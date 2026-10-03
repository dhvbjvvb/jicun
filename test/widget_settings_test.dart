// 设置、通知与下载文案 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/pages/preview.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/sponsor_store.dart';
import 'package:jicun/ui/notifications.dart';
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

  // 赞助名单同一条理:SponsorPage 一 initState 就在后台刷新。这里把整条取数
  // 换成"什么都拉不到"—— 两个出口(普通线路 / 优选 IP 连接器)一起堵上,
  // 用例不会去连真接口域名,页面显示的就是内置兜底那份。
  sponsorStore.fetchOverride = (_) async => null;


  testWidgets('系统主题卡:点开滑出三个选项,选一个回弹收起', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();

    // 卡片高度用「系统主题」到下一张卡标题的距离量,不依赖私有组件类型
    double cardHeight() =>
        tester.getTopLeft(find.text('底栏文字标识隐藏')).dy -
        tester.getTopLeft(find.text('系统主题')).dy;

    // 收起态:标题上只有当前值(选项内容一直挂在树上,只是被裁没了)
    expect(find.text('跟随系统'), findsWidgets);
    final collapsed = cardHeight();

    await tester.tap(find.text('系统主题'));
    await tester.pump();
    // 逐帧采样:动画长度是可调的,「采样哪一帧」不该写死在测试里,
    // 这里只断言过程里出现过峰值 / 谷值。
    final opening = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      opening.add(cardHeight());
    }
    await tester.pumpAndSettle();
    final expanded = cardHeight();

    expect(expanded, greaterThan(collapsed));
    // 真的是过渡:中途有一帧停在收起与展开之间
    expect(opening.any((h) => h > collapsed && h < expanded), isTrue);
    // 回弹:过程中冲过了最终高度再落回来
    expect(opening.reduce(math.max), greaterThan(expanded));
    // 时长:展开约 460ms(16ms 一帧 ≈ 29 帧)。太快就是「被弹开」,用户点名过。
    final openFrames = opening.indexWhere((h) => h >= expanded - 0.5);
    expect(openFrames, greaterThan(15));
    expect(find.text('浅色'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pump();
    final closing = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      closing.add(cardHeight());
    }
    await tester.pumpAndSettle();

    // 收起也带回弹:先把箱子往回涨一点,再收到底
    expect(closing.reduce(math.max), greaterThan(expanded));
    // 收起也不是一帧贴到底
    final closeFrames = closing.indexWhere((h) => h <= collapsed + 0.5);
    expect(closeFrames, greaterThan(12));

    // 选完收起:选中值写进了标题,选项那份被裁掉且不再响应触摸
    expect(cardHeight(), collapsed);
    expect(find.text('深色').hitTestable(), findsOneWidget);
    expect(find.text('浅色').hitTestable(), findsNothing);
  });

  testWidgets('关于本APP:四张一行卡摊开摆着,开源地址点一下就复制', (tester) async {
    usePhoneSurface(tester);
    final copied = useClipboardWrite();
    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于本APP'));
    await tester.pumpAndSettle();

    // 四张卡就是四行字,内容和文案一字不差。标题和内容在同一个 Text.rich 里
    // (标题后跟一个半角冒号),所以断言整行的纯文本。
    for (final line in const [
      '开源地址:https://github.com/dhvbjvvb/jicun',
      '制作人:春日大阪',
      '彩蛋出席:奶龙,不知名小人物,不知名大人物',
      '免责声明:本项目仅供学习与技术交流使用，请勿用于商业用途。解析与下载的内容版权归原作者所有，请自行确认拥有相应权利后再保存或传播，因使用本工具产生的一切后果由使用者自行承担。',
    ]) {
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == line,
        ),
        findsOneWidget,
        reason: '这一行应该是「$line」',
      );
    }

    // 不摆"点击即可复制"之类的提示(用户点名不要)
    expect(find.textContaining('点击'), findsNothing);

    // 但功能要在:点开源地址那一行就复制,并给回音
    await tester.tap(find.textContaining('开源地址:'));
    await tester.pumpAndSettle();
    expect(copied, ['https://github.com/dhvbjvvb/jicun']);
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('赞助名单:设置里进得去,页面只剩一句赞助文案', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    expect(find.text('修改主题，底栏效果，自定义背景图'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('赞助名单'), 200);
    expect(find.text('为本项目提供支持的吴彦祖和刘亦菲'), findsOneWidget);

    await tester.tap(find.text('赞助名单'));
    await tester.pumpAndSettle();

    // 二级页是一张表:表头三列都在,某一条金额也摆出来了。
    expect(find.text('微信昵称'), findsOneWidget);
    expect(find.text('赞助时间'), findsOneWidget);
    expect(find.text('赞助金额'), findsOneWidget);
    expect(find.text('¥8.88'), findsOneWidget);
    // 原来的提示卡删了,这页不再有可展开的卡。
    expect(find.text('提示'), findsNothing);
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNothing);
  });

  testWidgets('赞助名单:线上那份拉回来之后,表格自己重画', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    usePhoneSurface(tester);

    // 替身吐一份线上格式的响应,名字是兜底里没有的 —— 它出现即说明
    // "网络 -> 存储 -> 界面"这一条真的走通了。
    addTearDown(() => sponsorStore.fetchOverride = null);
    sponsorStore.fetchOverride = (_) async =>
        '{"updated":"2026-10-02T14:52:44+08:00","sponsors":['
        '{"name":"*联调","date":"10月3日","amount":"¥1.23"}]}';
    await sponsorStore.refresh();

    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('赞助名单'), 200);
    await tester.tap(find.text('赞助名单'));
    await tester.pumpAndSettle();

    expect(find.text('*联调'), findsOneWidget);
    expect(find.text('10月3日'), findsOneWidget);
    expect(find.text('¥1.23'), findsOneWidget);
    // 兜底那份已经被顶掉了:它是"还能不能显示"的底线,不是一直挂着的备胎。
    expect(find.text('¥8.88'), findsNothing);
  });

  testWidgets('使用帮助及反馈:反馈渠道点一下就复制,平台卡点开滑出教程', (tester) async {
    usePhoneSurface(tester);
    final copied = useClipboardWrite();
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    // 这一页列表长,设置项本身要滚到才点得到
    await tester.scrollUntilVisible(find.text('使用帮助及反馈'), 200);
    await tester.tap(find.text('使用帮助及反馈'));
    await tester.pumpAndSettle();

    // 第一张卡:反馈渠道,两行都在,不伸缩
    expect(find.text('反馈渠道'), findsOneWidget);
    expect(find.text('1124541108'), findsOneWidget);
    expect(find.text('1515068599@qq.com'), findsOneWidget);

    await tester.tap(find.text('QQ群'));
    await tester.pumpAndSettle();
    expect(copied, ['1124541108']);
    // 复制完要给回音,不然点了看不出发生过什么
    expect(find.text('已复制'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('QQ邮箱'));
    await tester.pumpAndSettle();
    expect(copied, ['1124541108', '1515068599@qq.com']);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    // 平台卡:名字和「支持解析的内容」在收起态就要看得见
    expect(find.text('抖音'), findsOneWidget);
    expect(find.text('视频、图片、实况、文案'), findsWidgets);

    // 图标真的是从 assets/platform-icons/ 里取到的。加载失败时 Image.asset 会走
    // errorBuilder 给一个空盒子,界面上看不出差别 —— 所以这里直接问一次资源。
    expect(find.byType(Image), findsWidgets);
    final icon = await rootBundle.load('assets/platform-icons/douyin.png');
    expect(icon.lengthInBytes, greaterThan(0));

    // 教程那块默认高度为 0;里面的 Text 被裁掉之后自身尺寸还在,所以量外层
    final reveal = find.byKey(const ValueKey('platformTutorial.抖音'));
    double tutorialHeight() => tester.getSize(reveal).height;
    expect(tutorialHeight(), 0);

    await tester.tap(find.text('抖音'));
    await tester.pump();
    final opening = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      opening.add(tutorialHeight());
    }
    await tester.pumpAndSettle();
    final expanded = tutorialHeight();

    expect(expanded, greaterThan(0));
    // 真的是过渡,不是一帧铺开
    expect(opening.any((h) => h > 0 && h < expanded), isTrue);
    // 回弹和「主题与外观」同一套:过程中冲过最终高度再落回来
    expect(opening.reduce(math.max), greaterThan(expanded));
  });

  testWidgets('卡片列表:越界拖动只走一点点,回弹还在', (tester) async {
    usePhoneSurface(tester);
    const dragBy = 300.0;

    // 对照组:同样的画布、同样的手势,用 Cupertino 默认的越界阻力量一次。
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: const BouncingScrollPhysics(),
          children: List.generate(
            40,
            (i) => SizedBox(height: 60, child: Text('row$i')),
          ),
        ),
      ),
    );
    final bare = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    final defaultOverscroll = await dragPastTop(
      tester,
      bare,
      dragBy,
      tester.getCenter(find.byType(Scrollable)),
    );
    expect(defaultOverscroll, greaterThan(0));

    // 本尊:缩放拉满让内容真的溢出 —— 不溢出时列表根本不接受拖动。
    SharedPreferences.setMockInitialValues({'ui.scale': 1.3});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(LiquidGlassDemo(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();

    // 三张卡现在默认都是收起的,刚进页面撑不满一屏(见下一个用例)。
    // 这个用例要量「溢出时」的越界阻力,所以把后两张展开 —— 先展开最后一张:
    // 反过来先展开「底栏外观样式」的话,「界面缩放大小」会被顶出列表的构建范围。
    await tester.tap(find.text('界面缩放大小'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('底栏外观样式'));
    await tester.pumpAndSettle();

    // 锚在「底栏外观样式」上而不是最后一张卡:两张都展开之后,「界面缩放大小」
    // 已经被顶出列表的构建范围,拿它当锚点会找不到。
    final position = tester
        .state<ScrollableState>(
          find.ancestor(
            of: find.text('底栏外观样式'),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    // 前提:内容真的溢出了,否则下面量到的一直是 0
    expect(position.maxScrollExtent, greaterThan(0));

    final overscroll = await dragPastTop(
      tester,
      position,
      dragBy,
      tester.getCenter(find.text('底栏文字标识隐藏')),
    );

    // 松手回到边界内
    expect(position.pixels, position.minScrollExtent);
    // 回弹还在,但明显比默认短(阻力砍半)
    expect(overscroll, greaterThan(0));
    expect(overscroll, lessThan(defaultOverscroll * 0.75));
  });

  testWidgets('首次进入:内容没溢出,也要能拖出回弹', (tester) async {
    usePhoneSurface(tester);
    const dragBy = 200.0;
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(
          find.ancestor(
            of: find.text('界面缩放大小'),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    // 前提:这就是刚进页面时的样子 —— 内容不满一屏,列表本来滚不动
    expect(position.maxScrollExtent, 0);

    final overscroll = await dragPastTop(
      tester,
      position,
      dragBy,
      tester.getCenter(find.text('底栏文字标识隐藏')),
    );

    // 没展开任何卡片也要有回弹,而不是「拖不动」
    expect(overscroll, greaterThan(0));
    expect(position.pixels, position.minScrollExtent);
  });

  testWidgets('设置会记住:重开 App 读回上次的缩放与主题,改动写回存储', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({
      'ui.scale': 1.15,
      'ui.themeMode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(LiquidGlassDemo(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();

    // 读回:上次的缩放值出现在卡片上,而不是默认的 100%
    expect(find.text('115%'), findsOneWidget);

    // 写回:改一项之后存储里就是新值
    expect(prefs.getString('ui.themeMode'), 'dark');
    await tester.tap(find.text('系统主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(prefs.getString('ui.themeMode'), 'light');
  });

  testWidgets('通知管理与下载:两个开关各自独立,关掉就写回存储', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(LiquidGlassDemo(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('通知管理与下载'));
    await tester.pumpAndSettle();

    // 开关顺序就是列表顺序:0 = 下载完成通知,1 = 下载失败通知
    expect(tester.widget<Switch>(find.byType(Switch).at(0)).value, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch).at(1)).value, isTrue);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch).at(1)).value, isFalse);
    expect(prefs.getBool('notify.downloadFailed'), isFalse);
    // 另一个不受影响
    expect(tester.widget<Switch>(find.byType(Switch).at(0)).value, isTrue);
    expect(prefs.getBool('notify.downloadDone'), isTrue);
  });

  testWidgets('下载结果 ↔ 通知开关:成功看「下载完成」,失败看「下载失败」', (tester) async {
    expect(
      downloadNoticeEnabled(ok: true, done: true, failed: false),
      isTrue,
      reason: '成功 + 完成通知开着 → 发',
    );
    expect(
      downloadNoticeEnabled(ok: true, done: false, failed: true),
      isFalse,
      reason: '成功不受「失败通知」管',
    );
    expect(
      downloadNoticeEnabled(ok: false, done: true, failed: false),
      isFalse,
      reason: '失败不受「完成通知」管',
    );
    expect(
      downloadNoticeEnabled(ok: false, done: false, failed: true),
      isTrue,
      reason: '失败 + 失败通知开着 → 发',
    );
  });

  testWidgets('下载失败文案:原生异常不甩给用户,按「该怎么办」归类', (tester) async {
    // 原生下载器把错误拼成 `类型: message`,Dart 再包一层 HttpException ——
    // 这句原文曾经直接进弹窗(用户实测看到的就是这一串)。
    expect(
      downloadErrorMessage(
        const HttpException('SocketException: Connection reset'),
      ),
      '网络中断，请重试',
    );
    expect(
      downloadErrorMessage(
        const HttpException('SocketTimeoutException: timeout'),
      ),
      '网络中断，请重试',
    );
    expect(
      downloadErrorMessage(const HttpException('HTTP 403')),
      '下载地址已失效，请重新解析',
      reason: '4xx 是直链失效,重试无用,得重新解析',
    );
    expect(
      downloadErrorMessage(
        const HttpException('文件不完整:1234/5678 字节'),
      ),
      '文件不完整，请重试',
    );
    expect(
      downloadErrorMessage(const DownloadCancelled()),
      '已取消',
    );
    // 音频抽轨端点(自己的 /audio)失败时回的是中文理由,那句比「服务器暂时不可用」
    // 具体得多 —— 用户看到「这段视频没有可提取的音轨」才知道该换个链接。
    expect(
      downloadErrorMessage(
        const HttpException(
          'HTTP 502: {"retcode":502,"retdesc":"这段视频没有可提取的音轨","succ":false}',
        ),
      ),
      '这段视频没有可提取的音轨',
    );
    expect(
      downloadErrorMessage(const HttpException('HTTP 500')),
      '服务器暂时不可用，请稍后再试',
      reason: '没有可读理由的 5xx 才用通用文案',
    );
    expect(
      downloadErrorMessage(StateError('没见过的错')),
      contains('没见过的错'),
      reason: '没归过类的错因原样透出,不要藏',
    );
  });

  test('播放器请求头:B 站 CDN 补 Referer,别的主机一个都不塞', () {
    // B 站 DASH 那条纯音频流不带 Referer 一律 403(实测),而它的 Content-Type 是
    // video/mp4 —— 没有任何本地线索能反推出来,只能按主机名补。少了这一步,音频
    // 预览就只有一块灰面板(播放器加载失败),时长自然也是空的。
    final headers = playbackHeaders(
      'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/16/51/x-1-30280.m4s?e=1',
    );
    expect(headers['Referer'], 'https://www.bilibili.com/');
    // **不塞 UA**:just_audio 会把 headers 里的 User-Agent 摘出来当播放器自己的 UA
    // 用(AudioPlayer.buildDataSourceFactory),而 B 站 CDN 按「IP + UA」一起判 ——
    // 我们猜哪一份都可能猜错,交给播放器自己那份。
    expect(headers.containsKey('User-Agent'), isFalse);

    // 别人的 CDN 不吃这一套:乱塞一个 Referer 反而可能被拒
    expect(playbackHeaders('https://cdn.example/a.mp3'), isEmpty);
    expect(playbackHeaders(''), isEmpty);
  });

  testWidgets('实况帖(没有 video_url):下载的是实况的 MP4,不是封面', (tester) async {
    usePhoneSurface(tester);
    // 真实接口对实况帖就是这样的:video_url 为 null,视频只在 live_photo_url 里
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '实况单条',
        'desc': '神的睡觉方式',
        'platform': '抖音',
        'video_url': null,
        'cover_url': 'https://example.invalid/c.jpg',
        'audio_url': 'https://example.invalid/a.mp3',
        'image_list': [
          {
            'url': 'https://example.invalid/live.jpg',
            'live_photo_url': 'https://example.invalid/live.mp4',
          },
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
      'https://v.douyin.com/liveonly/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 单条媒体:底部是一颗直接能按的「下载媒体」(不是多视频的选中网格)
    await tester.tap(find.text('下载媒体').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(items, hasLength(1));
    expect(items.single.url, 'https://example.invalid/live.mp4');
    expect(items.single.kind, MediaKind.video);
    expect(items.single.fileName, endsWith('.mp4'));

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });

  // ────────────────────── 转场:整屏抓纹理那条路 ──────────────────────

  testWidgets('主壳不挂库的滚动边缘渐隐(它每次 pop 都整屏抓纹理)', (tester) async {
    // 库默认 edgeFade 为真:只要传了 bottomBar,整个 body 就被包进
    // GlassScrollEdgeEffect。它并不只是画一层渐变 —— 默认(soft)档会把整屏背景
    // toImage(pixelRatio: 1.0) 抓成一张纹理,而且依赖 ModalRoute.isCurrentOf:
    // 每次从二级页返回一级页,都在转场中间重新抓一次整屏。那次离屏渲染是 GPU 的活,
    // 和转场抢同一个光栅线程,慢机型上就是「一按返回就卡」。
    //
    // 这里钉住「那层效果没有被打开」:光栅收益在无头测试里量不到(与
    // test/board_fade_test.dart 里既有的注释同一口径),能验的只是结构。
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(GlassScrollEdgeEffect),
      findsNothing,
      reason: '开着它每次 pop 都要整屏抓纹理,和转场抢光栅',
    );
  });

  // ────────────────────────── 检查更新 ──────────────────────────

}