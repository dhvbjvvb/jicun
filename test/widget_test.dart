// 应用外壳与横滑切板块 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/audio_stage.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/prefs.dart';
import 'package:jicun/ui/theme_appearance_page.dart';

import 'widget_support.dart';

void main() {
  // 音频预览的本地缓存兜底要关:假时钟里真实网络 I/O 不会推进,会把用例挂住。
  AudioStage.localCacheFallback = false;

  // 启动流程会顺手刷新一次「域名 + 优选 IP」。这里换成空配置,免得用例真去连
  // 接口域名 —— 用例要验的是页面行为,不是这条后台链路。
  PreferredIpUpdater.overrideClient(
    MockClient((_) async => http.Response('{"ips":[]}', 200)),
  );

  testWidgets('renders the navigation labels and settings entry', (
    tester,
  ) async {
    usePhoneSurface(tester);
    // autoCheckUpdate: false —— 这个用例只看标签和设置入口。开着自动检查的话,
    // 设置页那张「检查更新」卡会显示「检查中…」,断言里会多出一条。
    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('解析'), findsWidgets);
    expect(find.text('历史'), findsWidgets);
    expect(find.text('设置'), findsWidgets);

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();

    expect(find.text('通知管理与下载'), findsOneWidget);

    await tester.tap(find.text('通知管理与下载'));
    await tester.pumpAndSettle();

    expect(find.text('下载完成通知'), findsOneWidget);
    expect(find.text('下载失败通知'), findsOneWidget);
    expect(find.text('测试通知'), findsOneWidget);
    // 保存位置卡片:三行都摊开摆着,不用再点一下。
    // 这三条必须和 MainActivity.kindOf 里写的一字不差 —— 之前就是两边各说各话。
    expect(find.text('存储保存位置（点击路径可自定义）'), findsOneWidget);
    expect(find.text('Movies/Jicun/Video'), findsOneWidget);
    expect(find.text('Pictures/Jicun/Picture'), findsOneWidget);
    expect(find.text('Music/Jicun/Music'), findsOneWidget);
  });

  testWidgets('存储保存位置:选过自定义目录就显示它,并给一颗「默认」', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefsStorageTreeKey('image'): 'content://tree/primary%3APictures%2F我的图片',
      kPrefsStorageLabelKey('image'): '内部存储/Pictures/我的图片',
    });
    addTearDown(Downloader.customStorage.clear);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(LiquidGlassDemo(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('通知管理与下载'));
    await tester.pumpAndSettle();

    // 图片那一行换成自定义路径,默认那条不再出现;另外两条不受影响。
    expect(find.text('内部存储/Pictures/我的图片'), findsOneWidget);
    expect(find.text('Pictures/Jicun/Picture'), findsNothing);
    expect(find.text('Movies/Jicun/Video'), findsOneWidget);
    expect(find.text('Music/Jicun/Music'), findsOneWidget);
    // 自定义过才有「默认」这颗退回键。
    expect(find.text('默认'), findsOneWidget);
  });

  testWidgets('自定义背景图:主题页有这张卡,展开出两个选项', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();

    expect(find.text('自定义背景图'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    // 展开前后两个选项都挂在树上(Reveal 只是把高度收到 0),所以看 expanded,
    // 而不是 findsNothing。
    bool expanded() => tester
        .widget<Reveal>(
          find.descendant(
            of: find.byType(CustomBackgroundCard),
            matching: find.byType(Reveal),
          ),
        )
        .expanded;
    expect(expanded(), isFalse);

    await tester.tap(find.text('自定义背景图'));
    await tester.pumpAndSettle();
    expect(expanded(), isTrue);
    expect(find.text('选取相册中图片做背景'), findsOneWidget);
    expect(find.text('还原默认背景图'), findsOneWidget);
  });

  testWidgets('自定义背景图:偏好里有图时显示已设置', (tester) async {
    usePhoneSurface(tester);
    final dir = Directory.systemTemp.createTempSync('jicun_bg');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 1x1 透明 PNG:不为像素,只为让 Image.file 真能解码。
    final file = File('${dir.path}/bg.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      );
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefsCustomBackground: file.path,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      LiquidGlassDemo(prefs: prefs, autoCheckUpdate: false),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();
    expect(find.text('已设置'), findsOneWidget);
  });

  testWidgets('桌面端:设置页没有「检查更新」,视频路径是 Windows 的 Videos/', (tester) async {
    // 电脑端和手机端差两件事,一条用例把两边都钉住:
    //   1. 应用内更新只对 Android 成立(发出去的资产是 APK,靠系统安装器装),
    //      桌面端连入口都不显示;
    //   2. 视频在 Windows 上落的是标准媒体文件夹 Videos/,不是 Android 的 Movies/。
    // 两条判据都走 defaultTargetPlatform,所以这里改那个 override 就能在快的单元
    // 用例里验,不用起一台真 Windows 跑 integration_test。
    //
    // 必须在**测试体里**用 try/finally 还原:binding 在跑完测试体、还没轮到
    // addTearDown 的时候就查了一遍"foundation 的调试变量有没有被动过"。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      usePhoneSurface(tester);
      await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();

      expect(find.text('检查更新'), findsNothing);
      // 只该少掉「检查更新」那一条,别的入口都在 —— 别把整份清单一起挡掉了。
      expect(find.text('主题与外观'), findsOneWidget);
      expect(find.text('使用帮助及反馈'), findsOneWidget);
      expect(find.text('关于本APP'), findsOneWidget);

      await tester.tap(find.text('通知管理与下载'));
      await tester.pumpAndSettle();

      expect(find.text('Videos/Jicun/Video'), findsOneWidget);
      expect(find.text('Movies/Jicun/Video'), findsNothing);
      // 图片和音频两边同名,不该跟着变。
      expect(find.text('Pictures/Jicun/Picture'), findsOneWidget);
      expect(find.text('Music/Jicun/Music'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('横滑切板块', () {
    /// 起一次 App,停在解析板块。
    Future<void> openApp(WidgetTester tester) async {
      usePhoneSurface(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(const LiquidGlassDemo());
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// 在页面中间横滑一把。落点取屏幕中间偏下的普通区域 —— 视频画面、缩略图条、
    /// 进度条上都有自己的横向手势,那些地方归它们(见 [_onTabSwipeEnd] 的注释)。
    Future<void> swipe(WidgetTester tester, double dx) async {
      await tester.dragFrom(const Offset(180, 620), Offset(dx, 0));
      await tester.pumpAndSettle();
    }

    testWidgets('解析往左滑到历史,再往左到设置;到头了就不动', (tester) async {
      await openApp(tester);
      expect(find.text('粘贴链接').hitTestable(), findsOneWidget);

      await swipe(tester, -200);
      expect(find.text('暂无解析记录').hitTestable(), findsOneWidget);

      await swipe(tester, -200);
      expect(find.text('通知管理与下载').hitTestable(), findsOneWidget);

      // 设置是最后一个板块:再往左没有下一个了
      await swipe(tester, -200);
      expect(find.text('通知管理与下载').hitTestable(), findsOneWidget);
    });

    testWidgets('往右滑退回上一个板块;解析是第一个,再往右不动', (tester) async {
      await openApp(tester);
      await swipe(tester, -200);
      expect(find.text('暂无解析记录').hitTestable(), findsOneWidget);

      await swipe(tester, 200);
      expect(find.text('粘贴链接').hitTestable(), findsOneWidget);

      await swipe(tester, 200);
      expect(find.text('粘贴链接').hitTestable(), findsOneWidget);
    });

    testWidgets('拖一小段(不是一挥)不切板块', (tester) async {
      await openApp(tester);

      await swipe(tester, -40);

      expect(find.text('粘贴链接').hitTestable(), findsOneWidget);
    });

    testWidgets('够快的一挥也算:短距离快速滑动能切板块', (tester) async {
      await openApp(tester);

      // 距离只有 70px(不到阈值),靠速度切
      await tester.fling(find.byType(IndexedStack), const Offset(-70, 0), 1500);
      await tester.pumpAndSettle();

      expect(find.text('暂无解析记录').hitTestable(), findsOneWidget);
    });

    testWidgets('缩略图条上的横滑是滚它自己,不切板块', (tester) async {
      usePhoneSurface(tester);
      // 八张图:缩略图条比屏幕宽,横滑确实能滚起来
      useStubParseBackend(
        data: <String, dynamic>{
          'title': '多图',
          'desc': '文案',
          'platform': '抖音',
          'image_list': <dynamic>[
            for (var i = 0; i < 8; i++) 'https://example.invalid/$i.jpg',
          ],
        },
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(const LiquidGlassDemo());
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byType(CupertinoTextField),
        'https://v.douyin.com/gallery/',
      );
      await tester.pump();
      await tester.tap(find.text('开始解析'));
      await tester.pumpAndSettle();

      final strip = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal,
      );
      expect(strip, findsOneWidget);
      await tester.ensureVisible(strip);
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(
            find.descendant(of: strip, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.pixels, 0);

      await tester.drag(strip, const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(0), reason: '横滑该滚的是这条缩略图');
      expect(
        find.text('粘贴链接').hitTestable(),
        findsOneWidget,
        reason: '缩略图条上的横滑不该切板块',
      );
    });
  });

  // 启动画面只在原生侧,Flutter 这边没有那一层了(理由见 main.dart 里那段注释),
  // 所以这里也没有"启动图淡出"的用例 —— 真机上它就是在界面上留了个鸟的残影。
}
