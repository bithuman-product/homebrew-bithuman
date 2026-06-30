// engine_registry.dart — re-exports the Layer-0 Dart contract.
//
// The contract (EngineDescriptor + kEngineRegistry + kExpression2/kEssence2 +
// engineDescriptorFor) is INLINED at lib/src/engine_protocol.dart and re-exported
// here, so the plugin is self-contained — no separate `bithuman_engine_protocol`
// pub.dev package (2026-06-30; reverts the M2 split that required publishing the
// protocol first). The FROZEN dual-accept slugs (`expression2`/`embody`,
// `essence2`/`elevate`) have a SINGLE source of truth; app imports of
// `package:bithuman/engine_registry.dart` are unchanged. The Swift half stays a
// product in the homebrew-bithuman SwiftPM package for the engine SDKs.
//
// The BithumanAvatar.load(path, {engine, motionDir, chunk}) WIRE contract is
// UNCHANGED — the registry only types call sites + gallery tabs.
//
// Apache-2.0; (c) bitHuman.
library;

export 'src/engine_protocol.dart';
