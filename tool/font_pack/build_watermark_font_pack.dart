import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:nai_launcher/core/watermark/watermark_font_pack_manifest.dart';

const _lockSchemaVersion = 1;
const _toolVersion = 1;
const _defaultLockPath = 'tool/font_pack/watermark_font_pack_source_lock.json';
const _defaultOutputDirectory = 'tool/.tmp/watermark_font_pack';
const _defaultClientManifestPath = watermarkFontPackManifestAsset;

Future<void> main(List<String> arguments) async {
  try {
    await buildWatermarkFontPack(arguments);
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('Watermark font pack build failed: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  }
}

Future<void> buildWatermarkFontPack(List<String> arguments) =>
    _build(_Options.parse(arguments));

Future<void> _build(_Options options) async {
  final lockFile = File(options.lockPath).absolute;
  if (!await lockFile.exists()) {
    throw StateError('Missing source lock: ${lockFile.path}');
  }
  final lock = _asStringMap(jsonDecode(await lockFile.readAsString()));
  _validateLock(lock);

  final dataVersion = lock['dataVersion'] as String;
  final release = _asStringMap(lock['release']);
  final repository = release['repository'] as String;
  final releaseTag = release['tag'] as String;
  final sourceDirPath =
      options.sourceDirectory ?? (lock['sourceDirectory'] as String);
  final sourceDirectory = Directory(sourceDirPath).absolute;
  if (!await sourceDirectory.exists()) {
    throw StateError('Missing font source directory: ${sourceDirectory.path}');
  }

  final rawFonts = lock['fonts'] as List<dynamic>;
  final lockedFonts = rawFonts.map(_asStringMap).toList(growable: false);

  final actualFiles = await sourceDirectory
      .list(followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .map((file) => file.uri.pathSegments.last)
      .toList();
  actualFiles.sort();
  final expectedFiles = lockedFonts
      .map((entry) => entry['fileName'] as String)
      .toList()
    ..sort();
  if (!_listEquals(actualFiles, expectedFiles)) {
    throw StateError(
      'Source directory font files do not match lock.\n'
      '  expected: $expectedFiles\n'
      '  actual:   $actualFiles',
    );
  }

  final outputDirectory = Directory(options.outputDirectory).absolute;
  await outputDirectory.create(recursive: true);

  final manifestFile = File('${outputDirectory.path}/manifest.json');
  final reportFile = File('${outputDirectory.path}/verification-report.json');
  for (final file in [manifestFile, reportFile]) {
    if (await file.exists()) await file.delete();
  }

  final verifiedAssets = <WatermarkFontAsset>[];
  final reportEntries = <Map<String, dynamic>>[];
  var totalBytes = 0;

  for (final entry in lockedFonts) {
    final family = entry['family'] as String;
    final fileName = entry['fileName'] as String;
    final licenseDirPath = entry['licenseDirectory'] as String;
    final sourceFile = File('${sourceDirectory.path}/$fileName');
    if (!await sourceFile.exists()) {
      throw StateError('Missing source font file: ${sourceFile.path}');
    }

    await _verifyFontBinary(sourceFile, fileName: fileName);
    await _verifyFontLicense(licenseDirPath, fileName: fileName);

    final size = await sourceFile.length();
    final digest = await _sha256Of(sourceFile);

    if (!options.updateLock) {
      final expectedSize = entry['size'] as int;
      final expectedSha256 = (entry['sha256'] as String).toLowerCase();
      if (size != expectedSize) {
        throw StateError(
          'Font size mismatch for $fileName: expected $expectedSize, got $size',
        );
      }
      if (digest != expectedSha256) {
        throw StateError(
          'Font SHA256 mismatch for $fileName: '
          'expected $expectedSha256, got $digest',
        );
      }
    } else {
      entry['size'] = size;
      entry['sha256'] = digest;
    }

    final stagedFile = File('${outputDirectory.path}/$fileName');
    final buildingFile = File('${stagedFile.path}.building');
    if (await buildingFile.exists()) await buildingFile.delete();
    await sourceFile.copy(buildingFile.path);
    if (await stagedFile.exists()) await stagedFile.delete();
    await buildingFile.rename(stagedFile.path);

    final stagedSize = await stagedFile.length();
    final stagedSha256 = await _sha256Of(stagedFile);
    if (stagedSize != size || stagedSha256 != digest) {
      throw StateError('Staged font verification failed for $fileName');
    }

    final url = Uri.parse(
      'https://github.com/$repository/releases/download/$releaseTag/$fileName',
    );
    verifiedAssets.add(
      WatermarkFontAsset(
        family: family,
        fileName: fileName,
        size: size,
        sha256: digest,
        downloadUri: url,
      ),
    );
    reportEntries.add({
      'family': family,
      'fileName': fileName,
      'size': size,
      'sha256': digest,
      'url': url.toString(),
      'licenseDirectory': licenseDirPath,
    });
    totalBytes += size;
  }

  final packSha256 = _computePackSha256(verifiedAssets);
  final shortHash = packSha256.substring(0, 8);
  final expectedDataVersion = '$shortHash-v1';
  final expectedTag = 'watermark-fonts-$shortHash-v1';

  if (options.updateLock) {
    lock['dataVersion'] = expectedDataVersion;
    release['tag'] = expectedTag;
    lock['output'] = {
      'packSha256': packSha256,
      'totalBytes': totalBytes,
      'fontCount': verifiedAssets.length,
    };
  } else {
    if (dataVersion != expectedDataVersion) {
      throw StateError(
        'Locked dataVersion ($dataVersion) does not match pack hash '
        '($expectedDataVersion)',
      );
    }
    if (releaseTag != expectedTag) {
      throw StateError(
        'Locked release tag ($releaseTag) does not match pack hash '
        '($expectedTag)',
      );
    }
    final output = _asStringMap(lock['output']);
    if (output['packSha256'] != packSha256 ||
        output['totalBytes'] != totalBytes ||
        output['fontCount'] != verifiedAssets.length) {
      throw StateError('Locked output summary does not match staged font pack');
    }
  }

  final effectiveTag = release['tag'] as String;
  final effectiveAssets = [
    for (final asset in verifiedAssets)
      WatermarkFontAsset(
        family: asset.family,
        fileName: asset.fileName,
        size: asset.size,
        sha256: asset.sha256,
        downloadUri: Uri.parse(
          'https://github.com/$repository/releases/download/'
          '$effectiveTag/${asset.fileName}',
        ),
      ),
  ];

  final manifest = WatermarkFontPackManifest(
    dataVersion: lock['dataVersion'] as String,
    releaseTag: effectiveTag,
    fonts: effectiveAssets,
  );
  final encodedManifest = _encodePrettyJson(manifest.toJson());
  // Round-trip through the production parser to guarantee client compatibility.
  WatermarkFontPackManifest.parse(encodedManifest);

  await manifestFile.writeAsString(encodedManifest, flush: true);

  final clientManifestFile = File(options.clientManifestPath).absolute;
  if (options.updateLock) {
    await _writeJson(lockFile, lock);
    await clientManifestFile.parent.create(recursive: true);
    await clientManifestFile.writeAsString(encodedManifest, flush: true);
  } else {
    if (!await clientManifestFile.exists()) {
      throw StateError(
        'Missing locked client manifest: ${clientManifestFile.path}',
      );
    }
    final lockedClientBytes = await clientManifestFile.readAsBytes();
    final stagedManifestBytes = await manifestFile.readAsBytes();
    final matchesExact = _bytesEqual(lockedClientBytes, stagedManifestBytes);
    final matchesWindowsNormalized =
        Platform.isWindows &&
        (await clientManifestFile.readAsString()).replaceAll('\r\n', '\n') ==
            encodedManifest;
    if (!matchesExact && !matchesWindowsNormalized) {
      throw StateError(
        'Staged manifest does not match locked client manifest byte-for-byte: '
        '${clientManifestFile.path}',
      );
    }
  }

  await _writeJson(reportFile, {
    'toolVersion': _toolVersion,
    'dataVersion': manifest.dataVersion,
    'releaseTag': manifest.releaseTag,
    'packSha256': packSha256,
    'fontCount': effectiveAssets.length,
    'totalBytes': totalBytes,
    'fonts': reportEntries,
  });

  stdout.writeln(
    'Verified watermark font pack (${manifest.releaseTag})\n'
    '  fonts: ${effectiveAssets.length}\n'
    '  total bytes: $totalBytes\n'
    '  pack sha256: $packSha256\n'
    '  staged manifest: ${manifestFile.path}\n'
    '  report: ${reportFile.path}',
  );
}

void _validateLock(Map<String, dynamic> lock) {
  if (lock['schemaVersion'] != _lockSchemaVersion) {
    throw StateError('Unsupported source lock schemaVersion');
  }
  if (lock['toolVersion'] != _toolVersion) {
    throw StateError(
      'Source lock toolVersion must be $_toolVersion, got '
      '${lock['toolVersion']}',
    );
  }
  final dataVersion = lock['dataVersion'];
  if (dataVersion is! String || dataVersion.isEmpty) {
    throw StateError('Source lock dataVersion is required');
  }
  final release = _asStringMap(lock['release']);
  final tag = release['tag'];
  if (tag is! String ||
      !tag.startsWith('watermark-fonts-') ||
      tag.startsWith('v')) {
    throw StateError(
      'Release tag must start with watermark-fonts- and not use v* namespace',
    );
  }
  if (release['prerelease'] != true || release['makeLatest'] != false) {
    throw StateError(
      'Font pack release must set prerelease=true and makeLatest=false',
    );
  }
  if (release['repository'] != 'Aaalice233/Aaalice_NAI_Launcher') {
    throw StateError('Unexpected release repository: ${release['repository']}');
  }
  final fonts = lock['fonts'];
  if (fonts is! List || fonts.isEmpty) {
    throw StateError('Source lock must declare at least one font');
  }
}

Future<void> _verifyFontBinary(File file, {required String fileName}) async {
  final length = await file.length();
  if (length < 1024) {
    throw StateError('Font file is unexpectedly small ($length B): $fileName');
  }
  final header = await file.openRead(0, 4).expand((chunk) => chunk).toList();
  final magic = String.fromCharCodes(header);
  if (magic != '\u0000\u0001\u0000\u0000' && magic != 'OTTO') {
    throw StateError('Invalid OpenType/TrueType sfnt header in $fileName');
  }
}

Future<void> _verifyFontLicense(
  String licenseDirectoryPath, {
  required String fileName,
}) async {
  final oflFile = File('$licenseDirectoryPath/OFL.txt');
  final upstreamFile = File('$licenseDirectoryPath/upstream_info.md');
  if (!await oflFile.exists()) {
    throw StateError('Missing OFL.txt for $fileName at ${oflFile.path}');
  }
  if (!await upstreamFile.exists()) {
    throw StateError(
      'Missing upstream_info.md for $fileName at ${upstreamFile.path}',
    );
  }
  final oflText = await oflFile.readAsString();
  if (!oflText.contains('SIL OPEN FONT LICENSE')) {
    throw StateError('Invalid OFL license text for $fileName');
  }
}

String _computePackSha256(List<WatermarkFontAsset> assets) {
  final sorted = List<WatermarkFontAsset>.of(assets)
    ..sort((a, b) => a.fileName.compareTo(b.fileName));
  final buffer = StringBuffer();
  for (final asset in sorted) {
    buffer.writeln('${asset.fileName}:${asset.size}:${asset.sha256}');
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

Future<String> _sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

String _encodePrettyJson(Map<String, dynamic> data) =>
    '${const JsonEncoder.withIndent('  ').convert(data)}\n';

Future<void> _writeJson(File file, Map<String, dynamic> data) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(_encodePrettyJson(data), flush: true);
}

Map<String, dynamic> _asStringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, entry) => MapEntry('$key', entry));
  }
  throw StateError('Expected JSON object, got ${value.runtimeType}');
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Options {
  const _Options({
    required this.lockPath,
    required this.outputDirectory,
    required this.clientManifestPath,
    required this.updateLock,
    this.sourceDirectory,
  });

  final String lockPath;
  final String outputDirectory;
  final String clientManifestPath;
  final bool updateLock;
  final String? sourceDirectory;

  static _Options parse(List<String> arguments) {
    var lockPath = _defaultLockPath;
    var outputDirectory = _defaultOutputDirectory;
    var clientManifestPath = _defaultClientManifestPath;
    var updateLock = false;
    String? sourceDirectory;

    for (final argument in arguments) {
      if (argument == '--update-lock') {
        updateLock = true;
      } else if (argument.startsWith('--lock=')) {
        lockPath = argument.substring('--lock='.length);
      } else if (argument.startsWith('--output-dir=')) {
        outputDirectory = argument.substring('--output-dir='.length);
      } else if (argument.startsWith('--client-manifest=')) {
        clientManifestPath = argument.substring('--client-manifest='.length);
      } else if (argument.startsWith('--source-dir=')) {
        sourceDirectory = argument.substring('--source-dir='.length);
      } else {
        throw ArgumentError('Unknown argument: $argument');
      }
    }

    return _Options(
      lockPath: lockPath,
      outputDirectory: outputDirectory,
      clientManifestPath: clientManifestPath,
      updateLock: updateLock,
      sourceDirectory: sourceDirectory,
    );
  }
}
