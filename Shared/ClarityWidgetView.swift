import Foundation
import SwiftUI
import WidgetKit

/// The production presentation boundary used by both WidgetKit and the
/// account-free visual/accessibility evidence harness. Keeping placeholder
/// treatment here prevents gallery samples from being announced as real
/// account usage while ensuring the harness exercises the exact same view.
public struct ClarityWidgetPresentationView: View {
    public let state: UsageViewState
    public let family: WidgetFamily
    public let date: Date
    public let isPlaceholder: Bool

    public init(
        state: UsageViewState,
        family: WidgetFamily,
        date: Date,
        isPlaceholder: Bool
    ) {
        self.state = state
        self.family = family
        self.date = date
        self.isPlaceholder = isPlaceholder
    }

    @ViewBuilder
    public var body: some View {
        if isPlaceholder {
            ClarityWidgetView(state: state, family: family, date: date)
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Example usage placeholder")
                .accessibilityHint("Open Codex Usage to load account limits")
        } else {
            ClarityWidgetView(state: state, family: family, date: date)
        }
    }
}

public struct ClarityWidgetView: View {
    public let state: UsageViewState
    public let family: WidgetFamily
    public let date: Date

    public init(state: UsageViewState, family: WidgetFamily, date: Date) {
        self.state = state
        self.family = family
        self.date = date
    }

    public var body: some View {
        Group {
            switch state {
            case .loading:
                StatusWidgetView(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Loading usage",
                    detail: "Open Codex Usage to refresh."
                )
            case .unauthenticated(let message):
                StatusWidgetView(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    title: "Sign in required",
                    detail: message
                )
            case .failed(let message):
                StatusWidgetView(
                    symbol: "exclamationmark.triangle",
                    title: "Usage unavailable",
                    detail: message
                )
            case .available(let snapshot):
                usageView(snapshot: snapshot, stale: false, staleMessage: nil)
            case .stale(let snapshot, let message):
                usageView(snapshot: snapshot, stale: true, staleMessage: message)
            }
        }
    }

    @ViewBuilder
    private func usageView(
        snapshot: UsageSnapshot,
        stale: Bool,
        staleMessage: String?
    ) -> some View {
        let recoveryAction = stale ? StaleRecoveryAction(message: staleMessage) : nil
        if family == .systemMedium {
            ClarityMediumView(
                snapshot: snapshot,
                date: date,
                stale: stale,
                recoveryAction: recoveryAction
            )
        } else {
            ClaritySmallView(
                snapshot: snapshot,
                date: date,
                stale: stale,
                recoveryAction: recoveryAction
            )
        }
    }
}

private enum StaleRecoveryAction {
    case resume
    case refresh

    init(message: String?) {
        switch WidgetStaleRecoveryKind(message: message) {
        case .resume: self = .resume
        case .refresh: self = .refresh
        }
    }

    var fullVisibleLabel: LocalizedStringKey {
        switch self {
        case .resume: "Out of date · Open app to resume"
        case .refresh: "Out of date · Open app to refresh"
        }
    }

    var actionVisibleLabel: LocalizedStringKey {
        switch self {
        case .resume: "Open app to resume"
        case .refresh: "Open app to refresh"
        }
    }

    var accessibilityInstruction: String {
        switch self {
        case .resume: "Open the app to resume updates."
        case .refresh: "Open the app to refresh usage."
        }
    }
}

private struct ClaritySmallView: View {
    let snapshot: UsageSnapshot
    let date: Date
    let stale: Bool
    let recoveryAction: StaleRecoveryAction?

    private var limiting: UsageWindow? { snapshot.limitingWindow }

