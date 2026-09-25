import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

class ThemeBackground extends StatelessWidget {
  const ThemeBackground({
    super.key,
    required this.isDark,
    required this.child,
    this.tag = '?',
  });

  final bool isDark;
  final Widget child;
  final String tag;

  @override
  Widget build(BuildContext context) {
    if (isDark) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF000000), Color(0xFF434343)],
          ),
        ),
        child: child,
      );
    }

    return CustomPaint(
      painter: const LightThemeBackgroundPainter(),
      child: child,
    );
  }
}

class LightThemeBackgroundPainter extends CustomPainter {
  const LightThemeBackgroundPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFFCDDCDC));

    final linearShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x40FFFFFF), Color(0x40000000)],
    ).createShader(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = linearShader
        ..blendMode = BlendMode.overlay,
    );

    final center = Offset(size.width * 0.5, size.height);
    final radius = math.sqrt(
      size.width * size.width * 0.25 + size.height * size.height,
    );
    final radialShader = RadialGradient(
      center: Alignment(
        (center.dx / size.width) * 2 - 1,
        (center.dy / size.height) * 2 - 1,
      ),
      radius: radius / size.height,
      colors: const [Color(0x80FFFFFF), Color(0x80000000)],
    ).createShader(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = radialShader
        ..blendMode = BlendMode.screen,
    );
  }

  @override
  bool shouldRepaint(covariant LightThemeBackgroundPainter oldDelegate) =>
      false;
}

/// 比 Cupertino 默认更「收」的越界回弹。
///
/// 越界拖动走多远由 `frictionFactor` 决定(正常档起始 0.52):值越小,同样的手指
/// 位移越走不动。这里砍掉一半 —— 松手后那点回弹还在,但不会再甩出去一大截,
/// 手指也不用拖很远才回到边界。
class ShortBounceScrollPhysics extends BouncingScrollPhysics {
  const ShortBounceScrollPhysics({super.parent});

  /// 必须重写。Scrollable 会把这里的 physics 和全局滚动物理合并
  /// (`physicsFromWidget.applyTo(configuration)`),而
  /// `BouncingScrollPhysics.applyTo` 返回的是一个**新的 BouncingScrollPhysics** ——
  /// 不重写的话这个子类会被悄悄换掉,阻力改了个寂寞。
  @override
  ShortBounceScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ShortBounceScrollPhysics(parent: buildParent(ancestor));

  /// 内容不满一屏时也要能拖。默认物理在这种情况下直接拒收拖动
  /// (`shouldAcceptUserOffset` 在 min==max==0 时返回 false),刚进「主题与外观」
  /// 就是这个状态 —— 手指下去毫无反应,展开一张卡把内容撑高了才突然有回弹。
  /// 这里跟 AlwaysScrollableScrollPhysics 一样放开,越界那点回弹始终在。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double frictionFactor(double overscrollFraction) =>
      super.frictionFactor(overscrollFraction) * 0.5;
}

/// 「点开滑出 / 再点缩回」那套伸缩回弹的规格。系统主题卡与首页三张预览卡共用
/// 同一份,两处的开合手感才一致。
///
/// 展开比收起慢:一次性滑出一整块内容,太快像被弹开。
const Duration kRevealExpand = Duration(milliseconds: 460);

/// 收起稍快一点更利落,但同样留回弹。
const Duration kRevealCollapse = Duration(milliseconds: 420);

/// 回弹要留在**末尾**:曲线前半段匀速铺开,最后冲到目标高度上面一点再落回来
/// (easeOutBack 那种形状是前段猛冲、末尾慢慢蹭,看着就是「一下就完了」)。
const Curve kRevealExpandCurve = Cubic(0.35, 0.30, 0.45, 1.25);

/// 收起的回弹只能做成「先往回涨一点再缩」—— 高度没法缩得比标题行还短。
/// 这里让曲线前三分之一下探(箱子先涨 ~9%),再一路收到 0。
const Curve kRevealCollapseCurve = Cubic(0.70, -0.50, 0.40, 1.0);

/// 靠高度做伸缩的「滑出/缩回」盒子。
///
/// 内容一直挂在树上,收起时只是被裁掉 —— 否则收起那一瞬间内容就没了,只剩一段
/// 空白在收,看着就是「啪一下贴到底」。展开:曲线冲过目标高度再收回,落到底那下
/// 是回弹。收起:曲线开头先往回一点(anticipation),箱子先微微涨一下再缩回去。
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: !expanded,
      child: IgnorePointer(
        ignoring: !expanded,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: expanded ? 1 : 0),
          duration: expanded ? kRevealExpand : kRevealCollapse,
          curve: expanded ? kRevealExpandCurve : kRevealCollapseCurve,
          builder: (context, t, child) => ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: t < 0 ? 0 : t,
              child: child,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 卡片右侧那个「展开/收起」箭头,转半圈。曲线与时长跟 [Reveal] 同一份。
class RevealChevron extends StatelessWidget {
  const RevealChevron({super.key, required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: expanded ? kRevealExpand : kRevealCollapse,
      // 回弹曲线:箭头会稍微转过头再落回来
      curve: expanded ? kRevealExpandCurve : kRevealCollapseCurve,
      child: Icon(CupertinoIcons.chevron_down, size: 18, color: color),
    );
  }
}

/// 解析成功后每张预览卡的入场:淡入 + 上浮 16px。
///
/// 三张卡共用一条时间线,靠 [Interval] 错开(`index` 越大越晚),所以不需要
/// 定时器、也不会出现「谁先谁后」的帧间抖动。系统「减弱动态效果」时直接给终态。
class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.show,
    required this.child,
  });

  /// 第几张(从 0 起),决定入场顺序。
  final int index;

  final bool show;
  final Widget child;

  @override
  State<StaggerIn> createState() => StaggerInState();
}

class StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  static const Duration _motion = Duration(milliseconds: 560);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _motion,
    // 已经可见时(例如热重载、从别的 tab 切回来)直接是终态,不补播
    value: widget.show ? 1 : 0,
  );

  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      // 第 0 张立刻走,之后每张晚 22% 的时间线(≈120ms)
      (widget.index * 0.22).clamp(0.0, 0.7),
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void didUpdateWidget(StaggerIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.show == oldWidget.show) return;
    if (widget.show) {
      _controller.forward(from: 0);
    } else {
      // 收回去时不播:外层 [Reveal] 正在把高度收回,卡片再自己淡出会看着重影
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只要 disableAnimations 这一个 aspect:MediaQuery.of 会把键盘 insets 的
    // 变化也算成依赖,白白重建一次。
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _progress.value,
        child: Transform.translate(
          offset: Offset(0, (1 - _progress.value) * 16),
          child: child,
        ),
      ),
    );
  }
}

