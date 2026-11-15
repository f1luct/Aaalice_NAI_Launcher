import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/presentation/widgets/common/horizontal_action_strip.dart';

import '../../../core/utils/localization_extension.dart';
import '../../../core/watermark/watermark_font_catalog.dart';
import '../../../core/watermark/watermark_font_pack_service.dart';
import '../../../data/models/watermark/watermark_settings.dart';
import '../../adaptive/adaptive_presenter.dart';
import '../../adaptive/content_sized_adaptive_form.dart';
import '../../providers/watermark_font_pack_provider.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/labeled_slider_rows.dart';
import '../../widgets/image_editor/widgets/color_picker.dart';

class WatermarkEditorControls extends StatefulWidget {
  const WatermarkEditorControls({
    super.key,
    required this.settings,
    required this.layout,
    required this.selectedLayer,
    required this.logoAvailable,
    required this.preserveMetadata,
    required this.onOpenMetadataSettings,
    required this.onSettingsChanged,
    required this.onLayoutChanged,
    required this.onSelectedLayerChanged,
    required this.onChooseLogo,
  });

  final WatermarkSettings settings;
  final WatermarkLayout layout;
  final WatermarkEditableLayer selectedLayer;
  final bool logoAvailable;
  final bool preserveMetadata;
  final VoidCallback onOpenMetadataSettings;
  final ValueChanged<WatermarkSettings> onSettingsChanged;
  final ValueChanged<WatermarkLayout> onLayoutChanged;
  final ValueChanged<WatermarkEditableLayer> onSelectedLayerChanged;
  final VoidCallback onChooseLogo;

  @override
  State<WatermarkEditorControls> createState() =>
      _WatermarkEditorControlsState();
}

