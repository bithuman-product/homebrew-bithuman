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
    test('maps a full elevate-catalog-v1 row', () {
      final e = Essence2CatalogEntry.fromJson('A63GVG1577', const {
        'agent_id': 'A63GVG1577',
        'url':
            'https://models.bithuman.ai/elevate/A63GVG1577/A63GVG1577-elevatedir-v3-148709eb.tar.gz',
        'sha256':
            '148709EB12F068F6A4D1956E53C1FE533F5A039EE8C0760DF07D6F8520423AA8',
        'size': 227511949,
        'format_version': 'elevatedir-v3',
      });
      expect(e.agentId, 'A63GVG1577');
      expect(e.url, contains('A63GVG1577-elevatedir-v3-148709eb.tar.gz'));
      // SHA-256 is normalised to lowercase so the shasum comparison is exact.
      expect(e.sha256,
          '148709eb12f068f6a4d1956e53c1fe533f5a039ee8c0760df07d6f8520423aa8');
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
