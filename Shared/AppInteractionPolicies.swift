import Foundation

enum CodexUsageRoute: Equatable, Sendable {
    case dashboard

    static func resolve(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "codexusage",
              url.host?.lowercased() == "dashboard" else { return nil }
        return .dashboard
    }
}

enum AutomaticUpdatesPersistencePolicy {
    static let pausedMessage = "Automatic updates are paused. Open the app to resume updates."

    static func pausedEnvelope(
        previous: SharedUsageEnvelope?,
        at date: Date
    ) -> SharedUsageEnvelope {
        if let previous,
           previous.serviceStatus == .failed,
           previous.message == pausedMessage {
            return previous
        }
        return SharedUsageEnvelope(
            snapshot: previous?.snapshot,
            serviceStatus: .failed,
            lastAttemptAt: date,
            message: pausedMessage
        )
    }
}

/// Serializes every lifecycle mutation of the app-server connection. Calls may
/// arrive while an earlier async operation is suspended; the loop always
/// re-checks the latest desired state before becoming idle.
@MainActor
final class AutomaticUpdatesCoordinator {
    typealias Operation = @MainActor @Sendable () async -> Bool
    typealias ShutdownOperation = @MainActor @Sendable () async -> Bool

    private let resumeOperation: Operation
    private let suspendOperation: Operation
    private let redetectOperation: Operation
    private let shutdownOperation: ShutdownOperation
    private var desiredRunning: Bool
    private var appliedRunning: Bool? = false
    private var redetectPending = false
    private var started = false
    private var shutdownRequested = false
    private var shutdownCompleted = false
    private var desiredRevision: UInt64 = 0
    private var operationTask: Task<Void, Never>?

    init(
        initiallyRunning: Bool,
        resume: @escaping Operation,
        suspend: @escaping Operation,
        redetect: @escaping Operation,
        shutdown: @escaping ShutdownOperation
    ) {
        desiredRunning = initiallyRunning
        resumeOperation = resume
        suspendOperation = suspend
        redetectOperation = redetect
        shutdownOperation = shutdown
    }

    func start() {
        guard !shutdownRequested, !shutdownCompleted else { return }
        started = true
        ensureProcessing()
    }

    func setRunning(_ running: Bool) {
        guard !shutdownRequested, !shutdownCompleted else { return }
        desiredRunning = running
        desiredRevision &+= 1
        ensureProcessing()
    }

    func redetect() {
        guard !shutdownRequested, !shutdownCompleted else { return }
        redetectPending = true
        desiredRevision &+= 1
        ensureProcessing()
    }

    func waitForIdle() async {
        while let operationTask {
            await operationTask.value
        }
    }

    @discardableResult
    func shutdown() async -> Bool {
        guard !shutdownCompleted else { return true }
        shutdownRequested = true
        desiredRunning = false
        redetectPending = false
        desiredRevision &+= 1
        ensureProcessing()
        await waitForIdle()
        return shutdownCompleted
    }

    private func ensureProcessing() {
        guard operationTask == nil,
              shutdownRequested || started else { return }
        operationTask = Task { [weak self] in
            await self?.processDesiredState()
        }
    }

    private func processDesiredState() async {
        while true {
            if shutdownRequested {
                let completed = await shutdownOperation()
                appliedRunning = completed ? false : nil
                shutdownCompleted = completed
                operationTask = nil
                return
            }

            if redetectPending {
                redetectPending = false
                let operationRevision = desiredRevision
                guard await suspendOperation() else {
                    appliedRunning = nil
                    if shutdownRequested || desiredRevision != operationRevision { continue }
                    operationTask = nil
                    return
                }
                appliedRunning = false
                guard await redetectOperation() else {
                    appliedRunning = nil
                    if shutdownRequested || desiredRevision != operationRevision { continue }
                    operationTask = nil
                    return
                }
                continue
            }

            guard appliedRunning != desiredRunning else {
                operationTask = nil
                return
            }

            let targetRunning = desiredRunning
            let operationRevision = desiredRevision
            let applied: Bool
            if targetRunning {
                applied = await resumeOperation()
            } else {
                applied = await suspendOperation()
            }
            guard applied else {
                appliedRunning = nil
                if shutdownRequested || desiredRevision != operationRevision { continue }
                operationTask = nil
                return
            }
            appliedRunning = targetRunning
        }
    }
}

