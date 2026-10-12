//
//  PersonPickerSheet.swift
//  GeneaLogicApp
//

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The shared shell for every sheet that picks a concluded person from a searchable
/// list: the resolve-mention sheet (42), the relationship editor (43), the couple-partner
/// picker (43c) and the dangling-endpoint replacement (44g).
///
/// Each of those had hand-written its own copy of the same ~45 lines — the
/// `searchText`/`results` pair and its reload, the sizing block, the
/// `ScrollView`-of-`PersonPickRow` list, the centred empty state and the Cancel footer —
/// and the copies had **already drifted** (four different action verbs, two different
/// empty-state rules) before anyone noticed. What actually differs between them is the
/// wording, what extra controls sit above the search field, and what happens on select;
/// everything else is this shell.
///
/// It **only presents** — the caller owns the write, exactly as before, so the
/// evidence/conclusions boundary each sheet documents stays in that sheet.
///
/// Two `@ViewBuilder` slots carry the per-sheet extras:
///   - `accessory` sits between the header and the search field (the relationship
///     editor's kind/nature pickers, the partner picker's inline new-person form);
///   - `footerLeading` fills the leading end of the footer beside Cancel (the resolve
///     sheet's "create a new person from this mention" action).
struct PersonPickerSheet<Accessory: View, FooterLeading: View>: View {
    @Environment(ArchiveModel.self) private var model

    /// Sheet title (headline) and the caption beneath it.
    let title: String
    let prompt: String
    /// The trailing call-to-action on each row — "Link", "Add", "Select".
    let actionLabel: String
    /// A person to drop from the results (the subject of the sheet — you can't relate,
    /// marry or substitute someone with themselves). `nil` excludes nobody.
    ///
    /// It also decides the no-match wording: with an exclusion the candidates are the
    /// *other* people, so the message says so.
    let excluding: PersonID?
    /// Shown when there is nobody to pick at all, whatever the search says. Per-sheet,
    /// because each points at a different next step ("create a new spouse above", …).
    let emptyMessage: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let footerLeading: () -> FooterLeading
    let onSelect: (PersonID) -> Void

    @State private var searchText = ""

    /// The current results. Recomputed on appear and on each query change via
    /// `model.matchingPersons` (the engine name search, matching every one of a person's
    /// names) rather than on every body evaluation.
    @State private var results: [PersonSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            accessory()
            PersonSearchField(text: $searchText)
            Divider()
            peopleList
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        .frame(
            minWidth: Layout.ContentSheet.minWidth,
            idealWidth: Layout.ContentSheet.idealWidth,
            maxWidth: .infinity,
            minHeight: Layout.ContentSheet.minHeight,
            idealHeight: Layout.ContentSheet.idealHeight,
            maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        .onAppear { reloadResults() }
        .onChange(of: searchText) { reloadResults() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var peopleList: some View {
        if results.isEmpty {
            Text(hasAnyCandidate ? noMatchMessage : emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results, id: \.uid) { person in
                        PersonPickRow(person: person, actionLabel: actionLabel) {
                            onSelect(person.uid)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerLeading()
            Spacer()
            CancelSheetButton()
        }
    }

    /// Whether *any* person could be picked, ignoring the search — the difference
    /// between "this archive has nobody to offer" and "your search matched nothing".
    /// Derived from the candidate set rather than a raw person count, so it stays right
    /// however `excluding` is used.
    private var hasAnyCandidate: Bool {
        model.persons.contains { $0.uid != excluding }
    }

    private var noMatchMessage: String {
        excluding == nil
            ? "No people match “\(searchText)”."
            : "No other people match “\(searchText)”."
    }

    private func reloadResults() {
        results = model.matchingPersons(searchText).filter { $0.uid != excluding }
    }
}

/// The trailing Cancel every picker sheet ends with, wired to ⎋.
struct CancelSheetButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
    }
}
