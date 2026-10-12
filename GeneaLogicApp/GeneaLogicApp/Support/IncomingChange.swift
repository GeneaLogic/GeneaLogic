//
//  IncomingChange.swift
//  GeneaLogicApp
//

import Foundation

/// A change from another machine that has not finished landing, as the window
/// says it (slice 61).
///
/// **Not damage, and the type exists to keep it that way.** Slice 60 spent three
/// rounds separating *this file has not arrived yet* from *this file is
/// damaged*, and the cheapest way to lose that distinction again would be to
/// route an arrival through `FileDamageSummary` and its octagon. So this is a
/// separate type with its own voice: no count, no octagon, and — unlike 56's and
/// 57's findings — **no file names**. Those are named because they are durable
/// and actionable; this one is transient and the only action is waiting, so a
/// list of paths that disappears by itself is noise. The Verify panel keeps the
/// detail for anyone who wants it.
enum IncomingChange: Equatable {
    /// A delivery is in flight and still looks like progress.
    case receiving
    /// It has been in flight without progress long enough that waiting is no
    /// longer the obvious reading — see `ArchiveModel.incomingChangeStallThreshold`.
    case stalled

    /// The one line the bar shows.
    ///
    /// **The stalled wording accuses nothing, deliberately.** A large file
    /// arriving over a slow link is structurally indistinguishable from one that
    /// stopped: sync providers download to a temporary file and swap it in, so an
    /// in-flight file is simply *absent* for the whole transfer and there is no
    /// progress to observe. Saying "the sync has failed" would therefore be the
    /// banner crying wolf on exactly the archives that most need it (57's rule).
    /// Saying it *hasn't finished* is true either way, and the escalation is the
    /// offer of somewhere to look rather than a diagnosis.
    var headline: String {
        switch self {
        case .receiving: "Receiving a change from another machine…"
        case .stalled: "A change from another machine hasn't finished arriving."
        }
    }

    var detail: String? {
        switch self {
        case .receiving: nil
        case .stalled: "If your sync has stopped, Verify Integrity shows what's still outstanding."
        }
    }

    /// Whether the bar offers Verify Integrity. Only once stalled: while a
    /// delivery is progressing normally there is nothing to go and look at, and a
    /// button on a transient bar invites a click that answers a question nobody
    /// had.
    var offersVerify: Bool { self == .stalled }
}
