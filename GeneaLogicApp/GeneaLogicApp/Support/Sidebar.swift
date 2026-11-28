import GeneaLogicArchive
import GeneaLogicModel

/// The window's one sidebar (slice 84): **Review, Artifacts and People** as sections of
/// one list, each section an area's collection, and the **Trash** pinned below it (86).
/// The types here are the sidebar's logic with no SwiftUI in it, so it can be tested as values: which area a row belongs to,
/// where a switch of area scrolls to, what a header's count says, and the order of
/// Review's rows.

/// One of the sidebar's sections, in the sidebar's order. Review is first: it is the work
/// owed. Trash is last: one row, pinned under the list rather than in it, so it neither
/// collapses nor scrolls away.
enum SidebarSection: String, CaseIterable, Identifiable {
    case review, artifacts, people, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: "Review"
        case .artifacts: "Artifacts"
        case .people: "People"
        case .trash: "Trash"
        }
    }

    /// The sections a search hides. Their rows aren't search results, and left among the
    /// results they would sit there unfiltered: Review (slice 84) and Trash (86).
    static func hidden(isSearching: Bool) -> Set<SidebarSection> {
        isSearching ? [.review, .trash] : []
    }
}

extension ArchiveTab {
    /// The section holding this area's collection. Tree is a view of People, so it is
    /// People's section.
    var section: SidebarSection {
        switch self {
        case .artifacts: .artifacts
        case .people, .tree: .people
        case .review: .review
        case .trash: .trash
        }
    }
}

/// A selectable row of the sidebar. Damaged-record placeholders and the duplicates
/// scan's progress row are rows too, but have no item: nothing can select them.
enum SidebarItem: Hashable {
    case review(ReviewItem.ID)
    case artifact(ArtifactID)
    case person(PersonID)
    /// The Trash row, which is its area's only row (slice 86).
    case trash

    var section: SidebarSection {
        switch self {
        case .review: .review
        case .artifact: .artifacts
        case .person: .people
        case .trash: .trash
        }
    }
}

/// What the sidebar can scroll to: a section's header or one of its items.
enum SidebarRowID: Hashable {
    case header(SidebarSection)
    case item(SidebarItem)
}

/// The window's area and each area's own selection, and how the sidebar's one list
/// selection maps onto them.
///
/// **The area is where the selection is.** The list shows one selected row, the
/// current area's; selecting a row in another section moves the area there, and each
/// area keeps its own selection for when it comes back.
struct SidebarSelection: Equatable {
    var area: ArchiveTab
    var artifact: ArtifactID?
    var person: PersonID?
    var review: ReviewItem.ID?
    /// Whether People was last shown as a tree, so coming back to it through a person
    /// row brings back the view it was left in.
    var peopleShowsTree = false

    /// The row the list shows selected: the current area's selection.
    var item: SidebarItem? {
        switch area.section {
        case .artifacts: artifact.map(SidebarItem.artifact)
        case .people: person.map(SidebarItem.person)
        case .review: review.map(SidebarItem.review)
        case .trash: .trash
        }
    }

    /// Selects `item`, moving the area to its section. A person keeps People's view:
    /// picking someone while the tree shows refocuses the tree rather than leaving it, and
    /// from another area returns to whichever view People was left in.
    ///
    /// **A deselection is ignored**, not applied. The list deselects when its selected
    /// row leaves it (a search filters it out, Review hides while searching), and the
    /// selection is what each area comes back to, so losing it there would lose it for
    /// good. Each detail resolves its selection against the whole archive, so a row
    /// filtered out of the sidebar still shows.
    mutating func select(_ item: SidebarItem?) {
        switch item {
        case .review(let id):
            area = .review
            review = id
        case .artifact(let id):
            area = .artifacts
            artifact = id
        case .person(let id):
            if area.section != .people { area = peopleShowsTree ? .tree : .people }
            person = id
        case .trash:
            area = .trash
        case nil:
            break
        }
    }
}

/// Where the sidebar goes when the area is switched without a click in it: by ⌘1–⌘4,
/// or by a jump (Show in People, Show in Tree, a mention's person, a person's source).
///
/// It scrolls to the area's selection if the list shows it, else to the section's
/// header, and expands the section first if it is collapsed. A hidden section (Review
/// and Trash while searching) has nothing to scroll to.
struct SidebarReveal: Equatable {
    /// The section to expand before scrolling, if it is collapsed.
    var expand: SidebarSection?
    /// The row to scroll to, or `nil` for none.
    var target: SidebarRowID?

    init(expand: SidebarSection?, target: SidebarRowID?) {
        self.expand = expand
        self.target = target
    }

    /// - Parameters:
    ///   - isListed: whether the list shows `item` right now (a search can filter the
    ///     selection out).
    init(
        for selection: SidebarSelection, collapsed: Set<SidebarSection>,
        hidden: Set<SidebarSection>, isListed: (SidebarItem) -> Bool
    ) {
        let section = selection.area.section
        // The Trash is pinned under the list, always in view: nothing to scroll to.
        guard !hidden.contains(section), section != .trash else {
            self.init(expand: nil, target: nil)
            return
        }
        let target: SidebarRowID =
            if let item = selection.item, isListed(item) { .item(item) } else { .header(section) }
        self.init(expand: collapsed.contains(section) ? section : nil, target: target)
    }
}

/// What a section header's count says.
enum SidebarCount {
    /// `"309"`, or `"15 of 309"` while a search or filter narrows the section.
    static func text(shown: Int, of total: Int) -> String {
        shown == total ? "\(total)" : "\(shown) of \(total)"
    }

    /// Review's count, with an ellipsis while the duplicates scan is still running, so a
    /// number that will grow doesn't read as the whole.
    static func review(_ count: Int, isScanning: Bool) -> String {
        isScanning ? "\(count)…" : "\(count)"
    }
}

/// One row of the sidebar's Review section. The lanes run one after another: names,
/// facts, relationships, then duplicates. **`rows` is the one definition of that order**:
/// `ArchiveModel.reviewRows`, which Review's keys walk, is drawn from it.
enum ReviewSidebarRow: Identifiable {
    case name(ReviewItem)
    case fact(FactReviewItem)
    case relationship(RelationshipReviewItem)
    case duplicate(DuplicateReviewItem)
    /// The duplicates lane's place while its first scan runs. Without it the lane would
    /// be absent mid-scan, which reads as "no duplicates".
    case scanningDuplicates

    /// The review ids are lane-prefixed (`ReviewSelection`), so this can't collide.
    static let scanningID = "scanning-duplicates"

    var id: String {
        switch self {
        case .name(let item): item.id
        case .fact(let item): item.id
        case .relationship(let item): item.id
        case .duplicate(let item): item.id
        case .scanningDuplicates: Self.scanningID
        }
    }

    /// The row's worklist target, or `nil` for the progress row.
    var target: ReviewTarget? {
        switch self {
        case .name(let item): item.target
        case .fact(let item): item.target
        case .relationship(let item): item.target
        case .duplicate(let item): item.target
        case .scanningDuplicates: nil
        }
    }

    static func rows(
        names: [ReviewItem], facts: [FactReviewItem], relationships: [RelationshipReviewItem],
        duplicates: [DuplicateReviewItem], isScanningDuplicates: Bool
    ) -> [ReviewSidebarRow] {
        var rows = names.map(Self.name) + facts.map(Self.fact)
        rows += relationships.map(Self.relationship)
        if isScanningDuplicates && duplicates.isEmpty { rows.append(.scanningDuplicates) }
        rows += duplicates.map(Self.duplicate)
        return rows
    }
}