class _WatermarkEditorControlsState extends State<WatermarkEditorControls> {
  ProviderContainer? _container;
  ProviderSubscription<WatermarkFontPackState>? _fontSubscription;
  WatermarkFontPackState _fontPackState = const WatermarkFontPackState();
  bool _initializedScope = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextContainer = _maybeContainerOf(context);
    if (!identical(nextContainer, _container)) {
      _fontSubscription?.close();
      _fontSubscription = null;
      _container = nextContainer;
      _initializedScope = false;
      if (nextContainer != null) {
        _fontSubscription = nextContainer.listen<WatermarkFontPackState>(
          watermarkFontPackProvider,
          (previous, next) {
            if (!mounted) return;
            setState(() => _fontPackState = next);
            if (previous != null &&
                next.registeredRevision != previous.registeredRevision) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _markSiblingPreviewNeedsPaint();
              });
            }
          },
          fireImmediately: true,
        );
      } else {
        _fontPackState = const WatermarkFontPackState();
      }
    }

    final container = _container;
    if (container != null && !_initializedScope) {
      _initializedScope = true;
      final notifier = container.read(watermarkFontPackProvider.notifier);
      unawaited(notifier.probeLocalCache());
      final initialFamily = widget.settings.textStyle.fontFamily;
      if (WatermarkFontCatalog.isDownloadable(initialFamily)) {
        unawaited(
          _ensureFontForSelection(initialFamily, notifyOnFailure: true),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant WatermarkEditorControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextFamily = widget.settings.textStyle.fontFamily;
    if (nextFamily != oldWidget.settings.textStyle.fontFamily &&
        WatermarkFontCatalog.isDownloadable(nextFamily) &&
        !_fontPackState.stateFor(nextFamily).isReady) {
      unawaited(_ensureFontForSelection(nextFamily, notifyOnFailure: false));
    }
  }

  @override
  void dispose() {
    _fontSubscription?.close();
    super.dispose();
  }

  static ProviderContainer? _maybeContainerOf(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() ==
        null) {
      return null;
    }
    return ProviderScope.containerOf(context, listen: false);
  }

  Future<void> _ensureFontForSelection(
    String family, {
    required bool notifyOnFailure,
  }) async {
    final container = _container;
    if (container == null || !WatermarkFontCatalog.isDownloadable(family)) {
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final fallbackMessage = context.l10n.watermark_fontFallbackNotice(family);
    final notifier = container.read(watermarkFontPackProvider.notifier);
    try {
      final ready = await notifier.ensureFontReady(family);
      if (!ready && notifyOnFailure && mounted) {
        AppToast.warningOnOverlay(overlay, fallbackMessage);
      }
    } on Object {
      if (notifyOnFailure && mounted) {
        AppToast.warningOnOverlay(overlay, fallbackMessage);
      }
    }
  }

  void _markSiblingPreviewNeedsPaint() {
    RenderObject? ancestor = context.findRenderObject();
    for (var depth = 0; depth < 6 && ancestor?.parent != null; depth++) {
      ancestor = ancestor!.parent;
    }
    if (ancestor == null) return;
    void visit(RenderObject object) {
      if (object is RenderCustomPaint) {
        object.markNeedsPaint();
      }
      object.visitChildren(visit);
    }

    ancestor.visitChildren(visit);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final layout = widget.layout;
    final selectedLayer = widget.selectedLayer;
    final text = settings.textStyle;
    final logo = settings.logoStyle;
    final selectedPlacement = selectedLayer == WatermarkEditableLayer.text
        ? layout.textPlacement
        : layout.logoPlacement;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            widget.preserveMetadata
                ? Icons.data_object_outlined
                : Icons.remove_circle_outline,
          ),
          title: Text(
            widget.preserveMetadata
                ? context.l10n.watermark_metadataPreserved
                : context.l10n.watermark_metadataRemoved,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.settings_outlined),
          onTap: widget.onOpenMetadataSettings,
        ),
        const SizedBox(height: 8),
        HorizontalActionStrip(
          child: SegmentedButton<WatermarkEditableLayer>(
            segments: [
              ButtonSegment(
                value: WatermarkEditableLayer.text,
                icon: const Icon(Icons.text_fields),
                label: Text(context.l10n.watermark_textLayer),
              ),
              ButtonSegment(
                value: WatermarkEditableLayer.logo,
                icon: const Icon(Icons.image_outlined),
                label: Text(context.l10n.watermark_logoLayer),
              ),
            ],
            selected: {selectedLayer},
            onSelectionChanged: (value) =>
                widget.onSelectedLayerChanged(value.first),
          ),
        ),
        const SizedBox(height: 12),
        if (selectedLayer == WatermarkEditableLayer.text) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.watermark_enableLayer),
            value: text.enabled,
            onChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(textStyle: text.copyWith(enabled: value)),
            ),
          ),
          _WatermarkTextField(
            value: text.text,
            label: context.l10n.watermark_text,
            onChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(textStyle: text.copyWith(text: value)),
            ),
          ),
          const SizedBox(height: 12),
          _WatermarkFontPicker(
            textStyle: text,
            fontPackState: _fontPackState,
            decoration: _controlDecoration(
              context,
              context.l10n.watermark_font,
            ),
            onSelected: (family) {
              widget.onSettingsChanged(
                settings.copyWith(
                  textStyle: text.copyWith(fontFamily: family),
                ),
              );
              unawaited(
                _ensureFontForSelection(family, notifyOnFailure: true),
              );
            },
            onRetry: (family) => unawaited(
              _ensureFontForSelection(family, notifyOnFailure: true),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !text.autoTone,
            leading: CircleAvatar(
              backgroundColor: Color(text.colorArgb),
              child: const Icon(Icons.palette_outlined),
            ),
            title: Text(context.l10n.editor_toolColorPicker),
            subtitle: text.autoTone
                ? Text(context.l10n.watermark_colorFromAutoTone)
                : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickColor(context, Color(text.colorArgb), (color) {
              widget.onSettingsChanged(
                settings.copyWith(
                  textStyle: text.copyWith(colorArgb: color.toARGB32()),
                ),
              );
            }),
          ),
          _AutoToneControls(
            enabled: text.autoTone,
            contrast: text.toneContrast,
            hint: context.l10n.watermark_autoToneTextHint,
            onEnabledChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(textStyle: text.copyWith(autoTone: value)),
            ),
            onContrastChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(textStyle: text.copyWith(toneContrast: value)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.watermark_alignment,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          HorizontalActionStrip(
            child: SegmentedButton<WatermarkTextAlignment>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: WatermarkTextAlignment.left,
                  icon: const Icon(Icons.format_align_left),
                  label: Text(context.l10n.watermark_alignLeft),
                  tooltip: context.l10n.watermark_alignLeft,
                ),
                ButtonSegment(
                  value: WatermarkTextAlignment.center,
                  icon: const Icon(Icons.format_align_center),
                  label: Text(context.l10n.watermark_alignCenter),
                  tooltip: context.l10n.watermark_alignCenter,
                ),
                ButtonSegment(
                  value: WatermarkTextAlignment.right,
                  icon: const Icon(Icons.format_align_right),
                  label: Text(context.l10n.watermark_alignRight),
                  tooltip: context.l10n.watermark_alignRight,
                ),
              ],
              selected: {text.alignment},
              onSelectionChanged: (value) => widget.onSettingsChanged(
                settings.copyWith(
                  textStyle: text.copyWith(alignment: value.first),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          LabeledSliderRows(
            sliders: [
              _ratioSlider(
                label: context.l10n.watermark_letterSpacing,
                value: text.letterSpacingRatio,
                min: -0.02,
                max: 0.08,
                onChanged: (value) => widget.onSettingsChanged(
                  settings.copyWith(
                    textStyle: text.copyWith(letterSpacingRatio: value),
                  ),
                ),
              ),
              _ratioSlider(
                label: context.l10n.watermark_stroke,
                value: text.strokeWidthRatio,
                min: 0,
                max: 0.012,
                onChanged: (value) => widget.onSettingsChanged(
                  settings.copyWith(
                    textStyle: text.copyWith(strokeWidthRatio: value),
                  ),
                ),
              ),
              _ratioSlider(
                label: context.l10n.watermark_shadow,
                value: text.shadowBlurRatio,
                min: 0,
                max: 0.04,
                onChanged: (value) => widget.onSettingsChanged(
                  settings.copyWith(
                    textStyle: text.copyWith(shadowBlurRatio: value),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.watermark_enableLayer),
            subtitle: !widget.logoAvailable && logo.enabled
                ? Text(
                    context.l10n.watermark_logoMissing,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                : null,
            value: logo.enabled,
            onChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(logoStyle: logo.copyWith(enabled: value)),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: widget.onChooseLogo,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              widget.logoAvailable
                  ? context.l10n.watermark_replaceLogo
                  : context.l10n.watermark_chooseLogo,
            ),
          ),
          const SizedBox(height: 8),
          _AutoToneControls(
            enabled: logo.autoTone,
            contrast: logo.toneContrast,
            hint: context.l10n.watermark_autoToneLogoHint,
            onEnabledChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(logoStyle: logo.copyWith(autoTone: value)),
            ),
            onContrastChanged: (value) => widget.onSettingsChanged(
              settings.copyWith(logoStyle: logo.copyWith(toneContrast: value)),
            ),
          ),
        ],
        const SizedBox(height: 12),
        LabeledSliderRows(
          sliders: [
            _ratioSlider(
              label: context.l10n.watermark_opacity,
              value: selectedLayer == WatermarkEditableLayer.text
                  ? text.opacity
                  : logo.opacity,
              min: 0.05,
              max: 1,
              onChanged: (value) => widget.onSettingsChanged(
                selectedLayer == WatermarkEditableLayer.text
                    ? settings.copyWith(
                        textStyle: text.copyWith(opacity: value),
                      )
                    : settings.copyWith(
                        logoStyle: logo.copyWith(opacity: value),
                      ),
              ),
            ),
            _ratioSlider(
              label: context.l10n.watermark_size,
              value: selectedPlacement.sizeRatio,
              min: 0.02,
              max: selectedLayer == WatermarkEditableLayer.text ? 0.25 : 0.6,
              onChanged: (value) => _updatePlacement(
                selectedPlacement.copyWith(sizeRatio: value),
              ),
            ),
            _ratioSlider(
              label: context.l10n.watermark_margin,
              value: selectedPlacement.marginRatio,
              min: 0,
              max: 0.2,
              onChanged: (value) => _updatePlacement(
                selectedPlacement.copyWith(marginRatio: value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<WatermarkAnchor>(
          initialValue: selectedPlacement.anchor,
          decoration: _controlDecoration(
            context,
            context.l10n.watermark_anchor,
          ),
          items: [
            for (final anchor in WatermarkAnchor.values)
              DropdownMenuItem(
                value: anchor,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_anchorIcon(anchor), size: 20),
                    const SizedBox(width: 8),
                    Flexible(child: Text(_anchorName(context, anchor))),
                  ],
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              _updatePlacement(
                selectedPlacement.copyWith(
                  anchor: value,
                  offsetXRatio: 0,
                  offsetYRatio: 0,
                ),
              );
            }
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.watermark_autoPlacement),
          subtitle: Text(context.l10n.watermark_autoPlacementHint),
          value: settings.autoPlacement,
          onChanged: (value) =>
              widget.onSettingsChanged(settings.copyWith(autoPlacement: value)),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<WatermarkLayerArrangement>(
          initialValue: settings.composition.arrangement,
          decoration: _controlDecoration(
            context,
            context.l10n.watermark_layerArrangement,
          ),
          items: [
            DropdownMenuItem(
              value: WatermarkLayerArrangement.independent,
              child: Text(context.l10n.watermark_arrangementIndependent),
            ),
            DropdownMenuItem(
              value: WatermarkLayerArrangement.horizontal,
              child: Text(context.l10n.watermark_arrangementHorizontal),
            ),
            DropdownMenuItem(
              value: WatermarkLayerArrangement.vertical,
              child: Text(context.l10n.watermark_arrangementVertical),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              widget.onSettingsChanged(
                settings.copyWith(
                  composition: settings.composition.copyWith(
                    arrangement: value,
                  ),
                ),
              );
            }
          },
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            final other = selectedLayer == WatermarkEditableLayer.text
                ? layout.logoPlacement
                : layout.textPlacement;
            _updatePlacement(
              selectedPlacement.copyWith(zIndex: other.zIndex + 1),
            );
          },
          icon: const Icon(Icons.flip_to_front_outlined),
          label: Text(context.l10n.watermark_zOrder),
        ),
      ],
    );
  }

  InputDecoration _controlDecoration(BuildContext context, String label) =>
      InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainer,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      );

  void _updatePlacement(WatermarkPlacement placement) {
    widget.onLayoutChanged(
      widget.selectedLayer == WatermarkEditableLayer.text
          ? widget.layout.copyWith(textPlacement: placement)
          : widget.layout.copyWith(logoPlacement: placement),
    );
  }

  Future<void> _pickColor(
    BuildContext context,
    Color initial,
    ValueChanged<Color> onChanged,
  ) async {
    final result = await AdaptivePresenter.showForm<Color>(
      context: context,
      title: context.l10n.editor_toolColorPicker,
      dialogWidth: 440,
      headerScrollsWithContent: true,
      builder: (panelContext, scrollController) => _WatermarkColorForm(
        initial: initial,
        scrollController: scrollController,
      ),
    );
    if (result != null) onChanged(result);
  }

  static IconData _anchorIcon(WatermarkAnchor anchor) => switch (anchor) {
    WatermarkAnchor.topLeft => Icons.north_west,
    WatermarkAnchor.topCenter => Icons.north,
    WatermarkAnchor.topRight => Icons.north_east,
    WatermarkAnchor.centerLeft => Icons.west,
    WatermarkAnchor.center => Icons.center_focus_weak,
    WatermarkAnchor.centerRight => Icons.east,
    WatermarkAnchor.bottomLeft => Icons.south_west,
    WatermarkAnchor.bottomCenter => Icons.south,
    WatermarkAnchor.bottomRight => Icons.south_east,
  };

  static String _anchorName(BuildContext context, WatermarkAnchor anchor) =>
      switch (anchor) {
        WatermarkAnchor.topLeft => context.l10n.watermark_anchorTopLeft,
        WatermarkAnchor.topCenter => context.l10n.watermark_anchorTopCenter,
        WatermarkAnchor.topRight => context.l10n.watermark_anchorTopRight,
        WatermarkAnchor.centerLeft => context.l10n.watermark_anchorCenterLeft,
        WatermarkAnchor.center => context.l10n.watermark_anchorCenter,
        WatermarkAnchor.centerRight => context.l10n.watermark_anchorCenterRight,
        WatermarkAnchor.bottomLeft => context.l10n.watermark_anchorBottomLeft,
        WatermarkAnchor.bottomCenter =>
          context.l10n.watermark_anchorBottomCenter,
        WatermarkAnchor.bottomRight => context.l10n.watermark_anchorBottomRight,
      };
}

class _WatermarkFontPicker extends StatelessWidget {
  const _WatermarkFontPicker({
    required this.textStyle,
    required this.fontPackState,
    required this.decoration,
    required this.onSelected,
    required this.onRetry,
  });

  final WatermarkTextStyle textStyle;
  final WatermarkFontPackState fontPackState;
  final InputDecoration decoration;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    final selectedFamily = WatermarkFontCatalog.contains(textStyle.fontFamily)
        ? textStyle.fontFamily
        : WatermarkFontCatalog.defaultFamily;
    final selectedItemState = fontPackState.stateFor(selectedFamily);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey(selectedFamily),
          initialValue: selectedFamily,
          isExpanded: true,
          selectedItemBuilder: (context) => [
            for (final option in WatermarkFontCatalog.options)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  option.family,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          decoration: decoration,
          items: [
            for (final option in WatermarkFontCatalog.options)
              DropdownMenuItem(
                value: option.family,
                child: _WatermarkFontMenuItem(
                  option: option,
                  customText: textStyle.text,
                  itemState: fontPackState.stateFor(option.family),
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              onSelected(value);
            }
          },
        ),
        if (selectedItemState.status == WatermarkFontStatus.downloading) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: selectedItemState.progress.clamp(0.02, 1.0),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.watermark_fontDownloading(
              (selectedItemState.progress * 100).round(),
            ),
            style: theme.textTheme.bodySmall,
          ),
        ] else if (selectedItemState.status == WatermarkFontStatus.failed) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.l10n.watermark_fontDownloadFailed,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => onRetry(selectedFamily),
                child: Text(context.l10n.common_retry),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _WatermarkFontMenuItem extends StatelessWidget {
  const _WatermarkFontMenuItem({
    required this.option,
    required this.customText,
    required this.itemState,
  });

  final WatermarkFontOption option;
  final String customText;
  final WatermarkFontItemState itemState;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusSuffix = switch (itemState.status) {
      WatermarkFontStatus.bundled ||
      WatermarkFontStatus.downloaded ||
      WatermarkFontStatus.ready => null,
      WatermarkFontStatus.notDownloaded => l10n.watermark_fontNotDownloaded,
      WatermarkFontStatus.downloading => l10n.watermark_fontDownloading(
        (itemState.progress * 100).round(),
      ),
      WatermarkFontStatus.failed => l10n.watermark_fontDownloadFailed,
    };
    final semanticsLabel = statusSuffix == null
        ? '${l10n.watermark_font}: ${option.family}'
        : '${l10n.watermark_font}: ${option.family}, $statusSuffix';

    final effectiveFamily = WatermarkFontRegistry.processInstance
        .resolveRenderableFamily(option.family);

    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                option.family,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: Text(
                customText.trim().isEmpty ? option.sample : customText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: effectiveFamily,
                  fontFamilyFallback: WatermarkFontCatalog.fallbackFamilies,
                  fontSize: 18,
                ),
              ),
            ),
            if (!option.isBundled) ...[
              const SizedBox(width: 8),
              Flexible(
                flex: 3,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: _buildTrailingStatus(context, theme, colorScheme),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrailingStatus(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return switch (itemState.status) {
      WatermarkFontStatus.bundled => const SizedBox.shrink(),
      WatermarkFontStatus.notDownloaded => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              context.l10n.watermark_fontNotDownloaded,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      WatermarkFontStatus.downloading => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: itemState.progress.clamp(0.05, 1.0),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${(itemState.progress * 100).round()}%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
      WatermarkFontStatus.downloaded || WatermarkFontStatus.ready => Icon(
        Icons.check_circle_outline,
        size: 16,
        color: colorScheme.primary,
      ),
      WatermarkFontStatus.failed => Icon(
        Icons.error_outline,
        size: 16,
        color: colorScheme.error,
      ),
    };
  }
}

class _WatermarkColorForm extends StatefulWidget {
  const _WatermarkColorForm({
    required this.initial,
    required this.scrollController,
  });

  final Color initial;
  final ScrollController scrollController;

  @override
  State<_WatermarkColorForm> createState() => _WatermarkColorFormState();
}

class _WatermarkColorFormState extends State<_WatermarkColorForm> {
  late Color _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return ContentSizedAdaptiveForm(
      scrollViewKey: const ValueKey('watermark-color-form'),
      scrollController: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      content: [
        HSVColorPicker(
          color: widget.initial,
          hexLabel: context.l10n.editor_colorHex,
          saturationBrightnessLabel:
              context.l10n.editor_colorSaturationBrightness,
          hueLabel: context.l10n.editor_colorHue,
          hueHeight: 48,
          onColorChanged: (value) => _selected = value,
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_selected),
              child: Text(context.l10n.common_confirm),
            ),
          ],
        ),
      ],
    );
  }
}

