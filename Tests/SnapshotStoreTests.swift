import Foundation
import Darwin
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
#endif

final class SnapshotStoreTests: XCTestCase {
    // Team IDs, timestamps, and usage values in this file are synthetic fixtures.
    func testAppGroupSuiteNameValidationFailsClosed() {
        XCTAssertNil(AppGroupSnapshotStore.validatedSuiteName(nil))
        XCTAssertNil(AppGroupSnapshotStore.validatedSuiteName("  "))
        XCTAssertNil(AppGroupSnapshotStore.validatedSuiteName(
            "$(TeamIdentifierPrefix)com.henryyue.CodexUsageWidget"
        ))
        XCTAssertNil(AppGroupSnapshotStore.validatedSuiteName("team/group"))
        XCTAssertEqual(
            AppGroupSnapshotStore.validatedSuiteName(
                " ABCDE12345.com.example.CodexUsageWidget "
            ),
            "ABCDE12345.com.example.CodexUsageWidget"
        )
    }

    func testAtomicFileStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppGroupSnapshotStore(directoryURL: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let envelope = SharedUsageEnvelope(
            snapshot: .previewDualWindow(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )

        try store.save(envelope)
        XCTAssertEqual(store.load(), envelope)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testFailedPrimaryPublicationRecoversCachedValuesAsStale() throws {
        enum InjectedFailure: Error { case write }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let oldEnvelope = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        try AppGroupSnapshotStore(directoryURL: directory).save(oldEnvelope)

        let failingStore = AppGroupSnapshotStore(
            directoryURL: directory,
            atomicWriter: { _, _ in throw InjectedFailure.write }
        )
        let replacement = SharedUsageEnvelope(
            snapshot: .previewDualWindow(now: now.addingTimeInterval(60)),
            serviceStatus: .available,
            lastAttemptAt: now.addingTimeInterval(60)
        )

        XCTAssertThrowsError(try failingStore.save(replacement)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .writeFailedRecoveredAsStale)
        }
        guard case .loaded(let recovered) = failingStore.loadResult() else {
            return XCTFail("Expected an atomically published stale recovery envelope")
        }
        XCTAssertEqual(recovered.snapshot, replacement.snapshot)
        XCTAssertEqual(recovered.serviceStatus, .failed)
        guard case .stale(let snapshot, let message) = UsageViewState.resolve(
            envelope: recovered,
            at: now.addingTimeInterval(60)
        ) else {
            return XCTFail("Recovered cached values must be explicitly stale")
        }
        XCTAssertEqual(snapshot, replacement.snapshot)
        XCTAssertEqual(message, "Shared usage could not be updated. Open the app to refresh.")
    }

    func testPrimaryAndRecoveryWriteFailureInvalidatesOlderReadySnapshot() throws {
        enum InjectedFailure: Error { case write }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let oldEnvelope = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        try AppGroupSnapshotStore(directoryURL: directory).save(oldEnvelope)

        let failingStore = AppGroupSnapshotStore(
            directoryURL: directory,
            atomicWriter: { _, _ in throw InjectedFailure.write },
            recoveryWriter: { _, _ in throw InjectedFailure.write }
        )
        XCTAssertThrowsError(try failingStore.save(oldEnvelope)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .writeFailed)
        }
        XCTAssertEqual(failingStore.loadResult(), .missing)
    }

