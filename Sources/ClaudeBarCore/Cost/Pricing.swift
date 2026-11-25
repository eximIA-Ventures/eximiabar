import Foundation
import os

/// Per-token USD prices for a model.
public struct TokenPrice: Sendable, Equatable {
    /// USD per input token.
    public let input: Double
    /// USD per output token.
    public let output: Double
    /// USD per cache-read input token (`cache_read_input_tokens`).
    public let cacheRead: Double
    /// USD per cache-write input token (`cache_creation_input_tokens`, 5-minute TTL).
    public let cacheWrite: Double

    /// Anthropic's published multipliers when a model has no explicit cache price:
    /// cache read = 0.1 × input, 5-minute cache write = 1.25 × input.
    public static let defaultCacheReadMultiplier = 0.1
    public static let defaultCacheWriteMultiplier = 1.25

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * Self.defaultCacheReadMultiplier
        self.cacheWrite = cacheWrite ?? input * Self.defaultCacheWriteMultiplier
    }

    /// Convenience: build from USD per **million** tokens (how Anthropic publishes prices).
    static func perMillion(_ input: Double, _ output: Double, cacheRead: Double? = nil) -> TokenPrice {
        TokenPrice(
            input: input / 1_000_000,
            output: output / 1_000_000,
            cacheRead: cacheRead.map { $0 / 1_000_000 })
    }

    /// USD cost of one usage record (input + output + cache read + cache write).
    public func cost(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double {
        Double(input) * self.input
            + Double(output) * self.output
            + Double(cacheRead) * self.cacheRead
            + Double(cacheWrite) * self.cacheWrite
    }
}

