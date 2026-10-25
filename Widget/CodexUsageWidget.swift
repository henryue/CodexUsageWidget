import SwiftUI
import WidgetKit
import OSLog

struct CodexUsageEntry: TimelineEntry, Sendable {
    let date: Date
    let state: UsageViewState
    let isPlaceholder: Bool
}

struct CodexUsageProvider: TimelineProvider {
    private let store = AppGroupSnapshotStore()
    private static let logger = Logger(subsystem: "com.henryyue.CodexUsage", category: "widget")

    func placeholder(in context: Context) -> CodexUsageEntry {
        let now = Date.now
        return CodexUsageEntry(
            date: now,
            state: .available(.previewSevenDay(now: now)),
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageEntry) -> Void) {
        let now = Date.now
        if context.isPreview {
            completion(CodexUsageEntry(
                date: now,
                state: .available(.previewSevenDay(now: now)),
                isPlaceholder: WidgetPreviewPolicy.isPlaceholder(contextIsPreview: true)
            ))
        } else {
            completion(entry(from: store.loadResult(), at: now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageEntry>) -> Void) {
        let now = Date.now
        let capturedLoadResult = store.loadResult()
        if case .loaded(let envelope) = capturedLoadResult, let snapshot = envelope.snapshot {
            let age = max(0, now.timeIntervalSince(snapshot.fetchedAt)).rounded()
            Self.logger.info("Widget loaded shared snapshot; age in seconds: \(age)")
        } else {
            Self.logger.info("Widget has no readable shared snapshot")
        }
        let timeline = WidgetSnapshotPolicy.timeline(from: capturedLoadResult, now: now)
        let entries = timeline.entries.map {
            CodexUsageEntry(date: $0.date, state: $0.state, isPlaceholder: false)
        }
        completion(Timeline(entries: entries, policy: .after(timeline.reloadAfter)))
    }

    private func entry(
        from loadResult: SnapshotStoreLoadResult,
        at date: Date
    ) -> CodexUsageEntry {
        CodexUsageEntry(
            date: date,
            state: WidgetSnapshotPolicy.state(from: loadResult, at: date),
            isPlaceholder: false
        )
    }
}

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexUsageProvider()) { entry in
            ClarityWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "codexusage://dashboard"))
        }
        .configurationDisplayName("Codex Usage")
        .description("See remaining Codex account limits from the latest local refresh.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ClarityWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexUsageEntry

    var body: some View {
        ClarityWidgetPresentationView(
            state: entry.state,
            family: family,
            date: entry.date,
            isPlaceholder: entry.isPlaceholder
        )
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageWidget()
    }
}

#if DEBUG
/// Xcode previews only. All values and dates are synthetic.
private enum WidgetPreviewFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

    static let sevenDay = entry(
        .available(snapshot([
            window(remaining: 87, durationMinutes: 10_080, resetAfter: 5 * 86_400 + 23 * 3_600)
        ]))
    )

    static let fiveHour = entry(
        .available(snapshot([
            window(remaining: 62, durationMinutes: 300, resetAfter: 3 * 3_600 + 12 * 60)
        ]))
    )

    static let dualFiveHourTighter = entry(
        .available(snapshot([
            window(remaining: 68, durationMinutes: 10_080, resetAfter: 4 * 86_400),
            window(remaining: 25, durationMinutes: 300, resetAfter: 2 * 3_600)
        ]))
    )

    static let dualSevenDayTighter = entry(
        .available(snapshot([
            window(remaining: 32, durationMinutes: 10_080, resetAfter: 4 * 86_400),
            window(remaining: 81, durationMinutes: 300, resetAfter: 2 * 3_600)
        ]))
    )

    static let strictnessTie = entry(
        .available(snapshot([
            window(remaining: 50, durationMinutes: 10_080, resetAfter: 4 * 3_600),
            window(remaining: 50, durationMinutes: 300, resetAfter: 4 * 3_600)
        ]))
    )

    static let genericWindow = entry(
        .available(snapshot([
            window(remaining: 44, durationMinutes: 90, resetAfter: 54 * 60)
        ]))
    )

    static let missingDuration = entry(
        .available(snapshot([
            window(remaining: 56, durationMinutes: nil, resetAfter: 65 * 60)
        ]))
    )

    static let zeroRemaining = entry(
        .available(snapshot([
            window(remaining: 0, durationMinutes: 300, resetAfter: 32 * 60)
        ]))
    )

    static let singleDigitRemaining = entry(
        .available(snapshot([
            window(remaining: 9, durationMinutes: 10_080, resetAfter: 2 * 86_400)
        ]))
    )

    static let fullRemaining = entry(
        .available(snapshot([
            window(remaining: 100, durationMinutes: 300, resetAfter: 5 * 3_600)
        ]))
    )

    static let additionalWindows = entry(
        .available(snapshot([
            window(remaining: 40, durationMinutes: 300, resetAfter: 2 * 3_600),
            window(remaining: 50, durationMinutes: 10_080, resetAfter: 3 * 86_400),
            window(remaining: 20, durationMinutes: 90, resetAfter: 45 * 60),
            window(remaining: 30, durationMinutes: 120, resetAfter: 75 * 60)
        ]))
    )

    static let stale = entry(
        .stale(
            snapshot(
                [window(remaining: 45, durationMinutes: 10_080, resetAfter: 2 * 86_400)],
                fetchedAt: referenceDate.addingTimeInterval(-2 * 3_600)
            ),
            message: "The last refresh did not complete."
        )
    )

    static let staleSingleFiveHour = entry(
        .stale(
            snapshot(
                [window(remaining: 45, durationMinutes: 300, resetAfter: 2 * 3_600)],
                fetchedAt: referenceDate.addingTimeInterval(-2 * 3_600)
            ),
            message: "The last refresh did not complete."
        )
    )

    static let staleSingleGeneric = entry(
        .stale(
            snapshot(
                [window(remaining: 45, durationMinutes: 90, resetAfter: 45 * 60)],
                fetchedAt: referenceDate.addingTimeInterval(-2 * 3_600)
            ),
            message: "The last refresh did not complete."
        )
    )

    static let staleMultiple = entry(
        .stale(
            snapshot(
                [
                    window(remaining: 30, durationMinutes: 300, resetAfter: 2 * 3_600),
                    window(remaining: 50, durationMinutes: 10_080, resetAfter: 3 * 86_400),
                    window(remaining: 20, durationMinutes: 90, resetAfter: 45 * 60)
                ],
                fetchedAt: referenceDate.addingTimeInterval(-2 * 3_600)
            ),
            message: "The last refresh did not complete."
        )
    )

    static let codexNotFound = entry(
        .failed("Codex was not found. Install or update the ChatGPT app, then choose Re-detect Codex.")
    )
    static let protocolUnsupported = entry(
        .failed("This Codex version returned an unsupported usage response. Update ChatGPT, then choose Re-detect Codex.")
    )
    static let refreshFailedWithCache = entry(
        .stale(
            snapshot([
                window(remaining: 62, durationMinutes: 300, resetAfter: 3 * 3_600),
                window(remaining: 87, durationMinutes: 10_080, resetAfter: 5 * 86_400)
            ]),
            message: "Usage is temporarily unavailable. Try Refresh Now."
        )
    )
    static let refreshFailedWithoutCache = entry(
        .failed("Usage is temporarily unavailable. Try Refresh Now.")
    )

    static let resetPending = entry(
        .stale(
            snapshot([
                window(remaining: 12, durationMinutes: 300, resetAfter: -10 * 60)
            ]),
            message: "Waiting for refreshed limits."
        )
    )

    static let failed = entry(.failed("Open Codex Usage to try again."))
    static let signedOut = entry(.unauthenticated("Sign in to Codex, then refresh."))
    static let loading = entry(.loading)

    private static func entry(_ state: UsageViewState) -> CodexUsageEntry {
        CodexUsageEntry(date: referenceDate, state: state, isPlaceholder: false)
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
}

