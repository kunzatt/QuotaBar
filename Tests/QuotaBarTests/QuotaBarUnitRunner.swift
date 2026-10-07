import Foundation
import Darwin

@main
struct QuotaBarUnitRunner {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("initialize response decoding", testInitializeResponse),
            ("notification between responses", testNotification),
            ("rate limit mapping", testRateLimitMapping),
            ("shortest quota window selection", testShortestQuotaWindowSelection),
            ("null-heavy payload", testNullPayload),
            ("Int64 token usage", testTokenUsage),
            ("malformed JSONL recovery", testMalformedJSONL),
            ("authentication error classification", testAuthenticationErrorClassification),
            ("duration and clamp", testDurationAndClamp),
            ("Codex plan recognition", testCodexPlanRecognition),
            ("Plus five-hour window availability", testPlusFiveHourWindowAvailability),
            ("latest daily token bucket", testLatestDailyTokenBucket),
            ("polling backoff", testPollingBackoff),
            ("repository persistence", testRepositoryPersistence),
            ("CodexBar data migration", testLegacyStorageMigration),
            ("profile provider decoding", testProfileProviderDecoding),
            ("managed Claude profile lifecycle", testManagedClaudeProfileLifecycle),
            ("Claude usage mapping", testClaudeUsageMapping),
            ("Claude legacy usage mapping", testClaudeLegacyUsageMapping),
            ("Claude Retry-After parsing", testClaudeRetryAfterParsing),
            ("Claude scratch-profile renewal", testClaudeScratchRenewal),
            ("Claude keychain service naming", testClaudeKeychainServiceNaming),
            ("Claude credential parsing", testClaudeCredentialParsing),
            ("Claude login URL extraction", testClaudeAuthorizationURLExtraction),
            ("Claude process runner bounds", testClaudeProcessRunnerBounds),
            ("log redaction", testRedaction)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS  \(name)")
            } catch {
                failures += 1
                print("FAIL  \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) unit tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testInitializeResponse() throws {
        let data = #"{"id":1,"result":{"serverInfo":{"name":"codex"}}}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONLMessage.self, from: data)
        try expect(message.id?.integerValue == 1, "request ID")
        try expect(message.result?["serverInfo"]?["name"]?.string == "codex", "result object")
        try expect(message.method == nil, "must not be a notification")
    }

    private static func testNotification() throws {
        let data = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":42}}}}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONLMessage.self, from: data)
        try expect(message.id == nil, "notification has no id")
        try expect(message.method == "account/rateLimits/updated", "notification method")
    }

    private static func testRateLimitMapping() throws {
        let value = try decode(#"""
        {"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitName":"Codex 기본","primary":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":1785024014},"secondary":{"usedPercent":15,"windowDurationMins":300,"resetsAt":1784700000}},"fast":{"limitId":"fast","primary":{"usedPercent":120,"windowDurationMins":60}}}}
        """#)
        let buckets = ProtocolMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 2, "all buckets")
        try expect(buckets.first?.limitId == "codex", "codex first")
        try expect(buckets.first?.primary?.remainingPercent == 41, "primary remaining")
        try expect(buckets.first?.secondary?.remainingPercent == 85, "secondary remaining")
        try expect(buckets.last?.primary?.remainingPercent == 0, "clamp usedPercent")
    }

    private static func testNullPayload() throws {
        let value = try decode(#"{"rateLimits":{"limitId":null,"limitName":null,"primary":null,"secondary":null,"credits":null}}"#)
        let buckets = ProtocolMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 1, "fallback bucket")
        try expect(buckets[0].limitId == "codex", "safe fallback id")
        try expect(buckets[0].primary == nil, "null window")
    }

    private static func testShortestQuotaWindowSelection() throws {
        let bucket = RateLimitBucket(
            limitId: "codex",
            displayName: "Codex",
            primary: RateLimitWindow(usedPercent: 59, windowDurationMinutes: 10_080),
            secondary: RateLimitWindow(usedPercent: 15, windowDurationMinutes: 300),
            hasCredits: nil,
            unlimitedCredits: nil,
            creditBalance: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
        let snapshot = AccountUsageSnapshot(accountID: UUID(), rateLimitBuckets: [bucket])
        try expect(snapshot.activeCodexWindow?.windowDurationMinutes == 300, "five-hour window wins")
        try expect(snapshot.remainingPercent == 85, "status uses five-hour remaining")
    }

    private static func testTokenUsage() throws {
        let value = try decode(#"{"summary":{"lifetimeTokens":9000000000000000000,"peakDailyTokens":1234567,"currentStreakDays":10},"dailyUsageBuckets":[{"startDate":"2026-07-20","tokens":12345}]}"#)
        let usage = ProtocolMapper.tokenSummary(from: value)
        try expect(usage.lifetimeTokens == 9_000_000_000_000_000_000, "Int64 lifetime")
        try expect(usage.dailyBuckets == [DailyTokenUsage(startDate: "2026-07-20", tokens: 12_345)], "daily bucket")
    }

    private static func testMalformedJSONL() throws {
        var buffer = JSONLLineBuffer()
        let messages = buffer.append(Data("{bad json}\n{\"id\":2,\"result\":{}}\n".utf8))
        try expect(messages.count == 1, "must skip one malformed line")
        try expect(messages.first?.id?.integerValue == 2, "valid later response survives")
    }

    private static func testAuthenticationErrorClassification() throws {
        try expect(
            CodexAppServerClient.isExplicitAuthenticationFailure(ServerErrorPayload(code: 401, message: nil)),
            "HTTP unauthorized is authentication required"
        )
        try expect(
            CodexAppServerClient.isExplicitAuthenticationFailure(ServerErrorPayload(code: nil, message: "Authentication required")),
            "explicit authentication message is authentication required"
        )
        try expect(
            !CodexAppServerClient.isExplicitAuthenticationFailure(ServerErrorPayload(code: nil, message: "Unable to refresh auth metadata")),
            "generic auth wording must remain a retryable error"
        )
        try expect(
            !CodexAppServerClient.isExplicitAuthenticationFailure(ServerErrorPayload(code: nil, message: "Login request timed out")),
            "generic login wording must remain a retryable error"
        )
    }

    private static func testDurationAndClamp() throws {
        try expect(RateLimitWindow(usedPercent: -20).remainingPercent == 100, "lower clamp")
        try expect(RateLimitWindow(usedPercent: 150).remainingPercent == 0, "upper clamp")
        try expect(QuotaBarFormatters.windowText(300) == "5시간", "five hours")
        try expect(QuotaBarFormatters.windowText(10_080) == "1주", "one week")
        try expect(QuotaBarFormatters.windowText(73) == "73분", "arbitrary duration")
    }

    private static func testCodexPlanRecognition() throws {
        let plus = ProtocolMapper.accountIdentity(from: try decode(#"{"account":{"planType":"plus"}}"#))
        try expect(plus.planName == "Plus", "plus from app-server")
        try expect(plus.isPlus, "plus flag")
        try expect(AccountIdentity(loginType: "chatgpt", email: nil, planType: "pro").planName == "Pro", "pro")
        try expect(AccountIdentity(loginType: "chatgpt", email: nil, planType: "prolite").planName == "Pro Lite", "prolite")
        try expect(AccountIdentity(loginType: "chatgpt", email: nil, planType: "future-plan").planName == "future-plan", "unknown plan remains visible")
    }

    private static func testPlusFiveHourWindowAvailability() throws {
        let plus = AccountIdentity(loginType: "chatgpt", email: nil, planType: " Plus ")
        let weeklyOnly = RateLimitBucket(
            limitId: "codex",
            displayName: "Codex",
            primary: RateLimitWindow(usedPercent: 31, windowDurationMinutes: 10_080),
            secondary: nil,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditBalance: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: nil
        )
        let weeklyAndFiveHour = RateLimitBucket(
            limitId: "codex",
            displayName: "Codex",
            primary: weeklyOnly.primary,
            secondary: RateLimitWindow(usedPercent: 12, windowDurationMinutes: 300),
            hasCredits: nil,
            unlimitedCredits: nil,
            creditBalance: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: nil
        )

        let missing = AccountUsageSnapshot(accountID: UUID(), identity: plus, rateLimitBuckets: [weeklyOnly])
        try expect(missing.isPlusFiveHourWindowMissing, "plus weekly-only response is explicit")

        let present = AccountUsageSnapshot(accountID: UUID(), identity: plus, rateLimitBuckets: [weeklyAndFiveHour])
        try expect(!present.isPlusFiveHourWindowMissing, "five-hour response is not flagged")

        let pro = AccountUsageSnapshot(
            accountID: UUID(),
            identity: AccountIdentity(loginType: "chatgpt", email: nil, planType: "pro"),
            rateLimitBuckets: [weeklyOnly]
        )
        try expect(!pro.isPlusFiveHourWindowMissing, "non-Plus response is not flagged")

        let unrelatedBucket = RateLimitBucket(
            limitId: "codex_bengalfox",
            displayName: "Spark",
            primary: weeklyOnly.primary,
            secondary: nil,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditBalance: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: nil
        )
        let unrelated = AccountUsageSnapshot(accountID: UUID(), identity: plus, rateLimitBuckets: [unrelatedBucket])
        try expect(!unrelated.isPlusFiveHourWindowMissing, "unrelated bucket is not flagged")
    }

    private static func testLatestDailyTokenBucket() throws {
        let summary = TokenUsageSummary(
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            dailyBuckets: [
                DailyTokenUsage(startDate: "2026-09-08", tokens: 200),
                DailyTokenUsage(startDate: "2026-09-09", tokens: 138),
                DailyTokenUsage(startDate: "2026-09-07", tokens: 300)
            ]
        )
        try expect(summary.latestDailyBucket?.startDate == "2026-09-09", "latest bucket is date-based")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        try expect(
            QuotaBarFormatters.dailyUsageLabel(for: "2026-09-09", now: now, calendar: calendar) == "오늘",
            "today label"
        )
        try expect(
            QuotaBarFormatters.dailyUsageLabel(for: "2026-09-08", now: now, calendar: calendar) == "최근 일 · 2026-09-08",
            "historical bucket label"
        )
    }

    private static func testPollingBackoff() throws {
        try expect(PollingPolicy.delay(forConsecutiveFailures: 0) == 30, "normal")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 1) == 60, "first failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 2) == 120, "second failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 3) == 300, "max failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 0) == 30, "successful reset")
    }

    private static func testRepositoryPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AccountRepository(rootURL: root)
        try await repository.bootstrap()
        let first = AccountProfile(alias: "첫 계정", codexHomePath: root.appendingPathComponent("first"), isManagedByApp: true)
        let second = AccountProfile(alias: "둘째 계정", codexHomePath: root.appendingPathComponent("second"), isManagedByApp: true)
        _ = try await repository.save(QuotaBarPreferences(profiles: [first, second], primaryAccountID: second.id))
        let reloaded = AccountRepository(rootURL: root)
        try await reloaded.bootstrap()
        let preferences = await reloaded.currentPreferences()
        try expect(preferences.primaryAccountID == second.id, "primary persistence")
    }

    private static func testLegacyStorageMigration() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("CodexBar", isDirectory: true)
        let root = base.appendingPathComponent("QuotaBar", isDirectory: true)
        let legacyRepository = AccountRepository(rootURL: legacy)
        try await legacyRepository.bootstrap()
        let managed = try ProfileManager.createManagedProfile(alias: "관리", provider: .codex, repositoryRoot: legacy)
        try Data("{}".utf8).write(to: managed.codexHomePath.appendingPathComponent("auth.json"))
        let external = ProfileManager.defaultProfile(alias: "기본", provider: .codex)
        _ = try await legacyRepository.save(QuotaBarPreferences(profiles: [managed, external], primaryAccountID: managed.id, launchAtLogin: true))

        let repository = AccountRepository(rootURL: root, legacyRootURL: legacy)
        try await repository.bootstrap()
        let preferences = await repository.currentPreferences()
        try expect(!FileManager.default.fileExists(atPath: legacy.path), "legacy folder moved")
        try expect(preferences.primaryAccountID == managed.id && preferences.launchAtLogin, "settings carried over")
        let movedHome = preferences.profiles.first { $0.id == managed.id }?.codexHomePath
        try expect(movedHome?.path.hasPrefix(root.path + "/") == true, "managed path rewritten")
        try expect(FileManager.default.fileExists(atPath: movedHome?.appendingPathComponent("auth.json").path ?? ""), "profile files moved")
        try expect(preferences.profiles.first { $0.id == external.id }?.codexHomePath == external.codexHomePath, "external path untouched")
        if let moved = preferences.profiles.first(where: { $0.id == managed.id }) {
            try ProfileManager.removeManagedProfile(moved, repositoryRoot: root)
        }

        // Once QuotaBar exists, a leftover CodexBar folder is left alone.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try await AccountRepository(rootURL: root, legacyRootURL: legacy).bootstrap()
        try expect(FileManager.default.fileExists(atPath: legacy.path), "no second migration")
    }

    private static func testProfileProviderDecoding() throws {
        let legacy = #"""
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"이전 계정","codexHomePath":"file:///tmp/codex-home/","isManagedByApp":true,"isEnabled":true,"createdAt":"2026-09-01T00:00:00Z"}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(AccountProfile.self, from: Data(legacy.utf8))
        try expect(profile.provider == .codex, "profiles saved before Claude support stay Codex")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let claude = AccountProfile(
            alias: "Claude",
            codexHomePath: URL(fileURLWithPath: "/tmp/claude-home"),
            isManagedByApp: true,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            provider: .claude
        )
        let roundTrip = try decoder.decode(AccountProfile.self, from: encoder.encode(claude))
        try expect(roundTrip == claude, "Claude profile round-trip")
    }

    private static func testManagedClaudeProfileLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ProfileManager.createManagedProfile(alias: " 회사 Max ", provider: .claude, repositoryRoot: root)
        try expect(profile.provider == .claude, "provider")
        try expect(profile.alias == "회사 Max", "alias trimmed")
        try expect(profile.codexHomePath.lastPathComponent == "claude-home", "Claude config directory")
        try expect(!FileManager.default.fileExists(atPath: profile.codexHomePath.appendingPathComponent("config.toml").path), "no Codex config")
        try expect(ClaudeProfilePaths.configDirectoryEnvironment(for: profile) == profile.codexHomePath.path, "managed profile sets CLAUDE_CONFIG_DIR")

        let external = ProfileManager.defaultProfile(alias: "기본 Claude", provider: .claude)
        try expect(ClaudeProfilePaths.configDirectoryEnvironment(for: external) == nil, "default ~/.claude leaves CLAUDE_CONFIG_DIR unset")

        let mismatched = AccountProfile(
            id: profile.id,
            alias: profile.alias,
            codexHomePath: profile.codexHomePath.deletingLastPathComponent().appendingPathComponent("codex-home"),
            isManagedByApp: true,
            provider: .claude
        )
        var rejected = false
        do { try ProfileManager.removeManagedProfile(mismatched, repositoryRoot: root) } catch { rejected = true }
        try expect(rejected, "Claude profile must point at claude-home before deletion")

        try ProfileManager.removeManagedProfile(profile, repositoryRoot: root)
        try expect(!FileManager.default.fileExists(atPath: profile.codexHomePath.deletingLastPathComponent().path), "account folder removed")
    }

    private static func testClaudeUsageMapping() throws {
        // Shape returned by api.anthropic.com/api/oauth/usage on 2026-10-07.
        let value = try decode(#"""
        {"five_hour":{"utilization":99.0,"resets_at":"2026-10-07T02:20:00.103257+00:00"},
         "seven_day":{"utilization":99.0,"resets_at":"2026-10-12T11:00:00+00:00"},
         "seven_day_opus":null,
         "limits":[
          {"kind":"session","group":"session","percent":38,"resets_at":"2026-10-07T02:20:00.103257+00:00","scope":null},
          {"kind":"weekly_all","group":"weekly","percent":32,"resets_at":"2026-10-12T11:00:00.103276+00:00","scope":null},
          {"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"2026-10-12T11:00:00+00:00","scope":{"model":{"id":null,"display_name":"Opus"}}},
          {"kind":"monthly_spend","group":"spend","percent":50,"scope":null},
          {"kind":"weekly_scoped","group":"weekly","percent":null,"scope":{"model":{"display_name":"Sonnet"}}}
         ]}
        """#)
        let buckets = ClaudeUsageMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 2, "main and one scoped bucket; unknown kinds and null percents skipped")
        let main = buckets[0]
        try expect(main.limitId == "claude", "main bucket first")
        try expect(main.primary?.remainingPercent == 62, "session from limits wins over five_hour")
        try expect(main.primary?.windowDurationMinutes == 300, "five-hour duration")
        try expect(main.secondary?.remainingPercent == 68, "weekly from limits")
        try expect(main.shortestWindow == main.primary, "five-hour window is the active one")
        let fractionalReset = main.primary?.resetsAt?.timeIntervalSince1970 ?? 0
        try expect(abs(fractionalReset - 1_791_339_600.103257) < 0.001, "fractional reset time")
        try expect(buckets[1].limitId == "claude_weekly_opus", "scoped id")
        try expect(buckets[1].displayName == "Opus 주간" && buckets[1].primary?.remainingPercent == 88, "scoped weekly bucket")
        try expect(buckets[1].primary?.resetsAt == Date(timeIntervalSince1970: 1_791_802_800), "whole-second reset time")

        let snapshot = AccountUsageSnapshot(accountID: UUID(), rateLimitBuckets: buckets)
        try expect(snapshot.remainingPercent == 62, "menu bar shows the five-hour remainder")

        let empty = ClaudeUsageMapper.rateLimitBuckets(from: try decode(#"{"five_hour":null,"seven_day":null,"limits":[]}"#))
        try expect(empty.isEmpty, "null windows produce no bucket")
    }

    private static func testClaudeLegacyUsageMapping() throws {
        let value = try decode(#"""
        {"five_hour":{"utilization":40.0,"resets_at":"2026-10-07T02:20:00+00:00"},
         "seven_day":{"utilization":10.0,"resets_at":"2026-10-12T11:00:00+00:00"},
         "seven_day_opus":{"utilization":25.0,"resets_at":"2026-10-12T11:00:00+00:00"},
         "seven_day_oauth_apps":null}
        """#)
        let buckets = ClaudeUsageMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 2, "named windows without limits")
        try expect(buckets[0].primary?.remainingPercent == 60 && buckets[0].secondary?.remainingPercent == 90, "main windows")
        try expect(buckets[1].displayName == "Opus 주간" && buckets[1].primary?.remainingPercent == 75, "named scoped window")
    }

    private static func testClaudeRetryAfterParsing() throws {
        let now = Date(timeIntervalSince1970: 1_791_331_200)
        try expect(ClaudeUsageClient.retryAfterSeconds("120", now: now) == 120, "seconds")
        try expect(ClaudeUsageClient.retryAfterSeconds("Wed, 07 Oct 2026 00:10:00 GMT", now: now) == 600, "HTTP date")
        try expect(ClaudeUsageClient.retryAfterSeconds(nil, now: now) == nil, "absent")
        try expect(ClaudeUsageClient.retryAfterSeconds("soon", now: now) == nil, "garbage")
    }

    /// Exercises the scratch-profile renewal against a stand-in CLI and file-backed
    /// credentials, so no real login or Keychain item is involved.
    private static func testClaudeScratchRenewal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ProfileManager.createManagedProfile(alias: "renewal", provider: .claude, repositoryRoot: root)
        let live = profile.codexHomePath.appendingPathComponent(".credentials.json")
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fakeCLI = tools.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        dir=$(dirname "$0")
        echo call >> "$dir/calls"
        [ "$1 $2 $3" = "auth login --claudeai" ] || exit 9
        [ "$BROWSER" = "false" ] || exit 8
        [ "$CLAUDE_CODE_OAUTH_SCOPES" = "user:inference user:profile" ] || exit 7
        case "$CLAUDE_CONFIG_DIR" in */ClaudeRenewal/*) ;; *) exit 6 ;; esac
        case "$(cat "$dir/mode")" in
          success)
            [ "$CLAUDE_CODE_OAUTH_REFRESH_TOKEN" = "refresh-old" ] || exit 5
            expires=$(( ($(date +%s) + 28800) * 1000 ))
            printf '{"claudeAiOauth":{"accessToken":"access-new","refreshToken":"refresh-new","expiresAt":%s,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}' "$expires" > "$CLAUDE_CONFIG_DIR/.credentials.json"
            exit 0 ;;
          revoked) echo 'Login failed: {"error":"invalid_grant"}' >&2; exit 1 ;;
          *) echo 'Login failed: Request failed with status code 400' >&2; exit 1 ;;
        esac
        """#.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)

        func writeLive(accessToken: String, expiresIn seconds: TimeInterval) throws {
            let expires = Int64((Date.now.timeIntervalSince1970 + seconds) * 1000)
            let document = #"{"mcpOAuth":{"server":{"accessToken":"mcp"}},"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"refresh-old","expiresAt":\#(expires),"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
            try Data(document.utf8).write(to: live)
        }
        func setMode(_ mode: String) throws { try Data(mode.utf8).write(to: tools.appendingPathComponent("mode")) }
        func calls() -> Int {
            (try? String(contentsOf: tools.appendingPathComponent("calls"), encoding: .utf8))?.split(separator: "\n").count ?? 0
        }
        func liveValue() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: live)) }

        // A valid token is returned as is.
        try writeLive(accessToken: "access-old", expiresIn: 3_600)
        try setMode("success")
        let fresh = ClaudeUsageClient(profile: profile, executableURL: fakeCLI)
        let scratchBefore = (try? FileManager.default.contentsOfDirectory(atPath: ClaudeProfilePaths.renewalRoot.path)) ?? []
        let untouched = try await fresh.usableCredentials(rejecting: nil)
        try expect(untouched.accessToken == "access-old", "valid token untouched")
        try expect(calls() == 0, "no renewal for a valid token")

        // An expired token is renewed in a scratch profile and written back.
        try writeLive(accessToken: "access-old", expiresIn: -60)
        let renewed = try await fresh.usableCredentials(rejecting: nil)
        try expect(renewed.accessToken == "access-new", "renewed token returned")
        let written = try liveValue()
        try expect(written["claudeAiOauth"]?["refreshToken"]?.string == "refresh-new", "rotation written back")
        try expect(written["claudeAiOauth"]?["rateLimitTier"]?.string == "default_claude_max_20x", "other OAuth fields kept")
        try expect(written["mcpOAuth"]?["server"]?["accessToken"]?.string == "mcp", "rest of the document kept")
        let scratchAfter = (try? FileManager.default.contentsOfDirectory(atPath: ClaudeProfilePaths.renewalRoot.path)) ?? []
        try expect(Set(scratchAfter) == Set(scratchBefore), "scratch profile removed")

        // A rejected but unexpired token is renewed too.
        try writeLive(accessToken: "access-old", expiresIn: 3_600)
        let afterRejection = try await ClaudeUsageClient(profile: profile, executableURL: fakeCLI).usableCredentials(rejecting: "access-old")
        try expect(afterRejection.accessToken == "access-new", "rejected token renewed")

        // A transient failure keeps the live login and backs off.
        try writeLive(accessToken: "access-old", expiresIn: -60)
        let before = try Data(contentsOf: live)
        try setMode("transient")
        let transient = ClaudeUsageClient(profile: profile, executableURL: fakeCLI)
        let callsBefore = calls()
        do {
            _ = try await transient.usableCredentials(rejecting: nil)
            throw TestFailure("transient failure must throw")
        } catch let error as QuotaBarError {
            try expect(error == .claudeTokenRenewalFailed, "transient failure is not a sign-out")
        }
        let afterTransient = try Data(contentsOf: live)
        try expect(afterTransient == before, "live credentials untouched on failure")
        do { _ = try await transient.usableCredentials(rejecting: nil) } catch {}
        try expect(calls() == callsBefore + 1, "backoff skips an immediate second attempt")

        // A revoked grant asks for sign-in and still keeps the live document.
        try setMode("revoked")
        do {
            _ = try await ClaudeUsageClient(profile: profile, executableURL: fakeCLI).usableCredentials(rejecting: nil)
            throw TestFailure("revoked grant must throw")
        } catch let error as QuotaBarError {
            try expect(error == .authenticationRequired, "invalid_grant needs sign-in")
        }
        let afterRevoked = try Data(contentsOf: live)
        try expect(afterRevoked == before, "live credentials untouched when revoked")

        let expiredRotation = try decode(#"{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["s"]}"#)
        try expect(!ClaudeUsageClient.isCompleteRotation(expiredRotation, replacing: "x"), "expired rotation rejected")
    }

    private static func testClaudeKeychainServiceNaming() throws {
        try expect(ClaudeCredentialStore.keychainService(configDirectory: nil) == "Claude Code-credentials", "default login")
        // Observed from Claude Code 2.1.280: CLAUDE_CONFIG_DIR=/Users/apple/.claude uses this item.
        try expect(
            ClaudeCredentialStore.keychainService(configDirectory: "/Users/apple/.claude") == "Claude Code-credentials-dfd91f6e",
            "configured directory suffix"
        )
        // Claude Code hashes the NFC form, so a decomposed path must name the same item.
        try expect(
            ClaudeCredentialStore.keychainService(configDirectory: "/tmp/cafe\u{301}") ==
                ClaudeCredentialStore.keychainService(configDirectory: "/tmp/caf\u{E9}"),
            "NFC normalization"
        )
    }

    private static func testClaudeCredentialParsing() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":1790000000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        guard let credentials = ClaudeCredentialStore.parse(Data(json.utf8)) else { throw TestFailure("credentials parse") }
        try expect(credentials.hasRefreshToken, "refresh token present")
        try expect(credentials.planType == "max_20x", "Max tier")
        try expect(AccountIdentity(loginType: "claude.ai", email: nil, planType: credentials.planType).planName == "Max 20x", "plan label")
        try expect(credentials.isUsable(at: Date(timeIntervalSince1970: 1_789_990_000)), "valid before expiry")
        try expect(!credentials.isUsable(at: Date(timeIntervalSince1970: 1_789_999_990)), "expiring token is refreshed first")

        let loggedOut = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        guard let cleared = ClaudeCredentialStore.parse(Data(loggedOut.utf8)) else { throw TestFailure("cleared parse") }
        try expect(!cleared.isUsable(at: .now) && !cleared.hasRefreshToken, "cleared login needs sign-in")
        try expect(ClaudeCredentialStore.parse(Data("not json".utf8)) == nil, "garbage ignored")

        let pro = ClaudeOAuthCredentials(accessToken: "t", hasRefreshToken: true, expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil)
        try expect(pro.planType == "pro", "Pro plan")
    }

    private static func testClaudeAuthorizationURLExtraction() throws {
        let url = "https://claude.com/cai/oauth/authorize?code=true&state=XYZ"
        let plain = "Opening browser to sign in…\nIf the browser didn't open, visit: \(url)\nPaste code here if prompted > "
        try expect(ClaudeUsageMapper.authorizationURL(in: plain)?.absoluteString == url, "plain output")

        let colored = "visit: \u{1B}[36m\(url)\u{1B}[39m\n"
        try expect(ClaudeUsageMapper.authorizationURL(in: colored)?.absoluteString == url, "colour codes")

        let hyperlinkBEL = "visit: \u{1B}]8;;\(url)\u{07}\(url)\u{1B}]8;;\u{07}\n"
        try expect(ClaudeUsageMapper.authorizationURL(in: hyperlinkBEL)?.absoluteString == url, "OSC 8 hyperlink with BEL")

        let hyperlinkST = "visit: \u{1B}]8;;\(url)\u{1B}\\\(url)\u{1B}]8;;\u{1B}\\\n"
        try expect(ClaudeUsageMapper.authorizationURL(in: hyperlinkST)?.absoluteString == url, "OSC 8 hyperlink with ST")

        try expect(ClaudeUsageMapper.authorizationURL(in: "Opening browser to sign in…") == nil, "no URL yet")
    }

    private static func testClaudeProcessRunnerBounds() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let environment = ProcessInfo.processInfo.environment

        let large = try await ClaudeProcessRunner.run(
            shell,
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a"],
            environment: environment,
            timeout: .seconds(10)
        )
        try expect(large.status == 0 && large.stdout.count == 200_000, "output larger than a pipe buffer is drained")

        let stubbornStart = Date()
        let stubborn = try await ClaudeProcessRunner.run(
            shell,
            arguments: ["-c", "trap '' TERM; sleep 20"],
            environment: environment,
            timeout: .seconds(1)
        )
        try expect(Date().timeIntervalSince(stubbornStart) < 10, "SIGTERM-ignoring child is killed")
        try expect(stubborn.status != 0, "killed child is not a success")

        let inheritedStart = Date()
        let inherited = try await ClaudeProcessRunner.run(
            shell,
            arguments: ["-c", "sleep 6 & echo hi"],
            environment: environment,
            timeout: .seconds(10)
        )
        try expect(Date().timeIntervalSince(inheritedStart) < 5, "grandchild holding stdout does not block the result")
        try expect(String(decoding: inherited.stdout, as: UTF8.self) == "hi\n", "output before exit is kept")
    }

    private static func testRedaction() throws {
        let redacted = RedactingLogger.redact("user@example.com opened https://example.com/login?token=secret")
        try expect(!redacted.contains("user@example.com"), "email must not remain")
        try expect(!redacted.contains("token=secret"), "query must not remain")
    }

    private static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
