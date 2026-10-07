import Foundation

actor AccountRepository {
    private let rootURL: URL
    private let legacyRootURL: URL?
    private let preferencesURL: URL
    private var preferences = QuotaBarPreferences()

    /// Before the QuotaBar rename the app stored everything in Application Support/CodexBar.
    init(rootURL: URL? = nil, legacyRootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultRoot = support.appendingPathComponent("QuotaBar", isDirectory: true)
        self.rootURL = rootURL ?? defaultRoot
        self.legacyRootURL = legacyRootURL ?? (rootURL == nil ? support.appendingPathComponent("CodexBar", isDirectory: true) : nil)
        self.preferencesURL = (rootURL ?? defaultRoot).appendingPathComponent("accounts.json")
    }

    func bootstrap() async throws {
        try await migrateLegacyRoot()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                preferences = try JSONDecoder.quotaBar.decode(QuotaBarPreferences.self, from: Data(contentsOf: preferencesURL))
            } catch {
                // Metadata is non-sensitive. A damaged file is preserved for inspection and the app recovers empty.
                preferences = QuotaBarPreferences()
            }
        }
    }

    func rootDirectory() -> URL { rootURL }
    func currentPreferences() -> QuotaBarPreferences { preferences }

    /// Moves the pre-rename data folder once and points managed profiles at their new
    /// location. Codex profiles keep their files in the folder; a Claude profile's Keychain
    /// item is keyed by its folder path, so it moves to the new path's item.
    private func migrateLegacyRoot() async throws {
        let manager = FileManager.default
        guard let legacyRootURL,
              !manager.fileExists(atPath: preferencesURL.path),
              manager.fileExists(atPath: legacyRootURL.appendingPathComponent("accounts.json").path) else { return }
        if manager.fileExists(atPath: rootURL.path) {
            // A QuotaBar folder without accounts can already hold scratch folders. Move the
            // legacy entries in beside them and leave any name clash in the legacy folder.
            for name in try manager.contentsOfDirectory(atPath: legacyRootURL.path) {
                let target = rootURL.appendingPathComponent(name)
                guard !manager.fileExists(atPath: target.path) else { continue }
                try manager.moveItem(at: legacyRootURL.appendingPathComponent(name), to: target)
            }
            if (try? manager.contentsOfDirectory(atPath: legacyRootURL.path))?.isEmpty == true {
                try? manager.removeItem(at: legacyRootURL)
            }
        } else {
            try manager.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: legacyRootURL, to: rootURL)
        }

        guard let data = try? Data(contentsOf: preferencesURL),
              var migrated = try? JSONDecoder.quotaBar.decode(QuotaBarPreferences.self, from: data) else { return }
        let legacyPrefix = legacyRootURL.standardizedFileURL.path + "/"
        var movedClaudeHomes: [(old: String, new: String)] = []
        for index in migrated.profiles.indices where migrated.profiles[index].isManagedByApp {
            let oldPath = migrated.profiles[index].codexHomePath.standardizedFileURL.path
            guard oldPath.hasPrefix(legacyPrefix) else { continue }
            let newHome = rootURL.appendingPathComponent(String(oldPath.dropFirst(legacyPrefix.count)), isDirectory: true)
            migrated.profiles[index].codexHomePath = newHome
            if migrated.profiles[index].provider == .claude {
                movedClaudeHomes.append((oldPath, newHome.path))
            }
        }
        preferences = migrated
        try persist()
        for home in movedClaudeHomes {
            await ClaudeCredentialStore.moveManagedItem(fromConfigDirectory: home.old, toConfigDirectory: home.new)
        }
    }

    func save(_ newPreferences: QuotaBarPreferences) throws -> QuotaBarPreferences {
        preferences = newPreferences
        try persist()
        return preferences
    }

    private func persist() throws {
        let data = try JSONEncoder.quotaBar.encode(preferences)
        try data.write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
    }
}

enum ProfileManager {
    static func managedHomeDirectoryName(for provider: AccountProvider) -> String {
        switch provider {
        case .codex: "codex-home"
        case .claude: "claude-home"
        }
    }

