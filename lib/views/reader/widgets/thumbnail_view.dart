import 'dart:math';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:haka_comic/network/models.dart';

class ThumbnailView extends StatefulWidget {
  final List<ChapterImage> images;
  final void Function(int) onPageSelected;
  final int initialPage;

  const ThumbnailView({
    super.key,
    required this.images,
    required this.onPageSelected,
    required this.initialPage,
  });

  @override
  State<ThumbnailView> createState() => _ThumbnailViewState();
}

class _ThumbnailViewState extends State<ThumbnailView> {
  int _crossAxisCount = 3;
  double _startScale = 1.0;
  double _currentScale = 1.0;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final screenWidth = MediaQuery.of(context).size.width;
        final itemWidth = (screenWidth - (_crossAxisCount - 1) * 4.0) / _crossAxisCount;
        final itemHeight = itemWidth / 0.75 + 4.0;
        final initialRow = (widget.initialPage / _crossAxisCount).floor();
        _scrollController.jumpTo(initialRow * itemHeight);
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        _startScale = _currentScale;
      },
      onScaleUpdate: (details) {
        double scale = _startScale * details.scale;
        // Clamp scale to avoid extreme zooming
        scale = scale.clamp(0.5, 2.0);

        if ((scale > 1.5 && _crossAxisCount == 3) || (scale < 0.75 && _crossAxisCount == 6)) {
          setState(() {
            _crossAxisCount = (_crossAxisCount == 3) ? 6 : 3;
            _currentScale = (_crossAxisCount == 3) ? 1.0 : 1.5;
          });
        }
      },
      child: GridView.builder(
        controller: _scrollController,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          crossAxisSpacing: 4.0,
          mainAxisSpacing: 4.0,
          childAspectRatio: 0.75,
        ),
        itemCount: widget.images.length,
        itemBuilder: (context, index) {
          final imageUrl = widget.images[index].media.url;
          return GestureDetector(
            onTap: () {
              widget.onPageSelected(index);
              Navigator.of(context).pop();
            },
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              memCacheHeight: 400,
              placeholder: (context, url) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (context, url, error) => const Icon(Icons.error),
            ),
          );
        },
      ),
    );
  }
}