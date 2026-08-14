import 'package:flutter/services.dart';

class MacOsSecurityScopedBookmark {
  const MacOsSecurityScopedBookmark._();

  static const MethodChannel _channel = MethodChannel(
    'haka_comic/macos_security_scoped_bookmark',
  );

  static Future<String> create(String path) async {
    return await _channel.invokeMethod<String>('create', {'path': path}) ??
        (throw StateError('无法保存所选文件夹的访问权限'));
  }

  static Future<String?> resolve(String bookmark) {
    return _channel.invokeMethod<String>('resolve', {'bookmark': bookmark});
  }
}
