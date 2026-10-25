import Darwin
import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
@testable import CodexUsageRuntime
#endif

final class CodexAppServerBrokerTests: XCTestCase {
    func testFakeServerEnforcesInitializeInitializedReadSequenceAndClientMetadata() async throws {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)

        let snapshot = try await broker.fetchRateLimits()

        XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 73)
        XCTAssertEqual(script.initializeCount, 1)
        XCTAssertEqual(script.initializedNotificationCount, 1)
        XCTAssertEqual(script.readCount, 1)
        XCTAssertEqual(script.handshakeViolationCount, 0)
        await broker.shutdown()

        let earlyReadScript = FakeScript()
        let earlyReadTransport = FakeTransport(
            script: earlyReadScript,
            executableURL: URL(fileURLWithPath: "/nonexistent/fake-codex"),
            onStop: {}
        )
        let earlyRead = try JSONSerialization.data(withJSONObject: [
            "id": "early-read",
            "method": "account/rateLimits/read",
            "params": NSNull()
        ])
        try earlyReadTransport.send(line: earlyRead)
        XCTAssertEqual(earlyReadScript.handshakeViolationCount, 1)
        XCTAssertEqual(earlyReadScript.readCount, 0)
        _ = await earlyReadTransport.stop()
    }

    func testIntegrationGeneratesSanitizedJSONLProtocolTranscript() async throws {
        let script = FakeScript()
        let broker = makeBroker(factory: FakeTransportFactory(script: script))
        _ = try await broker.fetchRateLimits()
        await broker.shutdown()

        let transcript = try script.sanitizedTranscriptJSONL()
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsage-Sanitized-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        try transcript.write(to: transcriptURL, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcript)

        let records = try transcript.split(separator: 0x0A).map { line -> [String: Any] in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            )
        }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2, 3])
        XCTAssertEqual(
            records.map { $0["method"] as? String },
            ["initialize", "initialized", "account/rateLimits/read"]
        )
        XCTAssertEqual(
            records.map { $0["idCategory"] as? String },
            ["initialize", "notification", "rate-limits"]
        )
        for record in records {
            XCTAssertEqual(Set(record.keys), Set(["sequence", "method", "idCategory"]))
        }

        let text = String(decoding: transcript, as: UTF8.self)
        for forbidden in [
            "params", "result", "usedPercent", "remainingPercent", "resetsAt",
            "codexHome", "token", "cookie", "/Users/", "initialize-", "rate-limits-"
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }

        let attachment = XCTAttachment(data: transcript, uniformTypeIdentifier: "public.json")
        attachment.name = "sanitized-app-server-transcript.jsonl"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTwentyConcurrentRefreshesUseOneChildAndOneRead() async throws {
        let script = FakeScript()
        script.holdReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)

        let results = Task {
            try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                for _ in 0..<20 {
                    group.addTask { try await broker.fetchRateLimits() }
                }
                var snapshots: [UsageSnapshot] = []
                for try await snapshot in group { snapshots.append(snapshot) }
                return snapshots
            }
        }

        let coalescedReadStarted = await waitUntil { script.readCount == 1 }
        XCTAssertTrue(coalescedReadStarted)
        XCTAssertEqual(factory.startCount, 1)
        script.releaseHeldReads()
        let snapshots = try await results.value
        XCTAssertEqual(snapshots.count, 20)
        XCTAssertTrue(snapshots.allSatisfy { $0.sevenDayWindow?.remainingPercent == 73 })
        await broker.shutdown()
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.maximumActiveCount, 1)
    }

    func testHungFactoryIsCoveredByStartupDeadlineAndLateTransportIsStopped() async {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        factory.holdStarts = true
        let broker = makeBroker(factory: factory, initializeTimeout: .milliseconds(25))

        let startedAt = ContinuousClock.now
        do {
            _ = try await broker.fetchRateLimits()
            XCTFail("Expected total startup timeout")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .initializeTimedOut)
        }
        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.activeCount, 0)

        factory.releaseHeldStarts()
        let lateTransportStopped = await waitUntil { factory.stopCount == 1 }
        XCTAssertTrue(lateTransportStopped)
        XCTAssertEqual(factory.activeCount, 0)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        await broker.shutdown()
    }

    func testUniqueRefreshCancellationStopsUnderlyingReadAndSession() async {
        let script = FakeScript()
        script.holdReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)
        let refresh = Task { try await broker.fetchRateLimits() }
        let readStarted = await waitUntil { script.readCount == 1 }
        XCTAssertTrue(readStarted)

        refresh.cancel()
        do {
            _ = try await refresh.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
        script.releaseHeldReads()
        await broker.shutdown()
    }

    func testOneCancelledWaiterDoesNotCancelSharedReadForRemainingWaiter() async throws {
        let script = FakeScript()
        script.holdReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)
        let cancelledWaiter = Task { try await broker.fetchRateLimits() }
        let successfulWaiter = Task { try await broker.fetchRateLimits() }
        let readStarted = await waitUntil { script.readCount == 1 }
        XCTAssertTrue(readStarted)
        let bothWaitersRegistered = await waitForRefreshWaiters(2, broker: broker)
        XCTAssertTrue(bothWaitersRegistered)

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(factory.activeCount, 1)

        script.releaseHeldReads()
        let snapshot = try await successfulWaiter.value
        XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 73)
        XCTAssertEqual(factory.startCount, 1)
        await broker.shutdown()
        XCTAssertEqual(factory.stopCount, 1)
    }

    func testLastCancelledWaiterStopsSharedReadAndClearsSession() async {
        let script = FakeScript()
        script.holdReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)
        let first = Task { try await broker.fetchRateLimits() }
        let last = Task { try await broker.fetchRateLimits() }
        let readStarted = await waitUntil { script.readCount == 1 }
        XCTAssertTrue(readStarted)
        let bothWaitersRegistered = await waitForRefreshWaiters(2, broker: broker)
        XCTAssertTrue(bothWaitersRegistered)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first waiter cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(factory.stopCount, 0)

        last.cancel()
        do {
            _ = try await last.value
            XCTFail("Expected last waiter cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
        script.releaseHeldReads()
        await broker.shutdown()
    }

    func testAutomaticReconciliationUpdatesWithoutForegroundOrNotificationsAndStopsWhenPaused() async {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(60))
        let broker = makeBroker(
            factory: factory,
            reconciliationInterval: .seconds(60),
            sleeper: sleeper
        )
        let events = LockedEvents()
        let stream = await broker.events()
        let eventTask = Task {
            for await event in stream { events.append(event) }
        }
        defer { eventTask.cancel() }

        _ = await broker.resume()
        let timerWaiting = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(timerWaiting)
        XCTAssertEqual(script.readCount, 1)

        script.normalUsedPercent = 40
        XCTAssertTrue(sleeper.releaseNext())
        let updated = await waitUntil {
            events.values.contains {
                guard case .snapshot(let snapshot, reason: .reconciliation) = $0 else { return false }
                return snapshot.sevenDayWindow?.remainingPercent == 60
            }
        }
        XCTAssertTrue(updated, "A timer alone must publish quota consumed by another session")
        XCTAssertEqual(script.readCount, 2)
        XCTAssertEqual(script.initializeCount, 1)
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.maximumActiveCount, 1)

        let nextTimerWaiting = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(nextTimerWaiting)
        let paused = await broker.suspend()
        XCTAssertTrue(paused)
        XCTAssertEqual(sleeper.pendingSleepCount, 0)
        XCTAssertFalse(sleeper.releaseNext(), "Pausing must cancel the periodic timer")
        XCTAssertEqual(script.readCount, 2)
        XCTAssertEqual(factory.activeCount, 0)
        XCTAssertEqual(factory.stopCount, 1)
        _ = await broker.shutdown()
    }

    func testAutomaticReconciliationCoalescesRepeatedTicksWithAnOutstandingRead() async {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(60))
        let broker = makeBroker(
            factory: factory,
            readTimeout: .seconds(5),
            reconciliationInterval: .seconds(60),
            sleeper: sleeper
        )
        _ = await broker.resume()
        let initialTimerWaiting = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(initialTimerWaiting)

        script.holdReads = true
        let manual = Task { try await broker.fetchRateLimits() }
        let readStarted = await waitUntil { script.readCount == 2 }
        XCTAssertTrue(readStarted)

        XCTAssertTrue(sleeper.releaseNext())
        let firstTickJoined = await waitForRefreshWaiters(2, broker: broker)
        XCTAssertTrue(firstTickJoined)
        let nextTimerWaiting = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(nextTimerWaiting)
        XCTAssertTrue(sleeper.releaseNext())
        let secondTickJoined = await waitForRefreshWaiters(3, broker: broker)
        XCTAssertTrue(secondTickJoined)
        XCTAssertEqual(script.readCount, 2, "Timer ticks must join the pending RPC rather than start another")
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.maximumActiveCount, 1)

        script.holdReads = false
        script.releaseHeldReads()
        switch await manual.result {
        case .success(let snapshot):
            XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 73)
        case .failure(let error):
            XCTFail("The shared read should complete: \(error)")
        }
        let readsCompleted = await waitForRefreshWaiters(0, broker: broker)
        XCTAssertTrue(readsCompleted)
        XCTAssertEqual(script.readCount, 2)
        _ = await broker.shutdown()
        XCTAssertEqual(sleeper.pendingSleepCount, 0)
        XCTAssertEqual(factory.stopCount, 1)
    }

    func testNotificationDuringReadSchedulesExactlyOneFollowUpFullRead() async throws {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory, notificationDebounce: .milliseconds(5))
        await broker.resume()
        XCTAssertEqual(script.readCount, 1)

        script.holdReads = true
        let manual = Task { try await broker.fetchRateLimits() }
        let manualReadStarted = await waitUntil { script.readCount == 2 }
        XCTAssertTrue(manualReadStarted)
        factory.latestTransport?.yieldJSON([
            "method": "account/rateLimits/updated",
            "params": ["rateLimits": [:]]
        ])
        try await Task.sleep(for: .milliseconds(20))
        script.holdReads = false
        script.releaseHeldReads()
        _ = try await manual.value

        let followUpReadStarted = await waitUntil { script.readCount == 3 }
        XCTAssertTrue(followUpReadStarted)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(script.readCount, 3)
        XCTAssertEqual(factory.startCount, 1)
        await broker.shutdown()
    }

    func testBlankLineAndUnknownNotificationDoNotCorruptOutstandingRead() async throws {
        let script = FakeScript()
        script.holdReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)
        let read = Task { try await broker.fetchRateLimits() }
        let readStarted = await waitUntil { script.readCount == 1 }
        XCTAssertTrue(readStarted)

        factory.latestTransport?.yield(Data(" \t\r".utf8))
        factory.latestTransport?.yieldJSON([
            "method": "future/notification",
            "params": ["unknown": true]
        ])
        script.releaseHeldReads()

        let snapshot = try await read.value
        XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 73)
        let diagnostics = await broker.diagnostics()
        XCTAssertEqual(diagnostics.unknownNotificationCount, 1)
        XCTAssertEqual(diagnostics.consecutiveFailures, 0)
        await broker.shutdown()
    }

    func testReadTimeoutFailsOnceAndStopsOwnedTransport() async {
        let script = FakeScript()
        script.ignoreReads = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory, readTimeout: .milliseconds(10))

        do {
            _ = try await broker.fetchRateLimits()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .readTimedOut)
        }
        let transportStopped = await waitUntil { factory.stopCount == 1 }
        XCTAssertTrue(transportStopped)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        await broker.shutdown()
    }

    func testTenConsecutiveCrashesStopRapidRetries() async {
        let script = FakeScript()
        script.closeOnRead = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(
            factory: factory,
            retryDelays: [.milliseconds(1)],
            maximumAutomaticFailures: 10
        )

        await broker.resume()
        let circuitReached = await waitUntil(timeout: 2) { factory.startCount == 10 }
        XCTAssertTrue(circuitReached)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(factory.startCount, 10)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
        let diagnostics = await broker.diagnostics()
        XCTAssertEqual(diagnostics.consecutiveFailures, 10)
        await broker.shutdown()
    }

    func testTransientFailureRecoversAfterFastRetryBudgetWithoutUserAction() async {
        let script = FakeScript()
        script.closeOnRead = true
        let factory = FakeTransportFactory(script: script)
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(300))
        let broker = makeBroker(
            factory: factory,
            sleeper: sleeper,
            retryDelays: [.milliseconds(1)],
            maximumAutomaticFailures: 3,
            slowRecoveryInterval: .seconds(300)
        )

        await broker.resume()
        let slowRetryScheduled = await waitUntil {
            factory.startCount == 3 && sleeper.pendingSleepCount == 1
        }
        XCTAssertTrue(slowRetryScheduled)
        XCTAssertEqual(factory.activeCount, 0)

        XCTAssertTrue(sleeper.releaseNext())
        let stillUsingSlowRetries = await waitUntil {
            factory.startCount == 4 && sleeper.pendingSleepCount == 1
        }
        XCTAssertTrue(stillUsingSlowRetries)

        script.closeOnRead = false
        XCTAssertTrue(sleeper.releaseNext())
        let recovered = await waitUntil {
            factory.startCount == 5 && script.successfulReadCount == 1
        }
        XCTAssertTrue(recovered)
        let counterReset = await waitForConsecutiveFailures(0, broker: broker)
        XCTAssertTrue(counterReset)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        await broker.shutdown()
    }

    func testSuspendCancelsSlowRecoveryAndResumeCanRetryImmediately() async {
        let script = FakeScript()
        script.closeOnRead = true
        let factory = FakeTransportFactory(script: script)
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(300))
        let broker = makeBroker(
            factory: factory,
            sleeper: sleeper,
            maximumAutomaticFailures: 1,
            slowRecoveryInterval: .seconds(300)
        )

        await broker.resume()
        let slowRetryScheduled = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(slowRetryScheduled)
        await broker.suspend()
        let cancelled = await waitUntil { sleeper.pendingSleepCount == 0 }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(sleeper.releaseNext())
        XCTAssertEqual(factory.startCount, 1)

        script.closeOnRead = false
        await broker.resume()
        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(script.successfulReadCount, 1)
        await broker.shutdown()
    }

    func testShutdownCancelsSlowRecoveryWithoutReplacementProcess() async {
        let script = FakeScript()
        script.closeOnRead = true
        let factory = FakeTransportFactory(script: script)
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(300))
        let broker = makeBroker(
            factory: factory,
            sleeper: sleeper,
            maximumAutomaticFailures: 1,
            slowRecoveryInterval: .seconds(300)
        )

        await broker.resume()
        let slowRetryScheduled = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(slowRetryScheduled)
        let shutdown = await broker.shutdown()
        XCTAssertTrue(shutdown)
        let cancelled = await waitUntil { sleeper.pendingSleepCount == 0 }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(sleeper.releaseNext())
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testSuccessfulRecoveryResetsBackoffCounter() async {
        let script = FakeScript()
        script.closeOnRead = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(
            factory: factory,
            retryDelays: [.milliseconds(5)],
            maximumAutomaticFailures: 10
        )

        let resume = Task { await broker.resume() }
        let retried = await waitUntil { factory.startCount >= 2 }
        XCTAssertTrue(retried)
        script.closeOnRead = false
        _ = await resume.value
        let recovered = await waitUntil { script.successfulReadCount >= 1 }
        XCTAssertTrue(recovered)
        let diagnostics = await broker.diagnostics()
        XCTAssertEqual(diagnostics.consecutiveFailures, 0)
        await broker.shutdown()
    }

    func testOneMalformedProtocolLineRetriesThenRecovers() async {
        let script = FakeScript()
        script.malformedReadsRemaining = 1
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(
            factory: factory,
            retryDelays: [.milliseconds(1)],
            maximumAutomaticFailures: 3
        )

        await broker.resume()

        let recovered = await waitUntil(timeout: 2) {
            factory.startCount == 2 && script.successfulReadCount == 1
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        let failureCounterReset = await waitForConsecutiveFailures(0, broker: broker)
        XCTAssertTrue(failureCounterReset)
        let recoveredDiagnostics = await broker.diagnostics()
        XCTAssertEqual(recoveredDiagnostics.consecutiveFailures, 0)
        await broker.shutdown()
    }

    func testPermanentMalformedProtocolStopsAtConfiguredRetryThreshold() async {
        let script = FakeScript()
        script.malformedRead = true
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(
            factory: factory,
            retryDelays: [.milliseconds(1)],
            maximumAutomaticFailures: 3
        )

        await broker.resume()

        let thresholdReached = await waitUntil(timeout: 2) { factory.startCount == 3 }
        XCTAssertTrue(thresholdReached)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(factory.startCount, 3)
        XCTAssertEqual(factory.activeCount, 0)
        let terminalDiagnostics = await broker.diagnostics()
        XCTAssertEqual(terminalDiagnostics.consecutiveFailures, 3)
        await broker.shutdown()
    }

    func testOneHundredResumeReadSuspendCyclesHaveOneActiveChild() async {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)

        for _ in 0..<100 {
            await broker.resume()
            await broker.suspend()
        }

        XCTAssertEqual(factory.startCount, 100)
        XCTAssertEqual(factory.stopCount, 100)
        XCTAssertEqual(factory.activeCount, 0)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        await broker.shutdown()
    }

    func testMalformedAndAuthenticationResponsesMapToSafeErrors() async {
        let malformedScript = FakeScript()
        malformedScript.malformedRead = true
        let malformedBroker = makeBroker(factory: FakeTransportFactory(script: malformedScript))
        do {
            _ = try await malformedBroker.fetchRateLimits()
            XCTFail("Expected protocol error")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .protocolError)
        }
        await malformedBroker.shutdown()

        let authScript = FakeScript()
        authScript.authenticationError = true
        let authBroker = makeBroker(factory: FakeTransportFactory(script: authScript))
        do {
            _ = try await authBroker.fetchRateLimits()
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .unauthenticated)
        }
        await authBroker.shutdown()
    }

    func testProductionFramerRejectsOversizeUnterminatedLine() async throws {
        let transport = try CodexProcessTransport.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "1048577", "/dev/zero"]
        )
        var observedError: CodexTransportError?
        do {
            for try await _ in transport.events {}
        } catch let error as CodexTransportError {
            observedError = error
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(observedError, .outputLineTooLarge)
        _ = await transport.stop()
        XCTAssertNil(transport.processIdentifier.map { pid in Darwin.kill(pid, 0) == 0 ? pid : nil } ?? nil)
    }

    func testProductionTransportBackpressureIsBoundedAndFatal() async throws {
        let transport = try CodexProcessTransport.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["bounded"]
        )
        try await Task.sleep(for: .milliseconds(50))
        var observedBackpressure = false
        do {
            for try await _ in transport.events {}
        } catch let error as CodexTransportError {
            observedBackpressure = error == .outputBackpressure
        } catch {}
        XCTAssertTrue(observedBackpressure)
        _ = await transport.stop()
    }

    func testActualPipeFramesSplitAndMultipleJSONLines() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import os,time; os.write(1,b'{\"part\":'); time.sleep(0.02); os.write(1,b'1}\\n{\"second\":2}\\n')"
            ]
        )
        var lines: [String] = []
        for try await event in transport.events {
            if case .stdoutLine(let data) = event {
                lines.append(String(decoding: data, as: UTF8.self))
                if lines.count == 2 { break }
            }
        }
        XCTAssertEqual(lines, ["{\"part\":1}", "{\"second\":2}"])
        _ = await transport.stop()
    }

    func testProductionTransportDeliversSmallResponseBeforeLongLivedPeerExits() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import sys,time; sys.stdin.buffer.readline(); sys.stdout.buffer.write(b'{\"id\":\"initialize-1\",\"result\":{}}\\n'); sys.stdout.buffer.flush(); time.sleep(30)"
            ]
        )
        let response = expectation(description: "small response arrives while peer remains alive")
        let receivedLine = LockedString()
        let collector = Task {
            do {
                for try await event in transport.events {
                    if case .stdoutLine(let data) = event {
                        receivedLine.value = String(decoding: data, as: UTF8.self)
                        response.fulfill()
                        return
                    }
                }
            } catch {}
        }

        try transport.send(line: Data("{\"id\":\"initialize-1\"}".utf8))
        await fulfillment(of: [response], timeout: 1)
        XCTAssertEqual(receivedLine.value, "{\"id\":\"initialize-1\",\"result\":{}}")
        XCTAssertEqual(transport.processIdentifier.map { Darwin.kill($0, 0) }, 0)
        collector.cancel()
        _ = await transport.stop()
    }

    func testThirtyTwoConcurrentStopsShareOneCleanupResult() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: ["-c", "import time; time.sleep(30)"]
        )
        let pid = try XCTUnwrap(transport.processIdentifier)

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { await transport.stop() }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.count, 32)
        XCTAssertEqual(Set(results), Set([true]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        XCTAssertNil(transport.processIdentifier)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testFalseTransportStopIsRetriedAndConcurrentWavesStaySingleFlight() async throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sleep.path))
        let transport = try CodexProcessTransport.start(
            executableURL: sleep,
            arguments: ["30"],
            terminationHandlerDeliveryDelayForTesting: .seconds(3),
            suppressSynchronousExitObservationForTesting: true
        )
        let ownedPID = try XCTUnwrap(transport.processIdentifier)

        let firstWave = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await transport.stop() } }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(Set(firstWave), Set([false]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertEqual(transport.processIdentifier, ownedPID, "false stop dropped logical PID ownership")

        try? await Task.sleep(for: .milliseconds(1_200))
        let secondWave = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await transport.stop() } }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(Set(secondWave), Set([true]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 2)
        XCTAssertNil(transport.processIdentifier)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        errno = 0
        XCTAssertEqual(Darwin.kill(ownedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testLiveChildAfterDroppedSIGKILLRetriesThirtyTwoStopCallersAsOneWave() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let signalGate = ProcessSignalGate()
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); sys.stdout.write('ready\\n'); sys.stdout.flush(); time.sleep(30)"
            ],
            processSignalForTesting: { processIdentifier, signal in
                signalGate.send(processIdentifier: processIdentifier, signal: signal)
            }
        )
        let ownedPID = try XCTUnwrap(transport.processIdentifier)
        defer { _ = Darwin.kill(ownedPID, SIGKILL) }
        let ready = expectation(description: "SIGTERM-ignoring child is ready")
        let reader = Task {
            do {
                for try await event in transport.events {
                    if case .stdoutLine(let data) = event,
                       String(decoding: data, as: UTF8.self) == "ready" {
                        ready.fulfill()
                        return
                    }
                }
            } catch {}
        }
        await fulfillment(of: [ready], timeout: 1)

        let firstWave = await stopWave(transport)
        XCTAssertEqual(Set(firstWave), Set([false]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertEqual(transport.forcedKillCountForTesting, 1)
        XCTAssertEqual(transport.processIdentifier, ownedPID)
        XCTAssertEqual(Darwin.kill(ownedPID, 0), 0, "first false wave lost a live child")
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)

        signalGate.release()
        let secondWave = await stopWave(transport)
        XCTAssertEqual(Set(secondWave), Set([true]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 2)
        XCTAssertEqual(transport.forcedKillCountForTesting, 2)
        XCTAssertNil(transport.processIdentifier)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
        errno = 0
        XCTAssertEqual(Darwin.kill(ownedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        reader.cancel()
    }

    func testExitedChildWithDeferredReadersRetriesThirtyTwoStopCallersAsOneWave() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let readerExitGate = BlockingTestGate()
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: ["-c", "import time; time.sleep(30)"],
            readerExitHookForTesting: { readerExitGate.wait() }
        )
        let ownedPID = try XCTUnwrap(transport.processIdentifier)
        defer {
            readerExitGate.release()
            _ = Darwin.kill(ownedPID, SIGKILL)
        }

        let firstWave = await stopWave(transport)
        XCTAssertEqual(Set(firstWave), Set([false]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertNil(transport.processIdentifier, "exited child retained a stale logical PID")
        XCTAssertEqual(transport.activeReaderCountForTesting, 2)
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
        errno = 0
        XCTAssertEqual(Darwin.kill(ownedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        readerExitGate.release()
        let secondWave = await stopWave(transport)
        XCTAssertEqual(Set(secondWave), Set([true]))
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 2)
        XCTAssertNil(transport.processIdentifier)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
    }

    func testBlockedNonreadingStdinIsWokenAndStopMeetsDeadline() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: ["-c", "import time; time.sleep(30)"]
        )
        let sendTask = Task.detached { () -> CodexTransportError? in
            do {
                try transport.send(line: Data(repeating: 0x78, count: 65_536))
                return nil
            } catch let error as CodexTransportError {
                return error
            } catch {
                return .writeAfterStop
            }
        }
        let sendBegan = await waitUntil { transport.activeSendCountForTesting == 1 }
        XCTAssertTrue(sendBegan)

        let start = ContinuousClock.now
        let stopped = await transport.stop()
        let elapsed = start.duration(to: .now)
        let sendError = await sendTask.value

        XCTAssertTrue(stopped)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(sendError == .writeAfterStop || sendError == .inputBackpressure)
        XCTAssertEqual(transport.activeSendCountForTesting, 0)
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
    }

    func testDescendantInheritingOutputPipesCannotHoldReadersOpen() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import os,time\npid=os.fork()\nif pid == 0:\n time.sleep(2); os._exit(0)\ntime.sleep(0.05); os._exit(0)"
            ]
        )
        try await Task.sleep(for: .milliseconds(150))

        let start = ContinuousClock.now
        let stopped = await transport.stop()
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(stopped)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
    }

    func testSIGTERMIgnoringChildReceivesOneSIGKILLAndIsReaped() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); sys.stdout.write('ready\\n'); sys.stdout.flush(); time.sleep(30)"
            ]
        )
        let ready = expectation(description: "child installed SIGTERM handler")
        let reader = Task {
            do {
                for try await event in transport.events {
                    if case .stdoutLine(let data) = event,
                       String(decoding: data, as: UTF8.self) == "ready" {
                        ready.fulfill()
                        return
                    }
                }
            } catch {}
        }
        await fulfillment(of: [ready], timeout: 1)
        let pid = try XCTUnwrap(transport.processIdentifier)

        let firstStop = await transport.stop()
        XCTAssertTrue(firstStop)
        reader.cancel()
        XCTAssertEqual(transport.forcedKillCountForTesting, 1)
        let repeatedStop = await transport.stop()
        XCTAssertTrue(repeatedStop)
        XCTAssertEqual(transport.forcedKillCountForTesting, 1)
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testStopEOFOversizeAndTerminationRaceHasOneTerminalCompletion() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import os,sys; sys.stdout.buffer.write(b'x'*1048577); sys.stdout.buffer.flush(); os._exit(3)"
            ]
        )
        let consumer = Task {
            do { for try await _ in transport.events {} } catch {}
        }
        try await Task.sleep(for: .milliseconds(20))
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { await transport.stop() } }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        await consumer.value

        XCTAssertEqual(Set(results).count, 1)
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
    }

    func testStderrFloodIsDrainedWithoutBlockingStdout() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: [
                "-c",
                "import sys; sys.stderr.buffer.write(b'x'*2000000); sys.stderr.flush(); sys.stdout.write('{}\\n'); sys.stdout.flush()"
            ]
        )
        var stdoutLine: String?
        for try await event in transport.events {
            if case .stdoutLine(let data) = event {
                stdoutLine = String(decoding: data, as: UTF8.self)
                break
            }
        }
        XCTAssertEqual(stdoutLine, "{}")
        _ = await transport.stop()
    }

    func testNonzeroExitIsObserved() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let transport = try CodexProcessTransport.start(
            executableURL: python,
            arguments: ["-c", "raise SystemExit(7)"]
        )
        var terminationStatus: Int32?
        for try await event in transport.events {
            if case .terminated(let status) = event {
                terminationStatus = status
                break
            }
        }
        XCTAssertEqual(terminationStatus, 7)
        _ = await transport.stop()
    }

    func testProductionLaunchFailureMapsToActionableBrokerError() {
        XCTAssertThrowsError(
            try CodexProcessTransport.start(
                executableURL: URL(fileURLWithPath: "/nonexistent/codex-usage-launch-test"),
                arguments: []
            )
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .launchFailed)
        }
    }

    func testCleanEOFCompletesOnceAndLeavesNoReaders() async throws {
        let transport = try CodexProcessTransport.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: []
        )
        for try await _ in transport.events {}
        let stopped = await transport.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
        XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
        XCTAssertEqual(transport.activeReaderCountForTesting, 0)
        XCTAssertNil(transport.processIdentifier)
    }

    func testInitializeTimeoutAndMalformedInitializeCleanTransport() async {
        let timeoutScript = FakeScript()
        timeoutScript.ignoreInitialize = true
        let timeoutFactory = FakeTransportFactory(script: timeoutScript)
        let timeoutBroker = makeBroker(
            factory: timeoutFactory,
            initializeTimeout: .milliseconds(10)
        )
        do {
            _ = try await timeoutBroker.fetchRateLimits()
            XCTFail("Expected initialize timeout")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .initializeTimedOut)
        }
        XCTAssertEqual(timeoutFactory.stopCount, 1)
        await timeoutBroker.shutdown()

        let malformedScript = FakeScript()
        malformedScript.malformedInitialize = true
        let malformedFactory = FakeTransportFactory(script: malformedScript)
        let malformedBroker = makeBroker(factory: malformedFactory)
        do {
            _ = try await malformedBroker.fetchRateLimits()
            XCTFail("Expected initialize protocol error")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .protocolError)
        }
        XCTAssertEqual(malformedFactory.stopCount, 1)
        await malformedBroker.shutdown()
    }

    func testOneFailureEmitsOneUnavailableEvent() async {
        let script = FakeScript()
        script.closeOnRead = true
        let broker = makeBroker(factory: FakeTransportFactory(script: script))
        let stream = await broker.events()
        let collector = LockedEvents()
        let eventTask = Task {
            for await event in stream { collector.append(event) }
        }
        _ = try? await broker.fetchRateLimits()
        try? await Task.sleep(for: .milliseconds(30))
        eventTask.cancel()
        let unavailableCount = collector.values.reduce(into: 0) { count, event in
            if case .connectionUnavailable = event { count += 1 }
        }
        XCTAssertEqual(unavailableCount, 1)
        await broker.shutdown()
    }

    func testStrictNumericResponseIDBoundaries() {
        XCTAssertEqual(CodexAppServerBroker.strictResponseID(NSNumber(value: Int64.min)), String(Int64.min))
        XCTAssertEqual(CodexAppServerBroker.strictResponseID(NSNumber(value: Int64.max)), String(Int64.max))
        XCTAssertEqual(CodexAppServerBroker.strictResponseID(NSNumber(value: 42.0)), "42")
        XCTAssertNil(CodexAppServerBroker.strictResponseID(NSNumber(value: 42.5)))
        XCTAssertNil(CodexAppServerBroker.strictResponseID(NSNumber(value: UInt64.max)))
        XCTAssertNil(CodexAppServerBroker.strictResponseID(true))
        XCTAssertNil(CodexAppServerBroker.strictResponseID(""))
    }

    func testForwardCompatibleDriftIsCountedByCategoryWithoutBreakingSession() async throws {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)
        _ = try await broker.fetchRateLimits()

        factory.latestTransport?.yieldJSON([
            "method": "future/nonSensitiveNotification",
            "params": ["privatePayload": "must-not-be-copied"]
        ])
        factory.latestTransport?.yieldJSON([
            "id": "unknown-response-id",
            "result": ["privatePayload": "must-not-be-copied"]
        ])
        var diagnostics = await broker.diagnostics()
        for _ in 0..<100 where diagnostics.unknownNotificationCount < 1 || diagnostics.unknownResponseIDCount < 1 {
            await Task.yield()
            diagnostics = await broker.diagnostics()
        }
        XCTAssertEqual(diagnostics.unknownNotificationCount, 1)
        XCTAssertEqual(diagnostics.unknownResponseIDCount, 1)
        XCTAssertEqual(diagnostics.consecutiveFailures, 0)
        XCTAssertEqual(factory.startCount, 1)
        await broker.shutdown()
    }

    func testParserDriftDiagnosticsAccumulateDiscardAndCollisionCategories() async throws {
        let script = FakeScript()
        script.readFixture = .invalidSibling
        let factory = FakeTransportFactory(script: script)
        let broker = makeBroker(factory: factory)

        let first = try await broker.fetchRateLimits()
        XCTAssertEqual(first.windows.count, 1)
        script.readFixture = .sameDurationCollision
        let second = try await broker.fetchRateLimits()
        XCTAssertEqual(second.windows.count, 2)

        let diagnostics = await broker.diagnostics()
        XCTAssertEqual(diagnostics.invalidWindowDiscardCount, 1)
        XCTAssertEqual(diagnostics.sameDurationCollisionCount, 1)
        XCTAssertEqual(diagnostics.consecutiveFailures, 0)
        await broker.shutdown()
    }

    func testSanitizedDiagnosticContainsNoSensitiveValuesOrPaths() {
        let report = SanitizedDiagnosticReport.make(
            diagnostics: BrokerDiagnostics(
                executablePath: "/Users/example/secret/codex",
                executableVersion: "codex-cli 1.2.3\ntoken=secret",
                processIdentifier: 123,
                consecutiveFailures: 2,
                unknownNotificationCount: 3,
                unknownResponseIDCount: 4,
                invalidWindowDiscardCount: 5,
                sameDurationCollisionCount: 6
            ),
            state: "available",
            automaticUpdatesPaused: false
        )
        for forbidden in [
            "/Users/", "secret", "token=", "auth.json", "email", "cookie",
            "stderr", "usedPercent", "remainingPercent", "rateLimits"
        ] {
            XCTAssertFalse(report.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertTrue(report.contains("custom validated location"))
        XCTAssertTrue(report.contains("Codex version: unavailable"))
        XCTAssertTrue(report.contains("Unknown notifications: 3"))
        XCTAssertTrue(report.contains("Unknown response IDs: 4"))
        XCTAssertTrue(report.contains("Invalid windows discarded: 5"))
        XCTAssertTrue(report.contains("Same-duration collisions: 6"))
        XCTAssertFalse(report.contains("123"))
    }

    func testApplicationDiscoveryFindsCurrentLayoutWithoutCLIInPathAndFallsBackToLegacy() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("CodexDiscovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let application = root.appendingPathComponent("Renamed ChatGPT.app", isDirectory: true)
        let nativeBinary = application.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        let legacyBinary = application.appendingPathComponent("Contents/Resources/codex")
        let paths = CodexExecutableResolver.applicationExecutablePaths(at: application)

        for binary in [nativeBinary, legacyBinary] {
            try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.deletingLastPathComponent().path)
            try manager.copyItem(atPath: "/usr/bin/true", toPath: binary.path)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }

        // Both layouts may coexist during an update; prefer the current native CLI.
        XCTAssertEqual(try CodexExecutableResolver.resolveCandidates(paths).get(), nativeBinary)
        try manager.removeItem(at: legacyBinary)
        XCTAssertEqual(try CodexExecutableResolver.resolveCandidates(paths).get(), nativeBinary)
        try manager.copyItem(atPath: "/usr/bin/true", toPath: legacyBinary.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyBinary.path)
        try manager.removeItem(at: nativeBinary)
        XCTAssertEqual(try CodexExecutableResolver.resolveCandidates(paths).get(), legacyBinary)
        try manager.removeItem(at: legacyBinary)
        XCTAssertThrowsError(try CodexExecutableResolver.resolveCandidates(paths).get()) {
            XCTAssertEqual($0 as? CodexAppServerError, .executableNotFound)
        }
    }

    func testApplicationDiscoveryKeepsExecutableSecurityValidation() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("CodexDiscovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let application = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let nativeBinary = application.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        try manager.createDirectory(at: nativeBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(atPath: "/usr/bin/true", toPath: nativeBinary.path)
        try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: nativeBinary.path)
        XCTAssertThrowsError(try CodexExecutableResolver.resolveCandidates(
            CodexExecutableResolver.applicationExecutablePaths(at: application)
        ).get()) {
            XCTAssertEqual($0 as? CodexAppServerError, .executableRejected)
        }
    }

    func testExecutableValidationRejectsWritableAndGroupPathsWithoutShellParsing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        let safeDirectory = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safeDirectory.path)
        let oddName = safeDirectory.appendingPathComponent("codex with spaces 'quotes';touch-pwned")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: oddName.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oddName.path)
        XCTAssertEqual(CodexExecutableResolver.validatedExecutable(path: oddName.path)?.path, oddName.path)

        let marker = safeDirectory.appendingPathComponent("touch-pwned")
        let process = Process()
        process.executableURL = oddName
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let writableFile = safeDirectory.appendingPathComponent("writable")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: writableFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writableFile.path)
        XCTAssertNil(CodexExecutableResolver.validatedExecutable(path: writableFile.path))

        let writableDirectory = root.appendingPathComponent("writable-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writableDirectory.path)
        let protectedFile = writableDirectory.appendingPathComponent("codex")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: protectedFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedFile.path)
        XCTAssertNil(CodexExecutableResolver.validatedExecutable(path: protectedFile.path))

        let groupDirectory = root
            .appendingPathComponent("Library/Group Containers/group.example", isDirectory: true)
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: groupDirectory.path)
        let groupFile = groupDirectory.appendingPathComponent("codex")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: groupFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: groupFile.path)
        XCTAssertNil(CodexExecutableResolver.validatedExecutable(path: groupFile.path))

        let symlink = safeDirectory.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: oddName)
        XCTAssertEqual(CodexExecutableResolver.validatedExecutable(path: symlink.path)?.path, oddName.path)
    }

    func testRealProcessTransportHundredCycleMixedSuccessTimeoutCancellationCrashHasNoOrphansOrFDGrowth() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let before = try fileDescriptorCount()
        for index in 0..<100 {
            let scenario = index % 4
            let program: String
            switch scenario {
            case 0:
                program = "import sys,time; sys.stdin.buffer.readline(); sys.stdout.write('{\"ok\":true}\\n'); sys.stdout.flush(); time.sleep(30)"
            case 1, 2:
                program = "import sys,time; sys.stdin.buffer.readline(); time.sleep(30)"
            default:
                program = "import os,sys; sys.stdin.buffer.readline(); os._exit(7)"
            }
            let weakBox: WeakTransportBox
            let pid: Int32
            do {
                let transport = try CodexProcessTransport.start(
                    executableURL: python,
                    arguments: ["-c", program]
                )
                weakBox = WeakTransportBox(transport)
                pid = try XCTUnwrap(transport.processIdentifier)
                try transport.send(
                    line: Data("{\"id\":\"stress\",\"method\":\"read\"}".utf8)
                )

                switch scenario {
                case 0:
                    var receivedResponse = false
                    for try await event in transport.events {
                        if case .stdoutLine(let line) = event {
                            receivedResponse = String(decoding: line, as: UTF8.self) == "{\"ok\":true}"
                            break
                        }
                    }
                    XCTAssertTrue(receivedResponse, "success cycle \(index)")
                case 1:
                    // A test deadline expires before the peer responds.
                    try? await Task.sleep(for: .milliseconds(5))
                case 2:
                    let pendingRead = Task {
                        do { for try await _ in transport.events {} } catch {}
                    }
                    await Task.yield()
                    pendingRead.cancel()
                    await pendingRead.value
                default:
                    var status: Int32?
                    for try await event in transport.events {
                        if case .terminated(let value) = event {
                            status = value
                            break
                        }
                    }
                    XCTAssertEqual(status, 7, "crash cycle \(index)")
                }

                let stopped = await transport.stop()
                XCTAssertTrue(stopped, "stop cycle \(index)")
                XCTAssertEqual(transport.cleanupExecutionCountForTesting, 1)
                XCTAssertEqual(transport.terminalCompletionCountForTesting, 1)
                XCTAssertEqual(transport.activeReaderCountForTesting, 0)
                errno = 0
                XCTAssertEqual(Darwin.kill(pid, 0), -1, "orphan cycle \(index)")
                XCTAssertEqual(errno, ESRCH, "reap cycle \(index)")
            }
            let released = await waitUntil { weakBox.isEmpty }
            XCTAssertTrue(released, "transport leaked in cycle \(index)")
        }
        let after = try fileDescriptorCount()
        XCTAssertLessThanOrEqual(after, before + 3)
    }

    func testImmediateShutdownCancelsAndReapsVersionProbe() async throws {
        let descriptorCountBefore = try fileDescriptorCount()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVersionProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let hangingExecutable = directory.appendingPathComponent("codex-probe")
        let readyFile = directory.appendingPathComponent("ready")
        let source = """
        #!/usr/bin/python3
        import signal
        import time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(\(readyFile.path.debugDescription), "w") as ready:
            ready.write("ready")
        time.sleep(30)
        """
        try Data(source.utf8).write(to: hangingExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hangingExecutable.path)

        let factory = FakeTransportFactory(script: FakeScript(), executableURL: hangingExecutable)
        let broker = makeBroker(
            factory: factory,
            versionInspectionHandlerDelayForTesting: .seconds(2)
        )
        var ownedPID: Int32?
        do {
            _ = try await broker.fetchRateLimits()
            let probeReady = await waitUntil(timeout: 2) {
                FileManager.default.fileExists(atPath: readyFile.path)
            }
            XCTAssertTrue(probeReady)
            let diagnostics = await broker.diagnostics()
            ownedPID = try XCTUnwrap(diagnostics.versionProcessIdentifier)
        } catch {
            await broker.shutdown()
            throw error
        }

        let shutdownStartedAt = ContinuousClock.now
        let initialShutdownCompleted = await broker.shutdown()
        XCTAssertTrue(initialShutdownCompleted)
        XCTAssertLessThan(shutdownStartedAt.duration(to: .now), .seconds(2))
        assertProcessDoesNotExist(ownedPID, message: "SIGKILL version probe")
        // The delayed delivery arrives after the fallback has independently
        // confirmed reaping. It must be harmless and must not resume twice.
        try? await Task.sleep(for: .milliseconds(2_100))
        let repeatedShutdownCompleted = await broker.shutdown()
        XCTAssertTrue(repeatedShutdownCompleted)
        let descriptorCountAfter = try fileDescriptorCount()
        XCTAssertLessThanOrEqual(descriptorCountAfter, descriptorCountBefore + 3)
    }

    func testBrokerStopIsSingleFlightAndShutdownDominatesSuspension() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        let broker = makeBroker(factory: factory)
        _ = try await broker.fetchRateLimits()
        await broker.waitForVersionInspectionForTesting()
        factory.holdStops = true

        let suspendTask = Task { await broker.suspend() }
        let stopEntered = await waitUntil { factory.stopAttemptCount == 1 }
        XCTAssertTrue(stopEntered)

        let shutdownFinished = LockedFlag()
        let shutdownTask = Task {
            let result = await broker.shutdown()
            shutdownFinished.value = true
            return result
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(shutdownFinished.value, "joined shutdown returned before owned stop")

        do {
            _ = try await broker.fetchRateLimits()
            XCTFail("cleanup-pending broker accepted a replacement transport")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .connectionClosed)
        }
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopAttemptCount, 1)

        factory.releaseHeldStops()
        let suspendCompleted = await suspendTask.value
        let shutdownCompleted = await shutdownTask.value
        XCTAssertFalse(suspendCompleted, "suspend applied stale side effects after shutdown won")
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(factory.stopAttemptCount, 1)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testBrokerRetainsTransportAfterFalseStopAndRetriesIt() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        factory.stopResults = [false, true]
        let broker = makeBroker(factory: factory)
        _ = try await broker.fetchRateLimits()
        await broker.waitForVersionInspectionForTesting()

        let firstShutdown = await broker.shutdown()
        XCTAssertFalse(firstShutdown)
        XCTAssertEqual(factory.stopAttemptCount, 1)
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(factory.activeCount, 1)

        do {
            _ = try await broker.fetchRateLimits()
            XCTFail("shutdown-pending broker launched a replacement transport")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .connectionClosed)
        }
        XCTAssertEqual(factory.startCount, 1)

        let retriedShutdown = await broker.shutdown()
        XCTAssertTrue(retriedShutdown)
        XCTAssertEqual(factory.stopAttemptCount, 2)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testCleanupRetryOutlivesAutomaticFailureCeilingWithoutStartingReplacement() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        factory.stopResults = [false, true]
        let broker = makeBroker(factory: factory, maximumAutomaticFailures: 1)
        let resumed = await broker.resume()
        XCTAssertTrue(resumed)
        await broker.waitForVersionInspectionForTesting()
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.activeCount, 1)

        factory.latestTransport?.finish()
        let firstFalseStopRetainedOwnership = await waitUntil {
            factory.stopAttemptCount == 1 && factory.activeCount == 1
        }
        XCTAssertTrue(firstFalseStopRetainedOwnership)

        let independentCleanupCompleted = await waitUntil(timeout: 2) {
            factory.stopAttemptCount == 2 && factory.activeCount == 0
        }
        XCTAssertTrue(independentCleanupCompleted)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.startCount, 1, "circuit-open cleanup launched a replacement")
        XCTAssertEqual(factory.maximumActiveCount, 1)

        let shutdownCompleted = await broker.shutdown()
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testDeferredCleanupRecoveryRestoresPeriodicReads() async {
        let script = FakeScript()
        let factory = FakeTransportFactory(script: script)
        factory.stopResults = [false, true]
        let sleeper = ControlledReconciliationSleeper(interval: .seconds(60))
        let broker = makeBroker(
            factory: factory,
            reconciliationInterval: .seconds(60),
            sleeper: sleeper
        )

        await broker.resume()
        await broker.waitForVersionInspectionForTesting()
        let initialTimerStarted = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(initialTimerStarted)
        factory.latestTransport?.finish()

        let reconnected = await waitUntil(timeout: 2) {
            factory.startCount == 2 && script.successfulReadCount == 2
        }
        XCTAssertTrue(reconnected)
        let timerRestored = await waitUntil { sleeper.pendingSleepCount == 1 }
        XCTAssertTrue(timerRestored)
        XCTAssertTrue(sleeper.releaseNext())
        let reconciled = await waitUntil { script.successfulReadCount == 3 }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        await broker.shutdown()
    }

    func testResumeDrainsCleanupPendingBeforeStartingReplacementTransport() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        factory.stopResults = [false, true]
        let broker = makeBroker(factory: factory)
        _ = try await broker.fetchRateLimits()
        await broker.waitForVersionInspectionForTesting()

        let suspended = await broker.suspend()
        XCTAssertFalse(suspended)
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.activeCount, 1)

        let resumed = await broker.resume()
        XCTAssertTrue(resumed)
        XCTAssertEqual(factory.stopAttemptCount, 2)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        XCTAssertEqual(factory.activeCount, 1)

        let shutdown = await broker.shutdown()
        XCTAssertTrue(shutdown)
        XCTAssertEqual(factory.stopCount, 2)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testRecoveryResumingBeforeStopFinalizationCannotStartAfterShutdownEpoch() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        let recoveryWillDrain = LockedFlag()
        let recoveryDidDrain = LockedFlag()
        let stopFinalizationGate = AsyncTestGate()
        let broker = makeBroker(
            factory: factory,
            teardownRaceHooksForTesting: BrokerTeardownRaceHooks(
                ensureReadyWillDrainRetiredTransport: {
                    recoveryWillDrain.value = true
                },
                ensureReadyDidDrainRetiredTransport: {
                    recoveryDidDrain.value = true
                },
                stopBeforeStableStateVerification: {
                    await stopFinalizationGate.enter()
                }
            )
        )
        _ = try await broker.fetchRateLimits()
        await broker.waitForVersionInspectionForTesting()
        factory.holdStops = true
        factory.latestTransport?.finish()
        let retiredStopEntered = await waitUntil { factory.stopAttemptCount == 1 }
        XCTAssertTrue(retiredStopEntered)

        let recovery = Task { try await broker.fetchRateLimits() }
        let recoveryAttached = await waitUntil { recoveryWillDrain.value }
        XCTAssertTrue(recoveryAttached)

        let suspend = Task { await broker.suspend() }
        let shutdownFinished = LockedFlag()
        let shutdown = Task {
            let result = await broker.shutdown()
            shutdownFinished.value = true
            return result
        }

        factory.releaseHeldStops()
        let stopReachedFinalVerification = await waitUntil { stopFinalizationGate.hasEntered }
        XCTAssertTrue(stopReachedFinalVerification)
        let recoveryResumedFirst = await waitUntil { recoveryDidDrain.value }
        XCTAssertTrue(recoveryResumedFirst)
        XCTAssertEqual(factory.startCount, 1, "stale recovery crossed the stop epoch")
        switch await recovery.result {
        case .success:
            XCTFail("stale recovery succeeded while shutdown owned the lifecycle")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError
                    || (error as? CodexAppServerError) == .connectionClosed
            )
        }
        XCTAssertFalse(shutdownFinished.value, "shutdown bypassed its stable-state check")

        stopFinalizationGate.release()
        let suspendCompleted = await suspend.value
        let shutdownCompleted = await shutdown.value
        XCTAssertFalse(suspendCompleted, "shutdown must dominate the joined suspend")
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopAttemptCount, 1)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(factory.activeCount, 0)
    }

    func testShutdownRetainsHeldFactoryOwnershipUntilLateTransportStops() async throws {
        let factory = FakeTransportFactory(script: FakeScript())
        factory.holdStartsAfterCreatingTransport = true
        let broker = makeBroker(factory: factory)
        let fetchTask = Task { try await broker.fetchRateLimits() }
        let hiddenChildStarted = await waitUntil {
            factory.startCount == 1 && factory.activeCount == 1
        }
        XCTAssertTrue(hiddenChildStarted)

        let firstStartedAt = ContinuousClock.now
        let firstShutdown = await broker.shutdown()
        XCTAssertFalse(firstShutdown)
        XCTAssertLessThan(firstStartedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(factory.activeCount, 1)

        let secondShutdown = await broker.shutdown()
        XCTAssertFalse(secondShutdown)
        do {
            _ = try await broker.fetchRateLimits()
            XCTFail("unresolved factory ownership allowed a replacement start")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .connectionClosed)
        }
        XCTAssertEqual(factory.startCount, 1)

        factory.releaseHeldStartsAfterCreatingTransport()
        _ = await fetchTask.result
        let lateTransportStopped = await waitUntil(timeout: 2) {
            factory.stopCount == 1 && factory.activeCount == 0
        }
        XCTAssertTrue(lateTransportStopped)

        let finalShutdown = await broker.shutdown()
        XCTAssertTrue(finalShutdown)
        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopAttemptCount, 1)
        XCTAssertEqual(factory.stopCount, 1)
    }

    func testVersionInspectionRunFailureCompletesWithoutRetainingProbeOrFDs() async throws {
        let descriptorCountBefore = try fileDescriptorCount()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProbeRunFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let invalidExecutable = directory.appendingPathComponent("codex-invalid")
        try Data("not a valid executable format\n".utf8).write(to: invalidExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: invalidExecutable.path
        )

        let factory = FakeTransportFactory(
            script: FakeScript(),
            executableURL: invalidExecutable
        )
        let broker = makeBroker(factory: factory)
        _ = try await broker.fetchRateLimits()

        let inspectionStartedAt = ContinuousClock.now
        await broker.waitForVersionInspectionForTesting()
        XCTAssertLessThan(inspectionStartedAt.duration(to: .now), .seconds(1))
        let diagnostics = await broker.diagnostics()
        XCTAssertEqual(diagnostics.executablePath, invalidExecutable.path)
        XCTAssertNil(diagnostics.executableVersion)
        XCTAssertNil(diagnostics.versionProcessIdentifier)
        let shutdownCompleted = await broker.shutdown()
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(factory.activeCount, 0)

        let descriptorCountAfter = try fileDescriptorCount()
        XCTAssertLessThanOrEqual(descriptorCountAfter, descriptorCountBefore + 3)
    }

    func testPendingVersionTeardownCannotBeOverwrittenByRefreshOrRedetect() async throws {
        let descriptorCountBefore = try fileDescriptorCount()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexPendingProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let executable = directory.appendingPathComponent("codex-probe")
        let readyFile = directory.appendingPathComponent("ready")
        let source = """
        #!/usr/bin/python3
        import signal
        import time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(\(readyFile.path.debugDescription), "w") as ready:
            ready.write("ready")
        time.sleep(30)
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let factory = FakeTransportFactory(script: FakeScript(), executableURL: executable)
        let broker = makeBroker(
            factory: factory,
            versionInspectionHandlerDelayForTesting: .seconds(2),
            suppressSynchronousVersionExitObservationForTesting: true
        )

        do {
            _ = try await broker.fetchRateLimits()
            let probeReady = await waitUntil(timeout: 2) {
                FileManager.default.fileExists(atPath: readyFile.path)
            }
            XCTAssertTrue(probeReady)
            let running = await broker.diagnostics()
            let ownedPID = try XCTUnwrap(running.versionProcessIdentifier)

            let firstShutdown = Task { await broker.shutdown() }
            let joinedShutdown = Task { await broker.shutdown() }
            let initialShutdownCompleted = await firstShutdown.value
            let joinedShutdownCompleted = await joinedShutdown.value
            XCTAssertFalse(initialShutdownCompleted)
            XCTAssertFalse(joinedShutdownCompleted)
            assertProcessDoesNotExist(ownedPID, message: "pending teardown child")
            var pending = await broker.diagnostics()
            XCTAssertEqual(pending.versionProcessIdentifier, ownedPID)

            do {
                _ = try await broker.fetchRateLimits()
                XCTFail("shutdown-pending broker accepted a new fetch")
            } catch {
                XCTAssertEqual(error as? CodexAppServerError, .connectionClosed)
            }
            pending = await broker.diagnostics()
            XCTAssertEqual(pending.versionProcessIdentifier, ownedPID)
            XCTAssertEqual(factory.startCount, 1)

            await broker.redetect()
            pending = await broker.diagnostics()
            XCTAssertEqual(pending.versionProcessIdentifier, ownedPID)
            XCTAssertEqual(pending.executablePath, executable.path)
            XCTAssertEqual(factory.activeCount, 0)
            XCTAssertEqual(factory.startCount, 1)

            try? await Task.sleep(for: .milliseconds(2_100))
            let repeatedShutdownCompleted = await broker.shutdown()
            XCTAssertTrue(repeatedShutdownCompleted)
            let completed = await broker.diagnostics()
            XCTAssertNil(completed.versionProcessIdentifier)
        } catch {
            try? await Task.sleep(for: .milliseconds(2_100))
            await broker.shutdown()
            throw error
        }

        let descriptorCountAfter = try fileDescriptorCount()
        XCTAssertLessThanOrEqual(descriptorCountAfter, descriptorCountBefore + 3)
    }

    func testExplicitRedetectClearsDiagnosticsAndReinspectsSamePathUpgradeOrDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRedetect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let executable = directory.appendingPathComponent("codex")
        try writeVersionExecutable("codex-test 1.0", to: executable)

        let factory = FakeTransportFactory(
            script: FakeScript(),
            executableURL: executable,
            requiresExecutableToExist: true
        )
        let broker = makeBroker(factory: factory)
        do {
            _ = try await broker.fetchRateLimits()
            await broker.waitForVersionInspectionForTesting()
            var diagnostics = await broker.diagnostics()
            XCTAssertEqual(diagnostics.executablePath, executable.path)
            XCTAssertEqual(diagnostics.executableVersion, "codex-test 1.0")

            await broker.redetect()
            diagnostics = await broker.diagnostics()
            XCTAssertNil(diagnostics.executablePath)
            XCTAssertNil(diagnostics.executableVersion)
            try writeVersionExecutable("codex-test 2.0", to: executable)

            _ = try await broker.fetchRateLimits()
            await broker.waitForVersionInspectionForTesting()
            diagnostics = await broker.diagnostics()
            XCTAssertEqual(diagnostics.executablePath, executable.path)
            XCTAssertEqual(diagnostics.executableVersion, "codex-test 2.0")

            await broker.redetect()
            try FileManager.default.removeItem(at: executable)
            do {
                _ = try await broker.fetchRateLimits()
                XCTFail("Expected deleted executable to be rediscovered as missing")
            } catch {
                XCTAssertEqual(error as? CodexAppServerError, .executableNotFound)
            }
            diagnostics = await broker.diagnostics()
            XCTAssertNil(diagnostics.executablePath)
            XCTAssertNil(diagnostics.executableVersion)
            XCTAssertEqual(factory.activeCount, 0)
        } catch {
            await broker.shutdown()
            throw error
        }
        await broker.shutdown()
    }

    func testVersionInspectionAccepts4096BytesAndRejects4097Bytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVersionLimit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let executable = directory.appendingPathComponent("codex")
        let factory = FakeTransportFactory(script: FakeScript(), executableURL: executable)
        let broker = makeBroker(factory: factory)

        do {
            let maximumVersion = String(repeating: "v", count: 4_095)
            try writeVersionExecutable(maximumVersion, to: executable)
            _ = try await broker.fetchRateLimits()
            await broker.waitForVersionInspectionForTesting()
            var diagnostics = await broker.diagnostics()
            XCTAssertEqual(diagnostics.executableVersion, maximumVersion)

            await broker.redetect()
            try writeVersionExecutable(String(repeating: "v", count: 4_096), to: executable)
            _ = try await broker.fetchRateLimits()
            await broker.waitForVersionInspectionForTesting()
            diagnostics = await broker.diagnostics()
            XCTAssertNil(diagnostics.executableVersion)
        } catch {
            await broker.shutdown()
            throw error
        }
        await broker.shutdown()
    }

    func testVersionInspectionDoesNotWaitForDescendantHoldingStdoutOpen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVersionInheritedPipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let executable = directory.appendingPathComponent("codex")
        let descendantPIDFile = directory.appendingPathComponent("descendant-pid")
        try writeInheritedOutputExecutable(
            version: "codex-inherited 1.0",
            descendantPIDFile: descendantPIDFile,
            to: executable
        )
        defer {
            if let processIdentifier = try? processIdentifier(from: descendantPIDFile) {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        let broker = makeBroker(
            factory: FakeTransportFactory(script: FakeScript(), executableURL: executable)
        )
        var descendantPID: Int32?
        do {
            _ = try await broker.fetchRateLimits()
            let startedAt = ContinuousClock.now
            await broker.waitForVersionInspectionForTesting()
            XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
            let diagnostics = await broker.diagnostics()
            XCTAssertEqual(diagnostics.executableVersion, "codex-inherited 1.0")
            descendantPID = try processIdentifier(from: descendantPIDFile)
        } catch {
            await broker.shutdown()
            throw error
        }
        await broker.shutdown()
        if let descendantPID {
            _ = Darwin.kill(descendantPID, SIGKILL)
            let descendantExited = await waitUntil(timeout: 2) {
                errno = 0
                return Darwin.kill(descendantPID, 0) < 0 && errno == ESRCH
            }
            XCTAssertTrue(descendantExited, "fixture descendant was not reaped")
        }
    }

    func testOneHundredVersionProbeRedetectDeletionCyclesHaveNoOrphansOrFDGrowth() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVersionStress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let executable = directory.appendingPathComponent("codex")
        let processIdentifierFile = directory.appendingPathComponent("probe-pid")
        let descriptorCountBefore = try fileDescriptorCount()
        let stressStartedAt = ContinuousClock.now
        let factory = FakeTransportFactory(
            script: FakeScript(),
            executableURL: executable,
            requiresExecutableToExist: true
        )
        let broker = makeBroker(factory: factory)
        var stressError: Error?

        do {
            for iteration in 0..<100 {
                try? FileManager.default.removeItem(at: processIdentifierFile)
                let expectedVersion = "codex-stress \(iteration)"
                try writeTrackedVersionExecutable(
                    version: expectedVersion,
                    processIdentifierFile: processIdentifierFile,
                    to: executable
                )
                _ = try await broker.fetchRateLimits()
                let inspectionStartedAt = ContinuousClock.now
                await broker.waitForVersionInspectionForTesting()
                XCTAssertLessThan(
                    inspectionStartedAt.duration(to: .now),
                    .seconds(3),
                    "inspection cycle \(iteration)"
                )
                let inspected = await broker.diagnostics()
                XCTAssertEqual(inspected.executablePath, executable.path, "path cycle \(iteration)")
                XCTAssertEqual(inspected.executableVersion, expectedVersion, "version cycle \(iteration)")
                XCTAssertNil(inspected.versionProcessIdentifier, "live probe cycle \(iteration)")
                let ownedPID = try processIdentifier(from: processIdentifierFile)
                assertProcessDoesNotExist(ownedPID, message: "probe cycle \(iteration)")

                await broker.redetect()
                let redetected = await broker.diagnostics()
                XCTAssertNil(redetected.executablePath, "redetect path cycle \(iteration)")
                XCTAssertNil(redetected.executableVersion, "redetect version cycle \(iteration)")
                XCTAssertEqual(factory.activeCount, 0, "active after redetect cycle \(iteration)")

                try FileManager.default.removeItem(at: executable)
                do {
                    _ = try await broker.fetchRateLimits()
                    XCTFail("deleted executable launched in cycle \(iteration)")
                } catch {
                    XCTAssertEqual(
                        error as? CodexAppServerError,
                        .executableNotFound,
                        "deletion cycle \(iteration)"
                    )
                }
                let deleted = await broker.diagnostics()
                XCTAssertNil(deleted.executablePath, "deleted path cycle \(iteration)")
                XCTAssertNil(deleted.executableVersion, "deleted version cycle \(iteration)")
            }
        } catch {
            stressError = error
        }

        let shutdownStartedAt = ContinuousClock.now
        await broker.shutdown()
        XCTAssertLessThan(shutdownStartedAt.duration(to: .now), .seconds(3))
        XCTAssertEqual(factory.activeCount, 0)
        XCTAssertEqual(factory.maximumActiveCount, 1)
        XCTAssertEqual(factory.startCount, 200)
        XCTAssertEqual(factory.stopCount, 100)
        XCTAssertLessThan(stressStartedAt.duration(to: .now), .seconds(60))
        let descriptorCountAfter = try fileDescriptorCount()
        XCTAssertLessThanOrEqual(descriptorCountAfter, descriptorCountBefore + 3)
        if let stressError { throw stressError }
    }

    private func makeBroker(
        factory: FakeTransportFactory,
        initializeTimeout: Duration = .seconds(1),
        notificationDebounce: Duration = .milliseconds(5),
        readTimeout: Duration = .seconds(1),
        reconciliationInterval: Duration = .seconds(3_600),
        sleeper: any BrokerSleeper = ContinuousBrokerSleeper(),
        retryDelays: [Duration] = [.milliseconds(5)],
        maximumAutomaticFailures: Int = 10,
        slowRecoveryInterval: Duration = .seconds(300),
        versionInspectionHandlerDelayForTesting: Duration = .zero,
        suppressSynchronousVersionExitObservationForTesting: Bool = false,
        teardownRaceHooksForTesting: BrokerTeardownRaceHooks? = nil
    ) -> CodexAppServerBroker {
        CodexAppServerBroker(
            factory: factory,
            configuration: .init(
                initializeTimeout: initializeTimeout,
                readTimeout: readTimeout,
                notificationDebounce: notificationDebounce,
                reconciliationInterval: reconciliationInterval,
                retryDelays: retryDelays,
                maximumAutomaticFailures: maximumAutomaticFailures,
                slowRecoveryInterval: slowRecoveryInterval
            ),
            sleeper: sleeper,
            jitter: { $0 },
            versionInspectionHandlerDelayForTesting: versionInspectionHandlerDelayForTesting,
            suppressSynchronousVersionExitObservationForTesting:
                suppressSynchronousVersionExitObservationForTesting,
            teardownRaceHooksForTesting: teardownRaceHooksForTesting
        )
    }

    private func fileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private func writeVersionExecutable(_ version: String, to url: URL) throws {
        let source = "#!/bin/sh\nprintf '%s\\n' '\(version)'\n"
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTrackedVersionExecutable(
        version: String,
        processIdentifierFile: URL,
        to url: URL
    ) throws {
        let source = """
        #!/bin/sh
        printf '%s\\n' "$$" > \(shellQuoted(processIdentifierFile.path))
        printf '%s\\n' \(shellQuoted(version))
        """
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeInheritedOutputExecutable(
        version: String,
        descendantPIDFile: URL,
        to url: URL
    ) throws {
        let source = """
        #!/bin/sh
        sleep 30 &
        descendant_pid=$!
        printf '%s\\n' "$descendant_pid" > \(shellQuoted(descendantPIDFile.path))
        printf '%s\\n' \(shellQuoted(version))
        """
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func processIdentifier(from url: URL) throws -> Int32 {
        let value = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(value))
    }

    private func assertProcessDoesNotExist(
        _ processIdentifier: Int32?,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let processIdentifier else {
            XCTFail("missing process identifier: \(message)", file: file, line: line)
            return
        }
        errno = 0
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1, message, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, message, file: file, line: line)
    }

    private func waitForRefreshWaiters(
        _ expectedCount: Int,
        broker: CodexAppServerBroker
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await broker.refreshWaiterCountForTesting() == expectedCount { return true }
            await Task.yield()
        }
        return await broker.refreshWaiterCountForTesting() == expectedCount
    }

    private func waitForConsecutiveFailures(
        _ expectedCount: Int,
        broker: CodexAppServerBroker
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await broker.diagnostics().consecutiveFailures == expectedCount { return true }
            await Task.yield()
        }
        return await broker.diagnostics().consecutiveFailures == expectedCount
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private func stopWave(_ transport: CodexProcessTransport) async -> [Bool] {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await transport.stop() } }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
    }
}

/// Only reconciliation sleeps are manually advanced; RPC deadlines still use
/// the real clock. This exercises the broker's production timer loop without
/// waiting a minute or allowing timing-dependent extra polling in the tests.
private final class ControlledReconciliationSleeper: BrokerSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Duration
    private var waits: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelledIDs = Set<UUID>()

    init(interval: Duration) { self.interval = interval }

    var pendingSleepCount: Int { lock.withLock { waits.count } }

    func sleep(for duration: Duration) async throws {
        guard duration == interval else {
            try await Task.sleep(for: duration)
            return
        }
        let id = UUID()
        defer { _ = lock.withLock { cancelledIDs.remove(id) } }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    guard !Task.isCancelled, !cancelledIDs.contains(id) else { return true }
                    waits.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func releaseNext() -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !waits.isEmpty else { return nil }
            return waits.removeFirst().1
        }
        guard let continuation else { return false }
        continuation.resume()
        return true
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let index = waits.firstIndex(where: { $0.0 == id }) else {
                cancelledIDs.insert(id)
                return nil
            }
            return waits.remove(at: index).1
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class FakeScript: @unchecked Sendable {
    enum ReadFixture: Sendable { case normal, invalidSibling, sameDurationCollision }
    private struct TranscriptRecord: Sendable {
        let sequence: Int
        let method: String
        let idCategory: String
    }

    private let lock = NSLock()
    private var heldReads: [(FakeTransport, String)] = []
    private var transcript: [TranscriptRecord] = []
    private var _readCount = 0
    private var _successfulReadCount = 0
    private var _holdReads = false
    private var _ignoreReads = false
    private var _closeOnRead = false
    private var _malformedRead = false
    private var _malformedReadsRemaining = 0
    private var _authenticationError = false
    private var _ignoreInitialize = false
    private var _malformedInitialize = false
    private var _initializeCount = 0
    private var _initializedNotificationCount = 0
    private var _handshakeViolationCount = 0
    private var _readFixture = ReadFixture.normal
    private var _normalUsedPercent = 27

    var readCount: Int { lock.withLock { _readCount } }
    var successfulReadCount: Int { lock.withLock { _successfulReadCount } }
    var initializeCount: Int { lock.withLock { _initializeCount } }
    var initializedNotificationCount: Int { lock.withLock { _initializedNotificationCount } }
    var handshakeViolationCount: Int { lock.withLock { _handshakeViolationCount } }
    var readFixture: ReadFixture {
        get { lock.withLock { _readFixture } }
        set { lock.withLock { _readFixture = newValue } }
    }
    var normalUsedPercent: Int {
        get { lock.withLock { _normalUsedPercent } }
        set { lock.withLock { _normalUsedPercent = newValue } }
    }
    var holdReads: Bool {
        get { lock.withLock { _holdReads } }
        set { lock.withLock { _holdReads = newValue } }
    }
    var ignoreReads: Bool {
        get { lock.withLock { _ignoreReads } }
        set { lock.withLock { _ignoreReads = newValue } }
    }
    var closeOnRead: Bool {
        get { lock.withLock { _closeOnRead } }
        set { lock.withLock { _closeOnRead = newValue } }
    }
    var malformedRead: Bool {
        get { lock.withLock { _malformedRead } }
        set { lock.withLock { _malformedRead = newValue } }
    }
    var malformedReadsRemaining: Int {
        get { lock.withLock { _malformedReadsRemaining } }
        set { lock.withLock { _malformedReadsRemaining = max(0, newValue) } }
    }
    var authenticationError: Bool {
        get { lock.withLock { _authenticationError } }
        set { lock.withLock { _authenticationError = newValue } }
    }
    var ignoreInitialize: Bool {
        get { lock.withLock { _ignoreInitialize } }
        set { lock.withLock { _ignoreInitialize = newValue } }
    }
    var malformedInitialize: Bool {
        get { lock.withLock { _malformedInitialize } }
        set { lock.withLock { _malformedInitialize = newValue } }
    }

    func handle(line: Data, transport: FakeTransport) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = root["method"] as? String else { return }
        let id = root["id"] as? String
        recordTranscript(method: method, id: id)

        switch method {
        case "initialize":
            guard let id,
                  validateInitializeParameters(root["params"]),
                  transport.acceptInitialize() else {
                recordHandshakeViolation()
                if let id {
                    transport.yieldJSON([
                        "id": id,
                        "error": ["code": -32_600, "message": "invalid initialize handshake"]
                    ])
                }
                return
            }
            let initializeAction = lock.withLock { () -> (Bool, Bool) in
                _initializeCount += 1
                return (_ignoreInitialize, _malformedInitialize)
            }
            if initializeAction.0 { return }
            if initializeAction.1 {
                transport.yieldJSON(["id": id, "result": ["userAgent": "incomplete"]])
                return
            }
            transport.yieldJSON([
                "id": id,
                "result": [
                    "userAgent": "fake-codex/1",
                    "codexHome": "/redacted",
                    "platformFamily": "unix",
                    "platformOs": "macos"
                ]
            ])
        case "initialized":
            guard id == nil, transport.acceptInitializedNotification() else {
                recordHandshakeViolation()
                return
            }
            lock.withLock { _initializedNotificationCount += 1 }
        case "account/rateLimits/read":
            guard let id else { return }
            guard transport.handshakeReady else {
                recordHandshakeViolation()
                transport.yieldJSON([
                    "id": id,
                    "error": ["code": -32_600, "message": "read before initialized"]
                ])
                return
            }
            let action = lock.withLock { () -> ReadAction in
                _readCount += 1
                if _ignoreReads { return .ignore }
                if _closeOnRead { return .close }
                if _holdReads {
                    heldReads.append((transport, id))
                    return .hold
                }
                if _authenticationError { return .authentication }
                if _malformedReadsRemaining > 0 {
                    _malformedReadsRemaining -= 1
                    return .malformed
                }
                if _malformedRead { return .malformed }
                _successfulReadCount += 1
                return .success
            }
            perform(action: action, transport: transport, id: id)
        default:
            break
        }
    }

    private func validateInitializeParameters(_ value: Any?) -> Bool {
        guard let params = value as? [String: Any],
              params["experimentalApi"] == nil,
              let capabilities = params["capabilities"] as? [String: Any],
              capabilities["experimentalApi"] == nil,
              let clientInfo = params["clientInfo"] as? [String: Any] else {
            return false
        }
        for key in ["name", "title", "version"] {
            guard let field = clientInfo[key] as? String,
                  !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
        }
        return true
    }

    private func recordHandshakeViolation() {
        lock.withLock { _handshakeViolationCount += 1 }
    }

    private func recordTranscript(method: String, id: String?) {
        lock.withLock {
            let idCategory: String
            if id == nil {
                idCategory = "notification"
            } else if method == "initialize" {
                idCategory = "initialize"
            } else if method == "account/rateLimits/read" {
                idCategory = "rate-limits"
            } else {
                idCategory = "other"
            }
            transcript.append(
                TranscriptRecord(
                    sequence: transcript.count + 1,
                    method: method,
                    idCategory: idCategory
                )
            )
        }
    }

    func sanitizedTranscriptJSONL() throws -> Data {
        let records = lock.withLock { transcript }
        var output = Data()
        for record in records {
            let line = try JSONSerialization.data(
                withJSONObject: [
                    "sequence": record.sequence,
                    "method": record.method,
                    "idCategory": record.idCategory
                ],
                options: [.sortedKeys]
            )
            output.append(line)
            output.append(0x0A)
        }
        return output
    }

    func releaseHeldReads() {
        let reads = lock.withLock { () -> [(FakeTransport, String)] in
            let value = heldReads
            heldReads.removeAll()
            _successfulReadCount += value.count
            return value
        }
        for (transport, id) in reads { perform(action: .success, transport: transport, id: id) }
    }

    private enum ReadAction { case ignore, close, hold, authentication, malformed, success }

    private func perform(action: ReadAction, transport: FakeTransport, id: String) {
        switch action {
        case .ignore, .hold:
            break
        case .close:
            transport.finish()
        case .authentication:
            transport.yieldJSON([
                "id": id,
                "error": ["code": -32_000, "message": "not authenticated"]
            ])
        case .malformed:
            transport.yield(Data("not-json".utf8))
        case .success:
            let (fixture, normalUsedPercent) = lock.withLock { (_readFixture, _normalUsedPercent) }
            let primary: [String: Any]
            let secondary: Any
            switch fixture {
            case .normal:
                primary = [
                    "usedPercent": normalUsedPercent,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_900_000_000
                ]
                secondary = NSNull()
            case .invalidSibling:
                primary = [
                    "usedPercent": -1,
                    "windowDurationMins": 300,
                    "resetsAt": 1_900_000_000
                ]
                secondary = [
                    "usedPercent": 27,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_900_000_100
                ]
            case .sameDurationCollision:
                primary = [
                    "usedPercent": 27,
                    "windowDurationMins": 300,
                    "resetsAt": 1_900_000_000
                ]
                secondary = [
                    "usedPercent": 28,
                    "windowDurationMins": 300,
                    "resetsAt": 1_900_000_100
                ]
            }
            transport.yieldJSON([
                "id": id,
                "result": [
                    "rateLimits": [
                        "limitId": "codex",
                        "primary": primary,
                        "secondary": secondary
                    ]
                ]
            ])
        }
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BrokerEvent] = []
    var values: [BrokerEvent] { lock.withLock { storage } }
    func append(_ event: BrokerEvent) { lock.withLock { storage.append(event) } }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var entered = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { lock.withLock { entered } }

    func enter() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                entered = true
                guard !released else { return true }
                releaseContinuations.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            let continuations = releaseContinuations
            releaseContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }
}

private final class ProcessSignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func send(processIdentifier: Int32, signal: Int32) -> Int32 {
        let shouldDrop = lock.withLock { !released && signal == SIGKILL }
        return shouldDrop ? 0 : Darwin.kill(processIdentifier, signal)
    }

    func release() {
        lock.withLock { released = true }
    }
}

private final class BlockingTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class WeakTransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: CodexProcessTransport?

    init(_ value: CodexProcessTransport) {
        storage = value
    }

    var isEmpty: Bool { lock.withLock { storage == nil } }
}

private final class FakeTransportFactory: CodexTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let script: FakeScript
    private let executableURL: URL
    private let requiresExecutableToExist: Bool
    private var _startCount = 0
    private var _stopCount = 0
    private var _activeCount = 0
    private var _maximumActiveCount = 0
    private var _latestTransport: FakeTransport?
    private var _holdStarts = false
    private var _holdStartsAfterCreatingTransport = false
    private var _holdStops = false
    private var _stopAttemptCount = 0
    private var _stopResults = [true]
    private var heldStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var heldPostCreationStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var heldStopContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        script: FakeScript,
        executableURL: URL = URL(fileURLWithPath: "/nonexistent/codex-test-double"),
        requiresExecutableToExist: Bool = false
    ) {
        self.script = script
        self.executableURL = executableURL
        self.requiresExecutableToExist = requiresExecutableToExist
    }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var activeCount: Int { lock.withLock { _activeCount } }
    var maximumActiveCount: Int { lock.withLock { _maximumActiveCount } }
    var latestTransport: FakeTransport? { lock.withLock { _latestTransport } }
    var holdStarts: Bool {
        get { lock.withLock { _holdStarts } }
        set { lock.withLock { _holdStarts = newValue } }
    }
    var holdStartsAfterCreatingTransport: Bool {
        get { lock.withLock { _holdStartsAfterCreatingTransport } }
        set { lock.withLock { _holdStartsAfterCreatingTransport = newValue } }
    }
    var holdStops: Bool {
        get { lock.withLock { _holdStops } }
        set { lock.withLock { _holdStops = newValue } }
    }
    var stopAttemptCount: Int { lock.withLock { _stopAttemptCount } }
    var stopResults: [Bool] {
        get { lock.withLock { _stopResults } }
        set { lock.withLock { _stopResults = newValue } }
    }

    func start() async throws -> any CodexTransport {
        let shouldWait = lock.withLock { () -> Bool in
            _startCount += 1
            return _holdStarts
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let releaseImmediately = lock.withLock { () -> Bool in
                    guard _holdStarts else { return true }
                    heldStartContinuations.append(continuation)
                    return false
                }
                if releaseImmediately { continuation.resume() }
            }
        }
        if requiresExecutableToExist,
           !FileManager.default.isExecutableFile(atPath: executableURL.path) {
            throw CodexAppServerError.executableNotFound
        }
        let transport = FakeTransport(
            script: script,
            executableURL: executableURL,
            onStopAttempt: { [weak self] in await self?.performStopAttempt() ?? true },
            onStop: { [weak self] in self?.didStop() }
        )
        lock.withLock {
            _activeCount += 1
            _maximumActiveCount = max(_maximumActiveCount, _activeCount)
            _latestTransport = transport
        }
        let shouldHoldAfterCreation = lock.withLock { _holdStartsAfterCreatingTransport }
        if shouldHoldAfterCreation {
            await withCheckedContinuation { continuation in
                let releaseImmediately = lock.withLock { () -> Bool in
                    guard _holdStartsAfterCreatingTransport else { return true }
                    heldPostCreationStartContinuations.append(continuation)
                    return false
                }
                if releaseImmediately { continuation.resume() }
            }
        }
        return transport
    }

    func releaseHeldStarts() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdStarts = false
            let continuations = heldStartContinuations
            heldStartContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func releaseHeldStartsAfterCreatingTransport() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdStartsAfterCreatingTransport = false
            let continuations = heldPostCreationStartContinuations
            heldPostCreationStartContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func releaseHeldStops() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdStops = false
            let continuations = heldStopContinuations
            heldStopContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    private func performStopAttempt() async -> Bool {
        let shouldWait = lock.withLock { () -> Bool in
            _stopAttemptCount += 1
            return _holdStops
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let releaseImmediately = lock.withLock { () -> Bool in
                    guard _holdStops else { return true }
                    heldStopContinuations.append(continuation)
                    return false
                }
                if releaseImmediately { continuation.resume() }
            }
        }
        return lock.withLock {
            guard !_stopResults.isEmpty else { return true }
            return _stopResults.removeFirst()
        }
    }

    private func didStop() {
        lock.withLock {
            _stopCount += 1
            _activeCount -= 1
        }
    }
}

private final class FakeTransport: CodexTransport, @unchecked Sendable {
    let events: AsyncThrowingStream<CodexTransportEvent, Error>
    let executableURL: URL
    let processIdentifier: Int32? = nil

    private let continuation: AsyncThrowingStream<CodexTransportEvent, Error>.Continuation
    private let script: FakeScript
    private let onStopAttempt: @Sendable () async -> Bool
    private let onStop: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    private enum HandshakeState: Equatable { case awaitingInitialize, awaitingInitialized, ready }
    private var handshakeState = HandshakeState.awaitingInitialize

    init(
        script: FakeScript,
        executableURL: URL,
        onStopAttempt: @escaping @Sendable () async -> Bool = { true },
        onStop: @escaping @Sendable () -> Void
    ) {
        self.script = script
        self.onStopAttempt = onStopAttempt
        self.executableURL = executableURL
        self.onStop = onStop
        let pair = AsyncThrowingStream<CodexTransportEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func send(line: Data) throws {
        guard !lock.withLock({ stopped }) else { throw CodexTransportError.writeAfterStop }
        script.handle(line: line, transport: self)
    }

    func stop() async -> Bool {
        if lock.withLock({ stopped }) { return true }
        guard await onStopAttempt() else { return false }
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop {
            continuation.finish()
            onStop()
        }
        return true
    }

    var handshakeReady: Bool {
        lock.withLock { handshakeState == .ready }
    }

    func acceptInitialize() -> Bool {
        lock.withLock {
            guard handshakeState == .awaitingInitialize else { return false }
            handshakeState = .awaitingInitialized
            return true
        }
    }

    func acceptInitializedNotification() -> Bool {
        lock.withLock {
            guard handshakeState == .awaitingInitialized else { return false }
            handshakeState = .ready
            return true
        }
    }

    func yieldJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        yield(data)
    }

    func yield(_ data: Data) {
        continuation.yield(.stdoutLine(data))
    }

    func finish() {
        continuation.yield(.stdoutClosed)
        continuation.finish()
    }
}
