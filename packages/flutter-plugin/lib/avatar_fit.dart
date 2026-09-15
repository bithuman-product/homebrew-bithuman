// Aspect-aware avatar canvas fit — the FULL canvas is ALWAYS visible.
//
// Policy: BoxFit.contain, never cover. The canvas aspect varies per identity
// (the frameSize channel reports it — e.g. elevate's 720x1280 portrait,
// essence's 1248x704 landscape) and the viewport aspect varies per device
// and per moment (fold/unfold, rotation, macOS free-form resize, fullscreen).
// Cover crops whichever axis overflows — on near-square displays (fold inner
// screens) that cut the head and the bottom of a portrait canvas. Contain
// letterboxes instead; the bars carry the app's dark radial backdrop (the
// same gradient as the pre-load canvas) so they read as design, not dead
// space. Never stretch, never crop.
import 'package:flutter/material.dart';

class AvatarCanvasFit extends StatelessWidget {
  const AvatarCanvasFit({
    super.key,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.child,
  });

  /// Engine-reported frame size (canvas px) — the box the child is scaled
  /// from, so the child always renders at the canvas aspect ratio.
  final double canvasWidth;
  final double canvasHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          radius: 0.9,
          colors: [Color(0xFF1A1A1F), Color(0xFF050505)],
        ),
      ),
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: canvasWidth,
          height: canvasHeight,
          child: child,
        ),
      ),
    );
  }
}
