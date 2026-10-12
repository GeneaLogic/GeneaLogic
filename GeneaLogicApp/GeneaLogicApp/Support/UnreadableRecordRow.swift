//
//  UnreadableRecordRow.swift
//  GeneaLogicApp
//

import Foundation
import GeneaLogicArchive

/// A placeholder for a record the archive could not read — the row that stands
/// where an artifact or a person would have been (slice 56).
///
/// **The path is all there is.** A record that failed to decode has no index row,
/// so there is no title, no name, and — for an artifact — not even a uid, because
/// the uid was inside the file that didn't parse. Everything shown here is
/// therefore derived from the path.
///
/// That was the whole story until 59, when the path stopped being *all* the
/// archive knows: 58 keeps the record's own bytes against the same path, so a
/// restore is addressable where a uid-addressed mutation is not. The row's
/// identity is still path-derived and still weaker than the real thing — what
/// changed is that one operation can now be offered, and only when
/// `ArchiveModel.repairPlans` says there is a copy behind it.
///
/// **Since 58d it also stands for a record whose file is gone** (`.missing`) —
/// one the index kept a copy of, which is what makes it worth a row: it can be
/// restored, or deleted. The name stays (the record is
/// still one the archive cannot currently read), and so does the rule that the
/// row's identity is weaker than the real thing — except that the copy decodes,
/// so a row with a plan can say whose record it is (`displayLabel`).
struct UnreadableRecordRow: Identifiable, Hashable {
    /// Which browse list the record is missing from — or `other` for the kinds
    /// with no list of their own (relationships, links, dismissals), which the
    /// damage banner reports instead.
    enum Kind: Hashable {
        case artifact
        case person
        case other
    }

    /// Archive-relative path, e.g. `artifacts/deed-of-sale/record.json`.
    let path: String
    let kind: Kind

    /// What is wrong with the record — the engine's two skip reasons (slice 64),
    /// and a file that is gone (58d).
    enum Condition: Hashable {
        /// On disk, and couldn't be decoded.
        case undecodable
        /// Intact — written in an older archive format than the archive now is —
        /// so every sentence on the row is different for it: nothing was lost,
        /// and nothing is offered to restore.
        case olderFormat
        /// Not on disk at all, with a copy in the index (`StandingFindings.vanished`).
        case missing

        init(_ reason: UnreadableRecordReason) {
            switch reason {
            case .undecodable: self = .undecodable
            case .olderFormat: self = .olderFormat
            }
        }
    }

    let condition: Condition

    /// What to show as the row's identity: an artifact's folder slug (which is a
    /// friendly name, if a non-authoritative one), or a person's uid. Both are
    /// weaker than the real thing and are labelled as such in the row.
    let label: String

    var id: String { path }

    /// Parses one of `Archive.StandingFindings.unreadable`. Returns `nil` only
    /// for a path shaped like nothing the engine writes.
    init?(_ record: UnreadableRecord) {
        self.init(record.path, condition: Condition(record.reason))
    }

    /// One of `Archive.StandingFindings.vanished` (slice 58d).
    init?(missing path: String) {
        self.init(path, condition: .missing)
    }

    init?(_ path: String, condition: Condition = .undecodable) {
        self.path = path
        self.condition = condition

        let components = path.split(separator: "/").map(String.init)
        switch components.first {
        case "artifacts" where components.count == 3 && components[2] == "record.json":
            kind = .artifact
            label = components[1]
        case "conclusions" where components.count == 3:
            let uid = components[2].replacingOccurrences(of: ".json", with: "")
            kind = components[1] == "persons" ? .person : .other
            label = uid
        default:
            return nil
        }
    }

    /// The file itself, for Reveal in Finder.
    func fileURL(in root: URL) -> URL {
        root.appendingPathComponent(path)
    }

