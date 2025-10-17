import 'package.flutter/material.dart';
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
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          crossAxisSpacing: 4.0,
          mainAxisSpacing: 4.0,
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