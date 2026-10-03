import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/ui/widgets.dart';
import 'package:jicun/update_service.dart';
import 'package:jicun/ui/about_page.dart';
import 'package:jicun/ui/auto_paste_page.dart';
import 'package:jicun/ui/help_feedback_page.dart';
import 'package:jicun/ui/notification_management_page.dart';
import 'package:jicun/ui/sponsor_page.dart';
import 'package:jicun/ui/theme_appearance_page.dart';

/// 设置板块的**索引页**,以及它用的那两个小组件。
///
/// 这个文件原来是 1737 行 —— 七个二级页和它们的卡片全挤在这里。现在二级页各自
/// 搬去 lib/ui/ 下自己的文件,这里只剩下:
///   - 索引页本身 —— [SettingsPage];
///   - 一行选项的数据 —— [SettingsOption];
///   - 它的渲染 —— [SettingsOptionCard]。
///
/// 加一个二级页 = 在 [_options] 里加一行 + 在 lib/ui/ 下写那个页;这张表不再需要
/// 翻过一千多行去看别的页怎么写的。

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});

  /// 二级页要改的是应用级状态(主题、底栏),所以直接持有根 State。
  final ShellController app;

  /// 设置页那份入口清单。
  ///
  /// 「检查更新」只在 Android 上有:发布出去的资产是 APK,靠系统安装器装,桌面端
  /// 没有这条路。留着它,桌面用户点下去会下完一个 20MB 的包装不上,再收到一句
  /// "请在系统设置里允许安装应用" —— 所以整个入口不显示(见 update_service.dart 的
  /// `updateSupported`)。
  static List<SettingsOption> get _options => <SettingsOption>[
    const SettingsOption('主题与外观', '修改主题，底栏效果，自定义背景图'),
    const SettingsOption('通知管理与下载', '管理通知，自定义存储位置', icon: '通知管理'),
    // 图标用解析页那张「粘贴」:这一项干的就是粘贴,别再借通知管理那张。
    const SettingsOption('自动粘贴并解析', '剪贴板首条链接自动解析', icon: '粘贴'),
    if (updateSupported)
      const SettingsOption('检查更新', '点击检查最新版本', showChevron: false),
    const SettingsOption('使用帮助及反馈', '看APP支持范围及类别，反馈问题渠道', icon: '帮助及联系反馈'),
    const SettingsOption('关于本APP', '开源地址，彩蛋（自行摸索），免责声明'),
    const SettingsOption('赞助名单', '为本项目提供支持的吴彦祖和刘亦菲', icon: '赞助名单'),
  ];

  @override
  Widget build(BuildContext context) {
    // 取一次:下面既要遍历又要拿长度,getter 每次都会重建一份。
    final options = _options;
    // 「检查更新」那颗按钮的忙碌态来自根壳的 UpdateCoordinator.busy(一个
    // ValueListenable)。只包一层 ListenableBuilder,不把整页都挂上去:那一页
    // 里还有平台卡、彩蛋这些和更新无关的东西。
    return BoardScrollView(
      header: const BoardHeader(title: '设置'),
      children: [
        ...options.asMap().entries.map(
          (entry) => Padding(
            padding: EdgeInsets.only(
              bottom: entry.key == options.length - 1 ? 0 : 12,
            ),
            child: entry.value.title == '检查更新'
                // 检查更新要打网络,慢的时候好几秒;转个圈至少让人知道点到了
                ? ValueListenableBuilder<bool>(
                    valueListenable: app.checkingUpdate,
                    builder: (context, busy, _) => SettingsOptionCard(
                      option: entry.value,
                      busy: busy,
                      onPressed: () =>
                          _handleOption(context, entry.value.title),
                    ),
                  )
                : SettingsOptionCard(
                    option: entry.value,
                    onPressed: () => _handleOption(context, entry.value.title),
                  ),
          ),
        ),
      ],
    );
  }

  void _handleOption(BuildContext context, String title) {
    if (title == '检查更新') {
      // 手动检查:没新版、被忽略过、检查失败都要给个回音 —— 用户是主动点的,
      // 什么都不弹会让人以为按钮坏了(见 checkForUpdate 的 manual 参数)。
      app.checkForUpdate(manual: true);
      return;
    }

    if (title == '主题与外观') {
      Navigator.of(
        context,
      ).push(SubPageRoute<void>(builder: (_) => ThemeAppearancePage(app: app)));
      return;
    }

    if (title == '通知管理与下载') {
      Navigator.of(context).push(
        SubPageRoute<void>(
          builder: (_) => NotificationManagementPage(app: app),
        ),
      );
      return;
    }

    if (title == '自动粘贴并解析') {
      Navigator.of(context)
          .push(SubPageRoute<void>(builder: (_) => AutoPastePage(app: app)));
      return;
    }

    if (title == '使用帮助及反馈') {
      Navigator.of(context)
          .push(SubPageRoute<void>(builder: (_) => const HelpFeedbackPage()));
      return;
    }

    if (title == '关于本APP') {
      Navigator.of(context)
          .push(SubPageRoute<void>(builder: (_) => const AboutAppPage()));
      return;
    }

    if (title == '赞助名单') {
      Navigator.of(context)
          .push(SubPageRoute<void>(builder: (_) => const SponsorPage()));
      return;
    }

    // 兜底:以后在 _options 里加一项却忘了给它接二级页,点下去就是这句话。
    // 现在这七项各自都有去处,所以这条暂时到不了(上一版注释写的是「只有『使用帮助及
    // 反馈』到得了」,而那一项在上面就 return 了)。
    showInfo(context, title, '该设置项将在后续版本开放。');
  }
}

