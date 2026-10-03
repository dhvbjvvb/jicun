import 'dart:async';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/app_background.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/ui/prefs.dart';

/// 「主题与外观」二级页,以及这一页上的三张卡,从 lib/pages/settings.dart 拆出来。
///
/// 主题模式、自定义背景、底栏外观、界面缩放这四样是同一件事的四个面(都写进
/// 偏好、都由根 State 落盘),拆开反而要来回 import,所以合成一个文件。

/// 「系统主题」卡:收起时只有一行(标题 + 当前值 + 向下箭头),点箭头向下滑出
/// 三个选项;选完自己回弹收起。
///
/// 展开态是纯界面状态,所以留在本组件里 —— 每次进二级页都从收起开始。
class ThemeModeCard extends StatefulWidget {
  const ThemeModeCard({super.key, required this.app, required this.isDark});

  final ShellController app;
  final bool isDark;

  @override
  State<ThemeModeCard> createState() => ThemeModeCardState();
}

class ThemeModeCardState extends State<ThemeModeCard> {
  static const List<(AppThemeMode, String)> _options = [
    (AppThemeMode.system, '跟随系统'),
    (AppThemeMode.light, '浅色'),
    (AppThemeMode.dark, '深色'),
  ];

  bool _expanded = false;

  String get _currentLabel =>
      _options.firstWhere((o) => o.$1 == widget.app.themeMode).$2;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  GoogleCardTitle(isDark: isDark, text: '系统主题'),
                  const Spacer(),
                  Text(
                    _currentLabel,
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: RadioGroup<AppThemeMode>(
                groupValue: widget.app.themeMode,
                onChanged: (mode) {
                  if (mode == null) return;
                  widget.app.applySetting(() => widget.app.themeMode = mode);
                  widget.app.syncNightModeToNative(mode);
                  // 选完缩回去,回到收起卡片
                  setState(() => _expanded = false);
                },
                child: Column(
                  children: [
                    for (final (mode, label) in _options)
                      GoogleChoiceRow<AppThemeMode>(
                        isDark: isDark,
                        value: mode,
                        label: label,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「设置 → 主题与外观」的二级页
class ThemeAppearancePage extends StatelessWidget {
  const ThemeAppearancePage({super.key, required this.app});

  final ShellController app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度。图是按屏宽等比缩的,所以这里也按屏宽算,
    // 两边同一个 kHeaderArtAspect,界面缩放下不会错位。
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    // 这张画面基本铺满画布,底边实测在 599/605 处。第一张卡从图底边往下 5dp 起。
    final headerBottom = headerHeight * 599 / 605;

    return SubPage(
      title: '主题与外观',
      // 一张图两种模式共用:不补轮廓光,所以深浅模式不需要两版。
      headerImage: 'assets/theme-header/theme_top.webp',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              ThemeModeCard(app: app, isDark: isDark),
              const SizedBox(height: 16),
              BarAppearanceCard(app: app, isDark: isDark),
              // 选图只有 Android 有原生实现(见 MainActivity.pickBackgroundImage),
              // 别的平台不摆这张卡,免得点了没反应。
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(height: 16),
                CustomBackgroundCard(app: app, isDark: isDark),
              ],
              const SizedBox(height: 16),
              UiScaleCard(app: app, isDark: isDark),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「自定义背景图」卡:展开后两个选项 —— 选图 / 还原默认。
///
/// 图只铺在三个板块页(解析 / 历史 / 设置);二级页不展示(见 [ThemeBackground] 的
/// imagePath)。选中的图由原生复制进应用目录,偏好里只存那条路径。
///
/// 只有 Android 有选图这条路(见 MainActivity.pickBackgroundImage),别的平台这张卡
/// 干脆不出现(见 ThemeAppearancePage)。
class CustomBackgroundCard extends StatefulWidget {
  const CustomBackgroundCard({super.key, required this.app, required this.isDark});

  final ShellController app;
  final bool isDark;

  @override
  State<CustomBackgroundCard> createState() => CustomBackgroundCardState();
}

class CustomBackgroundCardState extends State<CustomBackgroundCard> {
  bool _expanded = false;

  /// 选图界面开着时不再接第二次点击(它返回前用户可能连点)。
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await AppBackground.pick();
      // 用户取消:null,保持原样。
      if (!mounted || path == null) return;
      // 原生每次写的都是唯一文件名,旧图它自己会清;这里再按偏好里那条兜一次。
      // **路径相同就不动** —— 曾经固定文件名时,这一删正好把刚写好的新图删掉,
      // 背景要么不换、要么重启后打回默认。
      final previous = widget.app.customBackgroundPath;
      if (previous != path) AppBackground.removeFile(previous);
      widget.app.applySetting(() => widget.app.customBackgroundPath = path);
      if (mounted) setState(() => _expanded = false);
    } catch (error) {
      if (!mounted) return;
      showInfo(context, '没能用上这张图', '系统没把图片交回来:$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _reset() {
    AppBackground.removeFile(widget.app.customBackgroundPath);
    widget.app.applySetting(() => widget.app.customBackgroundPath = null);
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final app = widget.app;
    final secondary = settingsPalette(isDark).secondary;
    final custom = app.customBackgroundPath != null;
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  GoogleCardTitle(isDark: isDark, text: '自定义背景图'),
                  const Spacer(),
                  Text(
                    // 收起时这一行就是这张卡的「当前值」,和系统主题卡同一位置。
                    custom ? '已设置' : '默认',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Column(
              children: [
                BackgroundOptionRow(
                  isDark: isDark,
                  title: '选取相册中图片做背景',
                  subtitle: '从手机相册或文件管理里选一张,只作用于解析、历史、设置三个板块',
                  icon: CupertinoIcons.photo_on_rectangle,
                  enabled: !_picking,
                  onTap: _pick,
                ),
                BackgroundOptionRow(
                  isDark: isDark,
                  title: '还原默认背景图',
                  subtitle: '回到本 APP 原本的深色 / 浅色渐变背景',
                  icon: CupertinoIcons.arrow_counterclockwise,
                  enabled: custom,
                  onTap: _reset,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「自定义背景图」卡里的一行选项:标题 + 说明 + 右侧图标。整行可点,禁用时置灰。
class BackgroundOptionRow extends StatelessWidget {
  const BackgroundOptionRow({
    super.key,
    required this.isDark,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final bool isDark;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    final Color titleColor = enabled
        ? foreground
        : secondary.withValues(alpha: 0.5);
    return PlainTap(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
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
            const SizedBox(width: 10),
            Icon(
              icon,
              size: 20,
              color: enabled ? secondary : secondary.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「底栏外观样式」卡:两个开关都只作用于底栏,所以合成一张。
///
/// 展开/收起与「系统主题」卡同一套(收起时只留一行标题 + 当前样式 + 箭头,
/// 点开向下滑出,见 [Reveal])。
class BarAppearanceCard extends StatefulWidget {
  const BarAppearanceCard({super.key, required this.app, required this.isDark});

  final ShellController app;
  final bool isDark;

  @override
  State<BarAppearanceCard> createState() => BarAppearanceCardState();
}

class BarAppearanceCardState extends State<BarAppearanceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final app = widget.app;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  GoogleCardTitle(isDark: isDark, text: '底栏外观样式'),
                  const Spacer(),
                  Text(
                    // 收起时这一行就是这张卡的「当前值」:和系统主题卡同一位置
                    app.glassBottomBar ? '液态玻璃' : '渐变按钮',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Column(
              children: [
                GoogleSwitchRow(
                  isDark: isDark,
                  title: '底栏文字标识隐藏',
                  subtitle: '开启后隐藏底栏的解析、历史、设置文字',
                  value: app.hideTabLabels,
                  onChanged: (v) =>
                      app.applySetting(() => app.hideTabLabels = v),
                ),
                GoogleSwitchRow(
                  isDark: isDark,
                  title: 'Apple 底栏液态玻璃风格',
                  subtitle: '关闭后底栏取消液态玻璃,改用渐变按钮样式',
                  value: app.glassBottomBar,
                  onChanged: (v) =>
                      app.applySetting(() => app.glassBottomBar = v),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「界面缩放大小」卡。
///
/// 收起/展开与系统主题、底栏外观样式同一套;拖动中的值只存在这张卡自己的 State 里:
/// 每帧只重建这一小块,不惊动整棵树,所以滑杆跟手。松手(onChangeEnd)才把值交给
/// 根 State 去真正缩放并落盘 —— 缩放会让整屏按新尺寸重新布局,每帧都做必然拖不动。
class UiScaleCard extends StatefulWidget {
  const UiScaleCard({super.key, required this.app, required this.isDark});

  static const double min = 0.8;
  static const double max = 1.3;

  final ShellController app;
  final bool isDark;

  @override
  State<UiScaleCard> createState() => UiScaleCardState();
}

class UiScaleCardState extends State<UiScaleCard> {
  late double _draft = widget.app.uiScale;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = settingsPalette(isDark).secondary;
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  GoogleCardTitle(isDark: isDark, text: '界面缩放大小'),
                  const Spacer(),
                  Text(
                    '${(_draft * 100).round()}%',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderTheme(
                    // 拖动时不画把手的灰色光晕:压在玻璃卡上就是一团阴影
                    data: SliderTheme.of(context)
                        .copyWith(overlayShape: SliderComponentShape.noOverlay),
                    child: Slider(
                      value: _draft,
                      min: UiScaleCard.min,
                      max: UiScaleCard.max,
                      // 不设 divisions:刻度会让把手一格一格跳,手感发涩、不跟手
                      label: '${(_draft * 100).round()}%',
                      onChanged: (v) => setState(() => _draft = v),
                      onChangeEnd: (v) => widget.app.applySetting(
                        () => widget.app.uiScale = v,
                      ),
                    ),
                  ),
                  Text(
                    '拖动调整,松手应用',
                    style: TextStyle(color: secondary, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
