// The on-device brain's third-party licences: the files are the upstream bytes
// (licenses/SOURCES.md), every one is a declared asset, the plugin registers
// them with Flutter's LicenseRegistry (dartPluginClass + LocalConverseTransport),
// and Attachment A of the Supertonic 3 licence can be read out for an app's terms.

import 'dart:io';

import 'package:bithuman/realtime_transport.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pubspec = File('pubspec.yaml').readAsStringSync();
  final allFiles = [for (final l in BithumanLicenses.all) ...l.files];

  test('every licence file exists and every upstream copy matches its SHA-256 in SOURCES.md', () {
    final sources = File('licenses/SOURCES.md').readAsStringSync();
    final rows = RegExp(r'^\| `([^`]+)` \| `([0-9a-f]{64})` \|', multiLine: true).allMatches(sources);
    final hashes = {for (final m in rows) 'licenses/${m.group(1)}': m.group(2)};
    expect(hashes, isNotEmpty);
    // Every file on disk is either an upstream copy with a row or one of the two notices bitHuman wrote.
    const notices = {'licenses/supertonic-3/MODIFICATIONS.txt', 'licenses/parakeet-tdt_ctc-110m/ATTRIBUTION.txt'};
    final onDisk = Directory('licenses')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.replaceAll(r'\', '/'))
        .where((p) => p != 'licenses/SOURCES.md')
        .toSet();
    expect(onDisk, {...hashes.keys, ...notices});
    for (final e in hashes.entries) {
      expect(sha256.convert(File(e.key).readAsBytesSync()).toString(), e.value, reason: '${e.key} is not the upstream file');
    }
    // The registry lists exactly the files on disk.
    expect(allFiles.toSet(), onDisk);
    expect(allFiles.length, onDisk.length, reason: 'a file is registered twice');
  });

  test('every licence directory is a declared asset, and the plugin registers at app start on every platform', () {
    final declared = RegExp(r'^    - (licenses/[^\s]+/)$', multiLine: true).allMatches(pubspec).map((m) => m.group(1)).toSet();
    final needed = allFiles.map((f) => f.substring(0, f.lastIndexOf('/') + 1)).toSet();
    expect(declared, needed);
    expect(RegExp(r'^        dartPluginClass: BithumanLicenses$', multiLine: true).allMatches(pubspec).length, 3,
        reason: 'android, ios and macos each name BithumanLicenses as the dartPluginClass');
  });

  test('register adds every file to LicenseRegistry once, under its component name', () async {
    LicenseRegistry.reset(); // drop the test binding's own NOTICES collector
    expect(BithumanLicenses.registered, isFalse);
    BithumanLicenses.registerWith(); // what the generated plugin registrant calls
    BithumanLicenses.register(); // what LocalConverseTransport.start calls: no second copy
    expect(BithumanLicenses.registered, isTrue);

    final entries = await LicenseRegistry.licenses.toList();
    expect(entries.length, allFiles.length);
    final byPackage = <String, List<String>>{};
    for (final e in entries) {
      final text = e.paragraphs.map((p) => p.text).join('\n');
      expect(text, isNot(startsWith('The text of this licence ships with')), reason: 'an asset did not load');
      for (final p in e.packages) {
        byPackage.putIfAbsent(p, () => []).add(text);
      }
    }
    for (final l in BithumanLicenses.all) {
      expect(byPackage[l.packages.single]?.length, l.files.length, reason: l.packages.single);
    }
    final supertonic = byPackage['Supertonic 3 (voice model)']!.join('\n');
    expect(supertonic, contains('NOTICE OF MODIFIED FILES'));
    expect(supertonic, contains('BigScience Open RAIL-M License'));
    expect(supertonic, contains('Attachment A'));
    final parakeet = byPackage['Parakeet TDT-CTC 110M (speech-to-text model)']!.join('\n');
    expect(parakeet, contains('Creative Commons Attribution 4.0 International'));
    expect(parakeet, contains('int8'));
    expect(byPackage['Silero VAD']!.single, contains('MIT License'));
    expect(byPackage['sherpa-onnx']!.single, contains('Apache License'));
    expect(byPackage['ONNX Runtime']!.first, contains('MIT License'));
  });

  test('loadText returns the shipped bytes and supertonicAttachmentA is the licence from its heading to the end', () async {
    final licence = File(BithumanLicenses.supertonicLicenseFile).readAsStringSync();
    expect(await BithumanLicenses.loadText(BithumanLicenses.supertonicLicenseFile), licence);
    final a = await BithumanLicenses.supertonicAttachmentA();
    expect(a, startsWith('Attachment A\n'));
    expect(licence.endsWith(a), isTrue);
    expect(a, contains('Use Restrictions'));
    expect(a, contains('You agree not to use the Model or Derivatives of the Model'));
  });
}
