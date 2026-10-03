// 权限、弹层与安装 —— 从原 test/widget_test.dart 按主题切出来的分片。
//
// 切分理由:整个 3495 行跑在一个测试 isolate 里,Windows 上 flutter_tester 会以
// 0xc0000005(访问违例,偏移 0x35aaf0)静默崩掉,一次带走几十条用例(见 README
// 「测试」一节)。分片之后每个文件一个 isolate,单个分片崩不会波及其它。
// 共享的假后端与 helper 在 test/widget_support.dart。

import 'dart:io';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,桌面端判据那两个名字不在里面。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jicun/main.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/audio_stage.dart';

import 'widget_support.dart';

void main() {
  // 音频预览的本地缓存兜底要关:假时钟里真实网络 I/O 不会推进,会把用例挂住。
  AudioStage.localCacheFallback = false;

  // 启动流程会顺手刷新一次「域名 + 优选 IP」。这里换成空配置,免得用例真去连
  // 接口域名 —— 用例要验的是页面行为,不是这条后台链路。
  PreferredIpUpdater.overrideClient(
    MockClient((_) async => http.Response('{"ips":[]}', 200)),
  );

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
      // 用户只会觉得莫名其妙(见 PermissionsGate.askOnFirstLaunch)
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
          updates: useStubReleases(release: releaseJson(tag: 'v1.0.0')),
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
          updates: useStubReleases(release: releaseJson()),
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
}
