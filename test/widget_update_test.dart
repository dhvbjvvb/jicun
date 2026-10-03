// 检查更新 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/audio_stage.dart';
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
      await openApp(tester, updates: useStubReleases(release: releaseJson()));
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
        updates: useStubReleases(release: releaseJson()),
        autoCheck: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('版本更新'), findsOneWidget);
    });

    testWidgets('没有新版:自动检查什么都不弹,手动检查给一句回音', (tester) async {
      // 本机就是最新的:release 比本机旧
      await openApp(
        tester,
        updates: useStubReleases(release: releaseJson(tag: 'v1.0.0')),
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
      await openApp(tester, updates: useStubReleases(release: releaseJson()));
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
        updates: useStubReleases(release: releaseJson()),
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
        updates: useStubReleases(release: releaseJson(tag: 'v1.2.0')),
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
            final body = utf8.encode(jsonEncode(releaseJson()));
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

      final service = useStubReleases(release: releaseJson());
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
}
