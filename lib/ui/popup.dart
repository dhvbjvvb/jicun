// 弹层的外壳与共用件:玻璃面板骨架([PopupShell])、弹层路由([GlassDialogRoute])、
// 主/次按钮,以及最常用的两个入口([showGlassLayer] / [showGlassDialog])。
//
// **这里只放外壳与共用件**。具体弹层在各自文件里,要用就直接 import 那个文件:
// 下载进度卡 `download_progress_card.dart`、版本更新卡 `update_card.dart`、
// 清晰度选择 `quality_picker.dart`、波浪进度环 `progress_ring.dart`。
//
// (曾经在这里 `export` 那四个文件,好让拆分时不必改几十个调用点。拆分做完、
// 验证过之后就把转发撤了 —— 一个符号只留一条 import 路径,顺手也解掉
// "外壳导出卡片、卡片又 import 外壳"那个环。)

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';



/// 普通提示卡的面板最大宽度。
///
/// 提成常量是因为它不只管布局:更新说明那个固定 12 行的窗口要按**面板实际能给的宽度**
/// 量行数(见 update_card.dart 的 `ReleaseNotesPreview._measure`)—— 面板被这个值卡住,
/// 而屏幕可以更宽;量行数时按屏幕算就会少算(实测 412dp 的机器上差四分之一,于是
/// 13~16 行的说明被判成"不超 12 行",滚动条不挂、多出来的字画到按钮上)。
const double kPopupPanelMaxWidth = 300;

/// 所有弹层的统一外壳:糊一层背景 + 玻璃面板 + 头部一行。
///
/// 四张弹层卡(媒体下载进度、版本更新、更新包下载、提示与授权)原来各自抄了一遍这段
/// 骨架,抄着抄着就分了家:提示弹窗没铺底色、标题居中、主按钮自己的配色,
/// 「需要安装权限」更是直接用了 CupertinoAlertDialog(iOS 灰底 + 细分割线),搁在满屏
/// 毛玻璃里像另一个 APP 的弹窗。统一走这里之后,弹层之间不可能再走样。
class PopupShell extends StatelessWidget {
  const PopupShell({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.onClose,
    this.maxWidth = kPopupPanelMaxWidth,
  });

  final String title;

  /// 完整资源路径(用 [settingsIcon] / [popupIcon] 拼)。
  final String icon;

  /// 头部右侧的关闭叉。null = 不给叉:必须点下面的按钮才能走。
  final VoidCallback? onClose;

  /// 面板最大宽度。普通提示卡 300 够用;大图预览要更宽,见 [ImageViewerDialog]。
  final double maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: const ColoredBox(color: Color(0x00000000)),
          ),
        ),
        Padding(
          // 底部留一点,弹层贴着屏幕边缘不好看
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              // 玻璃面板**不自己铺底**:它直接透过上面那层模糊采样页面本身。
              //
              // 原来这里铺了一整屏 ThemeBackground(为了和页面同色),结果是两件事
              // 一起坏:
              // 1. 割裂 —— 卡片里透出来的是"重新画了一遍、没被糊过"的渐变,而卡片
              //    外面是被模糊+压暗的页面,同一屏两套明度,边上就是一条缝;
              // 2. 白花帧 —— 浅色模式那层是 LightThemeBackgroundPainter:整屏三次
              //    drawRect,带 BlendMode.overlay / screen 和一个径向渐变。它叠在
              //    12 sigma 的整屏模糊底下,弹层每帧都要重算一遍,换来的只是上面
              //    那条缝。
              //
              // 弹层底下本来就只有页面自己,方向键上下滚也不会跑到别的地方去,
              // 所以直接采样即可 —— GlassPanel 本来就没有铺底这个参数,弹层的
              // 调用方也都不自己铺垫。
              child: GlassPanel(
                isDark: isDark,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          TintedSvgIcon(icon, size: 20, color: foreground),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (onClose != null)
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(28, 28),
                              onPressed: onClose,
                              child: Icon(
                                CupertinoIcons.xmark,
                                size: 18,
                                color: secondary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹层淡入的时长。
///
/// 系统那条(`showCupertinoDialog`)是 250ms 起步的弹簧。点一下就开的东西不该等
/// 半拍 —— 尤其点图片缩略图那只眼睛的时候,眼睛是个小目标,点完视线立刻落在弹层上。
const Duration kGlassDialogFade = Duration(milliseconds: 180);

/// 玻璃弹层走的路由。
///
/// 和 `showCupertinoDialog` 用的那条比,只动时间:
///
/// - **遮蔽先到位**。系统那条路由把遮蔽和面板绑在同一条动画上,遮蔽的曲线是
///   `Curves.ease` —— 走到后半程还剩一截,面板已经压上来了、身后那片变暗还在慢慢爬,
///   看着就是"遮蔽慢半拍"。这里让它在前 40% 就铺满(180ms 的动画里约 70ms),
///   面板还在淡入时后面已经黑透了。
/// - 整个入场短一档,见 [kGlassDialogFade]。
class GlassDialogRoute<T> extends RawDialogRoute<T> {
  GlassDialogRoute({required WidgetBuilder builder, required Color barrierColor})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        barrierColor: barrierColor,
        barrierDismissible: true,
        // 点背景也是关掉的一条路,这句是读屏要念的
        barrierLabel: '关闭',
        transitionDuration: kGlassDialogFade,
        transitionBuilder: (context, animation, _, child) => FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
          child: child,
        ),
      );

  /// 遮蔽在动画的前这么多(0~1)铺满,不跟着面板慢慢爬。
  static const double barrierLead = 0.4;

  @override
  Curve get barrierCurve => const Interval(0, barrierLead, curve: Curves.easeOut);
}

/// 开一块玻璃弹层。全 App 的弹层都走这一条 —— 骨架是 [PopupShell],路由见
/// [GlassDialogRoute]。
///
/// 挂 root navigator(和 [showCupertinoDialog] 一样):弹层要盖住玻璃底栏,挂在
/// 当前页的 navigator 上会从底栏底下钻出来。
Future<T?> showGlassLayer<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    GlassDialogRoute<T>(
      builder: builder,
      // 系统那条用的同一个遮罩色:浅色 20% 黑、深色 48% 黑,跟着当前主题走
      barrierColor: CupertinoDynamicColor.resolve(
        kCupertinoModalBarrierColor,
        context,
      ),
    ),
  );
}

