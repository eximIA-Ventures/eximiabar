import AppKit
import ClaudeBarCore
import SwiftUI

// EXB-1.1 seeds the app target so the SwiftPM graph compiles end to end.
// UI (status item, popover, settings) arrives in EXB-1.2+.
// For now we provide a minimal agent-style entry point that links ClaudeBarCore.

@main
struct ClaudeBarMain {
    static func main() {
        // Headless bootstrap placeholder. The real AppDelegate/NSApplication wiring
        // lands in EXB-1.4 (AppState + Refresh Loop). Keeping this minimal avoids
        // pulling UI surface into the foundation story while still proving the
        // ClaudeBarCore link.
        let _ = UsageSnapshot.placeholder
        FileHandle.standardError.write(Data(
            "exímIABar core linked (EXB-1.1). UI lands in EXB-1.2+.\n".utf8))
    }
}
