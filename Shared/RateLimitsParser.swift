import Foundation
import CoreFoundation

public enum RateLimitsParserError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case serverError(String)
    case missingCodexRateLimits
    case missingWindows
    case malformedWindow

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "Codex returned invalid JSON."
        case .serverError(let message): message
        case .missingCodexRateLimits: "The Codex rate-limit bucket was not present."
        case .missingWindows: "Codex returned no usage windows."
        case .malformedWindow: "Codex returned an incomplete usage window."
        }
    }
}

public struct RateLimitsParserDiagnostics: Equatable, Sendable {
    public var invalidWindowDiscardCount: Int
    public var sameDurationCollisionCount: Int

    public init(
        invalidWindowDiscardCount: Int = 0,
        sameDurationCollisionCount: Int = 0
    ) {
        self.invalidWindowDiscardCount = invalidWindowDiscardCount
        self.sameDurationCollisionCount = sameDurationCollisionCount
    }
}

public struct RateLimitsParseResult: Equatable, Sendable {
    public let snapshot: UsageSnapshot
    public let diagnostics: RateLimitsParserDiagnostics

    public init(snapshot: UsageSnapshot, diagnostics: RateLimitsParserDiagnostics) {
        self.snapshot = snapshot
        self.diagnostics = diagnostics
    }
}

public enum RateLimitsParseOutcome: Equatable, Sendable {
    case success(RateLimitsParseResult)
    case failure(RateLimitsParserError, RateLimitsParserDiagnostics)
}

public enum RateLimitsParser {
    public static func parseResponseLine(_ data: Data, fetchedAt: Date = .now) throws -> UsageSnapshot {
        switch parseResponseLineOutcome(data, fetchedAt: fetchedAt) {
        case .success(let result):
            return result.snapshot
        case .failure(let error, _):
            throw error
        }
    }

    public static func parseResponseLineOutcome(
        _ data: Data,
        fetchedAt: Date = .now
    ) -> RateLimitsParseOutcome {
        var diagnostics = RateLimitsParserDiagnostics()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.invalidJSON, diagnostics)
        }

        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex app-server returned an error."
            return .failure(.serverError(message), diagnostics)
        }

        guard let result = root["result"] as? [String: Any] else {
            return .failure(.missingCodexRateLimits, diagnostics)
        }

        let bucket = codexBucket(in: result)
        guard let bucket else {
            return .failure(.missingCodexRateLimits, diagnostics)
        }

        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let rawValue = bucket[key], !(rawValue is NSNull) else { continue }
            guard let rawWindow = rawValue as? [String: Any] else {
                diagnostics.invalidWindowDiscardCount += 1
                continue
            }
            if let window = parseWindow(rawWindow) {
                windows.append(window)
            } else {
                diagnostics.invalidWindowDiscardCount += 1
            }
        }

        guard !windows.isEmpty else {
            return .failure(.missingWindows, diagnostics)
        }

        var firstIdentityByDuration: [Int?: String] = [:]
        for window in windows {
            if let firstIdentity = firstIdentityByDuration[window.durationMinutes] {
                if firstIdentity != window.normalizedIdentityKey {
                    diagnostics.sameDurationCollisionCount += 1
                }
            } else {
                firstIdentityByDuration[window.durationMinutes] = window.normalizedIdentityKey
            }
        }

        return .success(RateLimitsParseResult(
            snapshot: UsageSnapshot(fetchedAt: fetchedAt, windows: windows),
            diagnostics: diagnostics
        ))
    }

    private static func codexBucket(in result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = buckets["codex"] as? [String: Any] {
                if let internalID = codex["limitId"], !(internalID is NSNull),
                   (internalID as? String) != "codex" {
                    return nil
                }
                return codex
            }

            let identifiedCodexBuckets = buckets.values.compactMap { $0 as? [String: Any] }.filter {
                ($0["limitId"] as? String) == "codex"
            }
            if identifiedCodexBuckets.count == 1 {
                return identifiedCodexBuckets[0]
            }
        }

        // Backward-compatible fallback. Refuse a legacy bucket explicitly identified
        // as a different product so a new server shape cannot silently misreport data.
        guard let legacy = result["rateLimits"] as? [String: Any],
              (legacy["limitId"] as? String) == "codex" else { return nil }
        return legacy
    }

    private static func parseWindow(_ raw: [String: Any]) -> UsageWindow? {
        guard let used = integer(raw["usedPercent"]), (0...100).contains(used) else { return nil }

        let parsedDuration = integer(raw["windowDurationMins"])
        let duration = parsedDuration.flatMap { $0 > 0 ? $0 : nil }

        let resetsAt: Date?
        if let timestamp = integer(raw["resetsAt"]),
           (946_684_800...4_102_444_800).contains(timestamp) {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            resetsAt = nil
        }

        return UsageWindow(
            usedPercent: Double(used),
            durationMinutes: duration,
            resetsAt: resetsAt
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.isFinite, number.rounded() == number else { return nil }
        return Int(exactly: number)
    }
}
