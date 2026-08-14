import 'package:flutter/services.dart';

class PickedFolderSnapshotFile {
  final String name;
  final String relativePath;
  final String localPath;
  final int size;
  final String? mimeType;

  const PickedFolderSnapshotFile({
    required this.name,
    required this.relativePath,
    required this.localPath,
    required this.size,
    required this.mimeType,
  });

  factory PickedFolderSnapshotFile.fromMap(Map<Object?, Object?> map) {
    return PickedFolderSnapshotFile(
      name: map['name'] as String? ?? '',
      relativePath: map['relativePath'] as String? ?? '',
      localPath: map['localPath'] as String? ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
      mimeType: map['mimeType'] as String?,
    );
  }
}

class PickedFolderSnapshot {
  final String name;
  final String localPath;
  final List<PickedFolderSnapshotFile> files;

  const PickedFolderSnapshot({
    required this.name,
    required this.localPath,
    required this.files,
  });

  factory PickedFolderSnapshot.fromMap(Map<Object?, Object?> map) {
    final rawFiles = map['files'] as List<Object?>? ?? const [];
    return PickedFolderSnapshot(
      name: map['name'] as String? ?? '',
      localPath: map['localPath'] as String? ?? '',
      files: rawFiles
          .whereType<Map<Object?, Object?>>()
          .map(PickedFolderSnapshotFile.fromMap)
          .toList(),
    );
  }
}

class PickedWritableFolder {
  final String uri;
  final String name;

  const PickedWritableFolder({required this.uri, required this.name});

  factory PickedWritableFolder.fromMap(Map<Object?, Object?> map) {
    return PickedWritableFolder(
      uri: map['uri'] as String? ?? '',
      name: map['name'] as String? ?? '已选择的文件夹',
    );
  }
}

class NativeDirectoryStats {
  final int fileCount;
  final int totalBytes;

  const NativeDirectoryStats({
    required this.fileCount,
    required this.totalBytes,
  });

  factory NativeDirectoryStats.fromMap(Map<Object?, Object?> map) {
    return NativeDirectoryStats(
      fileCount: (map['fileCount'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class NativeFolderPicker {
  static const MethodChannel _channel = MethodChannel(
    'haka_comic/folder_picker',
  );
  static final Map<String, void Function(int)> _copyProgressCallbacks = {};
  static var _copyOperationCounter = 0;
  static var _methodCallHandlerInitialized = false;

  static void _ensureMethodCallHandler() {
    if (_methodCallHandlerInitialized) return;
    _methodCallHandlerInitialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'copyLocalDirectoryProgress') return;
      final arguments = call.arguments;
      if (arguments is! Map<Object?, Object?>) return;

      final operationId = arguments['operationId'] as String?;
      final copiedBytes = (arguments['copiedBytes'] as num?)?.toInt();
      if (operationId == null || copiedBytes == null) return;
      _copyProgressCallbacks[operationId]?.call(copiedBytes);
    });
  }

  static Future<PickedFolderSnapshot?> pickDirectorySnapshot({
    bool recursive = true,
  }) async {
    final result = await _channel.invokeMethod<Object?>(
      'pickDirectorySnapshot',
      {'recursive': recursive},
    );
    if (result == null) {
      return null;
    }

    if (result is! Map<Object?, Object?>) {
      throw const FormatException('Invalid folder snapshot result');
    }

    return PickedFolderSnapshot.fromMap(result);
  }

  static Future<PickedWritableFolder?> pickWritableDirectory() async {
    final result = await _channel.invokeMethod<Object?>(
      'pickWritableDirectory',
    );
    if (result == null) return null;
    if (result is! Map<Object?, Object?>) {
      throw const FormatException('Invalid writable folder result');
    }
    return PickedWritableFolder.fromMap(result);
  }

  static Future<bool> hasPersistedPermission(String treeUri) async {
    return await _channel.invokeMethod<bool>('hasPersistedPermission', {
          'treeUri': treeUri,
        }) ??
        false;
  }

  static Future<String?> resolveTreePath(String treeUri) {
    return _channel.invokeMethod<String>('resolveTreePath', {
      'treeUri': treeUri,
    });
  }

  static Future<bool> areTreesNested({
    required String firstTreeUri,
    required String secondTreeUri,
  }) async {
    return await _channel.invokeMethod<bool>('areTreesNested', {
          'firstTreeUri': firstTreeUri,
          'secondTreeUri': secondTreeUri,
        }) ??
        false;
  }

  static Future<bool> fileExists({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<bool>('fileExists', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        false;
  }

  static Future<bool> directoryExists({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<bool>('directoryExists', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        false;
  }

  static Future<void> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  }) {
    return _channel.invokeMethod<void>('writeFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
      'sourcePath': sourcePath,
    });
  }

  static Future<void> copyLocalDirectoryInto({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
    void Function(int bytes)? onProgress,
  }) async {
    _ensureMethodCallHandler();
    final operationId =
        '${DateTime.now().microsecondsSinceEpoch}_${_copyOperationCounter++}';
    var reportedBytes = 0;

    if (onProgress != null) {
      _copyProgressCallbacks[operationId] = (copiedBytes) {
        final delta = copiedBytes - reportedBytes;
        if (delta <= 0) return;
        reportedBytes = copiedBytes;
        onProgress(delta);
      };
    }

    try {
      final result = await _channel
          .invokeMethod<Object?>('copyLocalDirectoryInto', {
            'treeUri': treeUri,
            'relativePath': relativePath,
            'sourcePath': sourcePath,
            'operationId': operationId,
          });
      if (result is! Map<Object?, Object?>) {
        throw const FormatException('Invalid directory copy result');
      }

      final copiedBytes = (result['copiedBytes'] as num?)?.toInt() ?? 0;
      final remainingBytes = copiedBytes - reportedBytes;
      if (remainingBytes > 0) {
        onProgress?.call(remainingBytes);
      }
    } finally {
      _copyProgressCallbacks.remove(operationId);
    }
  }

  static Future<String> materializeDirectory({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<String>('materializeDirectory', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        (throw StateError('无法读取所选下载目录'));
  }

  static Future<String> materializeFile({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<String>('materializeFile', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        (throw StateError('无法读取所选下载文件'));
  }

  static Future<void> deleteDirectory({
    required String treeUri,
    required String relativePath,
  }) {
    return _channel.invokeMethod<void>('deleteDirectory', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
  }

  static Future<NativeDirectoryStats> directoryStats({
    required String treeUri,
    required String relativePath,
  }) async {
    final result = await _channel.invokeMethod<Object?>('directoryStats', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
    if (result is! Map<Object?, Object?>) {
      throw const FormatException('Invalid directory stats result');
    }
    return NativeDirectoryStats.fromMap(result);
  }
}
