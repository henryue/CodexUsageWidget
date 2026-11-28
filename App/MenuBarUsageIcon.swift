import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import CodexUsageCore
#endif

struct MenuBarUsageIcon: View {
    private let image: Image
    let description: String

    init(state: UsageViewState, at date: Date = .now) {
        switch state {
        case .available(let snapshot), .stale(let snapshot, _):
            let window = snapshot.limitingWindow
            let lastReading = window.map { ", last reading: \($0.detailLabel) limit, \($0.roundedRemainingPercent)% remaining" } ?? ""
            if WidgetFreshnessPolicy.isOutOfDate(snapshot: snapshot, at: date) {
                image = Self.outOfDateImage().map { Image(nsImage: $0).renderingMode(.original) }
                    ?? Image(systemName: "clock")
                description = "Codex Usage, out of date" + lastReading
            } else if case .stale(_, let message) = state {
                let status: (symbol: String, text: String) = switch WidgetStaleRecoveryKind(message: message) {
                case .resume: ("pause.circle", "updates paused")
                case .signIn: ("person.crop.circle.badge.exclamationmark", "sign in required")
                case .storage: ("exclamationmark.triangle", "shared storage unavailable")
                case .refresh: ("exclamationmark.circle", "refresh delayed")
                }
                image = Image(systemName: status.symbol)
                description = "Codex Usage, " + status.text + lastReading
            } else if let window {
                let percent = window.roundedRemainingPercent
                image = Image(nsImage: Self.gauge(remainingPercent: percent))
                    .renderingMode(percent == 0 ? .template : .original)
                description = "Codex Usage, \(window.detailLabel) limit, \(percent)% remaining"
            } else {
                image = Image(systemName: "exclamationmark.triangle")
                description = "Codex Usage, usage unavailable"
            }
        case .loading:
            image = Image(systemName: "arrow.triangle.2.circlepath")
            description = "Codex Usage, waiting for usage"
        case .unauthenticated:
            image = Image(systemName: "exclamationmark.triangle")
            description = "Codex Usage, sign in required"
        case .failed:
            image = Image(systemName: "exclamationmark.triangle")
            description = "Codex Usage, usage unavailable"
        }
    }

    var body: some View {
        image
            .accessibilityLabel(Text(verbatim: description))
            .help(Text(verbatim: description))
    }

    static func outOfDateImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(.init(paletteColors: [.labelColor, .labelColor]))
        guard let clock = NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let image = NSImage(size: clock.size, flipped: false) { bounds in
            // The native symbol cuts the "!" out of the badge. Place red behind
            // that cutout, inside the disk, so the clock and badge keep their system color.
            let ink = NSRect(x: bounds.width * 0.6625, y: bounds.height * 0.15,
                             width: bounds.width * 0.115, height: bounds.height * 0.30)
            NSColor.systemRed.setFill()
            NSBezierPath(rect: ink).fill()
            clock.draw(in: bounds)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func gauge(remainingPercent: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.75, dy: 1.75))
            if remainingPercent > 0 {
                // Keep bright colors legible against light menu bars and wallpaper.
                NSColor(white: 0, alpha: 0.6).setStroke()
                rim.lineWidth = 2.75
                rim.stroke()
            }
            let color: NSColor = switch remainingPercent {
            case 0: .black
            case 1...10: .systemRed
            case 11...25: .systemOrange
            case 26...50: .systemYellow
            default: .systemGreen
            }
            color.set()
            rim.lineWidth = 1.5
            rim.stroke()

            let face = bounds.insetBy(dx: 3.5, dy: 3.5)
            if remainingPercent == 100 {
                NSBezierPath(ovalIn: face).fill()
            } else if remainingPercent > 0 {
                let slice = NSBezierPath()
                slice.move(to: center)
                // At menu-bar size a true 1% wedge is subpixel. Keep it visible until zero.
                let sweep = max(15, 3.6 * CGFloat(remainingPercent))
                slice.appendArc(withCenter: center, radius: face.width / 2,
                                startAngle: 90, endAngle: 90 + sweep,
                                clockwise: false)
                slice.close()
                slice.fill()
            }
            return true
        }
        image.isTemplate = remainingPercent == 0
        return image
    }
}
