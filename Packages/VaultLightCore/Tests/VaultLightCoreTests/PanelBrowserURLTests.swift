import Foundation
import Testing

@testable import VaultLightCore

@MainActor
@Suite("PanelViewModel.browserURL")
struct PanelBrowserURLTests {
    @Test func browserURLAcceptsHTTPAndHTTPS() {
        #expect(
            PanelViewModel.browserURL(from: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(PanelViewModel.browserURL(from: "http://example.com")?.absoluteString == "http://example.com")
        #expect(PanelViewModel.browserURL(from: "HTTPS://Example.com")?.host?.lowercased() == "example.com")
    }

    @Test func browserURLAddsHTTPSToSchemelessURIs() {
        #expect(PanelViewModel.browserURL(from: "example.com")?.absoluteString == "https://example.com")
        #expect(PanelViewModel.browserURL(from: "example.com/login")?.absoluteString == "https://example.com/login")
        #expect(PanelViewModel.browserURL(from: "localhost:8080/x")?.absoluteString == "https://localhost:8080/x")
    }

    @Test func browserURLRejectsOtherSchemesAndEmptyInput() {
        #expect(PanelViewModel.browserURL(from: "javascript:alert(1)") == nil)
        #expect(PanelViewModel.browserURL(from: "file:///etc/passwd") == nil)
        #expect(PanelViewModel.browserURL(from: "ftp://example.com") == nil)
        #expect(PanelViewModel.browserURL(from: "mailto:a@example.com") == nil)
        #expect(PanelViewModel.browserURL(from: "") == nil)
        #expect(PanelViewModel.browserURL(from: "   ") == nil)
        #expect(PanelViewModel.browserURL(from: "https://") == nil)
    }
}
