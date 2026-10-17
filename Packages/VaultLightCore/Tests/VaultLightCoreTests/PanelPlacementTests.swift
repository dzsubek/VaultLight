import CoreGraphics
import Testing

@testable import VaultLightCore

@Suite("PanelPlacement")
struct PanelPlacementTests {
    static let panel = CGSize(width: 680, height: 400)
    static let main = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    static let side = CGRect(x: 1600, y: 100, width: 1200, height: 900)

    @Test func panelAppearsOnTheScreenWithTheMouse() {
        let screens = [Self.main, Self.side]
        let onSide = PanelPlacement.frame(panelSize: Self.panel, screens: screens, mouse: CGPoint(x: 2000, y: 500))
        #expect(Self.side.contains(onSide))
        let onMain = PanelPlacement.frame(panelSize: Self.panel, screens: screens, mouse: CGPoint(x: 100, y: 500))
        #expect(Self.main.contains(onMain))
    }

    @Test func panelIsCenteredHorizontally() {
        let frame = PanelPlacement.frame(panelSize: Self.panel, screens: [Self.main], mouse: CGPoint(x: 10, y: 10))
        #expect(frame.midX == Self.main.midX)
        #expect(frame.size == Self.panel)
    }

    @Test func panelTopEdgeStaysFixedInTheUpperThird() {
        let frame = PanelPlacement.frame(panelSize: Self.panel, screens: [Self.main], mouse: CGPoint(x: 10, y: 10))
        // AppKit coordinates: y grows upwards, so the top edge sits a sixth of the screen below the top.
        #expect(frame.maxY == (1000 - 1000.0 / 6).rounded())
    }

    @Test func differentPanelHeightsShareTheSameTopEdge() {
        let short = PanelPlacement.frame(
            panelSize: CGSize(width: 680, height: 120), screens: [Self.main], mouse: .zero)
        let tall = PanelPlacement.frame(
            panelSize: CGSize(width: 680, height: 520), screens: [Self.main], mouse: .zero)
        #expect(short.maxY == tall.maxY)
        #expect(short.minY > tall.minY)
    }

    @Test func placementUsesTheScreensOwnOrigin() {
        let frame = PanelPlacement.frame(
            panelSize: Self.panel, screens: [Self.main, Self.side], mouse: CGPoint(x: 2000, y: 500))
        #expect(frame.midX == Self.side.midX)
        #expect(frame.maxY == (1000 - 900.0 / 6).rounded())
    }

    @Test func panelIsClampedInsideASmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 500, height: 450)
        let frame = PanelPlacement.frame(panelSize: Self.panel, screens: [small], mouse: CGPoint(x: 10, y: 10))
        #expect(frame.minX >= small.minX)
        #expect(frame.maxY <= small.maxY)
        #expect(frame.minY >= small.minY)
    }

    @Test func panelNearTheTopOfAShortScreenStaysInside() {
        let short = CGRect(x: 0, y: 0, width: 1400, height: 420)
        let frame = PanelPlacement.frame(panelSize: Self.panel, screens: [short], mouse: CGPoint(x: 10, y: 10))
        #expect(short.contains(frame))
    }

    @Test func mouseOutsideEveryScreenFallsBackToTheFirst() {
        let frame = PanelPlacement.frame(
            panelSize: Self.panel, screens: [Self.main, Self.side], mouse: CGPoint(x: -5000, y: -5000))
        #expect(Self.main.contains(frame))
    }

    @Test func noScreensReturnsAnOriginRect() {
        let frame = PanelPlacement.frame(panelSize: Self.panel, screens: [], mouse: .zero)
        #expect(frame == CGRect(origin: .zero, size: Self.panel))
    }

    @Test func frameIsRoundedToWholePoints() {
        let odd = CGRect(x: 0, y: 0, width: 1441, height: 901)
        let frame = PanelPlacement.frame(panelSize: CGSize(width: 681, height: 401), screens: [odd], mouse: .zero)
        #expect(frame.origin.x == frame.origin.x.rounded())
        #expect(frame.origin.y == frame.origin.y.rounded())
    }
}
