import Foundation
import os

/// Per-token USD prices for a model.
public struct TokenPrice: Sendable, Equatable {
    /// USD per input token.
    public let input: Double
    /// USD per output token.
    public let output: Double

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// Resolves per-token USD prices for Claude models (EXB-1.7 T2 / AC5).
///
/// Strategy:
///  1. In-memory cache (per model, valid for 24 h).
///  2. A models.dev catalog fetched lazily and cached to `UserDefaults` for 24 h.
///  3. A hardcoded fallback table when the network is unavailable / the cache is cold / the model
///     is unknown. Unknown models fall back to `claude-sonnet-4` prices (AC5, T2).
///
/// `actor` so all cache mutation and the network fetch run off the MainActor; callers `await`.
public actor Pricing {
    /// Hardcoded fallback prices (USD per token), from the story spec (T2). Keys are the
    /// normalized model identifiers `normalize(_:)` produces.
    static let fallbackTable: [String: TokenPrice] = [
        "claude-opus-4": TokenPrice(input: 0.000015, output: 0.000075),
        "claude-sonnet-4": TokenPrice(input: 0.000003, output: 0.000015),
        "claude-3-5-sonnet": TokenPrice(input: 0.000003, output: 0.000015),
        "claude-haiku-3-5": TokenPrice(input: 0.0000008, output: 0.000004),
    ]

    /// The model whose prices are used when an unknown model is requested (AC5, T2).
    static let unknownModelFallbackKey = "claude-sonnet-4"

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

        // 3. Hardcoded fallback; unknown model → sonnet-4 prices (AC5).
        let fallback = Self.fallbackTable[key]
            ?? Self.fallbackTable[Self.unknownModelFallbackKey]!
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
        for (key, pair) in raw where pair.count == 2 {
            prices[key] = TokenPrice(input: pair[0], output: pair[1])
        }
        guard !prices.isEmpty else { return nil }
        return (prices, fetchedAt)
    }

    private func persistCatalog(_ catalog: [String: TokenPrice], fetchedAt: Date) {
        let raw = catalog.mapValues { [$0.input, $0.output] }
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
                output: outputPerMillion / 1_000_000)
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
    /// Strips an `anthropic.` provider prefix and a trailing `-YYYYMMDD` date stamp, then collapses
    /// known long IDs to their family key (e.g. `claude-sonnet-4-5` / `claude-sonnet-4-20250514`
    /// → `claude-sonnet-4`; `claude-opus-4-1` → `claude-opus-4`; `claude-3-5-sonnet-20241022`
    /// → `claude-3-5-sonnet`). Adapted from the reference `normalizeClaudeModel` but trimmed to the
    /// families exímIABar prices.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("anthropic.") { s = String(s.dropFirst("anthropic.".count)) }
        if s.hasPrefix("anthropic/") { s = String(s.dropFirst("anthropic/".count)) }

        // Drop a trailing `-YYYYMMDD` build date.
        if let dateRange = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s = String(s[..<dateRange.lowerBound])
        }

        // Collapse to a priced family key by longest-prefix match.
        let families = [
            "claude-3-5-sonnet",
            "claude-haiku-3-5",
            "claude-haiku-4",
            "claude-opus-4",
            "claude-sonnet-4",
        ]
        for family in families.sorted(by: { $0.count > $1.count }) where s.hasPrefix(family) {
            return family
        }
        return s
    }
}
