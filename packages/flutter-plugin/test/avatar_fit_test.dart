// The fit policy is graded on GEOMETRY, not on a sentence. Each arm lays the canvas
// out in a real viewport and reads back the painted rect of the child, so "fills the
// screen" and "never crops" are numbers a change cannot reword.
import 'package:bithuman/avatar_fit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _marker = Key('canvas');

Future<Rect> _paint(WidgetTester t, {
  required Size view, required Size canvas, required AvatarSurface surface,
}) async {
  await t.binding.setSurfaceSize(view);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: SizedBox(
    width: view.width, height: view.height,
    child: AvatarCanvasFit(
      canvasWidth: canvas.width, canvasHeight: canvas.height, surface: surface,
      child: const SizedBox.expand(key: _marker),
    ),
  )));
  final box = t.renderObject<RenderBox>(find.byKey(_marker));
  final origin = box.localToGlobal(Offset.zero);
  // The painted size is the transformed size: read it from the global rect of the
  // box's corners rather than box.size, which is the untransformed canvas.
  final far = box.localToGlobal(Offset(box.size.width, box.size.height));
  return Rect.fromPoints(origin, far);
}

void main() {
  // expression-2's frame and the two phones the owner tests on, in logical px.
  const x2 = Size(416, 720);
  const e2 = Size(1248, 704);
  const galaxy = Size(1080 / 2.8125, 2340 / 2.8125); // S25+ at 450 dpi ≈ 384x832
  const iphone = Size(393, 852);

  for (final (name, phone) in [('Galaxy S25+', galaxy), ('iPhone 15', iphone)]) {
    testWidgets('$name: a portrait frame FILLS the screen — no band above or below', (t) async {
      final r = await _paint(t, view: phone, canvas: x2, surface: AvatarSurface.phone);
      // Height is covered exactly; width overflows and is clipped, never short.
      expect(r.top, closeTo(0, 0.5));
      expect(r.bottom, closeTo(phone.height, 0.5));
      expect(r.width, greaterThanOrEqualTo(phone.width));
      // And the overflow is modest: at most 25% of the frame's width is off-screen,
      // which for a centred head-and-shoulders is background, not character.
      expect((r.width - phone.width) / r.width, lessThan(0.25));
    });

    testWidgets('$name: a landscape frame FILLS the screen, cropping the sides', (t) async {
      final r = await _paint(t, view: phone, canvas: e2, surface: AvatarSurface.phone);
      expect(r.top, closeTo(0, 0.5));
      expect(r.bottom, closeTo(phone.height, 0.5));
      expect(r.width, greaterThan(phone.width));
    });
  }

  testWidgets('desktop: never cropped — the whole frame is inside the window', (t) async {
    const win = Size(600, 600);
    for (final canvas in [x2, e2]) {
      final r = await _paint(t, view: win, canvas: canvas, surface: AvatarSurface.desktop);
      expect(r.left, greaterThanOrEqualTo(-0.5));
      expect(r.top, greaterThanOrEqualTo(-0.5));
      expect(r.right, lessThanOrEqualTo(win.width + 0.5));
      expect(r.bottom, lessThanOrEqualTo(win.height + 0.5));
    }
  });

  testWidgets('a phone in a LANDSCAPE viewport falls back to contain — a portrait head is never cropped off', (t) async {
    const wide = Size(852, 393);
    final r = await _paint(t, view: wide, canvas: x2, surface: AvatarSurface.phone);
    expect(r.top, greaterThanOrEqualTo(-0.5));
    expect(r.bottom, lessThanOrEqualTo(wide.height + 0.5));
  });

  // ★The control: the OLD rule must FAIL the new grade, or the grade cannot see the
  // defect it was written for. Contain on the Galaxy leaves ~20% of the height black.
  testWidgets('control: BoxFit.contain on the Galaxy leaves a band (the defect the rule fixes)', (t) async {
    await t.binding.setSurfaceSize(galaxy);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(home: SizedBox(
      width: galaxy.width, height: galaxy.height,
      child: FittedBox(fit: BoxFit.contain, child: SizedBox(
        width: x2.width, height: x2.height, child: const SizedBox.expand(key: _marker))),
    )));
    final box = t.renderObject<RenderBox>(find.byKey(_marker));
    final r = Rect.fromPoints(box.localToGlobal(Offset.zero),
        box.localToGlobal(Offset(box.size.width, box.size.height)));
    final band = (galaxy.height - r.height) / galaxy.height;
    expect(band, greaterThan(0.15), reason: 'contain must show the ~20% band, or the arms above grade nothing');
  });
}
