import Foundation

public extension UsageSnapshot {
    /// Maps a decoded `OAuthUsageResponse` to the immutable `UsageSnapshot` value type
    /// (AC9, AC10).
    ///
    /// - `session`: from `five_hour`, with fallback cascade
    ///   `five_hour → seven_day → seven_day_oauth_apps → seven_day_sonnet → seven_day_opus`
    ///   (first non-nil wins). `windowMinutes == 300`.
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
        // Session — fallback cascade (AC9, spec §4.4).
        let sessionSource = response.fiveHour
            ?? response.sevenDay
            ?? response.sevenDayOAuthApps
            ?? response.sevenDaySonnet
            ?? response.sevenDayOpus
        let session = Self.window(
            from: sessionSource,
            windowMinutes: 300,
            fallbackUtilization: 0)

        // Weekly — from seven_day.
        let weekly = Self.window(
            from: response.sevenDay,
            windowMinutes: 10080,
            fallbackUtilization: 0)

        // Sonnet — from seven_day_sonnet ?? seven_day_opus.
        let sonnetSource = response.sevenDaySonnet ?? response.sevenDayOpus
        let sonnet = sonnetSource.flatMap { Self.window(from: $0, windowMinutes: 10080) }

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