    var body: some View {
        if let limiting {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    BrandLabel()
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(limiting.roundedRemainingPercent)%")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    WindowSummaryLabel(window: limiting, style: .small)
                        .font(.subheadline)
                        .foregroundStyle(ClarityPalette.secondaryText)
                }

                Spacer(minLength: 8)

                VStack(spacing: 7) {
                    RemainingProgressView(window: limiting)
                    ResetStatusRow(
                        resetAt: limiting.resetsAt,
                        referenceDate: date,
                        futureLabel: .resets
                    )
                    UpdatedRelativeText(
                        fetchedAt: snapshot.fetchedAt,
                        referenceDate: date,
                        stale: stale,
                        recoveryAction: recoveryAction
                    )
                    .font(.subheadline)
                    .foregroundStyle(ClarityPalette.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(limiting.detailLabel) Codex usage limit")
            .accessibilityValue(
                WidgetAccessibilityFormatter.windowValue(
                    window: limiting,
                    referenceDate: date,
                    freshness: WidgetAccessibilityFormatter.freshness(
                        fetchedAt: snapshot.fetchedAt,
                        referenceDate: date,
                        stale: stale,
                        recoveryAction: recoveryAction
                    )
                )
            )
            .accessibilityHint("Opens the Codex Usage dashboard")
        } else {
            StatusWidgetView(
                symbol: "chart.bar.xaxis",
                title: "No usage window",
                detail: "Open Codex Usage to refresh."
            )
        }
    }

}

private struct ClarityMediumView: View {
    let snapshot: UsageSnapshot
    let date: Date
    let stale: Bool
    let recoveryAction: StaleRecoveryAction?

    private var limiting: UsageWindow? { snapshot.limitingWindow }
    private var windows: [UsageWindow] {
        Array(snapshot.strictnessSortedWindows.prefix(2))
    }
    private var isMultiple: Bool { windows.count > 1 }

    var body: some View {
        if let limiting {
            GeometryReader { proxy in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        BrandLabel()
                        Spacer(minLength: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "\(limiting.roundedRemainingPercent)%")
                                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                            WindowSummaryLabel(window: limiting, style: .medium)
                                .font(.subheadline)
                                .foregroundStyle(ClarityPalette.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Limiting window")
                        .accessibilityValue(
                            "\(limiting.detailLabel) limit, \(limiting.roundedRemainingPercent) percent remaining"
                        )
                        .accessibilityHint("Opens the Codex Usage dashboard")
                        .accessibilitySortPriority(100)

                        Spacer(minLength: 5)

                        UpdatedRelativeText(
                            fetchedAt: snapshot.fetchedAt,
                            referenceDate: date,
                            stale: stale,
                            compactWhenStale: true,
                            recoveryAction: recoveryAction
                        )
                        .font(.subheadline)
                        .foregroundStyle(ClarityPalette.secondaryText)
                        .lineLimit(1)
                        .accessibilitySortPriority(10)
                    }
                    .frame(width: max(96, proxy.size.width * 0.36), alignment: .leading)

                    Rectangle()
                        .fill(.separator.opacity(0.7))
                        .frame(width: 1)
                        .accessibilityHidden(true)

                    Group {
                        if isMultiple {
                            VStack(spacing: 10) {
                                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                    WindowDetailView(window: window, date: date)
                                        .accessibilitySortPriority(90 - Double(index))
                                }
                                if snapshot.additionalWindowCount > 0 {
                                    Text("+\(snapshot.additionalWindowCount) more limits")
                                        .font(.subheadline)
                                        .foregroundStyle(ClarityPalette.secondaryText)
                                        .accessibilityLabel(
                                            "\(snapshot.additionalWindowCount) more limits available in the app"
                                        )
                                        .accessibilitySortPriority(80)
                                }
                            }
                        } else if let window = windows.first {
                            VStack(spacing: 14) {
                                HStack(spacing: 8) {
                                    WindowLabelText(window: window)
                                    Spacer(minLength: 4)
                                    PercentRemainingText(percent: window.roundedRemainingPercent)
                                        .foregroundStyle(ClarityPalette.secondaryText)
                                }
                                .font(.subheadline)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(window.detailLabel) limit")
                                .accessibilityValue("\(window.roundedRemainingPercent) percent remaining")

                                RemainingProgressView(window: window)

                                ResetStatusRow(
                                    resetAt: window.resetsAt,
                                    referenceDate: date,
                                    futureLabel: .nextReset
                                )
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(window.detailLabel) Codex usage limit")
                            .accessibilityValue(
                                WidgetAccessibilityFormatter.windowValue(
                                    window: window,
                                    referenceDate: date,
                                    freshness: nil
                                )
                            )
                            .accessibilitySortPriority(90)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            StatusWidgetView(
                symbol: "chart.bar.xaxis",
                title: "No usage window",
                detail: "Open Codex Usage to refresh."
            )
        }
    }
}

private struct WindowDetailView: View {
    let window: UsageWindow
    let date: Date

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                WindowLabelText(window: window)
                Spacer(minLength: 4)
                PercentRemainingText(percent: window.roundedRemainingPercent)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(window.detailLabel) limit")
            .accessibilityValue("\(window.roundedRemainingPercent) percent remaining")

            RemainingProgressView(window: window)

            ResetStatusRow(
                resetAt: window.resetsAt,
                referenceDate: date,
                futureLabel: .resets
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.detailLabel) Codex usage limit")
        .accessibilityValue(
            WidgetAccessibilityFormatter.windowValue(
                window: window,
                referenceDate: date,
                freshness: nil
            )
        )
    }
}

/// Keeps the approved English label when it fits, while giving genuinely
/// longer localizations an accurate shorter form before SwiftUI truncates.
private struct WindowSummaryLabel: View {
    enum Style {
        case small
        case medium
    }

    let window: UsageWindow
    let style: Style

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fitCandidate(fullLabel)
            fitCandidate(shortLabel)
            fitCandidate(windowLabel)
            fitCandidate(localizedKey(window.compactLabel))
        }
        .allowsTightening(true)
    }