    static func createManagedProfile(
        alias: String,
        provider: AccountProvider = .codex,
        repositoryRoot: URL
    ) throws -> AccountProfile {
        let id = UUID()
        let accountRoot = repositoryRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let home = accountRoot.appendingPathComponent(managedHomeDirectoryName(for: provider), isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        for url in [repositoryRoot.appendingPathComponent("Accounts", isDirectory: true), accountRoot, home] {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        if provider == .codex {
            let configURL = home.appendingPathComponent("config.toml")
            let config = "cli_auth_credentials_store = \"file\"\n"
            try config.data(using: .utf8)?.write(to: configURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
        return AccountProfile(
            id: id,
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            codexHomePath: home,
            isManagedByApp: true,
            provider: provider
        )
    }

    static func defaultHome(for provider: AccountProvider) -> URL {
        switch provider {
        case .codex: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        case .claude: ClaudeProfilePaths.defaultConfigDirectory
        }
    }

    static func defaultProfile(alias: String, provider: AccountProvider) -> AccountProfile {
        AccountProfile(alias: alias, codexHomePath: defaultHome(for: provider), isManagedByApp: false, provider: provider)
    }

    static func secureAuthenticationFile(at codexHome: URL) {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    static func removeManagedProfile(_ profile: AccountProfile, repositoryRoot: URL) throws {
        guard profile.isManagedByApp else { return }
        try FileManager.default.removeItem(at: managedAccountRoot(for: profile, repositoryRoot: repositoryRoot))
    }

    /// The UUID folder that may be deleted for a managed profile, after checking that the
    /// saved home path points exactly at that profile's provider home inside it.
    static func managedAccountRoot(for profile: AccountProfile, repositoryRoot: URL) throws -> URL {
        let expected = repositoryRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        let resolvedExpected = expected.standardizedFileURL.path
        let resolvedHome = profile.codexHomePath.standardizedFileURL.path
        let expectedHome = expected.appendingPathComponent(managedHomeDirectoryName(for: profile.provider), isDirectory: true)
        guard resolvedHome == expectedHome.standardizedFileURL.path,
              resolvedExpected.hasPrefix(repositoryRoot.standardizedFileURL.path + "/") else {
            throw QuotaBarError.invalidProfilePath
        }
        return expected
    }

}

struct CodexExecutableLocator: Sendable {
    var configuredURL: URL?

    func locate() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let configuredURL { candidates.append(configuredURL) }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        candidates += pathEntries.map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return match }
        if let configuredURL { throw QuotaBarError.executableNotUsable(configuredURL) }
        throw QuotaBarError.executableNotFound
    }

    func version(at executable: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw QuotaBarError.executableNotUsable(executable) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol CodexUsageProvider: Sendable {
    func refresh(includeUsage: Bool) async throws -> ProviderRefreshResult
    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin
    func waitForLogin(loginID: String) async throws
    func cancelLogin(loginID: String) async
    func logout() async
    func shutdown() async
}

actor CodexClientPool {
    private var clients: [UUID: CodexAppServerClient] = [:]
    private var claudeClients: [UUID: ClaudeUsageClient] = [:]
    private var configuredExecutableURL: URL?
    private var accountUpdateHandler: (@Sendable (UUID) async -> Void)?

    func setConfiguredExecutableURL(_ url: URL?) async {
        guard configuredExecutableURL != url else { return }
        let activeClients = Array(clients.values)
        clients.removeAll()
        configuredExecutableURL = url
        for client in activeClients { await client.shutdown() }
    }

    func setAccountUpdateHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
        accountUpdateHandler = handler
    }

    func refresh(profile: AccountProfile, includeUsage: Bool) async throws -> ProviderRefreshResult {
        switch profile.provider {
        case .codex: try await client(for: profile).refresh(includeUsage: includeUsage)
        case .claude: try await claudeClient(for: profile).refresh(includeUsage: includeUsage)
        }
    }

    func beginLogin(profile: AccountProfile) async throws -> AccountLogin {
        switch profile.provider {
        case .codex: .deviceCode(try await client(for: profile).beginDeviceCodeLogin())
        case .claude: .claudeBrowser(try await claudeClient(for: profile).beginBrowserLogin())
        }
    }

    func waitForLogin(profile: AccountProfile, loginID: String) async throws {
        switch profile.provider {
        case .codex:
            try await client(for: profile).waitForLogin(loginID: loginID)
            ProfileManager.secureAuthenticationFile(at: profile.codexHomePath)
        case .claude:
            try await claudeClient(for: profile).waitForLogin(loginID: loginID)
        }
    }

    func submitClaudeLoginCode(profile: AccountProfile, loginID: String, code: String) async {
        guard profile.provider == .claude else { return }
        await claudeClient(for: profile).submitLoginCode(code, loginID: loginID)
    }

    func cancelLogin(profile: AccountProfile, loginID: String) async {
        switch profile.provider {
        case .codex:
            guard let activeClient = try? await client(for: profile) else { return }
            await activeClient.cancelLogin(loginID: loginID)
        case .claude:
            await claudeClient(for: profile).cancelLogin(loginID: loginID)
        }
    }

    func logout(profile: AccountProfile) async {
        switch profile.provider {
        case .codex:
            guard let activeClient = try? await client(for: profile) else { return }
            await activeClient.logout()
        case .claude:
            await claudeClient(for: profile).logout()
        }
    }

    func shutdownAll() async {
        let activeClients = Array(clients.values)
        let activeClaudeClients = Array(claudeClients.values)
        clients.removeAll()
        claudeClients.removeAll()
        for client in activeClients { await client.shutdown() }
        for client in activeClaudeClients { await client.shutdown() }
    }

    func removeClient(for accountID: UUID) async {
        if let client = clients.removeValue(forKey: accountID) { await client.shutdown() }
        if let client = claudeClients.removeValue(forKey: accountID) { await client.shutdown() }
    }

    /// The Claude CLI is located lazily: reading usage needs only the Keychain and the network.
    private func claudeClient(for profile: AccountProfile) -> ClaudeUsageClient {
        if let existing = claudeClients[profile.id] { return existing }
        let newClient = ClaudeUsageClient(profile: profile)
        claudeClients[profile.id] = newClient
        return newClient
    }

    private func client(for profile: AccountProfile) async throws -> CodexAppServerClient {
        if let existing = clients[profile.id] { return existing }
        let executable = try CodexExecutableLocator(configuredURL: configuredExecutableURL).locate()
        let profileID = profile.id
        let newClient = CodexAppServerClient(profile: profile, executableURL: executable) { [weak self] in
            await self?.forwardAccountUpdate(for: profileID)
        }
        clients[profile.id] = newClient
        return newClient
    }

    private func forwardAccountUpdate(for profileID: UUID) async {
        await accountUpdateHandler?(profileID)
    }
}

actor PollingCoordinator {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(
        profiles: [AccountProfile],
        refresh: @escaping @Sendable (UUID, Bool) async -> Bool
    ) {
        stop()
        for (index, profile) in profiles.enumerated() where profile.isEnabled {
            let profileID = profile.id
            tasks[profileID] = Task { [weak self] in
                if index > 0 { try? await Task.sleep(for: .seconds(Double(index))) }
                var consecutiveFailures = 0
                var cycle = 0
                while !Task.isCancelled {
                    let includeUsage = cycle == 0 || cycle % 4 == 0
                    let succeeded = await refresh(profileID, includeUsage)
                    consecutiveFailures = succeeded ? 0 : min(consecutiveFailures + 1, 4)
                    cycle += 1
                    let base = PollingPolicy.delay(forConsecutiveFailures: consecutiveFailures)
                    let jitter = Double.random(in: 0...2)
                    try? await Task.sleep(for: .seconds(base + jitter))
                }
                await self?.removeTask(profileID)
            }
        }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func removeTask(_ id: UUID) { tasks[id] = nil }
}

enum PollingPolicy {
    static func delay(forConsecutiveFailures failures: Int) -> Double {
        switch failures {
        case ...0: 30
        case 1: 60
        case 2: 120
        default: 300
        }
    }
}

enum QuotaBarFormatters {
    static let token: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 3
        return formatter
    }()

    static func tokenText(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        if #available(macOS 13.0, *) {
            return tokens.formatted(.number.notation(.compactName))
        }
        return token.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    static func fullTokenText(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: tokens), number: .decimal)
    }

    static func dailyUsageLabel(
        for startDate: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard let startDate = startDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !startDate.isEmpty else {
            return "최근 일"
        }

        // The app-server currently sends an ISO date (and may add a time later).
        // Compare its date portion with the user's local calendar day. If it is
        // not today's bucket, show the actual date instead of claiming it is today.
        let bucketDate = String(startDate.prefix(10))
        guard bucketDate.count == 10 else { return "최근 일 · \(startDate)" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return bucketDate == formatter.string(from: now) ? "오늘" : "최근 일 · \(bucketDate)"
    }

    static func windowText(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "기간 미상" }
        if minutes % (60 * 24 * 7) == 0 { return "\(minutes / (60 * 24 * 7))주" }
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24))일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }

