import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app-layer seam `ArchiveModel` routes a scan through, so the model can ask
/// for a scan without importing AppKit (the engine-facing model stays UI-free; the
/// concrete scanner lives entirely in this file). `completion` receives a
/// **session-temp file URL** for the captured document — a multi-page PDF for a
/// scan, a PNG for a single photo — which the model then funnels through the
/// existing ingest/attach paths.
@MainActor
protocol ContinuityScanning: AnyObject {
    /// Present **one** connected menu with a leading "choose files" item
    /// (`leadingTitle` — *Add Media…* for the `+`, *Attach File…* for attach) above
    /// the flat Continuity scan options. `onChooseFiles` runs for the leading item;
    /// `onScanned` gets a captured file. Both the new-artifact `+` and the per-artifact
    /// Attach route through this, so each is a single connected menu, never a SwiftUI
    /// menu that pops a second AppKit menu (a slice 32 follow-up).
    func requestAddOrScan(
        leadingTitle: String,
        onChooseFiles: @escaping () -> Void, onScanned: @escaping (URL) -> Void)
}

/// Owns the hidden `NSView` that joins the window's responder chain to receive
/// Continuity Camera ("Import from iPhone or iPad") content. macOS delivers that
/// content through the **NSServices** infrastructure, not a callable picker API:
/// when our receiver is first responder and advertises that it accepts image/PDF
/// data, AppKit auto-inserts *Take Photo* / *Scan Documents* into the menu we pop
/// up, then hands the captured bytes to `readSelection(from:)` via the pasteboard
/// (slice 23).
@MainActor
final class ContinuityCameraScanner: ContinuityScanning {
    /// The responder-chain receiver, embedded zero-size by `ContinuityCameraHost`.
    let receiver = ContinuityCameraReceiver()

    func requestAddOrScan(
        leadingTitle: String,
        onChooseFiles: @escaping () -> Void, onScanned: @escaping (URL) -> Void
    ) {
        receiver.presentAddMenu(
            leadingTitle: leadingTitle, onChooseFiles: onChooseFiles, onReceive: onScanned)
    }
}

/// Bridges the scanner's receiver into the SwiftUI hierarchy so it lives in a
/// window and can become first responder. Rendered zero-size — it's plumbing, not
/// a visible control.
struct ContinuityCameraHost: NSViewRepresentable {
    let scanner: ContinuityCameraScanner

    func makeNSView(context: Context) -> ContinuityCameraReceiver { scanner.receiver }
    func updateNSView(_ nsView: ContinuityCameraReceiver, context: Context) {}
}

/// A zero-size `NSView` that receives Continuity Camera content via NSServices.
///
/// AppKit shows the *Import from iPhone or iPad* items only when a first responder
/// returns itself from `validRequestor(forSendType:returnType:)` for an
/// image/PDF return type; popping an (initially empty) menu after making this view
/// first responder lets AppKit insert those items. The captured data arrives in
/// `readSelection(from:)` — a **PDF** for a multi-page scan, image data for a
/// single *Take Photo* — which we write to a temp file and hand back to the caller.
final class ContinuityCameraReceiver: NSView {
    private var onReceive: ((URL) -> Void)?
    private var onChooseFiles: (() -> Void)?

    /// One connected menu carrying a leading "choose files" item (`leadingTitle` —
    /// *Add Media…* for the `+`, *Attach File…* for attach) above the Continuity
    /// items (*Take Photo* / *Scan Documents*), so there's no separate floating
    /// pop-up. `onChooseFiles` runs when the user picks the leading item; a scan
    /// routes to `onReceive`. (Slice 23.)
    ///
    /// **Observed macOS grouping:** when the menu already has a leading item like
    /// this, AppKit nests the Continuity items under an *Import from iPhone or iPad ▸*
    /// submenu (grouped by device), Finder-style — nicer than the flat insertion an
    /// items-only menu gets. Either way it's one connected menu (verified live,
    /// a slice 32 follow-up).
    func presentAddMenu(
        leadingTitle: String, onChooseFiles: @escaping () -> Void,
        onReceive: @escaping (URL) -> Void
    ) {
        self.onChooseFiles = onChooseFiles
        presentMenu(onReceive: onReceive) { [weak self] menu in
            guard let self else { return }
            let item = NSMenuItem(
                title: leadingTitle, action: #selector(self.chooseFilesInvoked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
    }

    @objc private func chooseFilesInvoked() { onChooseFiles?() }

    /// Makes this view first responder and shows a menu AppKit fills with the
    /// Continuity Camera items. `configure` seeds any leading app items first. If no
    /// capable device is nearby AppKit adds nothing — a benign no-op.
    ///
    /// Two non-obvious requirements, both learned the hard way (slice 23):
    /// - **Deferred to the next runloop turn.** This is invoked from a SwiftUI menu
    ///   action / button, so that menu may still be mid-dismissal when we're called;
    ///   you can't begin a new menu session while one is tracking, so a synchronous
    ///   present is silently dropped.
    /// - **Shown via `popUpContextMenu(_:with:for:)`, not bare `popUp`.** AppKit
    ///   only inserts the Continuity items when the menu is presented through the
    ///   contextual-menu path, which walks the responder chain to this requestor.
    private func presentMenu(onReceive: @escaping (URL) -> Void, configure: ((NSMenu) -> Void)?) {
        self.onReceive = onReceive
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            let menu = NSMenu()
            configure?(menu)
            // A synthesized left-click at the cursor anchors the contextual menu.
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1)
            if let event {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                let viewPoint = self.convert(windowPoint, from: nil)
                menu.popUp(positioning: nil, at: viewPoint, in: self)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType, Self.accepts(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Whether we accept a given pasteboard return type — any image type (the set
    /// `NSImage` itself advertises, matching Apple's sample) or PDF.
    private static func accepts(_ type: NSPasteboard.PasteboardType) -> Bool {
        if NSImage.imageTypes.contains(type.rawValue) || type == .pdf { return true }
        if let utType = UTType(type.rawValue) {
            return utType.conforms(to: .image) || utType.conforms(to: .pdf)
        }
        return false
    }
}

extension ContinuityCameraReceiver: NSServicesMenuRequestor {
    /// Receives the captured document from the pasteboard. A *Scan Documents*
    /// capture arrives as a multi-page PDF; a *Take Photo* capture as image data,
    /// which we normalize to PNG. Either way we write a session-temp file and hand
    /// its URL to `onReceive`.
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let pdf = pasteboard.data(forType: .pdf) {
            return deliver(data: pdf, fileExtension: "pdf", namePrefix: "Scan")
        }
        if let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            return deliver(data: png, fileExtension: "png", namePrefix: "Photo")
        }
        return false
    }

    /// Writes `data` to a temp file (its base name becomes the new artifact's
    /// title when routed through ingest) and invokes `onReceive`.
    ///
    /// **Each capture gets its own folder** (slice 67). The name has one-second
    /// resolution, and since 67 the file outlives this call until its write runs —
    /// so two captures in the same second would otherwise share a path, the
    /// second overwriting the first and the first's cleanup deleting the second.
    /// The folder, not the name, carries the uniqueness, so the title stays
    /// readable; `ArchiveModel.discardScan(at:)` removes both.
    private func deliver(data: Data, fileExtension: String, namePrefix: String) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneaLogicScans", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = "\(namePrefix) \(Self.timestamp())"
        let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        onReceive?(url)
        return true
    }

    /// A filesystem-safe timestamp (no colons) for the captured file's name, e.g.
    /// `2026-06-27 at 14.30.45` — mirrors macOS's screenshot naming so a scanned
    /// artifact gets a sensible default title.
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
