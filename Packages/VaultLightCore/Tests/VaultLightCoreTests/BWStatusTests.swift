import Foundation
import Testing

@testable import VaultLightCore

/// `bw status` decoding beyond the state (spec 7.3): the last sync time the footer starts from.
@Suite("BWStatus")
struct BWStatusTests {
    @Test func statusReportsTheLastSync() async throws {
        let fake = try FakeBW()
        try fake.configure(["last_sync": SessionManagerTests.earlierSync.text])
        let lastSync = try #require(try await fake.client().status().lastSync)
        #expect(abs(lastSync.timeIntervalSince(SessionManagerTests.earlierSync.date)) < 0.000_1)
        try fake.configure(["last_sync": "2026-10-17T08:00:00Z"])
        #expect(try await fake.client().status().lastSync == Date(timeIntervalSince1970: 1_792_224_000))
    }

    /// `lastSync` is only shown in the footer: a value VaultLight can't read never fails `bw status`.
    @Test(arguments: [nil, 42, "yesterday"] as [(any Sendable)?])
    func unreadableLastSyncIsIgnored(_ value: (any Sendable)?) async throws {
        let fake = try FakeBW()
        try fake.configure(["last_sync": value ?? NSNull()])
        let status = try await fake.client().status()
        #expect(status.state == .unauthenticated)
        #expect(status.lastSync == nil)
    }
}
