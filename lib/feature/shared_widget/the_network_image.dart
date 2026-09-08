import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Standard network image with a shimmer placeholder.
class TheNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const TheNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: SizedBox(
        width: width,
        height: height,
        child: LayoutBuilder(builder: (context, constraints) {
          // Catalog photos are 1600 x 1200. Size for BoxFit.cover without
          // stretching the decoded aspect ratio, including square thumbnails.
          const aspectRatio = 4 / 3;
          final logicalWidth =
              constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
          final logicalHeight =
              constraints.hasBoundedHeight ? constraints.maxHeight : 0.0;
          final decodeWidth =
              (math.max(logicalWidth, logicalHeight * aspectRatio) *
                      MediaQuery.devicePixelRatioOf(context))
                  .ceil();
          return CachedNetworkImage(
            memCacheWidth: decodeWidth > 0 ? math.min(1600, decodeWidth) : null,
            imageUrl: url,
            width: width,
            height: height,
            fit: fit,
            placeholder: (context, _) => Shimmer.fromColors(
              baseColor: Colors.grey.shade300,
              highlightColor: Colors.grey.shade100,
              child:
                  Container(width: width, height: height, color: Colors.white),
            ),
            errorWidget: (context, _, __) => Container(
              width: width,
              height: height,
              color: Colors.grey.shade200,
              child: const Icon(Icons.image_not_supported_outlined),
            ),
          );
        }),
      ),
    );
  }
}
