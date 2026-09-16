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
//   PHONE, any frame  ★FILL THE SCREEN. Whichever axis overflows is cropped, anchored
//                    on the character. Phones are portrait-only for character
//                    rendering, so a landscape canvas is cropped rather than rotated.
//
//     PORTRAIT frame (expression-2's 416x720) — this rule was "fit to width, residual
//     above and below" until 2026-09-16, described as "reads as full screen with
//     nothing cut". Measured on the Galaxy S25+ (1080x2340) it does not: the frame
//     scales to 1080x1869 and leaves 20% of the display as two black bands, the
//     chrome sitting in the lower one — exactly the "buttons at the bottom, not full
//     screen" the owner reported. The iPhone 15 (393x852) gets the same 20%. Cover
//     costs 20% of the frame's WIDTH (10% each side, background not character for a
//     centred head-and-shoulders) and nothing of its height. Same trade as the
//     landscape rule below, so it is now one rule.
//
//     LANDSCAPE frame (essence-2's 1248x704) — contain would leave 74% of the screen
//     empty, 393x222 of an 852-point screen, which is not a product.
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
        // The single ruled decision: a PHONE fills its screen; a desktop never crops.
        // On a phone every frame is cover-fit. A portrait frame that is wider in aspect
        // than the phone (expression-2's 0.578 vs 0.461) overflows horizontally and
        // loses ~10% per side; a landscape frame overflows a lot more. Both are anchored
        // on the character. `viewAspect < 1.0` keeps a phone in a landscape window
        // (a tablet, a test harness) on the contain rule rather than cropping a
        // portrait model's head off.
        final crop = surface == AvatarSurface.phone && viewAspect < 1.0;
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