    private var fullLabel: LocalizedStringKey {
        switch style {
        case .small:
            guard window.durationMinutes != nil else { return windowLabel }
            return localizedKey("\(window.detailLabel) remaining")
        case .medium:
            guard window.kind != .other else { return windowLabel }
            return localizedKey("\(window.detailLabel) remaining")
        }
    }

    private var shortLabel: LocalizedStringKey {
        guard window.durationMinutes != nil else { return windowLabel }
        return localizedKey("\(window.detailLabel) left")
    }

    private var windowLabel: LocalizedStringKey {
        localizedKey(window.detailLabel)
    }

    private func fitCandidate(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .lineLimit(1)
            // Fixed only while ViewThatFits measures each candidate. The
            // selected candidate is guaranteed to fit the proposed width.
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct WindowLabelText: View {
    let window: UsageWindow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(localizedKey(window.detailLabel))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(localizedKey(window.compactLabel))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
            .allowsTightening(true)
    }
}

private struct PercentRemainingText: View {
    let percent: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: "\(percent)% ") + Text("left")
            Text(verbatim: "\(percent)%")
        }
        .lineLimit(1)
        .allowsTightening(true)
        .monospacedDigit()
        .layoutPriority(1)
    }
}

private struct RemainingProgressView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let window: UsageWindow

    private var outlineOpacity: Double {
        // A 48% primary outline measures at least 3.7:1 against pure light or
        // dark backgrounds; non-full-color modes use an even stronger edge.
        renderingMode == .fullColor ? 0.48 : 0.62
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(outlineOpacity), lineWidth: 1)
                    }
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(0.28), lineWidth: 0.5)
                    }
                    .frame(width: proxy.size.width * window.remainingPercent / 100)
                    .widgetAccentable()
            }
        }
        .frame(height: 8)
        .accessibilityLabel("\(window.detailLabel) remaining progress")
        .accessibilityValue("\(window.roundedRemainingPercent) percent")
    }
}

private struct ResetStatusRow: View {
    let resetAt: Date?
    let referenceDate: Date
    let futureLabel: ResetLeadLabel.Kind

