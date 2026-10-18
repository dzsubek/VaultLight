import AppKit
import Testing

@testable import VaultLightCore

/// A private named pasteboard, never `.general`, that records what the manager asked of it.
@MainActor
final class SpyPasteboard: Clipboard {
    private let name = NSPasteboard.Name("com.vaultlight.test.\(UUID().uuidString)")
    private let backing: NSPasteboard
    private(set) var preparedOptions: [NSPasteboard.ContentsOptions] = []
    private(set) var clears = 0
    var failsToWrite = false
    /// Another app takes the pasteboard right after our write, before the manager reads `changeCount`.
    var takenRightAfterWrite = false

    init() {
        backing = NSPasteboard(name: name)
        backing.clearContents()
    }

    deinit {
        NSPasteboard(name: name).releaseGlobally()
    }

    var changeCount: Int { backing.changeCount }

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        preparedOptions.append(options)
        return backing.prepareForNewContents(with: options)
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        guard !failsToWrite else { return false }
        let written = backing.writeObjects(objects)
        if takenRightAfterWrite { copyElsewhere("notes") }
        return written
    }

    func clearContents() -> Int {
        clears += 1
        return backing.clearContents()
    }

    /// Another app copies something.
    func copyElsewhere(_ text: String) {
        backing.clearContents()
        backing.setString(text, forType: .string)
    }

    var string: String? { backing.string(forType: .string) }
    var itemCount: Int { backing.pasteboardItems?.count ?? 0 }
    var types: Set<NSPasteboard.PasteboardType> { Set(backing.types ?? []) }
}

/// Time that moves only when the manager sleeps, so a 45 s countdown runs instantly and deterministically.
@MainActor
final class ClipboardTestClock {
    private let start = ContinuousClock.now
    private(set) var elapsed = Duration.zero
    /// Called after every sleep, once the time has moved on.
    var onSleep: ((Duration) -> Void)?

    var now: ContinuousClock.Instant { start + elapsed }

    /// Throws when cancelled, like `Task.sleep`.
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed += duration
        onSleep?(elapsed)
        await Task.yield()
    }
}

@MainActor
@Suite("ClipboardManager")
struct ClipboardManagerTests {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let pasteboard = SpyPasteboard()
    let clock = ClipboardTestClock()
    let manager: ClipboardManager

    init() {
        let clock = clock
        manager = ClipboardManager(
            pasteboard: pasteboard, now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    /// Lets queued main-actor work run, including a countdown task cancelled before it started.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// The pasteboard holds `value` for this Mac only, as one item carrying both markers.
    func expectWrittenAsOneConcealedTransientItem(_ value: String) {
        #expect(pasteboard.preparedOptions == [.currentHostOnly])
        #expect(pasteboard.itemCount == 1)
        #expect(pasteboard.types.isSuperset(of: [.string, Self.concealed, Self.transient]))
        #expect(pasteboard.string == value)
    }

    // MARK: Writing (spec 6.1)

    @Test func secretIsWrittenForThisMacOnlyAsOneConcealedTransientItem() throws {
        try manager.copySecret("pw-github")
        expectWrittenAsOneConcealedTransientItem("pw-github")
    }

    @Test func usernameIsWrittenTheSameWay() throws {
        try manager.copyUsername("octo")
        expectWrittenAsOneConcealedTransientItem("octo")
    }

    @Test func failedWriteThrowsLeavesNothingBehindAndStartsNoCountdown() async {
        pasteboard.failsToWrite = true
        #expect(throws: ClipboardError.writeFailed) { try manager.copySecret("pw-github") }
        #expect(pasteboard.string == nil)
        #expect(manager.secondsUntilClear == nil)
        await manager.waitUntilIdle()
        #expect(clock.elapsed == .zero)
    }

    // MARK: Clearing (spec 6.2)

    @Test(arguments: [15, 30, 45, 90])
    func secretIsClearedAfterTheTimeout(seconds: Int) async throws {
        manager.clearAfter = .seconds(seconds)
        try manager.copySecret("pw-github")
        #expect(manager.secondsUntilClear == seconds)
        await manager.waitUntilIdle()
        #expect(clock.elapsed == .seconds(seconds))
        #expect(pasteboard.clears == 1)
        #expect(pasteboard.string == nil)
        #expect(manager.secondsUntilClear == nil)
    }

    @Test func defaultTimeoutIs45Seconds() {
        #expect(ClipboardManager(pasteboard: pasteboard).clearAfter == .seconds(45))
    }

    @Test func countdownShowsEverySecondFromTheTimeoutDownToOne() async throws {
        var shown: [Int?] = []
        clock.onSleep = { [manager] _ in shown.append(manager.secondsUntilClear) }
        try manager.copySecret("pw-github")
        await manager.waitUntilIdle()
        #expect(shown == Array((1...45).reversed()))
        #expect(manager.secondsUntilClear == nil)
    }

    @Test func somethingCopiedElsewhereIsNeverClearedAndStopsTheCountdown() async throws {
        var shown: [Int?] = []
        clock.onSleep = { [manager, pasteboard] elapsed in
            shown.append(manager.secondsUntilClear)
            if elapsed == .seconds(10) { pasteboard.copyElsewhere("notes") }
        }
        try manager.copySecret("pw-github")
        await manager.waitUntilIdle()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "notes")
        #expect(manager.secondsUntilClear == nil)
        #expect(shown.count == 10)
    }

    @Test func somethingCopiedElsewhereInTheLastSecondIsNeverCleared() async throws {
        clock.onSleep = { [pasteboard] elapsed in
            if elapsed == .seconds(45) { pasteboard.copyElsewhere("notes") }
        }
        try manager.copySecret("pw-github")
        await manager.waitUntilIdle()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "notes")
    }

