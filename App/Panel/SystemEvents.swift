import AppKit
import VaultLightCore

/// Maps the system notifications that clear the in-memory session (spec 3.5) to Core's `SystemEvent`.
enum SystemEvents {
    /// Holds the observer tokens so the stream's termination handler can remove them.
    private final class Observers: @unchecked Sendable {
        private var removals: [() -> Void] = []

        func add(
            _ center: NotificationCenter, name: Notification.Name, queue: OperationQueue? = .main,
            _ body: @escaping @Sendable () -> Void
        ) {
            let token = center.addObserver(forName: name, object: nil, queue: queue) { _ in body() }
            removals.append { [weak center] in center?.removeObserver(token) }
        }

        func removeAll() {
            removals.forEach { $0() }
            removals.removeAll()
        }
    }

    static func stream() -> AsyncStream<SystemEvent> {
        AsyncStream { continuation in
            let observers = Observers()
            let workspace = NSWorkspace.shared.notificationCenter
            observers.add(workspace, name: NSWorkspace.willSleepNotification) {
                continuation.yield(.willSleep)
            }
            observers.add(workspace, name: NSWorkspace.sessionDidResignActiveNotification) {
                continuation.yield(.sessionResigned)
            }
            observers.add(DistributedNotificationCenter.default(), name: Notification.Name("com.apple.screenIsLocked"))
            {
                continuation.yield(.screenLocked)
            }
            continuation.onTermination = { _ in observers.removeAll() }
        }
    }
}
