import AppKit
import Carbon.HIToolbox
import VaultLightCore

/// The global shortcut (⌘⇧Space by default, spec 4.1), registered with Carbon `RegisterEventHotKey`, which needs no
/// Accessibility permission.
@MainActor
final class HotKey {
    private let onPress: @MainActor () -> Void
    // Released in `stop()` and `deinit`; Carbon handles aren't Sendable.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns `false` when the system refuses the shortcut (another app owns it). Replaces any earlier
    /// registration either way.
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        stop()
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The context is passed as a pointer, not captured: a C function pointer can't capture anything.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            InstallEventHandler(
                GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr
        else { return false }

        let identifier = EventHotKeyID(signature: OSType(0x564C_484B), id: 1)  // "VLHK"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    fileprivate func fire() {
        onPress()
    }
}

/// Runs on the main thread (the application event target). Hops to the main actor to call the closure.
private func hotKeyHandler(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in hotKey.fire() }
    return noErr
}

/// Carbon modifier bits and the AppKit flags they stand for: the recorder reads key events, the menu shows the
/// shortcut as a key equivalent.
extension HotKeyShortcut {
    private static let modifierPairs: [(carbon: UInt32, appKit: NSEvent.ModifierFlags)] = [
        (command, .command), (shift, .shift), (option, .option), (control, .control),
    ]

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        modifierPairs.filter { flags.contains($0.appKit) }.reduce(0) { $0 | $1.carbon }
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(Self.modifierPairs.filter { modifiers & $0.carbon != 0 }.map(\.appKit))
    }
}
