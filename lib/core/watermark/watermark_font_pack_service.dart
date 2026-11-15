import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/verified_resumable_downloader.dart';
import '../utils/app_logger.dart';
import 'watermark_font_catalog.dart';
import 'watermark_font_pack_manifest.dart';

typedef WatermarkFontRegistrar =
    Future<void> Function(String family, Uint8List bytes);
typedef WatermarkFontManifestLoader = Future<WatermarkFontPackManifest> Function();
typedef WatermarkSupportDirectoryLoader = Future<Directory> Function();
typedef WatermarkDownloaderResolver = VerifiedResumableDownloader Function();

enum WatermarkFontStatus {
  bundled,
  notDownloaded,
  downloaded,
  downloading,
  ready,
  failed,
}

class WatermarkFontItemState {
  const WatermarkFontItemState({
    required this.family,
    required this.status,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final String family;
  final WatermarkFontStatus status;
  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final Object? error;

  bool get isReady =>
      status == WatermarkFontStatus.bundled ||
      status == WatermarkFontStatus.ready;

  WatermarkFontItemState copyWith({
    WatermarkFontStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    Object? error,
    bool clearError = false,
  }) => WatermarkFontItemState(
    family: family,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    error: clearError ? null : (error ?? this.error),
  );
}

class WatermarkFontPackState {
  const WatermarkFontPackState({
    this.fonts = const <String, WatermarkFontItemState>{},
    this.registeredRevision = 0,
  });

  final Map<String, WatermarkFontItemState> fonts;
  final int registeredRevision;

  WatermarkFontItemState stateFor(String family) {
    final existing = fonts[family];
    if (existing != null) return existing;
    if (WatermarkFontCatalog.isBundled(family)) {
      return WatermarkFontItemState(
        family: family,
        status: WatermarkFontStatus.bundled,
        progress: 1,
      );
    }
    return WatermarkFontItemState(
      family: family,
      status: WatermarkFontStatus.notDownloaded,
    );
  }

  WatermarkFontPackState copyWithFont(
    WatermarkFontItemState item, {
    int? registeredRevision,
  }) => WatermarkFontPackState(
    fonts: Map<String, WatermarkFontItemState>.unmodifiable({
      ...fonts,
      item.family: item,
    }),
    registeredRevision: registeredRevision ?? this.registeredRevision,
  );
}

/// Tracks font families registered in the current Flutter engine process so
/// each family is loaded via [FontLoader] at most once per process.
class WatermarkFontRegistry {
  WatermarkFontRegistry({WatermarkFontRegistrar? registrar})
    : _registrar = registrar ?? _defaultRegisterFont;

  static final WatermarkFontRegistry processInstance = WatermarkFontRegistry();

  final WatermarkFontRegistrar _registrar;
  final Set<String> _registeredFamilies = <String>{};
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  bool isReady(String family) {
    if (!WatermarkFontCatalog.contains(family) ||
        WatermarkFontCatalog.isBundled(family)) {
      return true;
    }
    return _registeredFamilies.contains(family);
  }

  String resolveRenderableFamily(String family) {
    if (!WatermarkFontCatalog.contains(family)) {
      return WatermarkFontCatalog.defaultFamily;
    }
    return isReady(family) ? family : WatermarkFontCatalog.defaultFamily;
  }

  Future<void> registerOnce(String family, Uint8List bytes) {
    if (isReady(family)) return Future<void>.value();
    final existing = _inFlight[family];
    if (existing != null) return existing;

    final operation = _register(family, bytes);
    _inFlight[family] = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight[family], operation)) {
        _inFlight.remove(family);
      }
    });
  }

  Future<void> _register(String family, Uint8List bytes) async {
    _validateFontHeader(bytes, family: family);
    await _registrar(family, bytes);
    _registeredFamilies.add(family);
  }

  static void _validateFontHeader(Uint8List bytes, {required String family}) {
    if (bytes.length < 4) {
      throw FormatException('Watermark font binary is truncated: $family');
    }
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != '\u0000\u0001\u0000\u0000' && magic != 'OTTO') {
      throw FormatException('Invalid sfnt header for watermark font: $family');
    }
  }

  static Future<void> _defaultRegisterFont(
    String family,
    Uint8List bytes,
  ) async {
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

class WatermarkFontPackService {
  WatermarkFontPackService({
    VerifiedResumableDownloader? downloader,
    WatermarkDownloaderResolver? downloaderResolver,
    WatermarkFontManifestLoader? manifestLoader,
    WatermarkSupportDirectoryLoader? supportDirectoryLoader,
    WatermarkFontRegistry? registry,
    WatermarkFontRegistrar? fontRegistrar,
    void Function(WatermarkFontPackState state)? onStateChanged,
  }) : _downloaderResolver =
           downloaderResolver ??
           (() {
             final fallback =
                 downloader ?? VerifiedResumableDownloader(dio: Dio());
             return () => fallback;
           })(),
       _manifestLoader = manifestLoader ?? _loadBundledManifest,
       _supportDirectoryLoader =
           supportDirectoryLoader ?? getApplicationSupportDirectory,
       _registry =
           registry ??
           (fontRegistrar != null
               ? WatermarkFontRegistry(registrar: fontRegistrar)
               : WatermarkFontRegistry.processInstance),
       _onStateChanged = onStateChanged {
    _state = _buildInitialState(_registry);
  }

  final WatermarkDownloaderResolver _downloaderResolver;
  final WatermarkFontManifestLoader _manifestLoader;
  final WatermarkSupportDirectoryLoader _supportDirectoryLoader;
  final WatermarkFontRegistry _registry;
  void Function(WatermarkFontPackState state)? _onStateChanged;

  late WatermarkFontPackState _state;
  WatermarkFontPackManifest? _manifest;
  Future<WatermarkFontPackManifest>? _manifestLoading;
  Future<void>? _probing;
  final Map<String, Future<bool>> _activeEnsures = <String, Future<bool>>{};
  bool _disposed = false;

  WatermarkFontPackState get state => _state;
  WatermarkFontRegistry get registry => _registry;

  set onStateChanged(void Function(WatermarkFontPackState state)? listener) {
    _onStateChanged = listener;
  }

  void dispose() {
    _disposed = true;
    _onStateChanged = null;
  }

  bool isFamilyReady(String family) => _registry.isReady(family);

  /// Probes local disk cache without loading fonts into the engine, so already
  /// downloaded fonts show accurate status in the picker without blocking
  /// startup or inflating memory.
  Future<void> probeLocalCache() => _probing ??= _probeLocalCache().whenComplete(
    () => _probing = null,
  );

  Future<void> _probeLocalCache() async {
    if (_disposed) return;
    try {
      final manifest = await _getManifest();
      final packDir = await _packDirectory(manifest);
      if (_disposed) return;

      final nextFonts = Map<String, WatermarkFontItemState>.of(_state.fonts);
      for (final asset in manifest.fonts) {
        final current = _state.stateFor(asset.family);
        if (_registry.isReady(asset.family)) {
          nextFonts[asset.family] = WatermarkFontItemState(
            family: asset.family,
            status: WatermarkFontStatus.ready,
            progress: 1,
            receivedBytes: asset.size,
            totalBytes: asset.size,
          );
          continue;
        }
        if (current.status == WatermarkFontStatus.downloading) {
          continue;
        }
        final target = File('${packDir.path}/${asset.fileName}');
        if (await target.exists() && await target.length() == asset.size) {
          nextFonts[asset.family] = WatermarkFontItemState(
            family: asset.family,
            status: WatermarkFontStatus.downloaded,
            progress: 1,
            receivedBytes: asset.size,
            totalBytes: asset.size,
          );
        } else {
          final partFile = File('${target.path}.part');
          final partial = await partFile.exists() ? await partFile.length() : 0;
          final clampedPartial = partial.clamp(0, asset.size);
          nextFonts[asset.family] = WatermarkFontItemState(
            family: asset.family,
            status: current.status == WatermarkFontStatus.failed
                ? WatermarkFontStatus.failed
                : WatermarkFontStatus.notDownloaded,
            progress: asset.size > 0 ? clampedPartial / asset.size : 0,
            receivedBytes: clampedPartial,
            totalBytes: asset.size,
            error: current.error,
          );
        }
      }
      _setState(
        WatermarkFontPackState(
          fonts: Map<String, WatermarkFontItemState>.unmodifiable(nextFonts),
          registeredRevision: _state.registeredRevision,
        ),
      );
    } on MissingPluginException {
      // Bare widget tests without path_provider keep safe default states.
    } on Object catch (error, stackTrace) {
      AppLogger.w(
        'Failed to probe local watermark font cache: $error\n$stackTrace',
        'WatermarkFontPack',
      );
    }
  }

  /// Ensures [family] is downloaded, SHA-256 verified, and registered in the
  /// current process. Returns `true` when ready, or `false` if download,
  /// verification, or registration failed.
  Future<bool> ensureFontReady(String family, {CancelToken? cancelToken}) {
    if (!WatermarkFontCatalog.contains(family) ||
        WatermarkFontCatalog.isBundled(family)) {
      return Future<bool>.value(true);
    }
    if (_registry.isReady(family)) {
      final current = _state.stateFor(family);
      if (current.status != WatermarkFontStatus.ready) {
        _updateFontState(
          current.copyWith(
            status: WatermarkFontStatus.ready,
            progress: 1,
            clearError: true,
          ),
        );
      }
      return Future<bool>.value(true);
    }

    final active = _activeEnsures[family];
    if (active != null) return active;

    final operation = _ensureFontReady(family, cancelToken: cancelToken);
    _activeEnsures[family] = operation;
    return operation.whenComplete(() {
      if (identical(_activeEnsures[family], operation)) {
        _activeEnsures.remove(family);
      }
    });
  }

  Future<bool> _ensureFontReady(
    String family, {
    CancelToken? cancelToken,
  }) async {
    WatermarkFontAsset? asset;
    File? targetFile;
    try {
      final manifest = await _getManifest();
      asset = manifest.fontForFamily(family);
      if (asset == null) {
        throw StateError('Watermark font "$family" is missing from manifest');
      }
      final packDir = await _packDirectory(manifest);
      targetFile = File('${packDir.path}/${asset.fileName}');

      final previous = _state.stateFor(family);
      _updateFontState(
        WatermarkFontItemState(
          family: family,
          status: WatermarkFontStatus.downloading,
          progress: previous.status == WatermarkFontStatus.downloaded
              ? 0.99
              : previous.progress.clamp(0.0, 0.99),
          receivedBytes: previous.receivedBytes,
          totalBytes: asset.size,
        ),
      );

      final result = await _downloaderResolver().download(
        uri: asset.downloadUri,
        targetFile: targetFile,
        expectedSize: asset.size,
        expectedSha256: asset.sha256,
        cancelToken: cancelToken,
        onProgress: (progress) {
          _updateFontState(
            WatermarkFontItemState(
              family: family,
              status: WatermarkFontStatus.downloading,
              progress: progress.progress,
              receivedBytes: progress.receivedBytes,
              totalBytes: progress.totalBytes,
            ),
          );
        },
      );

      final bytes = await result.file.readAsBytes();
      await _registry.registerOnce(family, bytes);

      _updateFontState(
        WatermarkFontItemState(
          family: family,
          status: WatermarkFontStatus.ready,
          progress: 1,
          receivedBytes: asset.size,
          totalBytes: asset.size,
        ),
        incrementRevision: true,
      );
      return true;
    } on VerifiedDownloadCancelledException {
      final size = asset?.size ?? 0;
      final existsOnDisk =
          targetFile != null &&
          size > 0 &&
          await targetFile.exists() &&
          await targetFile.length() == size;
      _updateFontState(
        WatermarkFontItemState(
          family: family,
          status: existsOnDisk
              ? WatermarkFontStatus.downloaded
              : WatermarkFontStatus.notDownloaded,
          progress: existsOnDisk ? 1 : 0,
          receivedBytes: existsOnDisk ? size : 0,
          totalBytes: size,
        ),
      );
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.w(
        'Watermark font "$family" failed to download or register; '
        'falling back to ${WatermarkFontCatalog.defaultFamily}: $error\n$stackTrace',
        'WatermarkFontPack',
      );
      _updateFontState(
        WatermarkFontItemState(
          family: family,
          status: WatermarkFontStatus.failed,
          progress: 0,
          receivedBytes: 0,
          totalBytes: asset?.size ?? 0,
          error: error,
        ),
      );
      return false;
    }
  }

  Future<WatermarkFontPackManifest> _getManifest() async {
    final cached = _manifest;
    if (cached != null) return cached;
    final loading = _manifestLoading ??= _manifestLoader();
    try {
      final loaded = await loading;
      _manifest = loaded;
      return loaded;
    } finally {
      if (identical(_manifestLoading, loading)) {
        _manifestLoading = null;
      }
    }
  }

  Future<Directory> _packDirectory(WatermarkFontPackManifest manifest) async {
    final supportDir = await _supportDirectoryLoader();
    return Directory('${supportDir.path}/watermark/fonts/${manifest.releaseTag}');
  }

  void _updateFontState(
    WatermarkFontItemState item, {
    bool incrementRevision = false,
  }) {
    _setState(
      _state.copyWithFont(
        item,
        registeredRevision: incrementRevision
            ? _state.registeredRevision + 1
            : _state.registeredRevision,
      ),
    );
  }

  void _setState(WatermarkFontPackState next) {
    _state = next;
    if (!_disposed) {
      _onStateChanged?.call(next);
    }
  }

  static WatermarkFontPackState _buildInitialState(
    WatermarkFontRegistry registry,
  ) => WatermarkFontPackState(
    fonts: Map<String, WatermarkFontItemState>.unmodifiable({
      for (final option in WatermarkFontCatalog.options)
        option.family: WatermarkFontItemState(
          family: option.family,
          status: option.isBundled
              ? WatermarkFontStatus.bundled
              : registry.isReady(option.family)
              ? WatermarkFontStatus.ready
              : WatermarkFontStatus.notDownloaded,
          progress: option.isBundled || registry.isReady(option.family) ? 1 : 0,
        ),
    }),
  );

  static Future<WatermarkFontPackManifest> _loadBundledManifest() async =>
      WatermarkFontPackManifest.parse(
        await rootBundle.loadString(watermarkFontPackManifestAsset),
      );
}
