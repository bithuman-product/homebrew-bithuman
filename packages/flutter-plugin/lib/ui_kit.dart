// The bitHuman UI kit — ONE set of components for iPhone, Android and macOS.
//
// ★Owner directive, 2026-09-15 (paraphrased for the public tree): standardize the UI
// components across every surface — loading animation, heroshots, buttons, animation
// effects — so that iPhone, Android and macOS all share the same effects.
//
// THE MECHANISM MATTERS MORE THAN THE WIDGETS. Components live HERE, in the shared
// plugin, and are IMPORTED by every surface; no surface defines its own. A surface that
// wants a button gets it from the kit or does not get one — the same rule as the error
// table and the engine protocol, for the same reason: a copy drifts the first time
// someone adjusts it.
//
// Every member below was PROMOTED from bithuman-jarvis-app (the product app), where it
// existed as a private widget inside main.dart — `_Frosted`, `_GlassIconBtn`,
// `_RoundBtn`, `_LoadingRingPainter`. Same implementation, public name, one home.
// Jarvis should import this file and delete its copies.
//
// Platform-specific behaviour lives INSIDE a component (haptics on touch, hover on a
// pointer), never in the surface: a surface should not know it is on iOS to render a
// button correctly.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_tokens.dart';
import 'src/dev_levers.dart';
export 'glass_tokens.dart';
export 'avatar_fit.dart';

// ─── MOTION ─────────────────────────────────────────────────────────────────
/// One set of curves and durations. Animation effects that differ per platform are
/// precisely what the owner asked to eliminate, so nothing outside this file names a
/// Duration or a Curve.
abstract final class Motion {
  static const Curve curve = Curves.easeOutCubic;

  /// A press, a hover, a dot changing colour.
  static const Duration quick = Duration(milliseconds: 150);

  /// A surface appearing or leaving: chrome fade, caption card, toast.
  static const Duration surface = Duration(milliseconds: 260);

  /// The idle-to-hidden delay for auto-hiding chrome.
  static const Duration chromeIdle = Duration(seconds: 4);

  /// One revolution of the loading ring.
  static const Duration loadingRevolution = Duration(milliseconds: 1100);
}

// ─── GLASS SURFACE ──────────────────────────────────────────────────────────
/// The frosted surface every floating element sits on: blur, a dark tint with a faint
/// top sheen, a 1 px hairline, and a shadow that floats it off the avatar. The shadow
/// lives OUTSIDE the clip — a shadow inside a ClipRRect is cut off.
class Frosted extends StatelessWidget {
  const Frosted({super.key, required this.child, required this.borderRadius, this.padding});
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: Glass.shadow),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma),
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Glass.tintTop, Glass.tintBottom],
                ),
                borderRadius: borderRadius,
                border: Border.all(color: Glass.hairline, width: 1),
              ),
              padding: padding,
              child: child,
            ),
          ),
        ),
      );
}

// ─── BUTTONS ────────────────────────────────────────────────────────────────
/// A small square glass button holding an icon. Haptics on touch surfaces, a pointer
/// cursor on desktops — decided here, not by the caller.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.onTap, this.tooltip, this.size = 30});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget btn = Frosted(
      borderRadius: BorderRadius.circular(size / 2),
      child: SizedBox(
        width: size, height: size,
        child: Center(child: Icon(icon, size: size / 2, color: Colors.white.withValues(alpha: 0.92))),
      ),
    );
    btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () { HapticFeedback.lightImpact(); onTap(); },
        child: btn,
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// A round filled button — the primary action (start, send). One pressed/hover state,
/// one disabled state (onTap == null), an optional glow for the inviting call-to-start.
class RoundButton extends StatefulWidget {
  const RoundButton({super.key, required this.icon, required this.fg, required this.bg, this.onTap, this.glow = false, this.size = 38});
  final IconData icon;
  final Color fg, bg;
  final VoidCallback? onTap;
  final bool glow;
  final double size;
  @override
  State<RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<RoundButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) { if (enabled) setState(() => _hover = true); },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? () { HapticFeedback.lightImpact(); widget.onTap!(); } : null,
        child: AnimatedScale(
          scale: (_hover && enabled) ? 1.12 : 1.0,
          duration: Motion.quick, curve: Motion.curve,
          child: AnimatedContainer(
            duration: Motion.quick,
            width: widget.size, height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? widget.bg : widget.bg.withValues(alpha: 0.35),
              boxShadow: widget.glow && enabled
                  ? [BoxShadow(color: widget.bg.withValues(alpha: _hover ? 0.6 : 0.4), blurRadius: _hover ? 18 : 12, spreadRadius: _hover ? 1.5 : 0.5)]
                  : null,
            ),
            child: Icon(widget.icon, color: enabled ? widget.fg : widget.fg.withValues(alpha: 0.5),
                        size: (_hover && enabled) ? widget.size * 0.58 : widget.size * 0.53),
          ),
        ),
      ),
    );
  }
}

