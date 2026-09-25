import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/main.dart';

/// 波浪进度环的几何自检:半径不出带宽、整圈首尾闭合、浪数对得上、相位推着浪走,
/// 以及底圈和进度那两段弧上的浪必须落在同一处(否则看着就是两圈错开的浪)。
///
/// 波形画在 canvas 上,这里不碰画布 —— 沿路径量半径,把「画出来的那条线」
/// 当成数据来验。
void main() {
  const center = Offset(88, 88);
  const radius = 70.0;
  const amplitude = 6.0;
  const waves = 8;

  /// 沿路径等距采 [count] 个点,回它们(角度, 半径)。角度从 12 点整顺时针。
  List<(double, double)> samplesOf(Path path, {int count = 2000}) {
    final metric = path.computeMetrics().single;
    return List<(double, double)>.generate(count, (i) {
      final position = metric.getTangentForOffset(metric.length * i / count)!.position;
      final offset = position - center;
      final angle = math.atan2(offset.dx, -offset.dy) % (2 * math.pi);
      return (angle, offset.distance);
    });
  }

  List<double> radiiOf(Path path, {int count = 2000}) =>
      samplesOf(path, count: count).map((s) => s.$2).toList();

  /// 半径往上穿过中心线的次数 = 浪数。
  int crestsOf(List<double> radii) {
    var count = 0;
    for (var i = 1; i < radii.length; i++) {
      if (radii[i - 1] <= radius && radii[i] > radius) count++;
    }
    return count;
  }

  Path wave({
    double from = 0,
    double to = 2 * math.pi,
    double phase = 0,
    double amp = amplitude,
    int waveCount = waves,
  }) => waveArcPath(
    center: center,
    radius: radius,
    amplitude: amp,
    startAngle: from,
    endAngle: to,
    phase: phase,
    waves: waveCount,
  );

  test('半径只在中心线上下一个浪高里', () {
    for (final r in radiiOf(wave())) {
      expect(r, greaterThanOrEqualTo(radius - amplitude - 0.3));
      expect(r, lessThanOrEqualTo(radius + amplitude + 0.3));
    }
  });

  test('整圈首尾闭合', () {
    final metric = wave().computeMetrics().single;
    final start = metric.getTangentForOffset(0)!.position;
    final end = metric.getTangentForOffset(metric.length)!.position;
    // 100% 时靠这条闭合:首尾不是同一个点,成功态就会留一道断口
    expect((end - start).distance, lessThan(0.01));

    // 整条线都在「半径 ± 浪高」的圈里:浪尖不一定正对上下左右,
    // 所以只能验包住,不能验贴着。
    final bounds = wave().getBounds();
    expect(bounds.left, greaterThanOrEqualTo(center.dx - radius - amplitude - 0.3));
    expect(bounds.right, lessThanOrEqualTo(center.dx + radius + amplitude + 0.3));
    expect(bounds.top, greaterThanOrEqualTo(center.dy - radius - amplitude - 0.3));
    expect(bounds.bottom, lessThanOrEqualTo(center.dy + radius + amplitude + 0.3));
    // 也不该缩成里面那个小圈
    expect(bounds.width, greaterThanOrEqualTo(2 * (radius - amplitude)));
    expect(bounds.height, greaterThanOrEqualTo(2 * (radius - amplitude)));
  });

  test('整圈浪数 = waves', () {
    expect(crestsOf(radiiOf(wave())), waves);
  });

  test('弧只画半圈时,浪数跟着减半 —— 波长不随进度变', () {
    expect(crestsOf(radiiOf(wave(to: math.pi))), waves ~/ 2);
  });

  test('相位推着浪走', () {
    final still = radiiOf(wave(), count: 400);
    final moved = radiiOf(wave(phase: 0.5), count: 400);
    expect(still, isNot(equals(moved)));
  });

  test('浪高为 0 时就是正圆', () {
    for (final r in radiiOf(wave(amp: 0))) {
      expect(r, closeTo(radius, 0.3));
    }
  });

  test('底圈和进度上的浪落在同一处', () {
    // 整圈量一遍,做成「角度 → 半径」的尺子;再量一段子弧,逐点对齐比半径。
    final whole = samplesOf(wave());
    final part = samplesOf(wave(from: 0.7, to: 1.9), count: 600);
    for (final (angle, r) in part) {
      final nearest = whole.reduce(
        (a, b) => (a.$1 - angle).abs() <= (b.$1 - angle).abs() ? a : b,
      );
      expect(
        r,
        closeTo(nearest.$2, 0.2),
        reason: '角度 $angle 处两段弧的半径不一样:浪没对齐',
      );
    }
  });
}
