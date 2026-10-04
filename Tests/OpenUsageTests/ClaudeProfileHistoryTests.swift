import XCTest
@testable import OpenUsage

final class ClaudeProfileHistoryTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    private func fixture(now: Date) throws -> (home: URL, profiles: [URL]) {
        let home = try ClaudeLogFixture.makeUserHome()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let profiles = [home.appendingPathComponent(".claude-personal"),
                        home.appendingPathComponent(".claude-work")]
        for (index, profile) in profiles.enumerated() {
            let projects = profile.appendingPathComponent("projects/workspace")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            try writeIdentity(user: "user-a", organization: "org-a", to: profile)
            let id = "profile-\(index)"
            let line = ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now),
                input: (index + 1) * 100, output: 0,
                costUSD: Double(index + 1), messageID: id, requestID: id
            )
            try line.write(to: projects.appendingPathComponent("\(id).jsonl"),
                           atomically: true, encoding: .utf8)
        }
        return (home, profiles)
    }

    private func writeIdentity(user: String, organization: String, to profile: URL) throws {
        let json = #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)","emailAddress":"\#(user)@example.com"}}"#
        try json.write(to: profile.appendingPathComponent(".claude.json"),
                       atomically: true, encoding: .utf8)
    }

    private func scanner(
        home: URL, profiles: [URL], allowsUnattributedSessions: Bool = false
    ) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a",
            allowsUnattributedSessions: allowsUnattributedSessions, currentDefaultLoginIdentity: { nil },
            ownedProfileDirectories: profiles.map(\.path)
        )
    }

    func testSameAccountCountsUnattributedHistoryFromBothProfiles() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        let scanner = scanner(home: fixture.home, profiles: fixture.profiles)

        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 300)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, 3, accuracy: 0.000_001)
    }

    func testChangedProfileIdentityStopsClaimingItsUnattributedHistory() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        let scanner = scanner(home: fixture.home, profiles: fixture.profiles)
        let initialResult = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let initialScan = try XCTUnwrap(initialResult)
        XCTAssertEqual(initialScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 300)

        // Reuse the scanner and unchanged logs to prove account ownership is re-read, not cached.
        try writeIdentity(user: "user-b", organization: "org-b", to: fixture.profiles[1])
        let changedResult = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let changedScan = try XCTUnwrap(changedResult)

        XCTAssertEqual(changedScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 100)
        XCTAssertEqual(changedScan.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, 1, accuracy: 0.000_001)
    }

    func testSingleAccountAllowanceDoesNotClaimHistoryAfterProfileChangesAccount() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        // Both profiles initially merge into one card, enabling the single-account allowance.
        let scanner = scanner(home: fixture.home, profiles: fixture.profiles,
                              allowsUnattributedSessions: true)
        let initialResult = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let initialScan = try XCTUnwrap(initialResult)
        XCTAssertEqual(initialScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 300)

        try writeIdentity(user: "user-b", organization: "org-b", to: fixture.profiles[1])
        let changedResult = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let changedScan = try XCTUnwrap(changedResult)

        XCTAssertEqual(changedScan.series.daily.reduce(0) { $0 + $1.totalTokens }, 100)
        XCTAssertEqual(changedScan.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, 1, accuracy: 0.000_001)
    }

    func testDesktopIndexKeepsOriginalAccountHistoryAfterProfileChangesAccount() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        let sessionID = UUID().uuidString.lowercased()
        let projects = fixture.profiles[1].appendingPathComponent("projects/workspace")
        try FileManager.default.moveItem(at: projects.appendingPathComponent("profile-1.jsonl"),
                                        to: projects.appendingPathComponent("\(sessionID).jsonl"))
        let index = fixture.home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions/user-a/org-a"
        )
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try #"{"cliSessionId":"\#(sessionID)"}"#.write(
            to: index.appendingPathComponent("local_session.json"), atomically: true, encoding: .utf8
        )
        try writeIdentity(user: "user-b", organization: "org-b", to: fixture.profiles[1])

        let result = await scanner(home: fixture.home, profiles: fixture.profiles)
            .scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 300)
    }
}
