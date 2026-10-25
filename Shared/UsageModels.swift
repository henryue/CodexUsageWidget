import Foundation

public enum UsageWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case sevenDay
    case other

    public static func classify(durationMinutes: Int?) -> Self {
        switch durationMinutes {
        case 300: .fiveHour
        case 10_080: .sevenDay
        default: .other
        }
    }

    public var compactLabel: String {
        switch self {
        case .fiveHour: "5 hour"
        case .sevenDay: "7 day"
        case .other: "Limit"
        }
    }

    public var detailLabel: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "7-day"
        case .other: "Usage"
        }
    }
}

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, durationMinutes: Int?, resetsAt: Date?) {
        precondition(
            usedPercent.isFinite &&
            usedPercent.rounded() == usedPercent &&
            (0...100).contains(usedPercent)
        )
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var id: String {
        normalizedIdentityKey
    }

    public var kind: UsageWindowKind {
        UsageWindowKind.classify(durationMinutes: durationMinutes)
    }

    public var clampedUsedPercent: Double {
        usedPercent
    }

    public var remainingPercent: Double {
        100 - clampedUsedPercent
    }

    public var roundedRemainingPercent: Int {
        Int(remainingPercent.rounded())
    }

    public var compactLabel: String {
        switch kind {
        case .fiveHour: return "5 hour"
        case .sevenDay: return "7 day"
        case .other:
            guard let durationMinutes, durationMinutes > 0 else { return "Usage" }
            if durationMinutes.isMultiple(of: 1_440) { return "\(durationMinutes / 1_440) day" }
            if durationMinutes.isMultiple(of: 60) { return "\(durationMinutes / 60) hour" }
            return "\(durationMinutes) min"
        }
    }

    public var detailLabel: String {
        switch kind {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .other:
            guard let durationMinutes, durationMinutes > 0 else { return "Usage window" }
            if durationMinutes.isMultiple(of: 1_440) { return "\(durationMinutes / 1_440)-day" }
            if durationMinutes.isMultiple(of: 60) { return "\(durationMinutes / 60)-hour" }
            return "\(durationMinutes)-minute"
        }
    }

    public var normalizedIdentityKey: String {
        let duration = durationMinutes.map(String.init) ?? "unknown"
        let reset = resetsAt.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) } ?? "unknown"
        return "duration:\(duration)|reset:\(reset)|used:\(Int(usedPercent))"
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case durationMinutes
        case resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let used = try container.decode(Double.self, forKey: .usedPercent)
        guard used.isFinite, used.rounded() == used, (0...100).contains(used) else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent,
                in: container,
                debugDescription: "usedPercent must be an integer within 0...100"
            )
        }
        let reset = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        if let reset,
           !(946_684_800...4_102_444_800).contains(reset.timeIntervalSince1970) {
            throw DecodingError.dataCorruptedError(
                forKey: .resetsAt,
                in: container,
                debugDescription: "resetsAt is outside the supported Unix-second range"
            )
        }
        usedPercent = used
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        resetsAt = reset
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let windows: [UsageWindow]

    public init(fetchedAt: Date, windows: [UsageWindow]) {
        self.fetchedAt = fetchedAt
        self.windows = Self.normalized(windows)
    }

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            windows: try container.decode([UsageWindow].self, forKey: .windows)
        )
    }

    public func window(kind: UsageWindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    public var fiveHourWindow: UsageWindow? { window(kind: .fiveHour) }
    public var sevenDayWindow: UsageWindow? { window(kind: .sevenDay) }

    /// Never assumes that the server's primary/secondary ordering is stable.
    public var limitingWindow: UsageWindow? {
        strictnessSortedWindows.first
    }

    public var mediumDisplayWindows: [UsageWindow] {
        Array(strictnessSortedWindows.prefix(2))
    }

    public var additionalWindowCount: Int {
        max(0, windows.count - 2)
    }

    public var strictnessSortedWindows: [UsageWindow] {
        windows.sorted(by: Self.isMoreRestrictive)
    }

    public func widgetTimelinePlan(
        now: Date,
        reconciliationInterval: TimeInterval = 15 * 60
    ) -> WidgetTimelinePlan {
        let reconciliationDate = now.addingTimeInterval(reconciliationInterval)
        let earliestFutureReset = windows
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
        var dates = [now]
        if let earliestFutureReset {
            dates.append(earliestFutureReset)
        }
        let staleTransitionDate = fetchedAt.addingTimeInterval(30 * 60 + 1)
        if staleTransitionDate > now {
            dates.append(staleTransitionDate)
        }
        dates = Array(Set(dates)).sorted()
        let resetReload = earliestFutureReset?.addingTimeInterval(1) ?? reconciliationDate
        let reloadAfter = min(reconciliationDate, resetReload)
        return WidgetTimelinePlan(entryDates: dates, reloadAfter: reloadAfter)
    }

    public func isStale(at date: Date, after interval: TimeInterval = 30 * 60) -> Bool {
        date.timeIntervalSince(fetchedAt) > interval || windows.contains {
            guard let resetsAt = $0.resetsAt else { return false }
            return resetsAt <= date
        }
    }

    private static func normalized(_ input: [UsageWindow]) -> [UsageWindow] {
        var output: [UsageWindow] = []
        var identities = Set<String>()

        for window in input {
            if identities.insert(window.normalizedIdentityKey).inserted {
                output.append(window)
            }
        }

        return output.sorted(by: Self.isMoreRestrictive)
    }

    private static func isMoreRestrictive(_ candidate: UsageWindow, than current: UsageWindow) -> Bool {
        if candidate.remainingPercent != current.remainingPercent {
            return candidate.remainingPercent < current.remainingPercent
        }
        let candidateReset = candidate.resetsAt ?? .distantFuture
        let currentReset = current.resetsAt ?? .distantFuture
        if candidateReset != currentReset { return candidateReset < currentReset }

        let candidateDuration = candidate.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? .max
        let currentDuration = current.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? .max
        if candidateDuration != currentDuration { return candidateDuration < currentDuration }
        return candidate.normalizedIdentityKey < current.normalizedIdentityKey
    }
}

