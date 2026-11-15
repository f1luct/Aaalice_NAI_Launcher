import 'dart:convert';

const watermarkFontPackManifestAsset =
    'assets/data/watermark_font_pack_manifest.json';

class WatermarkFontAsset {
  const WatermarkFontAsset({
    required this.family,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.downloadUri,
  });

  final String family;
  final String fileName;
  final int size;
  final String sha256;
  final Uri downloadUri;

  Map<String, dynamic> toJson() => {
    'family': family,
    'fileName': fileName,
    'size': size,
    'sha256': sha256,
    'url': downloadUri.toString(),
  };
}

class WatermarkFontPackManifest {
  const WatermarkFontPackManifest({
    required this.dataVersion,
    required this.releaseTag,
    required this.fonts,
  });

  final String dataVersion;
  final String releaseTag;
  final List<WatermarkFontAsset> fonts;

  WatermarkFontAsset? fontForFamily(String family) {
    for (final font in fonts) {
      if (font.family == family) return font;
    }
    return null;
  }

  static WatermarkFontPackManifest parse(String source) =>
      WatermarkFontPackManifestCodec.parse(source);

  Map<String, dynamic> toJson() => WatermarkFontPackManifestCodec.encode(this);
}

class WatermarkFontPackManifestCodec {
  const WatermarkFontPackManifestCodec._();

  static final RegExp _safeTagPattern = RegExp(
    r'^watermark-fonts-[a-z0-9][a-z0-9._-]*$',
  );
  static final RegExp _safeFileNamePattern = RegExp(
    r'^[A-Za-z0-9._-]+\.(ttf|otf)$',
  );
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  static WatermarkFontPackManifest parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['manifestVersion'] != 1) {
      throw const FormatException('Unsupported watermark font pack manifest');
    }
    final dataVersion = _string(decoded, 'dataVersion');
    final release = _map(decoded, 'release');
    final releaseTag = _string(release, 'tag');
    if (!_safeTagPattern.hasMatch(releaseTag) ||
        release['prerelease'] != true ||
        release['makeLatest'] != false) {
      throw const FormatException('Invalid watermark font pack release config');
    }

    final rawFonts = decoded['fonts'];
    if (rawFonts is! List || rawFonts.isEmpty) {
      throw const FormatException('Missing watermark font pack entries');
    }

    final seenFamilies = <String>{};
    final seenFileNames = <String>{};
    final fonts = <WatermarkFontAsset>[];
    for (final item in rawFonts) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid watermark font entry');
      }
      final family = _string(item, 'family');
      final fileName = _string(item, 'fileName');
      if (!_safeFileNamePattern.hasMatch(fileName) || fileName.contains('..')) {
        throw FormatException('Invalid watermark font fileName: $fileName');
      }
      if (!seenFamilies.add(family)) {
        throw FormatException('Duplicate watermark font family: $family');
      }
      if (!seenFileNames.add(fileName)) {
        throw FormatException('Duplicate watermark font fileName: $fileName');
      }
      final uri = Uri.parse(_string(item, 'url'));
      final expectedPath =
          '/Aaalice233/Aaalice_NAI_Launcher/releases/download/'
          '$releaseTag/$fileName';
      if (uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.path != expectedPath ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw FormatException('Untrusted watermark font release URL: $uri');
      }
      fonts.add(
        WatermarkFontAsset(
          family: family,
          fileName: fileName,
          size: _positiveInt(item, 'size'),
          sha256: _sha256(item, 'sha256'),
          downloadUri: uri,
        ),
      );
    }

    return WatermarkFontPackManifest(
      dataVersion: dataVersion,
      releaseTag: releaseTag,
      fonts: List.unmodifiable(fonts),
    );
  }

  static Map<String, dynamic> encode(WatermarkFontPackManifest manifest) => {
    'manifestVersion': 1,
    'dataVersion': manifest.dataVersion,
    'release': {
      'tag': manifest.releaseTag,
      'prerelease': true,
      'makeLatest': false,
    },
    'fonts': [for (final font in manifest.fonts) font.toJson()],
  };

  static Map<String, dynamic> _map(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! Map<String, dynamic>) {
      throw FormatException('Missing manifest object: $key');
    }
    return value;
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing manifest string: $key');
    }
    return value;
  }

  static int _positiveInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int || value <= 0) {
      throw FormatException('Invalid manifest integer: $key');
    }
    return value;
  }

  static String _sha256(Map<String, dynamic> map, String key) {
    final value = _string(map, key).toLowerCase();
    if (!_sha256Pattern.hasMatch(value)) {
      throw FormatException('Invalid manifest SHA256: $key');
    }
    return value;
  }
}
