import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';

/// 顶栏图的宽高比,按资源实际尺寸(1406x605,见 assets/theme-header)定。
/// 高度一律由屏宽算出来,不写死像素:页面外面套着 UiZoom,界面缩放不是
/// 1.0 时像素高度会和其它内容对不上。
const double kHeaderArtAspect = 1406 / 605;

/// 二级页统一外壳。
///
/// 关键:背景必须由**全屏**的 ThemeBackground 来画。直接用
/// CupertinoPageScaffold(child: ThemeBackground(...)) 时,child 从导航栏下方
/// 才开始布局,于是顶部露出 scaffold 的纯色 #CDDCDC,而且 ThemeBackground 里
/// 的渐变是按更小的矩形重算的 —— 同一屏幕位置的颜色就和主页面对不上。
/// 这里改成:背景铺满全屏 + scaffold 与导航栏透明,和主页面完全一致。
class SubPage extends StatelessWidget {
  const SubPage({
    super.key,
    required this.title,
    required this.child,
    this.headerImage,
    this.headerAspect = kHeaderArtAspect,
    this.headerLift = 0,
  });

  final String title;
  final Widget child;

  /// 顶部整宽图。null 表示这页不放图。
  ///
  /// 它只负责画,不占位:传了图的页面要自己把内容往下让出
  /// `屏宽 / headerAspect` 的高度,否则图会盖住第一张卡片。
  final String? headerImage;

  /// 顶栏图的宽高比。默认是画布比例 [kHeaderArtAspect];源图比例和画布差得多的
  /// 那张(见 [AboutAppPage])要传自己的,否则图会被拉伸或缩得比预期小一圈。
  final double headerAspect;

