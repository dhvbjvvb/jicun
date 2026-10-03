
import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:flutter/services.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/update_service.dart';
import 'package:jicun/widgets/tap_easter_egg.dart';

/// 「关于本APP」二级页,从 lib/pages/settings.dart 拆出来。
///
/// 连同它用的开源仓库地址 [kRepoUrl] 一起搬 —— 那个常量只有这一页用。

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
      headerImage: 'assets/theme-header/theme_top_5.webp',
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
                    title: '免责声明',
                    value:
                        '本项目仅供学习与技术交流使用，请勿用于商业用途。'
                        '解析与下载的内容版权归原作者所有，请自行确认拥有相应权利后再保存或传播，'
                        '因使用本工具产生的一切后果由使用者自行承担。',
                  ),
                ],
              ),
              // 彩蛋钉在内容区右下角,浮在卡片之上。**不能**挪进 ListView 当最后
              // 一项:它本来是贴在屏幕右下角的,跟着列表滚就跑到内容末尾去了。
              const Positioned(
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
