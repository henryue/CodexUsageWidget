import AppKit
import Combine
import Foundation
import Network
import OSLog
import ServiceManagement
import WidgetKit

@MainActor
private final class SystemLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class UsageController: ObservableObject {
    static let shared = UsageController()

    @Published private(set) var state: UsageViewState
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var updatesPaused: Bool
    @Published private(set) var launchAtLoginStatus: LoginItemStatus
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var brokerDiagnostics = BrokerDiagnostics(
        executablePath: nil,
        executableVersion: nil,
        processIdentifier: nil,
        consecutiveFailures: 0
    )

    private let client: CodexAppServerClient
    private let store: AppGroupSnapshotStore
    private let loginItemCoordinator: LoginItemCoordinator
    private let automaticUpdatesCoordinator: AutomaticUpdatesCoordinator
    private var activeFetchTask: Task<Void, Never>?
    private var brokerEventTask: Task<Void, Never>?
    private var redetectObservationTask: Task<Void, Never>?
    private var wakeObservers: Set<AnyCancellable> = []
    private var widgetReloadGate = WidgetReloadGate()
    private var forceNextWidgetReload = false
    private var lastActivationRefreshAt: Date?
    private let networkMonitor = NWPathMonitor()
    private var networkWasUnavailable = false
    private static let logger = Logger(subsystem: "com.henryyue.CodexUsage", category: "refresh")
    private static let updatesPausedKey = "codexUsage.automaticUpdatesPaused"

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        store: AppGroupSnapshotStore = AppGroupSnapshotStore(),
        loginItemService: any LoginItemServicing = SystemLoginItemService()
    ) {
        self.client = client
        self.store = store
        self.loginItemCoordinator = LoginItemCoordinator(service: loginItemService)
        let initiallyPaused = UserDefaults.standard.bool(forKey: Self.updatesPausedKey)
        self.updatesPaused = initiallyPaused
        self.launchAtLoginStatus = loginItemCoordinator.presentation.status
        self.launchAtLoginMessage = loginItemCoordinator.presentation.message
        self.automaticUpdatesCoordinator = AutomaticUpdatesCoordinator(
            initiallyRunning: !initiallyPaused,
            resume: { [client] in await client.resume() },
            suspend: { [client] in await client.suspend() },
            redetect: { [client] in await client.redetect() },
            shutdown: { [client] in await client.shutdown() }
        )
        switch store.loadResult() {
        case .loaded(let envelope):
            self.state = UsageViewState.resolve(envelope: envelope, at: .now)
            self.lastError = envelope.message
        case .missing:
            self.state = .loading
            self.lastError = nil
        case .invalid:
            self.state = .failed("Shared usage data is invalid. Refresh to replace it.")
            self.lastError = "Shared usage data is invalid. Refresh to replace it."
        case .unavailable:
            self.state = .failed("Shared usage storage is unavailable. Check App Group signing.")
            self.lastError = "Shared usage storage is unavailable. Check App Group signing."
        }

        loginItemCoordinator.onPresentationChange = { [weak self] presentation in
            self?.launchAtLoginStatus = presentation.status
            self?.launchAtLoginMessage = presentation.message
        }
        if updatesPaused {
            persistPausedState()
        }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshWhenActive() }
            }
            .store(in: &wakeObservers)

        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = self.networkWasUnavailable && isAvailable
                self.networkWasUnavailable = !isAvailable
                if recovered { self.refreshWhenActive() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.henryyue.CodexUsage.network"))

        brokerEventTask = Task { [weak self, client] in
            let events = await client.events()
            guard let self, !Task.isCancelled else { return }
            self.automaticUpdatesCoordinator.start()
            for await event in events {
                guard !Task.isCancelled else { return }
                self.handleBrokerEvent(event)
            }
        }
    }

    deinit {
        networkMonitor.cancel()
        activeFetchTask?.cancel()
        brokerEventTask?.cancel()
        redetectObservationTask?.cancel()
    }

    func refreshNow() {
        startRefresh(forceWidgetReload: true)
    }

    private func startRefresh(forceWidgetReload: Bool) {
        // A user action joining an existing fetch must still refresh the widget.
        forceNextWidgetReload = forceNextWidgetReload || forceWidgetReload
        guard activeFetchTask == nil else { return }
        activeFetchTask = Task { [weak self] in
            await self?.refreshAndWait()
        }
    }

    func refreshWhenActive() {
        loginItemCoordinator.refresh()
        guard !updatesPaused else { return }
        let now = Date.now
        // Wake, scene activation and menu presentation can arrive together.
        if let previous = lastActivationRefreshAt,
           now >= previous, now.timeIntervalSince(previous) < 5 { return }
        lastActivationRefreshAt = now
        if case .available(let snapshot) = state,
           now >= snapshot.fetchedAt,
           now.timeIntervalSince(snapshot.fetchedAt) < 30 {
            let current = store.loadResult()
            reloadWidgetIfNeeded(previous: current, current: current, at: now, force: true)
            return
        }
        startRefresh(forceWidgetReload: true)
    }

    func pauseAutomaticUpdates() {
        updatesPaused = true
        UserDefaults.standard.set(true, forKey: Self.updatesPausedKey)
        persistPausedState()
        activeFetchTask?.cancel()
        automaticUpdatesCoordinator.setRunning(false)
    }

    func resumeAutomaticUpdates() {
        updatesPaused = false
        UserDefaults.standard.set(false, forKey: Self.updatesPausedKey)
        automaticUpdatesCoordinator.setRunning(true)
    }

    func redetectCodex() {
        forceNextWidgetReload = false
        activeFetchTask?.cancel()
        automaticUpdatesCoordinator.redetect()
        redetectObservationTask?.cancel()
        redetectObservationTask = Task { [weak self, client, automaticUpdatesCoordinator] in
            await automaticUpdatesCoordinator.waitForIdle()
            guard !Task.isCancelled else { return }
            self?.brokerDiagnostics = await client.diagnostics()
        }
    }

    @discardableResult
    func shutdown() async -> Bool {
        networkMonitor.cancel()
        wakeObservers.removeAll()
        let eventTask = brokerEventTask
        eventTask?.cancel()
        brokerEventTask = nil
        let fetchTask = activeFetchTask
        fetchTask?.cancel()
        activeFetchTask = nil
        let observationTask = redetectObservationTask
        observationTask?.cancel()
        redetectObservationTask = nil
        await loginItemCoordinator.shutdown()
        let shutdownCompleted = await automaticUpdatesCoordinator.shutdown()
        await fetchTask?.value
        await eventTask?.value
        await observationTask?.value
        return shutdownCompleted
    }

    var launchAtLoginEnabled: Bool {
        if case .enabled = launchAtLoginStatus { return true }
        return false
    }

    var launchAtLoginRequiresApproval: Bool {
        if case .requiresApproval = launchAtLoginStatus { return true }
        return false
    }

    func setLaunchAtLogin(enabled: Bool) {
        loginItemCoordinator.setEnabled(enabled)
    }

    func openLoginItemsSettings() {
        loginItemCoordinator.openSystemSettings()
    }

    private func refreshAndWait() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            forceNextWidgetReload = false
            isRefreshing = false
            activeFetchTask = nil
        }

        let attemptDate = Date.now
        do {
            let snapshot = try await client.fetchRateLimits(now: attemptDate)
            brokerDiagnostics = await client.diagnostics()
            // Publish last, without another suspension that could swallow a
            // user refresh joining this task just before its defer runs.
            applySuccessfulSnapshot(snapshot)
        } catch is CancellationError {
            return
        } catch {
            applyFailure(error, at: attemptDate)
        }
    }

    private func handleBrokerEvent(_ event: BrokerEvent) {
        switch event {
        case .snapshot(let snapshot, _):
            applySuccessfulSnapshot(snapshot)
            Task { [weak self, client] in
                self?.brokerDiagnostics = await client.diagnostics()
            }
        case .connectionUnavailable(let error, _):
            applyFailure(error, at: .now)
            refreshBrokerDiagnostics()
        case .automaticRetriesStopped:
            applyFailure(CodexAppServerError.automaticRetriesStopped, at: .now)
            refreshBrokerDiagnostics()
        case .suspended:
            if updatesPaused { persistPausedState() }
        }
    }

    private func refreshBrokerDiagnostics() {
        Task { [weak self, client] in
            self?.brokerDiagnostics = await client.diagnostics()
        }
    }

    private func applySuccessfulSnapshot(_ snapshot: UsageSnapshot) {
        guard !updatesPaused else {
            persistPausedState()
            return
        }
        let previousLoadResult = store.loadResult()
        let previous = loadedEnvelope(from: previousLoadResult)
        let envelope = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .available,
            lastAttemptAt: snapshot.fetchedAt
        )
        var publicationFailed = false
        if previous != envelope {
            do {
                try store.save(envelope)
            } catch {
                publicationFailed = true
                if let recovered = store.load() {
                    state = UsageViewState.resolve(envelope: recovered, at: .now)
                } else {
                    state = .failed("Shared usage storage is unavailable. Check App Group signing.")
                }
                lastError = "Shared usage storage is unavailable. Check App Group signing."
            }
        }
        let currentLoadResult = store.loadResult()
        if !publicationFailed {
            state = UsageViewState.resolve(envelope: envelope, at: .now)
            lastError = nil
            if previous != envelope {
                Self.logger.info("Published a successful usage snapshot")
            }
        }
        reloadWidgetIfNeeded(
            previous: previousLoadResult,
            current: currentLoadResult,
            at: .now
        )
    }

    private func applyFailure(_ error: Error, at attemptDate: Date) {
        guard !updatesPaused else {
            persistPausedState()
            return
        }
        let status: SharedServiceStatus = isAuthenticationError(error) ? .unauthenticated : .failed
        let message = safeMessage(for: error)
        let previousLoadResult = store.loadResult()
        let previous = loadedEnvelope(from: previousLoadResult)
        let envelope = SharedUsageEnvelope(
            snapshot: previous?.snapshot,
            serviceStatus: status,
            lastAttemptAt: attemptDate,
            message: message
        )
        var presentedMessage = message
        var publicationFailed = false
        do {
            try store.save(envelope)
        } catch {
            presentedMessage = "\(message) Snapshot sharing also failed."
            publicationFailed = true
        }
        let currentLoadResult = store.loadResult()
        let presentedEnvelope = publicationFailed
            ? (loadedEnvelope(from: currentLoadResult) ?? envelope)
            : envelope
        state = UsageViewState.resolve(envelope: presentedEnvelope, at: attemptDate)
        lastError = presentedMessage
        Self.logger.info("Usage refresh failed; retaining the last successful snapshot")
        reloadWidgetIfNeeded(
            previous: previousLoadResult,
            current: currentLoadResult,
            at: attemptDate
        )
    }

    private func persistPausedState() {
        let date = Date.now
        let previousLoadResult = store.loadResult()
        let previous = loadedEnvelope(from: previousLoadResult)
        let envelope = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: previous,
            at: date
        )
        let message = AutomaticUpdatesPersistencePolicy.pausedMessage
        do {
            if previous != envelope {
                try store.save(envelope)
            }
            state = UsageViewState.resolve(envelope: envelope, at: date)
            lastError = message
        } catch {
            if let recovered = store.load() {
                state = UsageViewState.resolve(envelope: recovered, at: date)
            } else {
                state = .failed("Updates are paused and shared usage storage is unavailable.")
            }
            lastError = "Updates are paused and shared usage storage is unavailable."
        }
        reloadWidgetIfNeeded(
            previous: previousLoadResult,
            current: store.loadResult(),
            at: date
        )
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerError else { return false }
        if case .unauthenticated = error { return true }
        return false
    }

    private func safeMessage(for error: Error) -> String {
        if error is SnapshotStoreError {
            return "Shared usage storage is unavailable. Check App Group signing, then refresh."
        }
        guard let error = error as? CodexAppServerError else {
            return "Usage is temporarily unavailable. Try Refresh Now."
        }
        switch error {
        case .unauthenticated:
            return "Sign in to Codex in the ChatGPT app, then refresh."
        case .executableNotFound:
            return "Codex was not found. Install or update the ChatGPT app, then choose Re-detect Codex."
        case .initializeTimedOut, .readTimedOut:
            return "Codex took too long to respond. Try Refresh Now."
        case .automaticRetriesStopped:
            return "Automatic retries stopped after repeated failures. Use Refresh Now to try again."
        case .executableRejected:
            return "The detected Codex executable was rejected. Update ChatGPT, then choose Re-detect Codex."
        case .protocolError:
            return "This Codex version returned an unsupported usage response. Update ChatGPT, then choose Re-detect Codex."
        case .launchFailed, .connectionClosed:
            return "Usage is temporarily unavailable. Try Refresh Now."
        }
    }

    private func reloadWidgetIfNeeded(
        previous: SnapshotStoreLoadResult,
        current: SnapshotStoreLoadResult,
        at date: Date,
        force explicitForce: Bool = false
    ) {
        let force = explicitForce || forceNextWidgetReload
        forceNextWidgetReload = false
        guard widgetReloadGate.shouldRequestReload(
            previous: previous,
            current: current,
            at: date,
            force: force
        ) else { return }
        Self.logger.info("Requesting widget timeline reload; user or activation request: \(force)")
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
    }

    private func loadedEnvelope(
        from result: SnapshotStoreLoadResult
    ) -> SharedUsageEnvelope? {
        guard case .loaded(let envelope) = result else { return nil }
        return envelope
    }

    func copySanitizedDiagnostic() {
        let report = SanitizedDiagnosticReport.make(
            diagnostics: brokerDiagnostics,
            state: UsageDiagnosticStateName.stateName(for: state),
            automaticUpdatesPaused: updatesPaused
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

}
