import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:haka_comic/config/app_config.dart';
import 'package:haka_comic/utils/common.dart';
import 'package:haka_comic/utils/macos_security_scoped_bookmark.dart';
import 'package:haka_comic/utils/native_folder_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

typedef DownloadStorageProgress = void Function(int copiedBytes);

class DownloadStorage {
  const DownloadStorage._({
    required this.localRootPath,
    required this.androidTreeUri,
    required this.displayName,
  });

  factory DownloadStorage.local(String path, {String? displayName}) {
    return DownloadStorage._(
      localRootPath: path,
      androidTreeUri: null,
      displayName: displayName ?? path,
    );
  }

  factory DownloadStorage.androidSaf({
    required String treeUri,
    required String displayName,
  }) {
    return DownloadStorage._(
      localRootPath: null,
      androidTreeUri: treeUri,
      displayName: displayName,
    );
  }

  final String? localRootPath;
  final String? androidTreeUri;
  final String displayName;

  bool get isAndroidSaf => androidTreeUri != null;

  Map<String, Object?> toDescriptor() => {
    'type': isAndroidSaf ? 'androidSaf' : 'local',
    'location': androidTreeUri ?? localRootPath,
    'displayName': displayName,
  };

  static DownloadStorage fromDescriptor(Map<String, Object?> descriptor) {
    final type = descriptor['type'] as String?;
    final location = descriptor['location'] as String?;
    final displayName = descriptor['displayName'] as String?;
    if (location == null || location.isEmpty) {
      throw const FormatException('Invalid download storage descriptor');
    }
    if (type == 'androidSaf') {
      return DownloadStorage.androidSaf(
        treeUri: location,
        displayName: displayName ?? '已选择的文件夹',
      );
    }
    if (type == 'local') {
      return DownloadStorage.local(location, displayName: displayName);
    }
    throw const FormatException('Unknown download storage descriptor');
  }

  bool hasSameLocation(DownloadStorage other) {
    final treeUri = androidTreeUri;
    final otherTreeUri = other.androidTreeUri;
    if (treeUri != null || otherTreeUri != null) {
      return treeUri != null && treeUri == otherTreeUri;
    }
    final root = localRootPath;
    final otherRoot = other.localRootPath;
    if (root == null || otherRoot == null) return false;
    return p.equals(p.canonicalize(root), p.canonicalize(otherRoot));
  }

  static Future<DownloadStorage> load() async {
    if (isAndroid) {
      final prefs = SharedPreferencesAsync();
      final treeUri = await prefs.getString('androidDownloadTreeUri');
      final treeName = await prefs.getString('androidDownloadTreeName');
      if (treeUri != null && treeUri.isNotEmpty) {
        return DownloadStorage.androidSaf(
          treeUri: treeUri,
          displayName: treeName ?? '已选择的文件夹',
        );
      }
    }

    if (isDesktop) {
      final prefs = SharedPreferencesAsync();
      final encodedLocation = await prefs.getString('desktopDownloadLocation');
      String? customPath;
      String? bookmark;
      if (encodedLocation != null && encodedLocation.isNotEmpty) {
        try {
          final decoded = jsonDecode(encodedLocation);
          if (decoded is Map) {
            final decodedPath = decoded['path'];
            final decodedBookmark = decoded['bookmark'];
            customPath = decodedPath is String ? decodedPath : null;
            bookmark = decodedBookmark is String ? decodedBookmark : null;
          }
        } on FormatException {
          // Fall back to the legacy keys below.
        }
      }
      customPath ??= await prefs.getString('desktopDownloadDirectory');
      if (customPath != null && customPath.isNotEmpty) {
        bookmark ??= await prefs.getString('desktopDownloadBookmark');
        final resolvedPath = await _resolveDesktopPath(customPath, bookmark);
        return DownloadStorage.local(resolvedPath ?? customPath);
      }
    }

    return DownloadStorage.local(await getDefaultDownloadDirectory());
  }

  static Future<DownloadStorage> currentFromConfig() async {
    if (isAndroid) {
      final treeUri = AppConf().androidDownloadTreeUri;
      if (treeUri != null && treeUri.isNotEmpty) {
        return DownloadStorage.androidSaf(
          treeUri: treeUri,
          displayName: AppConf().androidDownloadTreeName ?? '已选择的文件夹',
        );
      }
    }

    if (isDesktop) {
      final customPath = AppConf().desktopDownloadDirectory;
      if (customPath != null && customPath.isNotEmpty) {
        final resolvedPath = await _resolveDesktopPath(
          customPath,
          AppConf().desktopDownloadBookmark,
        );
        return DownloadStorage.local(resolvedPath ?? customPath);
      }
    }

    return DownloadStorage.local(await getDefaultDownloadDirectory());
  }