    /// Limit names as people say them: a seven-day window is "주간", not "1주".
    static func windowLabel(_ minutes: Int?) -> String {
        minutes == 7 * 24 * 60 ? "주간" : windowText(minutes)
    }

    /// The UI is Korean, so times are too, whatever the system language: "38분 후".
    static func resetCountdown(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "초기화 시각 미상" }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "곧 초기화" }
        if minutes < 60 { return "\(minutes)분 후" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 { return remainingMinutes == 0 ? "\(hours)시간 후" : "\(hours)시간 \(remainingMinutes)분 후" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)일 후" : "\(days)일 \(remainingHours)시간 후"
    }

    /// "오늘 13:20", "내일 09:00", "10월 9일 (금) 19:00".
    static func resetClock(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "오늘 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "내일 \(time)"
        }
        formatter.dateFormat = "M월 d일 (E) HH:mm"
        return formatter.string(from: date)
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "초기화 시각 미상" }
        let countdown = resetCountdown(date)
        return resetClock(date).map { "\(countdown) · \($0)" } ?? countdown
    }

    static func fetchedText(_ date: Date?) -> String {
        guard let date else { return "아직 갱신하지 않음" }
        if Date.now.timeIntervalSince(date) < 5 { return "방금" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

enum RedactingLogger {
    static func redact(_ text: String) -> String {
        let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let queryPattern = #"(https?://[^\s?]+)\?[^\s]+"#
        let redactedEmail = text.replacingOccurrences(of: emailPattern, with: "[email]", options: [.regularExpression, .caseInsensitive])
        return redactedEmail.replacingOccurrences(of: queryPattern, with: "$1?[redacted]", options: .regularExpression)
    }
}

private extension JSONDecoder {
    static var quotaBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var quotaBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
