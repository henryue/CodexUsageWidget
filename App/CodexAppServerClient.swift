import AppKit
import CoreFoundation
import Darwin
import Foundation
#if SWIFT_PACKAGE
import CodexUsageCore
#endif

public enum CodexAppServerError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case executableRejected
    case launchFailed
    case initializeTimedOut
    case readTimedOut
    case connectionClosed
    case protocolError
    case unauthenticated
    case automaticRetriesStopped

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex was not found."
        case .executableRejected:
            "The detected Codex executable did not pass the security check."
        case .launchFailed:
            "Codex could not start."
        case .initializeTimedOut:
            "Codex did not initialize before the five-second deadline."
        case .readTimedOut:
            "Codex did not return usage before the ten-second deadline."
        case .connectionClosed:
            "Codex closed the local connection."
        case .protocolError:
            "Codex returned an unsupported response."
        case .unauthenticated:
            "Sign in to Codex, then try again."
        case .automaticRetriesStopped:
            "Automatic retries stopped after repeated failures."
        }
    }
}

public enum BrokerRefreshReason: String, Sendable, Equatable {
    case launch
    case manual
    case foreground
    case notification
    case reconciliation
    case recovery
}

public enum BrokerEvent: Sendable, Equatable {
    case snapshot(UsageSnapshot, reason: BrokerRefreshReason)
    case connectionUnavailable(CodexAppServerError, retryIn: Duration?)
    case automaticRetriesStopped
    case suspended
}

public struct BrokerDiagnostics: Sendable, Equatable {
    public let executablePath: String?
    public let executableVersion: String?
    public let processIdentifier: Int32?
    public let versionProcessIdentifier: Int32?
    public let consecutiveFailures: Int
    public let receivedProtocolLineCount: Int
    public let unknownNotificationCount: Int
    public let unknownResponseIDCount: Int
    public let invalidWindowDiscardCount: Int
    public let sameDurationCollisionCount: Int

    public init(
        executablePath: String?,
        executableVersion: String?,
        processIdentifier: Int32?,
        versionProcessIdentifier: Int32? = nil,
        consecutiveFailures: Int,
        receivedProtocolLineCount: Int = 0,
        unknownNotificationCount: Int = 0,
        unknownResponseIDCount: Int = 0,
        invalidWindowDiscardCount: Int = 0,
        sameDurationCollisionCount: Int = 0
    ) {
        self.executablePath = executablePath
        self.executableVersion = executableVersion
        self.processIdentifier = processIdentifier
        self.versionProcessIdentifier = versionProcessIdentifier
        self.consecutiveFailures = consecutiveFailures
        self.receivedProtocolLineCount = receivedProtocolLineCount
        self.unknownNotificationCount = unknownNotificationCount
        self.unknownResponseIDCount = unknownResponseIDCount
        self.invalidWindowDiscardCount = invalidWindowDiscardCount
        self.sameDurationCollisionCount = sameDurationCollisionCount
    }
}

public enum SanitizedDiagnosticReport {
    public static func make(
        diagnostics: BrokerDiagnostics,
        state: String,
        automaticUpdatesPaused: Bool
    ) -> String {
        let connection = diagnostics.processIdentifier == nil ? "stopped" : "running"
        let location = executableLocationCategory(diagnostics.executablePath)
        let version = sanitizedVersion(diagnostics.executableVersion)
        return """
        Codex Usage diagnostic
        State: \(sanitizedState(state))
        Automatic updates: \(automaticUpdatesPaused ? "paused" : "enabled")
        Connection: \(connection)
        Executable location: \(location)
        Codex version: \(version)
        Consecutive failures: \(max(0, diagnostics.consecutiveFailures))
        Unknown notifications: \(max(0, diagnostics.unknownNotificationCount))
        Unknown response IDs: \(max(0, diagnostics.unknownResponseIDCount))
        Invalid windows discarded: \(max(0, diagnostics.invalidWindowDiscardCount))
        Same-duration collisions: \(max(0, diagnostics.sameDurationCollisionCount))
        Privacy: only connection categories are included
        """
    }

    private static func executableLocationCategory(_ path: String?) -> String {
        guard let path else { return "not detected" }
        if path.contains(".app/Contents/Resources/") { return "ChatGPT application bundle" }
        if path.hasPrefix("/opt/homebrew/") { return "Homebrew" }
        if path.hasPrefix("/usr/local/") { return "local command line installation" }
        return "custom validated location"
    }

    private static func sanitizedVersion(_ version: String?) -> String {
        guard let version, !version.isEmpty, version.count <= 80 else { return "unavailable" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._+-"))
        guard version.unicodeScalars.allSatisfy(allowed.contains) else { return "unavailable" }
        return version
    }

    private static func sanitizedState(_ state: String) -> String {
        let allowed = ["loading", "available", "stale", "signed-out", "unavailable"]
        return allowed.contains(state) ? state : "unavailable"
    }
}

protocol BrokerSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousBrokerSleeper: BrokerSleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A lock-protected, single-consumer completion gate. Startup uses this instead
/// of a structured task group so an uncooperative factory cannot make the
/// timeout branch wait for the late factory task to return.
private final class StartupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completed = lock.withLock { () -> Result<Void, Error>? in
                if let storedResult { return storedResult }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Void, Error>) -> Bool {
        let resolution = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
            guard storedResult == nil else { return (false, nil) }
            storedResult = result
            let waiting = continuation
            continuation = nil
            return (true, waiting)
        }
        resolution.1?.resume(with: result)
        return resolution.0
    }
}

/// Tracks the actual lifetime of an unstructured operation independently of
/// any caller-facing timeout or cancellation. Waiting is bounded, while the
/// latch and its owner remain strongly held until the operation really exits.
private final class AsyncCompletionLatch: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        var deadlineTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var completed = false
    private var waiters: [UUID: Waiter] = [:]

    var isCompleted: Bool { lock.withLock { completed } }

    func complete() {
        let ownedWaiters = lock.withLock { () -> [Waiter] in
            guard !completed else { return [] }
            completed = true
            let values = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            return values
        }
        for waiter in ownedWaiters {
            waiter.deadlineTask?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let shouldRegister = lock.withLock { () -> Bool in
                guard !completed, ContinuousClock.now < deadline else { return false }
                waiters[id] = Waiter(continuation: continuation, deadlineTask: nil)
                return true
            }
            guard shouldRegister else {
                continuation.resume(returning: isCompleted)
                return
            }

            let deadlineTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self?.resolveWaiter(id: id, completed: false)
            }
            let attached = lock.withLock { () -> Bool in
                guard var waiter = waiters[id] else { return false }
                waiter.deadlineTask = deadlineTask
                waiters[id] = waiter
                return true
            }
            if !attached { deadlineTask.cancel() }
        }
    }

    private func resolveWaiter(id: UUID, completed: Bool) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        guard let waiter else { return }
        waiter.deadlineTask?.cancel()
        waiter.continuation.resume(returning: completed)
    }
}

enum CodexTransportEvent: Sendable, Equatable {
    case stdoutLine(Data)
    case stdoutClosed
    case terminated(Int32)
}

protocol CodexTransport: AnyObject, Sendable {
    var events: AsyncThrowingStream<CodexTransportEvent, Error> { get }
    var executableURL: URL { get }
    var processIdentifier: Int32? { get }
    func send(line: Data) throws
    func stop() async -> Bool
}

protocol CodexTransportFactory: Sendable {
    func start() async throws -> any CodexTransport
}

struct BrokerTeardownRaceHooks: Sendable {
    let ensureReadyWillDrainRetiredTransport: (@Sendable () -> Void)?
    let ensureReadyDidDrainRetiredTransport: (@Sendable () -> Void)?
    let stopBeforeStableStateVerification: (@Sendable () async -> Void)?

    init(
        ensureReadyWillDrainRetiredTransport: (@Sendable () -> Void)? = nil,
        ensureReadyDidDrainRetiredTransport: (@Sendable () -> Void)? = nil,
        stopBeforeStableStateVerification: (@Sendable () async -> Void)? = nil
    ) {
        self.ensureReadyWillDrainRetiredTransport = ensureReadyWillDrainRetiredTransport
        self.ensureReadyDidDrainRetiredTransport = ensureReadyDidDrainRetiredTransport
        self.stopBeforeStableStateVerification = stopBeforeStableStateVerification
    }
}

