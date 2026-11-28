import AppKit
import Combine
import SwiftUI

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var controller = UsageController.shared
    @StateObject private var menuBarClock = MenuBarSnapshotClock(states: UsageController.shared.$state)

    var body: some Scene {
        WindowGroup("Codex Usage", id: "dashboard") {
            DashboardHostView(controller: controller)
        }
        .defaultSize(width: 700, height: 650)
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["dashboard"])
        .commands {
            // This utility has one dashboard; reopening is handled by the menu bar.
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarUsageView(controller: controller)
        } label: {
            MenuBarUsageIcon(state: controller.state, at: menuBarClock.date)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct DashboardHostView: View {
    @ObservedObject var controller: UsageController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DashboardView(controller: controller)
            .frame(minWidth: 560, minHeight: 520)
            .background(DashboardWindowProbe())
            .onAppear {
                DashboardWindowLifecycle.shared.installOpenAction {
                    openWindow(id: "dashboard")
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { controller.refreshWhenActive() }
            }
            .onOpenURL { url in
                guard CodexUsageRoute.resolve(url) == .dashboard else { return }
                // SwiftUI has already routed the URL to a dashboard window.
                DashboardWindowLifecycle.shared.activateDashboard()
                if !controller.updatesPaused { controller.refreshNow() }
            }
    }
}

/// Tracks dashboard windows only. MenuBarExtra's transient window must never
/// make the app appear to have an open dashboard or keep its Dock icon alive.
@MainActor
final class DashboardWindowLifecycle {
    static let shared = DashboardWindowLifecycle()

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var openAction: (@MainActor () -> Void)?

    func installOpenAction(_ action: @escaping @MainActor () -> Void) {
        openAction = action
    }

    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard windows[id] == nil else { return }
        windows[id] = WeakWindow(window)
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dashboardWillClose(id) }
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func showDashboard(openWindow: @MainActor () -> Void) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = windows.values.compactMap(\.value).first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
        NSApplication.shared.activate()
    }

    @discardableResult
    func handleReopen() -> Bool {
        guard let openAction else { return false }
        showDashboard(openWindow: openAction)
        return true
    }

    func activateDashboard() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    private func dashboardWillClose(_ id: ObjectIdentifier) {
        windows.removeValue(forKey: id)
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if windows.values.allSatisfy({ $0.value == nil }) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

private struct DashboardWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DashboardWindowLifecycle.shared.register(window)
        }
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private let terminationCoordinator = ApplicationTerminationCoordinator()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // hasVisibleWindows includes the menu-bar popover; use the dashboard
        // registry instead, and suppress a second default reopen when handled.
        !DashboardWindowLifecycle.shared.handleReopen()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = terminationCoordinator.requestTermination(
            shutdown: { await UsageController.shared.shutdown() },
            reply: { [weak sender] shouldTerminate in
                sender?.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        switch decision {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        }
    }
}

/// Owns the status item's age transition even when all app windows are closed.
@MainActor
final class MenuBarSnapshotClock: ObservableObject {
    @Published private(set) var date = Date.now
    private var observation: AnyCancellable?
    private var expiration: AnyCancellable?

    init(states: Published<UsageViewState>.Publisher) {
        let workspace = NSWorkspace.shared.notificationCenter
        let timeChanges = workspace.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.screensDidWakeNotification),
                   NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .map { _ in () }
            .prepend(())
        observation = states.combineLatest(timeChanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, _ in self?.update(for: state) }
    }

    private func update(for state: UsageViewState) {
        expiration = nil
        let now = Date.now
        date = now
        let snapshot: UsageSnapshot
        switch state {
        case .available(let value), .stale(let value, _): snapshot = value
        default: return
        }
        guard !snapshot.isStale(at: now) else { return }

        // Exactly five minutes is still fresh. Fire just past the boundary.
        let deadline = snapshot.fetchedAt.addingTimeInterval(WidgetFreshnessPolicy.maximumAge + 0.001)
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(for: state) }
        }
        expiration = AnyCancellable { timer.invalidate() }
        RunLoop.main.add(timer, forMode: .common)
    }
}
