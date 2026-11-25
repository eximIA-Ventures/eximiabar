import SwiftUI
import Testing
@testable import ClaudeBar

/// EXB-6.2 AC2 — colour follows gravity. Neutral when healthy and on pace, amber on deficit or
/// >= 70%, red only when the burn empties the window before the reset or >= 90%.
struct PopoverStyleZonesTests {
    @Test
    func severityThresholdsAreHalfOpen() {
        #expect(DesignTokens.severity(utilization: 69.9) == .neutral)
        #expect(DesignTokens.severity(utilization: 70) == .attention)
        #expect(DesignTokens.severity(utilization: 89.9) == .attention)
        #expect(DesignTokens.severity(utilization: 90) == .critical)
    }

    @Test
    func paceDrivesGravityBelowTheThresholds() {
        #expect(DesignTokens.severity(utilization: 20, inDeficit: true) == .attention)
        #expect(DesignTokens.severity(utilization: 20, inDeficit: true, runsOutBeforeReset: true) == .critical)
        #expect(DesignTokens.severity(utilization: 20) == .neutral)
    }

    @Test
    func neutralIsNotTheBrandColour() {
        #expect(DesignTokens.StatePalette.bar(.neutral) != DesignTokens.brand)
        #expect(DesignTokens.StatePalette.text(.neutral) != DesignTokens.brand)
        #expect(DesignTokens.StatePalette.bar(.attention) == DesignTokens.zoneAttentionBar)
        #expect(DesignTokens.StatePalette.bar(.critical) == DesignTokens.zoneCriticalBar)
    }

    /// No model identity swatch may coincide with a state colour, the brand or the meter accent —
    /// otherwise a heavy Opus week reads as an alert.
    @Test
    func modelPaletteStaysClearOfStateColours() {
        let forbidden = DesignTokens.StatePalette.all + [DesignTokens.brand, DesignTokens.meterAccent]
        for swatch in DashboardPalette.ramp {
            #expect(!forbidden.contains(swatch))
        }
        #expect(DashboardPalette.ramp(for: .meter) == DashboardPalette.ramp)
    }
}
