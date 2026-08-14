import 'dart:io';
import 'package:haka_comic/database/download_task_helper.dart';
import 'package:haka_comic/network/models.dart';
import 'package:haka_comic/utils/extension.dart';
import 'package:haka_comic/views/download/download_storage.dart';
import 'package:haka_comic/views/download/local_comic_files.dart';
import 'package:path/path.dart' as p;

Future<List<ImageBase>> fetchLocalImages(
  FetchChapterImagesPayload payload,
) async {
  final helper = DownloadTaskHelper();
  final comic = await helper.getDownloadComic(payload.id);
  final chapters = await helper.getDownloadChapters(payload.id);
  final chapter = chapters.firstWhere(
    (element) => element.order == payload.order,
    orElse: () => throw Exception('章节不存在，检查是否已被删除'),
  );
  final storage = await DownloadStorage.load();
  final comicRelativePath = comic.title.legalized;
  if (!await storage.directoryExists(comicRelativePath)) {
    throw Exception('漫画不存在，检查是否已被删除');
  }

  final chapterRelativePath = p.posix.join(
    comicRelativePath,
    '${chapter.order}_${chapter.title.legalized}',
  );
  Directory chapterDir;

  if (await storage.directoryExists(chapterRelativePath)) {
    chapterDir = Directory(
      await storage.materializeDirectory(chapterRelativePath),
    );
  } else {
    // 兼容之前下载的漫画
    final legacyRelativePath = p.posix.join(
      comicRelativePath,
      chapter.title.legalized,
    );
    if (!await storage.directoryExists(legacyRelativePath)) {
      throw Exception('漫画不存在，检查是否已被删除');
    }
    chapterDir = Directory(
      await storage.materializeDirectory(legacyRelativePath),
    );
  }

  final files = await listImageFiles(chapterDir);

  if (files.isEmpty) {
    throw Exception('章节下不存在漫画图片，检查是否已被删除');
  }

  return files
      .map(
        (file) => LocalImage(
          url: file.path,
          uid: file.path.hashCode.toString(),
          id: file.path.hashCode.toString(),
        ),
      )
      .toList();
}
