class WatermarkFontOption {
  const WatermarkFontOption({
    required this.family,
    required this.sample,
    required this.supportsCjk,
    this.isBundled = false,
  });

  final String family;
  final String sample;
  final bool supportsCjk;
  final bool isBundled;
}

class WatermarkFontCatalog {
  const WatermarkFontCatalog._();

  static const defaultFamily = 'LXGW ZhenKai GB';

  static const options = <WatermarkFontOption>[
    WatermarkFontOption(
      family: defaultFamily,
      sample: 'Aaalice 水印',
      supportsCjk: true,
      isBundled: true,
    ),
    WatermarkFontOption(
      family: 'Ma Shan Zheng',
      sample: 'Aaalice 山水',
      supportsCjk: true,
    ),
    WatermarkFontOption(
      family: 'Zhi Mang Xing',
      sample: 'Aaalice 行书',
      supportsCjk: true,
    ),
    WatermarkFontOption(
      family: 'Long Cang',
      sample: 'Aaalice 墨迹',
      supportsCjk: true,
    ),
    WatermarkFontOption(
      family: 'Great Vibes',
      sample: 'Aaalice Signature',
      supportsCjk: false,
    ),
    WatermarkFontOption(
      family: 'Caveat',
      sample: 'Aaalice Studio',
      supportsCjk: false,
    ),
    WatermarkFontOption(
      family: 'Allura',
      sample: 'Aaalice Art',
      supportsCjk: false,
    ),
  ];

  static const fallbackFamilies = <String>[defaultFamily];

  static bool contains(String family) =>
      options.any((option) => option.family == family);

  static bool isBundled(String family) => family == defaultFamily;

  static bool isDownloadable(String family) =>
      options.any((option) => option.family == family && !option.isBundled);
}
