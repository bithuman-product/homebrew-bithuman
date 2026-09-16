// Unit tests for the Essence-2 (Elevate) `.elevatedir` catalog parsing.
//
// Covers Essence2CatalogEntry.fromJson — the pure mapping from an
// `elevate-catalog-v1` agent row onto the typed entry the app routes on
// (fetchEssence2Catalog wraps this after an https + host-allowlist fetch, and
// downloadEssence2Bundle consumes it). No network / Process here.
//
// Apache-2.0; (c) bitHuman.

import 'package:bithuman/bithuman.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Essence2CatalogEntry.fromJson', () {
    // The row below is SYNTHETIC on purpose, like the two tests under it.
    // fromJson is a pure map->object mapping: nothing here is fetched, so a
    // real delivery URL would buy no coverage and would rot on the next
    // catalog rotation. It did: this fixture carried a real A63GVG1577
    // elevatedir-v3 URL and digest that went 404 when the catalog moved on,
    // leaving a public repo citing a dead artifact. Keep it fake.
    test('maps a full elevate-catalog-v1 row', () {
      final e = Essence2CatalogEntry.fromJson('A00EXAMPLE', const {
        'agent_id': 'A00EXAMPLE',
        'url':
            'https://models.bithuman.ai/elevate/A00EXAMPLE/A00EXAMPLE-elevatedir-v3-0123abcd.tar.gz',
        'sha256':
            '0123ABCD4567EF89012345678901234567890123456789012345678901234567',
        'size': 227511949,
        'format_version': 'elevatedir-v3',
      });
      expect(e.agentId, 'A00EXAMPLE');
      expect(e.url, contains('A00EXAMPLE-elevatedir-v3-0123abcd.tar.gz'));
      // SHA-256 is normalised to lowercase so the shasum comparison is exact.
      expect(e.sha256,
          '0123abcd4567ef89012345678901234567890123456789012345678901234567');
      expect(e.size, 227511949);
      expect(e.formatVersion, 'elevatedir-v3');
    });

    test('falls back to the map key when agent_id is missing/empty', () {
      final e = Essence2CatalogEntry.fromJson('AXYZ', const {
        'agent_id': '',
        'url': 'https://models.bithuman.ai/elevate/AXYZ/x.tar.gz',
      });
      expect(e.agentId, 'AXYZ');
    });

    test('tolerates a size-less / format-less row', () {
      final e = Essence2CatalogEntry.fromJson('AXYZ', const {
        'url': 'https://models.bithuman.ai/elevate/AXYZ/x.tar.gz',
        'sha256': 'abc',
      });
      expect(e.size, 0);
      expect(e.formatVersion, '');
      expect(e.sha256, 'abc');
    });
  });
}
