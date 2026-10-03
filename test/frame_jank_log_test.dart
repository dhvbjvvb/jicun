// 掉帧日志的行格式:报「返回一级页卡顿」时全靠它把构建慢和光栅慢分开,
// 所以这一行的三段时间必须和 FrameTiming 的语义对得上(见 dart:ui 的 FrameTiming):
//   构建 = buildFinish - buildStart,光栅 = rasterFinish - rasterStart,
//   总   = rasterFinish - vsyncStart。
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/bench.dart';

void main() {
  test('一帧摊成一行:构建 / 等 vsync / 光栅 三段各自对得上', () {
    final timing = FrameTiming(
      vsyncStart: 0,
      buildStart: 1000,
      buildFinish: 12000,
      rasterStart: 13000,
      rasterFinish: 45000,
      rasterFinishWallTime: 45000,
      frameNumber: 7,
    );

    expect(
      FrameJankLog.describe(timing),
      '帧 7 总 45ms | 构建 11ms(等 vsync 1ms) | 光栅 32ms',
    );
  });

  test('没开开关时 install 是空操作,重复调用也不出事', () {
    // 开关是编译期的 --dart-define;测试里没传,所以这两次都该直接返回。
    FrameJankLog.install();
    FrameJankLog.install();
  });
}
