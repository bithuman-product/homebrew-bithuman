// Expression2AgentDir.swift — which agent dir an Expression 2 load renders on iOS / macOS (2.6.36, security;
// PR #202 round 3). Plain Swift, no engine: scripts/test_swift_unit.sh runs test/swift/agent_dir_test.swift.
//
// Expression 2 renders from `Expression2Engine.activeAgentDir`, a process-wide static that
// `setExpression2AgentDir` sets out of band. Dart gates the dir it named (`DoorGate.openPath`) with the
// load's credential, but the static outlives the Dart side's copy: after a Dart hot restart, in an
// add-to-app or multi-engine setup, or after a sign-out, the static could still name account A's kept
// private dir while a load for account B passed an ungated path, and B rendered A's avatar.
//
// Now each load SENDS the dir Dart gated (`agentDir`; "" = none, the bundled default), and the plugin sets the
// static from that value right before the engine is created: the dir this channel resolved when the value is
// what this channel last named, otherwise the value itself, resolved now. A load that sends nothing (a caller
// older than 2.6.36 on this channel) renders what THIS channel named, never another channel's dir.
// `clearCredentials` and a new plugin instance (an engine attach) forget it.
import Foundation

struct Expression2AgentDirState: Equatable {
  /// What `setExpression2AgentDir` on this channel last named (nil: none, or the bundled default).
  private(set) var named: String?
  /// What that resolved to (a packed container is expanded to a directory).
  private(set) var resolved: String?

  /// `setExpression2AgentDir(dir)` finished on this channel; "" and nil name the bundled default.
  mutating func set(named dir: String?, resolved r: String?) {
    let d = (dir?.isEmpty ?? true) ? nil : dir
    named = d
    resolved = d == nil ? nil : r
  }

  /// Sign-out, or a new attach: nothing named.
  mutating func clear() {
    named = nil
    resolved = nil
  }

  /// The dir an Expression 2 load renders (nil: the bundled default). [requested] is the `agentDir` the load
  /// sent: "" the bundled default, a dir that one (this channel's resolution when it is what this channel
  /// named, else [resolve]d now), nil (not sent) this channel's own.
  func dirForLoad(requested: String?, resolve: (String) -> String?) -> String? {
    guard let req = requested else { return resolved }
    if req.isEmpty { return nil }
    if req == named { return resolved }
    return resolve(req)
  }
}