    @Test func aNewSecretReplacesThePendingClear() async throws {
        clock.onSleep = { [manager] elapsed in
            if elapsed == .seconds(30) { try? manager.copySecret("pw-gitlab") }
        }
        try manager.copySecret("pw-github")
        await manager.waitUntilIdle()
        #expect(clock.elapsed == .seconds(75))
        #expect(pasteboard.clears == 1)
        #expect(pasteboard.string == nil)
    }

    @Test func aNewSecretRestartsTheCountdown() async throws {
        var shown: [Int?] = []
        clock.onSleep = { [manager] elapsed in
            shown.append(manager.secondsUntilClear)
            if elapsed == .seconds(30) { try? manager.copySecret("pw-gitlab") }
        }
        try manager.copySecret("pw-github")
        await manager.waitUntilIdle()
        // 45…16 for the first secret; at 30 s the second starts again at 45.
        #expect(Array(shown.prefix(30)) == Array((16...45).reversed()))
        #expect(Array(shown.dropFirst(30)) == Array((1...45).reversed()))
    }

    @Test func aPasteboardTakenRightAfterOurWriteIsNeverCleared() async throws {
        pasteboard.takenRightAfterWrite = true
        try manager.copySecret("pw-github")
        #expect(manager.secondsUntilClear == nil)
        manager.clearPendingSecret()
        await manager.waitUntilIdle()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "notes")
    }

    // MARK: Quit (spec 6.2)

    @Test func quitClearsAPendingSecret() async throws {
        try manager.copySecret("pw-github")
        manager.clearPendingSecret()
        #expect(pasteboard.clears == 1)
        #expect(pasteboard.string == nil)
        #expect(manager.secondsUntilClear == nil)
        await settle()
        #expect(manager.secondsUntilClear == nil)
        #expect(pasteboard.clears == 1)
        #expect(clock.elapsed == .zero)
    }

    @Test func quitLeavesSomethingCopiedElsewhereAlone() throws {
        try manager.copySecret("pw-github")
        pasteboard.copyElsewhere("notes")
        manager.clearPendingSecret()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "notes")
    }

    @Test func quitWithNothingPendingDoesNothing() {
        pasteboard.copyElsewhere("notes")
        manager.clearPendingSecret()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "notes")
    }

    // MARK: Usernames (spec 6.1)

    @Test func usernamesAreNeverCleared() async throws {
        try manager.copyUsername("octo")
        #expect(manager.secondsUntilClear == nil)
        await manager.waitUntilIdle()
        manager.clearPendingSecret()
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "octo")
        #expect(clock.elapsed == .zero)
    }

    @Test func aUsernameCopiedOverASecretEndsTheCountdown() async throws {
        try manager.copySecret("pw-github")
        try manager.copyUsername("octo")
        #expect(manager.secondsUntilClear == nil)
        // The cancelled countdown task still runs once; it must not show a countdown again.
        await settle()
        #expect(manager.secondsUntilClear == nil)
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.string == "octo")
    }
}
