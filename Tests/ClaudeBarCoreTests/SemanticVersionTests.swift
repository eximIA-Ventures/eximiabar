import Testing
@testable import ClaudeBarCore

/// EXB-2.4 AC3: component-wise semver comparison.
@Suite
struct SemanticVersionTests {
    @Test
    func remotePatchNewer() {
        #expect(SemanticVersion.isNewer(remote: "1.1.1", than: "1.1.0"))
    }

    @Test
    func remoteMinorNewer() {
        #expect(SemanticVersion.isNewer(remote: "1.2.0", than: "1.1.9"))
    }

    @Test
    func remoteMajorNewer() {
        #expect(SemanticVersion.isNewer(remote: "2.0.0", than: "1.9.9"))
    }

    @Test
    func equalIsNotNewer() {
        #expect(!SemanticVersion.isNewer(remote: "1.1.0", than: "1.1.0"))
    }

    @Test
    func remoteOlderIsNotNewer() {
        #expect(!SemanticVersion.isNewer(remote: "1.0.0", than: "1.1.0"))
        #expect(!SemanticVersion.isNewer(remote: "1.1.0", than: "2.0.0"))
    }

    @Test
    func moreComponentsWinsWhenSharedEqual() {
        // 1.1.0 > 1.1 (the local app shipped a two-component version).
        #expect(SemanticVersion.isNewer(remote: "1.1.0", than: "1.1"))
        // 1.1 is not newer than 1.1.0.
        #expect(!SemanticVersion.isNewer(remote: "1.1", than: "1.1.0"))
    }

    @Test
    func nonNumericSuffixIgnored() {
        // Parsing stops at the first non-Int component, so "1.1.0-beta" → [1,1,0].
        #expect(!SemanticVersion.isNewer(remote: "1.1.0-beta", than: "1.1.0"))
        #expect(SemanticVersion.isNewer(remote: "1.2.0-rc1", than: "1.1.0"))
    }

    @Test
    func componentsParsesCleanly() {
        #expect(SemanticVersion.components("1.2.3") == [1, 2, 3])
        #expect(SemanticVersion.components("10.0.5") == [10, 0, 5])
        #expect(SemanticVersion.components("2.1") == [2, 1])
    }
}
