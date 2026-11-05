import AppKit
import SwiftUI

/// A menu-bar item for `command`, acting on the window's selection (slice 82). Lives in
/// `ArchiveCommands`, which has no environment model, so it takes the key window's.
/// Menu-bar items carry no symbol, as before.
struct CommandMenuItem: View {
    let command: ArchiveCommand
    let model: ArchiveModel?

    var body: some View {
        let context = model?.commandContext(for: command) ?? CommandContext()
        Button(command.title(in: context), role: command.isDestructive ? .destructive : nil) {
            run()
        }
        .keyboardShortcut(context.ownsShortcut(command) ? command.shortcut : nil)
        .disabled(!context.isAvailable(command))
    }

    private func run() {
        if let action = command.textEditingAction, NSApp.isTypingShortcut(of: command) {
            NSApp.sendAction(action, to: nil, from: nil)
            return
        }
        // The subject is the selection *now*, not when the menu was last drawn: SwiftUI can
        // redraw the menu bar after a key equivalent has already fired.
        guard let model, !NSApp.keyWindowIsUnderModal,
            let subject = model.commandContext(for: command).selectionSubject(for: command)
        else {
            NSSound.beep()
            return
        }
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
        .disabled(!model.canPerform(command, on: subject))
    }
}

/// A section heading's affordance for `command` (Add Name…, Attach File…), drawn as
/// `AddAffordanceLabel` and gated by the same rule as every other surface (slice 82).
///
/// **Not greyed while a sheet is up.** Nothing under a sheet can be clicked, and the
/// inspector dimming behind every sheet would only flicker; the rule is asked without it.
struct CommandAffordance: View {
    @Environment(ArchiveModel.self) private var model
    let command: ArchiveCommand
    let subject: CommandSubject
    var title: String?
    var opensMenu = false
    /// Runs in place of `perform`, for the one affordance whose in-pane action differs
    /// from the menu bar's (Attach File… offers the scan options here).
    var action: (() -> Void)?

    var body: some View {
        Button {
            if let action { action() } else { model.perform(command, on: subject) }
        } label: {
            AddAffordanceLabel(
                title: title ?? command.paneTitle, systemImage: command.systemImage,
                opensMenu: opensMenu)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    private var isAvailable: Bool {
        var context = model.commandContext(for: command)
        context.isPresentingModal = false
        return context.canPerform(command, on: subject)
    }
}

extension NSApplication {
    /// Whether AppKit has a sheet, dialog, alert or panel up over the key window: the
    /// backstop for one its presenting view didn't report (`reportsModal`). Reported
    /// modals grey the menu items; this keeps an unreported one from being covered.
    var keyWindowIsUnderModal: Bool {
        if modalWindow != nil { return true }
        guard let key = keyWindow else { return false }
        return key.sheetParent != nil || key.attachedSheet != nil
    }

    /// Whether the event being handled is `command`'s own shortcut typed into an editable
    /// text field. A menu's key equivalent is matched before the field sees the key, so
    /// the field is given it back. Not a Return in Help's search, nor a selectable label.
    fileprivate func isTypingShortcut(of command: ArchiveCommand) -> Bool {
        guard let shortcut = command.shortcut, let event = currentEvent,
            event.type == .keyDown,
            let field = keyWindow?.firstResponder as? NSTextView, field.isEditable
        else { return false }
        let typed = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return typed == String(shortcut.key.character)
            && modifiers.intersection([.command, .shift, .option, .control])
                == shortcut.modifiers.appKitFlags
    }
}

extension EventModifiers {
    fileprivate var appKitFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension View {
    /// Tells the window's commands that a sheet, dialog, popover or alert this view
    /// presents is up while `isPresented` is true, so their menu items grey out (slice
    /// 82). Goes beside the `.sheet`/`.confirmationDialog`/`.popover` it reports on.
    /// `NSApplication.keyWindowIsUnderModal` is the backstop for one that's missed.
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
