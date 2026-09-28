import 'package:bithuman/realtime_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ai.bithuman.avatar');

  test('voice values', () {
    expect(LocalBrainVoice.isSystem(LocalBrainVoice.system), isTrue);
    expect(LocalBrainVoice.systemVoice('com.apple.voice.premium.en-US.Ava'),
        'system:com.apple.voice.premium.en-US.Ava');
    expect(LocalBrainVoice.isSystem(LocalBrainVoice.systemVoice('x')), isTrue);
    expect(LocalBrainVoice.isSystem(LocalBrainVoice.builtIn), isFalse);
    expect(LocalBrainVoice.isSystem(null), isFalse);
    expect(LocalBrainVoice.isSystem('systemic'), isFalse);
  });

  test('query parses the native list', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'localSystemVoices');
      expect((call.arguments as Map)['language'], 'en');
      return {
        'voices': [
          {'id': 'p', 'name': 'Ava (Premium)', 'language': 'en-US', 'quality': 'premium', 'gender': 'female', 'personal': false},
          {'id': 'd', 'name': 'Samantha', 'language': 'en-US', 'quality': 'default', 'gender': 'female', 'personal': false},
        ],
        'best': 'p',
        'personalVoice': 'notDetermined',
        'downloadSteps': 'steps',
      };
    });
    final sv = await SystemVoices.query();
    expect(sv.voices.length, 2);
    expect(sv.hasHighQuality, isTrue);
    expect(sv.best?.name, 'Ava (Premium)');
    expect(sv.best?.isHighQuality, isTrue);
    expect(sv.voices[1].isHighQuality, isFalse);
    expect(sv.personalVoice, 'notDetermined');
    expect(sv.downloadSteps, 'steps');
  });

  test('only compact voices: no best, use the built-in voice', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'voices': [
          {'id': 'd', 'name': 'Samantha', 'language': 'en-US', 'quality': 'default', 'gender': 'female', 'personal': false},
        ],
        'best': null,
        'personalVoice': 'denied',
        'downloadSteps': 'steps',
      };
    });
    final sv = await SystemVoices.query();
    expect(sv.hasHighQuality, isFalse);
    expect(sv.best, isNull);
  });

  test('a platform without the method: empty, never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final sv = await SystemVoices.query();
    expect(sv.voices, isEmpty);
    expect(sv.hasHighQuality, isFalse);
    expect(await SystemVoices.requestPersonalVoice(), 'unsupported');
    expect(await SystemVoices.openSettings(), isFalse);
  });
}
