// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus_platform_interface/package_info_data.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/update_service.dart';

/// 造一条历史记录用的解析结果。
ParseResult sampleResult(String title) => ParseResult(
  title: title,
  desc: '示例文案内容',
  platform: '抖音',
  authorName: '作者',
  videoUrl: 'https://example.invalid/v.mp4',
  coverUrl: 'https://example.invalid/c.jpg',
);

/// 默认应答:视频 + 图集 + 音频 + 文案,四样都齐。字段按 media-parser 的结构给。
final Map<String, dynamic> stubParseData = <String, dynamic>{
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
final Map<String, dynamic> stubVideoOnlyData = <String, dynamic>{
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
final Map<String, dynamic> stubMultiVideoData = <String, dynamic>{
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
      payload = data ?? stubParseData;
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
  addTearDown(() => ParseService.clientFactory = http.Client.new);
}

/// 树里有没有拿 [url] 当图的 Image。
///
/// 测试环境加载不了网络图,但 Image widget 自己带着地址,足够断言"用的是哪张图"。
///
/// 注意要拆开 ResizeImage:带 cacheWidth 的 Image 会把 provider 包一层
/// ResizeImage(NetworkImage(url)),直接判 `is NetworkImage` 会漏。
bool hasImageWith(WidgetTester tester, String url) => tester
    .widgetList<Image>(find.byType(Image))
    .any((img) => providerUrl(img.image) == url);

String? providerUrl(ImageProvider provider) {
  if (provider is NetworkImage) return provider.url;
  if (provider is ResizeImage) return providerUrl(provider.imageProvider);
  return null;
}

/// 树里有几张图拿的是 [url]。大图预览弹出来时,缩略图那张和窗口里那张各算一张。
int imageCount(WidgetTester tester, String url) => tester
    .widgetList<Image>(find.byType(Image))
    .where((img) => providerUrl(img.image) == url)
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
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  final Set<int> _playing = <int>{};
  final Set<int> _disposed = <int>{};

  /// 让**下一次** create 卡在这个 future 上。
  ///
  /// 用例用它制造"上一条还在加载时换了链接":create 卡住 = 那个播放器还没初始化完。
  /// 以错误收场(gate.completeError)就是**这一次加载失败**,而它属于那个已经被
  /// `VideoStage.didUpdateWidget` 换掉的播放器 —— 正是要验的那条路。
  Completer<void>? holdNextCreate;

  /// 让**下一次** seek 卡在这个 future 上(制造"上一次还没回来")。
  Completer<void>? holdNextSeek;

  /// 收到过的 seek 目标。
  ///
  /// 假播放器不会真的跳转,画面也不会动 —— 「拖画面调进度」这条路上唯一能拿来
  /// 断言的,就是这条指令有没有送到播放器、送到的是多少。
  final List<Duration> seeks = <Duration>[];

  /// 现在有播放器在播吗。
  bool get playing => _playing.isNotEmpty;

  /// 播放器有没有被销毁过。点下载**不该**走到这里(那正是这次要修的 bug)。
  bool get disposed => _disposed.isNotEmpty;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async {
    // id 先占住:这一次就算失败(闸门以错误收场),后面的播放器也不会复用它的号。
    final id = _nextId++;
    final gate = holdNextCreate;
    holdNextCreate = null;
    if (gate != null) await gate.future;
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
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add(position);
    final gate = holdNextSeek;
    holdNextSeek = null;
    if (gate != null) await gate.future;
  }

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
///
/// 返回 [FakeVideoPlayerPlatform] 而不是基类:用例要读它身上的 `playing` /
/// `disposed` 断言播放器有没有被真的停掉,所以这个类必须是公开的。
FakeVideoPlayerPlatform useFakeVideoPlayer() {
  final fake = FakeVideoPlayerPlatform();
  final real = VideoPlayerPlatform.instance;
  VideoPlayerPlatform.instance = fake;
  addTearDown(() => VideoPlayerPlatform.instance = real);
  return fake;
}

/// 造一份 release JSON。
Map<String, dynamic> releaseJson({
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
      final dynamic body = tagOf != null ? releaseJson(tag: tagOf()) : release;
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
bool actionEnabled(WidgetTester tester, String name) =>
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
String linkText(WidgetTester tester) => tester
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
      'data': stubParseData,
    });
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  addTearDown(() => ParseService.clientFactory = http.Client.new);
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

/// 把下载换成假的:每 100ms 走 10%,用户可以中途取消。
///
/// 真实现要发网络请求,用例里既慢又碰运气,所以只测卡片自己的行为。
///
/// 返回的这一份下载器要喂给 [LiquidGlassDemo] 的 `downloader` 参数 —— 页面是从
/// `ShellController.downloader` 拿下载器的,已经没有一个能全局改的静态替身字段。
/// [fetch] 想自己拿捏字节流就传一份(开头就砸、记并发峰值之类)。
Downloader useStubDownloader({DownloadFetcher? fetch}) {
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

  return Downloader(
    useDartEngine: true,
    deps: DownloadDeps(
      fetch: fetch ?? _stubFetch,
      publish: (item, file) async => null,
    ),
  );
}

/// [useStubDownloader] 默认那份假收流:每 100ms 走 10%。
Future<File> _stubFetch(DownloadItem item, FetchContext ctx) async {
  ctx.onSize?.call(100);
  for (var i = 1; i <= 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (ctx.cancelled?.call() ?? false) throw const DownloadCancelled();
    ctx.onFraction(i / 10);
  }
  return File('${ctx.temp.path}/${item.fileName}');
}
