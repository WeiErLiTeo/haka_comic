import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:haka_comic/database/download_task_helper.dart';
import 'package:haka_comic/utils/extension.dart';
import 'package:haka_comic/utils/log.dart';
import 'package:haka_comic/utils/native_folder_picker.dart';
import 'package:haka_comic/views/download/download_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DownloadMigrationStage { preparing, copying, verifying, cleaning }

class DownloadMigrationProgress {
  const DownloadMigrationProgress({
    required this.stage,
    required this.copiedBytes,
    required this.totalBytes,
    this.currentFolder,
  });

  final DownloadMigrationStage stage;
  final int copiedBytes;
  final int totalBytes;
  final String? currentFolder;

  double? get fraction {
    if (totalBytes <= 0) return null;
    return (copiedBytes / totalBytes).clamp(0, 1);
  }
}

class DownloadStorageMigrationResult {
  const DownloadStorageMigrationResult({required this.folderNames});

  final List<String> folderNames;
}

class DownloadStorageMigrator {
  DownloadStorageMigrator({DownloadTaskHelper? helper})
    : _helper = helper ?? DownloadTaskHelper();

  static const _pendingMigrationKey = 'pendingDownloadStorageMigration';

  final DownloadTaskHelper _helper;

  static Future<void> recoverPendingMigration() async {
    final prefs = SharedPreferencesAsync();
    final encoded = await prefs.getString(_pendingMigrationKey);
    if (encoded == null || encoded.isEmpty) return;

    late final _PendingMigrationJournal journal;
    try {
      journal = _decodeJournal(encoded);
    } catch (_) {
      await prefs.remove(_pendingMigrationKey);
      rethrow;
    }
    final destination = DownloadStorage.fromDescriptor(journal.destination);
    final current = await DownloadStorage.load();
    if (current.hasSameLocation(destination)) {
      await prefs.remove(_pendingMigrationKey);
      return;
    }

    final cleaned = await _cleanupFolders(
      destination,
      journal.folderNames,
      logPrefix: 'recover pending migration destination',
    );
    if (!cleaned) {
      throw const FileSystemException('无法清理上次迁移留下的目标目录');
    }
    await prefs.remove(_pendingMigrationKey);
  }

  static Future<void> markPendingMigrationCommitted() async {
    await SharedPreferencesAsync().remove(_pendingMigrationKey);
  }

  Future<DownloadStorageMigrationResult> copyAndVerify({
    required DownloadStorage source,
    required DownloadStorage destination,
    required ValueChanged<DownloadMigrationProgress> onProgress,
  }) async {
    await recoverPendingMigration();
    await source.ensureReady();
    await destination.ensureReady();

    final tasks = await _helper.getAll();
    final folderNames = tasks
        .map((task) => task.comic.title.legalized)
        .toSet()
        .toList();

    onProgress(
      const DownloadMigrationProgress(
        stage: DownloadMigrationStage.preparing,
        copiedBytes: 0,
        totalBytes: 0,
      ),
    );

    var totalBytes = 0;
    for (final folderName in folderNames) {
      final stats = await source.directoryStats(folderName);
      totalBytes += stats.totalBytes;
      if (await destination.directoryExists(folderName)) {
        throw FileSystemException('目标位置已存在同名漫画目录', folderName);
      }
    }

    await _writePendingMigration(
      destination: destination,
      folderNames: folderNames,
    );

    final createdFolders = <String>[];
    try {
      var copiedBytes = 0;
      for (final folderName in folderNames) {
        if (!await source.directoryExists(folderName)) continue;

        onProgress(
          DownloadMigrationProgress(
            stage: DownloadMigrationStage.copying,
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            currentFolder: folderName,
          ),
        );

        Directory? materialized;
        try {
          final sourcePath = source.absoluteFilePath(folderName);
          final localSource = sourcePath != null
              ? Directory(sourcePath)
              : materialized = Directory(
                  await source.materializeDirectory(folderName),
                );

          createdFolders.add(folderName);
          await destination.copyLocalDirectoryInto(
            source: localSource,
            destinationRelativePath: folderName,
            onProgress: (bytes) {
              copiedBytes += bytes;
              onProgress(
                DownloadMigrationProgress(
                  stage: DownloadMigrationStage.copying,
                  copiedBytes: copiedBytes,
                  totalBytes: totalBytes,
                  currentFolder: folderName,
                ),
              );
            },
          );

          final expected = await _localDirectoryStats(localSource);
          onProgress(
            DownloadMigrationProgress(
              stage: DownloadMigrationStage.verifying,
              copiedBytes: copiedBytes,
              totalBytes: totalBytes,
              currentFolder: folderName,
            ),
          );
          final actual = await destination.directoryStats(folderName);
          if (actual.fileCount != expected.fileCount ||
              actual.totalBytes != expected.totalBytes) {
            throw FileSystemException('迁移后的文件校验失败', folderName);
          }
        } finally {
          if (materialized != null && await materialized.exists()) {
            await materialized.delete(recursive: true);
          }
        }
      }

      onProgress(
        DownloadMigrationProgress(
          stage: DownloadMigrationStage.verifying,
          copiedBytes: totalBytes,
          totalBytes: totalBytes,
        ),
      );
      return DownloadStorageMigrationResult(folderNames: createdFolders);
    } catch (_) {
      final cleaned = await _cleanupFolders(
        destination,
        createdFolders.reversed,
        logPrefix: 'cleanup failed migration target',
      );
      if (cleaned) {
        await markPendingMigrationCommitted();
      }
      rethrow;
    }
  }

