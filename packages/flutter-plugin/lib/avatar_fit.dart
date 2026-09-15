// Aspect-aware avatar canvas fit — ONE enforcement point for the whole estate.
//
// ★The fit is a POLICY COMPUTED HERE from the platform and the loaded frame's aspect.
// It is deliberately NOT a parameter: a caller cannot choose to crop where cropping is
// not the ruled behaviour, and cannot choose to letterbox where the owner asked for a
// filled phone screen. The rule lives in one place because it applies to three surfaces
// and two models.
//
// THE RULES, as ruled 2026-09-15:
//
//   macOS            never cropped, whole frame visible, in a window at the avatar's
//                    own resolution. A desktop window can be any shape, so there is
//                    never a reason to cut the picture.
//
//   PHONE, PORTRAIT frame (expression-2's 416x720)
//                    fit to width, whole frame visible, residual above and below. The
//                    residual is where the translucent chrome lives, so the result
//                    reads as full screen with nothing cut.
//
//   PHONE, LANDSCAPE frame (essence-2's 1248x704)
//                    ★FILL THE SCREEN AND CROP THE SIDES. Contain would leave 74% of
//                    the screen empty — 393x222 of an 852-point screen — which is not a
//                    product. Phones are portrait-only for character rendering, so a
//                    landscape canvas is cropped rather than rotated.
//
// WHAT THE CROP COSTS, arithmetic on the real metrics rather than a promise:
// essence-2 1248x704 on an iPhone 15's 393x852 needs scale 1.21 (driven by height),
// giving 1510x852 — so 393 of 1510 survives, about 26% of the frame's width, roughly
// 324 of the original 1248 pixels. That comfortably holds a head; it will cut shoulders
// and any background composition.
//
// ★THE CROP IS ANCHORED ON THE CHARACTER, NOT THE FRAME. `characterAlignmentX` says where
// the character sits horizontally (-1 left, 0 centre, +1 right). Centring the crop on the
// frame is only correct when the character is centred in it, which is an assumption about
// the identity rather than a property of the format — so it is passed in and defaults to
// centre.
import 'package:flutter/material.dart';

/// The surface this canvas is being shown on. Passed rather than sniffed so a test can
/// exercise every rule on one machine, and so macOS-in-a-phone-sized-window still
/// follows the macOS rule.
enum AvatarSurface { phone, desktop }

class AvatarCanvasFit extends StatelessWidget {
  const AvatarCanvasFit({
    super.key,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.child,
    required this.surface,
    this.characterAlignmentX = 0.0,
  });

  /// Engine-reported frame size (canvas px), read from the loaded avatar at runtime so
  /// a different model — or a different identity of the same model — lays out correctly
  /// with no code change.
  final double canvasWidth;
  final double canvasHeight;
  final Widget child;
  final AvatarSurface surface;

  /// Where the character sits in the frame horizontally: -1 left, 0 centre, +1 right.
  /// Only consulted when the ruled policy crops.
  final double characterAlignmentX;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          radius: 0.9,
          colors: [Color(0xFF1A1A1F), Color(0xFF050505)],
        ),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final canvasAspect = canvasWidth / canvasHeight;
        final viewAspect = (c.maxWidth.isFinite && c.maxHeight.isFinite && c.maxHeight > 0)
            ? c.maxWidth / c.maxHeight
            : canvasAspect;
        // The single ruled decision. Crop ONLY on a phone, and ONLY for a LANDSCAPE
        // canvas (aspect > 1). ★Not "wider in aspect than the screen": expression-2's
        // 416x720 (0.578) is ALSO wider than an iPhone's 393x852 (0.461), so that test
        // would have cropped 20% off the portrait model the owner has already approved
        // as fit-to-width. Landscape-vs-portrait is the distinction he actually drew —
        // essence-2 crops, expression-2 does not — and it does not depend on which phone.
        final crop = surface == AvatarSurface.phone && canvasAspect > 1.0 && viewAspect < 1.0;
        return FittedBox(
          fit: crop ? BoxFit.cover : BoxFit.contain,
          alignment: crop ? Alignment(characterAlignmentX, 0) : Alignment.center,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(width: canvasWidth, height: canvasHeight, child: child),
        );
      }),
    );
  }
}
