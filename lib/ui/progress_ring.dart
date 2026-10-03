// 波浪进度环:下载中 / 完成 / 失败三种样子,以及它们背后的画笔。
//
// 从 popup.dart 拆出来:这一段是纯绘制(波浪圆环、完成与失败的波浪徽章、勾和叉),
// 和弹层布局、下载流程一点关系都没有 —— 混在卡片代码里没人翻得动。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 下载进度环:谷歌 Play 那种波浪圆环。
///
/// - 整圈浅色底,进度从 12 点整顺时针扫过,弧线是滚动的波浪(见 [RingPainter]);
/// - 圆心是**加粗百分比**,和弧的进度严格同一个值;
/// - 下完(100%)时波浪闭合、不再爬,圆心换成蓝渐变波浪徽章加白勾(见 [ScallopBadge]);
/// - 失败时圆心换成红渐变波浪徽章加白叉。
class ProgressRing extends StatefulWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.failed,
    required this.isDark,
    this.diameter = defaultDiameter,
  });

  /// 0~1。
  final double progress;
  final bool failed;
  final bool isDark;

  /// 圆环外径。整张卡收小之后环也跟着收;更新卡里还要再小一点(卡片更矮)。
  final double diameter;

  static const double defaultDiameter = 128;

  /// 画法的基准直径:[RingPainter] 里的半径/线宽都是按 176 定的,
  /// 实际画的时候整块画布按 `diameter / 176` 缩放,这样只有一处尺寸可调。
  static const double designDiameter = 176;

  /// 波浪徽章盘面的直径(设计基准里)。徽章要**深深压到进度环的笔触下面**:
  /// 环笔触内缘 63、外缘 77(半径 70、半线宽 7),徽章半径取 70、起伏 5.5%,
  /// 浪谷 66、浪峰 74 —— 全程藏在笔触底下 3 个单位以上,抗锯齿也吃不穿,
  /// 缝里不可能露卡片底。相位和环对不对得上都无所谓,反正看不见交界。
  static const double badgeDiameter = 140;

  @override
  State<ProgressRing> createState() => ProgressRingState();
}

