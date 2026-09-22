import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// 彩蛋的收尾方式是在**动图绕回第 0 帧那一瞬间硬切**回静图,因为那一帧和静图
/// 逐像素重合,所以看不见。这个做法压在两个素材事实上,换素材时必须先在这里炸,
/// 而不是让用户在手机上看到跳一下。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const animated = 'assets/easter-egg/laugh.webp';
  const still = 'assets/easter-egg/laugh_still.webp';

  Future<ui.Codec> open(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    addTearDown(codec.dispose);
    return codec;
  }

  Future<List<int>> pixels(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }

  test('素材无限循环,播满 frameCount 帧后绕回的第 0 帧和第 0 帧逐像素相同', () async {
    final codec = await open(animated);
    expect(codec.frameCount, greaterThan(1));
    expect(
      codec.repetitionCount,
      -1,
      reason: '素材必须无限循环,否则第二圈的第 0 帧永远不来,彩蛋会停在动图那一层',
    );

    final first = await codec.getNextFrame();
    final firstPixels = await pixels(first.image);
    for (var i = 1; i < codec.frameCount; i++) {
      await codec.getNextFrame();
    }
    final wrapped = await codec.getNextFrame();
    expect(
      await pixels(wrapped.image),
      firstPixels,
      reason: '绕回的那一帧必须和第一帧完全相同,硬切才看不出来',
    );
  });

  test('静图和动图第 0 帧逐像素接近', () async {
    final animatedCodec = await open(animated);
    final stillCodec = await open(still);

    final frame0 = await animatedCodec.getNextFrame();
    final stillFrame = await stillCodec.getNextFrame();
    expect(frame0.image.width, stillFrame.image.width);
    expect(frame0.image.height, stillFrame.image.height);

    final a = await pixels(frame0.image);
    final b = await pixels(stillFrame.image);
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    final meanDiff = sum / a.length;
    expect(meanDiff, lessThan(4), reason: '静图应该是动图第 0 帧导出的,差太多说明素材配错了,硬切会看得见');
  });

  test('音效能加载', () async {
    // 组件里音效的异常是被吃掉的(音效坏了不该连累画面),所以路径写错的表现是
    // "完全没声音"而不会报错 —— 这个断言就是为了让那种错别字当场炸出来。
    // 时长约束(不长于动图一轮)由组件收尾时主动停声兜住,这里不重复测。
    final data = await rootBundle.load('assets/easter-egg/laugh.mp3');
    expect(data.lengthInBytes, greaterThan(0));
  });
}
