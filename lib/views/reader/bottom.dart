import 'package:flutter/material.dart';
import 'package:haka_comic/config/app_config.dart';
import 'package:haka_comic/utils/extension.dart';
import 'package:haka_comic/widgets/with_blur.dart';

const kBottomBarHeight = 105.0;

enum ReaderBottomActionType { previous, next }

/// 底部工具栏
class ReaderBottom extends StatelessWidget {
  const ReaderBottom({
    super.key,
    required this.onPageNoChanged,
    required this.showToolbar,
    required this.action,
    required this.total,
    required this.pageNo,
    required this.isVerticalMode,
    required this.onThumbnailButtonPressed,
  });

  final ValueChanged<int> onPageNoChanged;
  final bool showToolbar;
  final VoidCallback? Function(ReaderBottomActionType) action;
  final int total;
  final int pageNo;
  final bool isVerticalMode;
  final VoidCallback onThumbnailButtonPressed;

  @override
  Widget build(BuildContext context) {
    final bottom = context.bottom;

    final previousAction = action(ReaderBottomActionType.previous);
    final nextAction = action(ReaderBottomActionType.next);

    return AnimatedPositioned(
      bottom: showToolbar ? 0 : -(bottom + kBottomBarHeight),
      left: 0,
      right: 0,
      height: bottom + kBottomBarHeight,
      duration: const Duration(milliseconds: 250),
      child: WithBlur(
        child: Container(
          padding: EdgeInsets.fromLTRB(12, 8, 12, bottom + 8),
          decoration: BoxDecoration(
            color: context.colorScheme.surface.withValues(alpha: 0.92),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: previousAction,
                  ),
                  Expanded(
                    child: PageSlider(
                      onChanged: onPageNoChanged,
                      value: pageNo,
                      total: total,
                    ),
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.skip_next),
                    onPressed: nextAction,
                  ),
                ],
              ),
              Expanded(
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Scaffold.of(context).openDrawer();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: context.colorScheme.onSurface,
                      ),
                      label: const Text('章节'),
                      icon: const Icon(Icons.menu_outlined),
                    ),
                    if (isVerticalMode)
                      TextButton.icon(
                        onPressed: () {
                          final slipFactor = ValueNotifier(
                            AppConf().slipFactor,
                          );
                          showDialog(
                            context: context,
                            builder: (context) {
                              return SimpleDialog(
                                contentPadding: const EdgeInsets.all(20),
                                title: const Text('滑动距离'),
                                children: [
                                  const Text('用于调整阅读时翻页的滑动距离。'),
                                  ValueListenableBuilder<double>(
                                    valueListenable: slipFactor,
                                    builder: (context, value, child) {
                                      return Slider(
                                        value: value * 10,
                                        min: 3,
                                        max: 10,
                                        divisions: 7,
                                        label: '$value * 屏高',
                                        onChanged: (double value) {
                                          slipFactor.value = value / 10;
                                          AppConf().slipFactor = value / 10;
                                        },
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: context.colorScheme.onSurface,
                        ),
                        label: const Text('滑动距离'),
                        icon: const Icon(Icons.straighten_outlined),
                      ),
                    TextButton.icon(
                      onPressed: onThumbnailButtonPressed,
                      style: TextButton.styleFrom(
                        foregroundColor: context.colorScheme.onSurface,
                      ),
                      label: const Text('快速导航'),
                      icon: const Icon(Icons.grid_view_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slider
class PageSlider extends StatelessWidget {
  final ValueChanged<int> onChanged;
  final int total;
  final int value;

  const PageSlider({
    super.key,
    required this.onChanged,
    required this.value,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    if (total <= 1) return const SizedBox.shrink();
    return Slider(
      value: value.toDouble(),
      min: 0,
      max: (total - 1).toDouble(),
      divisions: total - 1,
      label: '${value + 1}',
      onChanged: (value) => onChanged(value.toInt()),
    );
  }
}