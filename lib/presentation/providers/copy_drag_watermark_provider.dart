import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';

import '../../core/utils/image_share_sanitizer.dart';
import '../../core/utils/locale_provider.dart';
import '../../core/watermark/watermark_render_service.dart';
import '../router/app_router_config.dart';
import '../widgets/common/app_toast.dart';
import 'share_image_settings_provider.dart';
import 'watermark_font_pack_provider.dart';
import 'watermark_settings_provider.dart';

/// Displays a warning toast on the application's root overlay when watermark
/// rendering falls back from an unavailable downloadable font.
final watermarkFontFallbackToastProvider =
    Provider<WatermarkFontFallbackHandler>((ref) {
      var disposed = false;
      ref.onDispose(() => disposed = true);
      return (family) {
        if (disposed) return;
        try {
          final overlay = ref
              .read(appRouterProvider)
              .routerDelegate
              .navigatorKey
              .currentState
              ?.overlay;
          if (overlay == null || !overlay.mounted) return;
          final l10n = lookupAppLocalizations(ref.read(localeNotifierProvider));
          AppToast.warningOnOverlay(
            overlay,
            l10n.watermark_fontFallbackNotice(family),
          );
        } on Object {
          // Bare ProviderContainer instances in unit tests do not mount GoRouter.
        }
      };
    });

/// A snapshot of the saved watermark, independent of the metadata policy.
final copyDragWatermarkProvider = Provider<ShareImageTransform?>((ref) {
  final enabled = ref.watch(
    shareImageSettingsProvider.select((s) => s.watermarkForCopyAndDrag),
  );
  if (!enabled) return null;

  final state = ref.watch(watermarkSettingsProvider);
  final logoService = ref.watch(watermarkLogoServiceProvider);
  final ensureFont =
      ref.read(watermarkFontPackProvider.notifier).ensureFontReady;
  final onFontFallback = ref.read(watermarkFontFallbackToastProvider);
  final cacheKey = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            state.configuration.encode(),
            state.localLogoPath,
            state.loadIssue?.name,
          ]),
        ),
      )
      .toString();

  return ShareImageTransform(
    cacheKey: cacheKey,
    apply: (image, {required stripMetadata}) async {
      if (state.loadIssue != null) {
        throw const WatermarkRenderException(
          'The saved watermark settings cannot be loaded. Save the defaults again.',
        );
      }
      final logoPath = state.localLogoPath;
      final logo = state.configuration.logoStyle.enabled
          ? await logoService.readValidated(logoPath ?? '')
          : null;
      final result = await WatermarkRenderService.render(
        WatermarkRenderRequest(
          sourceBytes: image.bytes,
          sourceFileName: image.fileName,
          settings: state.configuration,
          logoBytes: logo,
          // The editor's own preservation setting must not override sharing.
          preserveMetadata: !stripMetadata,
        ),
        ensureFont: ensureFont,
        onFontFallback: onFontFallback,
      );
      return SanitizedShareImage(
        bytes: result.bytes,
        fileName: result.fileName,
        mimeType: 'image/png',
      );
    },
  );
});
