import Foundation

public extension UsageSnapshot {
    /// Maps a decoded `OAuthUsageResponse` to the immutable `UsageSnapshot` value type
    /// (AC9, AC10).
    ///
    /// - `session`: from `five_hour` only, `windowMinutes == 300`. **Optional**: plans without a
    ///   5-hour limit (Claude Ultra) omit the key or send `null`, and the snapshot then carries no
    ///   session window at all — no 0% bar, no reset line, no alert. (It used to cascade into
    ///   `seven_day`, which on Ultra showed the weekly figure a second time labelled "Session".)
    /// - `weekly`: from `seven_day`, `windowMinutes == 10080`.
    /// - `sonnet`: from `seven_day_sonnet ?? seven_day_opus`.
    /// - `dailyRoutines`: from `seven_day_routines`; if the key is present but null, a 0%
    ///   window is rendered.
    /// - `extraUsage`: monetary fields normalized from centavos to major units.
    /// - `plan`: resolved from `subscriptionType` / `rateLimitTier`.
    static func from(
        _ response: OAuthUsageResponse,
        rateLimitTier: String? = nil,
        subscriptionType: String? = nil,
        identity: Identity? = nil,
        source: DataSource = .oauth,
        now: Date = Date()) -> UsageSnapshot
    {
        // Session — `five_hour` only; absent / null → no session window (Ultra has no 5-hour limit).
        // An object with neither utilization nor reset is the same "no 5-hour limit" signal.
        let session = response.fiveHour
            .flatMap { $0.utilization == nil && $0.resetsAt == nil ? nil : $0 }
            .map { Self.window(from: $0, windowMinutes: 300) }

        // Weekly — from seven_day.
        let weekly = Self.window(
            from: response.sevenDay,
            windowMinutes: 10080,
            fallbackUtilization: 0)

        // Sonnet — from seven_day_sonnet only (Opus is now its own window, not a fallback).
        let sonnet = response.sevenDaySonnet.flatMap { Self.window(from: $0, windowMinutes: 10080) }

        // Opus — from seven_day_opus, promoted to its own per-model window (EXB redesign #3).
        let opus = response.sevenDayOpus.flatMap { Self.window(from: $0, windowMinutes: 10080) }

        // Fable — from seven_day_fable when present; absent key leaves no window (no 0% placeholder).
        let fable = response.sevenDayFable.flatMap { Self.window(from: $0, windowMinutes: 10080) }

        // Daily routines — render a 0% window if the key is present but null (AC9).
        let dailyRoutines: RateWindow?
        if let routines = response.sevenDayRoutines {
            dailyRoutines = Self.window(from: routines, windowMinutes: 1440, fallbackUtilization: 0)
        } else if response.sevenDayRoutinesSourceKey != nil {
            // Key present but null → 0% bar.
            dailyRoutines = RateWindow(utilization: 0, resetsAt: nil, windowMinutes: 1440)
        } else {
            dailyRoutines = nil
        }

        // Extra usage — centavos → major units (AC7).
        let extraUsage = response.extraUsage.flatMap { Self.mapExtraUsage($0) }

        let plan = ClaudePlan(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier)

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            sonnet: sonnet,
            opus: opus,
            fable: fable,
            dailyRoutines: dailyRoutines,
            extraUsage: extraUsage,
            plan: plan,
            identity: identity,
            updatedAt: now,
            source: source,
            error: nil)
    }

    // MARK: Helpers

    private static func window(
        from window: OAuthUsageWindow?,
        windowMinutes: Int,
        fallbackUtilization: Double? = nil) -> RateWindow
    {
        let utilization = window?.utilization ?? fallbackUtilization ?? 0
        let resetsAt = ISO8601Decoder.date(from: window?.resetsAt)
        return RateWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes)
    }

    private static func mapExtraUsage(_ extra: OAuthExtraUsage) -> ExtraUsage {
        // Monetary fields arrive in centavos; convert to major units.
        let monthlyLimit = (extra.monthlyLimit ?? 0) / 100.0
        let usedCredits = (extra.usedCredits ?? 0) / 100.0
        let currency = (extra.currency?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        return ExtraUsage(
            isEnabled: extra.isEnabled ?? false,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: extra.utilization,
            currency: currency)
    }
}

public extension UsageSnapshot.Identity {
    /// Projects the roster-level `AccountIdentity` onto the display shape the popover header
    /// already consumes (EXB-5.1 AC4.9).
    ///
    /// The two types stay separate deliberately: `AccountIdentity` carries the provider key and
    /// the org/UUID metadata the roster needs, while this one is the two-field value
    /// `DisplaySnapshot` and `UsageCardView` were written against. Replacing it would break both.
    init(_ account: AccountIdentity) {
        self.init(
            name: account.displayName ?? account.organizationName ?? account.email,
            email: account.email)
    }
}
