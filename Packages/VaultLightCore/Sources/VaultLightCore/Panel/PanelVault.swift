import Foundation

/// What the panel needs from the vault (spec 5, 2.2). `SessionManager` is the production implementation;
/// tests use an in-memory fake, so no test starts `bw`.
public protocol PanelVault: Sendable {
    /// Ranked results for the query. Starts no process.
    func search(_ query: String) async -> [SearchResult]
    /// Records a copy for the ranking boost and the empty-query list (spec 5.1).
    func recordCopy(id: String) async
    /// `bw get password`. Throws `BWError.noValue` when the item has none.
    func password(for id: String) async throws -> String
    /// `bw get totp`. Throws `BWError.noValue` when the item has none.
    func totp(for id: String) async throws -> String
}

extension SessionManager: PanelVault {}

/// The side effects the panel causes outside Core. The App implements this with the clipboard manager (spec 6)
/// and `NSWorkspace`; tests use a recording fake.
@MainActor
public protocol PanelSystem: AnyObject {
    /// Writes a password or TOTP code to the clipboard and schedules the timed clear (spec 6.1, 6.2).
    func copySecret(_ value: String) throws
    /// Writes a username to the clipboard; it is not cleared on a timer (spec 6.1).
    func copyUsername(_ value: String) throws
    /// Opens the URL in the default browser.
    func open(_ url: URL)
}
