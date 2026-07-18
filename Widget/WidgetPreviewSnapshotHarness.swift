#if DEBUG && WIDGET_SNAPSHOT_HARNESS
import AppKit
import Foundation
import SwiftUI
import WidgetKit

/// Deterministic, account-free layout evidence for the Clarity widget.
///
/// Build this file with the shared view/model sources and pass one output
/// directory argument. It renders standard macOS small and medium canvas sizes
/// without reading App Group data or starting Codex. Every rendered value is synthetic.
@main
@MainActor
struct WidgetPreviewSnapshotHarness {
    private struct Fixture {
        let name: String
        let state: UsageViewState
    }

    private struct Surface {
        let name: String
        let colorScheme: ColorScheme
        let renderingMode: WidgetRenderingMode
    }

    private static let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw HarnessError.missingOutputDirectory
        }

        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let families: [(name: String, family: WidgetFamily, size: CGSize)] = [
            ("small", .systemSmall, CGSize(width: 158, height: 158)),
            ("medium", .systemMedium, CGSize(width: 338, height: 158))
        ]
        let surfaces = [
            Surface(
                name: "full-light",
                colorScheme: .light,
                renderingMode: .fullColor
            ),
            Surface(
                name: "full-dark",
                colorScheme: .dark,
                renderingMode: .fullColor
            ),
            Surface(
                name: "accented",
                colorScheme: .light,
                renderingMode: .accented
            ),
            Surface(
                name: "vibrant",
                colorScheme: .dark,
                renderingMode: .vibrant
            )
        ]

        let requestedFixture = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil
        for fixture in fixtures where requestedFixture == nil || requestedFixture == fixture.name {
            for family in families {
                for surface in surfaces {
                    let filename = "\(family.name)-\(surface.name)-\(fixture.name).png"
                    try render(
                        state: fixture.state,
                        family: family.family,
                        size: family.size,
                        surface: surface,
                        to: outputDirectory.appendingPathComponent(filename)
                    )
                }
            }
        }
    }

    private static func render(
        state: UsageViewState,
        family: WidgetFamily,
        size: CGSize,
        surface: Surface,
        to destination: URL
    ) throws {
        let background = surface.colorScheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.12)
            : Color.white
        let root = ClarityWidgetView(state: state, family: family, date: referenceDate)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(background)
            .environment(\.colorScheme, surface.colorScheme)
            .environment(\.widgetRenderingMode, surface.renderingMode)

        // Render once through a fully attached host before capturing. Repeated
        // batch renders can otherwise expose an incomplete first SwiftUI frame.
        let (_, warmupWindow) = settledHost(for: root, size: size)
        warmupWindow.orderOut(nil)
        warmupWindow.close()

        let (host, window) = settledHost(for: root, size: size)

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            window.orderOut(nil)
            window.close()
            throw HarnessError.couldNotCreateBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        window.close()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError.couldNotEncodePNG
        }
        try png.write(to: destination, options: .atomic)
    }

    private static func settledHost<Content: View>(
        for root: Content,
        size: CGSize
    ) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        host.displayIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        host.displayIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return (host, window)
    }

    private static var fixtures: [Fixture] {
        [
            Fixture(name: "seven-day", state: .available(snapshot([
                window(remaining: 87, durationMinutes: 10_080, resetAfter: 5 * 86_400 + 23 * 3_600)
            ]))),
            Fixture(name: "five-hour", state: .available(snapshot([
                window(remaining: 62, durationMinutes: 300, resetAfter: 3 * 3_600 + 12 * 60)
            ]))),
            Fixture(name: "dual-five-tighter", state: .available(snapshot([
                window(remaining: 68, durationMinutes: 10_080, resetAfter: 4 * 86_400),
                window(remaining: 25, durationMinutes: 300, resetAfter: 2 * 3_600)
            ]))),
            Fixture(name: "dual-seven-tighter", state: .available(snapshot([
                window(remaining: 32, durationMinutes: 10_080, resetAfter: 4 * 86_400),
                window(remaining: 81, durationMinutes: 300, resetAfter: 2 * 3_600)
            ]))),
            Fixture(name: "strictness-tie", state: .available(snapshot([
                window(remaining: 50, durationMinutes: 10_080, resetAfter: 4 * 3_600),
                window(remaining: 50, durationMinutes: 300, resetAfter: 4 * 3_600)
            ]))),
            Fixture(name: "generic-90-minute", state: .available(snapshot([
                window(remaining: 44, durationMinutes: 90, resetAfter: 54 * 60)
            ]))),
            Fixture(name: "generic-missing-duration", state: .available(snapshot([
                window(remaining: 56, durationMinutes: nil, resetAfter: 65 * 60)
            ]))),
            Fixture(name: "zero-remaining", state: .available(snapshot([
                window(remaining: 0, durationMinutes: 300, resetAfter: 32 * 60)
            ]))),
            Fixture(name: "single-digit", state: .available(snapshot([
                window(remaining: 9, durationMinutes: 10_080, resetAfter: 2 * 86_400)
            ]))),
            Fixture(name: "full-remaining", state: .available(snapshot([
                window(remaining: 100, durationMinutes: 300, resetAfter: 5 * 3_600)
            ]))),
            Fixture(name: "additional-limits", state: .available(snapshot([
                window(remaining: 40, durationMinutes: 300, resetAfter: 2 * 3_600),
                window(remaining: 50, durationMinutes: 10_080, resetAfter: 3 * 86_400),
                window(remaining: 20, durationMinutes: 90, resetAfter: 45 * 60),
                window(remaining: 30, durationMinutes: 120, resetAfter: 75 * 60)
            ]))),
            Fixture(
                name: "out-of-date",
                state: .stale(
                    snapshot(
                        [window(remaining: 45, durationMinutes: 10_080, resetAfter: 2 * 86_400)],
                        fetchedAt: referenceDate.addingTimeInterval(-2 * 3_600)
                    ),
                    message: "The last refresh did not complete."
                )
            ),
            Fixture(
                name: "reset-pending",
                state: .stale(
                    snapshot([window(remaining: 12, durationMinutes: 300, resetAfter: -10 * 60)]),
                    message: "Waiting for refreshed limits."
                )
            ),
            Fixture(name: "error", state: .failed("Open Codex Usage to try again.")),
            Fixture(name: "signed-out", state: .unauthenticated("Sign in to Codex, then refresh.")),
            Fixture(name: "loading", state: .loading)
        ]
    }

    private static func snapshot(
        _ windows: [UsageWindow],
        fetchedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: fetchedAt ?? referenceDate.addingTimeInterval(-3 * 60), windows: windows)
    }

    private static func window(
        remaining: Int,
        durationMinutes: Int?,
        resetAfter: TimeInterval
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: Double(100 - remaining),
            durationMinutes: durationMinutes,
            resetsAt: referenceDate.addingTimeInterval(resetAfter)
        )
    }

    private enum HarnessError: Error {
        case missingOutputDirectory
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}
#endif