    func testPrimaryRecoveryAndRemovalFailureCommitsOnlyStaleInPlace() throws {
        enum InjectedFailure: Error { case write, remove }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let oldEnvelope = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        try AppGroupSnapshotStore(directoryURL: directory).save(oldEnvelope)

        let replacement = SharedUsageEnvelope(
            snapshot: .previewDualWindow(now: now.addingTimeInterval(60)),
            serviceStatus: .available,
            lastAttemptAt: now.addingTimeInterval(60)
        )
        let failingStore = AppGroupSnapshotStore(
            directoryURL: directory,
            atomicWriter: { _, _ in throw InjectedFailure.write },
            recoveryWriter: { _, _ in throw InjectedFailure.write },
            snapshotRemover: { _ in throw InjectedFailure.remove }
        )

        XCTAssertThrowsError(try failingStore.save(replacement)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .writeFailedRecoveredAsStale)
        }
        guard case .loaded(let recovered) = failingStore.loadResult() else {
            return XCTFail("Emergency in-place commit must leave a complete recovery envelope")
        }
        XCTAssertEqual(recovered.snapshot, replacement.snapshot)
        XCTAssertEqual(recovered.serviceStatus, .failed)
        guard case .stale(let snapshot, let message) = WidgetSnapshotPolicy.state(
            from: .loaded(recovered),
            at: now.addingTimeInterval(60)
        ) else {
            return XCTFail("Emergency recovery must never decode as ready")
        }
        XCTAssertEqual(snapshot, replacement.snapshot)
        XCTAssertEqual(message, "Shared usage could not be updated. Open the app to refresh.")
    }

    func testEmergencyFailureAfterDurableSentinelLeavesOnlyInvalidData() throws {
        enum InjectedFailure: Error { case write, remove, interruptedEmergency }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let oldEnvelope = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        try AppGroupSnapshotStore(directoryURL: directory).save(oldEnvelope)

        let interruptedStore = AppGroupSnapshotStore(
            directoryURL: directory,
            atomicWriter: { _, _ in throw InjectedFailure.write },
            recoveryWriter: { _, _ in throw InjectedFailure.write },
            snapshotRemover: { _ in throw InjectedFailure.remove },
            emergencyInvalidator: { recoveryData, fileURL in
                let descriptor = fileURL.path.withCString {
                    Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else { throw InjectedFailure.interruptedEmergency }
                defer { _ = Darwin.close(descriptor) }

                var sentinel: UInt8 = 0
                guard Darwin.pwrite(descriptor, &sentinel, 1, 0) == 1,
                      Darwin.fsync(descriptor) == 0 else {
                    throw InjectedFailure.interruptedEmergency
                }

                // Simulate an interruption after some new bytes reached the
                // old inode but before truncate and the one-byte JSON commit.
                let prefix = Data(recoveryData.dropFirst().prefix(24))
                try prefix.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress,
                          Darwin.pwrite(descriptor, baseAddress, bytes.count, 1) == bytes.count else {
                        throw InjectedFailure.interruptedEmergency
                    }
                }
                throw InjectedFailure.interruptedEmergency
            }
        )

        XCTAssertThrowsError(try interruptedStore.save(oldEnvelope)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .writeRecoveryAndInvalidationFailed)
        }
        XCTAssertEqual(interruptedStore.loadResult(), .invalid)

        let fileURL = directory.appendingPathComponent("codex-usage-snapshot-v1.json")
        let bytes = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(bytes.first, 0x7B, "An interrupted emergency write must not commit JSON")
        XCTAssertThrowsError(try JSONDecoder().decode(SharedUsageEnvelope.self, from: bytes))
        XCTAssertEqual(
            WidgetSnapshotPolicy.state(from: interruptedStore.loadResult(), at: now),
            .failed("Shared usage data is invalid. Open Codex Usage to refresh.")
        )
    }

    func testReadOnlyDirectoryStillAllowsEmergencyInPlaceStaleCommit() throws {
        try XCTSkipIf(geteuid() == 0, "POSIX directory permission checks are not meaningful as root")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("codex-usage-snapshot-v1.json")
        defer {
            _ = Darwin.chmod(directory.path, 0o700)
            _ = Darwin.chmod(fileURL.path, 0o600)
            try? FileManager.default.removeItem(at: directory)
        }

        let now = Date(timeIntervalSince1970: 2_000_000_196)
        let store = AppGroupSnapshotStore(directoryURL: directory)
        try store.save(SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        ))
        XCTAssertEqual(Darwin.chmod(fileURL.path, 0o600), 0)
        XCTAssertEqual(Darwin.chmod(directory.path, 0o555), 0)

        let replacement = SharedUsageEnvelope(
            snapshot: .previewDualWindow(now: now.addingTimeInterval(60)),
            serviceStatus: .available,
            lastAttemptAt: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try store.save(replacement)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .writeFailedRecoveredAsStale)
        }
        guard case .loaded(let recovered) = store.loadResult() else {
            return XCTFail("Writable snapshot inode should permit emergency stale publication")
        }
        XCTAssertEqual(recovered.snapshot, replacement.snapshot)
        XCTAssertEqual(recovered.serviceStatus, .failed)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "Fail-closed recovery must retain the single-snapshot-file architecture"
        )
    }

    func testOneHundredEmergencyCommitsDoNotLeakFileDescriptors() throws {
        enum InjectedFailure: Error { case write, remove }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_196)
        try AppGroupSnapshotStore(directoryURL: directory).save(SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        ))
        let store = AppGroupSnapshotStore(
            directoryURL: directory,
            atomicWriter: { _, _ in throw InjectedFailure.write },
            recoveryWriter: { _, _ in throw InjectedFailure.write },
            snapshotRemover: { _ in throw InjectedFailure.remove }
        )
        let descriptorsBefore = try openFileDescriptorCount()

        for index in 0..<100 {
            let attemptDate = now.addingTimeInterval(Double(index + 1))
            let envelope = SharedUsageEnvelope(
                snapshot: .previewDualWindow(now: attemptDate),
                serviceStatus: .available,
                lastAttemptAt: attemptDate
            )
            XCTAssertThrowsError(try store.save(envelope)) { error in
                XCTAssertEqual(error as? SnapshotStoreError, .writeFailedRecoveredAsStale)
            }
            guard case .loaded(let recovered) = store.loadResult() else {
                return XCTFail("Iteration \(index) did not leave a complete stale envelope")
            }
            XCTAssertEqual(recovered.serviceStatus, .failed)
        }

        XCTAssertEqual(
            try openFileDescriptorCount(),
            descriptorsBefore,
            "Emergency invalidation descriptors must close on every path"
        )
    }

    func testLoadResultDistinguishesMissingInvalidAndUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupSnapshotStore(directoryURL: directory)
        XCTAssertEqual(store.loadResult(), .missing)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("codex-usage-snapshot-v1.json")
        )
        XCTAssertEqual(store.loadResult(), .invalid)
        XCTAssertEqual(AppGroupSnapshotStore(unavailableForTesting: ()).loadResult(), .unavailable)
    }

    func testOutOfRangePercentageInSharedSnapshotIsInvalid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = Data("""
        {"schemaVersion":1,"serviceStatus":"available","lastAttemptAt":1800000000,
         "snapshot":{"fetchedAt":1800000000,"windows":[{"usedPercent":120,"durationMinutes":300,"resetsAt":1800000300}]}}
        """.utf8)
        try invalid.write(to: directory.appendingPathComponent("codex-usage-snapshot-v1.json"))
        XCTAssertEqual(AppGroupSnapshotStore(directoryURL: directory).loadResult(), .invalid)
    }

    func testFractionalPercentageInSharedSnapshotIsInvalid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = Data("""
        {"schemaVersion":1,"serviceStatus":"available","lastAttemptAt":1800000000,
         "snapshot":{"fetchedAt":1800000000,"windows":[{"usedPercent":13.4,"durationMinutes":300,"resetsAt":1800000300}]}}
        """.utf8)
        try invalid.write(to: directory.appendingPathComponent("codex-usage-snapshot-v1.json"))
        XCTAssertEqual(AppGroupSnapshotStore(directoryURL: directory).loadResult(), .invalid)
    }

    func testOneHundredConcurrentAtomicWritesAndReadsNeverExposePartialJSON() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupSnapshotStore(directoryURL: directory)
        let collector = FailureCollector()

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let envelope = SharedUsageEnvelope(
                snapshot: .previewSevenDay(now: date),
                serviceStatus: .available,
                lastAttemptAt: date
            )
            do {
                try store.save(envelope)
                switch store.loadResult() {
                case .loaded(let decoded):
                    guard decoded.schemaVersion == SharedUsageEnvelope.currentSchemaVersion,
                          decoded.snapshot?.windows.count == 1,
                          decoded.snapshot?.windows.first?.kind == .sevenDay else {
                        collector.record("Decoded invariant failed at iteration \(index)")
                        break
                    }
                case .missing, .invalid, .unavailable:
                    collector.record("Missing, invalid, or unavailable read at iteration \(index)")
                }
            } catch {
                collector.record("Write failed at iteration \(index)")
            }
        }

        XCTAssertTrue(collector.failures.isEmpty, collector.failures.joined(separator: "; "))
        if case .loaded = store.loadResult() {
            // Expected final state is one complete old or new envelope.
        } else {
            XCTFail("Final atomic snapshot was not decodable")
        }
    }

    func testCapturedWidgetTimelineStaysOnOneRevisionWhenStoreUpdatesConcurrently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppGroupSnapshotStore(directoryURL: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetA = now.addingTimeInterval(3_600)
        let resetB = now.addingTimeInterval(7_200)
        let snapshotA = UsageSnapshot(
            fetchedAt: now,
            windows: [UsageWindow(usedPercent: 10, durationMinutes: 300, resetsAt: resetA)]
        )
        let snapshotB = UsageSnapshot(
            fetchedAt: now.addingTimeInterval(1),
            windows: [UsageWindow(usedPercent: 90, durationMinutes: 10_080, resetsAt: resetB)]
        )
        try store.save(SharedUsageEnvelope(
            snapshot: snapshotA,
            serviceStatus: .available,
            lastAttemptAt: now
        ))

        // This is the provider's single immutable read. A writer is allowed to
        // publish revision B before the provider finishes building its entries.
        let capturedRevision = store.loadResult()
        let updateFinished = expectation(description: "revision B published")
        DispatchQueue.global().async {
            try? store.save(SharedUsageEnvelope(
                snapshot: snapshotB,
                serviceStatus: .available,
                lastAttemptAt: now.addingTimeInterval(1)
            ))
            updateFinished.fulfill()
        }
        wait(for: [updateFinished], timeout: 2)

        let timeline = WidgetSnapshotPolicy.timeline(from: capturedRevision, now: now)
        XCTAssertTrue(timeline.entries.map(\.date).contains(resetA))
        XCTAssertFalse(timeline.entries.map(\.date).contains(resetB))
        for entry in timeline.entries {
            switch entry.state {
            case .available(let snapshot), .stale(let snapshot, message: _):
                XCTAssertEqual(snapshot, snapshotA)
            case .loading, .unauthenticated, .failed:
                XCTFail("Timeline plan and entries must stay on captured revision A")
            }
        }
        XCTAssertEqual(store.load()?.snapshot, snapshotB)
    }
}

private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var failures: [String] { lock.withLock { storage } }
    func record(_ message: String) { lock.withLock { storage.append(message) } }
}
