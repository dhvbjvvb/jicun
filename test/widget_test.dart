// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus_platform_interface/package_info_data.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/history_store.dart';
import 'package:jicun/main.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/update_service.dart';

/// 造一条历史记录用的解析结果。
ParseResult _sampleResult(String title) => ParseResult(
  title: title,
  desc: '示例文案内容',
  platform: '抖音',
  authorName: '作者',
  videoUrl: 'https://example.invalid/v.mp4',
  coverUrl: 'https://example.invalid/c.jpg',
);

/// 默认应答:视频 + 图集 + 音频 + 文案,四样都齐。字段按 media-parser 的结构给。
final Map<String, dynamic> _stubParseData = <String, dynamic>{
  'title': '示例视频标题',
  'desc': '示例文案内容',
  'platform': '哔哩哔哩',
  'author': {'nickname': '示例作者'},
  'video_url': 'https://example.invalid/v.mp4',
  'cover_url': 'https://example.invalid/c.jpg',
  'audio_url': 'https://example.invalid/a.mp3',
  // 图集:一条字符串元素 + 一条对象元素,覆盖两种上游写法
  'image_list': [
    'https://example.invalid/1.jpeg',
    {'url': 'https://example.invalid/2.webp'},
  ],
};

/// 纯视频 + 音频 + 文案,**没有图集** —— 抖音/快手的普通短视频链接就长这样。
final Map<String, dynamic> _stubVideoOnlyData = <String, dynamic>{
  'title': '示例视频标题',
  'desc': '示例文案内容',
  'platform': '抖音',
  'author': {'nickname': '示例作者'},
  'video_url': 'https://example.invalid/v.mp4',
  'cover_url': 'https://example.invalid/c.jpg',
  'audio_url': 'https://example.invalid/a.mp3',
  'image_list': <dynamic>[],
};

/// 两条视频的合集链接:接口只给 `video_list`,没有单条 `video_url`。
final Map<String, dynamic> _stubMultiVideoData = <String, dynamic>{
  'title': '合集视频',
  'desc': '合集文案',
  'platform': '抖音',
  'video_list': [
    {
      'url': 'https://example.invalid/1.mp4',
      'cover_url': 'https://example.invalid/1.jpg',
    },
    {
      'url': 'https://example.invalid/2.mp4',
      'cover_url': 'https://example.invalid/2.jpg',
    },
  ],
  'image_list': <dynamic>[],
};

/// 页面用例不该真打网络:把 http client 换成固定应答的 mock。
///
/// [data] 不给就用默认那份四样俱全的应答。
/// [sequence] 用来模拟「连续解析多条链接」:按顺序每次返回一份,用完之后
/// 一直返回最后一份。
///
/// 抖音/快手/微信视频号的链接会先打上游那几条路(/parse2/dy 等),这里对
/// **所有**解析地址都给同一份应答 —— 这些用例要验的是页面行为,不是路由
/// (路由的用例在 upstream_routing_test.dart 里)。给同一份还能顺带确认:
/// 换了上游之后页面照样认得出结果。
void useStubParseBackend({
  Map<String, dynamic>? data,
  List<Map<String, dynamic>>? sequence,
}) {
  var index = 0;
  ParseService.clientFactory = () => MockClient((request) async {
    // 预热请求打的是 /ping,和解析不是一回事,不能算进 sequence 的序号里。
    if (request.url.path == '/ping') {
      return http.Response('', 204);
    }
    final Map<String, dynamic> payload;
    if (sequence == null) {
      payload = data ?? _stubParseData;
    } else {
      payload = sequence[index < sequence.length ? index : sequence.length - 1];
      index++;
    }
    final body = jsonEncode(<String, dynamic>{
      'succ': true,
      'retcode': 200,
      'retdesc': '成功',
      'data': payload,
    });
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  addTearDown(() => ParseService.clientFactory = () => http.Client());
}

/// 树里有没有拿 [url] 当图的 Image。
///
/// 测试环境加载不了网络图,但 Image widget 自己带着地址,足够断言"用的是哪张图"。
///
/// 注意要拆开 ResizeImage:带 cacheWidth 的 Image 会把 provider 包一层
/// ResizeImage(NetworkImage(url)),直接判 `is NetworkImage` 会漏。
bool _hasImageWith(WidgetTester tester, String url) => tester
    .widgetList<Image>(find.byType(Image))
    .any((img) => _providerUrl(img.image) == url);

String? _providerUrl(ImageProvider provider) {
  if (provider is NetworkImage) return provider.url;
  if (provider is ResizeImage) return _providerUrl(provider.imageProvider);
  return null;
}

/// 树里有几张图拿的是 [url]。大图预览弹出来时,缩略图那张和窗口里那张各算一张。
int _imageCount(WidgetTester tester, String url) => tester
    .widgetList<Image>(find.byType(Image))
    .where((img) => _providerUrl(img.image) == url)
    .length;

/// 测试默认画布是 800x600(更像平板横屏),而这个 App 是竖屏手机界面:
/// 「主题与外观」二级页顶部有整宽图,再用默认画布量卡片位置会量到屏幕外。
/// 这里统一按真机尺寸(360x800pt)跑。
void usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1260, 2800);
  tester.view.devicePixelRatio = 3.5;
  addTearDown(tester.view.reset);
}

