import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/widgets/edge_dock.dart';

/// Mounts a dock of a known size inside a 400x800 stack.
Future<List<(bool, double)>> _pump(
  WidgetTester tester, {
  bool left = true,
  double y = 0,
}) async {
  final moves = <(bool, double)>[];
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.black)),
        EdgeDock(
          left: left,
          y: y,
          onMoved: (l, ny) => moves.add((l, ny)),
          builder: (_, isLeft, __) => Container(
            key: const ValueKey('dock'),
            width: 30,
            height: 50,
            color: isLeft ? Colors.red : Colors.blue,
          ),
        ),
      ],
    ),
  ));
  await tester.pumpAndSettle();
  return moves;
}

Finder get _dock => find.byKey(const ValueKey('dock'));

void main() {
  testWidgets('parks flush against the left edge, vertically centred',
      (tester) async {
    await _pump(tester);
    final r = tester.getRect(_dock);
    expect(r.left, 0);
    expect(r.center.dy, moreOrLessEquals(400, epsilon: 0.5));
  });

  testWidgets('parks flush against the right edge when told to',
      (tester) async {
    await _pump(tester, left: false);
    expect(tester.getRect(_dock).right, 400);
  });

  // The whole point of an alignment-based position: the dock cannot be parked
  // half off-screen, however tall it is.
  testWidgets('an extreme y still leaves the dock fully on screen',
      (tester) async {
    await _pump(tester, y: 1);
    final r = tester.getRect(_dock);
    expect(r.bottom, moreOrLessEquals(800, epsilon: 0.5));
    expect(r.top, greaterThanOrEqualTo(0));
  });

  testWidgets('a long press and drag moves it vertically and reports once',
      (tester) async {
    final moves = await _pump(tester);

    final gesture = await tester.startGesture(tester.getCenter(_dock));
    await tester.pump(const Duration(milliseconds: 600)); // long press fires
    await gesture.moveTo(const Offset(20, 700));
    await tester.pump();

    // It follows the finger before the release, not after.
    expect(tester.getRect(_dock).center.dy, greaterThan(600));
    expect(moves, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, hasLength(1));
    expect(moves.single.$1, isTrue, reason: 'still on the left half');
    expect(moves.single.$2, greaterThan(0.5));
  });

  testWidgets('dragging past the middle switches sides', (tester) async {
    final moves = await _pump(tester);

    final gesture = await tester.startGesture(tester.getCenter(_dock));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(380, 400));
    await tester.pump();

    expect(tester.getRect(_dock).right, 400, reason: 'snapped to the right');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(moves.single.$1, isFalse);
  });

  // A plain tap has to keep reaching the panel's own buttons; only a long
  // press picks the dock up.
  testWidgets('a short tap does not move the dock', (tester) async {
    final moves = await _pump(tester);
    await tester.tapAt(tester.getCenter(_dock));
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
    expect(tester.getRect(_dock).left, 0);
  });
}