    var body: some View {
        Group {
            if let resetAt, resetAt <= referenceDate {
                ViewThatFits(in: .horizontal) {
                    Text("Reset pending refresh")
                    Text("Reset pending")
                        .fontWidth(.condensed)
                }
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Reset pending refresh")
            } else {
                HStack(spacing: 8) {
                    ResetLeadLabel(kind: resetAt == nil ? .reset : futureLabel)
                        .foregroundStyle(ClarityPalette.secondaryText)
                    Spacer(minLength: 4)
                    ResetRelativeText(resetAt: resetAt, referenceDate: referenceDate)
                        .fontWeight(.medium)
                        .layoutPriority(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .allowsTightening(true)
    }

    private var accessibilityLabel: String {
        WidgetAccessibilityFormatter.reset(resetAt: resetAt, referenceDate: referenceDate)
    }
}

private struct ResetLeadLabel: View {
    enum Kind {
        case reset
        case resets
        case nextReset
    }

    let kind: Kind

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(fullLabel)
            Text("Reset")
        }
        .lineLimit(1)
        .allowsTightening(true)
    }

    private var fullLabel: LocalizedStringKey {
        switch kind {
        case .reset: "Reset"
        case .resets: "Resets"
        case .nextReset: "Next reset"
        }
    }
}

private struct ResetRelativeText: View {
    let resetAt: Date?
    let referenceDate: Date

    var body: some View {
        if let resetAt {
            Text(ResetTimeFormatter.compactRemaining(from: referenceDate, to: resetAt))
                .monospacedDigit()
        } else {
            Text("Unavailable")
        }
    }
}

private struct UpdatedRelativeText: View {
    let fetchedAt: Date
    let referenceDate: Date
    let stale: Bool
    let compactWhenStale: Bool
    let recoveryAction: StaleRecoveryAction?

    init(
        fetchedAt: Date,
        referenceDate: Date,
        stale: Bool,
        compactWhenStale: Bool = false,
        recoveryAction: StaleRecoveryAction? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.referenceDate = referenceDate
        self.stale = stale
        self.compactWhenStale = compactWhenStale
        self.recoveryAction = recoveryAction
    }

    private var label: LocalizedStringKey {
        let elapsedMinutes = max(0, Int(referenceDate.timeIntervalSince(fetchedAt) / 60))
        if stale {
            if compactWhenStale { return "Out of date" }
            if elapsedMinutes < 1 { return "Out of date · just now" }
            if elapsedMinutes < 60 {
                return localizedKey("Out of date · \(elapsedMinutes)m ago")
            }
            return localizedKey("Out of date · \(elapsedMinutes / 60)h ago")
        }
        if elapsedMinutes < 1 { return "Updated now" }
        if elapsedMinutes < 60 { return localizedKey("Updated \(elapsedMinutes)m ago") }
        return localizedKey("Updated \(elapsedMinutes / 60)h ago")
    }

    private var compactLabel: LocalizedStringKey {
        let elapsedMinutes = max(0, Int(referenceDate.timeIntervalSince(fetchedAt) / 60))
        if stale {
            if compactWhenStale { return "Stale" }
            if elapsedMinutes < 1 { return "Stale now" }
            if elapsedMinutes < 60 { return localizedKey("Stale \(elapsedMinutes)m") }
            return localizedKey("Stale \(elapsedMinutes / 60)h")
        }
        if elapsedMinutes < 1 { return "Now" }
        if elapsedMinutes < 60 { return localizedKey("\(elapsedMinutes)m ago") }
        return localizedKey("\(elapsedMinutes / 60)h ago")
    }

    var body: some View {
        Group {
            if stale, compactWhenStale {
                VStack(alignment: .leading, spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        fitCandidate("Out of date")
                        fitCandidate("Stale")
                    }
                    ViewThatFits(in: .horizontal) {
                        actionFitCandidate(
                            recoveryAction?.actionVisibleLabel ?? "Open app to refresh"
                        )
                        actionFitCandidate("Open app")
                        actionFitCandidate("Open")
                    }
                }
            } else if stale {
                ViewThatFits(in: .horizontal) {
                    fitCandidate(recoveryAction?.fullVisibleLabel ?? "Out of date · Open app to refresh")
                    fitCandidate("Out of date · Open app")
                    fitCandidate("Out of date · Open")
                    fitCandidate("Stale · Open")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    fitCandidate(label)
                    fitCandidate(compactLabel)
                }
            }
        }
        .allowsTightening(true)
        .accessibilityLabel(accessibilityLabel)
    }

    private func fitCandidate(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The Medium stale action is subordinate to the status heading. Footnote
    /// keeps the complete refresh/resume verb visible with Bold Text enabled,
    /// while `ViewThatFits` still provides safe fallbacks for longer future
    /// localizations.
    private func actionFitCandidate(_ label: LocalizedStringKey) -> some View {
        fitCandidate(label)
            .font(.footnote)
    }

    private var accessibilityLabel: String {
        WidgetAccessibilityFormatter.freshness(
            fetchedAt: fetchedAt,
            referenceDate: referenceDate,
            stale: stale,
            recoveryAction: recoveryAction
        )
    }
}

private struct BrandLabel: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(
                            Color.primary.opacity(renderingMode == .fullColor ? 0.22 : 0.5),
                            lineWidth: 4
                        )
                }
            Text(verbatim: "Codex")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .accessibilityHidden(true)
    }
}

