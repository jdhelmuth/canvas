import XCTest
import SwiftUI

@testable import Canvas

final class OverlayLayoutTests: XCTestCase {
    func testLegacySettingsDecodeWithoutLayoutsAndRoundTripPreservesOtherFields() throws {
        var settings = CanvasSettings()
        settings.photoDuration = 37
        let data = try JSONEncoder().encode(settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var overlays = try XCTUnwrap(json["overlays"] as? [String: Any])
        overlays.removeValue(forKey: "layouts"); json["overlays"] = overlays
        var restored = try JSONDecoder().decode(CanvasSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.overlays.layouts)
        var layouts = OverlayLayouts()
        var portrait = OverlayOrientationLayout()
        portrait[.clock] = OverlayPlacement(x: 0.9, y: 0.3, alignment: .right)
        layouts.set(portrait, portrait: true)
        restored.overlays.layouts = layouts
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(decoded, restored)
        XCTAssertEqual(decoded.photoDuration, 37)
        XCTAssertNil(decoded.overlays.layouts?.landscape)
    }
    func testPortraitDefaultsStaySideBySideAndBottomAlignedAtNarrowWidths() {
        for width in [320.0, 600, 834, 1032] {
            let bounds = OverlayLayoutGeometry.bounds(size: CGSize(width: width, height: 1366), insets: EdgeInsets())
            let ratio = (bounds.width - 15) / 650
            let clock = CGSize(width: 300 * min(1, ratio), height: 140 * min(1, ratio))
            let weather = CGSize(width: 350 * min(1, ratio), height: 500 * min(1, ratio))
            let a = OverlayLayoutGeometry.defaults(block: .clock, size: clock, clock: clock, weather: weather, bounds: bounds, portrait: true, position: .topTrailing)
            let b = OverlayLayoutGeometry.defaults(block: .weather, size: weather, clock: clock, weather: weather, bounds: bounds, portrait: true, position: .topTrailing)
            let af = OverlayLayoutGeometry.frame(size: clock, placement: a, bounds: bounds)
            let bf = OverlayLayoutGeometry.frame(size: weather, placement: b, bounds: bounds)
            XCTAssertEqual(af.minX, bounds.minX, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(bf.minX, af.maxX + 14)
            XCTAssertEqual(af.maxY, bf.maxY, accuracy: 0.01)
            XCTAssertLessThanOrEqual(bf.maxX, bounds.maxX + 0.01)
        }
    }
    func testClampsEdgesAndPreservesNormalizedPositionAcrossResizeAndContentChanges() {
        for canvas in [CGSize(width: 320, height: 700), CGSize(width: 1366, height: 1024)] {
            let bounds = OverlayLayoutGeometry.bounds(size: canvas, insets: EdgeInsets(top: 24, leading: 30, bottom: 34, trailing: 30))
            for content in [CGSize(width: 5000, height: 8000), CGSize(width: 150, height: 80)] {
                let size = OverlayLayoutGeometry.fittedSize(content, in: bounds)
                let p = OverlayLayoutGeometry.placement(origin: CGPoint(x: -100, y: 9000), size: size, bounds: bounds, snapping: false, alignment: .right)
                let rect = OverlayLayoutGeometry.frame(size: size, placement: p, bounds: bounds)
                XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX)
                XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.01)
                XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.01)
                XCTAssertEqual(p.alignment, .right)
            }
        }
        XCTAssertEqual(OverlayLayoutGeometry.unit(.nan), 0)
        XCTAssertEqual(OverlayLayoutGeometry.unit(.infinity), 0)
    }
    func testOptionalSnappingAndAlignmentOverrides() {
        let bounds = CGRect(x: 24, y: 80, width: 1000, height: 1000)
        let size = CGSize(width: 200, height: 100)
        let origin = CGPoint(x: 30, y: 535)
        let snapped = OverlayLayoutGeometry.placement(origin: origin, size: size, bounds: bounds, snapping: true, alignment: .automatic)
        let free = OverlayLayoutGeometry.placement(origin: origin, size: size, bounds: bounds, snapping: false, alignment: .automatic)
        XCTAssertEqual(snapped.x, 0); XCTAssertEqual(snapped.y, 0.5)
        XCTAssertGreaterThan(free.x, 0); XCTAssertGreaterThan(free.y, 0.5)
        XCTAssertTrue(OverlayTextAlignment.automatic.isTrailing(at: 0.9))
        XCTAssertFalse(OverlayTextAlignment.automatic.isTrailing(at: 0.1))
        XCTAssertFalse(OverlayTextAlignment.left.isTrailing(at: 0.9))
        XCTAssertTrue(OverlayTextAlignment.right.isTrailing(at: 0.1))
    }
    func testDraftCancelAndOrientationResetPreserveSavedLayout() throws {
        var saved = OverlayLayouts()
        var layout = OverlayOrientationLayout()
        layout[.weather] = OverlayPlacement(x: 1, y: 0)
        saved.set(layout, portrait: true)
        saved.set(layout, portrait: false)
        var draft = saved
        draft.set(nil, portrait: true)
        XCTAssertNotNil(saved.portrait)
        XCTAssertNil(draft.portrait)
        XCTAssertEqual(draft.landscape, saved.landscape)
        XCTAssertEqual(try JSONDecoder().decode(OverlayLayouts.self, from: JSONEncoder().encode(saved)), saved)
    }
}