/// Owns one long-lived app-server session and coalesces every overlapping read.
/// All raw JSON is kept in memory only until it has been normalized.
public actor CodexAppServerBroker {
    public struct Configuration: Sendable {
        public var initializeTimeout: Duration
        public var readTimeout: Duration
        public var notificationDebounce: Duration
        public var reconciliationInterval: Duration
        public var retryDelays: [Duration]
        public var maximumAutomaticFailures: Int
        public var slowRecoveryInterval: Duration

        public init(
            initializeTimeout: Duration = .seconds(5),
            readTimeout: Duration = .seconds(10),
            notificationDebounce: Duration = .milliseconds(500),
            // A separate desktop session may consume quota without notifying
            // this connection, so reconcile even while the dashboard is closed.
            reconciliationInterval: Duration = .seconds(30),
            retryDelays: [Duration] = [
                .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(30)
            ],
            maximumAutomaticFailures: Int = 10,
            slowRecoveryInterval: Duration = .seconds(5 * 60)
        ) {
            self.initializeTimeout = initializeTimeout
            self.readTimeout = readTimeout
            self.notificationDebounce = notificationDebounce
            self.reconciliationInterval = reconciliationInterval
            self.retryDelays = retryDelays
            self.maximumAutomaticFailures = maximumAutomaticFailures
            self.slowRecoveryInterval = slowRecoveryInterval
        }
    }

    private enum Lifecycle {
        case stopped
        case starting
        case ready
        case backingOff
        case suspended
        case terminal
        case cleanupPending
        case shutdownPending
        case shutdown
    }

    private struct PendingRPC {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct ReadWaiter {
        let continuation: CheckedContinuation<UsageSnapshot, Error>
    }

    private struct StartOperationOwnership {
        let task: Task<Void, Never>
        let completion: AsyncCompletionLatch
    }

    private struct RetiredTransportOwnership {
        let transport: any CodexTransport
        var stopAttemptToken: UUID?
        var stopTask: Task<Bool, Never>?
    }

    private struct DeferredConnectionFailure {
        let error: CodexAppServerError
        let scheduleConnectionRetry: Bool
    }

    private let configuration: Configuration
    private let factory: any CodexTransportFactory
    private let sleeper: any BrokerSleeper
    private let jitter: @Sendable (Duration) -> Duration
    private let versionInspectionHandlerDelayForTesting: Duration
    private let suppressSynchronousVersionExitObservationForTesting: Bool
    private let teardownRaceHooksForTesting: BrokerTeardownRaceHooks?

    private var lifecycle: Lifecycle = .stopped
    private var stopInProgress = false
    private var aggregatedStopTarget: Lifecycle?
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var stopEpoch: UInt64 = 0
    private var automaticUpdatesEnabled = false
    private var generation: UInt64 = 0
    private var nextRequestNumber: UInt64 = 0
    private var failureSerial: UInt64 = 0
    private var consecutiveFailures = 0
    private var receivedProtocolLineCount = 0
    private var unknownNotificationCount = 0
    private var unknownResponseIDCount = 0
    private var invalidWindowDiscardCount = 0
    private var sameDurationCollisionCount = 0

    private var transport: (any CodexTransport)?
    private var selectedExecutableURL: URL?
    private var selectedExecutableVersion: String?
    private var versionInspectionCompletedForURL: URL?
    private var versionInspectionTask: Task<Void, Never>?
    private var versionInspectionProbe: CodexBinaryInspector.Probe?
    private var versionInspectionResult: CodexBinaryInspector.ResultBox?
    private var receiveTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var startOperationTask: Task<Void, Never>?
    private var startDeadlineTask: Task<Void, Never>?
    private var startToken: UUID?
    private var startOperationOwnerships: [UUID: StartOperationOwnership] = [:]
    private var retiredTransports: [ObjectIdentifier: RetiredTransportOwnership] = [:]
    private var readTask: Task<UsageSnapshot, Error>?
    private var readToken: UUID?
    private var readWaiters: [UUID: ReadWaiter] = [:]
    private var readAgainAfterCurrent = false
    private var reconcileTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var backoffToken: UUID?
    private var cleanupRetryTask: Task<Void, Never>?
    private var cleanupRetryToken: UUID?
    private var deferredConnectionFailure: DeferredConnectionFailure?
    private var pending: [String: PendingRPC] = [:]
    private var eventContinuations: [UUID: AsyncStream<BrokerEvent>.Continuation] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.factory = ProcessCodexTransportFactory(resolver: CodexExecutableResolver())
        self.sleeper = ContinuousBrokerSleeper()
        self.jitter = Self.randomJitter
        self.versionInspectionHandlerDelayForTesting = .zero
        self.suppressSynchronousVersionExitObservationForTesting = false
        self.teardownRaceHooksForTesting = nil
    }

    public init(executableURL: URL, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.factory = ProcessCodexTransportFactory(
            resolver: FixedCodexExecutableResolver(url: executableURL)
        )
        self.sleeper = ContinuousBrokerSleeper()
        self.jitter = Self.randomJitter
        self.versionInspectionHandlerDelayForTesting = .zero
        self.suppressSynchronousVersionExitObservationForTesting = false
        self.teardownRaceHooksForTesting = nil
    }

    init(
        factory: any CodexTransportFactory,
        configuration: Configuration = Configuration(),
        sleeper: any BrokerSleeper = ContinuousBrokerSleeper(),
        jitter: @escaping @Sendable (Duration) -> Duration = { $0 },
        versionInspectionHandlerDelayForTesting: Duration = .zero,
        suppressSynchronousVersionExitObservationForTesting: Bool = false,
        teardownRaceHooksForTesting: BrokerTeardownRaceHooks? = nil
    ) {
        self.configuration = configuration
        self.factory = factory
        self.sleeper = sleeper
        self.jitter = jitter
        self.versionInspectionHandlerDelayForTesting = versionInspectionHandlerDelayForTesting
        self.suppressSynchronousVersionExitObservationForTesting =
            suppressSynchronousVersionExitObservationForTesting
        self.teardownRaceHooksForTesting = teardownRaceHooksForTesting
    }

    public func events() -> AsyncStream<BrokerEvent> {
        let pair = AsyncStream<BrokerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    public func diagnostics() -> BrokerDiagnostics {
        consumeVersionInspectionResult()
        return BrokerDiagnostics(
            executablePath: selectedExecutableURL?.path,
            executableVersion: selectedExecutableVersion,
            processIdentifier: transport?.processIdentifier
                ?? retiredTransports.values.lazy.compactMap {
                    $0.transport.processIdentifier
                }.first,
            versionProcessIdentifier: versionInspectionProbe?.processIdentifier,
            consecutiveFailures: consecutiveFailures,
            receivedProtocolLineCount: receivedProtocolLineCount,
            unknownNotificationCount: unknownNotificationCount,
            unknownResponseIDCount: unknownResponseIDCount,
            invalidWindowDiscardCount: invalidWindowDiscardCount,
            sameDurationCollisionCount: sameDurationCollisionCount
        )
    }

    func refreshWaiterCountForTesting() -> Int {
        readWaiters.count
    }

    /// Deterministically joins the inspection that is current at the time of
    /// this call. Tests use this instead of polling diagnostics with a timeout
    /// shorter than the inspector's own bounded termination deadline.
    func waitForVersionInspectionForTesting() async {
        consumeVersionInspectionResult()
        guard let task = versionInspectionTask,
              let result = versionInspectionResult else { return }
        await task.value
        guard versionInspectionResult === result else { return }
        consumeVersionInspectionResult()
    }

    public func fetchRateLimits(now: Date = .now) async throws -> UsageSnapshot {
        try await refresh(reason: .manual, fetchedAt: now)
    }

    public func refresh(
        reason: BrokerRefreshReason,
        fetchedAt: Date = .now
    ) async throws -> UsageSnapshot {
        if lifecycle == .cleanupPending {
            guard await stopCurrentSession(
                nextLifecycle: .stopped,
                reason: CodexAppServerError.connectionClosed
            ), lifecycle == .stopped else {
                throw CodexAppServerError.connectionClosed
            }
            if automaticUpdatesEnabled { ensureReconciliationLoop() }
        }
        guard lifecycle != .shutdownPending else {
            throw CodexAppServerError.connectionClosed
        }
        guard lifecycle != .shutdown, lifecycle != .suspended else {
            throw CancellationError()
        }

        if reason == .manual || reason == .foreground {
            permitExplicitRetry()
        } else if lifecycle == .backingOff || lifecycle == .terminal {
            throw CodexAppServerError.connectionClosed
        }

        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readWaiters[waiterID] = ReadWaiter(continuation: continuation)
                if readTask == nil {
                    beginRead(reason: reason, fetchedAt: fetchedAt)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReadWaiter(waiterID)
            }
        }
    }

    @discardableResult
    public func resume() async -> Bool {
        guard lifecycle != .shutdown, lifecycle != .shutdownPending else { return false }
        automaticUpdatesEnabled = true
        if lifecycle == .cleanupPending {
            guard await stopCurrentSession(
                nextLifecycle: .stopped,
                reason: CancellationError()
            ), lifecycle == .stopped else { return false }
        }
        if lifecycle == .suspended || lifecycle == .terminal {
            lifecycle = .stopped
            consecutiveFailures = 0
        }
        ensureReconciliationLoop()
        _ = try? await refresh(reason: .launch)
        return true
    }

    @discardableResult
    public func suspend() async -> Bool {
        guard lifecycle != .shutdown, lifecycle != .shutdownPending else { return false }
        automaticUpdatesEnabled = false
        guard await stopCurrentSession(
            nextLifecycle: .suspended,
            reason: CancellationError()
        ), lifecycle == .suspended else { return false }
        emit(.suspended)
        return true
    }

    @discardableResult
    public func shutdown() async -> Bool {
        guard lifecycle != .shutdown else { return true }
        automaticUpdatesEnabled = false
        // Close every new-work entry point before the first suspension in
        // stopCurrentSession. A failed attempt remains in this state so a
        // later shutdown call can retry teardown without reopening the broker.
        lifecycle = .shutdownPending
        guard await stopCurrentSession(
            nextLifecycle: .shutdown,
            reason: CancellationError()
        ), lifecycle == .shutdown else { return false }
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
        return true
    }

    /// Drops every executable-derived diagnostic and forces the next launch to
    /// resolve and inspect Codex again, including when the path is unchanged.
    @discardableResult
    public func redetect() async -> Bool {
        guard lifecycle != .shutdown, lifecycle != .shutdownPending else { return false }
        let shouldResume = automaticUpdatesEnabled
        automaticUpdatesEnabled = false
        guard await stopCurrentSession(
            nextLifecycle: .stopped,
            reason: CancellationError()
        ), lifecycle == .stopped else { return false }
        selectedExecutableURL = nil
        selectedExecutableVersion = nil
        versionInspectionCompletedForURL = nil
        if shouldResume {
            return await resume()
        }
        return true
    }

    private func performFullRead(
        reason: BrokerRefreshReason,
        fetchedAt: Date
    ) async throws -> UsageSnapshot {
        let startingFailureSerial = failureSerial
        do {
            try await ensureReady()
            let readGeneration = generation
            let response = try await rpc(
                method: "account/rateLimits/read",
                params: NSNull(),
                timeout: configuration.readTimeout,
                timeoutError: .readTimedOut,
                generation: readGeneration,
                idPrefix: "rate-limits"
            )
            let snapshot: UsageSnapshot
            switch RateLimitsParser.parseResponseLineOutcome(response, fetchedAt: fetchedAt) {
            case .success(let result):
                invalidWindowDiscardCount += result.diagnostics.invalidWindowDiscardCount
                sameDurationCollisionCount += result.diagnostics.sameDurationCollisionCount
                snapshot = result.snapshot
            case .failure(let parserError, let diagnostics):
                invalidWindowDiscardCount += diagnostics.invalidWindowDiscardCount
                sameDurationCollisionCount += diagnostics.sameDurationCollisionCount
                throw mapParserError(parserError)
            }

            markSuccessfulRead()
            emit(.snapshot(snapshot, reason: reason))
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let normalized = normalize(error)
            if failureSerial == startingFailureSerial {
                await failSession(
                    generation: generation,
                    error: normalized,
                    scheduleRetry: shouldAutomaticallyRetry(normalized)
                )
            }
            throw normalized
        }
    }

    private func beginRead(reason: BrokerRefreshReason, fetchedAt: Date) {
        let token = UUID()
        let task = Task { [weak self] () throws -> UsageSnapshot in
            guard let self else { throw CancellationError() }
            return try await self.performFullRead(reason: reason, fetchedAt: fetchedAt)
        }
        readTask = task
        readToken = token
        Task { [weak self, task] in
            let result = await task.result
            await self?.completeRead(token: token, result: result)
        }
    }

    private func completeRead(
        token: UUID,
        result: Result<UsageSnapshot, Error>
    ) {
        guard readToken == token else { return }
        readTask = nil
        readToken = nil

        let waiters = readWaiters.values
        readWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }

        guard readAgainAfterCurrent, automaticUpdatesEnabled,
              lifecycle != .shutdown, lifecycle != .cleanupPending,
              lifecycle != .shutdownPending else {
            readAgainAfterCurrent = false
            return
        }
        readAgainAfterCurrent = false
        Task { [weak self] in
            _ = try? await self?.refresh(reason: .notification)
        }
    }

    private func cancelReadWaiter(_ waiterID: UUID) async {
        guard let waiter = readWaiters.removeValue(forKey: waiterID) else { return }
        guard readWaiters.isEmpty, readTask != nil else {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }

        readTask?.cancel()
        _ = await stopCurrentSession(nextLifecycle: .stopped, reason: CancellationError())
        if automaticUpdatesEnabled { ensureReconciliationLoop() }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func ensureReady() async throws {
        let readinessStopEpoch = stopEpoch
        try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: true)
        if lifecycle == .ready, transport != nil { return }
        if let startTask {
            try await startTask.value
            try Task.checkCancellation()
            try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: false)
            guard lifecycle == .ready, transport != nil else {
                throw CodexAppServerError.connectionClosed
            }
            return
        }
        if !startOperationOwnerships.isEmpty {
            let startsStopped = await waitForStartOperationsToStop(
                until: ContinuousClock.now + .milliseconds(250)
            )
            try Task.checkCancellation()
            try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: true)
            guard startsStopped else {
                lifecycle = .cleanupPending
                throw CodexAppServerError.connectionClosed
            }
        }
        if !retiredTransports.isEmpty {
            teardownRaceHooksForTesting?.ensureReadyWillDrainRetiredTransport?()
            let transportsStopped = await stopAllRetiredTransports()
            teardownRaceHooksForTesting?.ensureReadyDidDrainRetiredTransport?()
            try Task.checkCancellation()
            try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: true)
            guard transportsStopped else {
                lifecycle = .cleanupPending
                throw CodexAppServerError.connectionClosed
            }
        }
        try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: true)
        if lifecycle == .cleanupPending { lifecycle = .stopped }
        try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: false)
        guard startOperationOwnerships.isEmpty, retiredTransports.isEmpty,
              transport == nil else {
            throw CodexAppServerError.connectionClosed
        }

        lifecycle = .starting
        generation &+= 1
        let requestedGeneration = generation
        let token = UUID()
        let totalStartupTimeout = min(configuration.initializeTimeout, .seconds(5))
        let completion = StartupCompletion()
        let operationCompletion = AsyncCompletionLatch()
        let operationTask = Task { [weak self, operationCompletion] in
            guard let self else {
                completion.resolve(.failure(CancellationError()))
                operationCompletion.complete()
                return
            }
            do {
                try await self.startSession(
                    generation: requestedGeneration,
                    stopEpoch: readinessStopEpoch
                )
                completion.resolve(.success(()))
            } catch {
                completion.resolve(.failure(error))
            }
            operationCompletion.complete()
            await self.startOperationActuallyCompleted(
                token: token,
                completion: operationCompletion
            )
        }
        let deadlineTask = Task { [weak self, sleeper, timeout = totalStartupTimeout] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard completion.resolve(.failure(CodexAppServerError.initializeTimedOut)) else {
                return
            }
            operationTask.cancel()
            await self?.startupDeadlineReached(
                generation: requestedGeneration,
                token: token
            )
        }
        let task = Task {
            try await withTaskCancellationHandler {
                try await completion.value()
            } onCancel: {
                operationTask.cancel()
                deadlineTask.cancel()
                completion.resolve(.failure(CancellationError()))
            }
        }
        startTask = task
        startOperationTask = operationTask
        startDeadlineTask = deadlineTask
        startToken = token
        startOperationOwnerships[token] = StartOperationOwnership(
            task: operationTask,
            completion: operationCompletion
        )

        do {
            try await task.value
            try Task.checkCancellation()
            try requireReadinessFence(epoch: readinessStopEpoch, allowCleanupPending: false)
            guard lifecycle == .ready, transport != nil else {
                throw CodexAppServerError.connectionClosed
            }
            clearStartTask(token: token)
        } catch {
            clearStartTask(token: token)
            throw error
        }
    }

    private func requireReadinessFence(
        epoch expectedStopEpoch: UInt64,
        allowCleanupPending: Bool
    ) throws {
        guard stopEpoch == expectedStopEpoch,
              !stopInProgress,
              aggregatedStopTarget == nil,
              lifecycle != .shutdown,
              lifecycle != .shutdownPending,
              lifecycle != .suspended,
              lifecycle != .backingOff,
              lifecycle != .terminal,
              allowCleanupPending || lifecycle != .cleanupPending else {
            throw CodexAppServerError.connectionClosed
        }
    }

    private func clearStartTask(token: UUID) {
        guard startToken == token else { return }
        startOperationTask?.cancel()
        startDeadlineTask?.cancel()
        startTask = nil
        startOperationTask = nil
        startDeadlineTask = nil
        startToken = nil
    }

    private func startOperationActuallyCompleted(
        token: UUID,
        completion: AsyncCompletionLatch
    ) {
        guard startOperationOwnerships[token]?.completion === completion else { return }
        startOperationOwnerships.removeValue(forKey: token)
        if startToken == token { startOperationTask = nil }
    }

    private func startupDeadlineReached(generation requestedGeneration: UInt64, token: UUID) async {
        guard startToken == token, generation == requestedGeneration else { return }
        await failSession(
            generation: requestedGeneration,
            error: .initializeTimedOut,
            scheduleRetry: true
        )
    }

    private func startSession(
        generation requestedGeneration: UInt64,
        stopEpoch requestedStopEpoch: UInt64
    ) async throws {
        do {
            try Task.checkCancellation()
            let startedTransport = try await factory.start()
            guard !Task.isCancelled,
                  generation == requestedGeneration,
                  stopEpoch == requestedStopEpoch,
                  !stopInProgress,
                  aggregatedStopTarget == nil,
                  lifecycle == .starting,
                  transport == nil else {
                _ = await retireAndStopTransport(startedTransport)
                throw CancellationError()
            }

            transport = startedTransport
            selectedExecutableURL = startedTransport.executableURL
            startReceiveLoop(transport: startedTransport, generation: requestedGeneration)

            let initializeResponse = try await rpc(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "CodexUsageWidget",
                        "title": "Codex Usage Widget",
                        "version": "1.0.0"
                    ],
                    "capabilities": [String: Any]()
                ],
                timeout: configuration.initializeTimeout,
                timeoutError: .initializeTimedOut,
                generation: requestedGeneration,
                idPrefix: "initialize"
            )
            try validateInitializeResponse(initializeResponse)
            try sendNotification(method: "initialized", generation: requestedGeneration)
            guard generation == requestedGeneration, transport != nil else {
                throw CancellationError()
            }
            lifecycle = .ready
            // A deferred transport cleanup cancels the old timer while it
            // drains ownership. Every successful reconnect restores polling.
            if automaticUpdatesEnabled { ensureReconciliationLoop() }
            scheduleVersionInspectionIfNeeded(for: startedTransport.executableURL)
        } catch is CancellationError {
            await failSession(
                generation: requestedGeneration,
                error: .connectionClosed,
                scheduleRetry: false
            )
            throw CancellationError()
        } catch {
            let normalized = normalize(error)
            await failSession(
                generation: requestedGeneration,
                error: normalized,
                scheduleRetry: shouldAutomaticallyRetry(normalized)
            )
            throw normalized
        }
    }

    private func startReceiveLoop(
        transport startedTransport: any CodexTransport,
        generation startedGeneration: UInt64
    ) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, startedTransport] in
            do {
                for try await event in startedTransport.events {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event: event, generation: startedGeneration)
                }
                await self?.connectionEnded(
                    generation: startedGeneration,
                    error: .connectionClosed
                )
            } catch {
                await self?.connectionEnded(
                    generation: startedGeneration,
                    error: self?.normalize(error) ?? .connectionClosed
                )
            }
        }
    }

    private func receive(event: CodexTransportEvent, generation eventGeneration: UInt64) async {
        guard eventGeneration == generation else { return }
        switch event {
        case .stdoutLine(let line):
            await receive(line: line, generation: eventGeneration)
        case .stdoutClosed, .terminated:
            await connectionEnded(generation: eventGeneration, error: .connectionClosed)
        }
    }

    private func receive(line: Data, generation lineGeneration: UInt64) async {
        guard lineGeneration == generation else { return }
        receivedProtocolLineCount += 1
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line)
        } catch {
            await failSession(generation: lineGeneration, error: .protocolError, scheduleRetry: true)
            return
        }
        guard let root = object as? [String: Any] else {
            await failSession(generation: lineGeneration, error: .protocolError, scheduleRetry: true)
            return
        }

        if let method = root["method"] as? String {
            if method == "account/rateLimits/updated" {
                guard let params = root["params"] as? [String: Any],
                      params["rateLimits"] is [String: Any] else {
                    await failSession(
                        generation: lineGeneration,
                        error: .protocolError,
                        scheduleRetry: true
                    )
                    return
                }
                scheduleNotificationRefresh(generation: lineGeneration)
            } else {
                unknownNotificationCount += 1
            }
            return
        }

        guard let id = Self.strictResponseID(root["id"]) else {
            await failSession(generation: lineGeneration, error: .protocolError, scheduleRetry: true)
            return
        }
        guard pending[id] != nil else {
            unknownResponseIDCount += 1
            return
        }
        finishRPC(id: id, result: .success(line))
    }

    private func validateInitializeResponse(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.protocolError
        }
        if let error = root["error"] as? [String: Any] {
            throw mapRemoteError(error)
        }
        guard let result = root["result"] as? [String: Any],
              let userAgent = result["userAgent"] as? String, !userAgent.isEmpty,
              let codexHome = result["codexHome"] as? String, !codexHome.isEmpty,
              let platformFamily = result["platformFamily"] as? String, !platformFamily.isEmpty,
              let platformOS = result["platformOs"] as? String, !platformOS.isEmpty else {
            throw CodexAppServerError.protocolError
        }
    }

    private func rpc(
        method: String,
        params: Any,
        timeout: Duration,
        timeoutError: CodexAppServerError,
        generation requestGeneration: UInt64,
        idPrefix: String
    ) async throws -> Data {
        guard generation == requestGeneration, let transport,
              lifecycle == .starting || lifecycle == .ready else {
            throw CodexAppServerError.connectionClosed
        }
        nextRequestNumber &+= 1
        let id = "\(idPrefix)-\(nextRequestNumber)"
        let request: [String: Any] = ["id": id, "method": method, "params": params]
        let encoded = try JSONSerialization.data(withJSONObject: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self, sleeper] in
                    do {
                        try await sleeper.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRPC(
                        id: id,
                        generation: requestGeneration,
                        error: timeoutError
                    )
                }
                pending[id] = PendingRPC(continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try transport.send(line: encoded)
                } catch {
                    finishRPC(id: id, result: .failure(CodexAppServerError.connectionClosed))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRPC(id: id, generation: requestGeneration)
            }
        }
    }

    private func sendNotification(method: String, generation requestGeneration: UInt64) throws {
        guard generation == requestGeneration, let transport else {
            throw CodexAppServerError.connectionClosed
        }
        let data = try JSONSerialization.data(withJSONObject: ["method": method])
        try transport.send(line: data)
    }

    nonisolated static func strictResponseID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if let exact = Int64(number.stringValue) { return String(exact) }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              let exact = Int64(exactly: double) else { return nil }
        return String(exact)
    }

    private func finishRPC(id: String, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func timeoutRPC(
        id: String,
        generation requestGeneration: UInt64,
        error: CodexAppServerError
    ) async {
        guard generation == requestGeneration, pending[id] != nil else { return }
        finishRPC(id: id, result: .failure(error))
        await failSession(generation: requestGeneration, error: error, scheduleRetry: true)
    }

    private func cancelRPC(id: String, generation requestGeneration: UInt64) {
        guard generation == requestGeneration else { return }
        finishRPC(id: id, result: .failure(CancellationError()))
    }

    private func scheduleNotificationRefresh(generation eventGeneration: UInt64) {
        guard automaticUpdatesEnabled, generation == eventGeneration else { return }
        notificationTask?.cancel()
        notificationTask = Task { [weak self, sleeper, delay = configuration.notificationDebounce] in
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return
            }
            await self?.notificationDebounceFired(generation: eventGeneration)
        }
    }

    private func notificationDebounceFired(generation eventGeneration: UInt64) {
        guard automaticUpdatesEnabled, generation == eventGeneration,
              lifecycle != .shutdown, lifecycle != .cleanupPending,
              lifecycle != .shutdownPending,
              lifecycle != .suspended else { return }
        notificationTask = nil
        if readTask != nil {
            readAgainAfterCurrent = true
            return
        }
        Task { [weak self] in
            _ = try? await self?.refresh(reason: .notification)
        }
    }

    private func ensureReconciliationLoop() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self, sleeper, interval = configuration.reconciliationInterval] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.reconciliationTick()
            }
        }
    }

    private func reconciliationTick() {
        guard automaticUpdatesEnabled, lifecycle == .ready else { return }
        Task { [weak self] in
            _ = try? await self?.refresh(reason: .reconciliation)
        }
    }

    private func connectionEnded(
        generation endedGeneration: UInt64,
        error: CodexAppServerError
    ) async {
        guard endedGeneration == generation,
              lifecycle != .shutdown, lifecycle != .cleanupPending,
              lifecycle != .shutdownPending,
              lifecycle != .suspended else { return }
        await failSession(generation: endedGeneration, error: error, scheduleRetry: true)
    }

    private func failSession(
        generation failedGeneration: UInt64,
        error: CodexAppServerError,
        scheduleRetry: Bool
    ) async {
        guard generation == failedGeneration else { return }

        failureSerial &+= 1
        generation &+= 1
        let cleanupGeneration = generation
        let ownedTransport = transport
        if let ownedTransport { _ = registerRetiredTransport(ownedTransport) }
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil
        startOperationTask?.cancel()
        startDeadlineTask?.cancel()
        startTask = nil
        startOperationTask = nil
        startDeadlineTask = nil
        startToken = nil
        failAllPending(with: error)
        let transportStopped = await stopAllRetiredTransports()
        // A lifecycle stop can interleave while transport.stop() suspends.
        // Its newer generation and shutdown-pending ownership must win.
        guard generation == cleanupGeneration,
              lifecycle != .shutdown, lifecycle != .cleanupPending,
              lifecycle != .shutdownPending else { return }
        guard transportStopped else {
            lifecycle = .cleanupPending
            recordFailure(error: error)
            deferredConnectionFailure = DeferredConnectionFailure(
                error: error,
                scheduleConnectionRetry: scheduleRetry
            )
            scheduleCleanupRetry()
            return
        }

        if scheduleRetry {
            recordFailure(error: error)
        } else {
            lifecycle = .terminal
            emit(.connectionUnavailable(error, retryIn: nil))
        }
    }

    private func recordFailure(error: CodexAppServerError) {
        consecutiveFailures += 1
        // Connection backoff/circuit state is downstream of transport
        // ownership. A failed stop must remain cleanupPending until its
        // independent retry has released every child and descriptor.
        guard lifecycle != .cleanupPending else { return }
        applyRecordedFailure(error: error)
    }

    private func applyRecordedFailure(error: CodexAppServerError) {
        guard lifecycle != .shutdown, lifecycle != .shutdownPending else { return }
        guard lifecycle != .cleanupPending else { return }
        guard automaticUpdatesEnabled, lifecycle != .suspended else {
            lifecycle = .stopped
            emit(.connectionUnavailable(error, retryIn: nil))
            return
        }

        guard consecutiveFailures < configuration.maximumAutomaticFailures else {
            // Stop rapid retries after a sustained outage, but keep checking
            // transient failures at a low rate so background updates recover
            // without requiring the user to reopen the dashboard.
            switch error {
            case .launchFailed, .initializeTimedOut, .readTimedOut, .connectionClosed:
                let delay = jitter(configuration.slowRecoveryInterval)
                lifecycle = .backingOff
                emit(.connectionUnavailable(error, retryIn: delay))
                scheduleBackoff(delay: delay)
                return
            case .protocolError, .executableNotFound, .executableRejected,
                 .unauthenticated, .automaticRetriesStopped:
                break
            }
            lifecycle = .terminal
            emit(.automaticRetriesStopped)
            return
        }

        let index = min(consecutiveFailures - 1, max(0, configuration.retryDelays.count - 1))
        let base = configuration.retryDelays.isEmpty ? Duration.seconds(30) : configuration.retryDelays[index]
        let delay = jitter(base)
        lifecycle = .backingOff
        emit(.connectionUnavailable(error, retryIn: delay))
        scheduleBackoff(delay: delay)
    }

    private func scheduleCleanupRetry() {
        guard cleanupRetryTask == nil,
              deferredConnectionFailure != nil,
              lifecycle == .cleanupPending,
              lifecycle != .shutdown,
              lifecycle != .shutdownPending else { return }
        let token = UUID()
        cleanupRetryToken = token
        cleanupRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await self?.cleanupRetryFired(token: token)
        }
    }

    private func cleanupRetryFired(token: UUID) async {
        guard cleanupRetryToken == token else { return }
        cleanupRetryTask = nil
        cleanupRetryToken = nil
        guard deferredConnectionFailure != nil,
              lifecycle == .cleanupPending,
              lifecycle != .shutdown,
              lifecycle != .shutdownPending else { return }

        let stopped = await stopCurrentSession(
            nextLifecycle: .stopped,
            reason: CodexAppServerError.connectionClosed,
            preserveDeferredConnectionFailure: true
        )
        guard deferredConnectionFailure != nil else { return }
        if stopped, lifecycle == .stopped {
            let deferred = deferredConnectionFailure
            deferredConnectionFailure = nil
            guard let deferred else { return }
            if deferred.scheduleConnectionRetry {
                applyRecordedFailure(error: deferred.error)
            } else {
                lifecycle = .terminal
                emit(.connectionUnavailable(deferred.error, retryIn: nil))
            }
        } else if lifecycle == .cleanupPending {
            scheduleCleanupRetry()
        }
    }

    private func clearDeferredConnectionFailure() {
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        cleanupRetryToken = nil
        deferredConnectionFailure = nil
    }

    private func scheduleBackoff(delay: Duration) {
        guard backoffTask == nil else { return }
        let token = UUID()
        backoffToken = token
        backoffTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return
            }
            await self?.backoffFired(token: token)
        }
    }

    private func backoffFired(token: UUID) {
        guard backoffToken == token else { return }
        backoffTask = nil
        backoffToken = nil
        guard automaticUpdatesEnabled, lifecycle == .backingOff else { return }
        lifecycle = .stopped
        Task { [weak self] in
            _ = try? await self?.refresh(reason: .recovery)
        }
    }

    private func permitExplicitRetry() {
        if lifecycle == .backingOff || lifecycle == .terminal {
            backoffTask?.cancel()
            backoffTask = nil
            backoffToken = nil
            lifecycle = .stopped
            consecutiveFailures = 0
        }
    }

    private func markSuccessfulRead() {
        consecutiveFailures = 0
        backoffTask?.cancel()
        backoffTask = nil
        backoffToken = nil
    }

    private func stopCurrentSession(
        nextLifecycle: Lifecycle,
        reason: Error,
        preserveDeferredConnectionFailure: Bool = false
    ) async -> Bool {
        if !preserveDeferredConnectionFailure {
            clearDeferredConnectionFailure()
        }
        mergeStopTarget(nextLifecycle)
        if stopInProgress {
            return await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
        }

        stopInProgress = true
        stopEpoch &+= 1
        // This assignment happens before the first await. Every new-work API
        // rejects the state, while concurrent stops join this owner.
        lifecycle = aggregatedStopTarget == .shutdown ? .shutdownPending : .cleanupPending

        notificationTask?.cancel()
        reconcileTask?.cancel()
        backoffTask?.cancel()
        notificationTask = nil
        reconcileTask = nil
        backoffTask = nil
        backoffToken = nil

        startTask?.cancel()
        readTask?.cancel()
        startOperationTask?.cancel()
        for ownership in startOperationOwnerships.values { ownership.task.cancel() }
        startDeadlineTask?.cancel()
        startTask = nil
        startOperationTask = nil
        startDeadlineTask = nil
        startToken = nil
        readTask = nil
        readToken = nil
        readAgainAfterCurrent = false

        let waiters = readWaiters.values
        readWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(throwing: reason)
        }

        generation &+= 1
        let ownedTransport = transport
        if let ownedTransport { _ = registerRetiredTransport(ownedTransport) }
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil
        failAllPending(with: reason)

        var attemptedRetiredTransportIDs = Set<ObjectIdentifier>()
        _ = await cancelVersionInspection()
        let ownershipDeadline = ContinuousClock.now + .milliseconds(250)
        _ = await waitForStartOperationsToStop(until: ownershipDeadline)
        captureLateActiveTransportForStop()
        attemptedRetiredTransportIDs = await stopUnattemptedRetiredTransports(
            attemptedRetiredTransportIDs
        )

        if let hook = teardownRaceHooksForTesting?.stopBeforeStableStateVerification {
            await hook()
        }

        // An actor can be re-entered at every await above. Drain anything a
        // pre-stop factory/start continuation registered late, then decide
        // success from the current owned state in one actor-isolated step.
        // Never publish shutdown from booleans captured before those awaits.
        for _ in 0..<3 {
            captureLateActiveTransportForStop()
            if !startOperationOwnerships.isEmpty {
                _ = await waitForStartOperationsToStop(until: ownershipDeadline)
                continue
            }
            if retiredTransports.keys.contains(where: {
                !attemptedRetiredTransportIDs.contains($0)
            }) {
                attemptedRetiredTransportIDs = await stopUnattemptedRetiredTransports(
                    attemptedRetiredTransportIDs
                )
                continue
            }
            break
        }
        captureLateActiveTransportForStop()
        discardConfirmedVersionInspectionOwnership()
        let teardownConfirmed = startOperationOwnerships.isEmpty
            && retiredTransports.isEmpty
            && transport == nil
            && versionInspectionProbe == nil

        let finalTarget = aggregatedStopTarget ?? nextLifecycle
        lifecycle = teardownConfirmed
            ? finalTarget
            : (finalTarget == .shutdown ? .shutdownPending : .cleanupPending)
        aggregatedStopTarget = nil
        stopInProgress = false
        let joinedWaiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in joinedWaiters {
            waiter.resume(returning: teardownConfirmed)
        }
        return teardownConfirmed
    }

    private func captureLateActiveTransportForStop() {
        guard let lateTransport = transport else { return }
        _ = registerRetiredTransport(lateTransport)
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func discardConfirmedVersionInspectionOwnership() {
        guard versionInspectionProbe?.teardownConfirmed != false else { return }
        versionInspectionTask = nil
        versionInspectionProbe = nil
        versionInspectionResult = nil
    }

    private func mergeStopTarget(_ requestedTarget: Lifecycle) {
        guard let currentTarget = aggregatedStopTarget else {
            aggregatedStopTarget = requestedTarget
            return
        }
        if currentTarget == .shutdown || requestedTarget == .shutdown {
            aggregatedStopTarget = .shutdown
        } else if currentTarget == .suspended || requestedTarget == .suspended {
            aggregatedStopTarget = .suspended
        } else {
            aggregatedStopTarget = .stopped
        }
    }

    private func waitForStartOperationsToStop(
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let snapshot = startOperationOwnerships
        for ownership in snapshot.values {
            ownership.task.cancel()
            _ = await ownership.completion.wait(until: deadline)
        }
        for (token, ownership) in snapshot where ownership.completion.isCompleted {
            guard startOperationOwnerships[token]?.completion === ownership.completion else {
                continue
            }
            startOperationOwnerships.removeValue(forKey: token)
        }
        return startOperationOwnerships.isEmpty
    }

    @discardableResult
    private func registerRetiredTransport(
        _ ownedTransport: any CodexTransport
    ) -> ObjectIdentifier {
        let id = ObjectIdentifier(ownedTransport)
        if retiredTransports[id] == nil {
            retiredTransports[id] = RetiredTransportOwnership(
                transport: ownedTransport,
                stopAttemptToken: nil,
                stopTask: nil
            )
        }
        return id
    }

    private func retireAndStopTransport(_ ownedTransport: any CodexTransport) async -> Bool {
        await stopRetiredTransport(registerRetiredTransport(ownedTransport))
    }

    private func stopAllRetiredTransports() async -> Bool {
        _ = await stopUnattemptedRetiredTransports([])
        return retiredTransports.isEmpty
    }

    private func stopUnattemptedRetiredTransports(
        _ alreadyAttempted: Set<ObjectIdentifier>
    ) async -> Set<ObjectIdentifier> {
        var attempted = alreadyAttempted
        while let id = retiredTransports.keys.first(where: { !attempted.contains($0) }) {
            attempted.insert(id)
            _ = await stopRetiredTransport(id)
        }
        return attempted
    }

    private func stopRetiredTransport(_ id: ObjectIdentifier) async -> Bool {
        guard var ownership = retiredTransports[id] else { return true }
        let attemptToken: UUID
        let stopTask: Task<Bool, Never>
        if let existingToken = ownership.stopAttemptToken,
           let existingTask = ownership.stopTask {
            attemptToken = existingToken
            stopTask = existingTask
        } else {
            attemptToken = UUID()
            let ownedTransport = ownership.transport
            stopTask = Task.detached(priority: .utility) {
                await ownedTransport.stop()
            }
            ownership.stopAttemptToken = attemptToken
            ownership.stopTask = stopTask
            retiredTransports[id] = ownership
        }

        let stopped = await stopTask.value
        guard retiredTransports[id]?.stopAttemptToken == attemptToken else {
            return retiredTransports[id] == nil
        }
        if stopped {
            retiredTransports.removeValue(forKey: id)
        } else {
            retiredTransports[id]?.stopAttemptToken = nil
            retiredTransports[id]?.stopTask = nil
        }
        return stopped
    }

    private func failAllPending(with error: Error) {
        let outstanding = pending.values
        pending.removeAll(keepingCapacity: true)
        for request in outstanding {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func mapParserError(_ error: RateLimitsParserError) -> CodexAppServerError {
        if case .serverError(let message) = error {
            return isAuthenticationMessage(message) ? .unauthenticated : .connectionClosed
        }
        return .protocolError
    }

    private func mapRemoteError(_ error: [String: Any]) -> CodexAppServerError {
        let message = error["message"] as? String ?? ""
        return isAuthenticationMessage(message) ? .unauthenticated : .protocolError
    }

    private func isAuthenticationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["auth", "login", "logged in", "sign in", "unauthorized", "credential"].contains {
            normalized.contains($0)
        }
    }

    private func normalize(_ error: Error) -> CodexAppServerError {
        if let error = error as? CodexAppServerError { return error }
        if error is CodexTransportError { return .connectionClosed }
        return .connectionClosed
    }

    private func shouldAutomaticallyRetry(_ error: CodexAppServerError) -> Bool {
        switch error {
        case .launchFailed, .initializeTimedOut, .readTimedOut, .connectionClosed, .protocolError:
            true
        case .executableNotFound, .executableRejected,
             .unauthenticated, .automaticRetriesStopped:
            false
        }
    }

    private func emit(_ event: BrokerEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func scheduleVersionInspectionIfNeeded(for url: URL) {
        guard versionInspectionCompletedForURL != url,
              versionInspectionTask == nil,
              versionInspectionProbe == nil else { return }
        let probe = CodexBinaryInspector.Probe(
            executableURL: url,
            handlerDeliveryDelay: versionInspectionHandlerDelayForTesting,
            suppressSynchronousExitObservation:
                suppressSynchronousVersionExitObservationForTesting
        )
        let result = CodexBinaryInspector.ResultBox()
        versionInspectionProbe = probe
        versionInspectionResult = result
        versionInspectionTask = Task {
            let version = await probe.version()
            result.complete(url: url, version: version)
        }
    }

    private func consumeVersionInspectionResult() {
        guard let completed = versionInspectionResult?.completedValue else { return }
        // A timed-out probe keeps owning its Process/PID until the late
        // termination delivery confirms teardown. Do not let a diagnostics
        // read discard that ownership.
        guard versionInspectionProbe?.teardownConfirmed != false else { return }
        if selectedExecutableURL == completed.url {
            selectedExecutableVersion = completed.version
            versionInspectionCompletedForURL = completed.url
        }
        versionInspectionTask = nil
        versionInspectionProbe = nil
        versionInspectionResult = nil
    }

    private func cancelVersionInspection() async -> Bool {
        guard let probe = versionInspectionProbe else { return true }
        probe.cancel()
        guard let task = versionInspectionTask,
              let result = versionInspectionResult else {
            let confirmed = await probe.waitForTeardown(
                until: ContinuousClock.now + .milliseconds(250)
            )
            if confirmed { versionInspectionProbe = nil }
            return confirmed
        }
        task.cancel()
        await task.value
        guard versionInspectionResult === result else { return true }
        let confirmed = await probe.waitForTeardown(
            until: ContinuousClock.now + .milliseconds(250)
        )
        versionInspectionTask = nil
        versionInspectionResult = nil
        if confirmed { versionInspectionProbe = nil }
        return confirmed
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private static func randomJitter(_ duration: Duration) -> Duration {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let factor = Double.random(in: 0.8...1.2)
        return .milliseconds(Int64(max(1, seconds * factor * 1_000)))
    }
}

public typealias CodexAppServerClient = CodexAppServerBroker

private protocol CodexExecutableResolving: Sendable {
    func resolve() async -> Result<URL, CodexAppServerError>
}

private struct FixedCodexExecutableResolver: CodexExecutableResolving, Sendable {
    let url: URL

    func resolve() async -> Result<URL, CodexAppServerError> {
        if let validated = CodexExecutableResolver.validatedExecutable(path: url.path) {
            return .success(validated)
        }
        return .failure(.executableRejected)
    }
}

struct CodexExecutableResolver: CodexExecutableResolving, Sendable {
    func resolve() async -> Result<URL, CodexAppServerError> {
        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = []

        let applicationURLs = await MainActor.run {
            ["com.openai.codex", "com.openai.chat"].compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
        }
        for applicationURL in applicationURLs {
            paths.append(contentsOf: Self.applicationExecutablePaths(at: applicationURL))
        }

        if let override = environment["CODEX_USAGE_CODEX_PATH"], !override.isEmpty {
            paths.append(override)
        }
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for directory in applicationDirectories {
            for name in ["ChatGPT.app", "Codex.app"] {
                paths.append(contentsOf: Self.applicationExecutablePaths(
                    at: directory.appendingPathComponent(name, isDirectory: true)
                ))
            }
        }
        paths.append(contentsOf: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        return Self.resolveCandidates(paths)
    }

    static func applicationExecutablePaths(at applicationURL: URL) -> [String] {
        // Current desktop releases embed the native CLI in its own app bundle.
        // Use the binary directly rather than the adjacent bin/codex shell shim.
        [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex"
        ].map { applicationURL.appendingPathComponent($0, isDirectory: false).path }
    }

    static func resolveCandidates(_ paths: [String]) -> Result<URL, CodexAppServerError> {
        var sawExistingRejectedCandidate = false
        for path in paths {
            if let validated = Self.validatedExecutable(path: path) {
                return .success(validated)
            }
            if FileManager.default.fileExists(atPath: path) {
                sawExistingRejectedCandidate = true
            }
        }
        return .failure(sawExistingRejectedCandidate ? .executableRejected : .executableNotFound)
    }

    static func validatedExecutable(path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let manager = FileManager.default
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        let originalPath = originalURL.path
        guard !originalPath.contains("/Library/Group Containers/"),
              !originalPath.contains("/Library/Containers/") else { return nil }
        let originalParentPath = originalURL.deletingLastPathComponent().path
        guard let originalParentAttributes = try? manager.attributesOfItem(atPath: originalParentPath),
              (originalParentAttributes[.type] as? FileAttributeType) == .typeDirectory,
              let originalParentPermissions = (originalParentAttributes[.posixPermissions] as? NSNumber)?.intValue,
              originalParentPermissions & 0o022 == 0 else { return nil }

        let url = originalURL.resolvingSymlinksInPath()
        let resolvedPath = url.path

        guard !resolvedPath.contains("/Library/Group Containers/"),
              !resolvedPath.contains("/Library/Containers/") else { return nil }

        guard let attributes = try? manager.attributesOfItem(atPath: resolvedPath),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              manager.isExecutableFile(atPath: resolvedPath),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o022 == 0 else { return nil }

        let parentPath = url.deletingLastPathComponent().path
        guard let parentAttributes = try? manager.attributesOfItem(atPath: parentPath),
              (parentAttributes[.type] as? FileAttributeType) == .typeDirectory,
              let parentPermissions = (parentAttributes[.posixPermissions] as? NSNumber)?.intValue,
              parentPermissions & 0o022 == 0 else { return nil }
        return url
    }
}

private struct ProcessCodexTransportFactory: CodexTransportFactory, Sendable {
    let resolver: any CodexExecutableResolving

    func start() async throws -> any CodexTransport {
        switch await resolver.resolve() {
        case .success(let executableURL):
            return try CodexProcessTransport.start(
                executableURL: executableURL,
                arguments: ["app-server", "--listen", "stdio://"]
            )
        case .failure(let error):
            throw error
        }
    }
}

private enum CodexBinaryInspector {
    struct CompletedValue: Sendable {
        let url: URL
        let version: String?
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: CompletedValue?
        var completedValue: CompletedValue? { lock.withLock { storage } }
        func complete(url: URL, version: String?) {
            lock.withLock { storage = CompletedValue(url: url, version: version) }
        }
    }

    final class Probe: @unchecked Sendable {
        private enum OutputResult: Sendable {
            case data(Data)
            case oversized
            case failed
        }

        private enum NonblockingReadResult {
            case data(Data)
            case wouldBlock
            case endOfFile
            case failed
        }

        private final class LifecycleState: @unchecked Sendable {
            private let lock = NSLock()
            private var launched = false
            private var exited = false
            private var cleanupCompleted = false
            private var cancellationRequested = false
            private var ownedPID: Int32?

            var processIdentifier: Int32? {
                lock.withLock {
                    guard launched, !exited, !cleanupCompleted else { return nil }
                    return ownedPID
                }
            }

            var isCancellationRequested: Bool {
                lock.withLock { cancellationRequested }
            }

            var isCleanupCompleted: Bool {
                lock.withLock { cleanupCompleted }
            }

            func requestCancellation() -> Int32? {
                lock.withLock {
                    cancellationRequested = true
                    guard launched, !exited, !cleanupCompleted else { return nil }
                    return ownedPID
                }
            }

            func didLaunch(processIdentifier: Int32) -> Bool {
                lock.withLock {
                    ownedPID = processIdentifier > 0 ? processIdentifier : nil
                    launched = ownedPID != nil && !exited && !cleanupCompleted
                    return cancellationRequested && launched
                }
            }

            func didExit() {
                lock.withLock {
                    exited = true
                    launched = false
                }
            }

            func runningProcessIdentifier() -> Int32? {
                lock.withLock {
                    guard launched, !exited, !cleanupCompleted else { return nil }
                    return ownedPID
                }
            }

            func completeCleanup() {
                lock.withLock {
                    cleanupCompleted = true
                    launched = false
                    ownedPID = nil
                }
            }
        }

        private final class ExitLatch: @unchecked Sendable {
            private struct Waiter {
                let continuation: CheckedContinuation<Int32?, Never>
                let interruptible: Bool
                var deadlineTask: Task<Void, Never>?
            }

            private enum Registration {
                case registered
                case immediate(Int32?)
            }

            private let lock = NSLock()
            private var terminationStatus: Int32?
            private var exitConfirmed = false
            private var interrupted = false
            private var waiters: [UUID: Waiter] = [:]

            var status: Int32? { lock.withLock { terminationStatus } }
            var isExitConfirmed: Bool { lock.withLock { exitConfirmed } }

            func complete(status: Int32) {
                let ownedWaiters = lock.withLock { () -> [Waiter] in
                    guard !exitConfirmed else { return [] }
                    exitConfirmed = true
                    terminationStatus = status
                    let values = Array(waiters.values)
                    waiters.removeAll(keepingCapacity: false)
                    return values
                }
                for waiter in ownedWaiters {
                    waiter.deadlineTask?.cancel()
                    waiter.continuation.resume(returning: status)
                }
            }

            func interrupt() {
                let ownedWaiters = lock.withLock { () -> [Waiter] in
                    interrupted = true
                    let interruptedIDs = waiters.compactMap { entry in
                        entry.value.interruptible ? entry.key : nil
                    }
                    return interruptedIDs.compactMap { waiters.removeValue(forKey: $0) }
                }
                for waiter in ownedWaiters {
                    waiter.deadlineTask?.cancel()
                    waiter.continuation.resume(returning: nil)
                }
            }

            func wait(
                until deadline: ContinuousClock.Instant,
                interruptible: Bool
            ) async -> Int32? {
                let id = UUID()
                if interruptible {
                    return await withTaskCancellationHandler {
                        await registerWaiter(id: id, until: deadline, interruptible: true)
                    } onCancel: { [weak self] in
                        self?.resolveWaiter(id: id, status: nil)
                    }
                }
                return await registerWaiter(id: id, until: deadline, interruptible: false)
            }

            private func registerWaiter(
                id: UUID,
                until deadline: ContinuousClock.Instant,
                interruptible: Bool
            ) async -> Int32? {
                await withCheckedContinuation { continuation in
                    let registration = lock.withLock { () -> Registration in
                        if exitConfirmed { return .immediate(terminationStatus) }
                        if ContinuousClock.now >= deadline
                            || (interruptible && (interrupted || Task.isCancelled)) {
                            return .immediate(nil)
                        }
                        waiters[id] = Waiter(
                            continuation: continuation,
                            interruptible: interruptible,
                            deadlineTask: nil
                        )
                        return .registered
                    }

                    switch registration {
                    case .immediate(let status):
                        continuation.resume(returning: status)
                    case .registered:
                        let deadlineTask = Task.detached(priority: .utility) { [weak self] in
                            do {
                                try await Task.sleep(until: deadline, clock: .continuous)
                            } catch {
                                return
                            }
                            self?.resolveWaiter(id: id, status: nil)
                        }
                        let attached = lock.withLock { () -> Bool in
                            guard var waiter = waiters[id] else { return false }
                            waiter.deadlineTask = deadlineTask
                            waiters[id] = waiter
                            return true
                        }
                        if !attached { deadlineTask.cancel() }
                    }
                }
            }

            private func resolveWaiter(id: UUID, status: Int32?) {
                let waiter = lock.withLock { waiters.removeValue(forKey: id) }
                guard let waiter else { return }
                waiter.deadlineTask?.cancel()
                waiter.continuation.resume(returning: status)
            }
        }

        let executableURL: URL
        private let process = Process()
        private let outputPipe = Pipe()
        private let state = LifecycleState()
        private let exitLatch = ExitLatch()
        private let handlerDeliveryDelay: Duration
        private let suppressSynchronousExitObservation: Bool

        private static let maximumOutputBytes = 4_096
        private static let normalExitDeadline: Duration = .seconds(2)
        private static let terminationGrace: Duration = .milliseconds(250)
        private static let killGrace: Duration = .milliseconds(250)
        private static let outputPollInterval: Duration = .milliseconds(5)
        private static let maximumReadsPerPass = 64

        init(
            executableURL: URL,
            handlerDeliveryDelay: Duration = .zero,
            suppressSynchronousExitObservation: Bool = false
        ) {
            self.executableURL = executableURL
            self.handlerDeliveryDelay = handlerDeliveryDelay
            self.suppressSynchronousExitObservation = suppressSynchronousExitObservation
            process.executableURL = executableURL
            process.arguments = ["--version"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
        }

        var processIdentifier: Int32? {
            state.processIdentifier
        }

        var teardownConfirmed: Bool {
            state.isCleanupCompleted || exitLatch.isExitConfirmed
        }

        func cancel() {
            let processIdentifier = state.requestCancellation()
            exitLatch.interrupt()
            if let processIdentifier { Self.signal(SIGTERM, processIdentifier: processIdentifier) }
        }

        func waitForTeardown(until deadline: ContinuousClock.Instant) async -> Bool {
            if state.isCleanupCompleted { return true }
            if !exitLatch.isExitConfirmed {
                _ = await exitLatch.wait(until: deadline, interruptible: false)
            }
            guard exitLatch.isExitConfirmed else { return false }
            process.terminationHandler = nil
            state.completeCleanup()
            return true
        }

        func version() async -> String? {
            let readHandle = outputPipe.fileHandleForReading
            let writeHandle = outputPipe.fileHandleForWriting
            do {
                try TransportWakePipe.configureNonblocking(
                    readHandle.fileDescriptor,
                    suppressSIGPIPE: false
                )
            } catch {
                try? writeHandle.close()
                try? readHandle.close()
                exitLatch.complete(status: -1)
                state.completeCleanup()
                return nil
            }

            process.terminationHandler = { [state, exitLatch, handlerDeliveryDelay] terminatedProcess in
                let status = terminatedProcess.terminationStatus
                let deliver = {
                    state.didExit()
                    exitLatch.complete(status: status)
                }
                if handlerDeliveryDelay > .zero {
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(for: handlerDeliveryDelay)
                        deliver()
                    }
                } else {
                    deliver()
                }
            }

            guard !Task.isCancelled, !state.isCancellationRequested else {
                process.terminationHandler = nil
                try? writeHandle.close()
                try? readHandle.close()
                exitLatch.complete(status: -1)
                state.completeCleanup()
                return nil
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? writeHandle.close()
                try? readHandle.close()
                exitLatch.complete(status: -1)
                state.completeCleanup()
                return nil
            }

            let launchedAt = ContinuousClock.now
            let processIdentifier = process.processIdentifier
            let cancelAfterLaunch = state.didLaunch(processIdentifier: processIdentifier)
            // This is the parent's copy. Closing it is necessary for normal EOF,
            // but the reader never relies on EOF because descendants can inherit
            // the child's stdout descriptor.
            try? writeHandle.close()

            let outputDeadline = launchedAt
                + Self.normalExitDeadline
                + Self.terminationGrace
                + Self.killGrace
                + .milliseconds(100)
            let readDescriptor = readHandle.fileDescriptor
            let outputTask = Task.detached(priority: .utility) { [exitLatch] in
                await Self.readBoundedOutput(
                    descriptor: readDescriptor,
                    exitLatch: exitLatch,
                    deadline: outputDeadline
                )
            }

            var terminationStatus: Int32?
            if cancelAfterLaunch || Task.isCancelled {
                _ = state.requestCancellation()
            } else {
                terminationStatus = await exitLatch.wait(
                    until: launchedAt + Self.normalExitDeadline,
                    interruptible: true
                )
            }

            if terminationStatus == nil {
                _ = state.requestCancellation()
                if let runningPID = state.runningProcessIdentifier() {
                    Self.signal(SIGTERM, processIdentifier: runningPID)
                }
                terminationStatus = await exitLatch.wait(
                    until: ContinuousClock.now + Self.terminationGrace,
                    interruptible: false
                )
            }

            if terminationStatus == nil {
                if let runningPID = state.runningProcessIdentifier() {
                    Self.signal(SIGKILL, processIdentifier: runningPID)
                }
                terminationStatus = await exitLatch.wait(
                    until: ContinuousClock.now + Self.killGrace,
                    interruptible: false
                )
            }

            // Foundation.Process remains the sole reaper. If its state has
            // already observed exit but handler delivery is late, complete the
            // same latch from terminationStatus without calling waitpid.
            if terminationStatus == nil,
               !suppressSynchronousExitObservation,
               !process.isRunning {
                terminationStatus = process.terminationStatus
                state.didExit()
                exitLatch.complete(status: terminationStatus ?? -1)
            }

            let exitConfirmed = exitLatch.isExitConfirmed
            if !exitConfirmed { outputTask.cancel() }
            let output = await outputTask.value
            try? readHandle.close()
            if exitConfirmed {
                process.terminationHandler = nil
                state.completeCleanup()
            }

            guard terminationStatus == 0,
                  case .data(let data) = output else { return nil }
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private static func signal(_ signal: Int32, processIdentifier: Int32) {
            guard processIdentifier > 0 else { return }
            _ = Darwin.kill(processIdentifier, signal)
        }

        private static func readBoundedOutput(
            descriptor: Int32,
            exitLatch: ExitLatch,
            deadline: ContinuousClock.Instant
        ) async -> OutputResult {
            var data = Data()
            var oversized = false

            while ContinuousClock.now < deadline, !Task.isCancelled {
                var reachedEnd = false
                for _ in 0..<maximumReadsPerPass {
                    let maximumCount = oversized
                        ? 4_096
                        : maximumOutputBytes + 1 - data.count
                    switch readNonblocking(
                        descriptor: descriptor,
                        maximumCount: max(1, maximumCount)
                    ) {
                    case .data(let chunk):
                        if !oversized {
                            data.append(chunk)
                            oversized = data.count > maximumOutputBytes
                        }
                    case .wouldBlock:
                        reachedEnd = true
                    case .endOfFile:
                        return oversized ? .oversized : .data(data)
                    case .failed:
                        return .failed
                    }
                    if reachedEnd { break }
                }

                if exitLatch.isExitConfirmed {
                    // Drain what was already buffered, then finish even if an
                    // inherited writer keeps the pipe permanently open.
                    for _ in 0..<maximumReadsPerPass {
                        let maximumCount = oversized
                            ? 4_096
                            : maximumOutputBytes + 1 - data.count
                        switch readNonblocking(
                            descriptor: descriptor,
                            maximumCount: max(1, maximumCount)
                        ) {
                        case .data(let chunk):
                            if !oversized {
                                data.append(chunk)
                                oversized = data.count > maximumOutputBytes
                            }
                        case .wouldBlock, .endOfFile:
                            return oversized ? .oversized : .data(data)
                        case .failed:
                            return .failed
                        }
                    }
                    return oversized ? .oversized : .data(data)
                }

                do {
                    try await Task.sleep(for: outputPollInterval)
                } catch {
                    return .failed
                }
            }
            return .failed
        }

        private static func readNonblocking(
            descriptor: Int32,
            maximumCount: Int
        ) -> NonblockingReadResult {
            var bytes = [UInt8](repeating: 0, count: maximumCount)
            while true {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count > 0 { return .data(Data(bytes.prefix(count))) }
                if count == 0 { return .endOfFile }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
                return .failed
            }
        }
    }
}

enum CodexTransportError: Error, Sendable, Equatable {
    case writeAfterStop
    case inputBackpressure
    case outputBackpressure
    case outputLineTooLarge
    case incompleteOutputLine
    case teardownTimedOut
}

private actor TransportStopOnce {
    private enum State {
        case idle
        case running(UUID, Task<Bool, Never>)
        case doneSuccess
    }

    private var state = State.idle

    func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        switch state {
        case .doneSuccess:
            return true
        case .running(let token, let task):
            let result = await task.value
            completeAttempt(token: token, result: result)
            return result
        case .idle:
            let token = UUID()
            let task = Task.detached(priority: .utility) { await operation() }
            state = .running(token, task)
            let result = await task.value
            completeAttempt(token: token, result: result)
            return result
        }
    }

    private func completeAttempt(token: UUID, result: Bool) {
        guard case .running(let activeToken, _) = state,
              activeToken == token else { return }
        state = result ? .doneSuccess : .idle
    }
}

private final class TransportWakePipe: @unchecked Sendable {
    private let lock = NSLock()
    private let readFD: Int32
    private let writeFD: Int32
    private var closed = false

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw Self.currentPOSIXError() }
        readFD = descriptors[0]
        writeFD = descriptors[1]
        do {
            try Self.configureNonblocking(readFD, suppressSIGPIPE: false)
            try Self.configureNonblocking(writeFD, suppressSIGPIPE: true)
        } catch {
            Darwin.close(readFD)
            Darwin.close(writeFD)
            throw error
        }
    }

    deinit { close() }

    var readDescriptor: Int32 { readFD }

    func signal() {
        lock.withLock {
            guard !closed else { return }
            var byte: UInt8 = 1
            _ = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(writeFD, pointer, 1)
            }
        }
    }

    func drain() {
        lock.withLock {
            guard !closed else { return }
            var bytes = [UInt8](repeating: 0, count: 64)
            while true {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(readFD, buffer.baseAddress, buffer.count)
                }
                if count > 0 { continue }
                if count < 0, errno == EINTR { continue }
                return
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(readFD)
            Darwin.close(writeFD)
        }
    }

    static func configureNonblocking(_ descriptor: Int32, suppressSIGPIPE: Bool) throws {
        let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) >= 0 else {
            throw currentPOSIXError()
        }
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
            throw currentPOSIXError()
        }
        if suppressSIGPIPE,
           Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0 {
            throw currentPOSIXError()
        }
    }

    static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Direct Process transport with bounded JSONL framing and single-owner teardown.
