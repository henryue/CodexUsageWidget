import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
#endif

final class UsageModelsTests: XCTestCase {
    func testFrequentUnchangedPollsDoNotPostponeWidgetFreshnessReload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = [UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))]
        func sample(_ minute: Int) -> SnapshotStoreLoadResult {
            let date = now.addingTimeInterval(Double(minute * 60))
            return .loaded(SharedUsageEnvelope(
                snapshot: UsageSnapshot(fetchedAt: date, windows: windows),
                serviceStatus: .available, lastAttemptAt: date
            ))
        }
        var gate = WidgetReloadGate()
        XCTAssertTrue(gate.shouldRequestReload(previous: .missing, current: sample(0), at: now))
        for minute in 1..<15 {
            XCTAssertFalse(gate.shouldRequestReload(
                previous: sample(minute - 1), current: sample(minute),
                at: now.addingTimeInterval(Double(minute * 60))
            ), "An unchanged minute sample must not request a Widget reload")
        }
        XCTAssertTrue(gate.shouldRequestReload(
            previous: sample(14), current: sample(15), at: now.addingTimeInterval(900)
        ), "Skipped polls must not move the freshness deadline")
        XCTAssertFalse(gate.shouldRequestReload(
            previous: sample(15), current: sample(15), at: now.addingTimeInterval(900)
        ), "The broker event and returned snapshot must not produce two reloads")
    }

    func testUsageAndResetChangesAndExplicitRefreshBypassFreshnessDelay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ seconds: Double, used: Double = 20, reset: Double = 86_400) -> SnapshotStoreLoadResult {
            let date = now.addingTimeInterval(seconds)
            return .loaded(SharedUsageEnvelope(
                snapshot: UsageSnapshot(fetchedAt: date, windows: [
                    UsageWindow(usedPercent: used, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(reset))
                ]), serviceStatus: .available, lastAttemptAt: date
            ))
        }
        var gate = WidgetReloadGate()
        XCTAssertTrue(gate.shouldRequestReload(previous: .missing, current: sample(0), at: now))
        XCTAssertFalse(gate.shouldRequestReload(previous: sample(0), current: sample(60), at: now.addingTimeInterval(60)))
        XCTAssertTrue(gate.shouldRequestReload(previous: sample(60), current: sample(120, used: 21), at: now.addingTimeInterval(120)))
        XCTAssertTrue(gate.shouldRequestReload(previous: sample(120, used: 21), current: sample(180, used: 21, reset: 172_800), at: now.addingTimeInterval(180)))
        let unchanged = sample(240, used: 21, reset: 172_800)
        XCTAssertTrue(gate.shouldRequestReload(previous: unchanged, current: unchanged, at: now.addingTimeInterval(240), force: true))
        XCTAssertFalse(gate.shouldRequestReload(previous: unchanged, current: unchanged, at: now.addingTimeInterval(240)))
    }

    func testWidgetReloadGatePreservesFailurePauseAndRecoveryTransitions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot.previewSevenDay(now: now)
        func state(_ status: SharedServiceStatus, message: String? = nil, snapshot value: UsageSnapshot? = nil) -> SnapshotStoreLoadResult {
            .loaded(SharedUsageEnvelope(snapshot: value ?? snapshot, serviceStatus: status, lastAttemptAt: now, message: message))
        }
        let ready = state(.available)
        let failed = state(.failed, message: "Read timed out.")
        let sameFailure = state(.failed, message: "A different hidden error.")
        let paused = state(.failed, message: AutomaticUpdatesPersistencePolicy.pausedMessage)
        let signedOut = state(.unauthenticated, message: "Sign in required.")
        var gate = WidgetReloadGate()
        XCTAssertTrue(gate.shouldRequestReload(previous: .missing, current: ready, at: now))
        XCTAssertTrue(gate.shouldRequestReload(previous: ready, current: failed, at: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.shouldRequestReload(previous: failed, current: sameFailure, at: now.addingTimeInterval(2)))
        XCTAssertTrue(gate.shouldRequestReload(previous: sameFailure, current: paused, at: now.addingTimeInterval(3)))
        XCTAssertTrue(gate.shouldRequestReload(previous: paused, current: signedOut, at: now.addingTimeInterval(4)))
        XCTAssertTrue(gate.shouldRequestReload(previous: signedOut, current: ready, at: now.addingTimeInterval(5)))

        let later = now.addingTimeInterval(31 * 60)
        let fresh = state(.available, snapshot: UsageSnapshot(fetchedAt: later, windows: snapshot.windows))
        XCTAssertTrue(gate.shouldRequestReload(previous: ready, current: fresh, at: later), "Recovery from an aged snapshot must reach the Widget")
    }

    func testDurationClassificationUsesValuesNotOrdering() {
        XCTAssertEqual(UsageWindowKind.classify(durationMinutes: 300), .fiveHour)
        XCTAssertEqual(UsageWindowKind.classify(durationMinutes: 10_080), .sevenDay)
        XCTAssertEqual(UsageWindowKind.classify(durationMinutes: 60), .other)
        XCTAssertEqual(UsageWindowKind.classify(durationMinutes: nil), .other)
    }

    func testPercentagePresentationAtValidBounds() {
        XCTAssertEqual(UsageWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(UsageWindow(usedPercent: 100, durationMinutes: 300, resetsAt: nil).remainingPercent, 0)
        XCTAssertEqual(UsageWindow(usedPercent: 13, durationMinutes: 10_080, resetsAt: nil).roundedRemainingPercent, 87)
    }

    func testLimitingWindowUsesRemainingThenEarlierResetThenShorterDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sevenDay = UsageWindow(usedPercent: 40, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(600))
        let fiveHourEarlier = UsageWindow(usedPercent: 40, durationMinutes: 300, resetsAt: now.addingTimeInterval(300))
        let snapshot = UsageSnapshot(fetchedAt: now, windows: [sevenDay, fiveHourEarlier])
        XCTAssertEqual(snapshot.limitingWindow?.kind, .fiveHour)

        let sameReset = UsageWindow(usedPercent: 40, durationMinutes: 300, resetsAt: sevenDay.resetsAt)
        let durationTie = UsageSnapshot(fetchedAt: now, windows: [sevenDay, sameReset])
        XCTAssertEqual(durationTie.limitingWindow?.kind, .fiveHour)
    }

    func testSharedTotalOrderingPrefersKnownResetAndKnownPositiveDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let knownReset = UsageWindow(
            usedPercent: 40,
            durationMinutes: nil,
            resetsAt: now.addingTimeInterval(600)
        )
        let missingReset = UsageWindow(
            usedPercent: 40,
            durationMinutes: 300,
            resetsAt: nil
        )
        XCTAssertEqual(
            UsageSnapshot(fetchedAt: now, windows: [missingReset, knownReset]).limitingWindow,
            knownReset
        )

        let knownDuration = UsageWindow(
            usedPercent: 40,
            durationMinutes: 300,
            resetsAt: now.addingTimeInterval(600)
        )
        let missingDuration = UsageWindow(
            usedPercent: 40,
            durationMinutes: nil,
            resetsAt: now.addingTimeInterval(600)
        )
        XCTAssertEqual(
            UsageSnapshot(fetchedAt: now, windows: [missingDuration, knownDuration]).limitingWindow,
            knownDuration
        )
    }

    func testSameDurationDistinctWindowsArePreservedAndSorted() {
        let now = Date(timeIntervalSince1970: 1_000)
        let generous = UsageWindow(usedPercent: 10, durationMinutes: 300, resetsAt: now.addingTimeInterval(500))
        let restrictive = UsageWindow(usedPercent: 70, durationMinutes: 300, resetsAt: now.addingTimeInterval(700))
        let snapshot = UsageSnapshot(fetchedAt: now, windows: [generous, restrictive])
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.limitingWindow?.remainingPercent, 30)
        XCTAssertEqual(snapshot.mediumDisplayWindows.map(\.remainingPercent), [30, 90])
    }

    func testOnlyCanonicalDuplicatesCollapseIncludingNilDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = UsageWindow(usedPercent: 70, durationMinutes: nil, resetsAt: now.addingTimeInterval(700))
        let exactDuplicate = UsageWindow(usedPercent: 70, durationMinutes: nil, resetsAt: now.addingTimeInterval(700))
        let distinct = UsageWindow(usedPercent: 70, durationMinutes: nil, resetsAt: now.addingTimeInterval(701))
        let snapshot = UsageSnapshot(fetchedAt: now, windows: [first, exactDuplicate, distinct])
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.strictnessSortedWindows.map(\.resetsAt), [first.resetsAt, distinct.resetsAt])
    }

    func testCanonicalIdentityIsLocaleIndependentAndSlotReversalStable() {
        let now = Date(timeIntervalSince1970: 1_000.5)
        let fiveHour = UsageWindow(usedPercent: 70, durationMinutes: 300, resetsAt: now.addingTimeInterval(500.25))
        let sevenDay = UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(700))
        let forward = UsageSnapshot(fetchedAt: now, windows: [fiveHour, sevenDay])
        let reversed = UsageSnapshot(fetchedAt: now, windows: [sevenDay, fiveHour])
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            try? JSONEncoder.sortedJSON.encode(forward),
            try? JSONEncoder.sortedJSON.encode(reversed)
        )
        XCTAssertEqual(forward.strictnessSortedWindows, reversed.strictnessSortedWindows)
        XCTAssertEqual(fiveHour.normalizedIdentityKey, "duration:300|reset:\(String(fiveHour.resetsAt!.timeIntervalSince1970.bitPattern, radix: 16))|used:70")
    }

    func testUnknownFutureWindowParticipatesWithAccurateGenericLabel() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sevenDay = UsageWindow(usedPercent: 10, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(900))
        let futureWindow = UsageWindow(usedPercent: 95, durationMinutes: 1_440, resetsAt: now.addingTimeInterval(500))
        let snapshot = UsageSnapshot(fetchedAt: now, windows: [sevenDay, futureWindow])
        XCTAssertEqual(snapshot.limitingWindow?.kind, .other)
        XCTAssertEqual(snapshot.limitingWindow?.detailLabel, "1-day")

        let unknownOnly = UsageSnapshot(fetchedAt: now, windows: [futureWindow])
        XCTAssertEqual(unknownOnly.limitingWindow?.detailLabel, "1-day")
    }

    func testPastResetMakesSnapshotStaleEvenWhenRecentlyFetched() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow(usedPercent: 20, durationMinutes: 300, resetsAt: now.addingTimeInterval(-1))
        let snapshot = UsageSnapshot(fetchedAt: now.addingTimeInterval(-10), windows: [window])
        XCTAssertTrue(snapshot.isStale(at: now))
    }

    func testThirtyMinuteFreshnessBoundary() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(
            fetchedAt: now.addingTimeInterval(-1_800),
            windows: [UsageWindow(usedPercent: 10, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(500))]
        )
        XCTAssertFalse(snapshot.isStale(at: now))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(1)))
    }

    func testResetTimeFormatting() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ResetTimeFormatter.compactRemaining(from: now, to: now.addingTimeInterval(5 * 86_400 + 23 * 3_600)), "5d 23h")
        XCTAssertEqual(ResetTimeFormatter.compactRemaining(from: now, to: now.addingTimeInterval(3 * 3_600 + 12 * 60)), "3h 12m")
        XCTAssertEqual(ResetTimeFormatter.compactRemaining(from: now, to: nil), "Unavailable")
    }


    func testEnvelopeRejectsFutureSchemaAndMigratesMissingVersion() throws {
        let future = Data("""
        {"schemaVersion":999,"snapshot":null,"serviceStatus":"failed","lastAttemptAt":1000}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertThrowsError(try decoder.decode(SharedUsageEnvelope.self, from: future))

        let legacy = Data("""
        {"snapshot":null,"serviceStatus":"failed","lastAttemptAt":1000}
        """.utf8)
        let migrated = try decoder.decode(SharedUsageEnvelope.self, from: legacy)
        XCTAssertEqual(migrated.schemaVersion, 1)
    }

    func testTimelinePlacesEntryExactlyAtResetBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "America/Toronto"), year: 2026, month: 3, day: 8, hour: 1, minute: 59))!
        let reset = now.addingTimeInterval(1)
        let snapshot = UsageSnapshot(
            fetchedAt: now,
            windows: [UsageWindow(usedPercent: 20, durationMinutes: 300, resetsAt: reset)]
        )
        let plan = snapshot.widgetTimelinePlan(now: now)
        XCTAssertEqual(
            plan.entryDates,
            [now, reset, now.addingTimeInterval(30 * 60 + 1)]
        )
        XCTAssertFalse(snapshot.isStale(at: reset.addingTimeInterval(-1)))
        XCTAssertTrue(snapshot.isStale(at: reset))
        XCTAssertTrue(snapshot.isStale(at: reset.addingTimeInterval(1)))
        XCTAssertEqual(plan.reloadAfter, reset.addingTimeInterval(1))
    }

    func testTimelineClockJumpPastResetStartsStaleWithoutPastEntry() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let nowAfterClockJump = reset.addingTimeInterval(3_600)
        let snapshot = UsageSnapshot(
            fetchedAt: reset.addingTimeInterval(-60),
            windows: [UsageWindow(usedPercent: 20, durationMinutes: 300, resetsAt: reset)]
        )
        let plan = snapshot.widgetTimelinePlan(now: nowAfterClockJump)
        XCTAssertEqual(plan.entryDates, [nowAfterClockJump])
        XCTAssertTrue(snapshot.isStale(at: nowAfterClockJump))
    }

    func testTimelinePreloadsDistantResetEvenIfProviderReloadIsDelayed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 3_600)
        let snapshot = UsageSnapshot(
            fetchedAt: now,
            windows: [UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: reset)]
        )
        let plan = snapshot.widgetTimelinePlan(now: now)
        XCTAssertEqual(
            plan.entryDates,
            [now, now.addingTimeInterval(30 * 60 + 1), reset]
        )
        XCTAssertEqual(plan.reloadAfter, now.addingTimeInterval(15 * 60))
        XCTAssertTrue(snapshot.isStale(at: plan.entryDates[1]))
        XCTAssertTrue(snapshot.isStale(at: plan.entryDates[2]))
    }

    func testTimelinePreloadsAgeStaleTransitionIfWidgetKitReloadIsDelayed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 3_600)
        let staleTransition = now.addingTimeInterval(30 * 60 + 1)
        let snapshot = UsageSnapshot(
            fetchedAt: now,
            windows: [UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: reset)]
        )

        let plan = snapshot.widgetTimelinePlan(now: now)

        XCTAssertEqual(plan.entryDates, [now, staleTransition, reset])
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(30 * 60)))
        XCTAssertTrue(snapshot.isStale(at: staleTransition))
        XCTAssertTrue(plan.entryDates.contains(reset), "reset transition must remain preloaded")
    }

    func testGenericLabelsAndMoreThanTwoWindowSelection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = [
            UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(900)),
            UsageWindow(usedPercent: 70, durationMinutes: 90, resetsAt: now.addingTimeInterval(500)),
            UsageWindow(usedPercent: 60, durationMinutes: nil, resetsAt: nil),
            UsageWindow(usedPercent: 10, durationMinutes: 120, resetsAt: now.addingTimeInterval(800))
        ]
        let snapshot = UsageSnapshot(fetchedAt: now, windows: windows)
        XCTAssertEqual(snapshot.limitingWindow?.detailLabel, "90-minute")
        XCTAssertEqual(snapshot.mediumDisplayWindows.map(\.detailLabel), ["90-minute", "Usage window"])
        XCTAssertEqual(snapshot.additionalWindowCount, 2)
        XCTAssertEqual(UsageWindow(usedPercent: 10, durationMinutes: 120, resetsAt: nil).detailLabel, "2-hour")
    }

    func testReloadPolicyIncludesFreshnessButDeduplicatesSameEvent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        XCTAssertFalse(WidgetReloadPolicy.visibleStateChanged(previous: first, current: first, at: now))

        let refreshedAt = now.addingTimeInterval(15 * 60)
        let sameValuesNewSample = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: refreshedAt),
            serviceStatus: .available,
            lastAttemptAt: refreshedAt
        )
        XCTAssertTrue(
            WidgetReloadPolicy.visibleStateChanged(
                previous: first,
                current: sameValuesNewSample,
                at: refreshedAt
            )
        )
    }

    func testReloadPolicyUsesPersistedResultAndDeduplicatesRepeatedRecoveredStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot.previewSevenDay(now: now)
        let available = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .available,
            lastAttemptAt: now
        )
        let recoveredStale = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(1),
            message: "Shared usage could not be updated. Open the app to refresh."
        )

        XCTAssertTrue(
            WidgetReloadPolicy.visibleStateChanged(
                previous: .loaded(available),
                current: .loaded(recoveredStale),
                at: now.addingTimeInterval(1)
            ),
            "The first recovery must replace a ready Widget with an explicit stale state"
        )

        let repeatedRecovery = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(2),
            message: recoveredStale.message
        )
        XCTAssertFalse(
            WidgetReloadPolicy.visibleStateChanged(
                previous: .loaded(recoveredStale),
                current: .loaded(repeatedRecovery),
                at: now.addingTimeInterval(2)
            ),
            "A repeated persistence failure with the same visible stale state must not reload again"
        )

        let differentHiddenRefreshMessage = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(3),
            message: "Codex took too long to respond. Try Refresh Now."
        )
        XCTAssertFalse(
            WidgetReloadPolicy.visibleStateChanged(
                previous: .loaded(recoveredStale),
                current: .loaded(differentHiddenRefreshMessage),
                at: now.addingTimeInterval(3)
            ),
            "Hidden refresh-error wording must not reload an otherwise identical Widget"
        )

        let pausedRecovery = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(4),
            message: "Automatic updates are paused. Open the app to resume updates."
        )
        XCTAssertTrue(
            WidgetReloadPolicy.visibleStateChanged(
                previous: .loaded(differentHiddenRefreshMessage),
                current: .loaded(pausedRecovery),
                at: now.addingTimeInterval(4)
            ),
            "Changing the visible stale action from refresh to resume must reload"
        )

        let newerSnapshot = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now.addingTimeInterval(5)),
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(5),
            message: pausedRecovery.message
        )
        XCTAssertTrue(
            WidgetReloadPolicy.visibleStateChanged(
                previous: .loaded(pausedRecovery),
                current: .loaded(newerSnapshot),
                at: now.addingTimeInterval(5)
            ),
            "Visible usage or last-updated changes must still reload"
        )
    }

    func testSlotSwapDoesNotTriggerWidgetReload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHour = UsageWindow(
            usedPercent: 38,
            durationMinutes: 300,
            resetsAt: now.addingTimeInterval(500)
        )
        let sevenDay = UsageWindow(
            usedPercent: 13,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(700)
        )
        let forward = SharedUsageEnvelope(
            snapshot: UsageSnapshot(fetchedAt: now, windows: [fiveHour, sevenDay]),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        let reversed = SharedUsageEnvelope(
            snapshot: UsageSnapshot(fetchedAt: now, windows: [sevenDay, fiveHour]),
            serviceStatus: .available,
            lastAttemptAt: now
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertFalse(
            WidgetReloadPolicy.visibleStateChanged(previous: forward, current: reversed, at: now)
        )
    }

    func testTwentyFourHourReconciliationBudgetIsAtMostNinetySix() {
        XCTAssertEqual(
            WidgetReloadPolicy.scheduledReadUpperBound(
                over: 24 * 60 * 60,
                reconciliationInterval: 15 * 60
            ),
            96
        )
    }

    func testWidgetSnapshotPolicyMapsEveryStoreReadResultWithoutWidgetKit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let envelope = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )

        XCTAssertEqual(
            WidgetSnapshotPolicy.state(from: .loaded(envelope), at: now),
            .available(envelope.snapshot!)
        )
        XCTAssertEqual(
            WidgetSnapshotPolicy.state(from: .missing, at: now),
            .failed("No shared usage data is available. Open Codex Usage to refresh.")
        )
        XCTAssertEqual(
            WidgetSnapshotPolicy.state(from: .invalid, at: now),
            .failed("Shared usage data is invalid. Open Codex Usage to refresh.")
        )
        XCTAssertEqual(
            WidgetSnapshotPolicy.state(from: .unavailable, at: now),
            .failed("Shared usage storage is unavailable. Open Codex Usage.")
        )
    }

    func testWidgetTimelinePolicyBuildsPlanAndEveryEntryFromOneCapturedRevision() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetA = now.addingTimeInterval(3_600)
        let snapshotA = UsageSnapshot(
            fetchedAt: now,
            windows: [UsageWindow(usedPercent: 11, durationMinutes: 300, resetsAt: resetA)]
        )
        let envelopeA = SharedUsageEnvelope(
            snapshot: snapshotA,
            serviceStatus: .available,
            lastAttemptAt: now
        )

        let timeline = WidgetSnapshotPolicy.timeline(from: .loaded(envelopeA), now: now)

        XCTAssertEqual(
            timeline.entries.map(\.date),
            [now, now.addingTimeInterval(30 * 60 + 1), resetA]
        )
        for entry in timeline.entries {
            switch entry.state {
            case .available(let snapshot), .stale(let snapshot, message: _):
                XCTAssertEqual(snapshot, snapshotA)
            case .loading, .unauthenticated, .failed:
                XCTFail("Every entry must resolve from captured revision A")
            }
        }
    }

    func testStaleSingleFiveHourSevenDayGenericAndMultipleStateFixtures() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows: [[UsageWindow]] = [
            [UsageWindow(usedPercent: 35, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600))],
            [UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))],
            [UsageWindow(usedPercent: 45, durationMinutes: 90, resetsAt: now.addingTimeInterval(1_800))],
            [
                UsageWindow(usedPercent: 35, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
                UsageWindow(usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
                UsageWindow(usedPercent: 45, durationMinutes: 90, resetsAt: now.addingTimeInterval(1_800))
            ]
        ]

        for fixtureWindows in windows {
            let snapshot = UsageSnapshot(
                fetchedAt: now.addingTimeInterval(-3_600),
                windows: fixtureWindows
            )
            let envelope = SharedUsageEnvelope(
                snapshot: snapshot,
                serviceStatus: .failed,
                lastAttemptAt: now,
                message: "The last refresh did not complete."
            )
            XCTAssertEqual(
                UsageViewState.resolve(envelope: envelope, at: now),
                .stale(snapshot, message: "The last refresh did not complete.")
            )
        }
    }

    func testCodexNotFoundProtocolUnsupportedAndRefreshFailureWithoutCacheAreFailed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [
            "Codex was not found. Install or update the ChatGPT app, then choose Re-detect Codex.",
            "This Codex version returned an unsupported usage response. Update ChatGPT, then choose Re-detect Codex.",
            "Usage is temporarily unavailable. Try Refresh Now."
        ]

        for message in messages {
            let envelope = SharedUsageEnvelope(
                snapshot: nil,
                serviceStatus: .failed,
                lastAttemptAt: now,
                message: message
            )
            XCTAssertEqual(UsageViewState.resolve(envelope: envelope, at: now), .failed(message))
        }
    }

    func testRefreshFailureWithCachePreservesSnapshotAsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot.previewDualWindow(now: now.addingTimeInterval(-60))
        let message = "Usage is temporarily unavailable. Try Refresh Now."
        let envelope = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now,
            message: message
        )
        XCTAssertEqual(
            UsageViewState.resolve(envelope: envelope, at: now),
            .stale(snapshot, message: message)
        )
    }
}

@MainActor
final class AutomaticUpdatesCoordinatorTests: XCTestCase {
    func testRapidPauseThenResumeSerializesToRunningLatestIntent() async {
        let service = FakeAutomaticUpdatesService()
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)
        coordinator.start()
        await coordinator.waitForIdle()

        service.delayNextSuspend = true
        coordinator.setRunning(false)
        await waitUntil { service.suspendCount == 1 }
        coordinator.setRunning(true)
        service.releaseSuspend()
        await coordinator.waitForIdle()

        XCTAssertTrue(service.running)
        XCTAssertTrue(service.activeChild)
        XCTAssertEqual(service.events, ["resume", "suspend", "resume"])
    }

    func testRapidResumeThenPauseSerializesToPausedLatestIntent() async {
        let service = FakeAutomaticUpdatesService()
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: false)
        coordinator.start()
        await coordinator.waitForIdle()

        service.delayNextResume = true
        coordinator.setRunning(true)
        await waitUntil { service.resumeCount == 1 }
        coordinator.setRunning(false)
        service.releaseResume()
        await coordinator.waitForIdle()

        XCTAssertFalse(service.running)
        XCTAssertFalse(service.activeChild)
        XCTAssertEqual(service.events, ["resume", "suspend"])
    }

    func testPauseDuringStartupCorrectsInFlightResumeBeforeBecomingIdle() async {
        let service = FakeAutomaticUpdatesService()
        service.delayNextResume = true
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)

        coordinator.start()
        await waitUntil { service.resumeCount == 1 }
        coordinator.setRunning(false)
        service.releaseResume()
        await coordinator.waitForIdle()

        XCTAssertFalse(service.running)
        XCTAssertFalse(service.activeChild)
        XCTAssertEqual(service.events, ["resume", "suspend"])
    }

    func testPauseDuringRedetectPreventsObsoleteResume() async {
        let service = FakeAutomaticUpdatesService()
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)
        coordinator.start()
        await coordinator.waitForIdle()

        service.delayNextSuspend = true
        coordinator.redetect()
        await waitUntil { service.suspendCount == 1 }
        coordinator.setRunning(false)
        service.releaseSuspend()
        await coordinator.waitForIdle()

        XCTAssertFalse(service.running)
        XCTAssertFalse(service.activeChild)
        XCTAssertEqual(service.events, ["resume", "suspend", "redetect"])
    }

    func testShutdownWaitsForInFlightStartupAndLeavesNoChild() async {
        let service = FakeAutomaticUpdatesService()
        service.delayNextResume = true
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)
        let completed = MainActorFlag()
        coordinator.start()
        await waitUntil { service.resumeCount == 1 }

        let shutdownTask = Task {
            let shutdownCompleted = await coordinator.shutdown()
            XCTAssertTrue(shutdownCompleted)
            completed.value = true
        }
        await Task.yield()
        XCTAssertFalse(completed.value)

        service.releaseResume()
        await shutdownTask.value
        XCTAssertTrue(completed.value)
        XCTAssertEqual(service.shutdownCount, 1)
        XCTAssertFalse(service.running)
        XCTAssertFalse(service.activeChild)
        XCTAssertEqual(service.events, ["resume", "shutdown"])
    }

    func testFailedShutdownStaysRequestedAndCanBeRetried() async {
        let service = FakeAutomaticUpdatesService()
        service.shutdownResults = [false, true]
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)
        coordinator.start()
        await coordinator.waitForIdle()

        let firstShutdownCompleted = await coordinator.shutdown()
        XCTAssertFalse(firstShutdownCompleted)
        XCTAssertEqual(service.shutdownCount, 1)

        coordinator.setRunning(true)
        coordinator.redetect()
        await coordinator.waitForIdle()
        XCTAssertEqual(service.resumeCount, 1, "shutdown-pending coordinator accepted new work")
        XCTAssertEqual(service.redetectCount, 0, "shutdown-pending coordinator accepted redetect")

        let secondShutdownCompleted = await coordinator.shutdown()
        XCTAssertTrue(secondShutdownCompleted)
        XCTAssertEqual(service.shutdownCount, 2)
        XCTAssertEqual(service.events, ["resume", "shutdown", "shutdown"])
    }

    func testFailedSuspendMarksAppliedStateUnknownAndResumeDrainsCleanup() async {
        let service = FakeAutomaticUpdatesService()
        service.suspendResults = [false]
        let coordinator = makeAutomaticUpdatesCoordinator(service: service, initiallyRunning: true)
        coordinator.start()
        await coordinator.waitForIdle()

        coordinator.setRunning(false)
        await coordinator.waitForIdle()
        XCTAssertEqual(service.suspendCount, 1)
        XCTAssertFalse(service.running)
        XCTAssertTrue(service.activeChild)

        coordinator.setRunning(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(service.suspendCount, 1)
        XCTAssertEqual(service.resumeCount, 2)
        XCTAssertTrue(service.running)
        XCTAssertTrue(service.activeChild)
    }

    private func makeAutomaticUpdatesCoordinator(
        service: FakeAutomaticUpdatesService,
        initiallyRunning: Bool
    ) -> AutomaticUpdatesCoordinator {
        AutomaticUpdatesCoordinator(
            initiallyRunning: initiallyRunning,
            resume: { await service.resume() },
            suspend: { await service.suspend() },
            redetect: { await service.redetect() },
            shutdown: { await service.shutdown() }
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

@MainActor
final class AppInteractionPoliciesTests: XCTestCase {
    func testWidgetGalleryPreviewIsAlwaysMarkedPlaceholder() {
        XCTAssertTrue(WidgetPreviewPolicy.isPlaceholder(contextIsPreview: true))
        XCTAssertFalse(WidgetPreviewPolicy.isPlaceholder(contextIsPreview: false))
    }

    func testDeepLinkRouteAcceptsDashboardAndRejectsWrongSchemeOrHost() {
        XCTAssertEqual(
            CodexUsageRoute.resolve(URL(string: "codexusage://dashboard")!),
            .dashboard
        )
        XCTAssertNil(CodexUsageRoute.resolve(URL(string: "https://dashboard")!))
        XCTAssertNil(CodexUsageRoute.resolve(URL(string: "codexusage://settings")!))
    }

    func testDiagnosticStateMappingCoversEveryPresentationState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot.previewSevenDay(now: now)
        XCTAssertEqual(UsageDiagnosticStateName.stateName(for: .loading), "loading")
        XCTAssertEqual(UsageDiagnosticStateName.stateName(for: .available(snapshot)), "available")
        XCTAssertEqual(UsageDiagnosticStateName.stateName(for: .stale(snapshot, message: nil)), "stale")
        XCTAssertEqual(UsageDiagnosticStateName.stateName(for: .unauthenticated("safe")), "signed-out")
        XCTAssertEqual(UsageDiagnosticStateName.stateName(for: .failed("safe")), "unavailable")
    }

    func testStopPolicyImmediatelyMarksCachedSnapshotStaleAndIsIdempotent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let available = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        let paused = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: available,
            at: now.addingTimeInterval(1)
        )
        guard case .stale = UsageViewState.resolve(envelope: paused, at: now.addingTimeInterval(1)) else {
            return XCTFail("Stopping updates must synchronously make cached data stale")
        }
        let repeated = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: paused,
            at: now.addingTimeInterval(100)
        )
        XCTAssertEqual(repeated, paused)
    }

    func testColdLaunchWhilePausedRewritesAvailableCacheAsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previouslyAvailable = SharedUsageEnvelope(
            snapshot: .previewSevenDay(now: now),
            serviceStatus: .available,
            lastAttemptAt: now
        )
        let startupEnvelope = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: previouslyAvailable,
            at: now.addingTimeInterval(10)
        )
        XCTAssertEqual(startupEnvelope.serviceStatus, .failed)
        XCTAssertEqual(startupEnvelope.message, AutomaticUpdatesPersistencePolicy.pausedMessage)
        guard case .stale = UsageViewState.resolve(
            envelope: startupEnvelope,
            at: now.addingTimeInterval(10)
        ) else {
            return XCTFail("A paused cold launch must not present cached data as current")
        }
    }

    func testPausedPolicyWinsOverLateFailureAndLateSnapshotEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot.previewSevenDay(now: now)
        let lateFailure = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .failed,
            lastAttemptAt: now.addingTimeInterval(1),
            message: "Usage is temporarily unavailable."
        )
        let afterFailure = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: lateFailure,
            at: now.addingTimeInterval(2)
        )
        XCTAssertEqual(afterFailure.message, AutomaticUpdatesPersistencePolicy.pausedMessage)

        let lateSnapshot = SharedUsageEnvelope(
            snapshot: snapshot,
            serviceStatus: .available,
            lastAttemptAt: now.addingTimeInterval(3)
        )
        let afterSnapshot = AutomaticUpdatesPersistencePolicy.pausedEnvelope(
            previous: lateSnapshot,
            at: now.addingTimeInterval(4)
        )
        XCTAssertEqual(afterSnapshot.message, AutomaticUpdatesPersistencePolicy.pausedMessage)
        guard case .stale = UsageViewState.resolve(
            envelope: afterSnapshot,
            at: now.addingTimeInterval(4)
        ) else {
            return XCTFail("Late broker events must not make paused data current")
        }
    }

    func testLoginItemEnableSucceeds() async {
        let service = FakeLoginItemService(status: .disabled)
        service.statusAfterRegister = .enabled
        let coordinator = LoginItemCoordinator(service: service)

        coordinator.setEnabled(true)
        await coordinator.waitForIdle()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(coordinator.presentation, LoginItemPresentation(status: .enabled, message: nil))
    }

    func testLoginItemRequiresApprovalDoesNotAutomaticallyRegisterAgainAndRefreshClearsMessage() async {
        let service = FakeLoginItemService(status: .disabled)
        service.statusAfterRegister = .requiresApproval
        let coordinator = LoginItemCoordinator(service: service)

        coordinator.setEnabled(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(coordinator.presentation.status, .requiresApproval)
        XCTAssertNotNil(coordinator.presentation.message)

        coordinator.refresh()
        XCTAssertEqual(service.registerCount, 1)
        service.status = .enabled
        coordinator.refresh()
        XCTAssertEqual(coordinator.presentation, LoginItemPresentation(status: .enabled, message: nil))
    }

    func testRejectedLoginItemChangeIsRecoverableOnlyAfterExplicitRetry() async {
        let service = FakeLoginItemService(status: .disabled)
        service.registerShouldThrow = true
        let coordinator = LoginItemCoordinator(service: service)

        coordinator.setEnabled(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertNotNil(coordinator.presentation.message)

        coordinator.refresh()
        XCTAssertNil(coordinator.presentation.message)
        XCTAssertEqual(service.registerCount, 1)

        service.registerShouldThrow = false
        service.statusAfterRegister = .enabled
        coordinator.setEnabled(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(service.registerCount, 2)
        XCTAssertEqual(coordinator.presentation.status, .enabled)
    }

    func testRapidDisableThenReenableIsSerializedToFinalIntent() async {
        let service = FakeLoginItemService(status: .enabled)
        service.delayUnregister = true
        let coordinator = LoginItemCoordinator(service: service)

        coordinator.setEnabled(false)
        await waitUntil { service.unregisterCount == 1 }
        coordinator.setEnabled(true)
        service.releaseUnregister()
        await coordinator.waitForIdle()

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(coordinator.presentation.status, .enabled)
    }

    func testDisableParticipatesInShutdownWait() async {
        let service = FakeLoginItemService(status: .enabled)
        service.delayUnregister = true
        let coordinator = LoginItemCoordinator(service: service)
        let completion = MainActorFlag()

        coordinator.setEnabled(false)
        await waitUntil { service.unregisterCount == 1 }
        let shutdown = Task {
            await coordinator.shutdown()
            completion.value = true
        }
        await Task.yield()
        XCTAssertFalse(completion.value)

        service.releaseUnregister()
        await shutdown.value
        XCTAssertTrue(completion.value)
        XCTAssertEqual(coordinator.presentation.status, .disabled)
    }

    func testTerminationCoordinatorRepliesOnlyAfterShutdownAndThenTerminatesNow() async {
        let coordinator = ApplicationTerminationCoordinator()
        let harness = TerminationHarness()

        let first = coordinator.requestTermination(
            shutdown: { await harness.shutdown() },
            reply: { harness.reply($0) }
        )
        let duplicate = coordinator.requestTermination(
            shutdown: {
                XCTFail("duplicate request must not start another shutdown")
                return false
            },
            reply: { _ in XCTFail("duplicate request must not reply independently") }
        )
        XCTAssertEqual(first, .terminateLater)
        XCTAssertEqual(duplicate, .terminateLater)
        await waitUntil { harness.shutdownStarted }
        XCTAssertTrue(harness.replies.isEmpty)

        harness.releaseShutdown()
        await coordinator.waitForShutdown()
        XCTAssertTrue(harness.shutdownFinished)
        XCTAssertEqual(harness.replies, [true])
        XCTAssertEqual(
            coordinator.requestTermination(shutdown: { true }, reply: { _ in }),
            .terminateNow
        )
    }

    func testTerminationCoordinatorRejectsFailedShutdownAndRetries() async {
        let coordinator = ApplicationTerminationCoordinator()
        let harness = TerminationHarness()
        harness.shutdownResults = [false, true]

        XCTAssertEqual(
            coordinator.requestTermination(
                shutdown: { await harness.shutdown() },
                reply: { harness.reply($0) }
            ),
            .terminateLater
        )
        await waitUntil { harness.shutdownCallCount == 1 }
        harness.releaseShutdown()
        await coordinator.waitForShutdown()
        XCTAssertFalse(coordinator.shutdownFinished)
        XCTAssertEqual(harness.replies, [false])

        XCTAssertEqual(
            coordinator.requestTermination(
                shutdown: { await harness.shutdown() },
                reply: { harness.reply($0) }
            ),
            .terminateLater
        )
        await waitUntil { harness.shutdownCallCount == 2 }
        harness.releaseShutdown()
        await coordinator.waitForShutdown()
        XCTAssertTrue(coordinator.shutdownFinished)
        XCTAssertEqual(harness.replies, [false, true])
        XCTAssertEqual(
            coordinator.requestTermination(shutdown: { true }, reply: { _ in }),
            .terminateNow
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    enum Failure: Error { case rejected }

    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerShouldThrow = false
    var unregisterShouldThrow = false
    var delayUnregister = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var settingsOpenCount = 0
    private var unregisterContinuation: CheckedContinuation<Void, Never>?

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if registerShouldThrow { throw Failure.rejected }
        status = statusAfterRegister
    }

    func unregister() async throws {
        unregisterCount += 1
        if delayUnregister {
            await withCheckedContinuation { continuation in
                unregisterContinuation = continuation
            }
        }
        if unregisterShouldThrow { throw Failure.rejected }
        status = .disabled
    }

    func openSystemSettings() {
        settingsOpenCount += 1
    }

    func releaseUnregister() {
        delayUnregister = false
        let continuation = unregisterContinuation
        unregisterContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class MainActorFlag {
    var value = false
}

@MainActor
private final class FakeAutomaticUpdatesService {
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var suspendContinuation: CheckedContinuation<Void, Never>?
    var delayNextResume = false
    var delayNextSuspend = false
    private(set) var running = false
    private(set) var activeChild = false
    private(set) var resumeCount = 0
    private(set) var suspendCount = 0
    private(set) var redetectCount = 0
    private(set) var shutdownCount = 0
    private(set) var events: [String] = []
    var shutdownResults = [true]
    var resumeResults = [true]
    var suspendResults = [true]
    var redetectResults = [true]

    func resume() async -> Bool {
        resumeCount += 1
        events.append("resume")
        if delayNextResume {
            delayNextResume = false
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }
        let result = resumeResults.isEmpty ? true : resumeResults.removeFirst()
        if result {
            running = true
            activeChild = true
        }
        return result
    }

    func suspend() async -> Bool {
        suspendCount += 1
        events.append("suspend")
        if delayNextSuspend {
            delayNextSuspend = false
            await withCheckedContinuation { continuation in
                suspendContinuation = continuation
            }
        }
        let result = suspendResults.isEmpty ? true : suspendResults.removeFirst()
        running = false
        if result {
            activeChild = false
        }
        return result
    }

    func shutdown() async -> Bool {
        shutdownCount += 1
        events.append("shutdown")
        running = false
        activeChild = false
        if shutdownResults.isEmpty { return true }
        return shutdownResults.removeFirst()
    }

    func redetect() async -> Bool {
        redetectCount += 1
        events.append("redetect")
        return redetectResults.isEmpty ? true : redetectResults.removeFirst()
    }

    func releaseResume() {
        let continuation = resumeContinuation
        resumeContinuation = nil
        continuation?.resume()
    }

    func releaseSuspend() {
        let continuation = suspendContinuation
        suspendContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TerminationHarness {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var shutdownStarted = false
    private(set) var shutdownFinished = false
    private(set) var shutdownCallCount = 0
    private(set) var replies: [Bool] = []
    var shutdownResults = [true]

    func shutdown() async -> Bool {
        shutdownCallCount += 1
        shutdownStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        let result = shutdownResults.isEmpty ? true : shutdownResults.removeFirst()
        shutdownFinished = result
        return result
    }

    func releaseShutdown() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func reply(_ value: Bool) {
        replies.append(value)
    }
}

private extension JSONEncoder {
    static var sortedJSON: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
