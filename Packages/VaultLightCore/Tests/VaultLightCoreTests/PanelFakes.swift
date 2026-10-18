import Foundation
import Testing

@testable import VaultLightCore

/// An in-memory vault: a real `SearchIndex` plus canned secrets. Records calls; never starts a process.
actor FakePanelVault: PanelVault {
    private var index: SearchIndex
    private var passwords: [String: String]
    private var codes: [String: String]
    private var errors: [String: BWError] = [:]
    private var delays: [String: Duration] = [:]
    private(set) var passwordCalls: [String] = []
    private(set) var totpCalls: [String] = []
    private(set) var copies: [String] = []
    private(set) var syncCalls = 0

    init(entries: [VaultEntry], passwords: [String: String] = [:], codes: [String: String] = [:]) {
        index = SearchIndex(entries: entries)
        self.passwords = passwords
        self.codes = codes
    }

    func fail(_ id: String, with error: BWError?) { errors[id] = error }
    func delay(query: String, by duration: Duration) { delays[query] = duration }

    func search(_ query: String) async -> [SearchResult] {
        let results = index.search(query)
        if let delay = delays[query] { try? await Task.sleep(for: delay) }
        return results
    }

    func recordCopy(id: String) {
        copies.append(id)
        index.recordCopy(id: id)
    }

    func password(for id: String) async throws -> String {
        passwordCalls.append(id)
        if let error = errors[id] { throw error }
        guard let value = passwords[id] else { throw BWError.noValue }
        return value
    }

    func sync() async throws {
        syncCalls += 1
    }

    func totp(for id: String) async throws -> String {
        totpCalls.append(id)
        if let error = errors[id] { throw error }
        guard let value = codes[id] else { throw BWError.noValue }
        return value
    }
}

@MainActor
final class RecordingPanelSystem: PanelSystem {
    struct CopyFailure: Error {}
    private(set) var secrets: [String] = []
    private(set) var usernames: [String] = []
    private(set) var opened: [URL] = []
    var failsToCopy = false

    func copySecret(_ value: String) throws {
        if failsToCopy { throw CopyFailure() }
        secrets.append(value)
    }

    func copyUsername(_ value: String) throws {
        if failsToCopy { throw CopyFailure() }
        usernames.append(value)
    }

    func open(_ url: URL) { opened.append(url) }
}