private struct StatusWidgetView: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BrandLabel()
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(ClarityPalette.secondaryText)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .allowsTightening(true)
                .accessibilityHint("Opens the Codex Usage dashboard")
                .accessibilitySortPriority(2)
            Text(verbatim: WidgetStatusCopy.visibleDetail(for: detail))
                .font(.subheadline)
                .foregroundStyle(ClarityPalette.secondaryText)
                .lineLimit(3)
                .allowsTightening(true)
                .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: detail))
        .accessibilityHint("Opens the Codex Usage dashboard")
    }
}

/// Widget cards have far less room than the host diagnostics view. Known safe
/// failure categories get concise, actionable visible copy while the complete
/// sanitized message remains the accessibility value below. The generic
/// fallback also prevents a future long message from being visually clipped.
private enum WidgetStatusCopy {
    static func visibleDetail(for detail: String) -> String {
        let category = detail.lowercased()
        if category.contains("not found") {
            return "Codex not found. Open app to re-detect."
        }
        if category.contains("unsupported") {
            return "Unsupported response. Update ChatGPT."
        }
        if category.contains("rejected") || category.contains("could not be used") {
            return "Codex could not be used. Open app to re-detect."
        }
        if category.contains("shared usage storage") || category.contains("app group") {
            return "Open Codex Usage to check shared storage."
        }
        if category.contains("automatic retries") {
            return "Retries paused. Open app to resume."
        }
        if category.contains("too long") || category.contains("timed out") {
            return "Codex timed out. Try Refresh Now."
        }
        if category.contains("temporarily unavailable") {
            return "Try Refresh Now in Codex Usage."
        }
        if detail.count > 64 {
            return "Open Codex Usage for details."
        }
        return detail
    }
}

private func localizedKey(_ value: String) -> LocalizedStringKey {
    LocalizedStringKey(value)
}

private enum ClarityPalette {
    /// Keeps auxiliary copy visually subordinate while exceeding 4.5:1 on
    /// light and dark widget backgrounds, including increased contrast.
    static let secondaryText = Color.primary.opacity(0.72)
}

private enum WidgetAccessibilityFormatter {
    static func windowValue(
        window: UsageWindow,
        referenceDate: Date,
        freshness: String?
    ) -> String {
        var components = [
            "\(window.roundedRemainingPercent) percent remaining.",
            reset(resetAt: window.resetsAt, referenceDate: referenceDate)
        ]
        if let freshness {
            components.append(freshness)
        }
        return components.joined(separator: " ")
    }

    static func reset(resetAt: Date?, referenceDate: Date) -> String {
        guard let resetAt else { return "Reset time unavailable." }
        guard resetAt > referenceDate else { return "Reset pending refresh." }
        return "Resets in \(duration(from: referenceDate, to: resetAt))."
    }

    static func freshness(
        fetchedAt: Date,
        referenceDate: Date,
        stale: Bool,
        recoveryAction: StaleRecoveryAction? = nil
    ) -> String {
        let prefix = stale ? "Out of date. Last updated" : "Last updated"
        let interval = max(0, referenceDate.timeIntervalSince(fetchedAt))
        let recoverySuffix = stale
            ? " \(recoveryAction?.accessibilityInstruction ?? StaleRecoveryAction.refresh.accessibilityInstruction)"
            : ""
        if interval < 60 {
            return "\(prefix) just now.\(recoverySuffix)"
        }

        let totalMinutes = max(1, Int(interval / 60))
        if totalMinutes < 60 {
            return "\(prefix) \(quantity(totalMinutes, singular: "minute")) ago.\(recoverySuffix)"
        }

        let hours = totalMinutes / 60
        return "\(prefix) \(quantity(hours, singular: "hour")) ago.\(recoverySuffix)"
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let totalMinutes = max(1, Int(ceil(end.timeIntervalSince(start) / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            var parts = [quantity(days, singular: "day")]
            if hours > 0 { parts.append(quantity(hours, singular: "hour")) }
            return parts.joined(separator: ", ")
        }
        if hours > 0 {
            var parts = [quantity(hours, singular: "hour")]
            if minutes > 0 { parts.append(quantity(minutes, singular: "minute")) }
            return parts.joined(separator: ", ")
        }
        return quantity(minutes, singular: "minute")
    }

    private static func quantity(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}