  Future<void> ensureReady() async {
    final root = localRootPath;
    if (root != null) {
      await Directory(root).create(recursive: true);
      return;
    }

    final uri = androidTreeUri!;
    if (!await NativeFolderPicker.hasPersistedPermission(uri)) {
      throw const FileSystemException('所选下载目录的访问权限已失效，请重新选择');
    }
  }

  Future<bool> fileExists(String relativePath) async {
    final root = localRootPath;
    if (root != null) {
      final file = File(_localPath(root, relativePath));
      if (!await file.exists()) return false;
      return await file.length() > 0;
    }

    return NativeFolderPicker.fileExists(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
    );
  }

  Future<bool> directoryExists(String relativePath) async {
    final root = localRootPath;
    if (root != null) {
      return Directory(_localPath(root, relativePath)).exists();
    }

    return NativeFolderPicker.directoryExists(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
    );
  }

  Future<void> writeFile({
    required String relativePath,
    required String sourcePath,
  }) async {
    final root = localRootPath;
    if (root != null) {
      final destination = File(_localPath(root, relativePath));
      await destination.parent.create(recursive: true);
      if (await destination.exists()) await destination.delete();
      await File(sourcePath).copy(destination.path);
      return;
    }

    await NativeFolderPicker.writeFile(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
      sourcePath: sourcePath,
    );
  }

  Future<String> materializeDirectory(String relativePath) async {
    final root = localRootPath;
    if (root != null) return _localPath(root, relativePath);

    return NativeFolderPicker.materializeDirectory(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
    );
  }

  Future<String?> materializeFile(String relativePath) async {
    if (!await fileExists(relativePath)) return null;

    final root = localRootPath;
    if (root != null) return _localPath(root, relativePath);

    return NativeFolderPicker.materializeFile(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
    );
  }

  Future<void> deleteDirectory(String relativePath) async {
    final root = localRootPath;
    if (root != null) {
      final directory = Directory(_localPath(root, relativePath));
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    }

    await NativeFolderPicker.deleteDirectory(
      treeUri: androidTreeUri!,
      relativePath: _safPath(relativePath),
    );
  }

  Future<NativeDirectoryStats> directoryStats(String relativePath) async {
    final root = localRootPath;
    if (root == null) {
      return NativeFolderPicker.directoryStats(
        treeUri: androidTreeUri!,
        relativePath: _safPath(relativePath),
      );
    }

    final directory = Directory(_localPath(root, relativePath));
    if (!await directory.exists()) {
      return const NativeDirectoryStats(fileCount: 0, totalBytes: 0);
    }

    var fileCount = 0;
    var totalBytes = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && !entity.path.endsWith('.part')) {
        fileCount += 1;
        totalBytes += await entity.length();
      }
    }
    return NativeDirectoryStats(fileCount: fileCount, totalBytes: totalBytes);
  }

  Future<void> copyLocalDirectoryInto({
    required Directory source,
    required String destinationRelativePath,
    DownloadStorageProgress? onProgress,
  }) async {
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.part')) continue;
      final childPath = p.relative(entity.path, from: source.path);
      final relativePath = p.posix.join(
        _safPath(destinationRelativePath),
        childPath.replaceAll('\\', '/'),
      );
      await writeFile(relativePath: relativePath, sourcePath: entity.path);
      onProgress?.call(await entity.length());
    }
  }

  String? absoluteFilePath(String relativePath) {
    final root = localRootPath;
    return root == null ? null : _localPath(root, relativePath);
  }

  static String _localPath(String root, String relativePath) {
    final parts = _safPath(
      relativePath,
    ).split('/').where((part) => part.isNotEmpty);
    return p.joinAll([root, ...parts]);
  }

  static String _safPath(String path) {
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.any((part) => part == '.' || part == '..')) {
      throw FileSystemException('下载路径包含无效目录段', path);
    }
    return parts.join('/');
  }

  static Future<String?> _resolveDesktopPath(
    String path,
    String? bookmark,
  ) async {
    if (!isMacOS) return path;
    if (bookmark == null || bookmark.isEmpty) return null;
    try {
      return await MacOsSecurityScopedBookmark.resolve(bookmark);
    } on PlatformException {
      return null;
    }
  }
}
