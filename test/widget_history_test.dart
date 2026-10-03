// 历史板块 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:convert';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/history_store.dart';
import 'package:jicun/main.dart';
import 'package:jicun/parse_service.dart';
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

  testWidgets('历史板块:单击一张卡回解析页重新解析', (tester) async {
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

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('示例视频标题'));
    await tester.pumpAndSettle();

    // 跳回解析页,并且真的重新解析了一遍(按钮又锁成「完成解析」)
    expect(find.text('混合预览').hitTestable(), findsOneWidget);
    expect(find.text('完成解析'), findsOneWidget);
    // 输入框里带回的是那条记录的源链接
    expect(find.text('https://b23.tv/abcd'), findsOneWidget);
  });

  testWidgets('解析页:媒体与图集默认摊开,音频与文案默认收起', (tester) async {
    usePhoneSurface(tester);
    // 纯视频 + 图集两条独立的卡才走这个用例;混合链接默认摊开见上一条
    useStubParseBackend(data: stubVideoOnlyData);
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

    // 这条链接只有三张卡:媒体卡摊开,音频和文案卡收起 ——
    // 收起的卡在标题行右侧写「已解析」,所以正好两条。
    expect(find.text('已解析'), findsNWidgets(2));

    // 媒体卡是摊开的,所以它的播放行能碰到
    expect(find.text('媒体预览'), findsOneWidget);
    expect(find.text('00:00'), findsNWidgets(2));
    expect(find.text('00:00').hitTestable(), findsOneWidget);
  });

  testWidgets('解析页:接口给了 audio_url,音频卡放的就是那份独立音频', (tester) async {
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

    // 默认应答里有 audio_url,放的就是它 —— 不该改口叫「视频原声」
    expect(find.text('音频预览与下载'), findsOneWidget);
    expect(find.text('视频原声'), findsNothing);
  });

  testWidgets('解析页:接口没给音频,就只呈现视频卡,不拿视频顶一张音频出来', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '只有视频',
        'desc': '文案',
        'platform': '抖音',
        'video_url': 'https://example.invalid/v.mp4',
        'cover_url': 'https://example.invalid/c.jpg',
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

    // 面板完整跟着返回的数据走:没有独立音轨就没有音频卡。原来会退回视频自己那条
    // 音轨、照样画一张「视频原声」的卡 —— 用户点「下载音频」落到本地的是 MP4。
    expect(find.text('音频预览与下载'), findsNothing);
    expect(find.text('视频原声'), findsNothing);
    // 视频卡照常在
    expect(find.text('媒体预览'), findsOneWidget);
  });

  testWidgets('解析页:audio_url 就是视频地址时不算独立音轨,音频卡不出现', (tester) async {
    usePhoneSurface(tester);
    // 汽水音乐/豆包在拿不到纯音频时会把视频地址回填进 audio_url —— 那条「音频」
    // 下下来是一段有画面有声音的 MP4,不能当成独立音轨呈现给用户。
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '回填的音频',
        'desc': '文案',
        'platform': '汽水音乐',
        'video_url': 'https://example.invalid/v.mp4',
        'audio_url': 'https://example.invalid/v.mp4',
        'cover_url': 'https://example.invalid/c.jpg',
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

    expect(find.text('音频预览与下载'), findsNothing);
    expect(find.text('媒体预览'), findsOneWidget);
  });

  testWidgets('解析页:媒体窗口用封面当首帧,不是「无封面」', (tester) async {
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

    // 接口给了 cover_url,窗口就该铺它当首帧 —— 空着写「无封面」很怪
    expect(hasImageWith(tester, 'https://example.invalid/c.jpg'), isTrue);
  });

  testWidgets('冷启动预热一次连接,点输入框不会重复打', (tester) async {
    usePhoneSurface(tester);
    var pings = 0;
    ParseService.clientFactory = () => MockClient((request) async {
      if (request.url.path == '/ping') {
        pings++;
        return http.Response('', 204);
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, dynamic>{'succ': true, 'data': stubParseData}),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() => ParseService.clientFactory = http.Client.new);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    // 进 App 就把到反代的连接建起来:用户几秒内就会粘链接
    expect(pings, 1);

    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();

    // 前一次预热还在有效期内(12 秒),点几下都不该再打
    expect(pings, 1);
  });

  testWidgets('解析页:换一条链接重新解析,媒体窗口跟着换', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      sequence: <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '第一条',
          'desc': '第一条文案',
          'platform': '抖音',
          'video_url': 'https://example.invalid/a.mp4',
          'cover_url': 'https://example.invalid/cover-A.jpg',
          'image_list': <dynamic>[],
        },
        <String, dynamic>{
          'title': '第二条',
          'desc': '第二条文案',
          'platform': '抖音',
          'video_url': 'https://example.invalid/b.mp4',
          'cover_url': 'https://example.invalid/cover-B.jpg',
          'image_list': <dynamic>[],
        },
      ],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/aaa/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();
    expect(hasImageWith(tester, 'https://example.invalid/cover-A.jpg'), isTrue);

    // 点一下输入框解锁,换成第二条链接再解析
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://v.douyin.com/bbb/',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 媒体窗口现在必须是第二条的封面 —— 播放器/封面还停在上一条就是状态没换
    expect(hasImageWith(tester, 'https://example.invalid/cover-B.jpg'), isTrue);
    expect(
      hasImageWith(tester, 'https://example.invalid/cover-A.jpg'),
      isFalse,
    );
  });

  testWidgets('历史板块:同一条链接解析两次,只留最新一条', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> parseOnce() async {
      await tester.enterText(
        find.byType(CupertinoTextField),
        'https://b23.tv/abcd',
      );
      await tester.pump();
      await tester.tap(find.text('开始解析'));
      await tester.pumpAndSettle();
    }

    await parseOnce();
    // 点一下输入框把按钮解锁,再解析同一条链接
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    await parseOnce();

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    // 同一条链接只留一条,不是两条
    expect(find.text('示例视频标题'), findsOneWidget);
  });

  testWidgets('历史板块:标题长短不一,卡片高度一致', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final store = HistoryStore();
    // 前两条标题一行放得下,第三条占两行。不锁高度的话第三张会更高。
    await store.add(sampleResult('短标题'), 'https://v.douyin.com/1/');
    await store.add(sampleResult('中等标题'), 'https://v.douyin.com/2/');
    await store.add(
      sampleResult('特别特别长的一个标题,长到必须换行才放得下这句话'),
      'https://v.douyin.com/3/',
    );
    // 写盘现在有 300ms 防抖(见 HistoryStore 的类注释),而下面 pumpWidget 出来的
    // 是**另一个** HistoryStore 实例,它读的是盘上的东西 —— 这里必须先落到盘上。
    await store.flush();

    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    double top(String title) => tester.getTopLeft(find.text(title)).dy;

    // 相邻两张卡标题的纵向间距 = 卡高 + 卡间距。两个间距相等 == 卡高一致。
    final firstGap = top('中等标题') - top('短标题');
    final secondGap = top('特别特别长的一个标题,长到必须换行才放得下这句话') - top('中等标题');
    expect(secondGap, closeTo(firstGap, 0.5));
  });

  testWidgets('历史板块:全选要先点「选择」进选择模式才有用', (tester) async {
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

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    // 还没进选择模式:全选是灰的,点它不会选中任何东西,删除自然也删不掉
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('示例视频标题'), findsOneWidget);
  });

  testWidgets('历史板块:全选点一次全选中,再点一次全部取消', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      sequence: <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '第一条',
          'desc': '文案一',
          'platform': '抖音',
          'video_url': 'https://example.invalid/a.mp4',
          'image_list': <dynamic>[],
        },
        <String, dynamic>{
          'title': '第二条',
          'desc': '文案二',
          'platform': '抖音',
          'video_url': 'https://example.invalid/b.mp4',
          'image_list': <dynamic>[],
        },
      ],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> parse(String link) async {
      await tester.enterText(find.byType(CupertinoTextField), link);
      await tester.pump();
      await tester.tap(find.text('开始解析'));
      await tester.pumpAndSettle();
    }

    await parse('https://v.douyin.com/aaa/');
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    await parse('https://v.douyin.com/bbb/');

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    // 全选 → 再点一次全部取消。取消之后删除是灰的,点了什么都不会掉 ——
    // 这就是「第二次点击是反选」的证据。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);

    // 再全选一次:这次真的全删掉
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('暂无解析记录'), findsOneWidget);
  });

  testWidgets('解析页:长文案不截断,超过 12 行时出滚动条', (tester) async {
    usePhoneSurface(tester);
    // 30 行文字,稳稳超过 12 行
    final longDesc = List<String>.generate(30, (i) => '第 $i 行文案内容。').join();
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '长文案',
        'desc': longDesc,
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

    // 文案卡默认收起,点标题行展开
    await tester.ensureVisible(find.text('文案预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文案预览'));
    await tester.pumpAndSettle();

    // 整段文案都在树上,没有被 maxLines + ellipsis 截掉后半截 ——
    // 之前就是这里丢内容:App 上只显示到一半,接口返回的其实是完整的。
    final text = tester.widget<Text>(find.text(longDesc));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));

    // 超过 12 行 → 窗口锁死并出滚动条
    final box = find.byType(CupertinoScrollbar);
    expect(box, findsOneWidget);

    // 而且真的能滚 —— 这就是「用户能上下滑动看到全文」那一条。
    // 先把整个窗口滚进可见区,否则手指会落在外面(外层列表或底栏)上。
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: box, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));

    final rect = tester.getRect(box);
    await tester.dragFrom(
      Offset(rect.center.dx, rect.top + 30),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('解析页:短文案不出滚动条', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(
      data: <String, dynamic>{
        'title': '短文案',
        'desc': '就一行字。',
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

    await tester.ensureVisible(find.text('文案预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文案预览'));
    await tester.pumpAndSettle();

    // 没超过 12 行:窗口跟着文字收缩,不摆一根用不上的滚动条
    expect(find.text('就一行字。'), findsOneWidget);
    expect(find.byType(CupertinoScrollbar), findsNothing);
  });

  testWidgets('历史板块:还没有记录,进来是空状态', (tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    expect(find.text('暂无解析记录'), findsOneWidget);

    // 右上角两颗按钮还在(原本就给「没有记录可挑」留了置灰的分支)
    expect(find.text('选择'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('历史板块:解析成功的记录会记下来', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));

    // 先在解析页成功解析一条
    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://b23.tv/abcd',
    );
    await tester.pump();
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();

    // 切到历史:刚才那条应该在
    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    expect(find.text('暂无解析记录'), findsNothing);
    expect(find.text('示例视频标题'), findsOneWidget);
    // 副标题三段都在:时间 · 平台 · 类型
    expect(find.textContaining('今天'), findsOneWidget);
    expect(find.textContaining('哔哩哔哩'), findsOneWidget);
    expect(find.textContaining('视频/图集/音频/文案'), findsOneWidget);

    // 封面图建出来了(测试环境加载不了,但 Image 在树上)
    expect(hasImageWith(tester, 'https://example.invalid/c.jpg'), isTrue);
    // 而且底下那层占位一直在 —— 图没下来时不至于是块光秃秃的灰。
    // 这是「封面加载时灰块 → 图片硬切」那条的防线。
    expect(find.byIcon(CupertinoIcons.play_circle_fill), findsWidgets);
  });

  testWidgets('历史板块:选择后删除,重开 App 也不会回来', (tester) async {
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

    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('示例视频标题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('暂无解析记录'), findsOneWidget);

    // 整棵树拆掉重建 = 重开 App。真的落盘删掉了才不会再出现,
    // 只把卡片从界面上拿掉的话这里会漏出来。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('历史').first);
    await tester.pumpAndSettle();

    expect(find.text('暂无解析记录'), findsOneWidget);
  });
}
