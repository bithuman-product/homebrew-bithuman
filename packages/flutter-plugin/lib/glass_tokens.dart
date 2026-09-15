// Design tokens for the bitHuman "liquid glass" look.
//
// MOVED DOWN from bithuman-jarvis-app so the product and the examples share ONE
// definition of the surface rather than drifting apart. Same reason the realtime
// layer and the avatar fit moved here: a design system copied into two apps is two
// design systems the first time someone adjusts a blur radius.
//
// Single source of truth for the glass surfaces (blur / tint / hairline /
// shadow) and the corner radii used by every floating chrome element. The
// native window chrome (the plugin's macos/Classes/WindowChrome.swift) mirrors
// [rWindow] and [bubbleSize] on the NSWindow side — keep them in sync.

import 'package:flutter/material.dart';

abstract final class Glass {
  // ── Corner radii ────────────────────────────────────────────────────
  /// Window corner mask (continuous curve). Must match
  /// `WindowChrome.normalRadius` in the plugin's macos/Classes/WindowChrome.swift.
  static const double rWindow = 18;
  static const double rSheet = 28; // control panel / settings sheet
  static const double rBar = 40; // floating control capsule
  static const double rPill = 24; // warming pill
  static const double rCaption = 22; // expanded caption card
  static const double rToast = 16; // top toast

  // ── Glass surface ───────────────────────────────────────────────────
  static const double blurSigma = 26;

  /// Dark glass tint with a faint top sheen (top → bottom gradient).
  static const Color tintTop = Color(0x5226262E);
  static const Color tintBottom = Color(0x52101015);

  /// 1 px hairline border around every glass surface.
  static const Color hairline = Color(0x21FFFFFF);

  /// Soft drop shadow that floats the glass off the avatar canvas.
  static const List<BoxShadow> shadow = [
    BoxShadow(color: Color(0x59000000), blurRadius: 26, offset: Offset(0, 10)),
  ];

  // ── Minimize-to-bubble window ───────────────────────────────────────
  /// Bubble window size (logical px == NSWindow pt). Must match the size the
  /// Dart side passes to the native `enterBubble` call.
  static const double bubbleSize = 140;
}
