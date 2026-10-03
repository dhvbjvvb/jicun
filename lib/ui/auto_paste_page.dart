
import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/motion.dart';

/// 「自动粘贴并解析」二级页,从 lib/pages/settings.dart 拆出来。

/// 「设置 → 自动粘贴并解析」的二级页。
///
/// 只有一张开关卡,样式与「通知管理与下载」页同一套
/// (GlassPanel + GoogleSwitchRow,同一张顶栏图):打开后,每次进入 APP
/// 都会把剪贴板首条链接自动填进输入栏并解析(见 `_maybeAutoPasteParse`)。
class AutoPastePage extends StatelessWidget {
  const AutoPastePage({super.key, required this.app});

  final ShellController app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    final headerBottom = headerHeight * 564 / 605;

    return SubPage(
      title: '自动粘贴并解析',
      headerImage: 'assets/theme-header/theme_top_2.webp',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              GlassPanel(
                isDark: isDark,
                child: GoogleSwitchRow(
                  isDark: isDark,
                  title: '进入APP自动粘贴并解析首条链接',
                  subtitle: '从其他平台复制链接后,打开即自动解析',
                  value: app.autoPasteParse,
                  onChanged: (value) => app.applySetting(
                    () => app.autoPasteParse = value,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
