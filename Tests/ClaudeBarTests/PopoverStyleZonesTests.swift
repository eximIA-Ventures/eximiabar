import SwiftUI
import Testing
@testable import ClaudeBar

/// EXB redesign #3 — the semantic usage-zone colours. Pure functions of consumed %: brand terracotta
/// in the comfortable zone, amber at attention, red at critical, with half-open thresholds so 90.0
/// is already critical.
struct PopoverStyleZonesTests {
    @Test
    func barZonesAreDistinct() {
        let comfortable = PopoverStyle.zoneBarColor(utilization: 50)
        let attention = PopoverStyle.zoneBarColor(utilization: 80)
        let critical = PopoverStyle.zoneBarColor(utilization: 95)
        #expect(comfortable == PopoverStyle.brand)
        #expect(comfortable != attention)
        #expect(attention != critical)
        #expect(comfortable != critical)
    }

    @Test
    func barThresholdsAreHalfOpen() {
        #expect(PopoverStyle.zoneBarColor(utilization: 69.9) == PopoverStyle.brand)
        #expect(PopoverStyle.zoneBarColor(utilization: 70) == PopoverStyle.zoneAttentionBar)
        #expect(PopoverStyle.zoneBarColor(utilization: 89.9) == PopoverStyle.zoneAttentionBar)
        #expect(PopoverStyle.zoneBarColor(utilization: 90) == PopoverStyle.zoneCriticalBar)
        #expect(PopoverStyle.zoneBarColor(utilization: 100) == PopoverStyle.zoneCriticalBar)
    }

    /// The headline number tracks the same zones (with its own lighter amber/red variants).
    @Test
    func textZonesTrackTheBar() {
        #expect(PopoverStyle.zoneTextColor(utilization: 50) == PopoverStyle.brand)
        #expect(PopoverStyle.zoneTextColor(utilization: 80) == PopoverStyle.zoneAttentionText)
        #expect(PopoverStyle.zoneTextColor(utilization: 95) == PopoverStyle.zoneCriticalText)
    }
}