// ── 检查更新:测试用的假版本号与假后端 ──

/// 本机版本。更新判定要拿它比,不 stub 的话 PackageInfo 会抛 MissingPluginException。
class _FakePackageInfo extends PackageInfoPlatform
    with MockPlatformInterfaceMixin {
  _FakePackageInfo(this.version);

  final String version;

  @override
  Future<PackageInfoData> getAll({String? baseUrl}) async => PackageInfoData(
    appName: '即存',
    packageName: 'com.videofix.jicun',
    version: version,
    buildNumber: '1',
    buildSignature: '',
  );
}

void useLocalVersion(String version) {
  PackageInfoPlatform.instance = _FakePackageInfo(version);
  // 检查更新一开头会问一次本机 ABI(见 UpdateService.abiResolver),那走的是平台
  // 通道。测试里没有原生侧,不打这个桩它会一直等在通道上,于是整条检查更新
  // 都不往下走 —— 卡片和回音一个都不弹。
  UpdateService.abiResolver = () async => null;
  addTearDown(() => UpdateService.abiResolver = deviceAbi);
}

// ── 预览播放器:测试用的假原生实现 ──

/// 假的 video_player 原生实现,只够让预览播放器「真的播起来」。
///
/// 没有它,`VideoPlayerController.initialize()` 在 widget 测试里会抛,预览区直接
/// 退化成一块占位 —— 而「点下载只是暂停、下完接着播」这条路就完全验不到。
///
/// 只实现验证需要的那几件事:创建/销毁、初始化事件、播放/暂停、取位置。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  final Set<int> _playing = <int>{};
  final Set<int> _disposed = <int>{};

  /// 现在有播放器在播吗。
  bool get playing => _playing.isNotEmpty;

  /// 播放器有没有被销毁过。点下载**不该**走到这里(那正是这次要修的 bug)。
  bool get disposed => _disposed.isNotEmpty;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _nextId++;
    // 单订阅流 + onListen 里发初始化事件:广播流会在监听挂上之前就把事件丢掉,
    // 而控制器是靠这个事件宣告"初始化完成"的。
    _events[id] = StreamController<VideoEvent>(
      onListen: () => _events[id]!.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: const Size(1280, 720),
        ),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    _disposed.add(playerId);
    _playing.remove(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async => _playing.add(playerId);

  @override
  Future<void> pause(int playerId) async => _playing.remove(playerId);

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

/// 装上假播放器;用完换回原来的实现(别的用例靠"播放器加载不了"验占位)。
_FakeVideoPlayerPlatform _useFakeVideoPlayer() {
  final fake = _FakeVideoPlayerPlatform();
  final real = VideoPlayerPlatform.instance;
  VideoPlayerPlatform.instance = fake;
  addTearDown(() => VideoPlayerPlatform.instance = real);
  return fake;
}

/// 造一份 release JSON。
Map<String, dynamic> _releaseJson({
  String tag = 'v1.1.0',
  String body = '修了几个 bug',
  bool withApk = true,
}) => <String, dynamic>{
  'tag_name': tag,
  'body': body,
  'published_at': '2026-09-19T10:00:00Z',
  'assets': <dynamic>[
    <String, String>{'name': 'source code (zip)'},
    if (withApk)
      <String, String>{'name': 'jicun-${tag.replaceAll('v', '')}.apk'},
  ],
};

/// 只认"检查更新"那几个候选地址的假后端;别的请求一律 404。
///
/// 没有 release 时回的是 **GitHub 那个 JSON 404**(`message: Not Found`),不是
/// 空体 404 —— 后者在真机上代表"这台机器没配这个接口",[UpdateService] 会当成
/// 失败而不是"没有新版"(见 _fetchOne 的注释)。用错形状会把用例验成假的。
///
/// [tagOf] 返回当前该报哪个版本 —— 用例想在同一个 App 实例里验"仓库发了更高的版本"
/// 时,改这个函数的返回值就行,不必重新 pumpWidget(同类型 widget 重 pump 会复用
/// 同一个 State,新的 UpdateService 传不进去)。
UpdateService useStubReleases({
  Map<String, dynamic>? release,
  String Function()? tagOf,
}) {
  http.Response githubNotFound() => http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'message': 'Not Found',
        'documentation_url': 'https://docs.github.com/rest/releases/releases#get-the-latest-release',
        'status': '404',
      }),
    ),
    404,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  final service = UpdateService(
    client: MockClient((request) async {
      if (!kReleasesApis.contains(request.url.toString())) {
        return http.Response('not found', 404);
      }
      final dynamic body = tagOf != null ? _releaseJson(tag: tagOf()) : release;
      if (body == null) return githubNotFound();
      return http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }),
  );
  addTearDown(service.dispose);
  return service;
}

