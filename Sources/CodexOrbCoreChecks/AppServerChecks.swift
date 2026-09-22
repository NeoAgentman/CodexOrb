import CodexOrbCore
import Darwin
import Foundation

/// Offline protocol peer: no account/network endpoints are used by these checks.
enum AppServerChecks {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AppServerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run() async throws {
        try parsing()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orb-app-server-check-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let binary = root.appendingPathComponent("codex")
        try Data(peer.utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let oldBinary = root.appendingPathComponent("old-codex")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: oldBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldBinary.path)
        let runtime = CodexRuntime.shared
        let compatible = try await runtime.resolve(candidates: [oldBinary, binary])
        try expect(compatible == binary, "skip incompatible runtime and probe actual schema")
        let store = PendingResetStore(root: root.appendingPathComponent("pending"))
        let service = CodexAccountService(pendingStore: store, executable: binary, timeout: 0.5)
        func account(_ name: String, includeAccountID: Bool = true) throws -> CodexAccount {
            let home = root.appendingPathComponent(name)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let claims: [String: Any] = ["email": "test@example.test", "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            var tokens = ["access_token": "fixture", "id_token": "header.\(payload).signature"]
            if includeAccountID { tokens["account_id"] = name }
            let auth = ["tokens": tokens]
            try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent("auth.json"))
            return try CodexAccountStore.read(home: home)
        }
        func mode(_ account: CodexAccount, _ value: String) throws {
            try Data(value.utf8).write(to: URL(fileURLWithPath: account.home).appendingPathComponent("mode"))
        }
        func calls(_ account: CodexAccount) throws -> [String] {
            let url = URL(fileURLWithPath: account.home).appendingPathComponent("calls")
            if !fm.fileExists(atPath: url.path) { return [] }
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        let a = try account("account-A")
        let b = try account("account-B")
        let usage = try await service.fetch(account: a)
        try expect(usage.weeklyQuota?.usedPercent == 60 && usage.fiveHourQuota?.usedPercent == 20, "fragmented response and interleaved notification")
        let missingID = try account("missing-id", includeAccountID: false)
        let missingIDUsage = try await service.fetch(account: missingID)
        try expect(missingIDUsage.weeklyQuota?.usedPercent == 60, "missing local account ID does not become an empty expected ID")
        try expect(try calls(a).isEmpty, "read-only preflight cannot consume")
        try expect(try store.read(a.identityKey) == nil, "preflight creates no pending mutation")
        let result = try await service.consume(account: a, creditID: "card-1")
        try expect(result.outcome == .reset && result.usage?.weeklyQuota?.usedPercent == 0, "consume then refresh")
        try expect(try store.read(a.identityKey) == nil, "completed operation removed")
        try expect(try calls(a).count == 1 && calls(b).isEmpty, "account scoped mutation")

        let dropped = try account("drop")
        try mode(dropped, "drop")
        do { _ = try await service.consume(account: dropped, creditID: "card-1"); throw AppServerError.cardUnavailable }
        catch AppServerError.disconnected { }
        let pending = try store.read(dropped.identityKey)!
        let permissions = try fm.attributesOfItem(atPath: store.directory(dropped.identityKey).appendingPathComponent("pending.json").path)[.posixPermissions] as? Int
        try expect(permissions == 0o600, "pending records are private")
        try expect(try calls(dropped) == [pending.idempotencyKey], "key durable before lost response")
        let recoveredService = CodexAccountService(pendingStore: store, executable: binary, timeout: 0.5)
        let recovered = try await recoveredService.consume(account: dropped, creditID: "card-1")
        try expect(recovered.outcome == .alreadyRedeemed && recovered.usage != nil, "restart recovers idempotent success")
        try expect(try calls(dropped) == [pending.idempotencyKey, pending.idempotencyKey], "same key on retry")

        let refreshFailure = try account("refresh-failure")
        try mode(refreshFailure, "refresh-failure")
        let known = try await service.consume(account: refreshFailure, creditID: "card-1")
        try expect(known.outcome == .reset && known.usage == nil, "known success stays known after read failure")
        try expect(try store.read(refreshFailure.identityKey)?.outcome == .reset, "known outcome durable")
        try mode(refreshFailure, "normal")
        let refreshed = try await recoveredService.consume(account: refreshFailure, creditID: "card-1")
        try expect(refreshed.usage != nil && calls(refreshFailure).count == 1, "known success recovery only reads")

        for outcome in [ResetOutcome.noCredit, .nothingToReset] {
            let current = try account(outcome.rawValue)
            try mode(current, outcome.rawValue)
            let value = try await service.consume(account: current, creditID: "card-1")
            try expect(value.outcome == outcome && value.usage != nil, "non-consuming outcome returned")
        }
        let wrong = try account("wrong")
        try mode(wrong, "wrong-account")
        do { _ = try await service.consume(account: wrong, creditID: "card-1"); throw AppServerError.cardUnavailable }
        catch AppServerError.accountChanged { }
        try expect(try calls(wrong).isEmpty && store.read(wrong.identityKey) == nil, "mismatched account cannot consume")
        let swapped = try account("swapped")
        try mode(swapped, "swap-auth")
        do { _ = try await service.consume(account: swapped, creditID: "card-1"); throw AppServerError.protocolError }
        catch AppServerError.accountChanged { }
        try expect(try calls(swapped).isEmpty, "auth changed during read cannot consume")
        let stale = try account("stale")
        do { _ = try await service.consume(account: stale, creditID: "not-a-card"); throw AppServerError.protocolError }
        catch AppServerError.cardUnavailable { }
        try expect(try calls(stale).isEmpty, "stale card cannot consume")

        // Automatic checks use the same offline peer, with account-specific live snapshots.
        func automaticAccount(_ name: String, used: Double = 60, count: Int = 2) throws -> CodexAccount {
            let value = try account(name)
            let snapshot: [String: Any] = [
                "used": used, "count": count,
                "cards": [
                    ["id": "later", "resetType": "codexRateLimits", "status": "available", "expiresAt": Date().addingTimeInterval(7200).timeIntervalSince1970],
                    ["id": "earliest", "resetType": "codexRateLimits", "status": "available", "expiresAt": Date().addingTimeInterval(1800).timeIntervalSince1970],
                ],
            ]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: URL(fileURLWithPath: value.home).appendingPathComponent("automatic.json"))
            return value
        }
        let automaticPolicy = AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: 1)
        let automaticA = try automaticAccount("automatic-A")
        let automaticB = try automaticAccount("automatic-B")
        let automaticAccounts = [automaticA, automaticA, automaticB]
        try expect(AutomaticResetPolicy().accounts(from: automaticAccounts, selectedHome: automaticA.home).isEmpty, "disabled scope is empty")
        try expect(automaticPolicy.accounts(from: automaticAccounts, selectedHome: nil).isEmpty, "no current account means no implicit fallback")
        let selectedOnly = automaticPolicy.accounts(from: automaticAccounts, selectedHome: automaticA.home)
        try expect(selectedOnly == [automaticA], "default scope is the selected account, deduplicated")
        for current in selectedOnly { _ = try await service.consumeExpiring(account: current, policy: automaticPolicy) }
        try expect(try calls(automaticA).count == 1 && calls(automaticB).isEmpty, "selected-only mode leaves other accounts untouched")
        let usedCard = try String(contentsOf: URL(fileURLWithPath: automaticA.home).appendingPathComponent("credit-ids"), encoding: .utf8)
        try expect(usedCard == "earliest\n", "automatic request names the earliest card explicitly")
        let allPolicy = AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: 1, allAccounts: true)
        let all = allPolicy.accounts(from: automaticAccounts, selectedHome: nil)
        try expect(all == [automaticA, automaticB], "all accounts mode works without a current selection")
        for current in all { _ = try await service.consumeExpiring(account: current, policy: allPolicy) }
        try expect(try calls(automaticA).count == 1 && calls(automaticB).count == 1, "fresh quota prevents another card after reset")
        for (name, used, count) in [("auto-full", 0.0, 2), ("auto-partial", 60.0, 3)] {
            let current = try automaticAccount(name, used: used, count: count)
            let result = try await service.consumeExpiring(account: current, policy: automaticPolicy)
            try expect(result == nil && (try calls(current)).isEmpty, "fresh ineligible quota or incomplete inventory never consumes")
        }
        let autoDisabled = try automaticAccount("auto-disabled")
        _ = try await service.consumeExpiring(account: autoDisabled, policy: .init())
        try expect(!fm.fileExists(atPath: URL(fileURLWithPath: autoDisabled.home).appendingPathComponent("pid").path), "disabled service does not start a process")
        let autoDrop = try automaticAccount("auto-drop")
        try mode(autoDrop, "drop")
        do { _ = try await service.consumeExpiring(account: autoDrop, policy: automaticPolicy); throw AppServerError.protocolError }
        catch AppServerError.disconnected { }
        let autoPending = try store.read(autoDrop.identityKey)!
        _ = try await service.consumeExpiring(account: autoDrop, policy: automaticPolicy)
        try expect(try calls(autoDrop).count == 1 && store.read(autoDrop.identityKey) == autoPending, "uncertain result blocks automatic retries and further cards")
        let autoRecovery = try await service.consume(account: autoDrop, creditID: autoPending.creditID)
        try expect(autoRecovery.outcome == .alreadyRedeemed && (try calls(autoDrop)) == [autoPending.idempotencyKey, autoPending.idempotencyKey], "manual recovery reuses the automatic operation key")
        let autoFailure = try automaticAccount("auto-failure")
        try mode(autoFailure, "wrong-account")
        let autoHealthy = try automaticAccount("auto-healthy")
        for current in allPolicy.accounts(from: [autoFailure, autoHealthy], selectedHome: nil) {
            do { _ = try await service.consumeExpiring(account: current, policy: allPolicy) }
            catch AppServerError.accountChanged { }
        }
        try expect(try calls(autoFailure).isEmpty && calls(autoHealthy).count == 1, "one account failure does not prevent remaining accounts")
        let autoReadback = try automaticAccount("auto-readback")
        try mode(autoReadback, "refresh-failure")
        let autoKnown = try await service.consumeExpiring(account: autoReadback, policy: automaticPolicy)
        try expect(autoKnown?.outcome == .reset && autoKnown?.usage == nil, "automatic success stays known if readback fails")
        _ = try await service.consumeExpiring(account: autoReadback, policy: automaticPolicy)
        try expect(try calls(autoReadback).count == 1, "failed readback cannot consume the next card")
        let autoNothing = try automaticAccount("auto-nothing")
        try mode(autoNothing, "nothingToReset")
        let nothing = try await service.consumeExpiring(account: autoNothing, policy: automaticPolicy)
        try expect(nothing?.outcome == .nothingToReset && (try calls(autoNothing)).count == 1, "server ineligibility ends the attempt without a tight retry loop")
        let autoChanged = try automaticAccount("auto-changed")
        let changed = try await service.consumeExpiring(account: autoChanged, policy: automaticPolicy, expectedCreditID: "previously-shown-card")
        try expect(changed == nil && (try calls(autoChanged)).isEmpty, "countdown never substitutes a different card")
        let autoDismissed = try automaticAccount("auto-dismissed")
        let dismissals = AutomaticResetDismissalStore(root: store.root)
        try dismissals.dismiss(identity: autoDismissed.identityKey, creditID: "earliest", expiresAt: Date().addingTimeInterval(1800))
        let restartedDismissals = AutomaticResetDismissalStore(root: store.root)
        try expect(try restartedDismissals.contains(identity: autoDismissed.identityKey, creditID: "earliest"), "cancel persists across restart")
        try expect(try !restartedDismissals.contains(identity: automaticB.identityKey, creditID: "earliest"), "cancel is account scoped")
        try expect(try !restartedDismissals.contains(identity: autoDismissed.identityKey, creditID: "earliest", now: Date().addingTimeInterval(1801)), "expired cancellation is inactive")
        let dismissed = try await service.consumeExpiring(account: autoDismissed, policy: automaticPolicy, expectedCreditID: "earliest")
        try expect(dismissed == nil && (try calls(autoDismissed)).isEmpty, "cancelled card cannot be used automatically")
        let manualAfterCancel = try await service.consume(account: autoDismissed, creditID: "earliest")
        try expect(manualAfterCancel.outcome == .reset, "cancel does not prevent explicit manual consumption")
        let afterCountdown = try automaticAccount("auto-after-countdown")
        let before = try await service.fetch(account: afterCountdown)
        try expect(automaticPolicy.candidate(in: before)?.id == "earliest", "candidate shown before countdown")
        _ = try automaticAccount("auto-after-countdown", used: 0)
        let noLongerEligible = try await service.consumeExpiring(account: afterCountdown, policy: automaticPolicy, expectedCreditID: "earliest")
        try expect(noLongerEligible == nil && (try calls(afterCountdown)).isEmpty, "quota revalidated after countdown")
        let autoCancel = try automaticAccount("auto-cancel")
        try mode(autoCancel, "hang")
        let autoTask = Task { try await service.consumeExpiring(account: autoCancel, policy: automaticPolicy) }
        for _ in 0..<100 {
            if fm.fileExists(atPath: URL(fileURLWithPath: autoCancel.home).appendingPathComponent("reading").path) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        autoTask.cancel()
        do { _ = try await autoTask.value; throw AppServerError.protocolError } catch is CancellationError { }
        try expect(try calls(autoCancel).isEmpty && store.read(autoCancel.identityKey) == nil, "disable or scope change cancellation during preflight cannot consume")

        let waiting = try account("waiting")
        try mode(waiting, "hang")
        let task = Task { try await service.fetch(account: waiting) }
        try await Task.sleep(for: .milliseconds(120))
        let competing = CodexAccountService(pendingStore: store, executable: binary)
        do { _ = try await competing.fetch(account: waiting); throw AppServerError.protocolError }
        catch CLIUpdateError.busy { }
        task.cancel()
        do { _ = try await task.value; throw AppServerError.protocolError }
        catch is CancellationError { }
        let pid = Int32(try String(contentsOf: URL(fileURLWithPath: waiting.home).appendingPathComponent("pid"), encoding: .utf8))!
        try expect(kill(pid, 0) != 0 && errno == ESRCH, "cancelled subprocess reaped")
        do { _ = try await service.fetch(account: waiting); throw AppServerError.protocolError }
        catch AppServerError.timedOut { }
        let latestPID = Int32(try String(contentsOf: URL(fileURLWithPath: waiting.home).appendingPathComponent("pid"), encoding: .utf8))!
        try expect(kill(latestPID, 0) != 0 && errno == ESRCH, "timed out subprocess reaped")

        let damaged = try account("damaged-pending")
        let damagedDirectory = try store.directory(damaged.identityKey)
        try fm.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damagedURL = damagedDirectory.appendingPathComponent("pending.json")
        try Data("{".utf8).write(to: damagedURL)
        try expect(store.state(damaged.identityKey) == .unreadable, "damaged pending record is distinct from recoverable pending")
        let quarantined = try store.quarantineUnreadable(damaged.identityKey)
        try expect(store.state(damaged.identityKey) == .none && fm.fileExists(atPath: quarantined.path),
                   "damaged pending record is preserved outside the active recovery path")
        let validPending = PendingReset(identityKey: damaged.identityKey, creditID: "card-1")
        try store.save(validPending)
        do {
            _ = try store.quarantineUnreadable(damaged.identityKey)
            throw AppServerError.protocolError
        } catch AppServerError.busy { }
        try expect(store.state(damaged.identityKey) == .pending(validPending),
                   "valid pending record cannot be quarantined")
        print("App-server checks passed: parsing, preflight, account isolation, idempotent recovery, known outcomes, locks, cancellation and timeout")
    }

    static func parsing() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":{"usedPercent":20,"windowDurationMins":300}},"other":{"primary":{"usedPercent":90,"windowDurationMins":300}}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"later","status":"available","resetType":"codexRateLimits","expiresAt":2100000000},{"id":"first","status":"available","resetType":"codexRateLimits","expiresAt":2000000000},{"id":"forever","status":"available","resetType":"codexRateLimits","expiresAt":null}]}}"#.utf8)
        let value = try AppServerUsageParser.parse(data)
        try expect(value.fiveHourQuota?.usedPercent == 20 && value.weeklyQuota?.usedPercent == 60, "bucket before duration mapping")
        try expect(value.resetCredits?.availableCards.map(\.id) == ["first", "later", "forever"], "sorted cards retain IDs")
        for (field, expected) in [("null", Optional<Int>.none), ("[]", 0)] {
            let parsed = try AppServerUsageParser.parse(Data("{\"rateLimits\":{},\"rateLimitResetCredits\":{\"availableCount\":4,\"credits\":\(field)}}".utf8))
            try expect(parsed.resetCredits?.credits?.count == expected && parsed.resetCredits?.availableCount == 4, "unknown/empty details preserve inventory")
        }
        let other = try AppServerUsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":20,"windowDurationMins":10080}}}}"#.utf8))
        try expect(other.windows.isEmpty, "never substitute another bucket")

        let monthly = try AppServerUsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":35,"windowDurationMins":43200},"secondary":{"usedPercent":90,"windowDurationMins":900}}}"#.utf8))
        try expect(monthly.monthlyQuota?.usedPercent == 35 && monthly.fiveHourQuota == nil && monthly.weeklyQuota == nil,
                   "classify monthly window and discard unsupported duration")

        let unsupported = try AppServerUsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":15},"secondary":null}}"#.utf8))
        try expect(unsupported.windows.isEmpty, "discard unsupported app-server window")
    }

    static let peer = #"""
