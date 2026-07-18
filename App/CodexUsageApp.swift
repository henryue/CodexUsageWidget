import SwiftUI

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var controller = UsageController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Codex Usage", id: "dashboard") {
            DashboardView(controller: controller)
                .frame(minWidth: 520, minHeight: 470)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        controller.refreshWhenActive()
                    }
                }
                .onOpenURL { url in
                    guard CodexUsageRoute.resolve(url) == .dashboard else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 650, height: 620)
        .handlesExternalEvents(matching: ["dashboard"])

        MenuBarExtra {
            MenuBarUsageView(controller: controller)
        } label: {
            Label("Codex Usage", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch controller.state {
        case .available: "chart.bar.fill"
        case .stale: "clock.badge.exclamationmark"
        case .loading: "arrow.triangle.2.circlepath"
        case .unauthenticated, .failed: "exclamationmark.triangle"
        }
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private let terminationCoordinator = ApplicationTerminationCoordinator()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = terminationCoordinator.requestTermination(
            shutdown: {
                await UsageController.shared.shutdown()
            },
            reply: { [weak sender] shouldTerminate in
                sender?.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        switch decision {
        case .terminateNow:
            return .terminateNow
        case .terminateLater:
            return .terminateLater
        }
    }
}