  Future<void> cleanupSource({
    required DownloadStorage source,
    required DownloadStorageMigrationResult result,
    required ValueChanged<DownloadMigrationProgress> onProgress,
  }) async {
    for (final folderName in result.folderNames) {
      onProgress(
        DownloadMigrationProgress(
          stage: DownloadMigrationStage.cleaning,
          copiedBytes: 1,
          totalBytes: 1,
          currentFolder: folderName,
        ),
      );
      try {
        await source.deleteDirectory(folderName);
      } catch (error, stackTrace) {
        Log.w(
          'cleanup old download directory failed ($folderName)',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<bool> cleanupDestination({
    required DownloadStorage destination,
    required DownloadStorageMigrationResult result,
  }) async {
    final cleaned = await _cleanupFolders(
      destination,
      result.folderNames.reversed,
      logPrefix: 'cleanup failed migration destination',
    );
    if (cleaned) {
      await markPendingMigrationCommitted();
    }
    return cleaned;
  }

  Future<NativeDirectoryStats> _localDirectoryStats(Directory directory) async {
    var fileCount = 0;
    var totalBytes = 0;
    if (!await directory.exists()) {
      return const NativeDirectoryStats(fileCount: 0, totalBytes: 0);
    }

    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && !entity.path.endsWith('.part')) {
        fileCount += 1;
        totalBytes += await entity.length();
      }
    }
    return NativeDirectoryStats(fileCount: fileCount, totalBytes: totalBytes);
  }

  static Future<void> _writePendingMigration({
    required DownloadStorage destination,
    required List<String> folderNames,
  }) async {
    final journal = <String, Object?>{
      'destination': destination.toDescriptor(),
      'folderNames': folderNames,
    };
    await SharedPreferencesAsync().setString(
      _pendingMigrationKey,
      jsonEncode(journal),
    );
  }

  static _PendingMigrationJournal _decodeJournal(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid download migration journal');
    }
    final rawDestination = decoded['destination'];
    final rawFolderNames = decoded['folderNames'];
    if (rawDestination is! Map || rawFolderNames is! List) {
      throw const FormatException('Invalid download migration journal');
    }
    return _PendingMigrationJournal(
      destination: Map<String, Object?>.from(rawDestination),
      folderNames: rawFolderNames.whereType<String>().toList(),
    );
  }

  static Future<bool> _cleanupFolders(
    DownloadStorage storage,
    Iterable<String> folderNames, {
    required String logPrefix,
  }) async {
    var succeeded = true;
    for (final folderName in folderNames) {
      try {
        await storage.deleteDirectory(folderName);
      } catch (error, stackTrace) {
        succeeded = false;
        Log.w('$logPrefix ($folderName)', error: error, stackTrace: stackTrace);
      }
    }
    return succeeded;
  }
}

class _PendingMigrationJournal {
  const _PendingMigrationJournal({
    required this.destination,
    required this.folderNames,
  });

  final Map<String, Object?> destination;
  final List<String> folderNames;
}