public struct WidgetTimelinePlan: Equatable, Sendable {
    public let entryDates: [Date]
    public let reloadAfter: Date

    public init(entryDates: [Date], reloadAfter: Date) {
        self.entryDates = entryDates
        self.reloadAfter = reloadAfter
    }
}

public struct WidgetStateEntry: Equatable, Sendable {
    public let date: Date
    public let state: UsageViewState

    public init(date: Date, state: UsageViewState) {
        self.date = date
        self.state = state
    }
}

public struct WidgetStateTimeline: Equatable, Sendable {
    public let entries: [WidgetStateEntry]
    public let reloadAfter: Date

    public init(entries: [WidgetStateEntry], reloadAfter: Date) {
        self.entries = entries
        self.reloadAfter = reloadAfter
    }
}

public enum SharedServiceStatus: String, Codable, Equatable, Sendable {
    case available
    case unauthenticated
    case failed
}

public struct SharedUsageEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var snapshot: UsageSnapshot?
    public var serviceStatus: SharedServiceStatus
    public var lastAttemptAt: Date
    public var message: String?

    public init(
        snapshot: UsageSnapshot?,
        serviceStatus: SharedServiceStatus,
        lastAttemptAt: Date,
        message: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.snapshot = snapshot
        self.serviceStatus = serviceStatus
        self.lastAttemptAt = lastAttemptAt
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshot
        case serviceStatus
        case lastAttemptAt
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion, version >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported snapshot schema version \(version)"
            )
        }
        schemaVersion = version
        snapshot = try container.decodeIfPresent(UsageSnapshot.self, forKey: .snapshot)
        serviceStatus = try container.decode(SharedServiceStatus.self, forKey: .serviceStatus)
        lastAttemptAt = try container.decode(Date.self, forKey: .lastAttemptAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

public enum UsageViewState: Equatable, Sendable {
    case loading
    case available(UsageSnapshot)
    case stale(UsageSnapshot, message: String?)
    case unauthenticated(String)
    case failed(String)

    public static func resolve(envelope: SharedUsageEnvelope?, at date: Date) -> Self {
        guard let envelope else { return .loading }

        if let snapshot = envelope.snapshot {
            if envelope.serviceStatus != .available || snapshot.isStale(at: date) {
                return .stale(snapshot, message: envelope.message)
            }
            return .available(snapshot)
        }

        switch envelope.serviceStatus {
        case .available:
            return .loading
        case .unauthenticated:
            return .unauthenticated(envelope.message ?? "Sign in to Codex in the ChatGPT app.")
        case .failed:
            return .failed(envelope.message ?? "Usage is temporarily unavailable.")
        }
    }
}

/// Resolves every Widget entry from one immutable store read. Keeping the
/// captured `SnapshotStoreLoadResult` as the sole input prevents a timeline
/// plan from revision A being paired with entries from later revisions.
public enum WidgetSnapshotPolicy {
    public static func state(
        from loadResult: SnapshotStoreLoadResult,
        at date: Date
    ) -> UsageViewState {
        switch loadResult {
        case .loaded(let envelope):
            UsageViewState.resolve(envelope: envelope, at: date)
        case .missing:
            .failed("No shared usage data is available. Open Codex Usage to refresh.")
        case .invalid:
            .failed("Shared usage data is invalid. Open Codex Usage to refresh.")
        case .unavailable:
            .failed("Shared usage storage is unavailable. Open Codex Usage.")
        }
    }

    public static func timeline(
        from loadResult: SnapshotStoreLoadResult,
        now: Date,
        reconciliationInterval: TimeInterval = 15 * 60
    ) -> WidgetStateTimeline {
        let plan: WidgetTimelinePlan
        if case .loaded(let envelope) = loadResult, let snapshot = envelope.snapshot {
            plan = snapshot.widgetTimelinePlan(
                now: now,
                reconciliationInterval: reconciliationInterval
            )
        } else {
            plan = WidgetTimelinePlan(
                entryDates: [now],
                reloadAfter: now.addingTimeInterval(reconciliationInterval)
            )
        }

        return WidgetStateTimeline(
            entries: plan.entryDates.map {
                WidgetStateEntry(date: $0, state: state(from: loadResult, at: $0))
            },
            reloadAfter: plan.reloadAfter
        )
    }
}

public enum WidgetPreviewPolicy {
    public static func isPlaceholder(contextIsPreview: Bool) -> Bool {
        contextIsPreview
    }
}

public enum WidgetStaleRecoveryKind: Equatable, Sendable {
    case resume
    case refresh

    public init(message: String?) {
        self = message?.localizedCaseInsensitiveContains("paused") == true
            ? .resume
            : .refresh
    }
}

public enum WidgetReloadPolicy {
    /// Fetch timestamps alone are not a reason to spend WidgetKit's reload
    /// budget on every background poll. Status, usage, and reset changes are.
    public static func contentStateChanged(
        previous: SnapshotStoreLoadResult,
        current: SnapshotStoreLoadResult,
        at date: Date
    ) -> Bool {
        contentSignature(for: previous, at: date) != contentSignature(for: current, at: date)
    }

    /// Compares what the Widget can actually read before and after a
    /// publication attempt. This is intentionally based on store results,
    /// rather than whether `save` threw: a failed primary write may still
    /// publish a complete stale recovery envelope, and repeating that same
    /// visible recovery state must not request another timeline reload.
    public static func visibleStateChanged(
        previous: SnapshotStoreLoadResult,
        current: SnapshotStoreLoadResult,
        at date: Date
    ) -> Bool {
        visibleSignature(for: previous, at: date) !=
            visibleSignature(for: current, at: date)
    }

    public static func visibleStateChanged(
        previous: SharedUsageEnvelope?,
        current: SharedUsageEnvelope,
        at date: Date
    ) -> Bool {
        guard let previous else { return true }
        if previous.serviceStatus != current.serviceStatus || previous.message != current.message {
            return true
        }
        switch (previous.snapshot, current.snapshot) {
        case (nil, nil):
            return false
        case (.some, nil), (nil, .some):
            return true
        case let (.some(old), .some(new)):
            return old.windows != new.windows ||
                old.fetchedAt != new.fetchedAt ||
                old.isStale(at: date) != new.isStale(at: date)
        }
    }

    public static func scheduledReadUpperBound(
        over duration: TimeInterval,
        reconciliationInterval: TimeInterval
    ) -> Int {
        guard duration > 0, reconciliationInterval > 0 else { return 0 }
        return Int(floor(duration / reconciliationInterval))
    }

    private enum VisibleSignature: Equatable {
        case loading
        case available(UsageSnapshot)
        case stale(UsageSnapshot, recovery: WidgetStaleRecoveryKind)
        case unauthenticated(String)
        case failed(String)
    }

    private enum ContentSignature: Equatable {
        case loading
        case available([UsageWindow])
        case stale([UsageWindow], recovery: WidgetStaleRecoveryKind)
        case unauthenticated(String)
        case failed(String)
    }

    private static func contentSignature(
        for result: SnapshotStoreLoadResult,
        at date: Date
    ) -> ContentSignature {
        switch WidgetSnapshotPolicy.state(from: result, at: date) {
        case .loading: .loading
        case .available(let snapshot): .available(snapshot.windows)
        case .stale(let snapshot, let message):
            .stale(snapshot.windows, recovery: WidgetStaleRecoveryKind(message: message))
        case .unauthenticated(let message): .unauthenticated(message)
        case .failed(let message): .failed(message)
        }
    }

    private static func visibleSignature(
        for result: SnapshotStoreLoadResult,
        at date: Date
    ) -> VisibleSignature {
        switch WidgetSnapshotPolicy.state(from: result, at: date) {
        case .loading:
            .loading
        case .available(let snapshot):
            .available(snapshot)
        case .stale(let snapshot, let message):
            .stale(snapshot, recovery: WidgetStaleRecoveryKind(message: message))
        case .unauthenticated(let message):
            .unauthenticated(message)
        case .failed(let message):
            .failed(message)
        }
    }
}

/// Keeps frequent account reads separate from requests to redraw the Widget.
/// Only a request actually sent advances the baseline and freshness clock.
public struct WidgetReloadGate: Sendable {
    private var lastRequestedResult: SnapshotStoreLoadResult?
    private var lastRequestedAt: Date?
    private let freshnessInterval: TimeInterval

    public init(freshnessInterval: TimeInterval = 15 * 60) {
        self.freshnessInterval = freshnessInterval
    }

    public mutating func shouldRequestReload(
        previous: SnapshotStoreLoadResult,
        current: SnapshotStoreLoadResult,
        at date: Date,
        force: Bool = false
    ) -> Bool {
        let baseline = lastRequestedResult ?? previous
        let freshnessDue = lastRequestedAt.map {
            date < $0 || date.timeIntervalSince($0) >= freshnessInterval
        } ?? true
        let contentChanged = WidgetReloadPolicy.contentStateChanged(
            previous: baseline, current: current, at: date
        )
        let freshnessChanged = freshnessDue && WidgetReloadPolicy.visibleStateChanged(
            previous: baseline, current: current, at: date
        )
        guard force || contentChanged || freshnessChanged else { return false }
        lastRequestedResult = current
        lastRequestedAt = date
        return true
    }
}

public extension UsageSnapshot {
    /// Deterministic synthetic data for previews and tests; never populated from a live account.
    static func previewSevenDay(now: Date = .now) -> Self {
        UsageSnapshot(
            fetchedAt: now,
            windows: [
                UsageWindow(
                    usedPercent: 20,
                    durationMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(5 * 86_400 + 23 * 3_600)
                )
            ]
        )
    }

    static func previewDualWindow(now: Date = .now) -> Self {
        UsageSnapshot(
            fetchedAt: now,
            windows: [
                UsageWindow(
                    usedPercent: 30,
                    durationMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(5 * 86_400 + 23 * 3_600)
                ),
                UsageWindow(
                    usedPercent: 60,
                    durationMinutes: 300,
                    resetsAt: now.addingTimeInterval(3 * 3_600 + 12 * 60)
                )
            ]
        )
    }
}
