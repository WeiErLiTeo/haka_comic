import 'package:haka_comic/network/models.dart';
import 'package:haka_comic/utils/download_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

final migrations =
    SqliteMigrations()..add(
      SqliteMigration(1, (tx) async {
        await tx.execute('PRAGMA foreign_keys = ON;');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS download_task(
            id TEXT PRIMARY KEY,
            total INTEGER DEFAULT 0,
            completed INTEGER DEFAULT 0,
            status TEXT NOT NULL
          )
        ''');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS download_comic(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            cover TEXT NOT NULL,
            FOREIGN KEY (id) REFERENCES download_task (id) ON DELETE CASCADE
          )
        ''');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS download_chapter(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            chapter_order INTEGER NOT NULL,
            task_id TEXT NOT NULL,
            FOREIGN KEY (task_id) REFERENCES download_task (id) ON DELETE CASCADE
          )
        ''');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS chapter_image(
            id INTEGER PRIMARY KEY,
            file_server TEXT NOT NULL,
            path TEXT NOT NULL,
            original_name TEXT NOT NULL,
            chapter_id TEXT NOT NULL,
            FOREIGN KEY (chapter_id) REFERENCES download_chapter (id) ON DELETE CASCADE,
            CONSTRAINT unique_file_server_path UNIQUE (file_server, path)
          )
        ''');

        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_download_chapter_task_id 
          ON download_chapter(task_id)
        ''');

        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_chapter_image_chapter_id 
          ON chapter_image(chapter_id)
        ''');
      }),
    );

class DownloadTaskHelper {
  DownloadTaskHelper._create();

  static final _instance = DownloadTaskHelper._create();

  factory DownloadTaskHelper() => _instance;

  late SqliteDatabase _db;

  Future<void> initialize() async {
    final dbPath = (await getApplicationSupportDirectory()).path;
    _db = SqliteDatabase(path: '$dbPath/download_task.db');
    await migrations.migrate(_db);
  }

  /// Insert or update a list of download tasks
  Future<void> insert(List<ComicDownloadTask> tasks) async {
    await _db.writeTransaction((tx) async {
      for (var task in tasks) {
        await tx.execute(
          '''
            INSERT INTO download_task (id, total, completed, status)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              total = excluded.total,
              completed = excluded.completed,
              status = excluded.status
          ''',
          [task.comic.id, task.total, task.completed, task.status.name],
        );

        await tx.execute(
          '''
            INSERT INTO download_comic (id, title, cover)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              cover = excluded.cover
          ''',
          [task.comic.id, task.comic.title, task.comic.cover],
        );

        await tx.executeBatch(
          '''
            INSERT INTO download_chapter (id, title, chapter_order, task_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              chapter_order = excluded.chapter_order,
              task_id = excluded.task_id
          ''',
          task.chapters.map((chapter) {
            return [chapter.id, chapter.title, chapter.order, task.comic.id];
          }).toList(),
        );

        await tx.executeBatch(
          '''
            INSERT INTO chapter_image (file_server, path, original_name, chapter_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(file_server, path) DO UPDATE SET
              original_name = excluded.original_name,
              chapter_id = excluded.chapter_id
          ''',
          task.chapters.expand((chapter) {
            return chapter.images.map((image) {
              return [
                image.fileServer,
                image.path,
                image.originalName,
                chapter.id,
              ];
            });
          }).toList(),
        );
      }
    });
  }

  /// Get all download tasks
  Future<List<ComicDownloadTask>> getAll() async {
    final result = await _db.readTransaction((tx) async {
      return await tx.getAll('''
        SELECT 
          t.id AS task_id,
          t.total,
          t.completed,
          t.status,
          c.title AS comic_title,
          c.cover,
          ch.id AS chapter_id,
          ch.title AS chapter_title,
          ch.chapter_order,
          img.file_server,
          img.path,
          img.original_name
        FROM download_task t
        JOIN download_comic c ON t.id = c.id
        LEFT JOIN download_chapter ch ON t.id = ch.task_id
        LEFT JOIN chapter_image img ON ch.id = img.chapter_id
        ORDER BY t.id, ch.chapter_order, img.id
      ''');
    });

    // 将扁平数据组装为嵌套结构
    final tasksMap = <String, ComicDownloadTask>{};
    for (var row in result) {
      final taskId = row['task_id'];
      var task = tasksMap[taskId];
      if (task == null) {
        task = ComicDownloadTask(
          comic: DownloadComic(
            id: taskId,
            title: row['comic_title'],
            cover: row['cover'],
          ),
          chapters: [],
        );
        task.total = row['total'];
        task.completed = row['completed'];
        task.status = downloadTaskStatusFromString(row['status']);
        tasksMap[taskId] = task;
      }

      final chapterId = row['chapter_id'];
      if (chapterId != null) {
        var chapter = task.chapters.firstWhere(
          (ch) => ch.id == chapterId,
          orElse: () {
            final newChapter = DownloadChapter(
              id: chapterId,
              title: row['chapter_title'],
              order: row['chapter_order'],
            );
            task?.chapters.add(newChapter);
            return newChapter;
          },
        );

        if (row['file_server'] != null) {
          chapter.images.add(
            ImageDetail(
              fileServer: row['file_server'],
              path: row['path'],
              originalName: row['original_name'],
            ),
          );
        }
      }
    }
    return tasksMap.values.toList();
  }

  /// Delete a task by comic ID
  Future<void> delete(String id) async {
    await _db.writeTransaction((tx) async {
      await tx.execute('DELETE FROM download_task WHERE id = ?', [id]);
    });
  }
}
