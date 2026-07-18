import CodexUsageCore
import CodexUsageRuntime
import Darwin
import Foundation

@main
struct CodexUsageSmoke {
    static func main() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let client = CodexAppServerClient()
        do {
            try await runSmoke(client: client, temporaryDirectory: temporaryDirectory)
        } catch {
            let diagnostics = await client.diagnostics()
            print("SMOKE FAIL: \(error)")
            print("Protocol lines received: \(diagnostics.receivedProtocolLineCount)")
            print("Owned app-server observed: \(diagnostics.processIdentifier != nil)")
            fflush(stdout)
            await shutdownUntilConfirmed(client: client)
            print("Cleanup confirmed: true")
            fflush(stdout)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func runSmoke(
        client: CodexAppServerClient,
        temporaryDirectory: URL
    ) async throws {
        let snapshot = try await client.fetchRateLimits()
        guard !snapshot.windows.isEmpty else { throw SmokeError.noWindows }
        guard let ownedPID = (await client.diagnostics()).processIdentifier,
              Darwin.kill(ownedPID, 0) == 0 else { throw SmokeError.childNotObserved }

        let store = AppGroupSnapshotStore(directoryURL: temporaryDirectory)
        let envelope = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .available,
            lastAttemptAt: snapshot.fetchedAt
        )
        try store.save(envelope)
        guard let decoded = store.load(), semanticallyEqual(decoded, envelope) else {
            throw SmokeError.storeRoundTrip
        }

        guard let smallWindow = decoded.snapshot?.limitingWindow else {
            throw SmokeError.noSmallPresentation
        }
        let mediumWindows = decoded.snapshot?.mediumDisplayWindows ?? []
        guard !mediumWindows.isEmpty else { throw SmokeError.noMediumPresentation }

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        guard storedFiles.count == 1 else { throw SmokeError.storeRoundTrip }
        let sanitizedBytes = try Data(contentsOf: storedFiles[0])
        let sanitizedText = String(decoding: sanitizedBytes, as: UTF8.self)
        for forbidden in ["auth.json", "planType", "credits", "rateLimitResetCredits", "limitId"] {
            guard !sanitizedText.contains(forbidden) else { throw SmokeError.unsanitizedData(forbidden) }
        }

        let shutdownCompleted = await shutdownWithRetries(client: client)
        guard shutdownCompleted else { throw SmokeError.teardownUnconfirmed }
        guard await exactProcessIsGone(ownedPID) else { throw SmokeError.childStillRunning }

        print("SMOKE PASS")
        // Never place live account percentages, reset times, window labels, or
        // raw protocol data in review logs. Selection success is sufficient.
        _ = smallWindow
        print("Small entry selection: PASS")
        print("Medium entry selection: PASS")
        print("Sanitized snapshot round-trip: PASS")
        print("Child process cleanup: PASS")
    }

    private static func semanticallyEqual(
        _ lhs: SharedUsageEnvelope,
        _ rhs: SharedUsageEnvelope
    ) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.serviceStatus == rhs.serviceStatus,
              lhs.message == rhs.message,
              abs(lhs.lastAttemptAt.timeIntervalSince(rhs.lastAttemptAt)) < 0.001 else {
            return false
        }
        switch (lhs.snapshot, rhs.snapshot) {
        case (nil, nil):
            return true
        case (.some(let left), .some(let right)):
            guard abs(left.fetchedAt.timeIntervalSince(right.fetchedAt)) < 0.001,
                  left.windows.count == right.windows.count else { return false }
            return zip(left.windows, right.windows).allSatisfy { leftWindow, rightWindow in
                guard leftWindow.usedPercent == rightWindow.usedPercent,
                      leftWindow.durationMinutes == rightWindow.durationMinutes else { return false }
                switch (leftWindow.resetsAt, rightWindow.resetsAt) {
                case (nil, nil):
                    return true
                case (.some(let leftReset), .some(let rightReset)):
                    return abs(leftReset.timeIntervalSince(rightReset)) < 0.001
                default:
                    return false
                }
            }
        default:
            return false
        }
    }

    private static func exactProcessIsGone(_ pid: Int32) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        errno = 0
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func shutdownWithRetries(
        client: CodexAppServerClient,
        attempts: Int = 3
    ) async -> Bool {
        for attempt in 0..<attempts {
            if await client.shutdown() { return true }
            if attempt + 1 < attempts {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return false
    }

    private static func shutdownUntilConfirmed(client: CodexAppServerClient) async {
        var delay = Duration.milliseconds(250)
        while !(await client.shutdown()) {
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(2))
        }
    }
}

private enum SmokeError: Error, LocalizedError {
    case noWindows
    case storeRoundTrip
    case noSmallPresentation
    case noMediumPresentation
    case unsanitizedData(String)
    case childNotObserved
    case childStillRunning
    case teardownUnconfirmed

    var errorDescription: String? {
        switch self {
        case .noWindows: "The production client returned no usage windows."
        case .storeRoundTrip: "The sanitized snapshot did not round-trip through the production store."
        case .noSmallPresentation: "Small presentation selection failed."
        case .noMediumPresentation: "Medium presentation selection failed."
        case .unsanitizedData(let key): "The shared snapshot contained forbidden field \(key)."
        case .childNotObserved: "The production client did not expose its owned child PID."
        case .childStillRunning: "A Codex app-server child remained after the request completed."
        case .teardownUnconfirmed: "Codex app-server teardown did not complete within its bound."
        }
    }
}