final class CodexProcessTransport: CodexTransport, @unchecked Sendable {
    nonisolated let events: AsyncThrowingStream<CodexTransportEvent, Error>
    nonisolated let executableURL: URL

    private enum ReadResult {
        case data(Data)
        case wouldBlock
        case endOfFile
    }

    private struct PollResult {
        let dataReady: Bool
        let wakeReady: Bool
    }

    private let continuation: AsyncThrowingStream<CodexTransportEvent, Error>.Continuation
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputWake: TransportWakePipe
    private let stdoutWake: TransportWakePipe
    private let stderrWake: TransportWakePipe
    private let stopOnce = TransportStopOnce()
    private let stateLock = NSLock()
    private let eventLock = NSLock()
    private let writeLock = NSLock()
    private let readerGroup = DispatchGroup()
    private let stdoutQueue = DispatchQueue(label: "CodexUsage.stdout", qos: .utility)
    private let stderrQueue = DispatchQueue(label: "CodexUsage.stderr", qos: .utility)
    private let terminationHandlerDeliveryDelayForTesting: Duration
    private let suppressSynchronousExitObservationForTesting: Bool
    private let processSignalForTesting: @Sendable (Int32, Int32) -> Int32
    private let readerExitHookForTesting: (@Sendable () -> Void)?

