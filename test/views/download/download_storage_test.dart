import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haka_comic/views/download/download_storage.dart';
import 'package:haka_comic/views/download/download_storage_migration.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  test('local storage copies, materializes, and deletes downloads', () async {
    final sourceRoot = await Directory.systemTemp.createTemp('haka_source_');
    final destinationRoot = await Directory.systemTemp.createTemp('haka_dest_');
    addTearDown(() async {
      if (await sourceRoot.exists()) await sourceRoot.delete(recursive: true);
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final chapter = Directory(p.join(sourceRoot.path, '漫画', '1_第一话'));
    await chapter.create(recursive: true);
    await File(p.join(chapter.path, '0001.jpg')).writeAsBytes([1, 2, 3]);
    await File(p.join(chapter.path, '0002.jpg')).writeAsBytes([4, 5]);
    await File(p.join(chapter.path, '0003.jpg.part')).writeAsBytes([9]);

    final storage = DownloadStorage.local(destinationRoot.path);
    final sourceStorage = DownloadStorage.local(sourceRoot.path);
    final sourceStats = await sourceStorage.directoryStats('漫画');
    expect(sourceStats.fileCount, 2);
    expect(sourceStats.totalBytes, 5);

    var copiedBytes = 0;
    await storage.copyLocalDirectoryInto(
      source: Directory(p.join(sourceRoot.path, '漫画')),
      destinationRelativePath: '漫画',
      onProgress: (bytes) => copiedBytes += bytes,
    );

    expect(copiedBytes, 5);
    expect(await storage.fileExists('漫画/1_第一话/0001.jpg'), isTrue);
    expect(await storage.fileExists('漫画/1_第一话/0003.jpg.part'), isFalse);
    expect(await storage.directoryExists('漫画/1_第一话'), isTrue);

    final stats = await storage.directoryStats('漫画');
    expect(stats.fileCount, 2);
    expect(stats.totalBytes, 5);
    expect(
      await storage.materializeDirectory('漫画'),
      p.join(destinationRoot.path, '漫画'),
    );

    await storage.deleteDirectory('漫画');
    expect(await storage.directoryExists('漫画'), isFalse);
  });

  test('migration cleanup only removes copied destination folders', () async {
    final destinationRoot = await Directory.systemTemp.createTemp(
      'haka_migration_cleanup_',
    );
    addTearDown(() async {
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final storage = DownloadStorage.local(destinationRoot.path);
    await File(
      p.join(destinationRoot.path, '已迁移漫画', '1_第一话', '0001.jpg'),
    ).create(recursive: true);
    final unrelatedFile = File(p.join(destinationRoot.path, '其他文件', '保留.txt'));
    await unrelatedFile.parent.create(recursive: true);
    await unrelatedFile.writeAsString('keep', flush: true);

    await DownloadStorageMigrator().cleanupDestination(
      destination: storage,
      result: const DownloadStorageMigrationResult(folderNames: ['已迁移漫画']),
    );

    expect(await storage.directoryExists('已迁移漫画'), isFalse);
    expect(await storage.fileExists('其他文件/保留.txt'), isTrue);
  });

  test('local storage rejects parent traversal paths', () async {
    final root = await Directory.systemTemp.createTemp('haka_storage_root_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final storage = DownloadStorage.local(root.path);
    expect(
      () => storage.absoluteFilePath('../outside.jpg'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('storage descriptors preserve and compare locations', () {
    final local = DownloadStorage.local(p.join('root', 'downloads'));
    final restoredLocal = DownloadStorage.fromDescriptor(local.toDescriptor());
    expect(restoredLocal.hasSameLocation(local), isTrue);

    final saf = DownloadStorage.androidSaf(
      treeUri: 'content://provider/tree/downloads',
      displayName: 'Downloads',
    );
    final restoredSaf = DownloadStorage.fromDescriptor(saf.toDescriptor());
    expect(restoredSaf.hasSameLocation(saf), isTrue);
  });

  test('desktop storage prefers the atomic location setting', () async {
    final atomicRoot = await Directory.systemTemp.createTemp(
      'haka_atomic_location_',
    );
    final legacyRoot = await Directory.systemTemp.createTemp(
      'haka_legacy_location_',
    );
    addTearDown(() async {
      if (await atomicRoot.exists()) await atomicRoot.delete(recursive: true);
      if (await legacyRoot.exists()) await legacyRoot.delete(recursive: true);
    });

    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'desktopDownloadLocation': jsonEncode({
            'path': atomicRoot.path,
            'bookmark': null,
          }),
          'desktopDownloadDirectory': legacyRoot.path,
        });

    final storage = await DownloadStorage.load();
    expect(storage.localRootPath, atomicRoot.path);
  });

  test('pending migration removes an uncommitted destination', () async {
    final sourceRoot = await Directory.systemTemp.createTemp(
      'haka_recovery_source_',
    );
    final destinationRoot = await Directory.systemTemp.createTemp(
      'haka_recovery_destination_',
    );
    addTearDown(() async {
      if (await sourceRoot.exists()) await sourceRoot.delete(recursive: true);
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final partialFolder = Directory(p.join(destinationRoot.path, '半成品漫画'));
    await partialFolder.create(recursive: true);
    await File(p.join(partialFolder.path, '0001.jpg')).writeAsBytes([1]);

    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'desktopDownloadDirectory': sourceRoot.path,
          'pendingDownloadStorageMigration': jsonEncode({
            'destination': DownloadStorage.local(
              destinationRoot.path,
            ).toDescriptor(),
            'folderNames': ['半成品漫画'],
          }),
        });

    await DownloadStorageMigrator.recoverPendingMigration();

    expect(await partialFolder.exists(), isFalse);
    expect(
      await SharedPreferencesAsync().getString(
        'pendingDownloadStorageMigration',
      ),
      isNull,
    );
  });

  test('pending migration keeps a committed destination', () async {
    final destinationRoot = await Directory.systemTemp.createTemp(
      'haka_committed_destination_',
    );
    addTearDown(() async {
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final completedFolder = Directory(p.join(destinationRoot.path, '完整漫画'));
    await completedFolder.create(recursive: true);
    await File(p.join(completedFolder.path, '0001.jpg')).writeAsBytes([1]);
    final destination = DownloadStorage.local(destinationRoot.path);

    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'desktopDownloadDirectory': destinationRoot.path,
          'pendingDownloadStorageMigration': jsonEncode({
            'destination': destination.toDescriptor(),
            'folderNames': ['完整漫画'],
          }),
        });

    await DownloadStorageMigrator.recoverPendingMigration();

    expect(await completedFolder.exists(), isTrue);
    expect(
      await SharedPreferencesAsync().getString(
        'pendingDownloadStorageMigration',
      ),
      isNull,
    );
  });
}