class ProgressRingState extends State<ProgressRing>
    with TickerProviderStateMixin {
  /// 显示用的进度。数据一段一段来,直接画会一跳一跳;补间到目标值就顺了。
  late double _shown = widget.progress;

  /// 离上一次真实上报过了几拍(见 [_creepTick])。
  ///
  /// 为什么要有这个东西:真机实测 360MB 那条视频,最后一块的连接卡了 11 秒 ——
  /// 一个字节都没进来,按字节算的进度就只能定在 49%,看着像死了,然后一下跳到
  /// 100%。所以闲下来就让 [_shown] 自己往前爬(见 [_onCreepTick])。
  int _idleBeats = 0;

  /// 现在算"卡住了":超过 [_stallAfterBeats] 没有新上报。弧上那道流光看这个开关。
  bool _stalled = false;

  /// 几拍没新上报就当卡住。5 拍 = 2 秒:正常下载 1% 用不了这么久。
  static const int _stallAfterBeats = 5;

  /// 爬的拍子,以及每拍吃掉"离封顶还差的那一截"的多少。
  /// 0.012 / 400ms ⇒ 中段约 1.5%/秒:看得见在走,又不会几秒钟冲到顶。
  static const Duration _creepTick = Duration(milliseconds: 400);
  static const double _creepShare = 0.012;

  /// 爬的天花板。**永远不自己到 100%**:那一下只留给真下完的那条上报。
  static const double _creepCeiling = 0.99;

  Timer? _creep;

  /// 100% 时对勾那一下弹出来。
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// 波浪的相位。走完 1.0 = 浪前进一个波长,所以 1 秒正好是谷歌的
  /// waveSpeed 默认值(每秒一个波长)。再快就显得躁。
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.progress >= 1 || widget.failed) _pop.value = 1;
    _syncWave();
    _creep = Timer.periodic(_creepTick, (_) => _onCreepTick());
  }

  @override
  void didUpdateWidget(ProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 来了新上报:重新开始数"闲了多久",流光也收掉。
    if (widget.progress != oldWidget.progress) {
      _idleBeats = 0;
      _stalled = false;
    }
    // 显示值只增不减:爬上去的那一截不能因为下一条上报比它小就退回来 ——
    // 进度倒着走比停着还难看。
    setState(() => _shown = math.max(_shown, widget.progress));
    if (widget.progress >= 1) {
      _shown = 1;
      _stalled = false;
    }
    if (widget.progress >= 1 && oldWidget.progress < 1) _pop.forward(from: 0);
    if (widget.failed && !oldWidget.failed) _pop.forward(from: 0);
    if (widget.progress < 1 && oldWidget.progress >= 1) _pop.value = 0;
    _syncWave();
  }

  /// 只有「还在下」的时候波浪才转:下完/失败还转着,看着像没结束。
  void _syncWave() {
    final running = widget.progress < 1 && !widget.failed;
    if (running && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!running && _wave.isAnimating) {
      _wave.stop();
    }
  }

  @override
  void dispose() {
    _creep?.cancel();
    _creep = null;
    _pop.dispose();
    _wave.dispose();
    super.dispose();
  }

  /// 闲下来了:让显示值自己往前爬,并把弧上那道流光点起来。
  ///
  /// 爬的是"离 [_creepCeiling] 还差的那一截"的固定比例 —— 越接近顶越慢,永远
  /// 够不到 100%(那一下只留给真下完的那条上报,见 [didUpdateWidget])。
  void _onCreepTick() {
    if (!mounted || widget.failed || _shown >= 1) return;
    if (_idleBeats < _stallAfterBeats) {
      _idleBeats++;
      // 还在动:上报之间的正常空档不该点灯。
      if (_stalled) setState(() => _stalled = false);
      return;
    }
    final gap = _creepCeiling - _shown;
    if (gap <= 0.0005) return;
    setState(() {
      _stalled = true;
      _shown += gap * _creepShare;
    });
  }

  @override
  Widget build(BuildContext context) {
    final done = _shown >= 1 && !widget.failed;
    final scale = widget.diameter / ProgressRing.designDiameter;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, _) => SizedBox(
        width: widget.diameter,
        height: widget.diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 圆心先画、圆环后画:完成/失败的徽章盘面要压进环的笔触底下,
            // 缝里才不露卡片底。下载中圆心只是百分比文字,环盖不盖它都一样。
            _center(value, done, scale),
            CustomPaint(
              size: Size.square(widget.diameter),
              painter: RingPainter(
                scale: scale,
                progress: done ? 1 : value,
                phase: _wave,
                stalled: _stalled,
                arcColor: widget.failed
                    ? const Color(0xFFE5484D)
                    : const Color(0xFF2F6BFF),
                deepColor: widget.failed ? failedDeep : doneDeep,
                // 底圈要看得见又不抢戏:太淡了整圈像没画,太重了分不出哪段是进度
                // 底圈用一个中性色再压到 22% 不透明:深色档是纯白、浅色档那个深蓝黑
                // (0xFF1B2430)和 Palette 的 foreground 同值,但深色档的白不是
                // foreground(那是 0xFFF5F7FA)—— 两档不是同一组,所以留内联。
                trackColor:
                    (widget.isDark
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFF1B2430))
                        .withValues(alpha: 0.22),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 圆心:没下完是加粗百分比,下完是蓝渐变波浪徽章加白勾,失败是红渐变徽章加白叉。
  Widget _center(double value, bool done, double scale) {
    final failed = widget.failed;
    final percent = '${(value * 100).round()}%';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: (done || failed)
          ? ScaleTransition(
              key: ValueKey(done ? 'done' : 'failed'),
              scale: CurvedAnimation(parent: _pop, curve: Curves.elasticOut),
              child: ScallopBadge(scale: scale, failed: failed),
            )
          : Text(
              percent,
              key: const ValueKey('percent'),
              style: TextStyle(
                // 卡片底色是磨砂浅色,百分比用深色才看得清;深色模式的卡片底是深灰,
                // 写白色。这一对(0xFFFFFFFF / 0xFF12203A)不在 Palette 里:那套的
                // foreground 深色档是 0xFFF5F7FA、浅色档是 0xFF1B2430,都不是这两支。
                color: widget.isDark
                    ? const Color(0xFFFFFFFF)
                    : const Color(0xFF12203A),
                fontSize: 28 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

/// 渐变深端(完成)。品牌蓝压暗的那一头。
const Color doneDeep = Color(0xFF001F6B);

/// 渐变深端(失败)。
///
/// **不能沿用蓝色那一头**:红 lerp 进深蓝会变成发紫的脏红,和「红色渐变」差着
/// 一整档 —— 成功/失败该只差颜色,不该差成另一个配方。
const Color failedDeep = Color(0xFF6B0008);

/// 完成/失败的波浪徽章:谷歌 Play 下载完成那种边缘起伏的圆盘。
///
/// - 边缘是正弦起伏的闭合圆(14 道浪,和外圈进度环同数,看着是一家人),
///   起伏约半径的 7%,和参考图里那圈圆润的波浪同量级;
/// - 盘面**藏进进度环的笔触底下**(见 [badgeDiameter]),和环叠在一起才是一整块,
///   中间没有任何露底的缝;
/// - 盘面渐变和进度弧**同一配方**(深 → 亮,横向),叠放处色调连得上;
///   完成走品牌蓝,失败走红;
/// - 中央符号是粗白勾 / 粗白叉,和参考图同字重。
class ScallopBadge extends StatelessWidget {
  const ScallopBadge({super.key, required this.scale, required this.failed});

  final double scale;
  final bool failed;

  /// 边缘起伏的瓣数。12 瓣 + 小起伏 = 圆润的花瓣,瓣数越多齿越尖
  /// (斜率 ≈ 瓣数 × 起伏,之前 14 瓣 × 7% 真机上像齿轮)。
  /// 和外圈进度环瓣数不一样没关系:交界藏在环底下,看不见。
  static const int lobes = 12;

  /// 起伏幅度占半径的比例。5.5% 配 12 瓣,圆润和参考图同量级。
  static const double ripple = 0.055;

  @override
  Widget build(BuildContext context) {
    final base = failed
        ? const Color(0xFFE5484D)
        : const Color(0xFF2F6BFF);
    // 和进度弧同一配方(见 RingPainter 的 shader):徽章压在环底下,
    // 配方不一致的话叠放处会断色。
    final deep = failed ? failedDeep : doneDeep;
    const light = Color(0xFFFFFFFF);
    final d = ProgressRing.badgeDiameter * scale;
    return SizedBox(
      width: d,
      height: d,
      child: CustomPaint(
        painter: ScallopFill(
          stops: <Color>[
            Color.lerp(base, deep, 0.45)!,
            Color.lerp(base, light, 0.15)!,
          ],
        ),
        foregroundPainter: failed
            ? const CrossPainter(color: Color(0xFFFFFFFF))
            : const CheckPainter(color: Color(0xFFFFFFFF)),
      ),
    );
  }
}

/// 波浪徽章的盘面:起伏圆填渐变。
class ScallopFill extends CustomPainter {
  const ScallopFill({required this.stops});

  /// 对角渐变的上、下两档(见 [ScallopBadge])。
  final List<Color> stops;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final path = Path();
    const step = math.pi / 180;
    for (var deg = 0; deg <= 360; deg++) {
      final angle = deg * step;
      final rr =
          r *
          (1 +
              ScallopBadge.ripple *
                  math.sin(ScallopBadge.lobes * angle));
      final point = Offset(
        center.dx + rr * math.sin(angle),
        center.dy - rr * math.cos(angle),
      );
      if (deg == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    // 横向渐变,和进度弧的 shader 同方向同配方:徽章压在环底下,
    // 两边的色调在叠放处连得上,不会断色。
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, size.height / 2),
          Offset(size.width, size.height / 2),
          stops,
        ),
    );
  }

  @override
  bool shouldRepaint(ScallopFill old) => old.stops != stops;
}

/// 徽章中央符号的线宽 = 盘子直径的这个比例。勾和叉共用:15% 已经挺粗了,
/// 再粗折角就开始糊在一起。
const double badgeGlyphStrokeRatio = 0.15;

/// 失败徽章里的白叉,和 [CheckPainter] 同字重。
class CrossPainter extends CustomPainter {
  const CrossPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * badgeGlyphStrokeRatio
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(Offset(s * 0.32, s * 0.32), Offset(s * 0.68, s * 0.68), paint);
    canvas.drawLine(Offset(s * 0.68, s * 0.32), Offset(s * 0.32, s * 0.68), paint);
  }

  @override
  bool shouldRepaint(CrossPainter old) => old.color != color;
}

/// 波浪徽章里那个白对勾(见 [ScallopBadge])。
///
/// 不用图标字体:`CupertinoIcons.check_mark` 的字重是定死的,要「又大又粗」
/// 只能自己画。折线按 0~1 的相对坐标定,盘子多大都合用。
class CheckPainter extends CustomPainter {
  const CheckPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 起笔在左下、拐到中下、甩到右上:标准的对勾三段折线
    final path = Path()
      ..moveTo(size.width * 0.24, size.height * 0.52)
      ..lineTo(size.width * 0.42, size.height * 0.70)
      ..lineTo(size.width * 0.76, size.height * 0.32);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * badgeGlyphStrokeRatio
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(CheckPainter old) => old.color != color;
}

/// 波浪进度环的画笔 —— 谷歌 Play 商店下载中围着图标那圈「皱起来的圆环」
/// (Material 3 Expressive 的 wavy circular progress)。
///
/// - **底圈**和**进度**走同一条波浪:半径在 半径 ± 浪高 之间按正弦起伏。
///   波形只跟**角度**有关(`sin(浪数 × 角度 + 相位 × 2π)`),所以任何一段弧
///   的浪都落在同一处 —— 底圈和进度上的浪对得上,进度长出来时波形也不变形;
/// - 浪数取整、按**整圈**定死:波长不会随进度变,100% 时首尾严丝合缝闭合;
/// - 进度和底圈之间留一小段**缺口**(谷歌的 gapSize,默认 4dp),
///   看着是两段线而不是一整条;
/// - 相位一秒走一个波长(谷歌 waveSpeed 的默认值就是「每秒一个波长」)。
///
/// 比例是照参考抄的:细线(约 4dp)、浪高跟线宽同量级、波长约 20dp。
/// 之前那版线宽 20、整圈 20 道浪,浪比线还密,看着像毛毛虫 —— 谷歌不是那么画的。
class RingPainter extends CustomPainter {
  RingPainter({
    required this.scale,
    required this.progress,
    required this.phase,
    required this.stalled,
    required this.arcColor,
    required this.deepColor,
    required this.trackColor,
  }) : super(repaint: phase);

  /// 画布缩放:下面的半径/线宽都按 176 的基准定,乘上它才是实际尺寸。
  final double scale;

  final double progress;

  /// 波浪相位(0~1 循环)。挂成 [repaint] 的 listenable:相位往前走不用
  /// 重建 widget,只重画这一层。
  final Animation<double> phase;

  /// 卡住了(见 [ProgressRingState._onCreepTick]):在已经画出来的那段弧上再画一道
  /// 缓慢扫过的光。数字和弧长都定住的时候总得有个东西在动,不然看着就是死机。
  final bool stalled;

  final Color arcColor;

  /// 弧线渐变深端。见 [doneDeep] / [failedDeep] —— 失败时不能拿蓝色那一头去压,
  /// 红配深蓝出来是发紫的脏红。
  final Color deepColor;

  final Color trackColor;

  /// 圆环中心线半径、线宽、浪高。都按 176 的基准定。
  ///
  /// 浪高 4:浪太高齿就尖了,参考图里是圆润的起伏。斜率 ≈ 浪高 × 浪数 ÷ 半径,
  /// 取 0.8 左右齿形圆,之前 5.5 那版斜率 1.1,真机上看着像齿轮。
  static const double _radius = 70;
  static const double _stroke = 14;
  static const double _amplitude = 4;

  /// 整圈的浪数。整数:整圈才闭得上。14 道 = 176 基准下 31 个单位一个波长,
  /// 换成 dp 约 23dp —— 和谷歌那支波浪进度条的波长同量级。
  static const int _waves = 14;

  /// 进度和底圈之间的缺口(按中心线量)。谷歌默认 4dp,这里取同量级。
  static const double _gapLength = 6.5;

  @override
  void paint(Canvas canvas, Size size) {
    // 半径常量按 176 的基准定:先把画布缩到实际尺寸,圆心要换算回基准坐标系,
    // 否则会按实际尺寸算一半、再被缩放一次,整个环偏到左上。
    canvas.scale(scale);
    final center = Offset(size.width / scale / 2, size.height / scale / 2);

    final clamped = progress.clamp(0.0, 1.0);
    final sweep = 2 * math.pi * clamped;
    // 缺口换算成圆心角:弧长 ÷ 半径
    const gap = _gapLength / _radius;

    Paint strokePaint(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    Path wave(double from, double to) => waveArcPath(
      center: center,
      radius: _radius,
      amplitude: _amplitude,
      startAngle: from,
      endAngle: to,
      phase: phase.value,
      waves: _waves,
    );

    // 底圈:从进度末端(让出一个缺口)铺到 12 点前(再让出一个缺口)。
    // 进度下满时这段自然为空,整圈都归进度。
    final trackFrom = sweep + gap;
    const trackTo = 2 * math.pi - gap;
    if (trackFrom < trackTo) {
      canvas.drawPath(wave(trackFrom, trackTo), strokePaint(trackColor));
    }

    if (clamped <= 0) return;

    canvas.drawPath(
      wave(0, sweep),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(center.dx - _radius, center.dy),
          Offset(center.dx + _radius, center.dy),
          <Color>[
            // 深到浅的同色系:深浅两头都压得住底色,弧才明显
            Color.lerp(arcColor, deepColor, 0.45)!,
            Color.lerp(arcColor, const Color(0xFFFFFFFF), 0.15)!,
          ],
        ),
    );

    // 卡住时那道流光:沿已画出的弧从头扫到尾,一秒一遍。位置挂在波浪相位上,
    // 不用另开动画控制器 —— 相位推着浪走,同一份相位也推着这道光走,节奏一致。
    if (!stalled || clamped >= 1) return;
    const double band = 0.12; // 光带长度(占整圈的比例)
    final double head = phase.value;
    final double tail = math.max(0.0, head - band);
    if (head - tail <= 0.01) return;
    canvas.drawPath(
      wave(tail * clamped, head * clamped),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.scale != scale ||
      old.progress != progress ||
      old.stalled != stalled ||
      old.arcColor != arcColor ||
      old.deepColor != deepColor ||
      old.trackColor != trackColor;
}

/// 波浪弧的采样点,连成一条折线。
///
/// 角度从 **12 点整**起算、顺时针为正,[startAngle] / [endAngle] 是弧度。
/// 半径 = [radius] + [amplitude] × sin([waves] × 角度 + [phase] × 2π):
/// 波形只跟角度有关,所以同一条圆上任意两段弧在角度重叠处浪的位置一致 ——
/// 底圈和进度的浪才对得上,进度长出来时波形也不会变形。浪数取整时整圈闭合。
///
/// 采样步长 1°:一圈 360 段,每段远小于线宽,看着就是光滑的浪,比推贝塞尔省事。
Path waveArcPath({
  required Offset center,
  required double radius,
  required double amplitude,
  required double startAngle,
  required double endAngle,
  required double phase,
  required int waves,
}) {
  const double step = math.pi / 180;
  final span = endAngle - startAngle;
  final steps = math.max(2, (span / step).ceil());
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final angle = startAngle + span * i / steps;
    final r =
        radius + amplitude * math.sin(waves * angle + phase * 2 * math.pi);
    // 0 度在 12 点整,角度顺着表针长
    final point = Offset(
      center.dx + r * math.sin(angle),
      center.dy - r * math.cos(angle),
    );
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path;
}
