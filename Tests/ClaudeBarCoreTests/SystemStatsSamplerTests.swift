import Foundation
import Testing
@testable import ClaudeBarCore

/// The sampler reads the live machine (Mach + libproc), so assertions are invariants that hold on
/// any Mac rather than fixture equality: a sample exists, percentages are clamped, totals are sane.
struct SystemStatsSamplerTests {
    @Test
    func sampleProducesSaneValues() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let stats = try #require(SystemStatsSampler.sample(now: now))

        #expect(stats.sampledAt == now)
        #expect(stats.memoryFreePercent >= 0)
        #expect(stats.memoryFreePercent <= 100)
        // Any Mac this runs on has at least 1 GB of RAM.
        #expect(stats.memoryTotalBytes > 1_000_000_000)
        #expect(stats.claudeSessionCount >= 0)
        // Sessions and bytes agree: bytes without a session would mean we mis-attributed a process.
        if stats.claudeSessionCount == 0 {
            #expect(stats.claudeResidentBytes == 0)
        }
    }
}
