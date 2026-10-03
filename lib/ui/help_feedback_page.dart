import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';

/// 「使用帮助及反馈」二级页,从 lib/pages/settings.dart 拆出来。
///
/// 这一页连数据都自带的:平台清单 [kPlatforms]、教程文案、反馈渠道,全在这一个
/// 文件里,和「怎么改设置」没有关系。

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
///
/// **改这张表要连图标一起改**:`tool/fetch_platform_icons.py` 的 `PLATFORMS`
/// 是同一张表(图标按名字一个个从商店拉下来)。删了卡不删它、也不删
/// assets/platform-icons/ 下那张图,留下的就是死资源 —— 而且重跑脚本会把图标
/// 再拉回来。
const List<PlatformCardInfo> kPlatforms = [
  PlatformCardInfo('今日头条', 'toutiao.png', '视频、图片、文章'),
  PlatformCardInfo('快手', 'kuaishou.png', '视频、图片、实况、文案'),
  PlatformCardInfo('抖音', 'douyin.png', '视频、图片、实况、文案'),
  PlatformCardInfo('微信公众号', 'wechat.png', '视频、图片、文章'),
  PlatformCardInfo('微信视频号', 'wechat_channels.png', '视频'),
  PlatformCardInfo('小红书', 'xiaohongshu.png', '视频、图片、实况、文案'),
  PlatformCardInfo('汽水音乐', 'qishui.png', '仅免费音乐、MV'),
  PlatformCardInfo(
    '豆包',
    'doubao.png',
    '无水印图片、无水印视频',
    tutorial: '复制对话分享链接,回到本 APP 粘贴解析即可',
  ),
  PlatformCardInfo('哔哩哔哩', 'bilibili.png', '有水印视频'),
  PlatformCardInfo('微博', 'weibo.png', '图文、视频、实况'),
  PlatformCardInfo('皮皮搞笑', 'pipigaoxiao.png', '视频、图片、文案'),
  PlatformCardInfo('皮皮虾', 'pipixia.png', '视频、图片、文案'),
  PlatformCardInfo('最右', 'zuiyou.png', '视频、图片、实况、文案'),
  PlatformCardInfo('好看视频', 'haokan.png', '视频'),
  PlatformCardInfo('西瓜视频', 'xigua.png', '视频'),
];

/// 「设置 → 使用帮助及反馈」的二级页。
///
/// 第一张是反馈渠道,第二张起一个平台一张伸缩卡。不再放顶栏插画:原来的图占掉
/// 大半屏,反馈入口被推到一屏之外;去掉之后第一张卡直接贴顶,再用 [TopFadeListView]
/// 给顶边补一圈淡出 —— 卡片滚上去是化掉的,不是被视口切一条硬边(深浅两色同效)。
class HelpFeedbackPage extends StatelessWidget {
  const HelpFeedbackPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return SubPage(
      title: '使用帮助及反馈',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          // 顶边衬 12:去掉顶栏图之后第一张卡就贴在这儿,别顶到导航栏上。
          child: TopFadeListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
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
    const shape = LiquidRoundedSuperellipse(borderRadius: _size * 0.3);
    return SizedBox(
      width: _size,
      height: _size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x0F000000),
        ),
        child: ClipPath(
          clipper: const ShapeBorderClipper(shape: shape),
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
