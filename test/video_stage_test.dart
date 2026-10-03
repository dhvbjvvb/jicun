// 视频预览卡:换链接重新解析那条路上的竞态,以及画面上的拖动调进度。
//
// 单独一个文件(和其余按主题切开的 widget 用例一样):这里盯的是 VideoStage 自己那个
// State 在"上一条还在加载时被换掉"之后的表现,和解析/下载/历史都无关。
//
// 假播放器在 test/widget_support.dart([FakeVideoPlayerPlatform.holdNextCreate] /
// [FakeVideoPlayerPlatform.seeks])。

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

  // ─────────────────────── 画面上左右滑动调进度 ───────────────────────

  /// 在画面框里划一下,位移是 [dx] 像素。
  ///
  /// 一个位移事件就够:画面那块手势区是这片子树里**唯一**的手势识别者(没有滚动
  /// 祖先跟它抢),按下那一刻就被直接接受,所以整段位移都如实上报 —— 不像
  /// `tester.drag` 那样要先拿 20 像素去趟 slop。
  ///
  /// 收尾只用 pump 不用 pumpAndSettle:有用例故意让播放器初始化卡住,
  /// 那种状态下 settle 是等不到头的。
  Future<void> dragPicture(WidgetTester tester, double dx) async {
    final origin = tester.getTopLeft(find.byType(VideoStage));
    // 画面框是这条 Column 的第一块(328 宽、16:9 高约 184),起手点落在框内
    final gesture = await tester.startGesture(origin + const Offset(40, 60));
    await gesture.moveBy(Offset(dx, 0));
    await gesture.up();
    await tester.pump();
  }

  // 假播放器报的时长是 30 秒,画面框 328 宽 —— 于是「拖过的像素 / 328 * 30 秒」
  // 就是该跳到的位置。下面几条都拿这组数当尺子。
  //
  // 后两条(夹在总时长上 / 夹回 0)盯的是**端到端的契约**:不管怎么拖,送进播放器的
  // 都是 0..总时长 里的一个值。同样的夹法在 VideoPlayerController.seekTo 里还有一道,
  // 所以这两条不是「专盯画面里那一行 clamp」—— 把那儿去掉它们照样绿(试过)。

  testWidgets('画面上左右滑动调进度:拖过画面一半的宽度,就是总时长的一半', (tester) async {
    final fake = useFakeVideoPlayer();
    await tester.pumpWidget(stage(tester, 'https://cdn.example/seek-a.mp4'));
    await tester.pumpAndSettle();
    expect(fake.seeks, isEmpty, reason: '还没拖过,不该有 seek');

    // 164 = 328 的一半 → 15 秒
    await dragPicture(tester, 164);

    expect(fake.seeks, hasLength(1));
    expect(fake.seeks.single.inMilliseconds, closeTo(15000, 1));
  });

  testWidgets('画面拖出框外也夹在总时长上,不会报超出片长的进度', (tester) async {
    final fake = useFakeVideoPlayer();
    await tester.pumpWidget(stage(tester, 'https://cdn.example/seek-b.mp4'));
    await tester.pumpAndSettle();

    // 拖出去六个画面宽:不夹的话是 180 秒,而这条只有 30 秒
    await dragPicture(tester, 328 * 6);

    expect(fake.seeks, hasLength(1));
    expect(fake.seeks.single, const Duration(seconds: 30));
  });

  testWidgets('往回拖过了头夹回 0,不会把负的进度发给播放器', (tester) async {
    final fake = useFakeVideoPlayer();
    await tester.pumpWidget(stage(tester, 'https://cdn.example/seek-c.mp4'));
    await tester.pumpAndSettle();

    // 本来就在 0,再往回拖一个画面宽:不夹的话就是个负数
    await dragPicture(tester, -328);

    expect(fake.seeks, hasLength(1));
    expect(fake.seeks.single, Duration.zero);
  });

  testWidgets('总时长还没解析出来时,拖画面什么都不做', (tester) async {
    final fake = useFakeVideoPlayer();
    final gate = Completer<void>();
    fake.holdNextCreate = gate;

    await tester.pumpWidget(stage(tester, 'https://cdn.example/seek-d.mp4'));
    await tester.pump();
    // 播放器已经建出来了,但初始化事件还没来:这时候总时长还是 null
    await dragPicture(tester, 164);
    expect(fake.seeks, isEmpty, reason: '不知道总时长,就没法把像素换算成时间');

    // 初始化完成之后,同样的拖动就该生效 —— 证明上面那次是被拦下的,不是手势没接上
    gate.complete();
    await tester.pumpAndSettle();
    await dragPicture(tester, 164);
    expect(fake.seeks.single.inMilliseconds, closeTo(15000, 1));
  });

  testWidgets('上一次 seek 还没回来时,中间的拖动先丢掉', (tester) async {
    final fake = useFakeVideoPlayer();
    await tester.pumpWidget(stage(tester, 'https://cdn.example/seek-e.mp4'));
    await tester.pumpAndSettle();

    // 第一次拖动发出去的 seek 卡住不回来
    final gate = Completer<void>();
    fake.holdNextSeek = gate;
    await dragPicture(tester, 164);
    expect(fake.seeks, hasLength(1));

    // 拖动时每一帧都会发一次 seek:上一个没回来就丢新的,不然播放器会被塞满
    await dragPicture(tester, 10);
    expect(fake.seeks, hasLength(1), reason: '上一次还没回来,这次不该发出去');

    // 回来了,再拖就照发
    gate.complete();
    await tester.pumpAndSettle();
    await dragPicture(tester, 10);
    expect(fake.seeks, hasLength(2), reason: '上一次回来了,这次的拖动要发出去');
  });
}
