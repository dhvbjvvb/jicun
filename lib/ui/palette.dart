import 'package:flutter/widgets.dart';

/// 界面用色。**深浅两档的每一个色号都写在这里**,界面代码只引用名字。
///
/// 之前这套映射散在好几个文件里:同一对 `isDark ? Color(0xFF5AA9FF) :
/// Color(0xFF1257C9)` 在 preview.dart 里抄了三遍、history.dart 又抄一遍;
/// `0x1FFFFFFF / 0x12000000` 这一对表面底色也是到处抄。于是"想加第三档
/// 主题(比如纯黑 OLED)"变成了改四十处 —— 而漏一处就是那一块不跟着变。
///
/// 用法:`final c = Palette.of(isDark);` 然后 `c.accent`。
///
/// **刻意只按深浅分档取,不看 context**:这些色号跟着的是 app 里手选的主题档
/// (见 HomeShellState.build 里那个 switch),不是系统亮度。从 context 里读
/// platformBrightness 会在"用户手动选了深色、系统是浅色"时取错。
class Palette {
  const Palette._({
    required this.isDark,
    required this.accent,
    required this.accentSoft,
    required this.danger,
    required this.surface,
    required this.surfaceClear,
    required this.foreground,
    required this.secondary,
    required this.scrim,
    required this.onScrim,
    required this.barBackground,
    required this.pageBackground,
    required this.skeleton,
    required this.avatar,
    required this.tileUnselected,
    required this.subtleFill,
    required this.playerGradient,
  });

  /// 按当前主题取一套。
  static Palette of(bool isDark) => isDark ? dark : light;

  final bool isDark;

  /// 强调色:选中的缩略图、进度、可点的图标。
  final Color accent;

  /// 强调色的浅底(选中态的填充)。
  final Color accentSoft;

  /// 出错的红色。
  final Color danger;

  /// 卡片/面板的表面色。
  final Color surface;

  /// 更淡的表面(叠在插画上的那种)。
  final Color surfaceClear;

  final Color foreground;
  final Color secondary;

  /// 图片查看器、视频底色那种压暗层。
  final Color scrim;
  final Color onScrim;

  /// 底栏 / 状态栏区域的底色。
  final Color barBackground;
  final Color pageBackground;

  /// 占位骨架。
  final Color skeleton;

  /// 头像占位。
  final Color avatar;

  /// 未选中的图集格子。
  final Color tileUnselected;

  /// 再淡一档的填充:禁用态的底、未选中的胶囊。
  final Color subtleFill;

  /// 播放器上的渐变。
  final List<Color> playerGradient;

  /// 一级列表与二级页共用的那两色。以前是 palette.dart 里唯一的东西,现在只是
  /// 一个转发 —— **新代码直接用 [Palette.of]**,别再调这个。
  static const Palette light = Palette._(
    isDark: false,
    accent: Color(0xFF1257C9),
    accentSoft: Color(0x141257C9),
    danger: Color(0xFFC0392B),
    surface: Color(0x12000000),
    surfaceClear: Color(0x0AFFFFFF),
    foreground: Color(0xFF1B2430),
    secondary: Color(0xFF6E7887),
    scrim: Color(0x8C000000),
    onScrim: Color(0xFFFFFFFF),
    barBackground: Color(0xE6F2F2F7),
    pageBackground: Color(0xFFCDDCDC),
    skeleton: Color(0x12000000),
    avatar: Color(0x1F000000),
    tileUnselected: Color(0x0F000000),
    subtleFill: Color(0x14000000),
    playerGradient: <Color>[Color(0x2E1677FF), Color(0x0A1677FF)],
  );

  static const Palette dark = Palette._(
    isDark: true,
    accent: Color(0xFF5AA9FF),
    accentSoft: Color(0x1F5AA9FF),
    danger: Color(0xFFFF7B72),
    surface: Color(0x1FFFFFFF),
    surfaceClear: Color(0x14000000),
    foreground: Color(0xFFF5F7FA),
    secondary: Color(0xFFADB7C5),
    scrim: Color(0x8C000000),
    onScrim: Color(0xFFFFFFFF),
    barBackground: Color(0xE61C1C1E),
    pageBackground: Color(0xFF434343),
    skeleton: Color(0x1FFFFFFF),
    avatar: Color(0x24FFFFFF),
    tileUnselected: Color(0x1FFFFFFF),
    subtleFill: Color(0x1FFFFFFF),
    playerGradient: <Color>[Color(0x3D2E6BD6), Color(0x14000000)],
  );
}

/// 旧接口的转发。一级列表与二级页以前只从 palette.dart 拿这两个色,现在整套色号
/// 都收进了 [Palette] —— 这个函数留着只是为了让还在用它的地方继续编译。
/// **新代码写 `Palette.of(isDark)`。**
({Color foreground, Color secondary}) settingsPalette(bool isDark) {
  final c = Palette.of(isDark);
  return (foreground: c.foreground, secondary: c.secondary);
}
