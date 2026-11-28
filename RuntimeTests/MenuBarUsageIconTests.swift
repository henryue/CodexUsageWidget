import AppKit
import XCTest
#if SWIFT_PACKAGE
import CodexUsageCore
@testable import CodexUsageRuntime
#endif

@MainActor
final class MenuBarUsageIconTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testDescriptionFollowsTheLimitingWindowWhenUsageChanges() {
        let weekly = UsageWindow(usedPercent: 64, durationMinutes: 10_080, resetsAt: nil)
        let hourly = UsageWindow(usedPercent: 12, durationMinutes: 300, resetsAt: nil)
        let nearlySpent = UsageWindow(usedPercent: 98, durationMinutes: 300, resetsAt: nil)

        let first = UsageSnapshot(fetchedAt: fetchedAt, windows: [hourly, weekly])
        let next = UsageSnapshot(fetchedAt: fetchedAt, windows: [nearlySpent, weekly])
        XCTAssertEqual(MenuBarUsageIcon(state: .available(first), at: fetchedAt).description, "Codex Usage, 7-day limit, 36% remaining")
        XCTAssertEqual(MenuBarUsageIcon(state: .available(next), at: fetchedAt).description, "Codex Usage, 5-hour limit, 2% remaining")
    }

    func testLastSuccessfulSampleBecomesOutOfDateOnlyAfterFiveMinutes() {
        let snapshot = UsageSnapshot(fetchedAt: fetchedAt, windows: [
            UsageWindow(usedPercent: 83, durationMinutes: 10_080, resetsAt: nil)
        ])
        let boundary = fetchedAt.addingTimeInterval(300)
        let expired = fetchedAt.addingTimeInterval(300.1)
        let states: [(UsageViewState, String)] = [
            (.available(snapshot), "Codex Usage, 7-day limit, 17% remaining"),
            (.stale(snapshot, message: nil), "Codex Usage, refresh delayed"),
            (.stale(snapshot, message: "Connection failed"), "Codex Usage, refresh delayed"),
            (.stale(snapshot, message: "Automatic updates are paused."), "Codex Usage, updates paused")
        ]
        for (state, freshPrefix) in states {
            let atBoundary = MenuBarUsageIcon(state: state, at: boundary).description
            XCTAssertTrue(atBoundary.hasPrefix(freshPrefix), atBoundary)
            XCTAssertEqual(MenuBarUsageIcon(state: state, at: expired).description,
                           "Codex Usage, out of date, last reading: 7-day limit, 17% remaining")
        }
    }

    func testEmptySnapshotAndOtherStatusesAreDistinctFromZeroRemaining() {
        let empty = UsageSnapshot(fetchedAt: fetchedAt, windows: [])
        let zero = UsageSnapshot(fetchedAt: fetchedAt, windows: [
            UsageWindow(usedPercent: 100, durationMinutes: 300, resetsAt: nil)
        ])

        let cases: [(UsageViewState, String)] = [
            (.available(zero), "Codex Usage, 5-hour limit, 0% remaining"),
            (.available(empty), "Codex Usage, usage unavailable"),
            (.loading, "Codex Usage, waiting for usage"),
            (.unauthenticated("Sign in"), "Codex Usage, sign in required"),
            (.failed("Connection failed"), "Codex Usage, usage unavailable")
        ]
        for (state, expected) in cases {
            XCTAssertEqual(MenuBarUsageIcon(state: state, at: fetchedAt).description, expected)
        }
        let expired = fetchedAt.addingTimeInterval(301)
        for state in [UsageViewState.available(empty), .stale(empty, message: nil)] {
            XCTAssertEqual(MenuBarUsageIcon(state: state, at: expired).description, "Codex Usage, out of date")
        }
    }

    func testOutOfDateClockColorsOnlyItsLowerRightExclamationMark() throws {
        let appearances: [(NSAppearance.Name, Bool)] = [(.aqua, false), (.darkAqua, true)]
        for (name, expectsLightClock) in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let image = MenuBarUsageIcon.outOfDateImage()
                XCTAssertEqual(image?.isTemplate, false)
                data = image?.tiffRepresentation
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(data)))
            var hasRedMark = false
            var hasVisibleClock = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    guard pixel.alphaComponent > 0.35 else { continue }
                    let column = (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide)
                    let row = (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh)
                    if pixel.saturationComponent > 0.35, pixel.brightnessComponent > 0.35 {
                        XCTAssertTrue(pixel.hueComponent < 0.05 || pixel.hueComponent > 0.94)
                        XCTAssertTrue((0.60...0.84).contains(column) && (0.50...0.93).contains(row),
                                      "Unexpected colored pixel outside the punctuation in \(name)")
                        hasRedMark = true
                    } else if column < 0.55, row < 0.55, pixel.saturationComponent < 0.1,
                              (pixel.brightnessComponent > 0.5) == expectsLightClock {
                        hasVisibleClock = true
                    }
                }
            }
            XCTAssertTrue(hasRedMark, "Missing red punctuation in \(name)")
            XCTAssertTrue(hasVisibleClock, "Missing contrasting clock face in \(name)")
        }
    }

    func testColorBandsAtTheirExactEndpoints() throws {
        let bands: [([Int], NSColor)] = [
            ([1, 10], .systemRed), ([11, 25], .systemOrange),
            ([26, 50], .systemYellow), ([51, 100], .systemGreen)
        ]
        for (endpoints, expectedColor) in bands {
            let expected = try XCTUnwrap(expectedColor.usingColorSpace(.sRGB))
            for percent in endpoints {
                let image = MenuBarUsageIcon.gauge(remainingPercent: percent)
                XCTAssertFalse(image.isTemplate, "macOS would discard the color at \(percent)%")
                let bitmap = try raster(image)
                var hasColoredRim = false
                var hasColoredFace = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        // Seek pixels that retain the system color. Antialiased rim pixels
                        // may be blended with the darker outline underneath.
                        guard pixel.alphaComponent > 0.15, pixel.saturationComponent > 0.4 else { continue }
                        let hueDistance = abs(pixel.hueComponent - expected.hueComponent)
                        guard min(hueDistance, 1 - hueDistance) < 0.018 else { continue }
                        let radius = relativeRadius(x: x, y: y, in: bitmap)
                        if radius <= 0.28 { hasColoredFace = true }
                        if radius >= 0.35 { hasColoredRim = true }
                    }
                }
                XCTAssertTrue(hasColoredFace, "Expected colored fill at \(percent)%")
                XCTAssertTrue(hasColoredRim, "Expected a colored outline at \(percent)%")
            }
        }
    }

    func testZeroHasAnOutlineAndTransparentFaceAndPositiveFillGrows() throws {
        let zero = MenuBarUsageIcon.gauge(remainingPercent: 0)
        XCTAssertTrue(zero.isTemplate)
        let empty = try raster(zero)
        var outlineVisible = false
        for y in 0..<empty.pixelsHigh {
            for x in 0..<empty.pixelsWide {
                let pixel = try XCTUnwrap(empty.colorAt(x: x, y: y))
                if pixel.alphaComponent > 0.7 { outlineVisible = true }
            }
        }
        XCTAssertTrue(outlineVisible)

        let percents = [0, 1, 25, 50, 75, 100]
        let amounts = try percents.map { percent in
            let bitmap = try raster(MenuBarUsageIcon.gauge(remainingPercent: percent))
            var alpha: CGFloat = 0
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    // Check the circular face only. The persistent rim must not count as fill.
                    guard relativeRadius(x: x, y: y, in: bitmap) <= 0.28 else { continue }
                    alpha += try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                    count += 1
                }
            }
            return alpha / CGFloat(count)
        }
        XCTAssertEqual(amounts[0], 0)
        XCTAssertGreaterThan(amounts[1], 0.01, "1% should have a discernible mark.")
        for (lower, higher) in zip(amounts, amounts.dropFirst()) {
            XCTAssertGreaterThan(higher, lower)
        }
    }

    func testQuarterGaugeFillsTheUpperLeftQuadrant() throws {
        let quarter = MenuBarUsageIcon.gauge(remainingPercent: 25)
        let bitmap = try raster(quarter)
        // Bitmap row zero is the top of the raster. Sample inside the face, clear of the rim.
        let left = bitmap.pixelsWide * 3 / 8
        let right = bitmap.pixelsWide * 5 / 8
        let top = bitmap.pixelsHigh * 3 / 8
        let bottom = bitmap.pixelsHigh * 5 / 8
        for (x, y, expectedAlpha) in [(left, top, 1.0), (right, top, 0), (left, bottom, 0), (right, bottom, 0)] {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            XCTAssertEqual(pixel.alphaComponent, CGFloat(expectedAlpha), accuracy: 0.05)
        }
    }

    private func raster(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func relativeRadius(x: Int, y: Int, in bitmap: NSBitmapImageRep) -> CGFloat {
        let dx = (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide) - 0.5
        let dy = (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh) - 0.5
        return hypot(dx, dy)
    }
}