/// Resolves per-token USD prices for Claude models (EXB-1.7 T2 / AC5).
///
/// Strategy:
///  1. In-memory cache (per model, valid for 24 h).
///  2. A models.dev catalog fetched lazily and cached to `UserDefaults` for 24 h.
///  3. A hardcoded fallback table when the network is unavailable / the cache is cold / the model
///     is unknown. Unknown models fall back to the current model of their family (opus/sonnet/haiku/fable),
///     then to `claude-sonnet-5-5`.
///
/// `actor` so all cache mutation and the network fetch run off the MainActor; callers `await`.
public actor Pricing {
    /// Hardcoded fallback prices, built from Anthropic's published USD-per-million prices. Keys
    /// are the normalized identifiers `normalize(_:)` produces. Cache prices are explicit where
    /// Anthropic publishes them; otherwise `TokenPrice` derives 0.1× / 1.25× input.
    static let fallbackTable: [String: TokenPrice] = [
        // Fable / Mythos
        "claude-fable-5-2": .perMillion(8, 40, cacheRead: 0.20),
        "claude-fable-5-1": .perMillion(10, 50),
        "claude-fable-5": .perMillion(10, 50),
        "claude-mythos-5-2": .perMillion(8, 40),
        "claude-mythos-5-1": .perMillion(10, 50),
        // Opus
        "claude-opus-5-5": .perMillion(4, 20, cacheRead: 0.20),
        "claude-opus-5": .perMillion(5, 25),
        "claude-opus-4-8": .perMillion(5, 25),
        "claude-opus-4-7": .perMillion(5, 25),
        "claude-opus-4-6": .perMillion(5, 25),
        "claude-opus-4-5": .perMillion(5, 25),
        "claude-opus-4-1": .perMillion(15, 75),
        "claude-opus-4": .perMillion(15, 75),
        // Sonnet
        "claude-sonnet-5-5": .perMillion(2, 10, cacheRead: 0.10),
        "claude-sonnet-5": .perMillion(2, 10),
        "claude-sonnet-4-6": .perMillion(3, 15),
        "claude-sonnet-4-5": .perMillion(3, 15),
        "claude-sonnet-4": .perMillion(3, 15),
        "claude-3-7-sonnet": .perMillion(3, 15),
        "claude-3-5-sonnet": .perMillion(3, 15),
        // Haiku (haiku-5-5: price for prompts up to 100K tokens)
        "claude-haiku-5-5": .perMillion(0.10, 0.50),
        "claude-haiku-4-5": .perMillion(1, 5),
        "claude-haiku-3-5": .perMillion(0.8, 4),
        "claude-3-5-haiku": .perMillion(0.8, 4),
    ]

    /// Current model per family — used for unknown IDs whose family can still be inferred
    /// (e.g. a future `claude-opus-5-9` is priced as the current Opus, not as Sonnet).
    static let currentModelByFamily: [(family: String, key: String)] = [
        ("fable", "claude-fable-5-2"),
        ("mythos", "claude-mythos-5-2"),
        ("opus", "claude-opus-5-5"),
        ("sonnet", "claude-sonnet-5-5"),
        ("haiku", "claude-haiku-5-5"),
    ]

    /// The model whose prices are used when not even the family can be inferred.
    static let unknownModelFallbackKey = "claude-sonnet-5-5"

    /// The fallback-table price for `model` (exact normalized key → family → default).
    static func fallbackPrice(for model: String) -> TokenPrice {
        let key = Self.normalize(model)
        if let price = Self.fallbackTable[key] { return price }
        for (family, familyKey) in Self.currentModelByFamily where key.contains(family) {
            return Self.fallbackTable[familyKey]!
        }
        return Self.fallbackTable[Self.unknownModelFallbackKey]!
    }

    /// models.dev catalog endpoint (AC5, Dev Notes).
    static let modelsDevURL = URL(string: "https://models.dev/api/models.json")!

    /// `UserDefaults` keys for the persisted models.dev catalog + its fetch timestamp.
    static let catalogDefaultsKey = "costScanner.modelsDevCatalog"
    static let catalogTimestampDefaultsKey = "costScanner.modelsDevCatalogFetchedAt"

    /// Catalog freshness window (24 h, AC5).
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let transport: HTTPTransport
    private let defaults: CostDefaults
    private let now: @Sendable () -> Date
    /// Whether to attempt a network fetch at all. Disabled in tests to assert the fallback path (AC14d).
    private let networkEnabled: Bool
    private let log = Logger(subsystem: CoreLog.subsystem, category: "cost.pricing")

    /// In-memory price cache: normalized model → (price, fetchedAt).
    private var memoryCache: [String: (price: TokenPrice, fetchedAt: Date)] = [:]
    /// The decoded models.dev catalog (normalized model → price), or `nil` until loaded.
    private var catalog: [String: TokenPrice]?
    /// When `catalog` was loaded (from network or persisted cache).
    private var catalogFetchedAt: Date?
    /// Guards against re-fetching the catalog repeatedly within one scan after a failure.
    private var catalogFetchAttempted = false

    public init(
        transport: HTTPTransport = HTTPClient(),
        defaults: CostDefaults = CostDefaults(),
        networkEnabled: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.transport = transport
        self.defaults = defaults
        self.networkEnabled = networkEnabled
        self.now = now
    }

    /// Per-token USD prices for `model`. Never throws — always returns a usable price (AC5, AC12).
    public func costPerToken(model: String) async -> (input: Double, output: Double) {
        let price = await self.price(for: model)
        return (price.input, price.output)
    }

    /// Full per-token price (including cache read / write) for `model`. Never throws.
    public func tokenPrice(model: String) async -> TokenPrice {
        await self.price(for: model)
    }

    /// Resolve a `TokenPrice` for `model`, consulting (in order) memory cache → catalog → fallback.
    private func price(for model: String) async -> TokenPrice {
        let key = Self.normalize(model)

        // 1. Memory cache (24 h).
        if let cached = self.memoryCache[key], self.now().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached.price
        }

        // 2. models.dev catalog (lazy load, 24 h cache).
        await self.ensureCatalogLoaded()
        if let catalog = self.catalog, let price = catalog[key] {
            self.memoryCache[key] = (price, self.now())
            return price
        }

        // 3. Hardcoded fallback; unknown model → current model of its family, else sonnet-5-5.
        let fallback = Self.fallbackPrice(for: key)
        self.memoryCache[key] = (fallback, self.now())
        return fallback
    }

    // MARK: - models.dev catalog

    /// Load the catalog from the 24 h `UserDefaults` cache, or fetch it from models.dev on a cold /
    /// stale cache. Failures degrade silently to the fallback table (AC12).
    private func ensureCatalogLoaded() async {
        if let fetchedAt = self.catalogFetchedAt,
           self.now().timeIntervalSince(fetchedAt) < Self.cacheTTL,
           self.catalog != nil
        {
            return
        }

        // Try the persisted cache first.
        if let (cached, fetchedAt) = self.loadPersistedCatalog(),
           self.now().timeIntervalSince(fetchedAt) < Self.cacheTTL
        {
            self.catalog = cached
            self.catalogFetchedAt = fetchedAt
            return
        }

        // Network fetch (once per Pricing instance lifecycle after a failure, to avoid hammering).
        guard self.networkEnabled, !self.catalogFetchAttempted else {
            // Network disabled or already attempted: keep any stale persisted catalog if present.
            if self.catalog == nil, let (cached, fetchedAt) = self.loadPersistedCatalog() {
                self.catalog = cached
                self.catalogFetchedAt = fetchedAt
            }
            return
        }
        self.catalogFetchAttempted = true

        do {
            var request = URLRequest(url: Self.modelsDevURL)
            request.timeoutInterval = 10
            let response = try await self.transport.send(request)
            guard response.statusCode == 200 else {
                self.log.debug("models.dev fetch non-200: \(response.statusCode, privacy: .public)")
                return
            }
            guard let parsed = Self.parseCatalog(response.data) else {
                self.log.debug("models.dev parse produced no Claude prices")
                return
            }
            self.catalog = parsed
            self.catalogFetchedAt = self.now()
            self.persistCatalog(parsed, fetchedAt: self.now())
            self.log.debug("models.dev catalog loaded: \(parsed.count, privacy: .public) models")
        } catch {
            // Silent fallback (AC12): keep stale persisted catalog if any.
            self.log.debug("models.dev fetch failed: \(error.localizedDescription, privacy: .public)")
            if self.catalog == nil, let (cached, fetchedAt) = self.loadPersistedCatalog() {
                self.catalog = cached
                self.catalogFetchedAt = fetchedAt
            }
        }
    }

    private func loadPersistedCatalog() -> (catalog: [String: TokenPrice], fetchedAt: Date)? {
        guard let data = self.defaults.data(forKey: Self.catalogDefaultsKey),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else { return nil }
        let fetchedAt = Date(timeIntervalSince1970: self.defaults.double(forKey: Self.catalogTimestampDefaultsKey))
        var prices: [String: TokenPrice] = [:]
        // `[input, output]` (pre-cache format) or `[input, output, cacheRead, cacheWrite]`.
        for (key, values) in raw {
            switch values.count {
            case 2: prices[key] = TokenPrice(input: values[0], output: values[1])
            case 4: prices[key] = TokenPrice(
                    input: values[0], output: values[1], cacheRead: values[2], cacheWrite: values[3])
            default: continue
            }
        }
        guard !prices.isEmpty else { return nil }
        return (prices, fetchedAt)
    }

    private func persistCatalog(_ catalog: [String: TokenPrice], fetchedAt: Date) {
        let raw = catalog.mapValues { [$0.input, $0.output, $0.cacheRead, $0.cacheWrite] }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        self.defaults.set(data, forKey: Self.catalogDefaultsKey)
        self.defaults.set(fetchedAt.timeIntervalSince1970, forKey: Self.catalogTimestampDefaultsKey)
    }

    /// Parse the models.dev `models.json` payload into normalized Claude per-token prices.
    ///
    /// models.dev publishes prices per **million** tokens under `cost.input` / `cost.output`; the
    /// catalog is `{ providerID: { models: { modelID: {...} } } }`. We keep only Anthropic models
    /// and convert per-million → per-token. Robust to schema drift: anything we can't read is skipped.
    static func parseCatalog(_ data: Data) -> [String: TokenPrice]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var result: [String: TokenPrice] = [:]

        func absorb(modelID: String, _ model: [String: Any]) {
            guard let cost = model["cost"] as? [String: Any] else { return }
            guard let inputPerMillion = Self.toDouble(cost["input"]),
                  let outputPerMillion = Self.toDouble(cost["output"])
            else { return }
            let key = Self.normalize(modelID)
            guard key.hasPrefix("claude") else { return }
            result[key] = TokenPrice(
                input: inputPerMillion / 1_000_000,
                output: outputPerMillion / 1_000_000,
                cacheRead: Self.toDouble(cost["cache_read"]).map { $0 / 1_000_000 },
                cacheWrite: Self.toDouble(cost["cache_write"]).map { $0 / 1_000_000 })
        }

        // Layout A: { provider: { models: { id: {...} } } }
        for (_, providerAny) in root {
            guard let provider = providerAny as? [String: Any] else { continue }
            if let models = provider["models"] as? [String: Any] {
                for (id, m) in models {
                    if let model = m as? [String: Any] { absorb(modelID: id, model) }
                }
            }
        }
        // Layout B (flat): { modelID: {...cost...} } — covered by re-scanning top-level entries.
        for (id, m) in root {
            if let model = m as? [String: Any], model["cost"] != nil {
                absorb(modelID: id, model)
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func toDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Model normalization

    /// Normalize a raw model identifier to a fallback-table / catalog key.
    ///
    /// Strips `anthropic.` / `anthropic/` provider prefixes, a Bedrock `-vN[:N]` suffix and a
    /// trailing `-YYYYMMDD` date stamp, then collapses to the **longest** known key that matches on a
    /// `-` boundary — so `claude-opus-4-8` stays `claude-opus-4-8` (not `claude-opus-4`), while
    /// `claude-sonnet-4-20250514` → `claude-sonnet-4`. Unknown IDs are returned cleaned but intact.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["anthropic.", "anthropic/", "us.anthropic.", "eu.anthropic."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // Bedrock version suffix (`-v1:0`) and Vertex `@20250514`.
        if let r = s.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: #"@\d{8}$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        // Drop a trailing `-YYYYMMDD` build date.
        if let dateRange = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s = String(s[..<dateRange.lowerBound])
        }

        for key in Self.knownKeysLongestFirst where s == key || s.hasPrefix(key + "-") {
            return key
        }
        return s
    }

    /// Fallback-table keys, longest first (longest-prefix wins).
    private static let knownKeysLongestFirst: [String] =
        fallbackTable.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    /// Human-readable name for a normalized model ID: `claude-opus-5-5` → `Opus 5.5`,
    /// `claude-3-5-sonnet` → `Sonnet 3.5`. Unrecognised IDs are returned unchanged.
    public static func displayName(for model: String) -> String {
        let key = Self.normalize(model)
        var parts = key.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2 else { return model }
        parts.removeFirst()
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        guard let familyIndex = parts.firstIndex(where: { families.contains($0) }) else { return model }
        let family = parts.remove(at: familyIndex)
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return model }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + parts.joined(separator: ".")
    }
}
