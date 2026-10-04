import Foundation

/// Account metadata from an independent Claude Code configuration folder. Discovery reads no secrets.
struct ClaudeProfileLogin: Equatable, Sendable {
    let home: String
    let email: String
    let identityKey: String
    let organizationID: String
    let organizationName: String?
    let usesDefaultKeychain: Bool
    let keychainConfigDirectory: String?

    static func discover(
        observer: DefaultAccountObserver,
        listDirectories: @Sendable (String) -> [String]
    ) -> [Self] {
        let userHome = observer.homeDirectory()
        let defaultHome = userHome.appendingPathComponent(".claude").path
        var homes: [(path: String, keychainDirectory: String?)] = [(defaultHome, nil)]
        if let configured = observer.environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, !configured.contains(",") {
            homes.insert((CodexHomeScanner.standardizedHome(configured, homeDirectory: userHome), configured), at: 0)
        }
        homes += listDirectories(userHome.path).filter { $0.hasPrefix(".claude-") }.sorted()
            .map { let path = userHome.appendingPathComponent($0).path; return (path, path) }
        var seen = Set<String>()
        return homes.compactMap { candidate in
            let home = candidate.path
            guard seen.insert(home).inserted else { return nil }
            let isDefault = home == defaultHome
            let statePath = isDefault ? userHome.appendingPathComponent(".claude.json").path : home + "/.claude.json"
            do {
                guard let text = try observer.files.readTextIfPresent(statePath) else { return nil }
                let state = try JSONDecoder().decode(DefaultAccountObserver.ClaudeStateFile.self, from: Data(text.utf8))
                guard let account = state.oauthAccount,
                      let email = account.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                      let org = account.organizationUuid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                      let identity = DefaultAccountObserver.claudeIdentityKey(account)
                else { return nil }
                return Self(home: home, email: email, identityKey: identity, organizationID: org.lowercased(),
                            organizationName: account.organizationName?.nilIfEmpty, usesDefaultKeychain: isDefault,
                            keychainConfigDirectory: candidate.keychainDirectory)
            } catch {
                // Decoder messages can include file content. Report the source, never its contents.
                AppLog.warn(.config, "accounts: Claude profile at \(home) has unreadable account metadata; skipping it")
                return nil
            }
        }
    }
}

/// A profile owns its own terminal history; it must not inherit another shell's profile override.
struct ClaudeProfileEnvironment: EnvironmentReading {
    let base: EnvironmentReading
    let directory: String?

    init(base: EnvironmentReading, profile: ClaudeProfileLogin?) {
        self.base = base
        self.directory = profile?.home
    }

    init(base: EnvironmentReading, directory: String) {
        self.base = base
        self.directory = directory
    }

    func value(for name: String) -> String? {
        if let directory, name == "CLAUDE_CONFIG_DIR" { return directory }
        return base.value(for: name)
    }
}
