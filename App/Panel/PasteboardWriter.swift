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
        // One item carries the value and both markers, so there is no moment where the secret sits on the
        // pasteboard unmarked. Clipboard managers skip items that carry the markers.
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string),
            item.setData(Data(), forType: Self.concealed),
            item.setData(Data(), forType: Self.transient)
        else { throw WriteError.failed }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else {
            // Never leave a half-written or unmarked secret behind.
            pasteboard.clearContents()
            throw WriteError.failed
        }
        lastChangeCount = pasteboard.changeCount
    }
}
