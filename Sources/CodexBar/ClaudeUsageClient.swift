import CryptoKit
import Foundation

actor ClaudeExecutableLocator {
    static let shared = ClaudeExecutableLocator()

    private var resolved: URL?

    /// GUI apps start with a minimal PATH, so check the usual install locations first and
    /// fall back to asking the user's login shell once.
    func locate() async throws -> URL {
        if let resolved, FileManager.default.isExecutableFile(atPath: resolved.path) { return resolved }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".volta/bin/claude")
        ]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        candidates += pathEntries.map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            resolved = match
            return match
        }
        if let shellMatch = await locateWithLoginShell() {
            resolved = shellMatch
            return shellMatch
        }
        throw CodexBarError.claudeExecutableNotFound
    }

    /// Version managers such as nvm or fnm usually add their PATH in the interactive shell setup.
    private func locateWithLoginShell() async -> URL? {
        guard let output = try? await ClaudeProcessRunner.run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", "command -v claude"],
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(5)
        ), output.status == 0 else { return nil }
        let lines = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let path = lines.last.map(String.init)?.trimmingCharacters(in: .whitespaces),
              path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum ClaudeProfilePaths {
    static var defaultConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Private scratch profiles for token renewal. The path has no symlinks, so the Keychain
    /// item Claude Code creates for it can be found again and deleted.
    static var renewalRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("ClaudeRenewal", isDirectory: true)
    }

    /// The CLAUDE_CONFIG_DIR value for a profile, or nil for Claude Code's default location.
    /// The default must not be passed explicitly: Claude Code keys its Keychain item on
    /// whether the variable is set, so `~/.claude` passed explicitly is a different login.
    static func configDirectoryEnvironment(for profile: AccountProfile) -> String? {
        profile.isManagedByApp ? profile.codexHomePath.path : nil
    }
}

struct ClaudeOAuthCredentials: Sendable, Equatable {
    var accessToken: String
    var hasRefreshToken: Bool
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    /// `margin` keeps a request from starting with a token that is about to expire.
    func isUsable(at date: Date, margin: TimeInterval = 60) -> Bool {
        guard !accessToken.isEmpty else { return false }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(date) > margin
    }

    /// claude.ai reports Max without its multiplier; the rate-limit tier carries it.
    var planType: String? {
        guard let subscriptionType = subscriptionType?.lowercased(), !subscriptionType.isEmpty else { return nil }
        guard subscriptionType == "max", let tier = rateLimitTier?.lowercased() else { return subscriptionType }
        if tier.contains("20x") { return "max_20x" }
        if tier.contains("5x") { return "max_5x" }
        return subscriptionType
    }

