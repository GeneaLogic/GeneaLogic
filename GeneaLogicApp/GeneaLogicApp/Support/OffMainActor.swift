import Foundation

/// Runs `work` off the main actor, on the global concurrent executor, as part of the
/// calling task: cancelling the caller cancels it, unlike a `Task.detached`.
///
/// **`nonisolated async` alone does not leave the main actor in this app** (found in
/// slice 84's hand-test). The target builds with Approachable Concurrency, whose
/// `NonisolatedNonsendingByDefault` runs a `nonisolated async` function on its
/// caller's actor. The duplicates scan and the file sweep were written that way to run
/// in the background, and both ran on the main thread: the quadratic scan froze the
/// window for a second or more on a 400-person archive. `@concurrent` is the spelling
/// that means "off the caller's actor" under that rule.
@concurrent
nonisolated func offMainActor<T: Sendable>(_ work: @Sendable () -> T) async -> T {
    work()
}
