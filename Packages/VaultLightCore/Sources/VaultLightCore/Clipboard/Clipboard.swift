import AppKit

/// The parts of `NSPasteboard` the clipboard manager uses (spec 6). `NSPasteboard` conforms; tests use a spy over
/// a private named pasteboard, never `.general`.
@MainActor
public protocol Clipboard: AnyObject {
    var changeCount: Int { get }
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
    @discardableResult func clearContents() -> Int
}

extension NSPasteboard: Clipboard {}
