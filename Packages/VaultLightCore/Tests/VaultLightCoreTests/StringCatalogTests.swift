import Foundation
import Testing

@testable import VaultLightCore

/// Spec 10 "Strings are kept in a String Catalog": the copy Core shows comes from its catalog, and `make
/// check-strings` keeps both catalogs in step with the code.
@Suite("String Catalog")
struct StringCatalogTests {
    static let catalogURL = FakeBW.repositoryRoot.appending(
        path: "Packages/VaultLightCore/Sources/VaultLightCore/Resources/Localizable.xcstrings")

    static func catalogKeys() throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    @Test func fixedCopyIsInTheCatalog() throws {
        let keys = try Self.catalogKeys()
        let footers: [PanelFooter] = [
            .usernameCopied, .passwordCopied, .codeCopied, .noPassword, .noTOTP, .noUsername, .noURL, .copyFailed,
            .clipboardWriteFailed, .timedOut, .locked,
        ]
        let failures: [OnboardingModel.Failure] = [
            .invalidServerURL, .serverUnreachable, .wrongCredentials, .wrongAPIKey, .wrongCode, .wrongEmailCode,
            .wrongMasterPassword, .twoFactorExpired, .offline, .timedOut, .failed,
        ]
        let copy =
            footers.compactMap(\.message) + failures.map(\.message)
            + [SetupProblem.notInstalled, .unsafeBinary].flatMap { [$0.title, $0.message] }
            + [PanelFailure.timedOut, .offline, .unknown].map(\.message)
            + [SyncStatus(failure: .offline), SyncStatus(activity: .syncing)].compactMap {
                $0.footerLine(now: .now)?.text
            }
            + [SyncActivity.loadingDetails, .refreshing].map(\.message)
            + [PanelFooter.gettingPassword, .gettingCode].compactMap(\.message)
        for text in copy {
            #expect(keys.contains(text), "\(text)")
        }
    }

    /// English plural forms come from the catalog's variations, not from code.
    @Test func pluralsComeFromTheCatalog() {
        #expect(RelativeTime.duration(86_400) == "1 day")
        #expect(RelativeTime.duration(2 * 86_400) == "2 days")
        #expect(RelativeTime.duration(3_600) == "1 hour")
        #expect(RelativeTime.duration(3 * 3_600) == "3 hours")
        #expect(RelativeTime.duration(30) == "1 minute")
        #expect(RelativeTime.duration(5 * 60) == "5 minutes")
    }
}