class SettingsOption {
  const SettingsOption(
    this.title,
    this.subtitle, {
    this.icon,
    this.showChevron = true,
  });

  final String title;
  final String subtitle;

  /// 右侧箭头。false 用于没有二级页、点一下就地生效的条目(检查更新)。
  final bool showChevron;

  /// 图标文件名(不含扩展名)。不填就拿标题当文件名。
  ///
  /// 单独留一个字段,是为了「改文案不用跟着改资源名」——图标是按旧标题命名的,
  /// 文案一改,靠标题拼路径就找不到图了。
  final String? icon;
}

class SettingsOptionCard extends StatelessWidget {
  const SettingsOptionCard({
    super.key,
    required this.option,
    required this.onPressed,
    this.busy = false,
  });

  final SettingsOption option;
  final VoidCallback onPressed;

  /// 这一项正在办事(目前只有「检查更新」)。为真时右侧显示转圈并挡住重复点击 ——
  /// 检查更新要打网络,慢的时候好几秒才有回音,不给任何动静就像按钮坏了。
  final bool busy;

  String _iconPath(BuildContext context) =>
      settingsIcon(context, '${option.icon ?? option.title}.svg');

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;

    // 手写模糊面板。库的 GlassCard 无论走着色器路径、还是嵌套时的 vibrancy fill
    // 路径,都会在边界画一道高光:实测上沿 1 设备像素亮线(76 vs 内部 12),
    // 左沿 68 vs 内部 14,且 lightIntensity / fresnelStrength / useOwnLayer
    // 都关不掉。既然只要模糊,就自己拼,不再和库的着色器纠缠。
    final content = CupertinoButton(
      // 原来 18/18/16/18 + 50px 圆角块 = 86px 高,圆角块比右侧文字块还高,
      // 视觉上被图标块主导。收紧到 68px,让文字块重新成为主体。
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      onPressed: busy ? null : onPressed,
      pressedOpacity: 0.72,
      child: Row(
        children: [
          // 尺寸 20 而非资源的 24:图形在 24x24 画布里没有留白,
          // 按 24 渲染会顶满圆角块,20 才是正常呼吸感。
          GlassIconChip(isDark: isDark, asset: _iconPath(context)),
          const SizedBox(width: 14),
          Expanded(
            child: CardHeadline(
              isDark: isDark,
              title: option.title,
              subtitle: option.subtitle,
            ),
          ),
          if (busy) ...[
            const SizedBox(width: 8),
            // 用文字而不是转圈:转圈是**无限动画**,页面就再也 pumpAndSettle 不了
            // (用例里实测直接超时)。文字同样是"点到了、正在办"的回音,还不花帧。
            Text(
              '检查中…',
              style: TextStyle(
                color: secondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (option.showChevron) ...[
            const SizedBox(width: 8),
            Icon(CupertinoIcons.chevron_forward, color: secondary, size: 17),
          ],
        ],
      ),
    );

    return GlassPanel(isDark: isDark, child: content);
  }
}
