import AppKit
import SwiftUI

/// A menu-bar item for `command`, acting on the window's selection (slice 82). Lives in
/// `ArchiveCommands`, which has no environment model, so it takes the key window's.
/// Menu-bar items carry no symbol, as before.
struct CommandMenuItem: View {
    let command: ArchiveCommand
    let model: ArchiveModel?

    var body: some View {
        let context = model?.commandContext ?? CommandContext()
        Button(command.title(in: context), role: command.isDestructive ? .destructive : nil) {
            run(context)
        }
        .keyboardShortcut(context.ownsShortcut(command) ? command.shortcut : nil)
        .disabled(!context.isAvailable(command))
    }

    private func run(_ context: CommandContext) {
        // The shortcut typed in a text field means what it means there.
        if let action = command.textEditingAction, NSApp.currentEvent?.type == .keyDown,
            NSApp.keyWindow?.firstResponder is NSText
        {
            NSApp.sendAction(action, to: nil, from: nil)
            return
        }
        guard let model, let subject = context.selectionSubject(for: command) else { return }
        model.perform(command, on: subject)
    }
}

/// A button for `command` acting on `subject`, for a context menu or an in-pane menu: the
/// row it was opened on, not necessarily the selection (slice 82).
struct CommandButton: View {
    @Environment(ArchiveModel.self) private var model
    let command: ArchiveCommand
    let subject: CommandSubject

    init(_ command: ArchiveCommand, on subject: CommandSubject) {
        self.command = command
        self.subject = subject
    }

    var body: some View {
        Button(
            command.title, systemImage: command.systemImage,
            role: command.isDestructive ? .destructive : nil
        ) {
            model.perform(command, on: subject)
        }
        .disabled(!model.commandContext.canPerform(command, on: subject))
    }
}

extension View {
    /// Tells the window's commands that a sheet, dialog or alert this view presents is up
    /// while `isPresented` is true, so every command waits for it (slice 82). Goes beside
    /// the `.sheet`/`.confirmationDialog` it reports on.
    func reportsModal(_ isPresented: Bool) -> some View {
        modifier(ReportsModal(isPresented: isPresented))
    }
}

private struct ReportsModal: ViewModifier {
    @Environment(ArchiveModel.self) private var model
    let isPresented: Bool
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.setModal(token, presented: isPresented) }
            .onChange(of: isPresented) { _, presented in
                model.setModal(token, presented: presented)
            }
            // A view that goes away takes its sheet with it.
            .onDisappear { model.setModal(token, presented: false) }
    }
}