    /// Identifies the login without keeping a second copy of the token around.
    var fingerprint: String {
        SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where a credential document came from, so a renewed token is written back to the same place.
enum ClaudeCredentialSource: Sendable, Equatable {
    case keychain(service: String)
    case file(URL)
}

/// Claude Code's whole credential document. Renewal replaces only `claudeAiOauth` and keeps
/// everything else Claude Code stores alongside it, such as MCP OAuth state.
struct ClaudeCredentialDocument: Sendable, Equatable {
    var value: JSONValue
    var source: ClaudeCredentialSource

    var oauth: JSONValue? { value["claudeAiOauth"] }
    var credentials: ClaudeOAuthCredentials? { ClaudeCredentialStore.credentials(in: value) }
}

enum ClaudeCredentialStore {
    private static let security = URL(fileURLWithPath: "/usr/bin/security")
    /// Claude Code's own limit before it stops sending the command through `security -i`.
    private static let interactiveCommandLimit = 4_000

    /// Claude Code stores the default login as "Claude Code-credentials" and, when
    /// CLAUDE_CONFIG_DIR is set, appends the first 8 hex digits of SHA-256 of that value
    /// after Unicode NFC normalization.
    static func keychainService(configDirectory: String?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let normalized = configDirectory.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }

    static func parse(_ data: Data) -> ClaudeOAuthCredentials? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return credentials(in: value)
    }

    static func credentials(in value: JSONValue) -> ClaudeOAuthCredentials? {
        guard let oauth = value["claudeAiOauth"], oauth.object != nil else { return nil }
        return ClaudeOAuthCredentials(
            accessToken: oauth["accessToken"]?.string ?? "",
            hasRefreshToken: !(oauth["refreshToken"]?.string ?? "").isEmpty,
            expiresAt: oauth["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"]?.string,
            rateLimitTier: oauth["rateLimitTier"]?.string
        )
    }

    static func read(configDirectory: String?) async -> ClaudeOAuthCredentials? {
        await readDocument(configDirectory: configDirectory)?.credentials
    }

    /// Reads through `/usr/bin/security`, which Claude Code itself uses to write the item, so
    /// the item's access list already allows it. Falls back to the plaintext file Claude Code
    /// writes when the Keychain is unavailable. Credentials stay in memory only.
    static func readDocument(configDirectory: String?) async -> ClaudeCredentialDocument? {
        let service = keychainService(configDirectory: configDirectory)
        if let output = try? await ClaudeProcessRunner.run(
            security,
            arguments: ["find-generic-password", "-s", service, "-w"],
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(10)
        ), output.status == 0,
           let value = try? JSONDecoder().decode(JSONValue.self, from: output.stdout),
           value["claudeAiOauth"]?.object != nil {
            return ClaudeCredentialDocument(value: value, source: .keychain(service: service))
        }
        let directory = configDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ClaudeProfilePaths.defaultConfigDirectory
        let file = directory.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value["claudeAiOauth"]?.object != nil else { return nil }
        return ClaudeCredentialDocument(value: value, source: .file(file))
    }

    /// Writes the way Claude Code does: the command goes through `security -i` on stdin so the
    /// token never appears in another process's argument list.
    static func write(_ value: JSONValue, to source: ClaudeCredentialSource) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        switch source {
        case .file(let url):
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        case .keychain(let service):
            let account = await keychainAccount(service: service) ?? NSUserName()
            guard !account.contains("\""), !account.contains("\n"), !service.contains("\"") else {
                throw CodexBarError.claudeTokenRenewalFailed
            }
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
            let output: ClaudeProcessRunner.Output
            if command.utf8.count <= interactiveCommandLimit {
                output = try await ClaudeProcessRunner.run(
                    security,
                    arguments: ["-i"],
                    environment: ProcessInfo.processInfo.environment,
                    input: Data(command.utf8),
                    timeout: .seconds(10)
                )
            } else {
                output = try await ClaudeProcessRunner.run(
                    security,
                    arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: .seconds(10)
                )
            }
            guard output.status == 0 else { throw CodexBarError.claudeTokenRenewalFailed }
        }
    }

