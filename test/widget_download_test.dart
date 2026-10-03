// 下载 / 取消 / 粘贴 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:async';
import 'dart:io';

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
import 'package:jicun/ui/download_progress_card.dart';
import 'package:jicun/ui/progress_ring.dart';
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


  testWidgets('解析页:点下载媒体弹出进度卡片,不是原来的提示框', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubVideoOnlyData);
    useStubDownloader();
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

    // 媒体卡只有一条视频,下载按钮直接能按
    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pump();

    // 弹出来的是下载进度卡片:右上角标题、取消按钮,原来的提示框不该再出现
    expect(find.text('下载进度'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    expect(find.text('知道了'), findsNothing);

    // 走到一半:百分比在动,按钮还是「取消下载」
    // (不写死具体数字 —— 假下载每 100ms 走 10%,而 pump 的步长和入场动画
    //  谁先谁后会差一格,断言「有那么个百分比」就够)
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byWidgetPredicate((w) => w is Text && (w.data ?? '').endsWith('%')),
      findsOneWidget,
    );
    expect(find.text('取消下载'), findsOneWidget);

    // 中途取消:卡片关掉,不留下半个文件
    await tester.tap(find.text('取消下载'));
    await tester.pumpAndSettle();
    expect(find.text('下载进度'), findsNothing);
  });

  testWidgets('中途取消:相册里什么都没有,按「下载失败」发一条通知', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubVideoOnlyData);
    useStubDownloader();
    final calls = useStubNotificationChannel();
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

    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pump();
    // 假下载 1 秒走完,走到一半取消
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('取消下载'));
    await tester.pumpAndSettle();

    final shown = calls.where((call) => call.method == 'show').toList();
    expect(shown, hasLength(1), reason: '取消 = 相册里没有东西,按失败通知');
    expect('${shown.single.arguments}', contains('下载失败'));
  });

  testWidgets('下载失败:卡片自己变红叉,点「关闭」能收掉', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubVideoOnlyData);
    useStubDownloader();
    // 假下载器改成开头就砸:失败态该在这张卡里收场
    // (通知那条路不接通道也不该挡住失败态 —— 那正是以前卡住的原因之一)
    Downloader.fetchImpl =
        (item, temp, onFraction, cancelled, onSize, client) async =>
            throw const SocketException('连接被重置');
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

    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // 失败就在这张卡里:原因写在卡里,不再另弹一个「知道了」提示窗
    expect(find.text('下载进度'), findsOneWidget);
    expect(find.text('网络中断，请重试'), findsOneWidget);
    expect(find.text('知道了'), findsNothing);

    // 红叉徽章:盘面渐变两头都得是红的。深端留成蓝色的话,红 lerp 进深蓝会变成
    // 发紫的脏红 —— 成功 / 失败该只差颜色。
    final badges = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<ScallopFill>()
        .toList();
    expect(badges, isNotEmpty, reason: '失败态该有那个波浪徽章');
    for (final stop in badges.first.stops) {
      expect(stop.r, greaterThan(stop.b), reason: '失败态的渐变不该掺蓝');
    }

    // 按钮是「关闭」不是「取消下载」:下载循环早就结束了,再发取消没人接,
    // 窗口会一直卡在那儿 —— 这条就是那个 bug。
    expect(find.text('取消下载'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('下载进度'), findsNothing);
  });

  testWidgets('解析页:下载跑完,取消按钮变成完成并关掉卡片', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: stubVideoOnlyData);
    useStubDownloader();
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

    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pump();

    // 假下载 1 秒走完;走完之后圆环回到 100%,按钮改口叫「完成」
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsNothing);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('取消下载'), findsNothing);

    // 点完成,卡片收掉
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('下载进度'), findsNothing);
  });

  testWidgets('解析页:点下载只是暂停预览,下完接着播(播放器不销毁)', (tester) async {
    usePhoneSurface(tester);
    final video = useFakeVideoPlayer();
    useStubParseBackend(data: stubVideoOnlyData);
    useStubDownloader();
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

    // 先让预览播起来。播放按钮按尺寸认:音频卡那颗也是 play_fill,但没网可播、
    // 整行是灰的,而这里要的是媒体卡那颗(见 PlaybackRow)。
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w is Icon && w.icon == CupertinoIcons.play_fill && w.size == 18,
          )
          .first,
    );
    await tester.pump();
    expect(video.playing, isTrue, reason: '预览应该已经播起来了');

    // 点下载:只是暂停,播放器留着(以前是直接 dispose,于是再也播不了)
    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pump();
    expect(find.text('下载进度'), findsOneWidget);
    expect(video.playing, isFalse, reason: '下载期间预览要让位');
    expect(video.disposed, isFalse, reason: '只是暂停,不是把播放器拆了');

    // 假下载 1 秒走完:当初在播的,下完接着播
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(video.disposed, isFalse);
    expect(video.playing, isTrue, reason: '下完该接着预览');

    await tester.tap(find.text('完成'));
    await tester.pump();

    // 收尾:把预览停掉再 settle —— 播着的播放器每 100ms 记一次位置,一直有帧要画,
    // pumpAndSettle 永远等不到静止。
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w is Icon &&
                w.icon == CupertinoIcons.pause_fill &&
                w.size == 18,
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(video.playing, isFalse);
  });

  testWidgets('解析页:图集下载,文件名是标题加批次序号,话题标签不进名字', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        // 上线抓到的真实样式:标题带话题标签,图集三条
        'title': '云南旅行日记，第三天 #旅行 #vlog',
        'desc': '文案',
        'platform': '抖音',
        'video_url': null,
        'cover_url': 'https://example.invalid/c.jpg',
        'image_list': <dynamic>[
          'https://example.invalid/1.jpeg',
          'https://example.invalid/2.webp',
          'https://example.invalid/3.png',
        ],
      },
    );
    useStubDownloader();
    final items = <DownloadItem>[];
    Downloader.fetchImpl =
        (item, temp, onFraction, cancelled, onSize, client) async {
          items.add(item);
          onSize?.call(100);
          onFraction(1);
          return File('${temp.path}/${item.fileName}');
        };
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

    await tester.ensureVisible(find.text('全选媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载媒体').first);
    await tester.pumpAndSettle();

    expect(items, hasLength(3));
    // 话题标签被剥掉,序号从 1 起,后缀仍按各自地址猜(收尾时下载器会按文件头改)
    expect(items.map((i) => i.fileName).toList(), <String>[
      '云南旅行日记，第三天_1.jpeg',
      '云南旅行日记，第三天_2.webp',
      '云南旅行日记，第三天_3.png',
    ]);
  });

  testWidgets('解析页:混合卡下载,视频那格下的是视频地址而不是封面', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '单条视频',
        'desc': '文案',
        'platform': '快手',
        'video_url': 'https://example.invalid/v.mp4',
        'cover_url': 'https://example.invalid/c.jpg',
        'image_list': <dynamic>['https://example.invalid/1.jpg'],
      },
    );
    useStubDownloader();
    final items = <DownloadItem>[];
    Downloader.fetchImpl =
        (item, temp, onFraction, cancelled, onSize, client) async {
          items.add(item);
          onSize?.call(100);
          onFraction(1);
          return File('${temp.path}/${item.fileName}');
        };
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.kuaishou.com/mixed',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('全选媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载媒体').first);
    await tester.pumpAndSettle();

    // 缩略图网格里视频那格显示的是封面(jpg),但下载必须走视频地址 ——
    // 拿封面当视频下,文件名会取到 .jpg、MIME 是 image/jpeg,而 kind 还是 video,
    // 媒体库直接拒收:publish_failed, image/jpeg cannot be inserted into
    // content://media/external_primary/video/media
    expect(items, hasLength(2));
    final video = items.firstWhere((i) => i.kind == MediaKind.video);
    expect(video.url, 'https://example.invalid/v.mp4');
    expect(video.fileName, endsWith('.mp4'));

    final image = items.firstWhere((i) => i.kind == MediaKind.image);
    expect(image.url, 'https://example.invalid/1.jpg');
    expect(image.fileName, endsWith('.jpg'));
  });

  testWidgets('下载器:多条并发下,不是一条一条排队', (tester) async {
    // 只为了拿到 path_provider 的假实现
    usePhoneSurface(tester);
    useStubDownloader();

    var running = 0;
    var peak = 0;
    Downloader.fetchImpl =
        (item, temp, onFraction, cancelled, onSize, client) async {
          running++;
          peak = running > peak ? running : peak;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          running--;
          onFraction(1);
          return File('${temp.path}/${item.fileName}');
        };

    var last = 0.0;
    // 不 await,改成让用例自己推时钟:testWidgets 里默认是假时钟,直接 await
    // 会一直等真定时器(挂到用例超时)。推时钟还能顺带看并发峰值中间态。
    // 也刻意不用 runAsync —— 真异步工作跨用例残留会打乱后面的用例。
    final done = Downloader.saveAll([
      for (var i = 0; i < 8; i++)
        DownloadItem(
          url: 'https://example.invalid/$i',
          fileName: 'f$i.jpg',
          kind: MediaKind.image,
        ),
    ], onProgress: (p) => last = p.fraction);

    // 4 条并发 × 每条 2 个 50ms 周期 = 100ms
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await done;

    // 串行的话同一时刻只会有一条在跑;并发才会看到多条叠在一起
    expect(peak, greaterThan(1));
    expect(peak, lessThanOrEqualTo(Downloader.concurrency));
    // 收尾必须报满
    expect(last, 1.0);
  });

  testWidgets('解析页:描述为空时没有文案预览卡', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '只有标题没有描述',
        'desc': '',
        'platform': '抖音',
        'video_url': 'https://example.invalid/v.mp4',
        'image_list': <dynamic>[],
      },
    );
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

    // 文案卡只放描述;没有描述这张卡根本不该建出来
    expect(find.text('文案预览'), findsNothing);
    expect(find.text('媒体预览').hitTestable(), findsOneWidget);
  });

  testWidgets('解析页:粘进整段分享文本,输入框只留链接', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      '7.62 复制打开抖音,看看【某某的作品】https://v.douyin.com/MM-UwrwuwWU/ 复制此链接,打开Dou音搜索',
    );
    await tester.pump();

    expect(find.text('https://v.douyin.com/MM-UwrwuwWU/'), findsOneWidget);
    expect(find.textContaining('复制打开抖音'), findsNothing);
  });

  testWidgets('解析页:切走再回来,解析结果和输入框都还在', (tester) async {
    usePhoneSurface(tester);
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
    expect(find.text('混合预览').hitTestable(), findsOneWidget);

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('解析').first);
    await tester.pumpAndSettle();

    // 状态挂在根 State 上,所以换 tab 回来不该要人重新解析一遍
    expect(find.text('混合预览').hitTestable(), findsOneWidget);
    expect(find.text('https://b23.tv/abcd'), findsOneWidget);
  });

  testWidgets('解析页:成功后按钮变「完成解析」并置灰,点输入框才恢复', (tester) async {
    usePhoneSurface(tester);
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

    expect(find.text('完成解析'), findsOneWidget);
    expect(find.text('开始解析'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('完成解析'),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );

    // 手动点一下输入框 → 按钮放回「开始解析」
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    expect(find.text('开始解析'), findsOneWidget);
    expect(find.text('完成解析'), findsNothing);
  });

  testWidgets('粘贴链接卡:空着时「清空」不可点,「粘贴」随时把剪贴板塞进去', (tester) async {
    usePhoneSurface(tester);
    useClipboardText('https://v.douyin.com/abcd/');
    // 自动粘贴关掉:这条用例测的是「粘贴」这颗按钮。启动时自动把剪贴板填进输入框
    // 会让"输入框空着"这个前提不成立(自动粘贴有它自己的用例)。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'clipboard.autoPasteParse': false,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(LiquidGlassDemo(prefs: prefs));
    await tester.pumpAndSettle();

    // 输入框空着:清空灰掉,粘贴照样可点(它不看输入框里有什么)
    expect(actionEnabled(tester, 'clear'), isFalse);
    expect(actionEnabled(tester, 'paste'), isTrue);

    // 有内容(哪怕根本不是链接):清空可点
    await tester.enterText(find.byType(CupertinoTextField), '随手写点什么');
    await tester.pumpAndSettle();
    expect(actionEnabled(tester, 'clear'), isTrue);

    // 粘贴:剪贴板内容直接顶掉原来那段文字
    await tester.tap(find.byKey(const ValueKey('pasteLink.paste')));
    await tester.pumpAndSettle();
    expect(linkText(tester), 'https://v.douyin.com/abcd/');

    // 清空:输入框变空,清空自己又灰回去
    await tester.tap(find.byKey(const ValueKey('pasteLink.clear')));
    await tester.pumpAndSettle();
    expect(linkText(tester), isEmpty);
    expect(actionEnabled(tester, 'clear'), isFalse);
  });

  testWidgets('粘贴:自带剪贴板读成空时,走平台侧那条路(html / uri 那类剪贴板)', (tester) async {
    usePhoneSurface(tester);
    // 自带那条路读成 null —— 就是浏览器复制来的链接(只带 text/html)在真机上的样子
    useClipboardText(null);
    useStubClipboardChannel('https://v.douyin.com/abcd/');
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pasteLink.paste')));
    await tester.pumpAndSettle();

    expect(linkText(tester), 'https://v.douyin.com/abcd/');
    // 不能再说"没读到"
    expect(find.text('没读到剪贴板里的文字'), findsNothing);
  });

  testWidgets('粘贴:两条路都读不到,才说"没读到剪贴板里的文字"', (tester) async {
    usePhoneSurface(tester);
    useClipboardText(null);
    useStubClipboardChannel(null);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pasteLink.paste')));
    // 读空之后会等一下再问一次(见 readClipboard),得让假时钟走过那段时间
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('没读到剪贴板里的文字'), findsOneWidget);
  });

  testWidgets('取消下发后按钮先置灰,超过宽限就给「关闭」出口', (tester) async {
    // 这一条钉的是「取消期间不能是一颗按不动的死按钮」:原生卡住时用户得有个出口。
    final never = Completer<void>();
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: DownloadProgressCard(
            title: '测试',
            total: 1,
            run: (onProgress, cancelled) {
              onProgress(const DownloadProgress(received: 10, total: 100));
              return never.future;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('取消下载'));
    await tester.pump();
    expect(find.text('正在取消…'), findsOneWidget);
    // 这段时间按钮是**禁用**的(画成灰的、点不动),不是一颗按下去没反应的活按钮
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    // 超过宽限:换成「关闭」这个出口,按钮重新可用
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('关闭'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('网络收完(进度 50%)就改口径说「正在保存到相册」', (tester) async {
    // 进度口径是"搬两遍字节":50% 就是网络那一遍搬完、相册那一遍刚开始。
    // 这条钉住那个阈值 —— 原来写的是 0.99,于是整段搬运都没有这句话。
    final never = Completer<void>();
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: DownloadProgressCard(
            title: '测试',
            total: 1,
            run: (onProgress, cancelled) {
              onProgress(const DownloadProgress(received: 100, total: 200));
              return never.future;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('测试 · 正在保存到相册'), findsOneWidget);
  });

  testWidgets('上报停住之后环自己往前爬:数字一直在走,但不到 100%', (tester) async {
    // 真机上就是这么被看见的:网络最后一块卡住,进度钉在 49% 十几秒,然后一下跳到
    // 100%。这条钉住「停住也得看着在动」:数字自己缓慢往前爬(封顶 99%),同时弧上
    // 有一道流光扫着 —— 而真下完(上报到满载)那一下才给 100%。
    final never = Completer<void>();
    late void Function(DownloadProgress) report;
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: DownloadProgressCard(
            title: '测试',
            total: 1,
            run: (onProgress, cancelled) {
              report = onProgress;
              onProgress(const DownloadProgress(received: 50, total: 100));
              return never.future;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);

    RingPainter ring() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<RingPainter>()
        .single;
    String percent() => tester.widget<Text>(find.textContaining('%')).data!;

    expect(ring().stalled, isFalse, reason: '刚上报完,还在动,不该点流光');

    // 一直没新上报:数字必须往前走,而且到不了 100%
    // 一段一段地 pump:每帧之后补间落到新值上,和真机上一秒六十帧一样。
    // 一次 pump(12s) 只画一帧,补间还停在起点,看起来像没动 —— 那是测试的错觉。
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final crept = int.parse(percent().replaceAll('%', ''));
    expect(crept, greaterThan(50), reason: '停住之后数字得自己往前爬');
    expect(crept, lessThan(100), reason: '没真下完就不许给 100%');
    expect(ring().progress, lessThan(1.0), reason: '爬也要封在 100% 以下');
    expect(ring().stalled, isTrue, reason: '卡住了就该有那道流光');

    // 真上报回来了:以真值为准,流光收掉
    report(const DownloadProgress(received: 90, total: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(percent(), '90%', reason: '真值优先于爬出来的值');
    expect(ring().stalled, isFalse, reason: '又开始动了,流光该收');

    // 真下完那一下才给 100%
    report(const DownloadProgress(received: 100, total: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('完成'), findsOneWidget);
  });
}