#Preview("Small · complete state matrix", as: .systemSmall) {
    CodexUsageWidget()
} timeline: {
    WidgetPreviewFixtures.sevenDay
    WidgetPreviewFixtures.fiveHour
    WidgetPreviewFixtures.dualFiveHourTighter
    WidgetPreviewFixtures.dualSevenDayTighter
    WidgetPreviewFixtures.strictnessTie
    WidgetPreviewFixtures.genericWindow
    WidgetPreviewFixtures.missingDuration
    WidgetPreviewFixtures.zeroRemaining
    WidgetPreviewFixtures.singleDigitRemaining
    WidgetPreviewFixtures.fullRemaining
    WidgetPreviewFixtures.additionalWindows
    WidgetPreviewFixtures.stale
    WidgetPreviewFixtures.staleSingleFiveHour
    WidgetPreviewFixtures.staleSingleGeneric
    WidgetPreviewFixtures.staleMultiple
    WidgetPreviewFixtures.codexNotFound
    WidgetPreviewFixtures.protocolUnsupported
    WidgetPreviewFixtures.refreshFailedWithCache
    WidgetPreviewFixtures.refreshFailedWithoutCache
    WidgetPreviewFixtures.resetPending
    WidgetPreviewFixtures.failed
    WidgetPreviewFixtures.signedOut
    WidgetPreviewFixtures.loading
}

#Preview("Medium · complete state matrix", as: .systemMedium) {
    CodexUsageWidget()
} timeline: {
    WidgetPreviewFixtures.sevenDay
    WidgetPreviewFixtures.fiveHour
    WidgetPreviewFixtures.dualFiveHourTighter
    WidgetPreviewFixtures.dualSevenDayTighter
    WidgetPreviewFixtures.strictnessTie
    WidgetPreviewFixtures.genericWindow
    WidgetPreviewFixtures.missingDuration
    WidgetPreviewFixtures.zeroRemaining
    WidgetPreviewFixtures.singleDigitRemaining
    WidgetPreviewFixtures.fullRemaining
    WidgetPreviewFixtures.additionalWindows
    WidgetPreviewFixtures.stale
    WidgetPreviewFixtures.staleSingleFiveHour
    WidgetPreviewFixtures.staleSingleGeneric
    WidgetPreviewFixtures.staleMultiple
    WidgetPreviewFixtures.codexNotFound
    WidgetPreviewFixtures.protocolUnsupported
    WidgetPreviewFixtures.refreshFailedWithCache
    WidgetPreviewFixtures.refreshFailedWithoutCache
    WidgetPreviewFixtures.resetPending
    WidgetPreviewFixtures.failed
    WidgetPreviewFixtures.signedOut
    WidgetPreviewFixtures.loading
}
#endif
