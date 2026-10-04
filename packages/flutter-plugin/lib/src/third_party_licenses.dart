// The third-party licences of the on-device brain, registered with Flutter's
// LicenseRegistry so every app's licence page (showLicensePage, AboutDialog,
// AboutListTile) lists them without the app doing anything.
//
// The texts are the upstream files, byte for byte, under `licenses/` in this
// package (declared as assets in pubspec.yaml). `licenses/SOURCES.md` says where
// each one was taken from, at which revision, on which date, and its SHA-256;
// test/third_party_licenses_test.dart fails if a file no longer matches. The two
// files bitHuman wrote — the Supertonic modification notice and the Parakeet
// attribution — are notices, not licences.
//
// Registration runs at app start: pubspec.yaml names [BithumanLicenses] as the
// plugin's `dartPluginClass` on Android, iOS and macOS, so Flutter's generated
// plugin registrant calls [BithumanLicenses.registerWith] before `main`.
// `LocalConverseTransport.start` calls [BithumanLicenses.register] as well, and
// an app may call it itself; it registers once.
//
// This file imports Flutter only: the voice module (realtime_transport.dart)
// and the render module (bithuman.dart) both export it.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One component's licence files, shown under [packages] on the licence page.
class BithumanThirdPartyLicense {
  const BithumanThirdPartyLicense(this.packages, this.files);

  /// The names the licence page lists the files under.
  final List<String> packages;

  /// Paths of the files inside this package, e.g. `licenses/silero-vad/LICENSE`,
  /// in the order they are shown.
  final List<String> files;
}

/// The licences of the code and models the on-device brain uses (LOCAL mode and
/// the hybrid brain): see `THIRD_PARTY_NOTICES.md` for which build carries what.
class BithumanLicenses {
  BithumanLicenses._();

  /// The package that owns the licence assets.
  static const String assetPackage = 'bithuman';

  /// The Supertonic 3 licence (BigScience Open RAIL-M); its Attachment A holds the
  /// use restrictions an app's terms must include (paragraph 4(a)).
  static const String supertonicLicenseFile = 'licenses/supertonic-3/LICENSE';

  /// What was changed in the Supertonic 3 files the brain runs (paragraph 4(c)).
  static const String supertonicModificationsFile = 'licenses/supertonic-3/MODIFICATIONS.txt';

  /// Every licence the plugin registers, in licence-page order.
  static const List<BithumanThirdPartyLicense> all = [
    // Models the brain runs (downloaded by the app).
    BithumanThirdPartyLicense(['Supertonic 3 (voice model)'], [supertonicModificationsFile, supertonicLicenseFile]),
    BithumanThirdPartyLicense(['Parakeet TDT-CTC 110M (speech-to-text model)'],
        ['licenses/parakeet-tdt_ctc-110m/ATTRIBUTION.txt', 'licenses/parakeet-tdt_ctc-110m/LICENSE']),
    BithumanThirdPartyLicense(['Silero VAD'], ['licenses/silero-vad/LICENSE']),
    BithumanThirdPartyLicense(['Llama 3.2 (LOCAL mode language model)'],
        ['licenses/llama-3.2/LICENSE', 'licenses/llama-3.2/USE_POLICY.md']),
    // Code linked into the app.
    BithumanThirdPartyLicense(['Supertonic (inference code)'], ['licenses/supertonic/LICENSE']),
    BithumanThirdPartyLicense(['sherpa-onnx'], ['licenses/sherpa-onnx/LICENSE']),
    BithumanThirdPartyLicense(['kaldi-native-fbank'], ['licenses/kaldi-native-fbank/LICENSE']),
    BithumanThirdPartyLicense(['KISS FFT'], ['licenses/kissfft/COPYING', 'licenses/kissfft/BSD-3-Clause']),
    BithumanThirdPartyLicense(['kaldi-decoder'], ['licenses/kaldi-decoder/LICENSE']),
    BithumanThirdPartyLicense(['kaldifst'], ['licenses/kaldifst/LICENSE']),
    BithumanThirdPartyLicense(['OpenFst'], ['licenses/openfst/COPYING']),
    BithumanThirdPartyLicense(['simple-sentencepiece'], ['licenses/simple-sentencepiece/LICENSE']),
    BithumanThirdPartyLicense(['Eigen'], ['licenses/eigen/COPYING.MPL2']),
    BithumanThirdPartyLicense(['hclust-cpp (fastcluster)'], ['licenses/hclust-cpp/LICENSE']),
    BithumanThirdPartyLicense(['nlohmann/json'],
        ['licenses/nlohmann-json/LICENSE.MIT-3.12.0', 'licenses/nlohmann-json/LICENSE.MIT-3.11.3']),
    BithumanThirdPartyLicense(['ONNX Runtime'], ['licenses/onnxruntime/LICENSE', 'licenses/onnxruntime/ThirdPartyNotices.txt']),
    BithumanThirdPartyLicense(['llama.cpp'], ['licenses/llama.cpp/LICENSE']),
    BithumanThirdPartyLicense(['miniaudio'], ['licenses/miniaudio/LICENSE']),
  ];

  static bool _registered = false;

  /// Whether [register] has run in this isolate.
  static bool get registered => _registered;

  /// The `dartPluginClass` hook: Flutter's plugin registrant calls this at app
  /// start. Never throws.
  static void registerWith() {
    try {
      register();
    } catch (_) {
      // A licence page that misses these entries must never stop an app from starting.
    }
  }

  /// Adds the licences to [LicenseRegistry] (once; later calls do nothing). The
  /// files are read only when a licence page asks for them.
  static void register() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(_collect);
  }

  static Stream<LicenseEntry> _collect() async* {
    for (final licence in all) {
      for (final file in licence.files) {
        String text;
        try {
          text = await loadText(file);
        } catch (_) {
          // An asset that cannot be read (a build that strips assets) still names where the text lives.
          text = 'The text of this licence ships with the bithuman Flutter plugin as $file.';
        }
        yield LicenseEntryWithLineBreaks(licence.packages, text);
      }
    }
  }

  /// The text of one licence file (a path from [all]), exactly as shipped (a
  /// leading byte-order mark dropped).
  static Future<String> loadText(String file, {AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    String text;
    try {
      // How an app sees a dependency's asset.
      text = await b.loadString('packages/$assetPackage/$file', cache: false);
    } catch (_) {
      // How the plugin's own tests see it (this package is then the root package).
      text = await b.loadString(file, cache: false);
    }
    return text.startsWith('﻿') ? text.substring(1) : text;
  }

  /// Attachment A of the Supertonic 3 licence — the use restrictions — verbatim,
  /// from its heading to the end of the licence. OpenRAIL-M paragraph 4(a): an app
  /// that ships the on-device voice must include these as an enforceable provision
  /// of the agreement that governs its use (its terms of use / EULA) and tell its
  /// users the voice is subject to them. Show or link this text from the app's terms.
  static Future<String> supertonicAttachmentA({AssetBundle? bundle}) async {
    final text = await loadText(supertonicLicenseFile, bundle: bundle);
    final at = text.indexOf('\nAttachment A\n');
    if (at < 0) throw StateError('$supertonicLicenseFile has no Attachment A');
    return text.substring(at + 1);
  }
}