/// 拦截安装包下载 + 拉起安装器那条平台通道。
///
/// 返回记录下来的调用,断言"下的哪个包""有没有真去拉起安装器"。[canInstallApk]
/// 为假用来验「首次进入要跳安装权限页」和「点更新时的授权确认」。
List<MethodCall> useStubInstallChannel({
  String? tempDir,
  bool canInstallApk = true,
  bool Function()? canInstallApkValue,
}) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('jicun/downloader'), (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'canInstallApk':
            return canInstallApkValue?.call() ?? canInstallApk;
          case 'openInstallPermission':
            return true;
          case 'installApk':
            return 'content://test/$call';
          default:
            return null;
        }
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('jicun/downloader'),
          null,
        ),
  );
  if (tempDir != null) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getTemporaryDirectory' ? tempDir : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );
  }
  return calls;
}

/// 拦截通知插件的通道:首次进入 APP 要问「通知现在允许吗」、要一次权限。
///
/// 还得把 Android 实现挂上去:测试环境没有插件注册表,不挂的话
/// `resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()`
/// 返回 null —— 那被当成"问不出来",通知那一项就整段跳过。
///
/// 返回收到的调用流水,便于断言"到底发没发通知"。
List<MethodCall> useStubNotificationChannel({
  bool enabled = false,
  bool granted = true,
}) {
  // 挂上去之后就不再摘:摘了之后 instance 是"没初始化"而不是 null,再读就抛
  // LateInitializationError;而挂着它不影响别的用例(通道没拦时按"问不出来"算)。
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  final calls = <MethodCall>[];
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'areNotificationsEnabled':
            return enabled;
          case 'requestNotificationsPermission':
            return granted;
          default:
            return null;
        }
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  return calls;
}

/// 造一条剪贴板内容,让「粘贴」按钮在测试里读到指定文本。
///
/// 拦截整个 platform 通道:除了 Clipboard.getData 之外一律回 null ——
/// 测试里没有别的系统调用需要真应答。
void useClipboardText(String? text) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return text == null ? null : <String, dynamic>{'text': text};
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// 拦剪贴板**写入**,把落进去的文字收在 [captured] 里。
///
/// 「反馈渠道」那两行点一下就该复制,而复制成功没有任何界面变化 —— 不拦写入
/// 就没法验。
List<String> useClipboardWrite() {
  final captured = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      captured.add((call.arguments as Map<Object?, Object?>)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return captured;
}

/// 拦平台侧那条读剪贴板的路(`getClipboardText`)。
///
/// 真机上这条路走系统的 `coerceToText`,能读出来的比 Flutter 自带那条多 ——
/// 传 null 就是"两条都读不到"。
void useStubClipboardChannel(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('jicun/downloader'),
        (call) async => call.method == 'getClipboardText' ? text : null,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('jicun/downloader'),
          null,
        ),
  );
}

/// 粘贴链接卡右上角那颗胶囊按钮现在能不能点。
///
/// 这两颗走的是 [PlainTap] → InkWell(和历史页那颗同款),所以看的是 InkWell.onTap。
bool _actionEnabled(WidgetTester tester, String name) =>
    tester
        .widget<InkWell>(
          find.descendant(
            of: find.byKey(ValueKey('pasteLink.$name')),
            matching: find.byType(InkWell),
          ),
        )
        .onTap !=
    null;

/// 输入框里现在是什么。
String _linkText(WidgetTester tester) => tester
    .widget<EditableText>(find.byType(EditableText).first)
    .controller
    .text;

