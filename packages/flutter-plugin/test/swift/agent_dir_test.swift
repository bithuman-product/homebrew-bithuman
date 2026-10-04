// Which agent dir an Expression 2 load renders on iOS / macOS (shared/Classes/Expression2AgentDir.swift, 2.6.36,
// security; PR #202 round 3). The load renders the dir its Dart side gated and sent; a dir another channel, a
// Dart side before a hot restart, or an account before a sign-out named is never rendered. Plain Swift, no
// Flutter, no engine: scripts/test_swift_unit.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failures += 1; print("  FAIL (line \(line)) \(what)") } else { print("  PASS \(what)") }
}

var resolved: [String] = []
let resolve: (String) -> String? = { p in resolved.append(p); return "/expanded\(p)" }

// The ordinary path: setExpression2AgentDir(A's dir), then load sends that dir: the resolution is reused.
var s = Expression2AgentDirState()
s.set(named: "/cache/A99LTC2401", resolved: "/cache/A99LTC2401")
check(s.dirForLoad(requested: "/cache/A99LTC2401", resolve: resolve) == "/cache/A99LTC2401", "the dir Dart gated and sent")
check(resolved.isEmpty, "...without resolving it again")

// A Dart hot restart: Dart's copy is gone and the load sends "" (the bundled default): A's dir is NOT rendered.
check(s.dirForLoad(requested: "", resolve: resolve) == nil, "a load that sends no dir renders the bundled default")

// Another channel (a second FlutterEngine) named B's dir; this one sends its own gated dir: resolved now.
check(s.dirForLoad(requested: "/cache/B11BBB0001", resolve: resolve) == "/expanded/cache/B11BBB0001",
      "a dir this channel did not name is resolved for this load, never swapped for the named one")
check(resolved == ["/cache/B11BBB0001"], "resolved once")

// Sign-out (clearCredentials): nothing named; a caller that sends nothing gets the bundled default.
s.clear()
check(s.named == nil && s.resolved == nil, "clearCredentials forgets the dir")
check(s.dirForLoad(requested: nil, resolve: resolve) == nil, "after sign-out: the bundled default")

// A caller older than 2.6.36 on this channel (sends nothing): this channel's own dir, never another's.
var t = Expression2AgentDirState()
t.set(named: "/cache/A99LTC2401.imx", resolved: "/unpacked/A99LTC2401")
check(t.dirForLoad(requested: nil, resolve: resolve) == "/unpacked/A99LTC2401", "no agentDir sent: this channel's own")
// Naming the bundled default ("" or nil) clears it.
t.set(named: "", resolved: "/ignored")
check(t == Expression2AgentDirState(), "setExpression2AgentDir('') names nothing")
t.set(named: nil, resolved: nil)
check(t.dirForLoad(requested: nil, resolve: resolve) == nil, "setExpression2AgentDir(null): the bundled default")

if failures > 0 { print("agent_dir_test: \(failures) FAILED"); exit(1) }
print("agent_dir_test: all passed")