    private var stopping = false
    private var cleanupCompleted = false
    private var launched = false
    private var ownedPID: Int32?
    private var exitObserved = false
    private var readerShutdownRequested = false
    private var observedTerminationStatus: Int32?
    private var stderrByteCount = 0
    private var activeReaderCount = 0
    private var activeSendCount = 0
    private var cleanupExecutionCount = 0
    private var forcedKillCount = 0
    private var streamFinished = false
    private var terminalCompletionCount = 0

    private static let maximumLineBytes = 1_048_576
    private static let maximumOutboundLineBytes = 65_536
    private static let maximumBufferedEvents = 8
    private static let maximumDiagnosticByteCount = 65_536
    private static let sendDeadline: Duration = .seconds(1)
    private static let pollSliceMilliseconds: Int32 = 100

    private init(
        executableURL: URL,
        terminationHandlerDeliveryDelayForTesting: Duration,
        suppressSynchronousExitObservationForTesting: Bool,
        processSignalForTesting: @escaping @Sendable (Int32, Int32) -> Int32,
        readerExitHookForTesting: (@Sendable () -> Void)?
    ) throws {
        self.executableURL = executableURL
        self.terminationHandlerDeliveryDelayForTesting =
            terminationHandlerDeliveryDelayForTesting
        self.suppressSynchronousExitObservationForTesting =
            suppressSynchronousExitObservationForTesting
        self.processSignalForTesting = processSignalForTesting
        self.readerExitHookForTesting = readerExitHookForTesting
        inputWake = try TransportWakePipe()
        stdoutWake = try TransportWakePipe()
        stderrWake = try TransportWakePipe()
        let pair = AsyncThrowingStream<CodexTransportEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedEvents)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    nonisolated var processIdentifier: Int32? {
        stateLock.withLock { launched ? ownedPID : nil }
    }

