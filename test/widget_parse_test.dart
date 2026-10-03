// 解析页展示 —— 从原 test/widget_test.dart 按主题切出来的分片。
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
import 'package:jicun/main.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/audio_stage.dart';

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

  testWidgets('解析页:解析前只有粘贴卡,解析成功后混合等预览卡才入场', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend();
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('粘贴链接'), findsOneWidget);
    // 预览卡一直在树上(靠高度裁掉),所以断言的是「碰不到」而不是「不存在」
    expect(find.text('媒体预览').hitTestable(), findsNothing);
    expect(find.text('图集预览').hitTestable(), findsNothing);
    expect(find.text('混合预览').hitTestable(), findsNothing);
    expect(find.text('音频预览').hitTestable(), findsNothing);
    expect(find.text('文案预览').hitTestable(), findsNothing);

    // 空链接时按钮是禁用的,点了也不该翻出预览卡
    // (预览卡上也各有一颗 FilledButton,所以要按文字定位到这一颗)
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('开始解析'),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://b23.tv/abcd',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    // 入场是错开的(每张卡晚 22% 时间线),必须等整条时间线走完
    await tester.pumpAndSettle();

    // 这条链接既有视频又有图片:只出混合卡,媒体卡和图集卡都不该出现
    expect(find.text('混合预览').hitTestable(), findsOneWidget);
    expect(find.text('媒体预览'), findsNothing);
    expect(find.text('图集预览'), findsNothing);
    expect(find.text('共 3 项').hitTestable(), findsOneWidget);

    // 后两张在首屏之外:先滚到它们,再断言「碰到了」
    await tester.ensureVisible(find.text('音频预览'));
    await tester.pumpAndSettle();
    expect(find.text('音频预览').hitTestable(), findsOneWidget);

    await tester.ensureVisible(find.text('文案预览'));
    await tester.pumpAndSettle();
    expect(find.text('文案预览').hitTestable(), findsOneWidget);
  });

  testWidgets('解析页:没有图集的视频链接,不该出现图集预览卡', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubVideoOnlyData);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/abcd/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 有什么才显示什么:这条链接没有 image_list,图集卡根本不该被构建出来
    expect(find.text('图集预览'), findsNothing);
    expect(find.text('媒体预览').hitTestable(), findsOneWidget);
    // 粘贴卡右侧多了「粘贴/清空」两颗按钮,卡片比原来高一截,音频卡掉到折线下面 ——
    // 所以这里和下面那张卡一样要先滚到位
    await tester.ensureVisible(find.text('音频预览'));
    await tester.pumpAndSettle();
    expect(find.text('音频预览').hitTestable(), findsOneWidget);

    await tester.ensureVisible(find.text('文案预览'));
    await tester.pumpAndSettle();
    expect(find.text('文案预览').hitTestable(), findsOneWidget);
  });

  /// 卡片底部那颗「下载媒体」按钮。
  ///
  /// 一屏能有好几张卡、各带一颗,所以要给个 [within](卡里独有的文字)把范围锁到
  /// 那一张卡上;只有一颗的用例可以不传。
  FilledButton downloadButton(WidgetTester tester, {String? within}) {
    var finder = find.ancestor(
      of: find.text('下载媒体'),
      matching: find.byType(FilledButton),
    );
    if (within != null) {
      // 每张预览卡自己是一层 Material(GlassPanel 里那位),拿它当卡片边界。
      finder = find.descendant(
        of: find
            .ancestor(of: find.text(within), matching: find.byType(Material))
            .first,
        matching: finder,
      );
    }
    return tester.widget<FilledButton>(finder);
  }

  testWidgets('解析页:一条链接两个视频走缩略图,没有播放组件', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubMultiVideoData);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/multi/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 两个视频:排版与数量显示跟图集那条一样
    expect(find.text('共 2 个'), findsOneWidget);
    // 封面用的是每条视频自己的封面,不是播放器
    expect(hasImageWith(tester, 'https://example.invalid/1.jpg'), isTrue);
    expect(hasImageWith(tester, 'https://example.invalid/2.jpg'), isTrue);
    // 播放器整个取消掉了(缩略图角上那两个小播放标识不算播放组件)
    expect(find.text('00:00'), findsNothing);
    expect(find.byIcon(CupertinoIcons.play_fill), findsNWidgets(2));

    // 两条以上:左边多一颗「全选媒体」,下载按钮要先选中才能按
    expect(find.text('全选媒体'), findsOneWidget);
    expect(downloadButton(tester, within: '媒体预览').onPressed, isNull);
  });

  testWidgets('解析页:全选媒体点一次全选中,再点一次全部取消', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubMultiVideoData);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/multi/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 这颗按钮自己会改口:全选中之后写「取消全选」
    Finder selectAll = find.text('全选媒体');
    Future<void> tapSelectAll() async {
      await tester.ensureVisible(selectAll);
      await tester.pumpAndSettle();
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
    }

    await tapSelectAll();
    // 全选中:下载按钮活了,两颗缩略图都带上了勾,按钮改口叫「取消全选」
    expect(downloadButton(tester, within: '媒体预览').onPressed, isNotNull);
    expect(find.byIcon(CupertinoIcons.check_mark), findsNWidgets(2));
    expect(find.text('取消全选'), findsOneWidget);
    expect(find.text('全选媒体'), findsNothing);

    // 再点一次全部取消:按钮回到「全选媒体」,勾全没了,下载恢复灰色
    selectAll = find.text('取消全选');
    await tapSelectAll();
    expect(find.text('全选媒体'), findsOneWidget);
    expect(find.text('取消全选'), findsNothing);
    expect(downloadButton(tester, within: '媒体预览').onPressed, isNull);
    expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
  });

  testWidgets('解析页:实况图归视频,不进图集卡', (tester) async {
    usePhoneSurface(tester);
    // 实况图的 image_list 元素是「静态图 + live_photo_url(MP4)」一对
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '实况图',
        'desc': '文案',
        'platform': '抖音',
        'video_url': 'https://example.invalid/v.mp4',
        'cover_url': 'https://example.invalid/c.jpg',
        'image_list': [
          {
            'url': 'https://example.invalid/live1.jpg',
            'live_photo_url': 'https://example.invalid/live1.mp4',
          },
          {
            'url': 'https://example.invalid/live2.jpg',
            'live_photo_url': 'https://example.invalid/live2.mp4',
          },
          'https://example.invalid/plain.jpg',
        ],
      },
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/live/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 两张实况图 = 两条视频 + 一条单视频,再加上那条真图片 = 混合链接,
    // 所以走的是混合卡,数一共 4 项。
    expect(find.text('共 4 项'), findsOneWidget);
    // 缩略图用实况图的静态那张,不是 MP4
    expect(hasImageWith(tester, 'https://example.invalid/live1.jpg'), isTrue);
    expect(hasImageWith(tester, 'https://example.invalid/live2.jpg'), isTrue);
    expect(hasImageWith(tester, 'https://example.invalid/plain.jpg'), isTrue);
    // 媒体卡和图集卡都不该出现 —— 混合链接只出混合卡
    expect(find.text('媒体预览'), findsNothing);
    expect(find.text('图集预览'), findsNothing);
  });

  testWidgets('解析页:点缩略图选中,再点一次取消选中', (tester) async {
    usePhoneSurface(tester);
    // 默认应答:一条视频 + 两张图,走混合卡
    useStubParseBackend();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://b23.tv/abcd',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    Finder tile(String url) => find.byWidgetPredicate(
      (w) => w is Image && providerUrl(w.image) == url,
    );

    await tester.ensureVisible(find.text('共 3 项'));
    await tester.pumpAndSettle();
    expect(downloadButton(tester, within: '混合预览').onPressed, isNull);

    // 点第一张:出勾,下载按钮活了
    // (缩略图那格的中心有时落在卡片裁剪区外,点了会报 warning,所以关掉它 ——
    //  真要没点中,下面的「按钮活了」就断言不过。)
    await tester.tap(
      tile('https://example.invalid/1.jpeg'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
    expect(downloadButton(tester, within: '混合预览').onPressed, isNotNull);

    // 再点同一张:取消选中,下载按钮回到灰色
    await tester.tap(
      tile('https://example.invalid/1.jpeg'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
    expect(downloadButton(tester, within: '混合预览').onPressed, isNull);
  });

  testWidgets('解析页:一条视频加一张图走混合卡,要选中才能下', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '单条视频',
        'desc': '文案',
        'platform': '抖音',
        'video_url': 'https://example.invalid/v.mp4',
        'cover_url': 'https://example.invalid/c.jpg',
        'image_list': <dynamic>['https://example.invalid/only.jpg'],
      },
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/single/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 一条视频 + 一张图也算混合:只出混合卡,媒体卡和图集卡都不出现
    expect(find.text('混合预览'), findsOneWidget);
    expect(find.text('媒体预览'), findsNothing);
    expect(find.text('图集预览'), findsNothing);
    expect(find.text('共 2 项'), findsOneWidget);

    // 两条媒体:要「全选媒体」或点缩略图选中才能下
    expect(find.text('全选媒体'), findsOneWidget);
    expect(downloadButton(tester, within: '混合预览').onPressed, isNull);

    await tester.ensureVisible(find.text('全选媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选媒体'));
    await tester.pumpAndSettle();
    expect(downloadButton(tester, within: '混合预览').onPressed, isNotNull);
  });

  testWidgets('解析页:视频缩略图带播放标识,图片缩略图带看大图的眼睛', (tester) async {
    usePhoneSurface(tester);
    // 纯视频 + 两张图:走混合卡
    useStubParseBackend();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://b23.tv/abcd',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 混合卡:一条视频的封面格右下角一个播放标识,两张图那两格是一只眼睛。
    // 按尺寸滤一下 —— 音频卡那颗播放按钮是 play_fill 但 18,标识是 11。
    await tester.ensureVisible(find.text('共 3 项'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is Icon && w.icon == CupertinoIcons.play_fill && w.size == 11,
      ),
      findsOneWidget,
    );
    // 视频封面不是一张能看的图,它那格不给眼睛:三格里只有两张真图片有
    expect(find.byIcon(CupertinoIcons.eye_fill), findsNWidgets(2));
  });

  testWidgets('解析页:纯图集的缩略图不带播放标识', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '纯图集',
        'desc': '文案',
        'platform': '抖音',
        'image_list': <dynamic>[
          'https://example.invalid/1.jpg',
          'https://example.invalid/2.jpg',
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

    expect(find.text('图集预览'), findsOneWidget);
    expect(find.text('共 2 张'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.play_fill), findsNothing);
  });

  testWidgets('解析页:单张图片的图集直接能下,没有全选', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '单图',
        'desc': '文案',
        'platform': '抖音',
        'image_list': <dynamic>['https://example.invalid/only.jpg'],
      },
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/one/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 没有视频:只有图集卡和文案卡。一张图不用选中,直接一颗能按的「下载媒体」
    expect(find.text('图集预览'), findsOneWidget);
    expect(find.text('混合预览'), findsNothing);
    expect(find.text('共 1 张'), findsOneWidget);
    expect(find.text('全选媒体'), findsNothing);
    expect(downloadButton(tester, within: '图集预览').onPressed, isNotNull);
  });

  testWidgets('解析页:点图片缩略图的眼睛弹大图预览,窗口里是这张图的原片', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '纯图集',
        'desc': '文案',
        'platform': '抖音',
        'image_list': <dynamic>[
          'https://example.invalid/1.jpg',
          'https://example.invalid/2.jpg',
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

    // 图集两格图,右下角各一只眼睛(视频那几格才有播放标识)
    expect(find.byIcon(CupertinoIcons.eye_fill), findsNWidgets(2));
    expect(find.byIcon(CupertinoIcons.play_fill), findsNothing);

    await tester.tap(find.byIcon(CupertinoIcons.eye_fill).first);
    await tester.pumpAndSettle();

    // 窗口:上面一张大图,下面一颗关闭
    expect(find.text('图片预览'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    // 窗口里那张就是这一格的原片地址 —— 缩略图那格也是同一条,所以一共两张。
    // 走的是同一条地址、同一个解码器:不是把 72 宽的缩略图拉大。
    expect(imageCount(tester, 'https://example.invalid/1.jpg'), 2);

    // 遮蔽不许慢半拍:这条路由把遮蔽压进动画的前 40% 就铺满。系统那条
    // (showCupertinoDialog)用的是 Curves.ease,走到后半程还剩一截 —— 面板已经压
    // 上来了、身后那片才刚黑透,看着就是"遮蔽跟不上"。
    final route = ModalRoute.of(tester.element(find.text('图片预览')))!;
    expect(route.barrierCurve.transform(0.4), 1.0);
    expect(route.transitionDuration, const Duration(milliseconds: 180));

    // 点眼睛只是看大图,没顺手把这一格选中(两条媒体仍然要选中才能下)
    expect(downloadButton(tester, within: '图集预览').onPressed, isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('图片预览'), findsNothing);
    expect(imageCount(tester, 'https://example.invalid/1.jpg'), 1);
  });
}