/// 记录打了哪些解析请求(预热用的 /ping 不算)。
List<String> useCountingParseBackend() {
  final hits = <String>[];
  ParseService.clientFactory = () => MockClient((request) async {
    if (request.url.path == '/ping') return http.Response('', 204);
    hits.add(request.url.toString());
    final body = jsonEncode(<String, dynamic>{
      'succ': true,
      'retcode': 200,
      'retdesc': '成功',
      'data': _stubParseData,
    });
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  addTearDown(() => ParseService.clientFactory = () => http.Client());
  return hits;
}

/// 从 [start] 往下拖 [dragBy](把列表拽到顶部边界外面),返回越界走出多远,
/// 松手后等回弹结束。起点要在列表内容上,不能压在开关/单选框上。
Future<double> dragPastTop(
  WidgetTester tester,
  ScrollPosition position,
  double dragBy,
  Offset start,
) async {
  const steps = 20;
  final gesture = await tester.startGesture(start);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, dragBy / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  final overscroll = position.minScrollExtent - position.pixels;
  await gesture.up();
  await tester.pumpAndSettle();
  return overscroll;
}

void main() {
  // 收流那一步生产上是原生的(走平台通道),测试里到不了替身 —— 统一改走 Dart 实现,
  // 这样 fetchImpl 那些假下载器才生效。见 Downloader.useDartEngine。
  Downloader.useDartEngine = true;

  // 启动流程会顺手刷新一次「域名 + 优选 IP」。这里换成空配置,免得用例真去连
  // videofix.top —— 用例要验的是页面行为,不是这条后台链路。
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
    expect(find.text('存储保存位置'), findsOneWidget);
    expect(find.text('Movies/Jicun/Video'), findsOneWidget);
    expect(find.text('Pictures/Jicun/Picture'), findsOneWidget);
    expect(find.text('Music/Jicun/Music'), findsOneWidget);
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
    useStubParseBackend(data: _stubVideoOnlyData);
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
    useStubParseBackend(data: _stubMultiVideoData);
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
    expect(_hasImageWith(tester, 'https://example.invalid/1.jpg'), isTrue);
    expect(_hasImageWith(tester, 'https://example.invalid/2.jpg'), isTrue);
    // 播放器整个取消掉了(缩略图角上那两个小播放标识不算播放组件)
    expect(find.text('00:00'), findsNothing);
    expect(find.byIcon(CupertinoIcons.play_fill), findsNWidgets(2));

    // 两条以上:左边多一颗「全选媒体」,下载按钮要先选中才能按
    expect(find.text('全选媒体'), findsOneWidget);
    expect(downloadButton(tester, within: '媒体预览').onPressed, isNull);
  });

  testWidgets('解析页:全选媒体点一次全选中,再点一次全部取消', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: _stubMultiVideoData);
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
    expect(_hasImageWith(tester, 'https://example.invalid/live1.jpg'), isTrue);
    expect(_hasImageWith(tester, 'https://example.invalid/live2.jpg'), isTrue);
    expect(_hasImageWith(tester, 'https://example.invalid/plain.jpg'), isTrue);
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
      (w) => w is Image && _providerUrl(w.image) == url,
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
    expect(_imageCount(tester, 'https://example.invalid/1.jpg'), 2);

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
    expect(_imageCount(tester, 'https://example.invalid/1.jpg'), 1);
  });

  /// 把下载换成假的:每 100ms 走 10%,用户可以中途取消。
  ///
  /// 真实现要发网络请求,用例里既慢又碰运气,所以只测卡片自己的行为。
  void useStubDownloader() {
    // 下载第一步要问系统要临时目录。测试里没有真的 path_provider 插件,
    // 不接一下这一步就抛 MissingPluginException,进度一直停在 0%。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getTemporaryDirectory'
              ? Directory.systemTemp.createTempSync('jicun_test').path
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );

    final realFetch = Downloader.fetchImpl;
    final realPublish = Downloader.publishImpl;
    Downloader.fetchImpl =
        (item, temp, onFraction, cancelled, onSize, client) async {
          onSize?.call(100);
          for (var i = 1; i <= 10; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            if (cancelled?.call() ?? false) throw const DownloadCancelled();
            onFraction(i / 10);
          }
          return File('${temp.path}/${item.fileName}');
        };
    Downloader.publishImpl = (item, file) async => null;
    addTearDown(() {
      Downloader.fetchImpl = realFetch;
      Downloader.publishImpl = realPublish;
    });
  }

  testWidgets('解析页:点下载媒体弹出进度卡片,不是原来的提示框', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: _stubVideoOnlyData);
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
    useStubParseBackend(data: _stubVideoOnlyData);
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

  testWidgets('解析页:下载跑完,取消按钮变成完成并关掉卡片', (tester) async {
    usePhoneSurface(tester);
    useStubParseBackend(data: _stubVideoOnlyData);
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
    final video = _useFakeVideoPlayer();
    useStubParseBackend(data: _stubVideoOnlyData);
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
    expect(_actionEnabled(tester, 'clear'), isFalse);
    expect(_actionEnabled(tester, 'paste'), isTrue);

    // 有内容(哪怕根本不是链接):清空可点
    await tester.enterText(find.byType(CupertinoTextField), '随手写点什么');
    await tester.pumpAndSettle();
    expect(_actionEnabled(tester, 'clear'), isTrue);

    // 粘贴:剪贴板内容直接顶掉原来那段文字
    await tester.tap(find.byKey(const ValueKey('pasteLink.paste')));
    await tester.pumpAndSettle();
    expect(_linkText(tester), 'https://v.douyin.com/abcd/');

    // 清空:输入框变空,清空自己又灰回去
    await tester.tap(find.byKey(const ValueKey('pasteLink.clear')));
    await tester.pumpAndSettle();
    expect(_linkText(tester), isEmpty);
    expect(_actionEnabled(tester, 'clear'), isFalse);
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

    expect(_linkText(tester), 'https://v.douyin.com/abcd/');
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
    useStubParseBackend(data: _stubVideoOnlyData);
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

  testWidgets('解析页:接口没给 audio_url 时,音频卡退回「视频原声」', (tester) async {
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

    // 没有独立音频文件,只能放视频自带的那条音轨
    expect(find.text('视频原声'), findsOneWidget);
    expect(find.text('音频预览与下载'), findsNothing);
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
    expect(_hasImageWith(tester, 'https://example.invalid/c.jpg'), isTrue);
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
          jsonEncode(<String, dynamic>{'succ': true, 'data': _stubParseData}),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() => ParseService.clientFactory = () => http.Client());

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
    expect(
      _hasImageWith(tester, 'https://example.invalid/cover-A.jpg'),
      isTrue,
    );

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
    expect(
      _hasImageWith(tester, 'https://example.invalid/cover-B.jpg'),
      isTrue,
    );
    expect(
      _hasImageWith(tester, 'https://example.invalid/cover-A.jpg'),
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
    await store.add(_sampleResult('短标题'), 'https://v.douyin.com/1/');
    await store.add(_sampleResult('中等标题'), 'https://v.douyin.com/2/');
    await store.add(
      _sampleResult('特别特别长的一个标题,长到必须换行才放得下这句话'),
      'https://v.douyin.com/3/',
    );

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
    expect(_hasImageWith(tester, 'https://example.invalid/c.jpg'), isTrue);
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
      '后续维护:原则上,来讲是永久免费(看后续精力)',
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

  testWidgets('彩蛋提示:设置里进得去,提示卡摊开摆着,底部两个角色都加载得到', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 300));

    // 一级列表里那两句副标题改过文案,顺手钉住
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    expect(find.text('修改主题、显示效果'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('彩蛋提示'), 200);
    expect(find.text('开源地址、彩蛋出席'), findsOneWidget);

    await tester.tap(find.text('彩蛋提示'));
    await tester.pumpAndSettle();

    // 第一张卡:标题一行,内容一行,默认就是摊开的,没有展开/收起箭头
    expect(find.text('提示'), findsOneWidget);
    expect(find.text('也许在某个设置中的2级界面,快速连续3次点击人物,它会发出声音🤯'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNothing);

    // 底部两个角色是实打实的资源,路径写错的话 Image 只会画个空盒子,看不出来
    for (final asset in const [
      'assets/easter-egg-hint/left.png',
      'assets/easter-egg-hint/right.png',
    ]) {
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: '$asset 应该在 pubspec 里');
    }
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
        HttpException('SocketException: Connection reset'),
      ),
      '网络中断，请重试',
    );
    expect(
      downloadErrorMessage(
        HttpException('SocketTimeoutException: timeout'),
      ),
      '网络中断，请重试',
    );
    expect(
      downloadErrorMessage(HttpException('HTTP 403')),
      '下载地址已失效，请重新解析',
      reason: '4xx 是直链失效,重试无用,得重新解析',
    );
    expect(
      downloadErrorMessage(
        HttpException('文件不完整:1234/5678 字节'),
      ),
      '文件不完整，请重试',
    );
    expect(
      downloadErrorMessage(const DownloadCancelled()),
      '已取消',
    );
    expect(
      downloadErrorMessage(StateError('没见过的错')),
      contains('没见过的错'),
      reason: '没归过类的错因原样透出,不要藏',
    );
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

  // ────────────────────────── 检查更新 ──────────────────────────

  group('检查更新', () {
    /// 打开 App。更新服务由用例自己给(见 useStubReleases)。
    ///
    /// [autoCheck] 为假时把「启动自动检查」关掉:widget 测试里绝不能真去问 GitHub,
    /// 假时钟下那个请求永远回不来,`pumpAndSettle` 会一直等。要验更新卡片就走
    /// 「设置 → 检查更新」,或者把 autoCheck 打开(那时更新服务是假的)。
    Future<void> openApp(
      WidgetTester tester, {
      required UpdateService updates,
      String localVersion = '1.0.0',
      Map<String, Object> prefs = const <String, Object>{},
      bool autoCheck = false,
    }) async {
      usePhoneSurface(tester);
      useLocalVersion(localVersion);
      useStubParseBackend();
      SharedPreferences.setMockInitialValues(prefs);
      await tester.pumpWidget(
        LiquidGlassDemo(updates: updates, autoCheckUpdate: autoCheck),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// 切到设置板块。
    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
    }

    testWidgets('手动检查:有新版就弹「版本更新」卡片', (tester) async {
      await openApp(tester, updates: useStubReleases(release: _releaseJson()));
      await openSettings(tester);

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.text('版本更新'), findsOneWidget);
      // 版本变化写在副标题里,用户一眼能看出从哪升到哪
      expect(find.text('1.0.0 → 1.1.0'), findsOneWidget);
      // 需求指定:左边更新、右边忽略
      final update = tester.getCenter(find.text('更新'));
      final ignore = tester.getCenter(find.text('忽略'));
      expect(update.dx, lessThan(ignore.dx));
      // 说明内容按 release 的 body 显示
      expect(find.text('修了几个 bug'), findsOneWidget);
    });

    testWidgets('每次进 APP 自动检查:有新版本不用点就弹', (tester) async {
      await openApp(
        tester,
        updates: useStubReleases(release: _releaseJson()),
        autoCheck: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('版本更新'), findsOneWidget);
    });

    testWidgets('没有新版:自动检查什么都不弹,手动检查给一句回音', (tester) async {
      // 本机就是最新的:release 比本机旧
      await openApp(
        tester,
        updates: useStubReleases(release: _releaseJson(tag: 'v1.0.0')),
        autoCheck: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('版本更新'), findsNothing);

      await openSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已是最新版本'), findsOneWidget);
    });

    testWidgets('仓库里没有 release:手动检查说"还没有发布任何版本"', (tester) async {
      await openApp(tester, updates: useStubReleases());
      await openSettings(tester);

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有发布任何版本'), findsOneWidget);
      expect(find.text('版本更新'), findsNothing);
    });

    testWidgets('点忽略:卡片关掉,这个版本记进偏好', (tester) async {
      await openApp(tester, updates: useStubReleases(release: _releaseJson()));
      await openSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();
      // 落盘是异步的(见 _rememberIgnored),等它写完
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(find.text('版本更新'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update.ignoredVersion'), '1.1.0');
    });

    testWidgets('忽略过的版本:自动检查不再弹,手动检查照样弹更新卡', (tester) async {
      await openApp(
        tester,
        updates: useStubReleases(release: _releaseJson()),
        prefs: const <String, Object>{'update.ignoredVersion': '1.1.0'},
        autoCheck: true,
      );
      await tester.pumpAndSettle();

      // 忽略过 1.1.0:启动自动检查不弹
      expect(find.text('版本更新'), findsNothing);

      // 手动检查是用户自己点的:忽略过也得弹出来,不能被上次的「忽略」堵住
      await openSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('版本更新'), findsOneWidget);
      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();

      // 再点一次检查:还是弹
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('版本更新'), findsOneWidget);
    });

    testWidgets('忽略过的版本,仓库又发了更高的:自动检查重新弹', (tester) async {
      await openApp(
        tester,
        updates: useStubReleases(release: _releaseJson(tag: 'v1.2.0')),
        prefs: const <String, Object>{'update.ignoredVersion': '1.1.0'},
        autoCheck: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('1.0.0 → 1.2.0'), findsOneWidget);
    });

    testWidgets('点更新:先弹下载进度窗口,再把包交给系统安装器', (tester) async {
      final apkBytes = List<int>.generate(4096, (i) => i % 251);
      final temp = Directory.systemTemp.createTempSync('jicun_update_ui');
      addTearDown(() => temp.deleteSync(recursive: true));
      // 闸门:先让进度窗口画出来,再放数据过去 —— 不然下载会在窗口画出第一帧
      // 之前就跑完,断言"窗口弹出"就变成碰运气。
      final gate = Completer<void>();

      // 下载走 mock:反代那条地址给一段真流
      final service = UpdateService(
        client: MockClient.streaming((request, bodyStream) async {
          final url = request.url.toString();
          // release 接口:回 JSON
          if (url == kMirrorReleasesApi || url == kReleasesApi) {
            final body = utf8.encode(jsonEncode(_releaseJson()));
            return http.StreamedResponse(
              Stream<List<int>>.value(body),
              200,
              contentLength: body.length,
            );
          }
          // 安装包:回一段真字节流
          if (url == kMirrorAssetUrl('v1.1.0', 'jicun-1.1.0.apk') ||
              url == kReleaseAssetUrl('v1.1.0', 'jicun-1.1.0.apk')) {
            return http.StreamedResponse(
              Stream<List<int>>.fromFuture(gate.future.then((_) => apkBytes)),
              200,
              contentLength: apkBytes.length,
            );
          }
          return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
        }),
      );
      addTearDown(service.dispose);

      final calls = useStubInstallChannel(tempDir: temp.path);
      await openApp(tester, updates: service);
      await openSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('更新'));
      await tester.pump(); // 关掉更新卡
      // 弹层要跨一次 getTemporaryDirectory 的异步才画出来。这段时间里下载也在跑,
      // 但数据被闸门挡着,所以窗口一定停在"下载中" —— 这是这个用例能稳定断言进度
      // 窗口的原因。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('取消更新'), findsOneWidget, reason: '点更新要出下载进度窗口');
      expect(find.textContaining('%'), findsWidgets, reason: '窗口里要有百分比');

      // 放行下载,再等它把包交给安装器
      gate.complete();
      await tester.runAsync(() async {
        for (var i = 0; i < 200; i++) {
          if (calls.any((c) => c.method == 'installApk')) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();

      // 进度窗口自己收掉了
      expect(find.text('取消更新'), findsNothing);
      // 拉起安装器,带的正是下好的那个包
      final install = calls.firstWhere((c) => c.method == 'installApk');
      expect(install.arguments['path'], endsWith('jicun-1.1.0.apk'));
      expect(
        File('${temp.path}/jicun-1.1.0.apk').lengthSync(),
        apkBytes.length,
      );
    });

    testWidgets('点更新但没装成:进度窗口里说清原因,不静默失败', (tester) async {
      final temp = Directory.systemTemp.createTempSync('jicun_update_fail');
      addTearDown(() => temp.deleteSync(recursive: true));

      final service = useStubReleases(release: _releaseJson());
      useStubInstallChannel(tempDir: temp.path);
      await openApp(tester, updates: service);
      await openSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('更新'));
      await tester.pump();
      // 假后端对下载地址一律 404:让下载真的跑完(失败),窗口才会走到失败态
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      // 反代那条地址在假后端里是 404,直连同理 —— 下载必然失败,窗口要留下原因
      expect(find.text('下载没完成'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
    });
  });

  // ────────────────────────── 首次进入的权限 ──────────────────────────

  group('首次进入的权限', () {
    /// 打开 App。更新检查一律关掉:这里验的是权限,不能真去打 GitHub。
    Future<void> openApp(
      WidgetTester tester, {
      Map<String, Object> prefs = const <String, Object>{},
    }) async {
      usePhoneSurface(tester);
      useLocalVersion('1.0.0');
      useStubParseBackend();
      SharedPreferences.setMockInitialValues(prefs);
      await tester.pumpWidget(
        LiquidGlassDemo(updates: useStubReleases(), autoCheckUpdate: false),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('首次进入只问通知权限,不跳安装权限页', (tester) async {
      final calls = useStubInstallChannel(canInstallApk: false);
      useStubNotificationChannel();
      await openApp(tester);

      // 「安装未知应用」挪到更新流程里了:刚装好 APP 就被甩到系统设置页,
      // 用户只会觉得莫名其妙(见 _askPermissionsOnFirstLaunch)
      expect(
        calls.map((call) => call.method),
        isNot(contains('openInstallPermission')),
      );
      expect(find.text('开启必要权限'), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
    });

    testWidgets('通知已经开着就不再问', (tester) async {
      final calls = useStubInstallChannel();
      useStubNotificationChannel(enabled: true);
      await openApp(tester);

      expect(
        calls.map((call) => call.method),
        isNot(contains('openInstallPermission')),
      );
    });

    testWidgets('问过一次就不再问', (tester) async {
      final calls = useStubInstallChannel(canInstallApk: false);
      useStubNotificationChannel();
      await openApp(tester, prefs: const <String, Object>{'perm.asked': true});

      expect(
        calls.map((call) => call.method),
        isNot(contains('openInstallPermission')),
      );
    });

    testWidgets('问过之后把"问过"记进偏好', (tester) async {
      useStubInstallChannel(canInstallApk: false);
      useStubNotificationChannel();
      await openApp(tester);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('perm.asked'), isTrue);
    });

    testWidgets('平台侧问不出来(非 Android / 测试环境)时不打扰', (tester) async {
      useStubInstallChannel();
      await openApp(tester);

      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.text('开启必要权限'), findsNothing);
    });
  });

  // ────────────────────────── 弹层样式 ──────────────────────────

  group('弹层样式', () {
    testWidgets('检查更新的回音不是 iOS 灰底弹窗,和更新卡同一块玻璃卡', (tester) async {
      usePhoneSurface(tester);
      useLocalVersion('1.0.0');
      useStubParseBackend();
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await tester.pumpWidget(
        LiquidGlassDemo(
          // 仓库报的版本和本机一样:手动检查会给一句「已是最新版本」
          updates: useStubReleases(release: _releaseJson(tag: 'v1.0.0')),
          autoCheckUpdate: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已是最新版本'), findsOneWidget);
      // CupertinoAlertDialog 是 iOS 那套灰底 + 细分割线,搁在满屏毛玻璃里就是另一个 APP
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      // 和更新卡一样:糊一层背景 + 铺一份页面底色
      expect(find.byType(BackdropFilter), findsWidgets);
    });
  });

  // ─────────────────── 安装未知应用的授权(挪到更新流程里) ───────────────────

  group('安装权限', () {
    /// 开 App、进设置、检查更新、点「更新」。
    ///
    /// 安装包直接用缓存里那个:这样不用真下载,点「更新」会一路走到"交给安装器"
    /// 那一步 —— 也正是授权该出现的位置。
    Future<List<MethodCall>> startUpdate(
      WidgetTester tester, {
      required bool Function() canInstallApk,
    }) async {
      final temp = Directory.systemTemp.createTempSync('jicun_install_perm');
      addTearDown(() => temp.deleteSync(recursive: true));
      // 上一趟已经下好的包(见 ApkCache):跳过下载,直接进安装那一步
      File('${temp.path}/jicun-1.1.0.apk').writeAsBytesSync(<int>[1, 2, 3]);
      final calls = useStubInstallChannel(
        tempDir: temp.path,
        canInstallApkValue: canInstallApk,
      );

      usePhoneSurface(tester);
      useLocalVersion('1.0.0');
      useStubParseBackend();
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await tester.pumpWidget(
        LiquidGlassDemo(
          updates: useStubReleases(release: _releaseJson()),
          autoCheckUpdate: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('没开权限:包下完了才跳系统授权页,不弹 APP 自己的说明卡', (tester) async {
      final calls = await startUpdate(tester, canInstallApk: () => false);

      expect(
        calls.map((call) => call.method),
        contains('openInstallPermission'),
      );
      // 权限没开就别去拉安装器,不然只会得到一句"安装失败"
      expect(calls.map((call) => call.method), isNot(contains('installApk')));
      // 用户刚看完进度条走完,为什么跳过去是一目了然的 —— 不再多一张文字说明卡
      expect(find.text('需要安装权限'), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
    });

    testWidgets('去设置页开完权限回来:自动接着装,不用再点一次更新', (tester) async {
      var allowed = false;
      final calls = await startUpdate(tester, canInstallApk: () => allowed);
      expect(calls.map((call) => call.method), isNot(contains('installApk')));

      // 用户在系统设置页开了权限,回到 APP
      allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), contains('installApk'));
      final install = calls.firstWhere((call) => call.method == 'installApk');
      expect(install.arguments['path'], endsWith('jicun-1.1.0.apk'));
    });

    testWidgets('权限已经开着:不打扰,直接交给安装器', (tester) async {
      final calls = await startUpdate(tester, canInstallApk: () => true);

      expect(
        calls.map((call) => call.method),
        isNot(contains('openInstallPermission')),
      );
      expect(calls.map((call) => call.method), contains('installApk'));
    });

    testWidgets('回来还是没开权限:明说一句,别让人以为更新坏了', (tester) async {
      final calls = await startUpdate(tester, canInstallApk: () => false);
      expect(
        calls.map((call) => call.method),
        contains('openInstallPermission'),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('还差一步'), findsOneWidget);
    });
  });

  group('版本更新说明预览', () {
    /// 单独把卡片挂起来,pump 到弹层出来。
    Future<void> showCard(WidgetTester tester, String notes) async {
      usePhoneSurface(tester);
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
      // 12 行 × 13px × 1.55
      const expected = 12 * 13 * 1.55;
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
  });
}

