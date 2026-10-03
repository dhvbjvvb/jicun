// 视频预览卡:换链接重新解析那条路上的竞态。
//
// 单独一个文件(和其余按主题切开的 widget 用例一样):这里盯的是 VideoStage 自己那个
// State 在"上一条还在加载时被换掉"之后的表现,和解析/下载/历史都无关。
//
// 假播放器在 test/widget_support.dart([FakeVideoPlayerPlatform.holdNextCreate])。

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/video_stage.dart';

import 'widget_support.dart';

void main() {
  /// 把视频卡单独挂起来(它只吃 isDark / url)。
  ///
  /// 两点都是给测试补环境的:
  /// - [Material]:播放行里的 [PlainTap] 是 InkWell,没有 Material 祖先会直接断言失败;
  /// - 定死 328x420:画布按真机竖屏(360x800),外面再给个有界盒子 —— 卡片内部是
  ///   Column(16:9 画面 + 播放行),无界约束下会报一堆和本用例无关的溢出。
  Widget stage(WidgetTester tester, String url) {
    usePhoneSurface(tester);
    return CupertinoApp(
      home: Material(
        child: CupertinoPageScaffold(
          child: Center(
            child: SizedBox(
              width: 328,
              height: 420,
              child: VideoStage(isDark: false, url: url),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('换链接重新解析时,上一条的加载失败不会把新视频标成「视频无法播放」', (tester) async {
    final fake = useFakeVideoPlayer();
    // 上一条卡在"建播放器"这一步:它还没初始化完,用户就已经粘了下一条链接
    final gate = Completer<void>();
    fake.holdNextCreate = gate;

    await tester.pumpWidget(stage(tester, 'https://cdn.example/a.mp4'));
    await tester.pump();

    // 换链接:同类型同位置的 State 被复用,didUpdateWidget 先 dispose 旧的、再加载新的
    await tester.pumpWidget(stage(tester, 'https://cdn.example/b.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('视频无法播放'), findsNothing, reason: '新视频加载正常,卡上不该出现失败占位');

    // 闸门打开:上一条那次加载**现在**才失败 —— 它属于已经被换掉的那个播放器
    gate.completeError(PlatformException(code: 'stale_load'));
    await tester.pumpAndSettle();

    // 判据是 identical(_controller, controller):不是当前这个播放器失败,就不该改状态。
    // 少这一判(见 VideoStage._load 的 catch),这里会亮出"视频无法播放",而且链接不再
    // 变的话永远不会自愈。
    expect(find.text('视频无法播放'), findsNothing, reason: '旧播放器的失败不该算到新视频头上');
  });

  testWidgets('当前这条真的加载失败时,照样要报「视频无法播放」', (tester) async {
    // 上一条用例的反向保险:守卫不能把**当前**这条的失败也一起吞掉。
    final fake = useFakeVideoPlayer();
    final gate = Completer<void>();
    fake.holdNextCreate = gate;

    await tester.pumpWidget(stage(tester, 'https://cdn.example/only.mp4'));
    await tester.pump();
    // 这次没有换链接:失败的就是当前这个播放器
    gate.completeError(PlatformException(code: 'broken'));
    await tester.pumpAndSettle();

    expect(find.text('视频无法播放'), findsOneWidget);
  });
}