    /// The item's account attribute, so an update replaces Claude Code's item instead of adding one.
    static func keychainAccount(service: String) async -> String? {
        guard let output = try? await ClaudeProcessRunner.run(
            security,
            arguments: ["find-generic-password", "-s", service],
            environment: ProcessInfo.processInfo.environment,
            captureStandardError: true,
            timeout: .seconds(10)
        ), output.status == 0 else { return nil }
        let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        guard let range = text.range(of: #""acct"<blob>="[^"\n]*""#, options: .regularExpression) else { return nil }
        let attribute = text[range]
        return String(attribute.dropFirst(#""acct"<blob>=""#.count).dropLast())
    }

    /// For app-managed profiles whose CLI logout could not run, and for renewal scratch
    /// profiles: the item would otherwise outlive its folder with a refresh token in it.
    static func deleteManagedItem(configDirectory: String) async {
        _ = try? await ClaudeProcessRunner.run(
            security,
            arguments: ["delete-generic-password", "-s", keychainService(configDirectory: configDirectory)],
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(10)
        )
    }
}

enum ClaudeUsageMapper {
    /// Prefers the `limits` list Claude Code's `/usage` screen is built from and falls back
    /// to the older named windows (`five_hour`, `seven_day`, `seven_day_<model>`).
    static func rateLimitBuckets(from usage: JSONValue) -> [RateLimitBucket] {
        let listed = buckets(fromLimits: usage["limits"]?.array ?? [])
        return listed.isEmpty ? buckets(fromNamedWindows: usage) : listed
    }

    static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    /// Finds the manual sign-in URL in `claude auth login` output. The CLI may wrap it in
    /// colour codes or an OSC 8 terminal hyperlink depending on the inherited environment.
    static func authorizationURL(in output: String) -> URL? {
        let plain = output
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        guard let range = plain.range(of: "https://[^\\s\u{00}-\u{1F}\u{7F}]+", options: .regularExpression) else { return nil }
        return URL(string: String(plain[range]))
    }

    private static func buckets(fromLimits rows: [JSONValue]) -> [RateLimitBucket] {
        var session: RateLimitWindow?
        var weekly: RateLimitWindow?
        var scoped: [RateLimitBucket] = []
        for row in rows {
            guard let percent = row["percent"]?.double else { continue }
            let kind = row["kind"]?.string ?? ""
            let group = row["group"]?.string ?? ""
            let isSession = kind == "session" || group == "session"
            let isWeekly = kind.hasPrefix("weekly") || group == "weekly"
            guard isSession || isWeekly else { continue }
            let window = RateLimitWindow(
                usedPercent: percent,
                windowDurationMinutes: isSession ? 5 * 60 : 7 * 24 * 60,
                resetsAt: date(from: row["resets_at"]?.string)
            )
            let model = row["scope"]?["model"]?["display_name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            if !model.isEmpty {
                scoped.append(bucket(
                    id: "claude_\(isSession ? "session" : "weekly")_\(slug(model))",
                    name: "\(model) \(isSession ? "5시간" : "주간")",
                    primary: window,
                    secondary: nil
                ))
            } else if isSession {
                session = session ?? window
            } else {
                weekly = weekly ?? window
            }
        }
        let main = (session != nil || weekly != nil)
            ? [bucket(id: "claude", name: "Claude", primary: session, secondary: weekly)]
            : []
        return main + scoped
    }

    private static func buckets(fromNamedWindows usage: JSONValue) -> [RateLimitBucket] {
        var buckets: [RateLimitBucket] = []
        let session = window(from: usage["five_hour"], minutes: 5 * 60)
        let weekly = window(from: usage["seven_day"], minutes: 7 * 24 * 60)
        if session != nil || weekly != nil {
            buckets.append(bucket(id: "claude", name: "Claude", primary: session, secondary: weekly))
        }
        let scopedKeys = (usage.object.map { Array($0.keys) } ?? []).filter { $0.hasPrefix("seven_day_") }.sorted()
        for key in scopedKeys {
            guard let scoped = window(from: usage[key], minutes: 7 * 24 * 60) else { continue }
            let model = key.dropFirst("seven_day_".count).split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            buckets.append(bucket(id: "claude_weekly_\(slug(model))", name: "\(model) 주간", primary: scoped, secondary: nil))
        }
        return buckets
    }

    private static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func window(from value: JSONValue?, minutes: Int) -> RateLimitWindow? {
        guard let utilization = value?["utilization"]?.double else { return nil }
        return RateLimitWindow(
            usedPercent: utilization,
            windowDurationMinutes: minutes,
            resetsAt: date(from: value?["resets_at"]?.string)
        )
    }

    private static func bucket(id: String, name: String, primary: RateLimitWindow?, secondary: RateLimitWindow?) -> RateLimitBucket {
        RateLimitBucket(
            limitId: id,
            displayName: name,
            primary: primary,
            secondary: secondary,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditBalance: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
    }
}

/// Process is not Sendable; it is only touched from the owning actor and its own handlers.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Collects a child's output from Foundation's background reader without tying up a
/// Swift concurrency thread in a blocking read.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var isFinished = false
    private var waiter: CheckedContinuation<Data, Never>?

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finish()
            } else {
                append(chunk)
            }
        }
    }

    func append(_ chunk: Data) {
        lock.withLock { if !isFinished { data.append(chunk) } }
    }

