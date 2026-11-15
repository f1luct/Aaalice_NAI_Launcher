import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/services/verified_resumable_downloader.dart';
import 'package:nai_launcher/core/watermark/watermark_font_catalog.dart';
import 'package:nai_launcher/core/watermark/watermark_font_pack_manifest.dart';
import 'package:nai_launcher/core/watermark/watermark_font_pack_service.dart';
import 'package:nai_launcher/core/watermark/watermark_render_service.dart';
import 'package:nai_launcher/data/models/watermark/watermark_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses locked font pack manifest and rejects untrusted entries', () {
    final raw = File(watermarkFontPackManifestAsset).readAsStringSync();
    final manifest = WatermarkFontPackManifest.parse(raw);

    expect(manifest.releaseTag, startsWith('watermark-fonts-'));
    expect(manifest.fonts, hasLength(6));
    for (final font in manifest.fonts) {
      expect(WatermarkFontCatalog.isDownloadable(font.family), isTrue);
      expect(font.downloadUri.scheme, 'https');
      expect(font.downloadUri.host, 'github.com');
      expect(
        font.downloadUri.path,
        '/Aaalice233/Aaalice_NAI_Launcher/releases/download/'
        '${manifest.releaseTag}/${font.fileName}',
      );
    }

    final mutations = <void Function(Map<String, dynamic>)>[
      (json) {
        final fonts = json['fonts'] as List<dynamic>;
        (fonts.first as Map<String, dynamic>)['url'] =
            'https://example.com/malicious/MaShanZheng-Regular.ttf';
      },
      (json) {
        (json['release'] as Map<String, dynamic>)['tag'] = 'v1.0.0';
      },
      (json) {
        final fonts = json['fonts'] as List<dynamic>;
        (fonts.first as Map<String, dynamic>)['fileName'] = '../escape.ttf';
      },
      (json) {
        final fonts = json['fonts'] as List<dynamic>;
        (fonts.first as Map<String, dynamic>)['sha256'] = 'not-a-sha256';
      },
    ];

    for (final mutate in mutations) {
      final copy = jsonDecode(raw) as Map<String, dynamic>;
      mutate(copy);
      expect(
        () => WatermarkFontPackManifest.parse(jsonEncode(copy)),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects corrupted download payload, cleans partial file, and records failed state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'watermark_font_checksum_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dio = Dio();
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final expectedBytes = _fakeTrueTypeBytes('Allura');
      final corruptedBytes = Uint8List.fromList(expectedBytes);
      corruptedBytes[corruptedBytes.length - 1] ^= 0xFF;

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = corruptedBytes.length
          ..add(corruptedBytes);
        await request.response.close();
      });

      final registrations = <String>[];
      final manifest = WatermarkFontPackManifest(
        dataVersion: 'fixture-v1',
        releaseTag: 'watermark-fonts-fixture-v1',
        fonts: [
          WatermarkFontAsset(
            family: 'Allura',
            fileName: 'Allura-Regular.ttf',
            size: expectedBytes.length,
            sha256: sha256.convert(expectedBytes).toString(),
            downloadUri: Uri.parse(
              'http://127.0.0.1:${server.port}/Allura-Regular.ttf',
            ),
          ),
        ],
      );

      final service = WatermarkFontPackService(
        downloader: VerifiedResumableDownloader(dio: dio),
        manifestLoader: () async => manifest,
        supportDirectoryLoader: () async => tempDir,
        fontRegistrar: (family, _) async => registrations.add(family),
      );
      addTearDown(service.dispose);

      final ready = await service.ensureFontReady('Allura');

      expect(ready, isFalse);
      expect(registrations, isEmpty);
      final itemState = service.state.stateFor('Allura');
      expect(itemState.status, WatermarkFontStatus.failed);
      expect(
        itemState.error,
        isA<VerifiedDownloadException>().having(
          (e) => e.failure,
          'failure',
          VerifiedDownloadFailure.checksumMismatch,
        ),
      );

      final packDir = Directory(
        p.join(tempDir.path, 'watermark', 'fonts', manifest.releaseTag),
      );
      expect(
        await File(p.join(packDir.path, 'Allura-Regular.ttf')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(packDir.path, 'Allura-Regular.ttf.part')).exists(),
        isFalse,
      );
    },
  );

  test(
    'registers each font family only once per process across concurrent and cached calls',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'watermark_font_once_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dio = Dio();
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final fontBytes = _fakeTrueTypeBytes('Great Vibes');
      var httpRequestCount = 0;
      server.listen((request) async {
        httpRequestCount++;
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = fontBytes.length
          ..add(fontBytes);
        await request.response.close();
      });

      final registered = <String>[];
      final sharedRegistry = WatermarkFontRegistry(
        registrar: (family, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          registered.add(family);
        },
      );
      final manifest = WatermarkFontPackManifest(
        dataVersion: 'fixture-v1',
        releaseTag: 'watermark-fonts-fixture-v1',
        fonts: [
          WatermarkFontAsset(
            family: 'Great Vibes',
            fileName: 'GreatVibes-Regular.ttf',
            size: fontBytes.length,
            sha256: sha256.convert(fontBytes).toString(),
            downloadUri: Uri.parse(
              'http://127.0.0.1:${server.port}/GreatVibes-Regular.ttf',
            ),
          ),
        ],
      );

      final firstService = WatermarkFontPackService(
        downloader: VerifiedResumableDownloader(dio: dio),
        manifestLoader: () async => manifest,
        supportDirectoryLoader: () async => tempDir,
        registry: sharedRegistry,
      );
      final secondService = WatermarkFontPackService(
        downloader: VerifiedResumableDownloader(dio: dio),
        manifestLoader: () async => manifest,
        supportDirectoryLoader: () async => tempDir,
        registry: sharedRegistry,
      );
      addTearDown(() {
        firstService.dispose();
        secondService.dispose();
      });

      final concurrentResults = await Future.wait([
        firstService.ensureFontReady('Great Vibes'),
        firstService.ensureFontReady('Great Vibes'),
      ]);
      final repeatResult = await firstService.ensureFontReady('Great Vibes');
      final secondInstanceResult = await secondService.ensureFontReady(
        'Great Vibes',
      );

      expect(concurrentResults, [true, true]);
      expect(repeatResult, isTrue);
      expect(secondInstanceResult, isTrue);
      expect(httpRequestCount, 1);
      expect(registered, ['Great Vibes']);
    },
  );

  test(
    'render waits for font readiness before painting and falls back with notice on failure',
    () async {
      final source = await _solidPng(96, 64, const Color(0xFF203040));

      // 1. Waits for async font readiness before completing render.
      final fontGate = Completer<bool>();
      final fallbackFamilies = <String>[];
      var renderCompleted = false;

      final pendingRender = WatermarkRenderService.render(
        WatermarkRenderRequest(
          sourceBytes: source,
          settings: const WatermarkSettings(
            textStyle: WatermarkTextStyle(
              text: 'Aaalice',
              fontFamily: 'Ma Shan Zheng',
              enabled: true,
            ),
          ),
          preserveMetadata: false,
        ),
        ensureFont: (family) {
          expect(family, 'Ma Shan Zheng');
          return fontGate.future;
        },
        onFontFallback: fallbackFamilies.add,
      ).then((value) {
        renderCompleted = true;
        return value;
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(renderCompleted, isFalse);

      fontGate.complete(true);
      final readyResult = await pendingRender;
      expect(renderCompleted, isTrue);
      expect(fallbackFamilies, isEmpty);
      expect(img.decodePng(readyResult.bytes), isNotNull);

      // 2. Download failure notifies caller and renders using fallback font.
      final fallbackResult = await WatermarkRenderService.render(
        WatermarkRenderRequest(
          sourceBytes: source,
          settings: const WatermarkSettings(
            textStyle: WatermarkTextStyle(
              text: 'Aaalice',
              fontFamily: 'Caveat',
              enabled: true,
            ),
          ),
          preserveMetadata: false,
        ),
        ensureFont: (family) async {
          expect(family, 'Caveat');
          return false;
        },
        onFontFallback: fallbackFamilies.add,
      );

      expect(fallbackFamilies, ['Caveat']);
      final original = img.decodePng(source)!;
      final rendered = img.decodePng(fallbackResult.bytes)!;
      var changedPixels = 0;
      for (var y = 0; y < rendered.height; y++) {
        for (var x = 0; x < rendered.width; x++) {
          if (rendered.getPixel(x, y) != original.getPixel(x, y)) {
            changedPixels++;
          }
        }
      }
      expect(changedPixels, greaterThan(10));
    },
  );
}

Uint8List _fakeTrueTypeBytes(String seed) {
  final payload = utf8.encode('sfnt-fixture-$seed-padding-bytes');
  return Uint8List.fromList([0x00, 0x01, 0x00, 0x00, ...payload]);
}

Future<Uint8List> _solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
