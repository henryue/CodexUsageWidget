import SwiftUI
import WidgetKit

struct DashboardView: View {
    @ObservedObject var controller: UsageController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                liveStatus
                privacyNote
                launchAtLoginSettings
                diagnostics

#if DEBUG
                Divider()
                DebugPreviewGallery()
#endif
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Codex Usage")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex usage")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Local account limits, refreshed conservatively")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.refreshNow()
            } label: {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isRefreshing || controller.updatesPaused)
            .accessibilityHint("Requests the latest usage from the local Codex app-server")

            Menu {
                if controller.updatesPaused {
                    Button("Resume Automatic Updates", systemImage: "play.fill") {
                        controller.resumeAutomaticUpdates()
                    }
                } else {
                    Button("Stop Automatic Updates", systemImage: "pause.fill") {
                        controller.pauseAutomaticUpdates()
                    }
                }
                Divider()
                Button("Quit Codex Usage", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder
    private var liveStatus: some View {
        GroupBox("Current status") {
            VStack(alignment: .leading, spacing: 14) {
                if controller.isRefreshing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing from the local Codex service…")
                    }
                }

                if controller.updatesPaused {
                    Label("Automatic updates are paused. Resume updates to refresh.", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }

                switch controller.state {
                case .loading:
                    statusMessage(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Waiting for the first refresh",
                        message: "Codex Usage will keep the last successful snapshot for the widget."
                    )
                case .unauthenticated(let message):
                    statusMessage(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in required", message: message)
                case .failed(let message):
                    statusMessage(symbol: "exclamationmark.triangle", title: "Usage unavailable", message: message)
                case .available(let snapshot):
                    snapshotRows(snapshot, stale: false)
                case .stale(let snapshot, let message):
                    snapshotRows(snapshot, stale: true)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func snapshotRows(_ snapshot: UsageSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    stale ? "Last successful data" : "Up to date",
                    systemImage: stale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
                )
                .foregroundStyle(stale ? Color.orange : Color.green)
                Spacer()
                Text(snapshot.fetchedAt, style: .relative)
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.mediumDisplayWindows) { window in
                VStack(spacing: 7) {
                    LabeledContent("\(window.detailLabel) limit") {
                        Text("\(window.roundedRemainingPercent)% remaining")
                            .monospacedDigit()
                    }
                    ProgressView(value: window.remainingPercent, total: 100)
                        .tint(.accentColor)
                    LabeledContent("Resets") {
                        if let resetsAt = window.resetsAt {
                            if resetsAt <= .now {
                                Text("Pending refresh")
                            } else {
                                Text(resetsAt, style: .relative)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Unavailable")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusMessage(symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var privacyNote: some View {
        GroupBox("Privacy and refresh behavior") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Reads only the sanitized rate-limit response from the local Codex app-server.", systemImage: "lock.shield")
                Label("Does not read auth.json, scrape a webpage, or add telemetry.", systemImage: "hand.raised")
                Label("Refreshes on launch, when returning to the foreground, and about every 15 minutes while running.", systemImage: "clock")
                Text("WidgetKit controls the final desktop update schedule, so the widget is intentionally not described as second-by-second realtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var launchAtLoginSettings: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLogin(enabled: $0) }
                    )
                )
                Text("Off by default. Enabling it registers this app as a system login item so updates can resume after you sign in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.launchAtLoginRequiresApproval {
                    Label("Approval is required in System Settings.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if let message = controller.launchAtLoginMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if controller.launchAtLoginRequiresApproval || controller.launchAtLoginMessage != nil {
                    Button("Open Login Items Settings") {
                        controller.openLoginItemsSettings()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var diagnostics: some View {
        GroupBox("Codex connection") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Executable") {
                    Text(controller.brokerDiagnostics.executablePath ?? "Not detected")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Version") {
                    Text(controller.brokerDiagnostics.executableVersion ?? "Unavailable")
                        .textSelection(.enabled)
                }
                LabeledContent("Connection") {
                    Text(controller.brokerDiagnostics.processIdentifier == nil ? "Stopped" : "Running")
                }
                if controller.brokerDiagnostics.consecutiveFailures > 0 {
                    LabeledContent("Consecutive failures") {
                        Text("\(controller.brokerDiagnostics.consecutiveFailures)")
                            .monospacedDigit()
                    }
                }
                Button("Re-detect Codex") {
                    controller.redetectCodex()
                }
                .disabled(controller.updatesPaused)
                Button("Copy Sanitized Diagnostic") {
                    controller.copySanitizedDiagnostic()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct MenuBarUsageView: View {
    @ObservedObject var controller: UsageController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
            case .loading:
                Text("Loading usage…").foregroundStyle(.secondary)
            case .unauthenticated:
                Label("Sign in required", systemImage: "person.crop.circle.badge.exclamationmark")
            case .failed:
                Label("Usage unavailable", systemImage: "exclamationmark.triangle")
            }

            Divider()

            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApplication.shared.activate()
                }
                Button("Refresh Now") {
                    controller.refreshNow()
                }
                .disabled(controller.isRefreshing || controller.updatesPaused)
            }

            HStack {
                Button(controller.updatesPaused ? "Resume Updating" : "Stop Updating") {
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
