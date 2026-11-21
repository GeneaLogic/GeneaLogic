import Foundation
import Testing

@testable import GeneaLogicApp

/// Slice 84's hand-test: the background work that wasn't. See `offMainActor`.
@MainActor
@Suite struct OffMainActorTests {
    /// The trap, pinned so the reason for `offMainActor` can't quietly stop being true
    /// or be forgotten: in this target a `nonisolated async` function called from the
    /// main actor runs on the main thread.
    @Test func nonisolatedAsyncStaysOnTheCallersActor() async {
        #expect(await Self.nonisolatedProbe())
    }

    @Test func offMainActorLeavesTheMainThread() async {
        #expect(pthread_main_np() != 0)
        #expect(await offMainActor { pthread_main_np() != 0 } == false)
    }

    private nonisolated static func nonisolatedProbe() async -> Bool {
        pthread_main_np() != 0
    }
}
