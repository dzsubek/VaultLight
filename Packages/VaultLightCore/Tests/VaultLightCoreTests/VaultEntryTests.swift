import Foundation
import Testing

@testable import VaultLightCore

@Suite("VaultEntry")
struct VaultEntryTests {
    /// Values in the fixture vault that must never reach a `VaultEntry`.
    static let fixtureSecrets = [
        "fake-pw-", "otpauth://", "FAKEFAKE", "Branch: Budapest", "recovery-pin", "fake-field-secret",
        "fake-recovery-code", "4111111111111111",
    ]

    static func entries() async throws -> [VaultEntry] {
        let fake = try FakeBW.unlocked()
        let listed: [VaultEntry.Listed] = try await fake.client().listItems(session: FakeBW.session)
        #expect(listed.count == 15)
        return listed.compactMap(\.entry)
    }

    @Test func typeHoldsOnlyMetadata() {
        let entry = VaultEntry(id: "id", name: "name")
        let properties = Set(Mirror(reflecting: entry).children.compactMap(\.label))
        #expect(
            properties == [
                "id", "name", "username", "uris", "hosts", "folderId", "organizationId", "favorite", "hasTOTP",
            ])
    }

    @Test func decodesLoginMetadataFromTheFixture() async throws {
        let entries = try await Self.entries()
        let github = try #require(entries.first { $0.id == FakeBW.Item.github })
        #expect(github.name == "GitHub")
        #expect(github.username == "tester")
        #expect(github.uris == ["https://github.com/login"])
        #expect(github.hosts == ["github.com"])
        #expect(github.primaryHost == "github.com")
        #expect(github.folderId == "4ba68432-7f5f-5969-a603-89067894484c")
        #expect(github.organizationId == nil)
        #expect(github.favorite)
        #expect(github.hasTOTP)

        let gitlab = try #require(entries.first { $0.id == FakeBW.Item.gitlab })
        #expect(!gitlab.favorite)
        #expect(!gitlab.hasTOTP)

        let aws = try #require(entries.first { $0.name == "AWS Console" })
        #expect(aws.organizationId == "1307bd24-d6e1-546b-a7a7-a04653164a1f")
        #expect(aws.folderId == nil)
    }

    @Test func nonLoginItemsAreExcluded() async throws {
        let names = Set(try await Self.entries().map(\.name))
        #expect(names.count == 12)
        #expect(!names.contains("GitHub recovery codes"))
        #expect(!names.contains("Gift card"))
        #expect(!names.contains("Test identity"))
    }

    @Test func noSecretReachesAnEntry() async throws {
        for entry in try await Self.entries() {
            var text = ""
            dump(entry, to: &text)
            for secret in Self.fixtureSecrets {
                #expect(!text.contains(secret))
            }
        }
    }

    @Test func hostsComeFromEveryURI() async throws {
        let entries = try await Self.entries()
        let git = try #require(entries.first { $0.name == "Git server (self-hosted)" })
        #expect(git.hosts == ["git.internal.example", "git.internal.example"])
        let router = try #require(entries.first { $0.name == "Router admin" })
        #expect(router.hosts == ["192.168.1.1"])
        let gmail = try #require(entries.first { $0.name == "Gmail" })
        #expect(gmail.primaryHost == "accounts.google.com")
    }

    @Test func hostParsingHandlesBareAndOddURIs() {
        #expect(VaultEntry.host(of: "example.com/login") == "example.com")
        #expect(VaultEntry.host(of: "HTTPS://WWW.Example.COM") == "www.example.com")
        #expect(VaultEntry.host(of: "") == nil)
        #expect(VaultEntry.host(of: "not a uri") == nil)
    }

    @Test func missingOptionalFieldsDecode() throws {
        let json = Data(
            (#"[{"id":"a","type":1,"name":"Bare","login":{"uris":null,"username":null,"totp":""}},"#
                + #"{"id":"b","type":1,"name":"No login"}]"#).utf8)
        let listed = try JSONDecoder().decode([VaultEntry.Listed].self, from: json)
        let bare = try #require(listed[0].entry)
        #expect(bare.username == nil)
        #expect(bare.uris.isEmpty)
        #expect(!bare.hasTOTP)
        #expect(!bare.favorite)
        let noLogin = try #require(listed[1].entry)
        #expect(noLogin.hosts.isEmpty)
    }

    @Test func foldersAndOrganizationsDecode() async throws {
        let fake = try FakeBW.unlocked()
        let folders: [VaultFolder] = try await fake.client().listFolders(session: FakeBW.session)
        #expect(folders.map(\.name) == ["Work", "Personal"])
        let organizations: [VaultOrganization] = try await fake.client().listOrganizations(
            session: FakeBW.session)
        #expect(organizations.map(\.name) == ["Acme Ops"])

        // Real `bw list folders` includes "No Folder" with a null id.
        let noFolder = try JSONDecoder().decode(
            [VaultFolder].self, from: Data(#"[{"object":"folder","id":null,"name":"No Folder"}]"#.utf8))
        #expect(noFolder.first?.id == nil)
    }
}
