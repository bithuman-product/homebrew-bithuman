// engine_registry.dart — re-exports the canonical Layer-0 Dart contract.
//
// CANONICAL HOME: github.com/bithuman-product/bithuman-engine-protocol
// (pub package `bithuman_engine_protocol`, lib/bithuman_engine_protocol.dart) —
// EngineDescriptor + kEngineRegistry + kExpression2/kEssence2 + engineDescriptorFor.
//
// M0 mirrored that contract IN this file so the app could reach it via
// `package:bithuman/engine_registry.dart` with no new pub dependency. M2 folds
// the dependency onto the package directly: the umbrella now git-deps
// `bithuman_engine_protocol` (pubspec.yaml) and this file simply RE-EXPORTS it,
// so the FROZEN dual-accept slugs (`expression2`/`embody`, `essence2`/`elevate`)
// have a SINGLE source of truth. App imports of
// `package:bithuman/engine_registry.dart` keep working unchanged.
//
// The BithumanAvatar.load(path, {engine, motionDir, chunk}) WIRE contract is
// UNCHANGED — the registry only types call sites + gallery tabs.
//
// Apache-2.0; (c) bitHuman.
library;

export 'package:bithuman_engine_protocol/bithuman_engine_protocol.dart';