/// 弹层里的主按钮(确认 / 更新 / 一键授权 / 完成 / 取消)。
///
/// 颜色不取 ColorScheme:弹层挂在 CupertinoApp 那棵树下面,拿不到二级页的种子色,
/// 每个弹窗各写一遍 styleFrom 又必然走样 —— 所以整条配色只留这一份。
class PopupPrimaryButton extends StatelessWidget {
  const PopupPrimaryButton({super.key, required this.label, required this.onPressed});

  final String label;
  /// 传 null 就是禁用态(FilledButton 自己会画成灰的,点不动)。下载卡在「取消已经
  /// 下发、还没收尾」的那几秒用它,免得留一颗看着能按、按下去没反应的死按钮。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        // 深色档 0x1FFFFFFF 正好是 Palette 的 subtleFill,但浅色档要的是 accent 的
        // 8% 底(0x141257C9),那一对不是同一组色 —— 硬套会改掉这颗按钮的底。
        backgroundColor: isDark
            ? const Color(0x1FFFFFFF)
            : const Color(0x141257C9),
        foregroundColor: Palette.of(isDark).accent,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹层里的次按钮(忽略 / 稍后)。和主按钮并排时放右边。
class PopupSecondaryButton extends StatelessWidget {
  const PopupSecondaryButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        foregroundColor: secondary,
        side: BorderSide(color: secondary.withValues(alpha: 0.35)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹一句提示用的玻璃卡。
///
/// 骨架就是 [PopupShell]:和「版本更新」「下载进度」同一块面板、同一行头部,所以
/// 检查更新的回音和更新卡摆在一起不会像两个 APP。
///
/// 返回值:点了主按钮为真,点了右上角的叉为假。
Future<bool> showGlassDialog(
  BuildContext context, {
  required String title,
  required String body,
  String? icon,
  String primaryLabel = '知道了',
}) async {
  final result = await showGlassLayer<bool>(
    context,
    builder: (context) => AppGlassDialog(
      title: title,
      body: body,
      icon: icon,
      primaryLabel: primaryLabel,
    ),
  );
  return result ?? false;
}

/// 统一的轻提示。内容是 [AppGlassDialog],弹层的路由与遮罩见 [GlassDialogRoute]。
void showInfo(
  BuildContext context,
  String title,
  String body, {
  String? icon,
}) {
  unawaited(showGlassDialog(context, title: title, body: body, icon: icon));
}

class AppGlassDialog extends StatelessWidget {
  const AppGlassDialog({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    this.icon,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground = settingsPalette(isDark).foreground;
    return PopupShell(
      title: title,
      // 没点名要哪张图就用「检查更新」:用上这个弹窗的地方多半和检查更新有关
      icon: icon ?? settingsIcon(context, '检查更新.svg'),
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            body,
            style: TextStyle(color: foreground, fontSize: 13.5, height: 1.45),
          ),
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: primaryLabel,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}