class _AutoToneControls extends StatelessWidget {
  const _AutoToneControls({
    required this.enabled,
    required this.contrast,
    required this.hint,
    required this.onEnabledChanged,
    required this.onContrastChanged,
  });

  final bool enabled;
  final double contrast;
  final String hint;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<double> onContrastChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(context.l10n.watermark_autoTone),
        subtitle: Text(hint),
        value: enabled,
        onChanged: onEnabledChanged,
      ),
      if (enabled)
        LabeledSliderRows(
          sliders: [
            _ratioSlider(
              label: context.l10n.watermark_toneContrast,
              value: contrast,
              min: 0,
              max: 1,
              onChanged: onContrastChanged,
            ),
          ],
        ),
    ],
  );
}

enum WatermarkEditableLayer { text, logo }

LabeledSlider _ratioSlider({
  required String label,
  required double value,
  required double min,
  required double max,
  required ValueChanged<double> onChanged,
}) => LabeledSlider(
  label: label,
  value: value,
  min: min,
  max: max,
  valueText: _percentText,
  onChanged: onChanged,
);

String _percentText(double value) => '${(value * 100).toStringAsFixed(0)}%';

class _WatermarkTextField extends StatefulWidget {
  const _WatermarkTextField({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  State<_WatermarkTextField> createState() => _WatermarkTextFieldState();
}

class _WatermarkTextFieldState extends State<_WatermarkTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _WatermarkTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    maxLines: 3,
    minLines: 1,
    decoration: InputDecoration(
      labelText: widget.label,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainer,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
    ),
    onChanged: widget.onChanged,
  );
}