// ─── LOADING ────────────────────────────────────────────────────────────────
/// The one loading animation: a faint track, a bright leading sweep, a faint trailing
/// echo. Used for avatar load, session connect and identity fetch alike.
class LoadingRing extends StatefulWidget {
  const LoadingRing({super.key, this.size = 44, this.color = Colors.white});
  final double size;
  final Color color;
  @override
  State<LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<LoadingRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.loadingRevolution)..repeat();
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _LoadingRingPainter(t: _c.value, color: widget.color),
        ),
      );
}

class _LoadingRingPainter extends CustomPainter {
  _LoadingRingPainter({required this.t, required this.color});
  final double t; final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 4;
    final twoPi = 2 * math.pi;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = color.withValues(alpha: 0.12));
    canvas.drawArc(rect, t * twoPi, twoPi * 0.30, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round..color = color.withValues(alpha: 0.9));
    canvas.drawArc(rect, t * twoPi - twoPi * 0.18, twoPi * 0.14, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round..color = color.withValues(alpha: 0.3));
  }
  @override
  bool shouldRepaint(_LoadingRingPainter old) => old.t != t || old.color != color;
}

/// The loading STATE, not just the spinner: the ring plus the current stage, so the
/// ~35 s first-load progression ("loading the avatar…" → "avatar ready" → "connected")
/// looks identical on every surface.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, required this.stage});
  final String stage;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        const LoadingRing(),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: Motion.surface,
          child: Text(stage, key: ValueKey(stage),
              style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 0.2)),
        ),
      ]);
}

// ─── STATUS ─────────────────────────────────────────────────────────────────
/// What the session is doing, as a colour. ONE definition of the colours and what each
/// state means; surfaces map their own status into this enum.
enum SessionState { connecting, ready, listening, thinking, speaking, error }

extension SessionStateColor on SessionState {
  Color get dot => switch (this) {
        SessionState.connecting => const Color(0xFF6BA8E6),
        SessionState.ready      => const Color(0xFF9BE66B),
        SessionState.listening  => const Color(0xFF6BE675),
        SessionState.thinking   => const Color(0xFFE6C56B),
        SessionState.speaking   => const Color(0xFFB98BFF),
        SessionState.error      => const Color(0xFFE66B6B),
      };
}

/// A small glass pill: a state-coloured dot and a soft label. Never a banner.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.state, required this.label});
  final SessionState state;
  final String label;
  @override
  Widget build(BuildContext context) => Frosted(
        borderRadius: BorderRadius.circular(Glass.rPill),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: Motion.quick, curve: Motion.curve,
            width: 7, height: 7,
            decoration: BoxDecoration(color: state.dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      );
}

// ─── INPUT ──────────────────────────────────────────────────────────────────
/// The translucent text capsule with its send button.
class PromptCapsule extends StatelessWidget {
  const PromptCapsule({super.key, required this.controller, required this.onSend, this.hint = 'Say something, or type', this.onTap});
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onTap;
  final String hint;
  @override
  Widget build(BuildContext context) => Frosted(
        borderRadius: BorderRadius.circular(Glass.rBar),
        padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white70,
              decoration: InputDecoration(
                isDense: true, border: InputBorder.none,
                hintText: hint, hintStyle: const TextStyle(color: Colors.white38),
              ),
              onTap: onTap,
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 6),
          RoundButton(icon: Icons.arrow_upward_rounded, fg: Colors.white, bg: const Color(0x33FFFFFF), onTap: onSend, size: 32),
        ]),
      );
}

