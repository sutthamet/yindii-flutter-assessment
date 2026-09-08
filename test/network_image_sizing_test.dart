import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/shared_widget/the_network_image.dart';

void main() {
  Future<CachedNetworkImage> imageAt(WidgetTester tester,
      {required double width,
      required double height,
      required double dpr}) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: Center(
            child: SizedBox(
          width: width,
          height: height,
          child: const TheNetworkImage(url: '', width: double.infinity),
        )),
      ),
    ));
    return tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
  }

  testWidgets(
      'decode follows constrained width and pixel density, not infinity',
      (tester) async {
    final image = await imageAt(tester, width: 300, height: 160, dpr: 2);
    expect(image.memCacheWidth, 600);
    expect(image.memCacheHeight, isNull); // Preserve the source aspect ratio.
    expect(image.fit, BoxFit.cover);
    expect(tester.getSize(find.byType(TheNetworkImage)), const Size(300, 160));
    final resized = await imageAt(tester, width: 400, height: 160, dpr: 3);
    expect(resized.memCacheWidth, 1200);
    final highDensity = await imageAt(tester, width: 400, height: 160, dpr: 5);
    expect(highDensity.memCacheWidth, 1600); // No larger than the source.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('square thumbnails keep enough pixels to cover their height',
      (tester) async {
    final image = await imageAt(tester, width: 60, height: 60, dpr: 2);
    expect(image.memCacheWidth, 160); // Decodes 160 x 120 for a 120 x 120 box.
    expect(image.memCacheHeight, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('flash rail uses its small physical size', (tester) async {
    final image = await imageAt(tester, width: 192, height: 90, dpr: 2);
    expect(image.memCacheWidth, 384);
    expect(image.maxWidthDiskCache,
        isNull); // Leave original disk downloads alone.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
