import SwiftUI

/// Alerts preferences pane — new in the v2.1.4 redesign.
///
/// Consolidates everything about *when the app warns you*, which used to be split between the old
/// General tab (notifications master + sound + predictive) and the Claude tab (the warning
/// thresholds, which were duplicated). One master toggle gates the detail rows: the per-window
/// warning thresholds, the alert sound, and the predictive-exhaustion alert.
@MainActor
struct PreferencesAlertsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                notificationsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var notificationsSection: some View {
        SettingsSection(contentSpacing: 12) {
            SectionHeader(L("settings.alerts.section.notifications"))

            PreferenceToggleRow(
                title: L("settings.general.notifications"),
                subtitle: L("settings.general.notifications.subtitle"),
                binding: $settings.notificationsEnabled)

            // Every alert detail is suppressed when the master switch is off.
            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(L("settings.alerts.section.thresholds"))
                    ThresholdPairField(
                        title: L("settings.threshold.session"),
                        thresholds: $settings.sessionThresholds)
                    ThresholdPairField(
                        title: L("settings.threshold.weekly"),
                        thresholds: $settings.weeklyThresholds)

                    PreferenceToggleRow(
                        title: L("settings.general.play_sound"),
                        subtitle: nil,
                        binding: $settings.notificationSound)

                    // EXB-4.3: predictive exhaustion alert. Suppressed when notifications are off.
                    PreferenceToggleRow(
                        title: L("settings.general.predictive_alerts"),
                        subtitle: L("settings.general.predictive_alerts.subtitle"),
                        binding: $settings.predictiveAlertsEnabled)
                }
            }
        }
    }
}
