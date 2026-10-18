import AppKit
import Observation

public enum ClipboardError: Error, Equatable {
    /// The pasteboard refused the write. Anything it held before is already gone.
    case writeFailed
}

/// The clipboard manager (spec 6): writes values for this Mac only, marked so clipboard history apps skip them, and
/// clears a secret after the timeout unless something else was copied since.
///
/// It never stores a value: a secret lives on the pasteboard only. What it keeps is the pasteboard's `changeCount`
/// right after the write, which is how it knows the clipboard still holds that secret.
@MainActor
@Observable
public final class ClipboardManager {
    /// Whole seconds until the pending secret is cleared, counting down once a second; `nil` when no secret is
    /// pending. Drives the footer and the menu-bar countdown (design 04).
    public private(set) var secondsUntilClear: Int?
    /// The clear timeout (spec 6, 8). A change applies from the next copy.
    public var clearAfter = Duration.seconds(45)

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @ObservationIgnored private let pasteboard: any Clipboard
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    /// The pasteboard's `changeCount` right after a secret was written; `nil` when none is pending.
    @ObservationIgnored private var secretChangeCount: Int?
    /// The single delayed task that counts down and clears (spec 6.2). A new copy replaces it.
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    /// Held while a clear is pending: keeps App Nap from delaying the timer, and keeps macOS from terminating the
    /// app suddenly, which would skip the clear on quit.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    /// `now` and `sleep` default to the continuous clock, which keeps counting while the Mac sleeps, so a secret
    /// whose timeout passed during sleep is cleared on wake.
    public init(
        pasteboard: any Clipboard,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.now = now
        self.sleep = sleep
    }

    /// Writes a password or TOTP code and schedules its clear (spec 6.1, 6.2). Replaces any pending clear.
    public func copySecret(_ value: String) throws {
        let written = try write(value)
        // Another app took the pasteboard right after our write: what is there now isn't ours to clear.
        guard pasteboard.changeCount == written else { return }
        secretChangeCount = written
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Clearing the clipboard")
        secondsUntilClear = Self.wholeSeconds(clearAfter)
        let deadline = now() + clearAfter
        clearTask = Task { [weak self] in await self?.countdown(to: deadline) }
    }

    /// Writes a username the same way, without a timed clear (spec 6.1). A pending secret was just overwritten, so
    /// its countdown ends.
    public func copyUsername(_ value: String) throws {
        try write(value)
    }

    /// Clears the pending secret now if the clipboard still holds it, and ends the countdown. Called on quit
    /// (spec 6.2).
    public func clearPendingSecret() {
        if let secretChangeCount, pasteboard.changeCount == secretChangeCount {
            pasteboard.clearContents()
        }
        cancelPendingClear()
    }

    /// Returns the pasteboard's `changeCount` for our write: `prepareForNewContents` returns it, and
    /// `writeObjects` doesn't change it. Reading it afterwards could pick up another app's write instead.
    @discardableResult
    private func write(_ value: String) throws -> Int {
        // One item carries the value and both markers, so the secret never sits on the pasteboard unmarked.
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string),
            item.setData(Data(), forType: Self.concealed),
            item.setData(Data(), forType: Self.transient)
        else { throw ClipboardError.writeFailed }
        // From here the pasteboard's old contents are replaced, so a pending clear has nothing left to clear.
        cancelPendingClear()
        let written = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else {
            // Never leave a half-written or unmarked value behind.
            pasteboard.clearContents()
            throw ClipboardError.writeFailed
        }
        return written
    }

    private func cancelPendingClear() {
        clearTask?.cancel()
        clearTask = nil
        secretChangeCount = nil
        secondsUntilClear = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func countdown(to deadline: ContinuousClock.Instant) async {
        while case let remaining = deadline - now(), remaining > .zero {
            // A cancelled countdown was replaced or cleared by whoever cancelled it, possibly before this task
            // first ran: leave the state alone.
            guard !Task.isCancelled else { return }
            let seconds = Self.wholeSeconds(remaining)
            secondsUntilClear = seconds
            // Wake when the number shown changes.
            try? await sleep(remaining - .seconds(seconds - 1))
            guard !Task.isCancelled else { return }
            // Something else was copied: nothing of ours is left to clear.
            guard pasteboard.changeCount == secretChangeCount else { break }
        }
        clearPendingSecret()
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        Int((duration / .seconds(1)).rounded(.up))
    }

    /// For tests: returns once no countdown is pending.
    func waitUntilIdle() async {
        while let current = clearTask {
            await current.value
            if clearTask == current { return }
        }
    }
}