    /// The row's headline. Deliberately says *record*, not "artifact"/"person":
    /// what kind of thing it is comes from the folder it sits in, which is a
    /// weaker claim than a decoded record would make.
    ///
    /// **Kept short so it never truncates**, with `label` carrying the identity on
    /// the line below. The first version put both on one line and a narrow
    /// sidebar ate the middle of it — "Unreadable re…-of-sale-1899" — which drops
    /// the one word the row exists to say.
    var title: String {
        switch condition {
        case .undecodable: "Unreadable record"
        case .olderFormat: "Record in an older format"
        case .missing: "Missing record"
        }
    }

    /// The identity line: the saved copy's own name when the plan has one (58d,
    /// fork d), else the path-derived `label`. The copy is the same record and it
    /// decodes, so it can say *which* record — what a choice between Restore and
    /// Delete needs, and what `PER-0192…` could never tell anyone.
    func displayLabel(named recordLabel: String?) -> String {
        guard let recordLabel, !recordLabel.isEmpty else { return label }
        return recordLabel
    }

    /// Whether the file itself can be shown in Finder — not when it is gone.
    var canReveal: Bool { condition != .missing }

    /// What VoiceOver reads for the row — **including whether there is a restore
    /// to reach for** (review finding, 59).
    ///
    /// The row is one combined accessibility element (56: there is nothing here to
    /// navigate into, and three separate labels for one damaged record is worse
    /// than one sentence). Combining it means the label is written by hand, and a
    /// hand-written label does not learn about a new button on its own — so 59's
    /// Restore was visible to the eye and absent from the label, reachable only
    /// through the context menu. The affordance is named here, and matched by an
    /// `accessibilityAction` on the view, so the announcement and the action
    /// cannot drift apart.
    ///
    /// It lives on the row rather than in the view so it is testable where the
    /// rest of the row's wording is.
    func accessibilityLabel(
        canRestore: Bool, canDelete: Bool = false, named recordLabel: String? = nil
    ) -> String {
        let restore = canRestore ? " GeneaLogic has a saved copy that can be restored." : ""
        let delete = canDelete ? " It can also be deleted." : ""
        return "\(title), \(displayLabel(named: recordLabel)). \(detail)\(restore)\(delete)"
    }

    /// What the Verify Integrity panel says under a record row that has a saved
    /// copy (58d) — the row's own explanation, which the sidebar shows only on
    /// hover, named from the copy where it can be. The panel's generic line
    /// ("Listed in the manifest but absent on disk") says what is wrong with a
    /// *file*; this says what that means for the *record*, and what can be done.
    func panelDetail(named recordLabel: String?) -> String {
        let name = recordLabel.flatMap { $0.isEmpty ? nil : "“\($0)”. " } ?? ""
        let copy = condition == .missing ? "" : " GeneaLogic kept a copy, so it can be restored."
        return name + detail + copy
    }

    /// One line under the title, in the register of "here is what happened and
    /// what it means for you" rather than an error code.
    var detail: String {
        switch (condition, kind) {
        case (.undecodable, .artifact):
            "This artifact's record couldn't be read, so it isn't shown or searchable."
        case (.undecodable, .person):
            "This person's record couldn't be read, so they aren't shown or searchable."
        case (.undecodable, .other):
            "This record couldn't be read, so the archive is ignoring it."
        case (.olderFormat, .artifact):
            "This artifact's record is in an older archive format than the archive itself, "
                + "so it isn't shown until an upgrade brings it forward. The file is intact."
        case (.olderFormat, .person):
            "This person's record is in an older archive format than the archive itself, "
                + "so they aren't shown until an upgrade brings it forward. The file is intact."
        case (.olderFormat, .other):
            "This record is in an older archive format than the archive itself, so it's "
                + "left out until an upgrade brings it forward. The file is intact."
        case (.missing, .artifact):
            "This artifact's record file is gone from the archive, so it isn't shown or "
                + "searchable. GeneaLogic kept a copy."
        case (.missing, .person):
            "This person's record file is gone from the archive, so they aren't shown or "
                + "searchable. GeneaLogic kept a copy."
        case (.missing, .other):
            "This record's file is gone from the archive, so the archive is ignoring it. "
                + "GeneaLogic kept a copy."
        }
    }
}
