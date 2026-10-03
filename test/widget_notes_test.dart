// 更新说明预览与顶栏固定 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。


import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/history_store.dart';
import 'package:jicun/main.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/audio_stage.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/update_card.dart';
import 'package:jicun/update_service.dart';
import 'widget_support.dart';

void main() {
  // 收流那一步生产上是原生的(走平台通道),测试里到不了替身 —— 统一改走 Dart 实现,
  // 这样 fetchImpl 那些假下载器才生效。见 Downloader.useDartEngine。
  Downloader.useDartEngine = true;
  // 音频预览的本地缓存兜底要关:假时钟里真实网络 I/O 不会推进,会把用例挂住。
  AudioStage.localCacheFallback = false;

  // 启动流程会顺手刷新一次「域名 + 优选 IP」。这里换成空配置,免得用例真去连
  // 接口域名 —— 用例要验的是页面行为,不是这条后台链路。
  PreferredIpUpdater.overrideClient(
    MockClient((_) async => http.Response('{"ips":[]}', 200)),
  );


  group('版本更新说明预览', () {
    /// 单独把卡片挂起来,pump 到弹层出来。
    ///
    /// [surface] 不给就按真机竖屏(360x800)。量行数那条判据看的是**面板**宽度,而面板
    /// 比屏幕窄,所以那个用例特意给一个宽一点的画布(412x900)把差距放大。
    Future<void> showCard(
      WidgetTester tester,
      String notes, {
      Size? surface,
    }) async {
      if (surface == null) {
        usePhoneSurface(tester);
      } else {
        tester.view.physicalSize = surface;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: CupertinoButton(
                  onPressed: () => showUpdateCard(
                    context,
                    release: ReleaseInfo(
                      tag: 'v1.1.0',
                      notes: notes,
                      apkName: 'jicun-1.1.0.apk',
                      mirrorUrls: kAssetMirrorUrls('v1.1.0', 'jicun-1.1.0.apk'),
                      directUrl: kReleaseAssetUrl('v1.1.0', 'jicun-1.1.0.apk'),
                    ),
                    currentVersion: '1.0.0',
                    onUpdate: () {},
                    onIgnore: () {},
                  ),
                  child: const Text('开卡'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开卡'));
      await tester.pumpAndSettle();
    }

    testWidgets('说明超过 12 行:窗口高度锁在 12 行,并出现滚动条', (tester) async {
      await showCard(tester, List.generate(30, (i) => '第 $i 行说明').join('\n'));

      // 每行一个 Text(30 行说明 → 30 个)
      expect(find.text('第 0 行说明'), findsOneWidget);
      // 12 行 × 13px × 1.55,再加内容区上下两层内边距(10+10)。
      // 内边距原来没算在窗口高里,结果「按文字高量出来正好 12 行」的说明会顶出去 20px,
      // 末行在 release 里被静静裁掉(见 update_card.dart 的 _windowHeight)。
      const expected = 12 * 13 * 1.55 + 20;
      final box = tester.getSize(find.byType(Scrollbar));
      expect(box.height, closeTo(expected, 0.5));
      expect(find.byType(Scrollbar), findsOneWidget);
    });

    testWidgets('说明不到 12 行:不挂滚动条(免得右边留一条空槽)', (tester) async {
      await showCard(tester, '就一行');
      expect(find.text('就一行'), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);
    });

    testWidgets('说明为空:给一句占位', (tester) async {
      await showCard(tester, '');
      expect(find.text('这个版本没有写说明。'), findsOneWidget);
    });

    testWidgets('说明按面板宽度量行数:面板比屏幕窄,超 12 行照样挂滚动条', (tester) async {
      // 412 宽的画布,而面板被 PopupShell 卡在 kPopupPanelMaxWidth(300):字号 13 时内容
      // 实际只有 242 宽,按屏幕算却量出 306 —— 242 字要 14 行、306 字只要 11 行,于是旧
      // 的量法会把这条说明判成"不超 12 行":滚动条不挂,多出来的两行直接画到下面的
      // 更新/忽略按钮上(测试里就是那个 RenderFlex 溢出)。
      await showCard(
        tester,
        '这是一条很长的更新说明' * 22,
        surface: const Size(412, 900),
      );

      expect(find.byType(Scrollbar), findsOneWidget, reason: '14 行的说明必须能滚');
      expect(
        tester.takeException(),
        isNull,
        reason: '不能有溢出:那说明文字压到按钮上了',
      );
    });

    testWidgets('宽度变了行数跟着变:窄了要滚,宽了不挂', (tester) async {
      // 同一段说明,只改这块能拿到的宽度。行数以前是拿**屏幕**宽度倒推面板宽度算的,
      // 宽度怎么变都量出同一个数;现在按 [LayoutBuilder] 给的真实宽度算,两边必须给出
      // 不同结果 —— 这条用例就是钉住这一点:窄到放不下 12 行要挂滚动条,宽了不该留空槽。
      final notes = '这是一条很长的更新说明' * 22;
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Future<void> pumpAt(double width) => tester.pumpWidget(
        CupertinoApp(
          home: Center(
            child: SizedBox(
              width: width,
              child: ReleaseNotesPreview(
                notes: notes,
                foreground: CupertinoColors.black,
                secondary: CupertinoColors.systemGrey,
                isDark: false,
              ),
            ),
          ),
        ),
      );

      await pumpAt(120);
      expect(find.byType(Scrollbar), findsOneWidget, reason: '120 宽放不下 12 行,必须能滚');

      await pumpAt(600);
      expect(find.byType(Scrollbar), findsNothing, reason: '600 宽装得下,不该多一条空槽');
    });

    /// 固定宽度下把说明挂起来:行数由 [lines] 决定(每行都很短,不会折行),
    /// [textScale] 改系统字号缩放。
    ///
    /// 缩放用 `MediaQuery.of(context).copyWith` 从现有数据上改,不是新造一个
    /// [MediaQueryData] —— 后者会把尺寸一并重置成默认值,量出来的东西就不是 "这块
    /// 面板给多宽" 了。
    Future<void> pumpNotes(
      WidgetTester tester,
      List<String> lines, {
      double width = 600,
      double textScale = 1,
    }) => tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Center(
              child: SizedBox(
                width: width,
                child: ReleaseNotesPreview(
                  notes: lines.join('\n'),
                  foreground: CupertinoColors.black,
                  secondary: CupertinoColors.systemGrey,
                  isDark: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('判据是「超过 12 行」:正好 12 行不挂滚动条,也不许裁掉末行', (tester) async {
      // 既有用例比的是 30 行和 1 行,中间那一格没钉住:判据写成 `>= 12`、或者把 12
      // 写成 11,它们都照样绿。而这一格恰好踩在一个真坑上 —— 窗口高 12 行**文字**,
      // 内容外面还套着上下内边距;拿窗口高去比文字高,刚好 12 行的说明就会被判成
      // “放得下”:滚动条不挂,末行在 release 里被静静裁掉。
      final twelve = [for (var i = 0; i < 12; i++) '第 $i 行'];
      await pumpNotes(tester, twelve);
      expect(find.text('第 11 行'), findsOneWidget);
      expect(
        find.byType(Scrollbar),
        findsNothing,
        reason: '正好 12 行装得下,不该挂滚动条',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '12 行必须真的装得下:溢出意味着末行被裁掉了',
      );

      await pumpNotes(tester, [...twelve, '第 12 行']);
      expect(find.byType(Scrollbar), findsOneWidget, reason: '13 行超了,必须能滚');
      expect(
        tester.getSize(find.byType(Scrollbar)).height,
        closeTo(12 * 13 * 1.55 + 20, 0.5),
        reason: '窗口是 12 行文字高 + 上下内边距,不是 13 行',
      );
    });

    testWidgets('量行数用的是真实系统字号:字号放大后同样的说明要能滚', (tester) async {
      // 8 行短句:1.0 倍时总共 8 行高,放大到 2.0 倍就是 16 行高 —— 超过 12 行。
      // 这条钉的是 _measure 有没有把 MediaQuery.textScalerOf 传下去:漏传的话两边
      // 结果一样,它就是红的。
      final eight = [for (var i = 0; i < 8; i++) '第 $i 行'];
      await pumpNotes(tester, eight);
      expect(find.byType(Scrollbar), findsNothing, reason: '8 行装得下');

      await pumpNotes(tester, eight, textScale: 2);
      expect(
        find.byType(Scrollbar),
        findsOneWidget,
        reason: '字号放大一倍后相当于 16 行,必须能滚',
      );
    });
  });

  testWidgets('顶栏固定:列表滚动时标题与历史那排按钮不动', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final store = HistoryStore();
    for (var i = 0; i < 12; i++) {
      await store.add(sampleResult('记录 $i'), 'https://v.douyin.com/$i/');
    }
    // 写盘有防抖,而下面 pumpWidget 出来的是另一个 HistoryStore 实例
    await store.flush();

    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    // 顶栏那颗「历史」在 BoardHeader 里,底栏那个同名标签不在 —— 按祖先区分
    final header = find.ancestor(
      of: find.text('历史'),
      matching: find.byType(BoardHeader),
    );
    // 滚动区也用祖先找:三个板块都活在 IndexedStack 里,byType 会撞上另外两个。
    final board = find.ancestor(
      of: find.text('历史'),
      matching: find.byType(BoardScrollView),
    );
    final list = find
      .descendant(of: board, matching: find.byType(Scrollable))
      .first;
    double headerTop() => tester.getTopLeft(header).dy;
    double buttonTop() => tester.getTopLeft(find.text('选择')).dy;

    final titleBefore = headerTop();
    final buttonBefore = buttonTop();

    // 往上拖:顶部的记录滚出去
    await tester.drag(list, const Offset(0, -150));
    await tester.pumpAndSettle();

    expect(
      tester.state<ScrollableState>(list).position.pixels,
      greaterThan(50),
      reason: '列表确实滚上去了',
    );
    expect(headerTop(), closeTo(titleBefore, 0.5), reason: '标题不跟着滚');
    expect(buttonTop(), closeTo(buttonBefore, 0.5), reason: '按钮不跟着滚');
  });
}