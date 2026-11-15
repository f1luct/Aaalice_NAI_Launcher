import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/proxy_settings_provider.dart';
import '../../core/services/verified_resumable_downloader.dart';
import '../../core/watermark/watermark_font_pack_service.dart';

final watermarkFontPackDioProvider = Provider<Dio>((ref) {
  String? proxyAddress;
  var resolvedFromSettings = false;
  try {
    proxyAddress = ref.watch(currentProxyAddressProvider);
    resolvedFromSettings = true;
  } on Object {
    resolvedFromSettings = false;
  }

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  if (resolvedFromSettings) {
    final normalizedProxy = proxyAddress?.trim();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..findProxy = (_) => normalizedProxy == null || normalizedProxy.isEmpty
            ? 'DIRECT'
            : 'PROXY $normalizedProxy',
    );
  }
  ref.onDispose(dio.close);
  return dio;
});

final watermarkFontPackDownloaderProvider =
    Provider<VerifiedResumableDownloader>(
      (ref) => VerifiedResumableDownloader(
        dio: ref.watch(watermarkFontPackDioProvider),
      ),
    );

final watermarkFontPackProvider =
    NotifierProvider<WatermarkFontPackNotifier, WatermarkFontPackState>(
      WatermarkFontPackNotifier.new,
    );

class WatermarkFontPackNotifier extends Notifier<WatermarkFontPackState> {
  WatermarkFontPackService? _service;

  @override
  WatermarkFontPackState build() {
    _service?.dispose();
    final service = WatermarkFontPackService(
      downloaderResolver: () => ref.read(watermarkFontPackDownloaderProvider),
      onStateChanged: (next) => state = next,
    );
    _service = service;

    ref.onDispose(() {
      if (identical(_service, service)) {
        _service = null;
      }
      service.dispose();
    });
    return service.state;
  }

  Future<void> probeLocalCache() =>
      _service?.probeLocalCache() ?? Future<void>.value();

  Future<bool> ensureFontReady(String family) =>
      _service?.ensureFontReady(family) ?? Future<bool>.value(false);
}