enum UsageDiagnosticStateName {
    static func stateName(for state: UsageViewState) -> String {
        switch state {
        case .loading: "loading"
        case .available: "available"
        case .stale: "stale"
        case .unauthenticated: "signed-out"
        case .failed: "unavailable"
        }
    }
}

enum LoginItemStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

struct LoginItemPresentation: Equatable, Sendable {
    let status: LoginItemStatus
    let message: String?
}

/// Serializes login-item changes and coalesces rapid toggles to the latest intent.
/// Refreshing status never registers automatically; only an explicit user toggle can.
@MainActor
final class LoginItemCoordinator {
    typealias PresentationHandler = @MainActor (LoginItemPresentation) -> Void

    private let service: any LoginItemServicing
    private var desiredEnabled: Bool?
    private var operationTask: Task<Void, Never>?
    private var acceptsChanges = true
    private(set) var presentation: LoginItemPresentation
    var onPresentationChange: PresentationHandler?

    init(service: any LoginItemServicing) {
        self.service = service
        self.presentation = Self.presentation(for: service.status, operationFailed: false)
    }

    func refresh() {
        publish(Self.presentation(for: service.status, operationFailed: false))
    }

    func setEnabled(_ enabled: Bool) {
        guard acceptsChanges else { return }
        desiredEnabled = enabled
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            await self?.processDesiredStates()
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    func waitForIdle() async {
        while let operationTask {
            await operationTask.value
        }
    }

    func shutdown() async {
        acceptsChanges = false
        await waitForIdle()
    }

    private func processDesiredStates() async {
        while let desired = desiredEnabled {
            desiredEnabled = nil
            do {
                if desired {
                    switch service.status {
                    case .enabled, .requiresApproval:
                        break
                    case .disabled, .unavailable:
                        try service.register()
                    }
                } else if service.status != .disabled {
                    try await service.unregister()
                }

                let status = service.status
                let requestDidNotTake = desired && status != .enabled && status != .requiresApproval
                publish(Self.presentation(for: status, operationFailed: requestDidNotTake))
            } catch {
                publish(Self.presentation(for: service.status, operationFailed: true))
            }
        }
        operationTask = nil
    }

    private func publish(_ newValue: LoginItemPresentation) {
        presentation = newValue
        onPresentationChange?(newValue)
    }

    private static func presentation(
        for status: LoginItemStatus,
        operationFailed: Bool
    ) -> LoginItemPresentation {
        let message: String?
        if operationFailed {
            message = "The login item could not be changed. You can retry or open Login Items in System Settings."
        } else {
            switch status {
            case .requiresApproval:
                message = "Allow Codex Usage in System Settings › General › Login Items."
            case .unavailable:
                message = "Login item status is unavailable. You can retry or open Login Items in System Settings."
            case .disabled, .enabled:
                message = nil
            }
        }
        return LoginItemPresentation(status: status, message: message)
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    enum Decision: Equatable, Sendable {
        case terminateNow
        case terminateLater
    }

    typealias ShutdownOperation = @MainActor @Sendable () async -> Bool
    typealias ReplyHandler = @MainActor @Sendable (Bool) -> Void

    private var terminationTask: Task<Void, Never>?
    private(set) var shutdownFinished = false

    func requestTermination(
        shutdown: @escaping ShutdownOperation,
        reply: @escaping ReplyHandler
    ) -> Decision {
        if shutdownFinished { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { [weak self] in
            let completed = await shutdown()
            guard let self else { return }
            terminationTask = nil
            guard completed else {
                reply(false)
                return
            }
            shutdownFinished = true
            reply(true)
        }
        return .terminateLater
    }

    func waitForShutdown() async {
        await terminationTask?.value
    }
}