// ─── CHROME THAT AUTO-HIDES ─────────────────────────────────────────────────
/// Wraps floating chrome so it fades out after [Motion.chromeIdle] and returns on tap.
/// At rest there is a face and nothing else — this single behaviour is most of what
/// makes the surface feel elegant rather than like a harness.
class AutoHidingChrome extends StatefulWidget {
  const AutoHidingChrome({super.key, required this.child, required this.body});
  /// The full-bleed content underneath (the avatar).
  final Widget body;
  /// The chrome that fades.
  final Widget child;
  @override
  State<AutoHidingChrome> createState() => AutoHidingChromeState();
}

class AutoHidingChromeState extends State<AutoHidingChrome> {
  bool _visible = true;
  /// Whether the chrome is currently shown (measurement runs read it).
  bool get visible => _visible;
  Timer? _t;
  void poke() {
    _t?.cancel();
    if (!_visible) setState(() => _visible = true);
    _t = Timer(Motion.chromeIdle, () { if (mounted) setState(() => _visible = false); });
  }
  @override
  void initState() { super.initState(); poke(); }
  @override
  void dispose() { _t?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: poke,
        // A borderless window has no titlebar to grab: a drag on the picture moves it.
        // No-op where there is no window; the surface does not know which it is on.
        onPanStart: (_) => WindowChrome.startDrag(),
        child: Stack(fit: StackFit.expand, children: [
          widget.body,
          AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: Motion.surface, curve: Motion.curve,
            child: IgnorePointer(ignoring: !_visible, child: widget.child),
          ),
          // Never fades, never hides: a build that does not behave like the product says so.
          const MeasurementBanner(),
        ]),
      );
}

/// ★A MEASUREMENT BUILD MUST SAY ON SCREEN THAT IT IS ONE.
///
/// Twice on 2026-09-16 the owner watched our own instrumentation and reported it as a
/// product defect. The iPhone FLOORS probe paints a black screen by construction and he
/// filed "black screen". A macOS arm ran the stress driver — which by design requests the
/// next monologue after every completed response — and he filed "after the agent finishes
/// talking it keeps self talking on and on", which is a literal description of the
/// driver's rule. Both builds were doing exactly what they were told. Neither said so.
///
/// The instruments that were supposed to settle it could not: a `strings` scan of the
/// Mach-O cannot see a Flutter dart-define (they live in the AOT snapshot), so the only
/// record of what a build was doing was its BUILD LOG, on a different machine, in a
/// different lane's directory. The screen in front of the person is the right place.
///
/// Costs a release build nothing: every lever below is `DevLevers.enabled && ...` with
/// `enabled = !kReleaseMode`, a compile-time constant, so `_active` folds to `false` and
/// the whole widget is eliminated.
class MeasurementBanner extends StatelessWidget {
  const MeasurementBanner({super.key});

  /// The levers that make the app BEHAVE unlike the product — the ones that get
  /// misread. A verbose log or a frame counter changes nothing anyone can hear or see.
  static List<String> get _on => [
        if (DevLevers.stress) 'SELF-DRIVING (monologues on its own)',
        if (DevLevers.micFile.isNotEmpty) 'VOICE INJECTED INTO THE MIC',
        if (DevLevers.greeting) 'GREETS UNPROMPTED',
        if (DevLevers.transport.isNotEmpty) 'TRANSPORT=${DevLevers.transport}',
        if (DevLevers.wsUrl.isNotEmpty) 'MOCK SERVER',
      ];

  @override
  Widget build(BuildContext context) {
    final on = _on;
    if (on.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: const Color(0xCCB3261E),
          child: Text(
            'MEASUREMENT BUILD — NOT THE PRODUCT\n${on.join('  ·  ')}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white, fontSize: 11, height: 1.35,
              fontWeight: FontWeight.w600, letterSpacing: 0.3),
          ),
        ),
      ),
    );
  }
}

// ─── WINDOW (macOS) ─────────────────────────────────────────────────────────
/// The macOS window: borderless glass chrome and the floating-circle companion.
/// Backed by the plugin's `ai.bithuman.window` channel (macos/Classes/WindowChrome.swift);
/// every call is a harmless no-op where there is no such window (iOS, Android).
abstract final class WindowChrome {
  static const _ch = MethodChannel('ai.bithuman.window');
  static bool get _hasWindow => !kIsWeb && Platform.isMacOS;

  /// Make the window borderless: edge-to-edge canvas, rounded corners, traffic lights
  /// on hover. Call once the first frame is up (the plugin binds to the window then).
  static Future<void> attach() async {
    if (!_hasWindow) return;
    try { await _ch.invokeMethod<void>('configure'); } catch (_) {/* no native side */}
  }

