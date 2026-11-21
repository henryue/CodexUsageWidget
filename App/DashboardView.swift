import SwiftUI
import WidgetKit

private func snapshotAgeLabel(_ snapshot: UsageSnapshot, at date: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(snapshot.fetchedAt) / 60))
    if minutes < 1 { return "Just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    return "\(minutes / 60)h ago"
}

struct DashboardView: View {
    @ObservedObject var controller: UsageController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                liveStatus
                backgroundSettings
                connectionDetails
                privacyDetails

#if DEBUG
                Divider()
                DebugPreviewGallery()
#endif
            }
            .padding(24)
            .frame(maxWidth: 740)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Codex Usage")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    controller.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isRefreshing || controller.updatesPaused)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh usage from the local Codex service")
                .accessibilityHint("Requests the latest usage from the local Codex app-server")

                Menu {
                    Button(
                        controller.updatesPaused ? "Resume Automatic Updates" : "Pause Automatic Updates",
                        systemImage: controller.updatesPaused ? "play.fill" : "pause.fill"
                    ) {
                        setAutomaticUpdates(enabled: controller.updatesPaused)
                    }
                    Divider()
                    Button("Re-detect Codex", systemImage: "arrow.triangle.2.circlepath") {
                        controller.redetectCodex()
                    }
                    .disabled(controller.updatesPaused)
                    Button("Copy Sanitized Diagnostic", systemImage: "doc.on.doc") {
                        controller.copySanitizedDiagnostic()
                    }
                    Divider()
                    Button("Quit Codex Usage", systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More options")
                .accessibilityLabel("More options")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Your Codex usage")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Account limits at a glance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing usage")
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var liveStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.updatesPaused {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic updates paused")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Resume to get the latest usage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resume") {
                        controller.resumeAutomaticUpdates()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }

            switch controller.state {
            case .loading:
                statusCard(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Waiting for usage",
                    message: controller.updatesPaused
                        ? "Resume automatic updates to request your account limits."
                        : "Connecting to the local Codex service. Your usage will appear here after the first refresh.",
                    allowsRetry: false
                )
            case .unauthenticated(let message):
                statusCard(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    title: "Sign in required",
                    message: message,
                    allowsRetry: true
                )
            case .failed(let message):
                statusCard(
                    symbol: "exclamationmark.triangle",
                    title: "Usage unavailable",
                    message: message,
                    allowsRetry: true
                )
            case .available(let snapshot):
                snapshotCard(snapshot, stale: false, message: nil)
            case .stale(let snapshot, let message):
                snapshotCard(snapshot, stale: true, message: message)
            }
        }
    }

    private func snapshotCard(_ snapshot: UsageSnapshot, stale: Bool, message: String?) -> some View {
        TimelineView(.periodic(from: snapshot.fetchedAt.addingTimeInterval(1), by: 60)) { context in
            let outOfDate = WidgetFreshnessPolicy.isOutOfDate(snapshot: snapshot, at: context.date)
            DashboardCard {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        statusBadge(
                            title: controller.updatesPaused ? "Paused" : (outOfDate ? "Out of date" : snapshotAgeLabel(snapshot, at: context.date)),
                            symbol: controller.updatesPaused ? "pause.fill" : (outOfDate ? "clock.badge.exclamationmark" : "clock"),
                            color: controller.updatesPaused || outOfDate ? .orange : .secondary
                        )
                        Spacer()
                        if controller.updatesPaused || outOfDate {
                            Text(snapshotAgeLabel(snapshot, at: context.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))

                    if let limiting = snapshot.limitingWindow {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(limiting.detailLabel) limit")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(limiting.roundedRemainingPercent)%")
                                        .font(.system(size: 64, weight: .semibold))
                                        .tracking(-2)
                                        .monospacedDigit()
                                    Text("remaining")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }

                            ProgressView(value: limiting.remainingPercent, total: 100)
                                .tint(.accentColor)
                                .accessibilityLabel("\(limiting.detailLabel) usage remaining")
                                .accessibilityValue("\(limiting.roundedRemainingPercent) percent")

                            resetSummary(limiting, at: context.date)
                        }

                        if snapshot.windows.count > 1 {
                            Divider()
                            VStack(spacing: 16) {
                                ForEach(Array(snapshot.strictnessSortedWindows.dropFirst())) { window in
                                    additionalWindowRow(window, at: context.date)
                                }
                            }
                        }
                    } else {
                        Text("No usage limits are available in this snapshot.")
                            .foregroundStyle(.secondary)
                    }

                    if stale, !controller.updatesPaused, let message {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text(message)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func additionalWindowRow(_ window: UsageWindow, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(window.detailLabel) limit")
                    .font(.subheadline)
                Spacer()
                Text("\(window.roundedRemainingPercent)% remaining")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(.accentColor)
            resetSummary(window, at: date)
        }
    }

    private func resetSummary(_ window: UsageWindow, at date: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            if let resetsAt = window.resetsAt {
                if resetsAt <= date {
                    Text("Reset time passed · Pending refresh")
                } else {
                    Text("Resets in")
                    Text(resetsAt, style: .relative)
                        .monospacedDigit()
                        .help(resetsAt.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("Reset time unavailable")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func statusBadge(title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func statusCard(symbol: String, title: String, message: String, allowsRetry: Bool) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if allowsRetry {
                    Button("Refresh Now", systemImage: "arrow.clockwise") {
                        controller.refreshNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isRefreshing || controller.updatesPaused)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
    }

    private var backgroundSettings: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Background & startup", systemImage: "switch.2")
                    .font(.headline)

                HStack {
                    Text("Automatic updates")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Automatic updates", isOn: Binding(
                        get: { !controller.updatesPaused },
                        set: { setAutomaticUpdates(enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Automatic updates")
                }

                HStack {
                    Text("Launch at Login")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Launch at Login", isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLogin(enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Launch at Login")
                }

                if controller.launchAtLoginRequiresApproval {
                    Label("Approve the login item in System Settings.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let message = controller.launchAtLoginMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if controller.launchAtLoginRequiresApproval || controller.launchAtLoginMessage != nil {
                    Button("Open Login Items Settings") {
                        controller.openLoginItemsSettings()
                    }
                }

                Divider()
                Label {
                    Text("Close this window to keep running in the menu bar. Use its icon to reopen the dashboard or quit.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "menubar.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionDetails: some View {
        DashboardCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    LabeledContent("Version") {
                        Text(controller.brokerDiagnostics.executableVersion ?? "Unavailable")
                            .textSelection(.enabled)
                    }
                    LabeledContent("Service") {
                        Text(controller.brokerDiagnostics.processIdentifier == nil ? "Stopped" : "Running")
                    }
                    if controller.brokerDiagnostics.consecutiveFailures > 0 {
                        LabeledContent("Consecutive failures") {
                            Text("\(controller.brokerDiagnostics.consecutiveFailures)")
                                .monospacedDigit()
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Executable")
                            .foregroundStyle(.secondary)
                        Text(controller.brokerDiagnostics.executablePath ?? "Not detected")
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Re-detect Codex") {
                            controller.redetectCodex()
                        }
                        .disabled(controller.updatesPaused)
                        Button("Copy Sanitized Diagnostic") {
                            controller.copySanitizedDiagnostic()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .padding(.top, 8)
            } label: {
                HStack {
                    Label("Connection details", systemImage: "network")
                        .font(.headline)
                    Spacer()
                    Text(controller.updatesPaused ? "Paused" : (controller.brokerDiagnostics.processIdentifier == nil ? "Not connected" : "Running"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var privacyDetails: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reads only the sanitized rate-limit response from the local Codex app-server. It does not read auth.json, scrape a webpage, or add telemetry.")
                Text("Checks usage about every 30 seconds while running. Opening the dashboard or menu, waking your Mac, or reconnecting to the network also checks for updates. Temporary connection failures retry automatically, slowing to about every 5 minutes after repeated failures.")
                Text("Usage changes request a widget update right away. Unchanged readings are combined to reduce unnecessary refreshes; macOS controls when the desktop widget redraws.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            Label("Privacy & refresh behavior", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func setAutomaticUpdates(enabled: Bool) {
        if enabled {
            controller.resumeAutomaticUpdates()
        } else {
            controller.pauseAutomaticUpdates()
        }
    }
}

private struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct MenuBarUsageView: View {
    @ObservedObject var controller: UsageController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: ageTimelineStart, by: 60)) { context in
            content(at: context.date)
        }
    }

    private var ageTimelineStart: Date {
        switch controller.state {
        case .available(let snapshot), .stale(let snapshot, _):
            snapshot.fetchedAt.addingTimeInterval(1)
        case .loading, .unauthenticated, .failed:
            .now
        }
    }

    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex Usage")
                    .font(.headline)
                Spacer()
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            switch controller.state {
            case .available(let snapshot), .stale(let snapshot, _):
                if let limiting = snapshot.limitingWindow {
                    Text("\(limiting.roundedRemainingPercent)% remaining")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("\(limiting.detailLabel) limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if WidgetFreshnessPolicy.isOutOfDate(snapshot: snapshot, at: date) {
                    Label("Out of date", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(snapshotAgeLabel(snapshot, at: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                Text("Loading usage…").foregroundStyle(.secondary)
            case .unauthenticated:
                Label("Sign in required", systemImage: "person.crop.circle.badge.exclamationmark")
            case .failed:
                Label("Usage unavailable", systemImage: "exclamationmark.triangle")
            }

            if controller.updatesPaused {
                Label("Updates paused", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case .stale(_, let message) = controller.state, let message {
                Label(serviceStatusLabel(for: message), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(message)
            }

            Divider()

            HStack {
                Button("Open Dashboard") {
                    DashboardWindowLifecycle.shared.showDashboard {
                        openWindow(id: "dashboard")
                    }
                }
                Button("Refresh Now") {
                    controller.refreshNow()
                }
                .disabled(controller.isRefreshing || controller.updatesPaused)
            }

            HStack {
                Button(controller.updatesPaused ? "Resume Updating" : "Pause Updating") {
                    if controller.updatesPaused {
                        controller.resumeAutomaticUpdates()
                    } else {
                        controller.pauseAutomaticUpdates()
                    }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { controller.refreshWhenActive() }
    }

    private func serviceStatusLabel(for message: String) -> String {
        switch WidgetStaleRecoveryKind(message: message) {
        case .resume: "Updates paused"
        case .signIn: "Sign in required"
        case .storage: "Shared storage unavailable"
        case .refresh: "Refresh delayed"
        }
    }
}

#if DEBUG
private enum DebugGalleryState: String, CaseIterable, Identifiable {
    case current = "Current · 7-day"
    case future = "Future · 5-hour + 7-day"
    case loading = "Loading"
    case error = "Error"
    case stale = "Stale"

    var id: String { rawValue }
}

private struct DebugPreviewGallery: View {
    @State private var selection = DebugGalleryState.current
    @State private var family = WidgetFamily.systemMedium
    private let now = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Development Preview Gallery")
                .font(.title2)
                .fontWeight(.semibold)
            Text("DEBUG-only. This uses the exact Clarity content view shipped by the Widget extension.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("State", selection: $selection) {
                    ForEach(DebugGalleryState.allCases) { state in
                        Text(state.rawValue).tag(state)
                    }
                }
                Picker("Size", selection: $family) {
                    Text("Small").tag(WidgetFamily.systemSmall)
                    Text("Medium").tag(WidgetFamily.systemMedium)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            ClarityPreviewCard(family: family) {
                ClarityWidgetView(state: previewState, family: family, date: now)
            }
        }
    }

    private var previewState: UsageViewState {
        switch selection {
        case .current:
            .available(.previewSevenDay(now: now))
        case .future:
            .available(.previewDualWindow(now: now))
        case .loading:
            .loading
        case .error:
            .failed("Open Codex Usage to try again.")
        case .stale:
            .stale(.previewSevenDay(now: now.addingTimeInterval(-2 * 3_600)), message: "Preview error")
        }
    }
}

private struct ClarityPreviewCard<Content: View>: View {
    let family: WidgetFamily
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(
                width: family == .systemSmall ? 168 : 360,
                height: family == .systemSmall ? 168 : 168
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.10))
            }
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
            .frame(maxWidth: .infinity)
    }
}
#endif
