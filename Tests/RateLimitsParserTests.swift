import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
#endif

final class RateLimitsParserTests: XCTestCase {
    // Every payload, percentage, identifier, and timestamp below is synthetic test data.
    func testSevenDayPrimaryWithNullSecondaryProducesSingleSevenDaySnapshot() throws {
        let data = responseData(result: [
            "rateLimits": bucket(
                limitID: "codex",
                used: 13,
                duration: 10_080,
                resetsAt: 2_000_000_400
            )
        ])
        let snapshot = try RateLimitsParser.parseResponseLine(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.kind, .sevenDay)
        XCTAssertNil(snapshot.fiveHourWindow)
    }

    func testFiveHourPrimaryWithNullSecondaryProducesSingleFiveHourSnapshot() throws {
        let data = responseData(result: [
            "rateLimits": bucket(
                limitID: "codex",
                used: 38,
                duration: 300,
                resetsAt: 2_000_000_400
            )
        ])
        let snapshot = try RateLimitsParser.parseResponseLine(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.kind, .fiveHour)
        XCTAssertNil(snapshot.sevenDayWindow)
    }

    func testPrefersCodexBucketOverLegacyAndOtherBuckets() throws {
        let data = responseData(result: [
            "rateLimitsByLimitId": [
                "other": bucket(limitID: "other", used: 99, duration: 300, resetsAt: 2_000_000_050),
                "codex": bucket(limitID: "codex", used: 13, duration: 10_080, resetsAt: 2_000_000_196)
            ],
            "rateLimits": bucket(limitID: "codex", used: 80, duration: 300, resetsAt: 2_000_000_100)
        ])

        let snapshot = try RateLimitsParser.parseResponseLine(data, fetchedAt: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.sevenDayWindow?.usedPercent, 13)
        XCTAssertEqual(snapshot.sevenDayWindow?.resetsAt, Date(timeIntervalSince1970: 2_000_000_196))
    }

    func testFindsUniquelyIdentifiedCodexBucketWhenDictionaryKeyChanges() throws {
        let data = responseData(result: [
            "rateLimitsByLimitId": [
                "new-server-key": bucket(limitID: "codex", used: 38, duration: 300, resetsAt: 2_000_000_500),
                "other": bucket(limitID: "spark", used: 2, duration: 10_080, resetsAt: 2_000_000_900)
            ]
        ])

        let snapshot = try RateLimitsParser.parseResponseLine(data)
        XCTAssertEqual(snapshot.fiveHourWindow?.remainingPercent, 62)
    }

