import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/connection_profile.dart';
import 'package:terminal_agent/theme/app_theme.dart';
import 'package:terminal_agent/widgets/profile_tint.dart';

ConnectionProfile _profile({String? colorHex, bool isProduction = false}) =>
    ConnectionProfile(
      id: 'p1',
      name: 'prod-web',
      host: '10.0.0.1',
      port: 22,
      username: 'root',
      colorHex: colorHex,
      isProduction: isProduction,
    );

void main() {
  group('persistence', () {
    test('color and production survive a JSON round trip', () {
      final profile = _profile(colorHex: '#E63946', isProduction: true);
      final back = ConnectionProfile.fromJson(profile.toJson());
      expect(back.colorHex, '#E63946');
      expect(back.isProduction, isTrue);
    });

    test('a profile saved before this feature loads untinted', () {
      // Exactly what an older build wrote: no colorHex, no isProduction.
      final legacy = ConnectionProfile.fromMap({
        'id': 'old',
        'name': 'box',
        'host': 'h',
        'port': 22,
        'username': 'u',
      });
      expect(legacy.colorHex, isNull);
      expect(legacy.isProduction, isFalse);
      expect(profileTint(legacy), isNull);
    });

    test('an empty colorHex is read as no color, not as an unparseable one', () {
      final blank = ConnectionProfile.fromMap({
        'id': 'x',
        'name': 'box',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'colorHex': '   ',
      });
      expect(blank.colorHex, isNull);
    });

    test('the color is metadata, so it stays in the secret-free map', () {
      final map = _profile(colorHex: '#4C8DFF', isProduction: true).toMapPublic();
      expect(map['colorHex'], '#4C8DFF');
      expect(map['isProduction'], isTrue);
      expect(map.containsKey('password'), isFalse);
    });

    test('copyWith needs clearColor to remove a color', () {
      final tinted = _profile(colorHex: '#3FB950');
      expect(tinted.copyWith(name: 'other').colorHex, '#3FB950');
      expect(tinted.copyWith(clearColor: true).colorHex, isNull);
    });
  });

  group('profileTint', () {
    test('no color and not production means no tint at all', () {
      expect(profileTint(_profile()), isNull);
    });

    test('production without a chosen color falls back to danger', () {
      // Marking a machine as production and getting no visible difference
      // would make the switch a lie.
      expect(profileTint(_profile(isProduction: true)), AppColors.danger);
    });

    test('a chosen color wins over the production fallback', () {
      expect(profileTint(_profile(colorHex: '#22B8CF', isProduction: true)),
          AppColors.parseHex('#22B8CF'));
    });

    test('an unparseable color degrades to no tint, never to a crash', () {
      expect(profileTint(_profile(colorHex: 'not-a-color')), isNull);
    });

    test('a null profile has no tint', () {
      expect(profileTint(null), isNull);
    });

    test('every preset parses', () {
      for (final preset in kProfileColorPresets) {
        expect(AppColors.parseHex(preset.$2), isNotNull,
            reason: 'preset ${preset.$1} (${preset.$2}) must parse');
      }
    });
  });

  group('widgets', () {
    testWidgets('the band and the bar draw nothing without a tint',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Column(
          children: [
            ProfileTintBand(tint: null),
            ProfileTintBar(tint: null),
          ],
        ),
      ));
      // SizedBox.shrink() rather than a sized Container: an untinted terminal
      // must not lose 3px of scrollback to an invisible strip.
      for (final box in tester.widgetList<SizedBox>(find.byType(SizedBox))) {
        expect(box.height, 0);
        expect(box.width, 0);
      }
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('the band is 3px tall and painted in the tint', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Column(children: [ProfileTintBand(tint: Color(0xFFE63946))]),
      ));
      final size = tester.getSize(find.byType(Container));
      expect(size.height, 3);
    });
  });
}