#!/usr/bin/python3
import json, os, pathlib, signal, sys, time
if sys.argv[1:3] == ['app-server', 'generate-json-schema']:
    target = pathlib.Path(sys.argv[sys.argv.index('--out')+1])/'v2'
    target.mkdir(parents=True)
    schemas = {
      'GetAccountRateLimitsResponse':{'properties':{'rateLimitResetCredits':{}},'definitions':{'RateLimitResetCredit':{'properties':{'id':{}}}}},
      'ConsumeAccountRateLimitResetCreditParams':{'properties':{'idempotencyKey':{},'creditId':{}}},
      'ConsumeAccountRateLimitResetCreditResponse':{'properties':{'outcome':{}}}}
    for name, schema in schemas.items(): (target/(name+'.json')).write_text(json.dumps(schema))
    sys.exit(0)
home = pathlib.Path(os.environ['CODEX_HOME'])
(home/'pid').write_text(str(os.getpid()))
mode = (home/'mode').read_text() if (home/'mode').exists() else 'normal'
assert sys.argv[1:] == ['app-server','--stdio','-c','cli_auth_credentials_store="file"']
read_count = 0
for line in sys.stdin:
    obj = json.loads(line)
    method = obj.get('method')
    if method == 'initialized': continue
    if method == 'initialize': result = {'userAgent':'fixture'}
    elif method == 'account/read': result = {'account':{'type':'chatgpt','email':'test@example.test','planType':'pro'}}
    elif method == 'account/rateLimits/read':
        read_count += 1
        (home/'reading').write_text('1')
        if mode == 'hang':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
        if mode == 'swap-auth':
            auth = json.loads((home/'auth.json').read_text())
            auth['tokens']['account_id'] = 'new-identity'
            (home/'auth.json').write_text(json.dumps(auth))
        done = (home/'redeemed').exists()
        if mode == 'refresh-failure' and done:
            print(json.dumps({'id':obj['id'],'error':{'code':-1,'message':'secret upstream text'}}), flush=True)
            continue
        result = {'accountId':'different-account' if mode == 'wrong-account' else home.name,
                  'rateLimits':{'primary':{'usedPercent':0 if done else 20,'windowDurationMins':300},
                                'secondary':{'usedPercent':0 if done else 60,'windowDurationMins':10080}},
                  'rateLimitResetCredits':{'availableCount':0 if done else 1,
                    'credits':[] if done else [{'id':'card-1','resetType':'codexRateLimits','status':'available','expiresAt':2100000000}]}}
        if (home/'automatic.json').exists():
            config = json.loads((home/'automatic.json').read_text())
            result['rateLimits']['secondary']['resetsAt'] = time.time()+86400
            if not done:
                result['rateLimits']['secondary']['usedPercent'] = config['used']
                result['rateLimitResetCredits'] = {'availableCount':config['count'], 'credits':config['cards']}
    elif method == 'account/rateLimitResetCredit/consume':
        key = obj['params']['idempotencyKey']
        with (home/'credit-ids').open('a') as f: f.write(obj['params']['creditId']+'\n')
        with (home/'calls').open('a') as f: f.write(key+'\n')
        previous = (home/'redeemed').read_text() if (home/'redeemed').exists() else None
        if mode in ['noCredit','nothingToReset']: result = {'outcome':mode}
        else:
            assert previous is None or previous == key, 'new key would double redeem'
            result = {'outcome':'alreadyRedeemed' if previous else 'reset'}
            (home/'redeemed').write_text(key)
            if mode == 'drop' and not previous: sys.exit(0)
    else: raise RuntimeError('unexpected method')
    print(json.dumps({'method':'account/rateLimits/updated','params':{}}), flush=True)
    payload = json.dumps({'id':obj['id'],'result':result})+'\n'
    midpoint = len(payload)//2
    sys.stdout.write(payload[:midpoint]); sys.stdout.flush()
    time.sleep(0.002)
    sys.stdout.write(payload[midpoint:]); sys.stdout.flush()
"""#
}
