import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../constants/storage_keys.dart';
import 'proxy_service.dart';
import 'system_proxy_http_overrides.dart';
import '../platform/platform_capabilities.dart';
import '../storage/local_storage_service.dart';
import '../../data/models/settings/proxy_settings.dart';

part 'proxy_settings_provider.g.dart';

/// 代理开关的平台默认值：桌面启用，移动端不启用。
///
/// 偏离上游：上游 [ProxySettingsNotifier.build] 是 `?? true`，全平台默认开启
/// （桌面靠系统代理自动探测，代价很低）。手机通常直连，而且读不到系统代理，
/// 默认开着只会让人以为「已经走代理了」，所以移动端默认关闭。
///
/// 启动期注入 `HttpOverrides.global` 的 `resolveStartupProxyAddress`
/// （startup_initialization_provider.dart）读的是同一个默认值，两处必须保持一致，
/// 否则手机首启会出现「设置页显示未启用、实际却注入了代理」。
bool defaultProxyEnabled(PlatformCapabilities capabilities) =>
    !capabilities.isMobile;

/// 把存储里的代理模式解析成当前平台真正可用的模式。
///
/// [ProxyService.getSystemProxyAddress] 只实现了 Windows / macOS / Linux，
/// 移动端的 auto 永远拿不到地址，所以移动端一律按 manual 解析。只在读取时
/// 折算、不回写存储，同一份设置同步到桌面端时用户原来的选择仍然有效。
ProxyMode resolveProxyMode(
  ProxyMode storedMode,
  PlatformCapabilities capabilities,
) => capabilities.isMobile ? ProxyMode.manual : storedMode;

/// 代理设置状态 Notifier
@riverpod
class ProxySettingsNotifier extends _$ProxySettingsNotifier {
  @override
  ProxySettings build() {
    final storage = ref.read(localStorageServiceProvider);
    final capabilities = PlatformCapabilities.current;

    // 从本地存储读取代理设置
    final enabled =
        storage.getSetting<bool>(StorageKeys.proxyEnabled) ??
        defaultProxyEnabled(capabilities);
    final modeStr = storage.getSetting<String>(StorageKeys.proxyMode) ?? 'auto';
    final manualHost = storage.getSetting<String>(StorageKeys.proxyManualHost);
    final manualPort = storage.getSetting<int>(StorageKeys.proxyManualPort);

    // 解析模式
    ProxyMode mode;
    try {
      mode = ProxyMode.values.byName(modeStr);
    } catch (_) {
      mode = ProxyMode.auto;
    }

    return ProxySettings(
      enabled: enabled,
      mode: resolveProxyMode(mode, capabilities),
      manualHost: manualHost,
      manualPort: manualPort,
    );
  }

  /// 设置是否启用代理
  Future<void> setEnabled(bool value) async {
    _applySettings(state.copyWith(enabled: value));
    final storage = ref.read(localStorageServiceProvider);
    await storage.setSetting(StorageKeys.proxyEnabled, value);
  }

  /// 设置代理模式
  Future<void> setMode(ProxyMode mode) async {
    _applySettings(state.copyWith(mode: mode));
    final storage = ref.read(localStorageServiceProvider);
    await storage.setSetting(StorageKeys.proxyMode, mode.name);
  }

  /// 设置手动代理地址
  Future<void> setManualProxy(String host, int port) async {
    _applySettings(state.copyWith(manualHost: host, manualPort: port));
    final storage = ref.read(localStorageServiceProvider);
    await storage.setSetting(StorageKeys.proxyManualHost, host);
    await storage.setSetting(StorageKeys.proxyManualPort, port);
  }

  /// 清除手动代理设置
  Future<void> clearManualProxy() async {
    _applySettings(ProxySettings(enabled: state.enabled, mode: state.mode));
    final storage = ref.read(localStorageServiceProvider);
    await storage.deleteSetting(StorageKeys.proxyManualHost);
    await storage.deleteSetting(StorageKeys.proxyManualPort);
  }

  void _applySettings(ProxySettings settings) {
    // 先更新实际路由，再通知依赖这些设置的客户端重建。
    SystemProxyHttpOverrides.applyProxyAddress(settings.effectiveProxyAddress);
    state = settings;
    ref.invalidate(detectedSystemProxyProvider);
  }
}

/// 当前有效的代理地址
///
/// 供其他组件订阅，用于判断是否需要使用代理
@riverpod
String? currentProxyAddress(Ref ref) {
  final settings = ref.watch(proxySettingsNotifierProvider);
  return settings.effectiveProxyAddress;
}

/// 检测到的系统代理地址
///
/// 用于在 UI 中显示当前系统代理配置
@riverpod
String? detectedSystemProxy(Ref ref) {
  return ProxyService.getSystemProxyAddress();
}
