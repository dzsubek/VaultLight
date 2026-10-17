import AppKit
import VaultLightCore

/// Writes to the system clipboard as spec 6.1 requires.
@MainActor
final class PasteboardWriter: PanelSystem {
    enum WriteError: Error {
        case failed
    }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    /// The pasteboard's `changeCount` after the last write; compared before clearing.
    private(set) var lastChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copySecret(_ value: String) throws {
        try write(value)
        // TODO: clear after the timeout
    }

    func copyUsername(_ value: String) throws {
        try write(value)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func write(_ value: String) throws {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        // The markers go on first-class types of the same item: clipboard managers skip items that carry them.
        guard pasteboard.setString(value, forType: .string),
            pasteboard.setData(Data(), forType: Self.concealed),
            pasteboard.setData(Data(), forType: Self.transient)
        else {
            // Never leave an unmarked secret behind.
            pasteboard.clearContents()
            throw WriteError.failed
        }
        lastChangeCount = pasteboard.changeCount
    }
}
