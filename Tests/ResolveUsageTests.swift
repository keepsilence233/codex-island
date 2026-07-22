import Foundation

/// Regression tests for ClaudeCredentials.resolveUsage, run by
/// scripts/run-tests.sh (no XCTest — the app builds with bare swiftc, so the
/// harness does too). The runner sets CLAUDE_CODE_OAUTH_TOKEN to a stub value
/// so the env-token path drives the injected probe deterministically on any
/// machine, with or without a real "Claude Code-credentials" keychain item.
///
/// Why the rate-limited case is locked down (issue #35): Anthropic's
/// /api/oauth/usage limiter is account-keyed and sticky once tripped
/// (anthropics/claude-code#30930). resolveUsage must short-circuit on the
/// first rate-limited probe — if a regression reintroduces the old
/// fall-through, every poll cycle re-probes against a throttled account.
@main
struct ResolveUsageTests {
    final class ProbeCounter {
        var calls = 0
    }

    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func main() async {
        guard ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "test-stub-token" else {
            print("FAIL harness must run via scripts/run-tests.sh (env token stub missing)")
            exit(1)
        }

        // Hermetic credential sources: stub the keychain providers and pin
        // CLAUDE_CONFIG_DIR at an empty fixture dir, so no code path (incl.
        // the 401 re-read/retry) ever touches the developer's real keychain
        // or ~/.claude — a real read would pop the ACL prompt on every test
        // run and make results depend on the machine's login state.
        let emptyConfigDir = NSTemporaryDirectory() + "codexisland-tests-empty-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: emptyConfigDir, withIntermediateDirectories: true)
        setenv("CLAUDE_CONFIG_DIR", emptyConfigDir, 1)
        ClaudeCredentials.keychainCandidatesProvider = { [] }
        ClaudeCredentials.keychainModificationDatesProvider = { [] }

        // Prime the creds cache so T1/T2 drive the injected probe from a
        // known token without any store read.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "test-stub", accessToken: "stub-keychain-token", subscriptionType: nil)

        // T1 — a rate-limited probe short-circuits the whole resolution:
        // exactly one probe (no fallback to the next token source) and the
        // exact error string the UI and UsageStore cooldown match on.
        let t1 = ProbeCounter()
        let r1 = await ClaudeCredentials.resolveUsage { _, _ in
            t1.calls += 1
            return .rateLimited
        }
        if case .failed(let msg) = r1 {
            expect(msg == ClaudeCredentials.rateLimitedMessage, "T1 resolution is .failed(rateLimitedMessage)")
        } else {
            expect(false, "T1 resolution is .failed(rateLimitedMessage)")
        }
        expect(t1.calls == 1, "T1 probes exactly once (got \(t1.calls))")

        // T2 — a successful probe passes usage through untouched.
        let t2 = ProbeCounter()
        let fetched = AppUsage(
            fiveHour: WindowUsage(usedPercent: 0.13, resetAt: nil, error: nil),
            weekly: WindowUsage(usedPercent: 0.14, resetAt: nil, error: nil)
        )
        let r2 = await ClaudeCredentials.resolveUsage { _, _ in
            t2.calls += 1
            return .success(fetched)
        }
        if case .usage(let u) = r2 {
            expect(u.fiveHour.usedPercent == 0.13 && u.weekly.usedPercent == 0.14, "T2 usage passes through")
        } else {
            expect(false, "T2 usage passes through")
        }
        expect(t2.calls == 1, "T2 probes exactly once (got \(t2.calls))")

        // T3 — multi-item keychain selection. Claude Code writes several items
        // under one service name; a stray acct="unknown" item holds only
        // mcpOAuth. Selection must skip it (and any logged-out empty-token
        // item) and pick the item that actually carries claudeAiOauth.
        let candidates = [
            ClaudeCredentials.KeychainCandidate(account: "unknown", blob: ["mcpOAuth": ["server": "x"]]),
            ClaudeCredentials.KeychainCandidate(account: "loggedout", blob: ["claudeAiOauth": ["accessToken": "", "refreshToken": ""]]),
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "mcpOAuth": ["server": "x"],
                "claudeAiOauth": ["accessToken": "at", "refreshToken": "rt", "subscriptionType": "max"],
            ]),
        ]
        let picked = ClaudeCredentials.selectClaudeCreds(from: candidates)
        expect(picked?.account == "ericpark", "T3 selects the claudeAiOauth item, not the mcpOAuth/empty ones")
        expect(picked?.subscriptionType == "max", "T3 carries subscriptionType from the picked item")
        expect(ClaudeCredentials.selectClaudeCreds(from: [
            ClaudeCredentials.KeychainCandidate(account: "unknown", blob: ["mcpOAuth": [:]]),
        ]) == nil, "T3 returns nil when no item carries claudeAiOauth")

        // T4 — an unauthorized keychain-token probe must clear the creds
        // cache, or a token Claude Code rotated externally stays stale in
        // the cache forever and the chip never recovers past "token expired".
        // Priming the cache short-circuits the real keychain read, keeping
        // this deterministic on any machine.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "primed", accessToken: "stale-token", subscriptionType: "max")
        let t4 = ProbeCounter()
        let r4 = await ClaudeCredentials.resolveUsage { _, _ in
            t4.calls += 1
            return .unauthorized
        }
        // Env stub token probes first (unauthorized → falls through), then
        // the primed keychain creds probe (unauthorized → clears cache).
        expect(t4.calls == 2, "T4 probes env then cached keychain token (got \(t4.calls))")
        expect(ClaudeCredentials.cachedClaudeCreds == nil, "T4 unauthorized keychain probe clears the creds cache")
        if case .failed(let msg) = r4 {
            expect(msg == ClaudeCredentials.tokenExpiredMessage, "T4 resolution is .failed(tokenExpiredMessage)")
        } else {
            expect(false, "T4 resolution is .failed(tokenExpiredMessage)")
        }
        ClaudeCredentials.clearCache()

        // T5 — file credential store (issue #54). Users who migrated to
        // ~/.claude/.credentials.json and deleted the keychain item must
        // still get usage. Point CLAUDE_CONFIG_DIR at a fixture and assert
        // the decoded candidate feeds the same selection as keychain items.
        let fixtureDir = NSTemporaryDirectory() + "codexisland-tests-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: fixtureDir, withIntermediateDirectories: true)
        let fixture = """
        {"claudeAiOauth": {"accessToken": "file-at", "refreshToken": "file-rt", "subscriptionType": "pro"}}
        """
        FileManager.default.createFile(atPath: fixtureDir + "/.credentials.json", contents: Data(fixture.utf8))
        setenv("CLAUDE_CONFIG_DIR", fixtureDir, 1)
        let fileCandidates = ClaudeCredentials.readClaudeFileCandidates()
        let filePicked = ClaudeCredentials.selectClaudeCreds(from: fileCandidates)
        expect(filePicked?.accessToken == "file-at", "T5 file store candidate decodes and is selectable")
        expect(filePicked?.subscriptionType == "pro", "T5 file store carries subscriptionType")
        // Keychain outranks a coexisting (stale) credentials file — Claude
        // Code 2.x reads the keychain first and deletes/strands the file
        // when a keychain write succeeds, so readClaudeCreds concatenates
        // keychain candidates ahead of file candidates.
        let mixed = ClaudeCredentials.selectClaudeCreds(from: [
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "claudeAiOauth": ["accessToken": "live-keychain-at"],
            ]),
        ] + fileCandidates)
        expect(mixed?.accessToken == "live-keychain-at", "T5 keychain wins over a coexisting stale file")
        // Keep CLAUDE_CONFIG_DIR pinned to the (now deleted) fixture dir so
        // this assertion never touches a real ~/.claude on the dev machine.
        try? FileManager.default.removeItem(atPath: fixtureDir)
        expect(ClaudeCredentials.readClaudeFileCandidates().isEmpty, "T5 missing file yields no candidates")
        setenv("CLAUDE_CONFIG_DIR", emptyConfigDir, 1)

        // T6 — auth-failure classification. UsageStore lets a terminal auth
        // error (expired token / missing scope) REPLACE a stale good value,
        // while a transient 429/network error is retained. Both predicates
        // must key only on the two actionable sentinels, and
        // isTerminalAuthFailure must require BOTH windows to carry one — a
        // single-window failure is a transient per-window glitch, not a dead
        // token.
        expect(ClaudeCredentials.isReauthActionable(ClaudeCredentials.tokenExpiredMessage),
               "T6 expired token is reauth-actionable")
        expect(ClaudeCredentials.isReauthActionable(ClaudeCredentials.reauthRequiredMessage),
               "T6 scope-insufficient is reauth-actionable")
        expect(!ClaudeCredentials.isReauthActionable(ClaudeCredentials.rateLimitedMessage),
               "T6 rate-limited is NOT reauth-actionable")
        expect(!ClaudeCredentials.isReauthActionable("no data"), "T6 no-data is NOT reauth-actionable")
        expect(!ClaudeCredentials.isReauthActionable(nil), "T6 nil error is NOT reauth-actionable")

        func pair(_ msg: String?) -> AppUsage {
            AppUsage(
                fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: msg),
                weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: msg))
        }
        expect(ClaudeCredentials.isTerminalAuthFailure(pair(ClaudeCredentials.tokenExpiredMessage)),
               "T6 both-window expired is a terminal auth failure")
        expect(ClaudeCredentials.isTerminalAuthFailure(pair(ClaudeCredentials.reauthRequiredMessage)),
               "T6 both-window scope is a terminal auth failure")
        expect(!ClaudeCredentials.isTerminalAuthFailure(pair(ClaudeCredentials.rateLimitedMessage)),
               "T6 rate-limited is NOT a terminal auth failure")
        expect(!ClaudeCredentials.isTerminalAuthFailure(pair(nil)),
               "T6 good usage is NOT a terminal auth failure")
        expect(!ClaudeCredentials.isTerminalAuthFailure(AppUsage(
            fiveHour: WindowUsage(usedPercent: 0.1, resetAt: nil, error: nil),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: ClaudeCredentials.tokenExpiredMessage))),
            "T6 single-window failure is NOT terminal (needs both)")

        // T7 — expired cached token, rotated store (the recurring "Claude
        // session expired" nag): Claude Code rotates the keychain item ~8h
        // while our in-memory copy goes stale. A 401 on the cached token must
        // re-read the store and retry within the SAME pass — surfacing
        // "token expired" for a login that is fine flashed the re-auth panel
        // (and re-armed the keychain-prompt cycle) once per rotation.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "primed", accessToken: "stale-token", subscriptionType: "max")
        ClaudeCredentials.keychainCandidatesProvider = { [
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "claudeAiOauth": ["accessToken": "rotated-token", "subscriptionType": "max"],
            ]),
        ] }
        let t7 = ProbeCounter()
        let r7 = await ClaudeCredentials.resolveUsage { token, _ in
            t7.calls += 1
            return token == "rotated-token" ? .success(fetched) : .unauthorized
        }
        // env stub (401) → stale cached token (401) → re-read → rotated (ok)
        expect(t7.calls == 3, "T7 retries once with the re-read token (got \(t7.calls) probes)")
        if case .usage = r7 {
            expect(true, "T7 resolution is .usage despite the stale cached token")
        } else {
            expect(false, "T7 resolution is .usage despite the stale cached token")
        }
        expect(ClaudeCredentials.cachedClaudeCreds?.accessToken == "rotated-token",
               "T7 cache now holds the rotated token")

        // T7b — 401 with an UNrotated store (genuinely expired login): the
        // re-read returns the same token, so there must be no retry probe —
        // re-probing an identical dead token would loop a doomed request.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "primed", accessToken: "stale-token", subscriptionType: "max")
        ClaudeCredentials.keychainCandidatesProvider = { [
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "claudeAiOauth": ["accessToken": "stale-token"],
            ]),
        ] }
        let t7b = ProbeCounter()
        let r7b = await ClaudeCredentials.resolveUsage { _, _ in
            t7b.calls += 1
            return .unauthorized
        }
        expect(t7b.calls == 2, "T7b same re-read token is not re-probed (got \(t7b.calls) probes)")
        if case .failed(let msg) = r7b {
            expect(msg == ClaudeCredentials.tokenExpiredMessage, "T7b resolution is .failed(tokenExpiredMessage)")
        } else {
            expect(false, "T7b resolution is .failed(tokenExpiredMessage)")
        }

        // T7c — rotated store whose new token is ALSO dead (user logged out
        // everywhere): retry once, then surface expired with the cache
        // cleared so the next poll re-reads.
        ClaudeCredentials.cachedClaudeCreds = ClaudeCredentials.ClaudeCreds(
            account: "primed", accessToken: "stale-token", subscriptionType: "max")
        ClaudeCredentials.keychainCandidatesProvider = { [
            ClaudeCredentials.KeychainCandidate(account: "ericpark", blob: [
                "claudeAiOauth": ["accessToken": "rotated-token"],
            ]),
        ] }
        let t7c = ProbeCounter()
        let r7c = await ClaudeCredentials.resolveUsage { _, _ in
            t7c.calls += 1
            return .unauthorized
        }
        expect(t7c.calls == 3, "T7c dead rotated token probed exactly once (got \(t7c.calls) probes)")
        if case .failed(let msg) = r7c {
            expect(msg == ClaudeCredentials.tokenExpiredMessage, "T7c resolution is .failed(tokenExpiredMessage)")
        } else {
            expect(false, "T7c resolution is .failed(tokenExpiredMessage)")
        }
        expect(ClaudeCredentials.cachedClaudeCreds == nil, "T7c dead retry clears the creds cache")
        ClaudeCredentials.keychainCandidatesProvider = { [] }
        ClaudeCredentials.clearCache()

        // T8 — credential-store fingerprint (file half; the keychain half is
        // an attributes-only SecItem query stubbed out here). The re-auth
        // poll loop gates its secret reads on this changing, so it must
        // track the file's mtime exactly and be nil with no store at all.
        expect(ClaudeCredentials.credentialStoreFingerprint() == nil,
               "T8 fingerprint is nil with no credential store")
        let t8Dir = NSTemporaryDirectory() + "codexisland-tests-t8-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: t8Dir, withIntermediateDirectories: true)
        setenv("CLAUDE_CONFIG_DIR", t8Dir, 1)
        let t8Path = t8Dir + "/.credentials.json"
        FileManager.default.createFile(atPath: t8Path, contents: Data("{}".utf8))
        let t8Early = Date(timeIntervalSince1970: 1_700_000_000)
        let t8Late = Date(timeIntervalSince1970: 1_700_000_060)
        try? FileManager.default.setAttributes([.modificationDate: t8Early], ofItemAtPath: t8Path)
        expect(ClaudeCredentials.credentialStoreFingerprint() == t8Early,
               "T8 fingerprint tracks the credentials file mtime")
        try? FileManager.default.setAttributes([.modificationDate: t8Late], ofItemAtPath: t8Path)
        expect(ClaudeCredentials.credentialStoreFingerprint() == t8Late,
               "T8 fingerprint moves when the file is rewritten")
        try? FileManager.default.removeItem(atPath: t8Dir)
        setenv("CLAUDE_CONFIG_DIR", emptyConfigDir, 1)

        // T9 — keychain service name. Claude Code suffixes the service with
        // the first 8 hex chars of sha256(configDir) when a custom config
        // dir is set (and an explicitly EMPTY securestorage override means
        // default even then). Wrong name = custom-dir users' logins are
        // invisible. Vectors precomputed with `sha256(dir).hexdigest()[:8]`.
        expect(ClaudeCredentials.claudeKeychainService(env: [:]) == "Claude Code-credentials",
               "T9 default env yields the bare service name")
        expect(ClaudeCredentials.claudeKeychainService(env: ["CLAUDE_CONFIG_DIR": ""]) == "Claude Code-credentials",
               "T9 empty CLAUDE_CONFIG_DIR yields the bare service name")
        expect(ClaudeCredentials.claudeKeychainService(env: ["CLAUDE_CONFIG_DIR": "/tmp/codexisland-test-config"])
               == "Claude Code-credentials-f4baf293",
               "T9 CLAUDE_CONFIG_DIR suffixes with first 8 sha256 hex chars")
        expect(ClaudeCredentials.claudeKeychainService(env: [
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/codexisland-secure-config",
            "CLAUDE_CONFIG_DIR": "/tmp/codexisland-test-config",
        ]) == "Claude Code-credentials-08673229",
               "T9 securestorage override outranks CLAUDE_CONFIG_DIR")
        expect(ClaudeCredentials.claudeKeychainService(env: [
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
            "CLAUDE_CONFIG_DIR": "/tmp/codexisland-test-config",
        ]) == "Claude Code-credentials",
               "T9 empty securestorage override forces the default name")

        // The store and views match these exact strings; a reword is a
        // breaking change for them, not a copy edit.
        expect(ClaudeCredentials.rateLimitedMessage == "rate limited", "rateLimitedMessage literal is stable")
        expect(ClaudeCredentials.reauthRequiredMessage == "re-login: claude /login", "reauthRequiredMessage literal is stable")
        expect(ClaudeCredentials.tokenExpiredMessage == "token expired — run claude", "tokenExpiredMessage literal is stable")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
