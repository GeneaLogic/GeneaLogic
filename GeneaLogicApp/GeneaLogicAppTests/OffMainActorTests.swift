import Foundation
import Testing

@testable import GeneaLogicApp

/// Slice 84's hand-test: the background work that wasn't.
///
/// The app builds with Approachable Concurrency, under which a `nonisolated async`
/// function runs on its caller's actor. The duplicates scan, the file sweep, the
/// reconcile and Verify Integrity were all written that way to run in the background,
/// and all ran on the main thread. They are `@concurrent` now. These pin the rule the
/// fix relies on, so a change to the setting or the language shows up here.
@MainActor
@Suite struct OffMainActorTests {
    @Test func nonisolatedAsyncStaysOnTheCallersActor() async {
        #expect(pthread_main_np() != 0)
        #expect(await Self.nonisolatedProbe())
    }

    @Test func concurrentLeavesTheMainThread() async {
        #expect(pthread_main_np() != 0)
        #expect(await Self.concurrentProbe() == false)
    }

    private nonisolated static func nonisolatedProbe() async -> Bool {
        pthread_main_np() != 0
    }

    @concurrent
    private nonisolated static func concurrentProbe() async -> Bool {
        pthread_main_np() != 0
    }
}
