import XCTest
@testable import OpenUsage

final class WeeklyResetOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOrdersAllAccountsAcrossProvidersByWeeklyReset() {
        let ids = ["claude", "codex", "claude@second", "grok"]
        let snapshots = [
            snapshot("claude", lines: [weekly(400), session(1)]),
            snapshot("codex", lines: [weekly(100)]),
            snapshot("claude@second", lines: [weekly(200)]),
            snapshot("grok", lines: [weekly(300, label: "Weekly limit")]),
        ]
        XCTAssertEqual(order(ids, snapshots), ["codex", "claude@second", "grok", "claude"])
    }

    func testUnknownAndExpiredResetsGoLastAndTiesKeepSavedOrder() {
        let ids = ["missing", "expired", "codex", "claude", "sessionOnly", "noDate"]
        let snapshots = [
            snapshot("expired", lines: [weekly(-1)]),
            snapshot("codex", lines: [weekly(100)]),
            snapshot("claude", lines: [weekly(100)]),
            snapshot("sessionOnly", lines: [session(1)]),
            snapshot("noDate", lines: [.progress(label: "Weekly", used: 50, limit: 100,
                                                 format: .percent, periodDurationMs: MetricPeriod.weekMs)]),
        ]
        XCTAssertEqual(order(ids, snapshots), ["codex", "claude", "missing", "expired", "sessionOnly", "noDate"])
    }

    func testMainWeeklyQuotaTakesPriorityOverModelWindowsAndResetCredits() {
        let ids = ["claude", "codex", "other"]
        let snapshots = [
            snapshot("claude", lines: [weekly(10, label: "Sonnet"), weekly(300)]),
            snapshot("codex", lines: [weekly(5, label: "Spark Weekly"), weekly(200),
                .values(label: "Rate Limit Resets", values: [], expiriesAt: [now.addingTimeInterval(1)])]),
            snapshot("other", lines: [weekly(100, label: "Requests")]),
        ]
        XCTAssertEqual(order(ids, snapshots), ["other", "codex", "claude"])
    }

    func testNewSnapshotReordersWithoutChangingSavedOrder() {
        let ids = ["claude", "codex"]
        XCTAssertEqual(order(ids, [snapshot("claude", lines: [weekly(200)]),
                                  snapshot("codex", lines: [weekly(100)])]), ["codex", "claude"])
        XCTAssertEqual(order(ids, [snapshot("claude", lines: [weekly(50)]),
                                  snapshot("codex", lines: [weekly(100)])]), ["claude", "codex"])
        XCTAssertEqual(ids, ["claude", "codex"])
    }

    private func order(_ ids: [String], _ snapshots: [ProviderSnapshot]) -> [String] {
        WeeklyResetOrder.sorted(ids, snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.providerID, $0) }),
                                now: now, providerID: { $0 })
    }

    private func snapshot(_ id: String, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, displayName: id, lines: lines, refreshedAt: now)
    }

    private func weekly(_ seconds: TimeInterval, label: String = "Weekly") -> MetricLine {
        .progress(label: label, used: 50, limit: 100, format: .percent,
                  resetsAt: now.addingTimeInterval(seconds), periodDurationMs: MetricPeriod.weekMs)
    }

    private func session(_ seconds: TimeInterval) -> MetricLine {
        .progress(label: "Session", used: 50, limit: 100, format: .percent,
                  resetsAt: now.addingTimeInterval(seconds), periodDurationMs: MetricPeriod.sessionMs)
    }
}
