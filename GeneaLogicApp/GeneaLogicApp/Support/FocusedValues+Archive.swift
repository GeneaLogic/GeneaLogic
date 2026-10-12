import SwiftUI

/// Publishes the active archive window's `ArchiveModel` to the (app-wide) File
/// menu commands, so a command like Add Media targets whichever archive window
/// is key. The payload is an `@Observable` reference — identity-compared, never a
/// closure — so it's safe to carry as a focused value.
extension FocusedValues {
    var archiveModel: ArchiveModel? {
        get { self[ArchiveModelKey.self] }
        set { self[ArchiveModelKey.self] = newValue }
    }

    private struct ArchiveModelKey: FocusedValueKey {
        typealias Value = ArchiveModel
    }
}
