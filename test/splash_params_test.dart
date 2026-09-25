import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 启动图的**参数锁**。
///
/// ## 这个文件红了怎么读
///
/// **它不是功能测试。** 它红了,只有一个意思:**启动图(或它的参数)被改了** ——
/// 不代表代码坏了,也不代表这一次改动真的有问题。两种情况:
///
/// - **改是故意的**(比如换了一版启动图、调了启动底色):把本文件里**对应的那条
///   期望值一起改掉**(就在被点名的那一行上面),并在提交说明里写清为什么;
/// - **改不是故意的**("顺手"带走的):把那次改动退回去,**不要**改这里。
///
/// 之所以锁起来:以前为了让浅色底更贴首帧,把 `launch_background_color` 从
/// `#CDDCDC` 改成 `#D3DEDE`;为了做淡出,又在 Flutter 侧叠了一层启动图。对用户来说
/// 这些都不是"图被换了",而是**启动图又变样了** —— 症状一模一样。锁住参数之后,
/// 任何一次改动都会在跑测试时就停下来。
///
/// ## 当前这一版启动画面的全部参数
///
/// | 参数 | 值 | 在哪 |
/// |---|---|---|
/// | 浅色底 | `#CDDCDC` | `values/colors.xml` |
/// | 深色底 | `#434343` | `values-night/colors.xml` |
/// | 深色窗口渐变 | `#000000 → #434343`,从上到下 | `drawable-night/launch_background.xml` |
/// | 启动图 | `drawable-xxxhdpi/splash_logo.png`,浅/深色背景各一份 | 各 layer-list |
/// | API 31+ 的底 / 图标 | `@color/launch_background_color` / `@drawable/splash_logo` | `values*-v31/styles.xml` |
/// | Flutter 侧 | **没有**任何启动图层(那层是压在界面上的鸟的残影) | `lib/main.dart` |
/// | 跟随系统 | 清掉按应用夜间模式,APP 和启动图一起跟手机 | `MainActivity.applyAppNightMode` |
///
/// ## 启动入口(2026-09 那次「手动换主题启动图不适配」的修法)
///
/// 启动窗口是系统在 Activity 起来之前画的,它只认**被启动组件自己的主题**。主题里
/// 带 night 限定符时取的是系统那一档 —— 用户在 app 里手动换档,系统没变,启动图就
/// 还是上一档(vivo 实测;小米 / 模拟器上 `setApplicationNightMode` 能拉回来)。
///
/// 所以改成**一个主题一个启动入口**:`LaunchLightActivity` / `LaunchDarkActivity`,
/// 各挂一份写死不跟 night 走的主题(`LaunchThemeLight` / `LaunchThemeDark`),app 按
/// 落盘那档启用对应那个(`MainActivity.syncLaunchEntry`)。点图标 → launcher 挑启用
/// 着的那个 → 启动图必然是那一档,和系统深浅无关,API 31 以下一样有效。
///
/// | 参数 | 值 | 在哪 |
/// |---|---|---|
/// | 浅色入口底 | `#CDDCDC`(静态,不走 night) | `@color/launch_light` |
/// | 深色入口底 | `#434343`(静态) | `@color/launch_dark` |
/// | 浅色入口窗口 | `drawable/launch_light.xml`(平色背景 + 鸟图) | 不带限定符 |
/// | 深色入口窗口 | `drawable/launch_dark.xml`(渐变背景 + 鸟图) | 不带限定符 |
/// | 谁懂 `MainActivity` | 只剩开发路径 `am start -n …/.MainActivity`,主题是老 `LaunchTheme` | `AndroidManifest.xml` |
void main() {
  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: _locked('$path 不见了'));
    return file.readAsStringSync();
  }

  const res = 'android/app/src/main/res';
  const manifest = 'android/app/src/main/AndroidManifest.xml';

  test('启动底色:浅 #CDDCDC / 深 #434343', () {
    expect(
      read('$res/values/colors.xml'),
      contains('<color name="launch_background_color">#CDDCDC</color>'),
      reason: _locked('浅色启动底色不是 #CDDCDC 了'),
    );
    expect(
      read('$res/values-night/colors.xml'),
      contains('<color name="launch_background_color">#434343</color>'),
      reason: _locked('深色启动底色不是 #434343 了'),
    );
  });

  test('深色窗口渐变还是 #000000 → #434343', () {
    final night = read('$res/drawable-night/launch_background.xml');
    expect(
      night,
      contains('android:startColor="#FF000000"'),
      reason: _locked('深色窗口渐变的起点变了'),
    );
    expect(
      night,
      contains('android:endColor="#FF434343"'),
      reason: _locked('深色窗口渐变的终点变了'),
    );
  });

  test('三个 layer-list 都绘制启动图:288dp、居中', () {
    for (final path in <String>[
      '$res/drawable/launch_background.xml',
      '$res/drawable-v21/launch_background.xml',
      '$res/drawable-night/launch_background.xml',
    ]) {
      final xml = read(path);
      expect(xml, contains('@drawable/splash_logo'),
          reason: _locked('$path 没有引用原有鸟图'));
      expect(xml, contains('android:width="288dp"'),
          reason: _locked('$path 的启动图宽度不是 288dp'));
      expect(xml, contains('android:height="288dp"'),
          reason: _locked('$path 的启动图高度不是 288dp'));
      expect(xml, contains('android:gravity="center"'),
          reason: _locked('$path 的启动图不居中'));
    }
  });

  test('API 31+:底用启动背景色,图标用原有鸟图', () {
    for (final path in <String>[
      '$res/values-v31/styles.xml',
      '$res/values-night-v31/styles.xml',
    ]) {
      final xml = read(path);
      expect(
        xml,
        contains(
          '<item name="android:windowSplashScreenBackground">'
           '@color/launch_background_color</item>',
        ),
         reason: _locked('$path 的启动底色指向变了'),
      );
      expect(
        xml,
        contains(
          '<item name="android:windowSplashScreenAnimatedIcon">'
           '@drawable/splash_logo</item>',
        ),
         reason: _locked('$path 的启动图没有指向原有鸟图'),
      );
    }
  });

  test('Flutter 侧不许再加启动图层', () {
    final main = read('lib/main.dart');
    expect(
      main.contains('_SplashFade'),
      isFalse,
      reason: _locked(
        '又加回了 Flutter 侧的启动图层 —— 它画在已经可用的界面上,'
        '真机上就是一只鸟的残影(见 main.dart 里那段注释)',
      ),
    );
    expect(
      main.contains('splash_logo'),
      isFalse,
      reason: _locked('Flutter 侧又引用启动图了,启动画面只在原生侧'),
    );
  });

  test('启动入口:浅深各一个组件,默认只开浅色那个', () {
    final xml = read(manifest);
    expect(
      _activityBlock(xml, 'LaunchLightActivity'),
      contains('android:theme="@style/LaunchThemeLight"'),
      reason: _locked('浅色启动入口的主题指向变了'),
    );
    expect(
      _activityBlock(xml, 'LaunchDarkActivity'),
      contains('android:theme="@style/LaunchThemeDark"'),
      reason: _locked('深色启动入口的主题指向变了'),
    );
    expect(_activityBlock(xml, 'LaunchDarkActivity'),
        contains('android:enabled="false"'));
    expect(_activityBlock(xml, 'LaunchLightActivity'),
        contains('android.intent.category.LAUNCHER'));
    expect(_activityBlock(xml, 'LaunchDarkActivity'),
        contains('android.intent.category.LAUNCHER'));
  });

  test('MainActivity 自己不再挂 launcher 入口', () {
    final block = _activityBlock(read(manifest), 'MainActivity');
    expect(
      block.contains('android.intent.category.LAUNCHER'),
      isFalse,
      reason: _locked('MainActivity 又挂回 launcher 入口了'),
    );
    expect(
      block.contains('io.flutter.embedding.android.NormalTheme'),
      isTrue,
      reason: _locked(
        'MainActivity 的 NormalTheme 没了 —— 直接 am start 起来那条开发路径上,'
        'Flutter 首帧背后会一直挂着启动图那张 layer-list',
      ),
    );
  });

  test('两个启动入口的主题都写死,不跟 night 走', () {
    final base = read('$res/values/styles.xml');
    expect(
      base,
      contains('<style name="LaunchThemeLight"'),
      reason: _locked('浅色启动主题不在 values/styles.xml 里了'),
    );
    expect(
      base,
      contains('<style name="LaunchThemeDark"'),
      reason: _locked('深色启动主题不在 values/styles.xml 里了'),
    );
    for (final path in <String>[
      '$res/values-night/styles.xml',
      '$res/values-night-v31/styles.xml',
    ]) {
      expect(
        read(path).contains('LaunchThemeLight') ||
            read(path).contains('LaunchThemeDark'),
        isFalse,
        reason: _locked(
          '$path 里出现了启动入口的主题 —— 一带 night 限定符,启动图就又跟着'
          '系统的深浅跑了,手动换主题立刻回到"不适配"',
        ),
      );
    }
    final v31 = read('$res/values-v31/styles.xml');
    expect(v31, contains('@color/launch_background_color'),
        reason: _locked('API 31+ 启动底色指向变了'));
  });

  test('两个启动入口都保留静态背景和鸟图', () {
    final colors = read('$res/values/colors.xml');
    // 色值必须和 values-night/colors.xml 里那两档一致,否则 START 窗口和
    // NormalTheme 那个窗口之间会跳色。
    expect(
      colors,
      contains('<color name="launch_light">#CDDCDC</color>'),
      reason: _locked('浅色启动入口的底色变了'),
    );
    expect(
      colors,
      contains('<color name="launch_dark">#434343</color>'),
      reason: _locked('深色启动入口的底色变了'),
    );
    for (final path in <String>[
      '$res/drawable/launch_light.xml',
      '$res/drawable/launch_dark.xml',
    ]) {
      final xml = read(path);
      expect(xml, contains('@drawable/splash_logo'),
          reason: _locked('$path 没有引用原有鸟图'));
      expect(xml, contains('android:width="288dp"'),
          reason: _locked('$path 的启动图宽度不是 288dp'));
      expect(xml, contains('android:height="288dp"'),
          reason: _locked('$path 的启动图高度不是 288dp'));
      expect(xml, contains('android:gravity="center"'),
          reason: _locked('$path 的启动图不居中'));
    }
    expect(
      read('$res/drawable/launch_light.xml'),
      contains('@color/launch_light'),
      reason: _locked('浅色启动窗口的底不是静态的 @color/launch_light 了'),
    );
    expect(
      read('$res/drawable/launch_dark.xml'),
      contains('android:endColor="#FF434343"'),
      reason: _locked('深色启动窗口渐变的下端变了'),
    );
  });

  test('清单里的启动入口类名和 Kotlin 里拼的一字不差', () {
    // 只在一处改名的错编译器不报,只有点图标才看得出来 —— 所以在这儿对上。
    final inManifest = RegExp(r'android:name="\.(Launch\w+Activity)"')
        .allMatches(read(manifest))
        .map((m) => m.group(1)!)
        .toSet();
    final inKotlin = RegExp(r'"(Launch\w+Activity)"')
        .allMatches(read('android/app/src/main/kotlin/com/videofix/jicun/'
            'LaunchActivities.kt'))
        .map((m) => m.group(1)!)
        .toSet();
    expect(inManifest, isNotEmpty, reason: _locked('清单里找不到启动入口了'));
    expect(
      inManifest,
      inKotlin,
      reason: _locked('清单里的启动入口类名和 LaunchActivities.kt 里拼的不一致'),
    );
  });
}

/// 抠出 `<activity android:name=".X">` 到它自己的 `</activity>` 之间那段。
///
/// 清单里的元素不嵌套 activity,所以按名字切开就够 —— 不为了这个拉一个 XML 解析。
String _activityBlock(String xml, String name) {
  final start = xml.indexOf('android:name=".$name"');
  expect(start, greaterThanOrEqualTo(0), reason: _locked('清单里没有 $name'));
  final rest = xml.substring(start);
  final end = rest.indexOf('</activity>');
  return end < 0 ? rest : rest.substring(0, end);
}

/// 锁定类断言的统一说辞。
///
/// 直接写进 `reason`,所以**跑测试的输出里就能看到**"这是锁,不是功能坏了" ——
/// 不用回来翻源码才知道该怎么处理。
String _locked(String what) =>
    '【启动图参数锁】$what。'
    '红了不是功能坏了,是启动图被改了:故意的就把本文件里对应的那条期望值一起改掉,'
    '不是故意的就把那次改动退回去。改完记得跑 '
    '`flutter test test/splash_params_test.dart test/splash_asset_test.dart`。';