  /// Drag-anywhere: hand a pan-start to the window so it rides the mouse.
  static void startDrag() {
    if (!_hasWindow) return;
    unawaited(_ch.invokeMethod<void>('startDrag').catchError((_) {}));
  }

  /// Collapse to the always-on-top circle at the lower-right (Glass.bubbleSize).
  /// Swap the Flutter tree to a [BubbleView] FIRST so the shrink never shows the
  /// square layout.
  static Future<void> enterBubble({double size = Glass.bubbleSize}) async {
    if (!_hasWindow) return;
    try { await _ch.invokeMethod<void>('enterBubble', {'size': size}); } catch (_) {}
  }

  /// Restore the window the companion collapsed from.
  static Future<void> exitBubble() async {
    if (!_hasWindow) return;
    try { await _ch.invokeMethod<void>('exitBubble'); } catch (_) {}
  }
}

/// The whole UI while the window is the small floating circle: the live avatar
/// clipped to a circle, a thin state ring on the rim, dim + expand glyph on hover.
/// Click (not drag) restores; the whole bubble is a drag region. The SAME component
/// on every surface — the circle is the layout, the window is what changes size.
class BubbleView extends StatefulWidget {
  const BubbleView({
    super.key,
    required this.child,
    required this.state,
    required this.onRestore,
    this.canvasWidth = 0,
    this.canvasHeight = 0,
    this.characterAlignmentX = 0,
  });
  /// The avatar texture. Shown full-height, centred on the character, cropped to the circle.
  final Widget child;
  final SessionState state;
  final VoidCallback onRestore;
  final double canvasWidth;
  final double canvasHeight;
  final double characterAlignmentX;
  @override
  State<BubbleView> createState() => _BubbleViewState();
}

class _BubbleViewState extends State<BubbleView> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        // The native window is a transparent circle — paint nothing outside it.
        backgroundColor: Colors.transparent,
        body: Center(
          child: LayoutBuilder(builder: (context, c) {
            final s = math.min(c.maxWidth, c.maxHeight);
            return GestureDetector(
              onTap: widget.onRestore,
              onPanStart: (_) => WindowChrome.startDrag(),
              child: MouseRegion(
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: SizedBox(
                  width: s, height: s,
                  child: Stack(fit: StackFit.expand, children: [
                    ClipOval(
                      child: widget.canvasWidth > 0 && widget.canvasHeight > 0
                          ? _HeadCrop(
                              canvasWidth: widget.canvasWidth,
                              canvasHeight: widget.canvasHeight,
                              size: s,
                              characterAlignmentX: widget.characterAlignmentX,
                              child: widget.child)
                          : widget.child,
                    ),
                    IgnorePointer(
                      child: AnimatedContainer(
                        duration: Motion.surface, curve: Motion.curve,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: widget.state.dot, width: 2),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: Motion.quick,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Color(0x66000000)),
                          child: Center(child: Icon(Icons.open_in_full_rounded, color: Colors.white, size: 28)),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          }),
        ),
      );
}

/// The head band of the canvas, scaled to fill the circle (from jarvis's
/// `_BubbleHeadCrop`): a portrait canvas keeps its top 38% below 5% of headroom, a
/// landscape (essence-2) canvas its top 80% below 4%, centred on the character.
class _HeadCrop extends StatelessWidget {
  const _HeadCrop({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.size,
    required this.characterAlignmentX,
    required this.child,
  });
  final double canvasWidth, canvasHeight, size, characterAlignmentX;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final portrait = canvasHeight > canvasWidth;
    final cropH = (portrait ? 0.38 : 0.80) * canvasHeight; // band height (canvas px)
    final cropTop = (portrait ? 0.05 : 0.04) * canvasHeight; // headroom skipped
    final scale = size / cropH;
    final w = canvasWidth * scale;
    // Horizontal: centre the character (alignment −1..1 across the scaled width).
    final dx = -(w - size) / 2 - characterAlignmentX * (w - size) / 2;
    return OverflowBox(
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      alignment: Alignment.topLeft,
      child: Transform.translate(
        offset: Offset(dx, -cropTop * scale),
        child: SizedBox(width: w, height: canvasHeight * scale, child: child),
      ),
    );
  }
}
