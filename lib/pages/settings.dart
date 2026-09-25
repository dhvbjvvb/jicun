import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/ui/widgets.dart';
import 'package:jicun/widgets/tap_easter_egg.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});

  /// 二级页要改的是应用级状态(主题、底栏),所以直接持有根 State。
  final HomeShellState app;

  static const _options = <SettingsOption>[
    SettingsOption('主题与外观', '修改主题、显示效果'),
    SettingsOption('通知管理与下载', '通知管理与存储位置', icon: '通知管理'),
    SettingsOption('自动粘贴并解析', '剪贴板首条链接自动解析', icon: '通知管理'),
    // 检查更新是当场就办事的,没有下一级页面,所以不给箭头。
    SettingsOption('检查更新', '点击检查最新版本', showChevron: false),
    SettingsOption('使用帮助及反馈', '查看使用帮助或提交反馈', icon: '帮助及联系反馈'),
    SettingsOption('关于本APP', '开源地址、彩蛋出席'),
    SettingsOption('彩蛋提示', '看看APP里藏了什么'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, kBoardHeaderTop, 20, 120),
      children: [
        const BoardHeader(title: '设置'),
        const SizedBox(height: 18),
        ..._options.asMap().entries.map(
          (entry) => Padding(
            padding: EdgeInsets.only(
              bottom: entry.key == _options.length - 1 ? 0 : 12,
            ),
            child: SettingsOptionCard(
              option: entry.value,
              // 检查更新要打网络,慢的时候好几秒;转个圈至少让人知道点到了
              busy: entry.value.title == '检查更新' && app.checkingUpdate,
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
      Navigator.of(context).push(
        SubPageRoute<void>(builder: (_) => ThemeAppearancePage(app: app)),
      );
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
      Navigator.of(context).push(
        SubPageRoute<void>(builder: (_) => AutoPastePage(app: app)),
      );
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

    if (title == '彩蛋提示') {
      Navigator.of(context)
          .push(SubPageRoute<void>(builder: (_) => const EasterEggHintPage()));
      return;
    }

    // 这个分支目前只有「使用帮助及反馈」到得了,但别处加一项没做二级页的设置就是它
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

class NotificationManagementPage extends StatefulWidget {
  const NotificationManagementPage({super.key, required this.app});

  /// 这两个开关下载流程要用,所以和「主题与外观」一样直接持有根 State。
  final HomeShellState app;

  @override
  State<NotificationManagementPage> createState() =>
      NotificationManagementPageState();
}

class NotificationManagementPageState
    extends State<NotificationManagementPage> {
  bool _isSending = false;

  HomeShellState get app => widget.app;

  /// 要一次通知权限。和首次授权卡走同一个实现,免得两处判断分家。
  Future<bool> _requestPermission() => requestNotificationPermission();

  /// 拨一个下载通知开关。
  ///
  /// 打开前先要系统通知权限:没权限就别把开关点亮 —— 点亮了却弹不出通知,
  /// 用户只会以为是我们没做。关闭不需要权限,直接写。
  Future<void> _setNotify({required bool onDone, required bool value}) async {
    if (value) {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
    }
    app.applySetting(() {
      if (onDone) {
        app.notifyDownloadDone = value;
      } else {
        app.notifyDownloadFailed = value;
      }
    });
  }

  Future<void> _sendTestNotification() async {
    setState(() => _isSending = true);
    try {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
      final ready = notificationsReady;
      if (ready != null) await ready;
      await notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
        title: '即存通知测试',
        body: '通知功能运行正常。',
        notificationDetails: kNotificationDetails,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度。图按屏宽等比缩,所以这里也按屏宽算,
    // 两边同一个 kHeaderArtAspect,界面缩放下不会错位。
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    // 画面底边在画布 564/605 处(实测 bbox;画布下方那段是透明的),
    // 第一张卡从图底边往下 5dp 起。
    final headerBottom = headerHeight * 564 / 605;

    return SubPage(
      title: '通知管理与下载',
      // 抠好的插画带一圈白描边:深色模式下靠它把角色从背景里拎出来,
      // 浅色模式下描边和背景同色等于隐形,所以深浅两模式共用这一张。
      headerImage: 'assets/theme-header/theme_top_2.png',
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
                  title: '下载完成通知',
                  subtitle: '下载成功后,在系统状态栏提醒一声',
                  value: app.notifyDownloadDone,
                  onChanged: (value) => _setNotify(onDone: true, value: value),
                ),
              ),
              const SizedBox(height: 12),
              GlassPanel(
                isDark: isDark,
                child: GoogleSwitchRow(
                  isDark: isDark,
                  title: '下载失败通知',
                  subtitle: '下载中断或出错时提醒,免得白等',
                  value: app.notifyDownloadFailed,
                  onChanged: (value) => _setNotify(onDone: false, value: value),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _isSending ? null : _sendTestNotification,
                child: Text(_isSending ? '发送中…' : '测试通知'),
              ),
              const SizedBox(height: 24),
              StorageLocationCard(isDark: isDark),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「设置 → 自动粘贴并解析」的二级页。
///
/// 只有一张开关卡,样式与「通知管理与下载」页同一套
/// (GlassPanel + GoogleSwitchRow,同一张顶栏图):打开后,每次进入 APP
/// 都会把剪贴板首条链接自动填进输入栏并解析(见 `_maybeAutoPasteParse`)。
class AutoPastePage extends StatelessWidget {
  const AutoPastePage({super.key, required this.app});

  final HomeShellState app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    final headerBottom = headerHeight * 564 / 605;

    return SubPage(
      title: '自动粘贴并解析',
      headerImage: 'assets/theme-header/theme_top_2.png',
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

/// 「存储保存位置」卡。
///
/// 直接摊开,不做伸缩:只有三行,而且用户来这儿就是想知道文件去哪了,不该再点一下。
/// 路径由 Android 侧的媒体库归档决定(见 MainActivity 的 `ROOT` 与 `kindOf`),
/// 这里只做告知,不提供修改 —— 换目录得同时改 Kotlin 那套 MediaStore 映射、
/// [MediaKind] 里的展示路径和这张卡,不是切个开关的事。
///
/// 两边必须一字不差:这里写 Movies/Jicun/Video,那边就得真存到那儿,否则这页就是
/// 在骗用户(上一版就是:显示 Download/Jicun/*,实际存 Movies/JICUN、Pictures/Pictures)。
class StorageLocationCard extends StatelessWidget {
  const StorageLocationCard({super.key, required this.isDark});

  final bool isDark;

  static const _rows = <(String, String)>[
    ('视频 / 实况', 'Movies/Jicun/Video'),
    ('图片', 'Pictures/Jicun/Picture'),
    ('音频', 'Music/Jicun/Music'),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: GoogleCardTitle(isDark: isDark, text: '存储保存位置'),
          ),
          for (final (label, path) in _rows)
            GoogleValueRow(isDark: isDark, label: label, value: path),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// 一个平台的卡片要显示的四样东西。
///
/// [contents] 是「支持解析的内容」,原样列出上游真能给的媒体类型 —— 别为了好看
/// 往里加:这张卡就是用户拿去对「为什么这条解析不出来」的凭据,写多了等于骗人。
/// 上游能力见 parse_service.dart 的平台枚举与各家实测注释。
///
/// [tutorial] 卡里默认收起,点一下才滑出来(见 [Reveal])。
class PlatformCardInfo {
  const PlatformCardInfo(
    this.name,
    this.asset,
    this.contents, {
    this.tutorial = '复制 App 内的分享链接,回到本 APP 粘贴解析即可',
  });

  final String name;

  /// assets/platform-icons/ 下的图标文件名。由 tool/fetch_platform_icons.py 从
  /// App Store 直接拉,改版了重跑那个脚本就能跟上。
  final String asset;

  final String contents;
  final String tutorial;
}

/// 支持解析的平台清单,顺序就是页面里的卡片顺序。
///
/// 图标:「微信公众号」和「微信视频号」都用微信那张 —— 视频号没有独立 App,
/// 商店里也没有单独的图标,拿别的图顶上反而认不出来(见 PLATFORMS 的注释)。
///
/// 教程只有豆包那句不一样:它分享的是对话,不是帖子,写「分享链接」会让人去找
/// 一条根本不存在的分享按钮。
const List<PlatformCardInfo> kPlatforms = [
  PlatformCardInfo('今日头条', 'toutiao.png', '视频、图片、文章'),
  PlatformCardInfo('快手', 'kuaishou.png', '视频、图片、实况、文案'),
  PlatformCardInfo('抖音', 'douyin.png', '视频、图片、实况、文案'),
  PlatformCardInfo('微信公众号', 'wechat.png', '视频、图片、文章'),
  PlatformCardInfo('微信视频号', 'wechat_channels.png', '视频'),
  PlatformCardInfo('小红书', 'xiaohongshu.png', '视频、图片、实况、文案'),
  PlatformCardInfo('汽水音乐', 'qishui.png', '仅免费音乐'),
  PlatformCardInfo(
    '豆包',
    'doubao.png',
    '无水印图片、无水印视频',
    tutorial: '复制对话分享链接,回到本 APP 粘贴解析即可',
  ),
  PlatformCardInfo('哔哩哔哩', 'bilibili.png', '有水印视频'),
  PlatformCardInfo('微博', 'weibo.png', '图文、视频、实况'),
  PlatformCardInfo('央视频', 'yangshipin.png', '视频'),
  PlatformCardInfo('皮皮搞笑', 'pipigaoxiao.png', '视频、图片、文案'),
  PlatformCardInfo('皮皮虾', 'pipixia.png', '视频、图片、文案'),
  PlatformCardInfo('最右', 'zuiyou.png', '视频、图片、实况、文案'),
  PlatformCardInfo('红果短剧', 'hongguoduanju.png', '视频'),
  PlatformCardInfo('红果漫剧', 'hongguomanju.png', '视频'),
  PlatformCardInfo('好看视频', 'haokan.png', '视频'),
  PlatformCardInfo('西瓜视频', 'xigua.png', '视频'),
];

/// 「设置 → 使用帮助及反馈」的二级页。
///
/// 第一张是反馈渠道,第二张起一个平台一张伸缩卡。
class HelpFeedbackPage extends StatelessWidget {
  const HelpFeedbackPage({super.key});

  /// 图里那排角色离标题太远,整张图往上抬这么多,让脑袋贴到标题下面。
  static const double _headerLift = 24;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度,和别的二级页同一条算式。
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    // 画面底边在画布 484/605 处(落点 y=40 + 画面高 444,实测 bbox)。图被抬高了
    // _headerLift,所以卡片位置也跟着减掉同样的值,间距仍是 5dp。
    final headerBottom = headerHeight * 484 / 605 - _headerLift;

    return SubPage(
      title: '使用帮助及反馈',
      // 原图直接按比例缩进画布:居中、四周 52px 留白、不加白描边、整体上移
      // (--top 40)。复现命令见 tool/make_header_art.py --margin 52 --outline 0。
      headerImage: 'assets/theme-header/theme_top_4.png',
      headerLift: _headerLift,
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              FeedbackChannelsCard(isDark: isDark),
              for (final platform in kPlatforms) ...[
                const SizedBox(height: 16),
                PlatformCard(isDark: isDark, info: platform),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「反馈渠道」卡。摊开不伸缩:只有两行,而且是这页最想看的东西,
/// 不该再点一下才给(同 [StorageLocationCard] 的理由)。
class FeedbackChannelsCard extends StatelessWidget {
  const FeedbackChannelsCard({super.key, required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 14, 8),
            child: GoogleCardTitle(isDark: isDark, text: '反馈渠道'),
          ),
          CopyableRow(
            isDark: isDark,
            label: 'QQ群',
            value: '1124541108',
            hint: '点击即可复制',
          ),
          CopyableRow(
            isDark: isDark,
            label: 'QQ邮箱',
            value: '1515068599@qq.com',
            hint: '点击即可复制',
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

/// 「标签 + 可复制值」。整行点一下就进剪贴板,右边那句说明为什么要复制。
///
/// 反馈渠道是号码/邮箱,用户没法从卡片上直接选中复制,所以整行当按钮用;
/// 点了弹一句回音 —— 复制成功在这张卡上看不出任何变化,不给回音就像没点到。
class CopyableRow extends StatelessWidget {
  const CopyableRow({
    super.key,
    required this.isDark,
    required this.label,
    required this.value,
    required this.hint,
  });

  final bool isDark;
  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return PlainTap(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        // 和「复制文案」同一个回音弹窗,全 APP 一套
        showInfo(context, '已复制', '$label:$value');
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Row(
          children: [
            Text(label, style: TextStyle(color: foreground, fontSize: 15)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  color: secondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(hint, style: TextStyle(color: secondary, fontSize: 11.5)),
            const SizedBox(width: 6),
            Icon(CupertinoIcons.doc_on_doc, size: 16, color: secondary),
          ],
        ),
      ),
    );
  }
}

/// 一张平台卡:左边商店图标,右边平台名 + 支持解析的内容,点开滑出教程。
///
/// 伸缩(时长、曲线、箭头)与「主题与外观」那三张卡共用 [Reveal] / [RevealChevron],
/// 手感一致。
class PlatformCard extends StatefulWidget {
  const PlatformCard({super.key, required this.isDark, required this.info});

  final bool isDark;
  final PlatformCardInfo info;

  @override
  State<PlatformCard> createState() => PlatformCardState();
}

class PlatformCardState extends State<PlatformCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final info = widget.info;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              // 左边 18 和标题行对齐;右边 14 留给箭头自己的视觉留白
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
              child: Row(
                children: [
                  PlatformIcon(asset: info.asset),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          style: TextStyle(
                            color: settingsPalette(isDark).foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          info.contents,
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
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          // 挂个 key 是为了测试能直接量这一块的高度:里面的 Text 被裁掉之后
          // 自己的 RenderBox 还是原尺寸,量不到「收起=0」。
          KeyedSubtree(
            key: ValueKey('platformTutorial.${info.name}'),
            child: Reveal(
              expanded: _expanded,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Text(
                  '教程:${info.tutorial}',
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 平台图标:商店原图是方形满幅的,套一个超椭圆外形才和卡片的转角一个路数。
///
/// 底下一层极淡的色块只是兜底:图标自己有底色,正常情况下看不见;万一某张图
/// 拉失败(errorBuilder 给空盒子),这一层就当占位,卡片不会塌下去。
class PlatformIcon extends StatelessWidget {
  const PlatformIcon({super.key, required this.asset});

  final String asset;

  /// 画多大。和 [GoogleSwitchRow] 的行高同量级,不至于把卡片撑高。
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final shape = LiquidRoundedSuperellipse(borderRadius: _size * 0.3);
    return SizedBox(
      width: _size,
      height: _size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x0F000000),
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Image.asset(
            'assets/platform-icons/$asset',
            fit: BoxFit.cover,
            // 图标缺失不该把整页拖垮:留个占位块,卡片其它信息照常显示
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// 「关于本APP」上的开源仓库地址。
///
/// 要和 update_service.dart 里的 [kRepoOwner] / [kRepoName] 对得上 —— 那边是
/// 检查更新实际去打的仓库,这里写错就是让人去一个不存在的地方看源码。
const String kRepoUrl = 'https://github.com/dhvbjvvb/jicun';

/// 「设置 → 关于本APP」的二级页。
///
/// 四张一行卡 + 右下角那个彩蛋。
class AboutAppPage extends StatelessWidget {
  const AboutAppPage({super.key});

  /// 和「使用帮助及反馈」同一套摆法:图往上抬一截,角色贴到标题下面。
  static const double _headerLift = 24;

  /// 这张顶栏图自己的宽高比。插画本体是 1672x941,比画布 [kHeaderArtAspect]
  /// 宽得多:按画布比例画,角色会缩掉一大圈,所以照它自己的比例来。
  static const double _headerAspect = 1672 / 941;

  /// 彩蛋素材。静图就是动图的第 0 帧 —— 两者同尺寸,切换时像素重合,看不出接缝
  /// (见 widgets/tap_easter_egg.dart 的类文档)。
  static const String _eggStill = 'assets/easter-egg/laugh_still.webp';
  static const String _eggAnimated = 'assets/easter-egg/laugh.webp';

  /// 彩蛋音效。原素材 18.7s,裁到 3.17s —— 和动图一轮等长,图和声一起收。
  /// 2.92s 起 250ms 淡出:那一段本来就是笑收尾的气口(约 -14~-19 dB),淡掉听不出来。
  /// 单声道 96kbps,39 KB。
  static const String _eggSound = 'assets/easter-egg/laugh.mp3';

  /// 彩蛋显示宽度。素材是 300x486 的竖构图,150 宽在手机上约合屏宽的四成。
  static const double _eggWidth = 150;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度,按这张图自己的比例算,和 SubPage 里画的是同一个数。
    final headerHeight = MediaQuery.sizeOf(context).width / _headerAspect;
    // 画面底边在画布 537/605 处(落点 y=68 + 画面高 469),再减掉抬高量。
    final headerBottom = headerHeight * 537 / 605 - _headerLift;

    return SubPage(
      title: '关于本APP',
      // 原图直接按比例缩进画布:居中、四周 6px 留白、不加白描边。复现命令见
      // tool/make_header_art.py --margin 6 --outline 0。
      headerImage: 'assets/theme-header/theme_top_5.png',
      headerAspect: _headerAspect,
      headerLift: _headerLift,
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: Stack(
            children: [
              ListView(
                physics: const ShortBounceScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
                children: [
                  AboutInfoCard(
                    title: '开源地址',
                    value: kRepoUrl,
                    // 点了就复制,不提示怎么点 —— URL 在卡片上选不中,只能这么给
                    onTap: () async {
                      await Clipboard.setData(
                        const ClipboardData(text: kRepoUrl),
                      );
                      if (!context.mounted) return;
                      showInfo(context, '已复制', '开源地址已复制到剪贴板。');
                    },
                  ),
                  const SizedBox(height: 12),
                  const AboutInfoCard(title: '制作人', value: '春日大阪'),
                  const SizedBox(height: 12),
                  const AboutInfoCard(
                    title: '彩蛋出席',
                    value: '奶龙,不知名小人物,不知名大人物',
                  ),
                  const SizedBox(height: 12),
                  const AboutInfoCard(
                    title: '后续维护',
                    value: '原则上,来讲是永久免费(看后续精力)',
                  ),
                ],
              ),
              // 彩蛋钉在内容区右下角,浮在卡片之上。**不能**挪进 ListView 当最后
              // 一项:它本来是贴在屏幕右下角的,跟着列表滚就跑到内容末尾去了。
              Positioned(
                right: 0,
                bottom: 0,
                child: TapEasterEgg(
                  still: _eggStill,
                  animated: _eggAnimated,
                  sound: _eggSound,
                  width: _eggWidth,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 关于页的一张卡:只有一行「标题:内容」,和文案长得一样。
///
/// 刻意做成一行:这四张卡就是四句话,不是四块版面。分两行摆(标题一行、值一行)
/// 会把卡片撑到两倍高,四张摞起来像四个板块。
///
/// [onTap] 非空时整行可点(开源地址那张用它复制)。**不给"点击即可复制"这类提示**:
/// 是用户点名的。点了有回音就够了。
class AboutInfoCard extends StatelessWidget {
  const AboutInfoCard({super.key, required this.title, required this.value, this.onTap});

  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    // RichText 而不是 Text.rich:标题和内容一个色号、只差字重,拆成两段 Span
    // 排版上就是一行,长内容自然换行时也不用管缩进对不对齐。
    final line = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$title:',
            style: TextStyle(fontWeight: FontWeight.w600, color: foreground),
          ),
          TextSpan(
            text: value,
            style: TextStyle(color: secondary),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 14.5, height: 1.35),
    );

    return GlassPanel(
      isDark: isDark,
      child: onTap == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: line,
            )
          : PlainTap(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: line,
              ),
            ),
    );
  }
}

/// 「设置 → 彩蛋提示」的二级页。
///
/// 只摆一张卡,摊开不伸缩 —— 这页本来就是来看这一句话的,再点一下才给没有意义
/// (同 [FeedbackChannelsCard] 的理由)。
class EasterEggHintPage extends StatelessWidget {
  const EasterEggHintPage({super.key});

  /// 底部两个角色的底衬高度,占屏宽的比例。
  ///
  /// 素材出库时已经裁到角色本体(见 tool/make_egg_hint_art.py),一左一右各占
  /// 半个屏宽,所以真正卡住角色大小的是这个高度而不是宽度:给到 0.9 / 2 的
  /// 宽高比时两个角色才铺满各自那一半。素材本身就是 720x812 / 720x943,高度
  /// 是宽度的 1.13 / 1.31 倍,这里按 1.13 算 —— 取更宽的那个反而会把两个角色
  /// 挤到一起。
  static const double _artAspect = 0.9 / 2 / 1.13;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 底衬按屏宽算,和图片里角色的大小同一个比例,换机型不会一边大一边小。
    final artHeight = MediaQuery.sizeOf(context).width * _artAspect;

    return SubPage(
      title: '彩蛋提示',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: Stack(
            children: [
              ListView(
                physics: const ShortBounceScrollPhysics(),
                // 底部留出底衬的高度 + 32:滚动到底时卡片不会被角色盖住。
                padding: EdgeInsets.fromLTRB(20, 18, 20, artHeight + 32),
                children: [EggHintCard(isDark: isDark)],
              ),
              // 两个角色钉在内容区底部,浮在卡片之上。**不能**挪进 ListView 当最后
              // 一项:它们要的是贴着屏幕右下角不动,跟着列表滚就跑到内容末尾去了
              // (同 [AboutAppPage] 的彩蛋)。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: SizedBox(
                    height: artHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: const [
                        Expanded(
                          child: Image(
                            image: AssetImage(
                              'assets/easter-egg-hint/left.png',
                            ),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomLeft,
                          ),
                        ),
                        Expanded(
                          child: Image(
                            image: AssetImage(
                              'assets/easter-egg-hint/right.png',
                            ),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomRight,
                          ),
                        ),
                      ],
                    ),
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

/// 彩蛋提示页唯一那张卡:标题一行,内容一行。摊开不伸缩。
class EggHintCard extends StatelessWidget {
  const EggHintCard({super.key, required this.isDark});

  final bool isDark;

  static const String _hint = '也许在某个设置中的2级界面,快速连续3次点击人物,它会发出声音🤯';

  @override
  Widget build(BuildContext context) {
    final (foreground: _, secondary: secondary) = settingsPalette(isDark);
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 14, 8),
            child: GoogleCardTitle(isDark: isDark, text: '提示'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Text(
              _hint,
              style: TextStyle(
                color: secondary,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// 系统主题的三个选项
enum AppThemeMode { system, light, dark }

/// 「系统主题」卡:收起时只有一行(标题 + 当前值 + 向下箭头),点箭头向下滑出
/// 三个选项;选完自己回弹收起。
///
/// 展开态是纯界面状态,所以留在本组件里 —— 每次进二级页都从收起开始。
class ThemeModeCard extends StatefulWidget {
  const ThemeModeCard({super.key, required this.app, required this.isDark});

  final HomeShellState app;
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

  final HomeShellState app;

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
      headerImage: 'assets/theme-header/theme_top.png',
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
              const SizedBox(height: 16),
              UiScaleCard(app: app, isDark: isDark),
            ],
          ),
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

  final HomeShellState app;
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

  final HomeShellState app;
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

