import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeProfileAccountTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let suite = "ClaudeProfileAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suite)
        }
        return (home, defaults)
    }

    private func writeAccount(_ email: String, user: String, org: String, directory: String?, home: URL) throws {
        let parent = directory.map { home.appendingPathComponent($0) } ?? home
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(org)","emailAddress":"\#(email)","organizationName":"Personal"}}"#
        try json.write(to: parent.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    }

    private func assembly(home: URL, defaults: UserDefaults) async -> ProviderAccountAssembly {
        await ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(environment: FakeEnvironment(), keychain: FakeKeychain(), homeDirectory: { home }),
            accountsStore: ProviderAccountsStore(defaults: defaults), families: ["claude"]
        )
    }

    func testThreeIndependentProfilesGetEmailLabelsAndScopedCredentials() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("default@example.com", user: "user-a", org: "org-a", directory: nil, home: home)
        try writeAccount("work@example.com", user: "user-b", org: "org-b", directory: ".claude-work", home: home)
        try writeAccount("other@example.com", user: "user-c", org: "org-c", directory: ".claude-other", home: home)
        let result = await assembly(home: home, defaults: defaults)
        XCTAssertEqual(Set(result.claudeCards.map(\.displayName)),
            ["Claude — default@example.com", "Claude — work@example.com", "Claude — other@example.com"])
        XCTAssertEqual(Set(result.identityKeysByCard.values), ["user-a|org-a", "user-b|org-b", "user-c|org-c"])
        let runtimes = ProviderCatalog.make(defaults: defaults, claudeCards: result.claudeCards)
            .compactMap { $0 as? ClaudeProvider }
        for (email, directory) in [("work@example.com", ".claude-work"), ("other@example.com", ".claude-other")] {
            let runtime = try XCTUnwrap(runtimes.first { $0.provider.displayName == "Claude — \(email)" })
            XCTAssertEqual(runtime.authStore.claudeHomeOverride(), home.appendingPathComponent(directory).path)
            XCTAssertEqual(runtime.authStore.keychainServiceCandidates().count, 1)
            XCTAssertFalse(runtime.authStore.keychainServiceCandidates().contains("Claude Code-credentials"))
        }
        let repeated = await assembly(home: home, defaults: defaults)
        XCTAssertEqual(repeated.claudeCards, result.claudeCards)
    }

    func testProfileMergesWithDefaultIdentityWithoutDuplicateCard() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("same@example.com", user: "user-a", org: "org-a", directory: nil, home: home)
        try writeAccount("same@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        let result = await assembly(home: home, defaults: defaults)
        XCTAssertEqual(result.claudeCards.count, 1)
        XCTAssertEqual(result.claudeCards.first?.displayName, "Claude — same@example.com")
        XCTAssertEqual(result.claudeCards.first?.id, "claude")
    }

    func testSameEmailInTwoOrganizationsRemainsDistinguishable() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("same@example.com", user: "user-a", org: "org-a", directory: nil, home: home)
        try writeAccount("same@example.com", user: "user-a", org: "org-b", directory: ".claude-work", home: home)
        let result = await assembly(home: home, defaults: defaults)
        XCTAssertEqual(result.claudeCards.count, 2)
        XCTAssertEqual(Set(result.claudeCards.map(\.displayName)).count, 2)
        XCTAssertTrue(result.claudeCards.allSatisfy { $0.displayName.contains("same@example.com") })
    }

    func testProfileBindsIdentityAndNeverBorrowsGlobalCredentials() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("work@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        let result = await assembly(home: home, defaults: defaults)
        let profile = try XCTUnwrap(result.claudeCards.first?.profile)
        let foreign = #"{"claudeAiOauth":{"accessToken":"foreign","expiresAt":4102444800000}}"#
        let local = #"{"claudeAiOauth":{"accessToken":"local","expiresAt":4102444800000}}"#
        let files = FakeFiles([profile.home + "/.credentials.json": local])
        let keychain = ServiceKeychain(values: ["Claude Code-credentials": foreign])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/another/profile", "CLAUDE_CODE_OAUTH_TOKEN": "foreign-env"]),
            files: files, keychain: keychain, profile: profile
        )
        XCTAssertEqual(store.expectedIdentityKey, "user-a|org-a")
        XCTAssertEqual(store.loadCredentialCandidates().map(\.oauth.accessToken), ["local"])
        files.files.removeValue(forKey: profile.home + "/.credentials.json")
        XCTAssertTrue(store.loadCredentialCandidates().isEmpty)
    }

    func testMultipleHomesForOneIdentityRetainBothCredentialSources() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("same@example.com", user: "user-a", org: "org-a", directory: ".claude-one", home: home)
        try writeAccount("same@example.com", user: "user-a", org: "org-a", directory: ".claude-two", home: home)
        let result = await assembly(home: home, defaults: defaults)
        let runtime = try XCTUnwrap(ProviderCatalog.make(defaults: defaults, claudeCards: result.claudeCards)
            .compactMap { $0 as? ClaudeProvider }.first)
        let one = #"{"claudeAiOauth":{"accessToken":"one","expiresAt":4102444800000}}"#
        let two = #"{"claudeAiOauth":{"accessToken":"two","expiresAt":4102444800000}}"#
        let files = FakeFiles([home.path + "/.claude-one/.credentials.json": one, home.path + "/.claude-two/.credentials.json": two])
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            profile: runtime.authStore.profile, additionalProfiles: runtime.authStore.additionalProfiles)
        XCTAssertEqual(Set(store.loadCredentialCandidates().compactMap(\.oauth.accessToken)), ["one", "two"])
    }

    func testConfiguredProfileKeepsItsOriginalKeychainServiceRepresentation() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("work@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        for raw in ["~/.claude-work", home.path + "/.claude-work/"] {
            let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": raw])
            let observer = DefaultAccountObserver(environment: environment, keychain: FakeKeychain(), homeDirectory: { home })
            let result = await ProviderAccountAssembly.make(observer: observer,
                accountsStore: ProviderAccountsStore(defaults: defaults), families: ["claude"])
            let profile = try XCTUnwrap(result.claudeCards.first?.profile)
            let original = ClaudeAuthStore(environment: environment).keychainServiceCandidates().first
            let scoped = ClaudeAuthStore(environment: environment, profile: profile).keychainServiceCandidates()
            XCTAssertEqual(scoped, [try XCTUnwrap(original)])
        }
    }

    func testDefaultProfileDoesNotHideMatchingSwapCredentials() async throws {
        let (home, defaults) = try fixture()
        let user = "11111111-1111-1111-1111-111111111111"
        let org = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        try writeAccount("saved@example.com", user: user, org: org, directory: nil, home: home)
        let result = await assembly(home: home, defaults: defaults)
        let profile = try XCTUnwrap(result.claudeCards.first?.profile)
        let swap = ClaudeSwapAccount(root: home.path + "/.claude-swap-backup", slot: "1",
            email: "saved@example.com", identityKey: "\(user)|\(org)", organizationID: org)
        let credentials = #"{"claudeAiOauth":{"accessToken":"swap-session","expiresAt":4102444800000}}"#
        let files = FakeFiles([swap.sessionDirectory + "/.credentials.json": credentials])
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            swapAccount: swap, profile: profile)
        XCTAssertEqual(store.loadCredentialCandidates().map(\.oauth.accessToken), ["swap-session"])
        let generation = store.credentialGeneration()
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        state.oauth.accessToken = "rotated-swap"
        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        XCTAssertTrue(files.files[swap.sessionDirectory + "/.credentials.json"]?.contains("rotated-swap") == true)
        XCTAssertNil(files.files[profile.home + "/.credentials.json"])
    }

    func testProfileRejectsUsageFromAChangedAccount() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("work@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        let result = await assembly(home: home, defaults: defaults)
        let profile = try XCTUnwrap(result.claudeCards.first?.profile)
        let credentials = #"{"claudeAiOauth":{"accessToken":"wrong-account","expiresAt":4102444800000}}"#
        let store = ClaudeAuthStore(environment: FakeEnvironment(),
            files: FakeFiles([profile.home + "/.credentials.json": credentials]), keychain: FakeKeychain(), profile: profile)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url.path, "/api/oauth/profile")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"account":{"uuid":"different-user"},"organization":{"uuid":"org-a"}}"#.utf8))
        }
        let runtime = ClaudeProvider(authStore: store, usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        _ = await runtime.refresh()
        XCTAssertFalse(http.requests.contains { $0.url.path == "/api/oauth/usage" })
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRotatedProfileTokenIsSavedOnlyToItsOwnHome() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("work@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        let result = await assembly(home: home, defaults: defaults)
        let profile = try XCTUnwrap(result.claudeCards.first?.profile)
        let credentials = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-refresh","expiresAt":4102444800000},"otherLogin":{"value":"preserved"}}"#
        let files = FakeFiles([profile.home + "/.credentials.json": credentials, "~/.claude/.credentials.json": "untouched"])
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), profile: profile)
        let generation = store.credentialGeneration()
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        state.oauth.accessToken = "rotated"
        state.oauth.refreshToken = "rotated-refresh"
        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        let saved = try XCTUnwrap(files.files[profile.home + "/.credentials.json"])
        XCTAssertTrue(saved.contains("rotated-refresh"))
        XCTAssertTrue(saved.contains("preserved"))
        XCTAssertEqual(files.files["~/.claude/.credentials.json"], "untouched")
    }

    func testUnidentifiedAndMalformedFoldersDoNotHideValidProfiles() async throws {
        let (home, defaults) = try fixture()
        try writeAccount("work@example.com", user: "user-a", org: "org-a", directory: ".claude-work", home: home)
        for (directory, json) in [(".claude-broken", "{"), (".claude-unidentified", #"{"oauthAccount":{"emailAddress":"unknown@example.com"}}"#)] {
            let parent = home.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try json.write(to: parent.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        let result = await assembly(home: home, defaults: defaults)
        XCTAssertEqual(result.claudeCards.map(\.displayName), ["Claude — work@example.com"])
    }
}
