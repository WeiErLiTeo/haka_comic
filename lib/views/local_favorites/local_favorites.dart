import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:haka_comic/database/local_favorites_helper.dart';
import 'package:haka_comic/utils/extension.dart';
import 'package:haka_comic/utils/log.dart';
import 'package:haka_comic/utils/request/request.dart';
import 'package:haka_comic/utils/ui.dart';
import 'package:haka_comic/widgets/error_page.dart';
import 'package:haka_comic/widgets/toast.dart';

class LocalFavorites extends StatefulWidget {
  const LocalFavorites({super.key});

  @override
  State<LocalFavorites> createState() => _LocalFavoritesState();
}

class _LocalFavoritesState extends State<LocalFavorites> with RequestMixin {
  late final _helper = LocalFavoritesHelper();
  late final _getFoldersHandler = _helper.getFoldersWithCount.useRequest(
    onSuccess: (data) {
      Log.info('Get local folders success', data.toString());
    },
    onError: (e) => Log.error('Get local folders error', e),
  );

  late final _createFolderHandler = _helper.createFolder.useRequest(
    manual: true,
    onSuccess: (data, name) {
      if (data) {
        Log.info('Create folder success', name);
        _getFoldersHandler.refresh();
      } else {
        Toast.show(message: '「$name」已存在');
        Log.info('Create folder failed. $name already exists', name);
      }
    },
    onError: (e, name) {
      Toast.show(message: '创建失败');
      Log.error('Create folder $name error', e);
    },
  );

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        String name = '';
        return AlertDialog(
          title: const Text('创建收藏夹'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入收藏夹名称'),
            onChanged: (value) {
              name = value;
            },
            onSubmitted: (value) {
              context.pop(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                context.pop();
              },
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                context.pop(name);
              },
              child: const Text('创建'),
            ),
          ],
        );
      },
    );

    if (name == null || name.trim().isEmpty) return;

    _createFolderHandler.run(name.trim());
  }

  @override
  List<RequestHandler> registerHandler() => [
    _getFoldersHandler,
    _createFolderHandler,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地收藏夹'),
        leading: BackButton(onPressed: () => context.pop()),
      ),
      endDrawer: UiMode.m1(context)
          ? Drawer(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              child: _buildFolders(),
            )
          : null,
      body: SafeArea(
        child: switch (_getFoldersHandler.state) {
          Success(:final data) =>
            data.isEmpty
                ? const Center(child: Text('没有收藏夹，创建一个吧'))
                : Row(
                    children: [
                      if (!UiMode.m1(context))
                        Container(
                          width: 300,
                          decoration: BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                width: 2,
                                color: context.colorScheme.outline.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ),
                          child: _buildFolders(),
                        ),
                      Expanded(child: Container()),
                    ],
                  ),
          Error(:final error) => ErrorPage(
            errorMessage: error.toString(),
            onRetry: _getFoldersHandler.refresh,
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '创建收藏夹',
        onPressed: _createFolderHandler.state.loading ? null : _createFolder,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildFolders() {
    final folders = _getFoldersHandler.state.data ?? [];
    return ListView.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return ListTile(
          title: Text(folder.name),
          trailing: Text(folder.comicCount.toString()),
          onTap: () {},
        );
      },
    );
  }
}