  /// 顶栏图整体上移多少(逻辑像素)。
  ///
  /// 图默认从内容区顶端(返回栏下方)开始画。有些图角色偏小、离标题太远,就抬上来
  /// 一截,靠 Clip.none 画到返回栏那一行去,标题压在图上。调用方记得把列表顶边距
  /// 也减去同样的值。
  final double headerLift;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground = Palette.of(isDark).foreground;
    // 二级页也吃「界面缩放大小」:底栏不缩放,所以缩放只能落在页面内容这一层,
    // 这里和主页 body 一样包一层。
    return UiZoom(
      scale: UiScale.of(context),
      child: Stack(
        children: [
          Positioned.fill(
            // RepaintBoundary:背景是静态的(只依赖 isDark),缓存成一层纹理后
            // 转场时只需重新合成,不必每帧重跑全屏 BlendMode.overlay/screen。
            child: RepaintBoundary(
              child: ThemeBackground(
                isDark: isDark,
                tag: 'subpage',
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Column(
            children: [
              // 不用 CupertinoNavigationBar:它的底色非全不透明时会挂一层整宽
              // BackdropFilter(blur 10),转场时每帧都要重跑。这里只需要一个返回
              // 按钮和标题,手写一行更省,视觉一致。
              SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: Size.zero,
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Icon(CupertinoIcons.back, size: 26),
                        ),
                      ),
                      Text(
                        title,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 顶部内边距已由上面的 SafeArea 处理,这里必须把它从子树的 MediaQuery
              // 里去掉 —— 否则页面自身的 SafeArea 会再加一次状态栏高度(两者是兄弟
              // 节点,不是父子),内容会被顶下去一个状态栏的高度。
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: headerImage == null
                      ? child
                      : Stack(
                          // headerLift > 0 时图要画到这一层外面(返回栏那一行),
                          // 所以不能裁。列表自己会裁自己的滚动内容,不受影响。
                          clipBehavior: headerLift > 0
                              ? Clip.none
                              : Clip.hardEdge,
                          children: [
                            child,
                            // 图铺在内容之上,而不是和内容上下分家:向上滚的卡片是
                            // 从图的淡出区里化掉的,不会被一条直边切断。调用方因此
                            // 要在自己的列表顶部留出图的高度(见 ThemeAppearancePage),
                            // 图只负责画,不占位。
                            Positioned(
                              top: -headerLift,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: AspectRatio(
                                  aspectRatio: headerAspect,
                                  child: Image.asset(
                                    headerImage!,
                                    fit: BoxFit.fitWidth,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// 二级页统一走的路由。
///
/// 比 CupertinoPageRoute 少两样东西:
/// 1. **压在下面那页的 9% 黑罩**。CupertinoRouteTransitionMixin 的 barrierColor 是
///    0x18000000,由 AnimatedModalBarrier 跟着转场动画淡入淡出(routes.dart 的
///    _buildModalBarrier 用 ColorTween 从全透明到 barrierColor)。结果就是返回时
///    设置主界面先从暗处浮上来 —— 明明是同一层页面,却像亮度没对齐。
/// 2. **把 500ms 收到 320ms**。iOS 那套 500ms 在这台机器上返回时总觉得慢半拍。
class SubPageRoute<T> extends CupertinoPageRoute<T> {
  SubPageRoute({required super.builder});

  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);
}


/// 把「键盘内缩」(viewInsets.bottom)从子树上摘掉。
///
/// 页面本身不为键盘让位(见 GlassScaffold 的 resizeToAvoidBottomInset 注释),
/// 也不需要知道键盘多高。但 MediaQuery 里的 viewInsets 一变,依赖它的子树就会
/// 全部重建 —— 键盘弹出动画期间那是每帧一次,点输入框的卡顿就来自这里。
/// 摘掉之后键盘只影响底栏那一层,页面不动。
///
/// 注意只摘 bottom:顶部安全区(padding)照旧,输入框在页面顶部也不会被键盘
/// 盖住,所以不需要 EditableText 那套「自动滚到可见区」的逻辑。
class NoKeyboardInset extends StatelessWidget {
  const NoKeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.removeViewInsets(
    context: context,
    removeBottom: true,
    child: child,
  );
}

/// 把当前缩放值发到整棵树。
///
/// 缩放不能包在路由外面(会把底栏的 BackdropFilter 一起卷进来,见 CupertinoApp
/// 的 builder 注释),所以改成「谁需要谁自己取」:主页 body 与二级页各自包一层
/// UiZoom。
class UiScale extends InheritedWidget {
  const UiScale({super.key, required this.scale, required super.child});

  final double scale;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiScale>()?.scale ?? 1;

  @override
  bool updateShouldNotify(UiScale oldWidget) => oldWidget.scale != scale;
}

/// 「界面缩放大小」的执行者:把页面内容(主页 body、二级页)按 scale 等比放大缩小。
///
/// 底栏不在这里 —— 它内部有 BackdropFilter,绘制期 Transform 会让它采样错位
/// (见 CupertinoApp 的 builder 注释),所以底栏分成独立绘制层、永远按 100% 画。
///
/// 做法:让子树按「虚拟尺寸 = 真实尺寸 / scale」重新布局,再把画出来的东西整体
/// 乘 scale。等于临时把这块屏幕当成更大/更小的手机,所以安全区、留白、字号一起
/// 等比变化,两个方向都不会留空边,也不会被裁掉。
/// 拖动滑杆时 scale 不变,这里就不会每帧重排整屏。
class UiZoom extends StatelessWidget {
  const UiZoom({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final real = constraints.biggest;
        final virtual = Size(real.width / scale, real.height / scale);
        // RepaintBoundary + ClipRect:
        // 缩放是靠绘制期 Transform 做的,子树的「布局尺寸」是虚拟画布、真正画出来
        // 的却是整屏。切主题时 Flutter 只按布局尺寸去重画脏区,右侧/底部那条多出来
        // 的窄条不会被刷新 —— 上一套主题的像素留在这里,看着就是底栏错位/重影。
        // 包一层 RepaintBoundary 之后任何一处脏都会整层重画,脏区按真实屏幕裁剪。
        return RepaintBoundary(
          child: ClipRect(
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              // 虚拟画布比真实屏幕大(缩小时),得让父级放行超出的部分
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SizedBox(
                  width: virtual.width,
                  height: virtual.height,
                  child: MediaQuery(
                    // 安全区也要跟着虚拟尺寸走,否则状态栏留白会和内容对不上
                    data: mq.copyWith(
                      size: virtual,
                      padding: mq.padding / scale,
                      viewPadding: mq.viewPadding / scale,
                      viewInsets: mq.viewInsets / scale,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 二级设置页的 Material 3 环境。
///
/// 卡片本身与一级设置列表同一种毛玻璃(见 GlassPanel),这里只负责控件配色:
/// 一份 Material 3 的 ColorScheme(用品牌蓝做种子,所以强调色仍是即存的蓝,
/// 而不是 Google 默认的紫)。下面所有开关与单选都从它取色。
class GoogleSurface extends StatelessWidget {
  const GoogleSurface({super.key, required this.brightness, required this.child});

  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      // 主题对象按亮度缓存:ColorScheme.fromSeed 会在主 isolate 上现算一整套 HCT
      // 调色板(种子色 → tone 表 → 十几个颜色槽),是纯 CPU 的活。二级设置页每次
      // 进入都会重建 GoogleSurface,现算就等于在转场第一帧上多压一段主线程占用,
      // 慢机型上正好和光栅抢时间。两份(深/浅)算一次就够,之后只是查表。
      data: brightness == Brightness.dark ? _darkTheme : _lightTheme,
      // Material 祖先:Switch / Radio / FilledButton 的涟漪与状态层挂在这里。
      // transparency 保证它不画自己的底色,渐变背景照旧透出来。
      child: Material(type: MaterialType.transparency, child: child),
    );
  }

  /// 深/浅各算一次。static final 是惰性求值,没进过二级设置页就不会算。
  static final ThemeData _lightTheme = _buildTheme(Brightness.light);
  static final ThemeData _darkTheme = _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1677FF),
        brightness: brightness,
      ),
    );
  }
}

/// 一级设置列表与二级设置页共用的毛玻璃面板:超椭圆转角 + 半透明底。
///
/// 刻意**不挂** BackdropFilter:背景是平滑渐变,模糊它得到的像素几乎不变,每帧却
/// 要为每张卡片各跑一次全宽模糊(转场掉帧的主因)。
///
/// 也刻意**不画投影**:列表里卡片间距只有 12,而投影(blur 18 / 下移 8)会越过
/// 间隙盖到下一张卡上,深色模式下就是一整条发黑的带子把两张卡连在一起,卡片越多
/// 越明显。卡片与背景的层次改由半透明底自己承担。
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.isDark, required this.child});

  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 超椭圆转角,与库其它玻璃面一致(用正圆弧会和它们对不上)
    const shape = LiquidRoundedSuperellipse(borderRadius: 20);
    return DecoratedBox(
      decoration: const ShapeDecoration(shape: shape),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: shape),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            // 深浅这两档的白色透明度(0x26 / 0x8C)不在 Palette 里:它和 surface /
            // surfaceClear 都不是同一对(那几个是"叠在插画上"的底),硬套会改掉卡片底色。
            color: isDark ? const Color(0x26FFFFFF) : const Color(0x8CFFFFFF),
          ),
          // 卡片自己再当一次 Material 宿主,涟漪才画在半透明底之上而不是被它压暗
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class GoogleCardTitle extends StatelessWidget {
  const GoogleCardTitle({super.key, required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: settingsPalette(isDark).foreground,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}


/// 卡片里的点击区:不要涟漪、不要按下高亮。
///
/// Flutter 默认按下时给整行铺一层灰(highlight + splash),在玻璃卡上就是一块
/// 边界清楚的灰矩形,看着像把卡片切成了两半 —— 所以这里全部关掉。
/// 点了仍然有反应,只是反应交给控件本身(开关滑动、单选变蓝、卡片展开)。
class PlainTap extends StatelessWidget {
  const PlainTap({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  static const Color _none = Color(0x00000000);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: _none,
      hoverColor: _none,
      focusColor: _none,
      child: child,
    );
  }
}

/// 控件自带的状态层(Switch / Radio 按下时那圈灰)也一并关掉
const WidgetStateProperty<Color?> noOverlay = WidgetStatePropertyAll<Color?>(
  Color(0x00000000),
);

/// 一行「标题 + 说明 + Material 3 开关」。
class GoogleSwitchRow extends StatelessWidget {
  const GoogleSwitchRow({
    super.key,
    required this.isDark,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final bool isDark;
  final String title;
  final String subtitle;
  final bool value;

  /// null = 这个开关当前不生效,置灰(和 [Switch] 一样:传 null 就是禁用)。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Padding(
      // 右边留 8:开关自己带 8 的触控留白,视觉间距才是 16
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            overlayColor: noOverlay,
            // M3 规范里关闭态是「底色 + 2dp 描边」,Flutter 默认只画底色。
            // 补上描边才是 Google 设置页里那个开关的样子;开启态不描边。
            trackOutlineColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? const Color(0x00000000)
                  : scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行「Material 3 单选 + 文字」。整行可点,选中值由上层 RadioGroup 管。
class GoogleChoiceRow<T> extends StatelessWidget {
  const GoogleChoiceRow({
    super.key,
    required this.isDark,
    required this.value,
    required this.label,
  });

  final bool isDark;
  final T value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final onChanged = RadioGroup.maybeOf<T>(context)?.onChanged;
    return PlainTap(
      onTap: onChanged == null ? null : () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Radio<T>(value: value, overlayColor: noOverlay),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: settingsPalette(isDark).foreground,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题行高度:三个板块统一 32。
///
/// 为什么定死:历史板块右上角挂着「选择 / 删除」两颗按钮(整颗 32 高)。如果让标题
/// 和它们一起参与布局、按默认居中,标题就被按钮撑高的那一行挤下去 —— 真机实测
/// 比解析板块低 25 设备px,切板块时一眼就看出来。行高定死之后,右侧有没有按钮、
/// 按钮多高,都不再影响标题的位置。
const double kBoardHeaderHeight = 32;

/// 标题行的顶边距。
///
/// 原来是 24,但那是对着一颗裸 Text 量的。标题现在在 32 高的行里居中,会往下走
/// (32 - 标题文字盒高) / 2 ≈ 6,所以顶边距减掉同样的 6 —— 标题墨迹位置保持和
/// 改动前「解析」那颗裸 Text 一致(真机实测 232 设备px)。
const double kBoardHeaderTop = 18;

/// 板块左上角那行标题:标题 + 可选的右侧按钮。三个板块共用,高度才统一。
///
/// 右侧那组按钮用 FittedBox 兜底:历史板块现在有三颗(选择/全选/删除),
/// 窄屏上放不下会整行溢出(flex 溢出会画黄黑条),放不下时按比例缩一点比溢出差。
class BoardHeader extends StatelessWidget {
  const BoardHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kBoardHeaderHeight,
      child: Row(
        children: [
          Text(
            title,
            style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
          ),
          if (trailing != null)
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: trailing,
              ),
            ),
        ],
      ),
    );
  }
}

/// 板块页外壳:标题行钉在顶上,只有下面的列表滚。
///
/// 三个板块的标题(解析/历史/设置)和历史上方那排「选择 / 全选 / 删除」原来都是
/// 列表的第一项,用户一滑就跟着走。现在它们挂在滚动区**外面**:不管列表滚到哪儿,
/// 标题和按钮都停在原处。
class BoardScrollView extends StatelessWidget {
  const BoardScrollView({
    super.key,
    required this.header,
    required this.children,
    this.bottomPadding = 120,
  });

  /// 顶上那行标题(带不带右侧按钮都行)。
  final Widget header;

  final List<Widget> children;

  /// 列表底部留白,给悬浮底栏让位。
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    // **这一层 RepaintBoundary 是性能件,别删。**
    //
    // 二级页返回时,下面这页要跟着转场动画平移回原位。没有紧贴内容的缓存层时,
    // 引擎只能每帧把整块板子(**七张超椭圆裁剪的半透明卡 + SVG 图标 + 文字 + 列表
    // 顶上那层整块 ShaderMask**)重新光栅化一遍 —— 真机上就是"一按返回就卡"。
    // 转场是纯平移(translate),包一层之后内容可以复用缓存纹理,只做合成。
    //
    // 为什么不是"反正上层已经有 RepaintBoundary 了":实测那条链上最近的边界在很上面
    // (和整屏背景、底栏混在一起),粒度太粗 —— 它自己的内容一脏就整块重画,轮不到
    // 引擎复用这块板子。见 test/board_fade_test.dart 里对列表的那条断言。
    //
    // 代价:多一层整屏大小的纹理(1080p 约 8MB) + 滚动时这一层照旧每帧重画(和加它之前
    // 一样,滚动本来就要重画列表)。net 只赚不赔。
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 边距跟着原来的列表内边距走(20 左右、kBoardHeaderTop 顶),标题的墨迹
          // 位置和改动前一模一样。
          Padding(
            padding: const EdgeInsets.fromLTRB(20, kBoardHeaderTop, 20, 0),
            child: header,
          ),
          const SizedBox(height: 18),
          Expanded(
            child: TopFadeListView(
              padding: EdgeInsets.fromLTRB(20, 0, 20, bottomPadding),
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶边淡出的滚动列表。
///
/// 列表顶边那一圈是渐变遮罩 —— 卡片滚上去时淡出,而不是被视口切一刀。遮罩的宽度
/// 跟着滚动量长:停在顶部时第一条记录是完整的,往下滑才逐渐淡,到 [fadeHeight] 封顶。
/// 遮罩从头到尾都挂着(不在滚动量为 0 时换 widget 类型):换类型会让 ListView 整棵
/// 重建,滚动位置和那些展开态、播放中的预览全跟着丢。
///
/// 三个板块页靠 [BoardScrollView] 用它;二级页(使用帮助及反馈)去掉顶栏图之后也
/// 直接用它 —— 那里第一次滚上去的卡片同样不该是一条硬边。
class TopFadeListView extends StatefulWidget {
  const TopFadeListView({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 120),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  /// 淡出带的满宽(逻辑px)。下滑超过它之后,卡片就在这 28px 里淡没。
  static const double fadeHeight = 28;

  @override
  State<TopFadeListView> createState() => _TopFadeListViewState();
}

class _TopFadeListViewState extends State<TopFadeListView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 只有遮罩这一层跟着滚动重建;列表通过 child 原样透传,不参与重建。
      animation: _controller,
      builder: (context, child) {
        final offset = _controller.hasClients ? _controller.offset : 0.0;
        // shaderCallback **必须**每次重建都是一个新的闭包。
        //
        // 写成 `shaderCallback: _fadeShader`(同一个实例方法的 tear-off)时,
        // 同一对象同一方法的两次 tear-off 在 Dart 里是 `==` 的,而
        // RenderShaderMask 的 setter 见「相等」就提前 return、不 markNeedsPaint。
        // 结果:遮罩只在首帧按 offset=0 画过一次,之后列表怎么滚都不再重算,
        // 卡片顶边就是那条被视口切出来的硬边(深浅两色都一样明显)。
        // 包一层闭包给出新的 callback 身份,遮罩才会跟着滚动重画。
        return ShaderMask(
          shaderCallback: (rect) => _fadeShader(rect, offset),
          blendMode: BlendMode.dstIn,
          child: child!,
        );
      },
      child: ListView(
        controller: _controller,
        physics: const ShortBounceScrollPhysics(),
        padding: widget.padding,
        children: widget.children,
      ),
    );
  }

  /// 顶边渐隐用的着色器。BlendMode.dstIn 只看 alpha:不透明的地方留内容,
  /// 透明的地方擦掉。
  ///
  /// 滚到顶(以及顶部回弹那一段 offset < 0)时给一块全不透明的遮罩 —— 等效于没有
  /// 遮罩,第一条记录是完整的。
  Shader _fadeShader(Rect rect, double offset) {
    final band = offset.clamp(0.0, TopFadeListView.fadeHeight);
    if (band <= 0) {
      return const LinearGradient(
        colors: [Color(0xFF000000), Color(0xFF000000)],
      ).createShader(rect);
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [Color(0x00000000), Color(0xFF000000)],
      stops: [0.0, (band / rect.height).clamp(0.0, 1.0)],
    ).createShader(rect);
  }
}

/// 淡底 + 图标 + 文字的胶囊按钮。历史页顶栏那排「选择 / 全选 / 删除」,
/// 和解析页「粘贴链接」卡右上角的「粘贴 / 清空」,共用这一颗。
///
/// 手写而不是 FilledButton:后者自带 48 的触控区,几颗并排会把标题行撑得比标题高一截。
/// 配色沿用首页那些次级按钮(淡底 + 强调色);[destructive] 的红只给「删除」这种。
class PillAction extends StatelessWidget {
  const PillAction({
    super.key,
    required this.asset,
    required this.label,
    required this.onTap,
    this.active = false,
    this.destructive = false,
  });

  /// 已经解析好的资源路径(用 [historyIcon] / [homeIcon] 拼)。
  final String asset;
  final String label;
  final VoidCallback? onTap;

  /// 选择模式开着时高亮这颗按钮。
  final bool active;

  /// 删除键用红字,和普通动作分开。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    final c = Palette.of(isDark);
    final Color color = destructive ? c.danger : c.accent;
    final Color foreground = enabled
        ? color
        : settingsPalette(isDark).secondary.withValues(alpha: 0.45);
    // 这两颗按钮不在玻璃卡里,得自己当 Material 宿主 —— PlainTap 是 InkWell,
    // 找不到 Material 祖先会直接断言失败。
    return Material(
      type: MaterialType.transparency,
      child: PlainTap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? color.withValues(alpha: isDark ? 0.26 : 0.14)
                : Palette.of(isDark).subtleFill,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              TintedSvgIcon(asset, size: 18, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