    var cleanupExecutionCountForTesting: Int {
        stateLock.withLock { cleanupExecutionCount }
    }

    var forcedKillCountForTesting: Int {
        stateLock.withLock { forcedKillCount }
    }

    var activeReaderCountForTesting: Int {
        stateLock.withLock { activeReaderCount }
    }

    var activeSendCountForTesting: Int {
        stateLock.withLock { activeSendCount }
    }

    var terminalCompletionCountForTesting: Int {
        eventLock.withLock { terminalCompletionCount }
    }

    static func start(
        executableURL: URL,
        arguments: [String],
        terminationHandlerDeliveryDelayForTesting: Duration = .zero,
        suppressSynchronousExitObservationForTesting: Bool = false,
        processSignalForTesting: @escaping @Sendable (Int32, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        },
        readerExitHookForTesting: (@Sendable () -> Void)? = nil
    ) throws -> CodexProcessTransport {
        do {
            let transport = try CodexProcessTransport(
                executableURL: executableURL,
                terminationHandlerDeliveryDelayForTesting:
                    terminationHandlerDeliveryDelayForTesting,
                suppressSynchronousExitObservationForTesting:
                    suppressSynchronousExitObservationForTesting,
                processSignalForTesting: processSignalForTesting,
                readerExitHookForTesting: readerExitHookForTesting
            )
            do {
                try transport.launch(arguments: arguments)
                return transport
            } catch {
                transport.cleanupAfterLaunchFailure(error: error)
                throw CodexAppServerError.launchFailed
            }
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.launchFailed
        }
    }

