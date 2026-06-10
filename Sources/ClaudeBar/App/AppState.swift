import ClaudeBarCore
import Foundation
import Observation

/// The single source of UI truth.
///
/// **Stub for EXB-1.2.** It holds exactly one immutable `DisplaySnapshot` (anti-freeze rule:
/// one snapshot per refresh, no observable storm). The refresh loop that produces snapshots
/// from `UsageFetcher` lands in EXB-1.4; here `AppState` just stores whatever the app (or a
/// test / preview) assigns so the status item has something to render.
@MainActor
@Observable
final class AppState {
    /// The current snapshot, or `nil` before the first refresh completes.
    var snapshot: DisplaySnapshot?

    init(snapshot: DisplaySnapshot? = nil) {
        self.snapshot = snapshot
    }
}
