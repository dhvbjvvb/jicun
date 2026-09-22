import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 把单色 SVG 染成当前 [IconTheme] 的颜色。
///
/// glass 底栏在 `BottomBarTabItem` 里注入了
/// `IconThemeData(color: 玻璃主题色)`(见 liquid_glass_widgets 的
/// `tab_bar_bottom_internal.dart`),但那只对真正的 `Icon` 生效。
/// `SvgPicture` 既不读 `IconTheme`,也不吃 `SvgTheme`(后者只管 `currentColor`
/// 关键字),所以硬编码 `fill="#000000"` 的图标在深色玻璃上会变成黑上加黑。
/// 用 `BlendMode.srcIn` 强制上色,才能跟着玻璃主题走。
class TintedSvgIcon extends StatelessWidget {
  const TintedSvgIcon(this.asset, {super.key, this.size = 24, this.color});

  final String asset;
  final double size;

  /// 显式指定颜色。为 null 时按 [IconTheme] → [CupertinoColors.label] 依次回退,
  /// 所以放在 glass 底栏里会自动跟玻璃主题色,放在普通页面里会跟系统深浅色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(
        color ??
            IconTheme.of(context).color ??
            CupertinoColors.label.resolveFrom(context),
        BlendMode.srcIn,
      ),
    );
  }
}

/// 选中时**播放一次**的底栏图标,播完停在终态。
///
/// 关键点:把它放在 [GlassTab.activeIcon]。那一槽位只在 tab 被选中时构建
/// (`selected ? (tab.activeIcon ?? tab.icon) : tab.icon`),于是:
///
/// - 选中 → 组件构建 → `forward()` 跑一次 → 停在 scale 1.0
/// - 切走 → 组件销毁 → controller 释放
/// - 再选中 → 重新构建 → 再播一次
///
/// 天然就是「选中播放一次然后停止」,不需要任何"播放状态"标志位,
/// 也不会重复点击时乱播(重复点已选中的 tab 不会重建该项)。
class AnimatedTabIcon extends StatefulWidget {
  const AnimatedTabIcon(
    this.asset, {
    super.key,
    this.size = 24,
    this.duration = const Duration(milliseconds: 300),
    this.from = 0.80,
    this.overshoot = 1.06,
  });

  final String asset;
  final double size;
  final Duration duration;

  /// 起始缩放。0.80 在 24px 上是约 5px 的收缩,肉眼刚好能捕捉。
  final double from;

  /// 过冲峰值。1.06 ≈ 1.4px,再多会显得浮夸。
  final double overshoot;

  @override
  State<AnimatedTabIcon> createState() => _AnimatedTabIconState();
}

class _AnimatedTabIconState extends State<AnimatedTabIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// from → overshoot → 1.0。
  /// 时长与缓动对齐库自身的主力规格:300ms + ease-out cubic
  /// (glass 底栏的选中光晕与 accessory 都是这个规格)。
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: widget.from,
        end: widget.overshoot,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: widget.overshoot,
        end: 1,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
  ]).animate(_controller);

  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    // 系统「减弱动态效果」:库自己的动效会瞬间吸附到目标值
    // (README → Accessibility),这里必须一致,否则会出现
    // "光晕啪一下到位、图标还在慢慢弹"的割裂。
    if (!MediaQuery.of(context).disableAnimations) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = TintedSvgIcon(widget.asset, size: widget.size);

    if (MediaQuery.of(context).disableAnimations) {
      return icon;
    }
    return ScaleTransition(scale: _scale, child: icon);
  }
}