    private func launch(arguments: [String]) throws {
        try TransportWakePipe.configureNonblocking(
            inputPipe.fileHandleForWriting.fileDescriptor,
            suppressSIGPIPE: true
        )
        try TransportWakePipe.configureNonblocking(
            outputPipe.fileHandleForReading.fileDescriptor,
            suppressSIGPIPE: false
        )
        try TransportWakePipe.configureNonblocking(
            errorPipe.fileHandleForReading.fileDescriptor,
            suppressSIGPIPE: false
        )

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        readerGroup.enter()
        readerGroup.enter()
        process.terminationHandler = { [weak self, terminationHandlerDeliveryDelayForTesting] process in
            let status = process.terminationStatus
            if terminationHandlerDeliveryDelayForTesting > .zero {
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: terminationHandlerDeliveryDelayForTesting)
                    self?.recordProcessTermination(status: status)
                }
            } else {
                self?.recordProcessTermination(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            readerGroup.leave()
            readerGroup.leave()
            throw error
        }
        stateLock.withLock {
            launched = true
            ownedPID = process.processIdentifier
            activeReaderCount = 2
        }

        // Parent-only ends. Each reader owns and closes its own data handle.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        stdoutQueue.async { [self] in
            defer {
                readerExitHookForTesting?()
                try? outputPipe.fileHandleForReading.close()
                stateLock.withLock { activeReaderCount -= 1 }
                readerGroup.leave()
            }
            readStdout()
        }
        stderrQueue.async { [self] in
            defer {
                readerExitHookForTesting?()
                try? errorPipe.fileHandleForReading.close()
                stateLock.withLock { activeReaderCount -= 1 }
                readerGroup.leave()
            }
            drainStderr()
        }

    }

    func send(line: Data) throws {
        guard line.count <= Self.maximumOutboundLineBytes else {
            throw CodexTransportError.outputLineTooLarge
        }
        var framed = line
        if framed.last != 0x0A { framed.append(0x0A) }

        try writeLock.withLock {
            guard canWrite else { throw CodexTransportError.writeAfterStop }
            stateLock.withLock { activeSendCount += 1 }
            defer { stateLock.withLock { activeSendCount -= 1 } }
            let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
            let deadline = ContinuousClock.now + Self.sendDeadline
            try framed.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    guard canWrite else { throw CodexTransportError.writeAfterStop }
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR { continue }
                    if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try waitUntilWritable(
                            descriptor: descriptor,
                            deadline: deadline
                        )
                        continue
                    }
                    throw TransportWakePipe.currentPOSIXError()
                }
            }
        }
    }

    func stop() async -> Bool {
        requestStopFlagAndWake()
        return await stopOnce.run { [self] in await performStopOnce() }
    }

    private var canWrite: Bool {
        stateLock.withLock { launched && !stopping && !exitObserved && !cleanupCompleted }
    }

    private func waitUntilWritable(
        descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        while ContinuousClock.now < deadline {
            guard canWrite else { throw CodexTransportError.writeAfterStop }
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: inputWake.readDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), Self.pollSliceMilliseconds)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw TransportWakePipe.currentPOSIXError()
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                inputWake.drain()
                guard canWrite else { throw CodexTransportError.writeAfterStop }
            }
            if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw POSIXError(.EPIPE)
            }
            if descriptors[0].revents & Int16(POLLOUT) != 0 { return }
        }
        throw CodexTransportError.inputBackpressure
    }

    private func readStdout() {
        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        var buffer = Data()
        do {
            while true {
                let readiness = try pollForData(
                    dataDescriptor: descriptor,
                    wake: stdoutWake
                )
                if readiness.dataReady {
                    if try drainStdout(descriptor: descriptor, buffer: &buffer) { return }
                }
                if readiness.wakeReady { stdoutWake.drain() }
                if shouldReaderStop {
                    _ = try drainStdout(
                        descriptor: descriptor,
                        buffer: &buffer,
                        maximumChunks: 16
                    )
                    return
                }
            }
        } catch {
            guard !shouldReaderStop else { return }
            finishStream(throwing: error)
            requestTermination()
        }
    }

    /// Returns true after EOF or a fatal framing condition.
    private func drainStdout(
        descriptor: Int32,
        buffer: inout Data,
        maximumChunks: Int = 256
    ) throws -> Bool {
        for _ in 0..<maximumChunks {
            switch try readNonblocking(descriptor: descriptor, maximumCount: 4_096) {
            case .wouldBlock:
                return false
            case .endOfFile:
                if !buffer.isEmpty {
                    finishStream(throwing: CodexTransportError.incompleteOutputLine)
                }
                requestTermination()
                return true
            case .data(let chunk):
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    var line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.last == 0x0D { line.removeLast() }
                    guard line.count <= Self.maximumLineBytes else {
                        finishStream(throwing: CodexTransportError.outputLineTooLarge)
                        requestTermination()
                        return true
                    }
                    guard emitLine(.stdoutLine(line)) else {
                        requestTermination()
                        return true
                    }
                }
                guard buffer.count <= Self.maximumLineBytes else {
                    finishStream(throwing: CodexTransportError.outputLineTooLarge)
                    requestTermination()
                    return true
                }
            }
        }
        return false
    }

    private func drainStderr() {
        let descriptor = errorPipe.fileHandleForReading.fileDescriptor
        do {
            while true {
                let readiness = try pollForData(
                    dataDescriptor: descriptor,
                    wake: stderrWake
                )
                if readiness.dataReady {
                    if try drainStderrBytes(descriptor: descriptor) { return }
                }
                if readiness.wakeReady { stderrWake.drain() }
                if shouldReaderStop {
                    _ = try drainStderrBytes(descriptor: descriptor, maximumChunks: 16)
                    return
                }
            }
        } catch {
            guard !shouldReaderStop else { return }
            finishStream(throwing: error)
            requestTermination()
        }
    }

    private func drainStderrBytes(
        descriptor: Int32,
        maximumChunks: Int = 256
    ) throws -> Bool {
        for _ in 0..<maximumChunks {
            switch try readNonblocking(descriptor: descriptor, maximumCount: 4_096) {
            case .wouldBlock:
                return false
            case .endOfFile:
                return true
            case .data(let chunk):
                stateLock.withLock {
                    stderrByteCount = min(
                        Self.maximumDiagnosticByteCount,
                        stderrByteCount + chunk.count
                    )
                }
            }
        }
        return false
    }

    private var shouldReaderStop: Bool {
        stateLock.withLock { exitObserved || readerShutdownRequested || cleanupCompleted }
    }

    private func pollForData(
        dataDescriptor: Int32,
        wake: TransportWakePipe
    ) throws -> PollResult {
        var descriptors = [
            pollfd(
                fd: dataDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            ),
            pollfd(fd: wake.readDescriptor, events: Int16(POLLIN), revents: 0)
        ]
        while true {
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), Self.pollSliceMilliseconds)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw TransportWakePipe.currentPOSIXError()
            }
            if descriptors[0].revents & Int16(POLLNVAL) != 0 {
                throw POSIXError(.EBADF)
            }
            return PollResult(
                dataReady: descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0,
                wakeReady: descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
            )
        }
    }

    private func readNonblocking(
        descriptor: Int32,
        maximumCount: Int
    ) throws -> ReadResult {
        var bytes = [UInt8](repeating: 0, count: maximumCount)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return .data(Data(bytes.prefix(count))) }
            if count == 0 { return .endOfFile }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            throw TransportWakePipe.currentPOSIXError()
        }
    }

    @discardableResult
    private func emitLine(_ event: CodexTransportEvent) -> Bool {
        eventLock.withLock {
            guard !streamFinished else { return false }
            switch continuation.yield(event) {
            case .enqueued:
                return true
            case .dropped:
                streamFinished = true
                terminalCompletionCount += 1
                continuation.finish(throwing: CodexTransportError.outputBackpressure)
                return false
            case .terminated:
                streamFinished = true
                return false
            @unknown default:
                streamFinished = true
                terminalCompletionCount += 1
                continuation.finish(throwing: CodexTransportError.outputBackpressure)
                return false
            }
        }
    }

    private func finishWithTerminal(_ event: CodexTransportEvent) {
        eventLock.withLock {
            guard !streamFinished else { return }
            let result = continuation.yield(event)
            streamFinished = true
            terminalCompletionCount += 1
            switch result {
            case .enqueued:
                continuation.finish()
            case .dropped:
                continuation.finish(throwing: CodexTransportError.outputBackpressure)
            case .terminated:
                break
            @unknown default:
                continuation.finish(throwing: CodexTransportError.outputBackpressure)
            }
        }
    }

    private func finishStream(throwing error: Error?) {
        eventLock.withLock {
            guard !streamFinished else { return }
            streamFinished = true
            terminalCompletionCount += 1
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }

    private func recordProcessTermination(status: Int32) {
        let isFirstObservation = stateLock.withLock { () -> Bool in
            guard !exitObserved else { return false }
            exitObserved = true
            observedTerminationStatus = status
            return true
        }
        guard isFirstObservation else { return }
        requestTermination()
    }

    private func requestTermination() {
        requestStopFlagAndWake()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.stop()
        }
    }

    @discardableResult
    private func requestStopFlagAndWake() -> Bool {
        let shouldSignal = stateLock.withLock { () -> Bool in
            guard !stopping, !cleanupCompleted else { return false }
            stopping = true
            return true
        }
        guard shouldSignal else { return false }
        inputWake.signal()
        stdoutWake.signal()
        stderrWake.signal()
        return true
    }

    private func performStopOnce() async -> Bool {
        stateLock.withLock { cleanupExecutionCount += 1 }

        // The input wake releases a blocked nonblocking send before this lock is acquired.
        writeLock.withLock { try? inputPipe.fileHandleForWriting.close() }

        if !stateLock.withLock({ exitObserved }), process.isRunning {
            process.terminate()
        }

        var exited = await waitForExit(until: ContinuousClock.now + .seconds(1))
        if !exited {
            if !process.isRunning, !suppressSynchronousExitObservationForTesting {
                recordProcessTermination(status: process.terminationStatus)
                exited = true
            } else if let pid = stateLock.withLock({ ownedPID }), process.isRunning {
                stateLock.withLock { forcedKillCount += 1 }
                let result = processSignalForTesting(pid, SIGKILL)
                if result != 0, errno == ESRCH,
                   !process.isRunning,
                   !suppressSynchronousExitObservationForTesting {
                    recordProcessTermination(status: process.terminationStatus)
                }
            }
            exited = await waitForExit(until: ContinuousClock.now + .seconds(1))
        }

        stateLock.withLock { readerShutdownRequested = true }
        stdoutWake.signal()
        stderrWake.signal()
        var readersMetDeadline = await waitForReaders(
            until: ContinuousClock.now + .seconds(1)
        )
        if !readersMetDeadline {
            // Closing the wake descriptors releases any anomalous poll that did
            // not observe the first signal. The second wait is still bounded;
            // stop must never turn into an unlimited DispatchGroup join.
            stdoutWake.signal()
            stderrWake.signal()
            stdoutWake.close()
            stderrWake.close()
            readersMetDeadline = await waitForReaders(
                until: ContinuousClock.now + .milliseconds(250)
            )
        }

        let teardownConfirmed = exited && readersMetDeadline
        if exited { process.terminationHandler = nil }
        inputWake.close()
        stdoutWake.close()
        stderrWake.close()

        let terminalStatus = stateLock.withLock { () -> Int32? in
            if exited {
                launched = false
                ownedPID = nil
            }
            cleanupCompleted = teardownConfirmed
            return observedTerminationStatus
        }

        if let terminalStatus {
            finishWithTerminal(.terminated(terminalStatus))
        } else if exited {
            finishStream(throwing: nil)
        } else {
            finishStream(throwing: CodexTransportError.teardownTimedOut)
        }
        return teardownConfirmed
    }

    private func waitForExit(until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if stateLock.withLock({ exitObserved }) { return true }
            if !process.isRunning, !suppressSynchronousExitObservationForTesting {
                recordProcessTermination(status: process.terminationStatus)
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if stateLock.withLock({ exitObserved }) { return true }
        if !process.isRunning, !suppressSynchronousExitObservationForTesting {
            recordProcessTermination(status: process.terminationStatus)
            return true
        }
        return false
    }

    private func waitForReaders(until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if Self.readerGroupIsFinished(readerGroup) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return Self.readerGroupIsFinished(readerGroup)
    }

    private static func readerGroupIsFinished(_ group: DispatchGroup) -> Bool {
        group.wait(timeout: .now()) == .success
    }

    private func cleanupAfterLaunchFailure(error: Error) {
        stateLock.withLock {
            stopping = true
            cleanupCompleted = true
            launched = false
            ownedPID = nil
        }
        process.terminationHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForReading.close()
        inputWake.close()
        stdoutWake.close()
        stderrWake.close()
        finishStream(throwing: error)
    }
}