    func testLegacyFallbackRejectsWrongExplicitLimitID() {
        let data = responseData(result: [
            "rateLimits": bucket(limitID: "not-codex", used: 5, duration: 10_080, resetsAt: 2_000_000_500)
        ])

        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(data)) { error in
            XCTAssertEqual(error as? RateLimitsParserError, .missingCodexRateLimits)
        }
    }

    func testNullDurationAndResetRemainUnknownWithoutLosingUsage() throws {
        let data = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 25,
                    "windowDurationMins": NSNull(),
                    "resetsAt": NSNull()
                ],
                "secondary": NSNull()
            ]
        ])

        let window = try XCTUnwrap(RateLimitsParser.parseResponseLine(data).windows.first)
        XCTAssertEqual(window.usedPercent, 25)
        XCTAssertNil(window.durationMinutes)
        XCTAssertNil(window.resetsAt)
        XCTAssertEqual(window.kind, .other)
    }

    func testMissingRequiredUsedPercentMakesOnlyWindowUnusable() {
        let data = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["windowDurationMins": 300],
                "secondary": NSNull()
            ]
        ])

        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(data)) { error in
            XCTAssertEqual(error as? RateLimitsParserError, .missingWindows)
        }
    }

    func testPrimarySecondaryOrderDoesNotAffectWindowClassification() throws {
        let codex: [String: Any] = [
            "limitId": "codex",
            "primary": window(used: 13, duration: 10_080, resetsAt: 2_000_000_900),
            "secondary": window(used: 38, duration: 300, resetsAt: 2_000_000_400)
        ]
        let snapshot = try RateLimitsParser.parseResponseLine(responseData(result: ["rateLimits": codex]))

        XCTAssertEqual(snapshot.fiveHourWindow?.remainingPercent, 62)
        XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 87)
        XCTAssertEqual(snapshot.limitingWindow?.kind, .fiveHour)
    }

    func testReverseDualSlotsProduceExactlySameCanonicalSnapshotAsForward() throws {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let fiveHour = window(used: 38, duration: 300, resetsAt: 2_000_000_400)
        let sevenDay = window(used: 13, duration: 10_080, resetsAt: 2_000_000_900)
        let forward = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": fiveHour,
                "secondary": sevenDay
            ]
        ])
        let reversed = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": sevenDay,
                "secondary": fiveHour
            ]
        ])

        let forwardSnapshot = try RateLimitsParser.parseResponseLine(forward, fetchedAt: fetchedAt)
        let reversedSnapshot = try RateLimitsParser.parseResponseLine(reversed, fetchedAt: fetchedAt)
        XCTAssertEqual(forwardSnapshot, reversedSnapshot)
        XCTAssertEqual(forwardSnapshot.windows, reversedSnapshot.windows)
    }

    func testNullStringAndFractionalUsedPercentDiscardOnlyInvalidWindow() throws {
        let invalidValues: [Any] = [NSNull(), "13", 13.5]
        for invalid in invalidValues {
            let data = responseData(result: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": rawWindow(
                        used: invalid,
                        duration: 300,
                        resetsAt: 2_000_000_400
                    ),
                    "secondary": window(
                        used: 25,
                        duration: 10_080,
                        resetsAt: 2_000_000_500
                    )
                ]
            ])
            guard case .success(let result) = RateLimitsParser.parseResponseLineOutcome(data) else {
                return XCTFail("A valid sibling must survive invalid usedPercent")
            }
            XCTAssertEqual(result.snapshot.windows.count, 1)
            XCTAssertEqual(result.snapshot.sevenDayWindow?.remainingPercent, 75)
            XCTAssertEqual(result.diagnostics.invalidWindowDiscardCount, 1)
        }
    }

    func testNullZeroNegativeAndStringDurationsRemainGeneric() throws {
        let values: [Any] = [NSNull(), 0, -300, "300"]
        for value in values {
            let data = responseData(result: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": rawWindow(
                        used: 20,
                        duration: value,
                        resetsAt: 2_000_000_400
                    ),
                    "secondary": NSNull()
                ]
            ])
            let parsed = try RateLimitsParser.parseResponseLine(data)
            XCTAssertNil(parsed.windows.first?.durationMinutes)
            XCTAssertEqual(parsed.windows.first?.kind, .other)
            XCTAssertEqual(parsed.windows.first?.detailLabel, "Usage window")
        }
    }

    func testFutureExactPastMillisecondAndNullResetValues() throws {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let cases: [(Any, Date?, Bool)] = [
            (2_000_000_100, Date(timeIntervalSince1970: 2_000_000_100), false),
            (2_000_000_000, fetchedAt, true),
            (1_999_999_900, Date(timeIntervalSince1970: 1_999_999_900), true),
            (2_000_000_100_000, nil, false),
            (NSNull(), nil, false)
        ]
        for (rawReset, expectedDate, expectedStale) in cases {
            let data = responseData(result: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": rawWindow(
                        used: 20,
                        duration: 300,
                        resetsAt: rawReset
                    ),
                    "secondary": NSNull()
                ]
            ])
            let parsed = try RateLimitsParser.parseResponseLine(data, fetchedAt: fetchedAt)
            XCTAssertEqual(parsed.windows.first?.resetsAt, expectedDate)
            XCTAssertEqual(parsed.isStale(at: fetchedAt), expectedStale)
        }
    }

    func testMissingUnknownAndDamagedPayloadShapesAreHandledDeterministically() throws {
        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(responseData(result: [:]))) {
            XCTAssertEqual($0 as? RateLimitsParserError, .missingCodexRateLimits)
        }
        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(Data("{".utf8))) {
            XCTAssertEqual($0 as? RateLimitsParserError, .invalidJSON)
        }
        XCTAssertThrowsError(
            try RateLimitsParser.parseResponseLine(
                try JSONSerialization.data(withJSONObject: ["not", "an", "object"])
            )
        ) {
            XCTAssertEqual($0 as? RateLimitsParserError, .invalidJSON)
        }

        let unknownMembers = responseData(result: [
            "futureTopLevelField": ["opaque": "never persisted"],
            "rateLimits": [
                "limitId": "codex",
                "unknownPlanType": "future-plan",
                "primary": [
                    "usedPercent": 20,
                    "windowDurationMins": 90,
                    "resetsAt": 2_000_000_400,
                    "futureWindowField": ["opaque": "ignored"]
                ],
                "secondary": NSNull()
            ]
        ])
        let parsed = try RateLimitsParser.parseResponseLine(unknownMembers)
        XCTAssertEqual(parsed.windows.first?.detailLabel, "90-minute")
    }

    func testNullBucketMapFallsBackAndMalformedUnrelatedBucketDoesNotPoisonCodex() throws {
        let fallback = responseData(result: [
            "rateLimitsByLimitId": NSNull(),
            "rateLimits": bucket(
                limitID: "codex",
                used: 13,
                duration: 10_080,
                resetsAt: 2_000_000_400
            )
        ])
        XCTAssertEqual(
            try RateLimitsParser.parseResponseLine(fallback).sevenDayWindow?.remainingPercent,
            87
        )

        let malformedUnrelated = responseData(result: [
            "rateLimitsByLimitId": [
                "broken": "not-an-object",
                "codex": bucket(
                    limitID: "codex",
                    used: 38,
                    duration: 300,
                    resetsAt: 2_000_000_400
                )
            ]
        ])
        XCTAssertEqual(
            try RateLimitsParser.parseResponseLine(malformedUnrelated).fiveHourWindow?.remainingPercent,
            62
        )
    }

    func testRedactedParserDiagnosticsCountInvalidSiblingAndSameDurationCollision() {
        let invalidSibling = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": rawWindow(used: -1, duration: 300, resetsAt: 2_000_000_400),
                "secondary": window(used: 25, duration: 10_080, resetsAt: 2_000_000_500)
            ]
        ])
        guard case .success(let surviving) = RateLimitsParser.parseResponseLineOutcome(invalidSibling) else {
            return XCTFail("Valid sibling should survive")
        }
        XCTAssertEqual(surviving.diagnostics.invalidWindowDiscardCount, 1)
        XCTAssertEqual(surviving.diagnostics.sameDurationCollisionCount, 0)

        let collision = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": window(used: 20, duration: 300, resetsAt: 2_000_000_400),
                "secondary": window(used: 30, duration: 300, resetsAt: 2_000_000_500)
            ]
        ])
        guard case .success(let colliding) = RateLimitsParser.parseResponseLineOutcome(collision) else {
            return XCTFail("Distinct same-duration windows remain usable")
        }
        XCTAssertEqual(colliding.snapshot.windows.count, 2)
        XCTAssertEqual(colliding.diagnostics.invalidWindowDiscardCount, 0)
        XCTAssertEqual(colliding.diagnostics.sameDurationCollisionCount, 1)
    }

    func testRejectsBooleanUsedButPreservesFractionalDurationAsUnknown() throws {
        for boolean in [true, false] {
            let booleanUsed = responseData(result: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": boolean,
                        "windowDurationMins": 300,
                        "resetsAt": 2_000_000_400
                    ],
                    "secondary": NSNull()
                ]
            ])
            XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(booleanUsed))
        }

        let fractionalDuration = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 10,
                    "windowDurationMins": 300.5,
                    "resetsAt": 2_000_000_400
                ],
                "secondary": NSNull()
            ]
        ])
        let parsed = try RateLimitsParser.parseResponseLine(fractionalDuration)
        XCTAssertNil(parsed.windows.first?.durationMinutes)
        XCTAssertEqual(parsed.windows.first?.detailLabel, "Usage window")
    }

    func testInvalidResetTimestampsPreservePercentageWithUnavailableReset() throws {
        for timestamp in [2_000_000_400_000, 42] {
            let data = responseData(result: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 300,
                        "resetsAt": timestamp
                    ],
                    "secondary": NSNull()
                ]
            ])
            let parsed = try RateLimitsParser.parseResponseLine(data)
            XCTAssertEqual(parsed.windows.first?.remainingPercent, 90)
            XCTAssertNil(parsed.windows.first?.resetsAt)
        }
    }

    func testUsedPercentAcceptsBoundsAndRejectsOutOfRange() throws {
        for valid in [0, 1, 100] {
            let data = responseData(result: [
                "rateLimits": bucket(limitID: "codex", used: valid, duration: 300, resetsAt: 2_000_000_400)
            ])
            XCTAssertEqual(try RateLimitsParser.parseResponseLine(data).windows.first?.usedPercent, Double(valid))
        }
        for invalid in [-1, 101] {
            let data = responseData(result: [
                "rateLimits": bucket(limitID: "codex", used: invalid, duration: 300, resetsAt: 2_000_000_400)
            ])
            XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(data))
        }
    }

    func testCodexDictionaryKeyRejectsContradictoryInternalLimitID() {
        let data = responseData(result: [
            "rateLimitsByLimitId": [
                "codex": bucket(limitID: "different", used: 10, duration: 300, resetsAt: 2_000_000_400)
            ]
        ])
        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(data))
    }

    func testLegacyFallbackRequiresExplicitCodexLimitID() {
        let missingID = responseData(result: [
            "rateLimits": [
                "primary": window(used: 10, duration: 300, resetsAt: 2_000_000_400),
                "secondary": NSNull()
            ]
        ])
        XCTAssertThrowsError(try RateLimitsParser.parseResponseLine(missingID))
    }

    func testInvalidWindowDoesNotPoisonValidSibling() throws {
        let data = responseData(result: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": -1,
                    "windowDurationMins": 300,
                    "resetsAt": 2_000_000_400
                ],
                "secondary": window(used: 25, duration: 10_080, resetsAt: 2_000_000_500)
            ]
        ])
        let snapshot = try RateLimitsParser.parseResponseLine(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.sevenDayWindow?.remainingPercent, 75)
    }

    private func responseData(result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": 2, "result": result], options: [.sortedKeys])
    }

    private func bucket(limitID: String, used: Int, duration: Int, resetsAt: Int) -> [String: Any] {
        [
            "limitId": limitID,
            "primary": window(used: used, duration: duration, resetsAt: resetsAt),
            "secondary": NSNull()
        ]
    }

    private func window(used: Int, duration: Int, resetsAt: Int) -> [String: Any] {
        [
            "usedPercent": used,
            "windowDurationMins": duration,
            "resetsAt": resetsAt
        ]
    }

    private func rawWindow(used: Any, duration: Any, resetsAt: Any) -> [String: Any] {
        [
            "usedPercent": used,
            "windowDurationMins": duration,
            "resetsAt": resetsAt
        ]
    }
}