    func finish() {
        let pending: (CheckedContinuation<Data, Never>, Data)? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            defer { waiter = nil }
            return waiter.map { ($0, data) }
        }
        if let (waiter, collected) = pending { waiter.resume(returning: collected) }
    }

    func value() async -> Data {
        await withCheckedContinuation { continuation in
            let ready: Data? = lock.withLock {
                if isFinished { return data }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

enum ClaudeProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// stderr is discarded unless a caller needs to classify a failure; it can contain
    /// account details and is never logged or persisted.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data? = nil,
        captureStandardError: Bool = false,
        timeout: Duration
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let output = Pipe()
        let errors = captureStandardError ? Pipe() : nil
        process.standardOutput = output
        process.standardError = errors ?? FileHandle.nullDevice
        let box = ProcessBox(process)
        // Drain output while the child runs: a pipe can block the writer long before exit.
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        stdout.attach(to: output)
        if let errors { stderr.attach(to: errors) } else { stderr.finish() }
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let input, let inputPipe {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    guard box.process.isRunning else { return }
                    box.process.terminate()
                    try? await Task.sleep(for: .seconds(3))
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors?.fileHandleForReading.readabilityHandler = nil
            stdout.finish()
            stderr.finish()
            throw error
        }
        // A grandchild that inherited the pipes can keep them open; do not wait on it for long.
        Task {
            try? await Task.sleep(for: .seconds(2))
            stdout.finish()
            stderr.finish()
        }
        let collectedOutput = await stdout.value()
        let collectedErrors = await stderr.value()
        output.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        return Output(status: status, stdout: collectedOutput, stderr: collectedErrors)
    }
}

/// Reads claude.ai subscription limits for exactly one CLAUDE_CONFIG_DIR.
///
/// The usage endpoint is the one behind Claude Code's `/usage` screen. An access token near
/// expiry, or one the endpoint rejects, is renewed the way Ptah's collector does it: Claude
/// Code redeems the refresh token inside a private scratch profile, and only a complete,
/// validated rotation is written back to the live login. A failed renewal therefore never
/// signs the account out.
actor ClaudeUsageClient {
    private enum UsageFailure: Error {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
    }

    private enum RenewalOutcome {
        case renewed(JSONValue)
        case failed(loginRequired: Bool)
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Polling runs every 30 s; the unofficial endpoint is asked at most about once a minute.
    static let minimumFetchInterval: TimeInterval = 55
    /// Renew a little before expiry so a poll does not race the token's last seconds.
    static let renewAhead: TimeInterval = 120

    private let profile: AccountProfile
    /// Tests substitute a stand-in CLI; the app locates the installed one.
    private let executableURL: URL?
    private let session = URLSession(configuration: .ephemeral)
    private var cachedResult: ProviderRefreshResult?
    private var lastFetchedAt: Date?
    private var email: String?
    private var emailFingerprint: String?
    /// Bumped by each completed login so a refresh that started earlier cannot cache the
    /// previous account's data.
    private var loginGeneration = 0

    private var usageRetryAt: Date?
    private var usageRateLimitCount = 0
    private var renewalRetryAt: Date?
    private var renewalFailureCount = 0
    private var renewalFailureRequiresLogin = false
    /// A backoff applies only to the login that failed; signing in again clears it.
    private var renewalFailureFingerprint: String?

    private var loginProcess: ProcessBox?
    private var loginInput: Pipe?
    private var loginOutput: Pipe?
    private var activeLoginID: String?
    private var loginOutputText = ""
    private var loginExitStatus: Int32?
    private var loginWasCancelled = false
    private var loginWaiter: CheckedContinuation<Void, Error>?

    init(profile: AccountProfile, executableURL: URL? = nil) {
        self.profile = profile
        self.executableURL = executableURL
    }

    func refresh(includeUsage: Bool) async throws -> ProviderRefreshResult {
        if !includeUsage, let cachedResult, let lastFetchedAt,
           Date.now.timeIntervalSince(lastFetchedAt) < Self.minimumFetchInterval {
            return cachedResult
        }
        if let usageRetryAt, Date.now < usageRetryAt { throw CodexBarError.claudeUsageRateLimited }
        let generation = loginGeneration

        var credentials = try await usableCredentials(rejecting: nil)
        let usage: JSONValue
        do {
            usage = try await fetchUsage(accessToken: credentials.accessToken)
        } catch UsageFailure.unauthorized {
            // The token was revoked or rotated elsewhere; renew once and retry.
            credentials = try await usableCredentials(rejecting: credentials.accessToken)
            do {
                usage = try await fetchUsage(accessToken: credentials.accessToken)
            } catch UsageFailure.unauthorized {
                throw CodexBarError.authenticationRequired
            } catch UsageFailure.rateLimited(let retryAfter) {
                throw backOffUsage(retryAfter: retryAfter)
            }
        } catch UsageFailure.rateLimited(let retryAfter) {
            throw backOffUsage(retryAfter: retryAfter)
        }
        usageRateLimitCount = 0
        usageRetryAt = nil

        // A new token means a renewal or a different account, possibly switched in a terminal.
        let fingerprint = credentials.fingerprint
        var currentEmail = email
        if emailFingerprint != fingerprint {
            currentEmail = await readEmail()
        }
        let result = ProviderRefreshResult(
            identity: AccountIdentity(loginType: "claude.ai", email: currentEmail, planType: credentials.planType),
            buckets: ClaudeUsageMapper.rateLimitBuckets(from: usage),
            tokenSummary: nil
        )
        if generation == loginGeneration {
            email = currentEmail
            emailFingerprint = fingerprint
            cachedResult = result
            lastFetchedAt = .now
        }
        return result
    }

    func beginBrowserLogin() async throws -> ClaudeBrowserLogin {
        abandonActiveLogin()
        let executable = try await locateExecutable()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = childEnvironment(executable: executable, configDirectory: configDirectory)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let loginID = UUID().uuidString
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: an uncleared handler would keep firing on the closed pipe.
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.receiveLoginOutput(data, loginID: loginID) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.loginProcessDidExit(status: status, loginID: loginID) }
        }
        activeLoginID = loginID
        loginOutputText = ""
        loginExitStatus = nil
        loginWasCancelled = false
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            activeLoginID = nil
            throw error
        }
        loginProcess = ProcessBox(process)
        loginInput = input
        loginOutput = output

        // The CLI opens the browser itself and then prints a manual fallback URL.
        for _ in 0..<30 where currentAuthorizationURL() == nil && loginExitStatus == nil && activeLoginID == loginID {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard activeLoginID == loginID, !loginWasCancelled else { throw CancellationError() }
        if let status = loginExitStatus, status != 0 { throw CodexBarError.invalidLoginResponse }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.timeoutLogin(loginID: loginID)
        }
        return ClaudeBrowserLogin(loginID: loginID, authorizationURL: currentAuthorizationURL())
    }

    /// Supplies the code shown by the manual fallback page to the waiting CLI.
    func submitLoginCode(_ code: String, loginID: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loginID == activeLoginID, loginExitStatus == nil, !clean.isEmpty, let loginInput else { return }
        try? loginInput.fileHandleForWriting.write(contentsOf: Data((clean + "\n").utf8))
    }

    func waitForLogin(loginID: String) async throws {
        guard loginID == activeLoginID else { throw CancellationError() }
        if loginExitStatus == nil {
            try await withCheckedThrowingContinuation { continuation in
                loginWaiter = continuation
            }
        } else {
            try finishedLoginResult()
        }
        // A new login may belong to a different claude.ai account.
        resetAccountState()
        guard await readCredentials()?.isUsable(at: .now) == true else { throw CodexBarError.authenticationRequired }
    }

    func cancelLogin(loginID: String) {
        guard loginID == activeLoginID else { return }
        loginWasCancelled = true
        terminateLogin()
    }

    func logout() async {
        var loggedOut = false
        if let executable = try? await locateExecutable(),
           let output = try? await ClaudeProcessRunner.run(
               executable,
               arguments: ["auth", "logout"],
               environment: childEnvironment(executable: executable, configDirectory: configDirectory),
               timeout: .seconds(20)
           ) {
            loggedOut = output.status == 0
        }
        if !loggedOut, let configDirectory {
            await ClaudeCredentialStore.deleteManagedItem(configDirectory: configDirectory)
        }
        resetAccountState()
    }

    func shutdown() {
        abandonActiveLogin()
    }

    private var configDirectory: String? {
        ClaudeProfilePaths.configDirectoryEnvironment(for: profile)
    }

    private func locateExecutable() async throws -> URL {
        if let executableURL { return executableURL }
        return try await ClaudeExecutableLocator.shared.locate()
    }

    private func readCredentials() async -> ClaudeOAuthCredentials? {
        await ClaudeCredentialStore.read(configDirectory: configDirectory)
    }

    private func resetAccountState() {
        loginGeneration += 1
        email = nil
        emailFingerprint = nil
        cachedResult = nil
        lastFetchedAt = nil
        renewalRetryAt = nil
        renewalFailureCount = 0
        renewalFailureRequiresLogin = false
        renewalFailureFingerprint = nil
    }

    private func backOffUsage(retryAfter: TimeInterval?) -> CodexBarError {
        usageRateLimitCount = min(5, usageRateLimitCount + 1)
        let backoff = min(3_600, 300 * pow(2, Double(usageRateLimitCount - 1)))
        usageRetryAt = Date.now.addingTimeInterval(max(retryAfter ?? 0, backoff))
        return .claudeUsageRateLimited
    }

    /// Returns a token the usage endpoint should accept, renewing it when it is close to
    /// expiry or was just rejected.
    func usableCredentials(rejecting rejectedToken: String?) async throws -> ClaudeOAuthCredentials {
        guard let document = await ClaudeCredentialStore.readDocument(configDirectory: configDirectory),
              let current = document.credentials else { throw CodexBarError.authenticationRequired }
        let isRejected = rejectedToken != nil && current.accessToken == rejectedToken
        if !isRejected, current.isUsable(at: .now, margin: Self.renewAhead) { return current }
        let stillValid = !isRejected && current.isUsable(at: .now, margin: 0)

        if let renewalRetryAt, Date.now < renewalRetryAt, renewalFailureFingerprint == current.fingerprint {
            if stillValid { return current }
            throw renewalFailureRequiresLogin ? CodexBarError.authenticationRequired : CodexBarError.claudeTokenRenewalFailed
        }
        guard let oauth = document.oauth, current.hasRefreshToken else { throw CodexBarError.authenticationRequired }

        let executable = try await locateExecutable()
        let outcome = await renewInScratchProfile(oauth: oauth, previousAccessToken: current.accessToken, executable: executable)

        // Claude Code may have renewed the token, or the user may have signed in again,
        // while the scratch renewal ran. Never write over that newer login.
        guard let latest = await ClaudeCredentialStore.readDocument(configDirectory: configDirectory) else {
            throw CodexBarError.authenticationRequired
        }
        if latest.value != document.value {
            if let latestCredentials = latest.credentials,
               latestCredentials.accessToken != rejectedToken,
               latestCredentials.isUsable(at: .now) {
                return latestCredentials
            }
            throw CodexBarError.claudeTokenRenewalFailed
        }

        switch outcome {
        case .renewed(let fresh):
            var merged = oauth.object ?? [:]
            for (key, value) in fresh.object ?? [:] { merged[key] = value }
            var updated = document.value.object ?? [:]
            updated["claudeAiOauth"] = .object(merged)
            try await ClaudeCredentialStore.write(.object(updated), to: document.source)
            guard let written = await readCredentials(), written.accessToken == fresh["accessToken"]?.string else {
                throw CodexBarError.claudeTokenRenewalFailed
            }
            renewalRetryAt = nil
            renewalFailureCount = 0
            renewalFailureRequiresLogin = false
            renewalFailureFingerprint = nil
            return written
        case .failed(let loginRequired):
            renewalFailureCount = min(5, renewalFailureCount + 1)
            renewalRetryAt = Date.now.addingTimeInterval(min(3_600, 300 * pow(2, Double(renewalFailureCount - 1))))
            renewalFailureRequiresLogin = loginRequired
            renewalFailureFingerprint = current.fingerprint
            if stillValid { return current }
            throw loginRequired ? CodexBarError.authenticationRequired : CodexBarError.claudeTokenRenewalFailed
        }
    }

    /// Runs `claude auth login` with the refresh grant in an empty scratch profile. The CLI
    /// may clear the profile it runs in when the exchange fails, so it never sees the live one.
    private func renewInScratchProfile(oauth: JSONValue, previousAccessToken: String, executable: URL) async -> RenewalOutcome {
        guard let refreshToken = oauth["refreshToken"]?.string, !refreshToken.isEmpty,
              let scopes = oauth["scopes"]?.array?.compactMap(\.string), !scopes.isEmpty,
              scopes.allSatisfy({ !$0.isEmpty }) else { return .failed(loginRequired: true) }

        let scratch = ClaudeProfilePaths.renewalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: scratch,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(loginRequired: false)
        }

        var environment = childEnvironment(executable: executable, configDirectory: scratch.path)
        environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refreshToken
        environment["CLAUDE_CODE_OAUTH_SCOPES"] = scopes.joined(separator: " ")
        environment["BROWSER"] = "false"
        if let clientID = oauth["clientId"]?.string, !clientID.isEmpty {
            environment["CLAUDE_CODE_OAUTH_CLIENT_ID"] = clientID
        }
        let output = try? await ClaudeProcessRunner.run(
            executable,
            arguments: ["auth", "login", "--claudeai"],
            environment: environment,
            captureStandardError: true,
            timeout: .seconds(20)
        )
        let staged = await ClaudeCredentialStore.readDocument(configDirectory: scratch.path)?.oauth
        await ClaudeCredentialStore.deleteManagedItem(configDirectory: scratch.path)
        try? FileManager.default.removeItem(at: scratch)

        if let staged, Self.isCompleteRotation(staged, replacing: previousAccessToken) {
            return .renewed(staged)
        }
        // HTTP 400 alone does not prove the grant was revoked; only invalid_grant does.
        let errorText = String(decoding: output?.stderr ?? Data(), as: UTF8.self).lowercased()
        return .failed(loginRequired: errorText.contains("invalid_grant"))
    }

    static func isCompleteRotation(_ oauth: JSONValue, replacing previousAccessToken: String) -> Bool {
        guard let accessToken = oauth["accessToken"]?.string, !accessToken.isEmpty, accessToken != previousAccessToken,
              let refreshToken = oauth["refreshToken"]?.string, !refreshToken.isEmpty,
              let expiresAt = oauth["expiresAt"]?.double, expiresAt / 1000 > Date.now.timeIntervalSince1970,
              let scopes = oauth["scopes"]?.array, !scopes.isEmpty else { return false }
        return true
    }

    private func readEmail() async -> String? {
        guard let executable = try? await locateExecutable(),
              let output = try? await ClaudeProcessRunner.run(
                  executable,
                  arguments: ["auth", "status", "--json"],
                  environment: childEnvironment(executable: executable, configDirectory: configDirectory),
                  timeout: .seconds(20)
              ), output.status == 0,
              let status = try? JSONDecoder().decode(JSONValue.self, from: output.stdout) else { return nil }
        return status["email"]?.string
    }

    private func fetchUsage(accessToken: String) async throws -> JSONValue {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexBarError.malformedResponse }
        switch http.statusCode {
        case 200..<300:
            guard let usage = try? JSONDecoder().decode(JSONValue.self, from: data), usage.object != nil else {
                throw CodexBarError.malformedResponse
            }
            return usage
        case 401:
            throw UsageFailure.unauthorized
        case 429:
            throw UsageFailure.rateLimited(retryAfter: Self.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            // 403 means a scope or organisation policy problem, which signing in again would not fix.
            throw CodexBarError.server("usage request failed with HTTP \(http.statusCode)")
        }
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfterSeconds(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func childEnvironment(executable: URL, configDirectory: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let configDirectory {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        } else {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        // Each of these would redirect the CLI to a different Keychain item or credential, or
        // mark the child as nested inside another Claude Code session.
        for key in [
            "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
            "CLAUDE_CODE_OAUTH_SCOPES",
            "CLAUDE_CODE_OAUTH_CLIENT_ID",
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["FORCE_HYPERLINK"] = "0"
        // GUI apps start with a minimal PATH; an npm-installed Claude Code needs node on it.
        let searchPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (searchPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    private func currentAuthorizationURL() -> URL? {
        ClaudeUsageMapper.authorizationURL(in: loginOutputText)
    }

    private func receiveLoginOutput(_ data: Data, loginID: String) {
        guard loginID == activeLoginID else { return }
        // Keep only what is needed to find the fallback URL.
        loginOutputText = String((loginOutputText + String(decoding: data, as: UTF8.self)).suffix(8_192))
    }

    private func loginProcessDidExit(status: Int32, loginID: String) {
        guard loginID == activeLoginID else { return }
        loginExitStatus = status
        loginOutput?.fileHandleForReading.readabilityHandler = nil
        loginProcess = nil
        loginInput = nil
        loginOutput = nil
        guard let waiter = loginWaiter else { return }
        loginWaiter = nil
        waiter.resume(with: Result { try finishedLoginResult() })
    }

    private func finishedLoginResult() throws {
        if loginWasCancelled { throw CancellationError() }
        guard loginExitStatus == 0 else { throw CodexBarError.authenticationRequired }
    }

    private func timeoutLogin(loginID: String) {
        guard loginID == activeLoginID, loginExitStatus == nil else { return }
        terminateLogin()
    }

    private func terminateLogin() {
        if let process = loginProcess?.process, process.isRunning { process.terminate() }
    }

    /// Ends any login still owned by this client so its waiter and pipes cannot leak.
    private func abandonActiveLogin() {
        terminateLogin()
        loginOutput?.fileHandleForReading.readabilityHandler = nil
        loginProcess = nil
        loginInput = nil
        loginOutput = nil
        activeLoginID = nil
        if let waiter = loginWaiter {
            loginWaiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }
}
