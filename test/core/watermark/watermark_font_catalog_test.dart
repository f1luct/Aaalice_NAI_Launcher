import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/watermark/watermark_font_catalog.dart';
import 'package:nai_launcher/core/watermark/watermark_font_pack_manifest.dart';

void main() {
  test(
    'default font stays bundled while watermark pack fonts match source lock and licenses',
    () {
      expect(
        WatermarkFontCatalog.options.where((font) => font.isBundled).map(
          (font) => font.family,
        ),
        [WatermarkFontCatalog.defaultFamily],
      );
      expect(
        File('fonts/LXGWZhenKaiGB-Regular.ttf').existsSync(),
        isTrue,
      );
      expect(Directory('fonts/watermark').existsSync(), isFalse);

      expect(
        WatermarkFontCatalog.options.where((font) => font.supportsCjk).length,
        greaterThanOrEqualTo(3),
      );
      expect(
        WatermarkFontCatalog.options.where((font) => !font.supportsCjk).length,
        greaterThanOrEqualTo(3),
      );

      final manifest = WatermarkFontPackManifest.parse(
        File(watermarkFontPackManifestAsset).readAsStringSync(),
      );
      final downloadableFamilies = WatermarkFontCatalog.options
          .where((font) => !font.isBundled)
          .map((font) => font.family)
          .toList();
      expect(
        manifest.fonts.map((font) => font.family),
        orderedEquals(downloadableFamilies),
      );

      for (final asset in manifest.fonts) {
        final bytes = File(
          'tool/font_pack/fonts/${asset.fileName}',
        ).readAsBytesSync();
        expect(bytes.length, asset.size, reason: asset.fileName);
        expect(bytes.length, greaterThan(10000), reason: asset.fileName);
        expect(
          String.fromCharCodes(bytes.take(4)),
          anyOf('\u0000\u0001\u0000\u0000', 'OTTO'),
          reason: asset.fileName,
        );
        expect(
          sha256.convert(bytes).toString(),
          asset.sha256,
          reason: asset.fileName,
        );
      }

      for (final directory in const [
        'allura',
        'caveat',
        'great-vibes',
        'long-cang',
        'lxgw-zhenkai',
        'ma-shan-zheng',
        'zhi-mang-xing',
      ]) {
        final license = File('licenses/fonts/$directory/OFL.txt');
        final source = File('licenses/fonts/$directory/upstream_info.md');
        expect(license.readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
        expect(source.readAsStringSync(), contains('https://'));
      }
    },
  );
}
