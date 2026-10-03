import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动图的**字节锁**(和 `splash_params_test.dart` 是一对:那边锁参数,这边锁图)。
///
/// ## 这个文件红了怎么读
///
/// **它不是功能测试。** 它红了只有一个意思:**启动图那两张图的字节变了** ——
/// 不代表代码坏了。
///
/// - **换图是故意的**:把下面的 [kOriginalSha256](母本)/ [kSplashSha256](app 用的
///   那份)换成本地重算出来的值(`Get-FileHash <文件> -Algorithm SHA256`),并在提交
///   说明里写清换成哪一版、为什么;
/// - **不是故意的**:把图退回去,**不要**改这里。
///
/// ## 三份东西的关系
///
/// - 母本 `启动图.png`(仓库根目录):平台给的原图,1252×1252,鸟只占画布宽 44%。
///   **永远不动它** —— 它是回滚路径。
/// - app 用的 `android/.../drawable-xxxhdpi/splash_logo.webp`:母本**裁掉留白重排**
///   过的一版,912×912,鸟占 60%。为什么要裁:Android 12+ 的系统启动图把这张图铺进
///   288dp 画布,**鸟占画布多宽,屏幕上就多宽** —— "鸟太小"只能动图,改布局没用。
/// - 想回到母本那一版:`Copy-Item 启动图.png <上面那个路径> -Force`,再把
///   [kSplashSha256] 换成 [kOriginalSha256]。
///
/// 2026-09 第 0 周:这份图从 PNG 换成了 WebP(q=92,136.9KB -> 20.6KB),**画面没动**。
/// 换的时候按启动底色(#CDDCDC / #000000 / #434343)合成比对过:可见像素最大通道差
/// 27、均值 0.09(912×912),alpha 与原图逐字节相同。所以 [kSplashSha256] 跟着换新;
/// 换图取值的流程不变。
void main() {
  /// 平台给的母本。**永远不动它。**
  const original = '启动图.png';

  /// 系统启动窗口用的那份(也是仓库里唯一一份启动图)。
  const res = 'android/app/src/main/res/drawable-xxxhdpi/splash_logo.webp';

  String shaOf(String path) =>
      sha256.convert(File(path).readAsBytesSync()).toString();

  test('启动图两份都在', () {
    for (final path in <String>[original, res]) {
      expect(File(path).existsSync(), isTrue, reason: _locked('$path 不见了'));
    }
  });

  test('母本没被动过', () {
    expect(
      shaOf(original),
      kOriginalSha256,
      reason: _locked('仓库根目录那份启动图母本被改了 —— 它是回滚路径,不能动'),
    );
  });

  test('app 用的那份是裁过留白的那一版', () {
    expect(
      shaOf(res),
      kSplashSha256,
      reason: _locked('app 里的启动图被换过了'),
    );
  });
}

/// 现在 app 用的那一版:母本裁掉留白重排,912×912,鸟占画布 60%。
const String kSplashSha256 =
    '46723b43928080c007e8f782c0c3b3c227c28fa15c84b9eb7cb4d5da78d44b11';

/// 母本 `启动图.png` 的 sha256(1252×1252)。
const String kOriginalSha256 =
    'dc5a51a0cf524a14308a8793922177a1be3fe20a9736df9c4b4b21b14bd7df0e';

/// 锁定类断言的统一说辞(和 splash_params_test.dart 里那条一样)。
///
/// 直接写进 `reason`,跑测试的输出里就能看到"这是锁,不是功能坏了"。
String _locked(String what) =>
    '【启动图字节锁】$what。'
    '红了不是功能坏了,是启动图被换了:故意的就把本文件里的 sha256 换成新图算出来的值,'
    '不是故意的就把图退回去(母本在仓库根目录的 启动图.png)。';
