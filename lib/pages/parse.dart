import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jicun/main.dart';
import 'package:jicun/pages/history.dart';
import 'package:jicun/pages/preview.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/widgets.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';

/// 「解析」首页:一张窄的粘贴卡 + 若干张预览卡,单列排布。
/// 卡片样式与间距全部沿用一级设置列表(GlassPanel / 20 边距 / 12 间距),
/// 只有内容不同 —— 首页比设置页多一块「预览区 + 底部动作按钮」。
///
/// 预览卡默认**不显示**:没解析出东西之前,它们只是几块空骨架,摆在那里既没
/// 信息也占满一屏。只有解析成功后它们才逐张入场(见 [StaggerIn]),
/// 而且只显示这次真解析出来的内容(见 [PreviewKind.forResult])。
///
/// 状态全部挂在 [HomeShellState] 上,这里只是把那份状态画出来 ——
/// 状态留在本页自己的 State 里的话,切一次 tab 就被丢掉了。
class ParsePage extends StatelessWidget {
  const ParsePage({super.key, required this.app});

  final HomeShellState app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final parsed = app.parseResult;
    // 有什么才显示什么:纯视频链接底下不该挂一张空的「图集预览」。
    final kinds = parsed == null
        ? PreviewKind.values
        : PreviewKind.forResult(parsed);
    final showPreviews = parsed != null && kinds.isNotEmpty;
    return ListView(
      physics: const ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, kBoardHeaderTop, 20, 120),
      children: [
        const BoardHeader(title: '解析'),
        const SizedBox(height: 18),
        PasteLinkCard(app: app),
        if (app.parseError != null) ...[
          const SizedBox(height: 10),
          ErrorNotice(message: app.parseError!, isDark: isDark),
        ],
        // 入场分两层:外层 [Reveal] 把列表高度撑开(带系统主题卡那套回弹),
        // 内层每张卡各自淡入上浮、错开一拍。所以不是「啪」一下弹出来。
        Reveal(
          expanded: showPreviews,
          child: Column(
            children: [
              const SizedBox(height: 12),
              ...kinds.asMap().entries.map(
                (entry) => Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key == kinds.length - 1 ? 0 : 12,
                  ),
                  child: StaggerIn(
                    index: entry.key,
                    show: showPreviews,
                    child: PreviewCard(
                      // 带上 kind 做 key:重新解析后同一位置上可能是另一种卡,
                      // 不换 key 的话 State 会被复用,开合状态会串到新卡上。
                      key: ValueKey<PreviewKind>(entry.value),
                      kind: entry.value,
                      result: parsed,
                      app: app,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 解析失败的提示条。
///
/// 挂在粘贴卡下面,不占预览区的位置 —— 预览区里可能还留着上一次的结果。
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.message, required this.isDark});

  final String message;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final color = isDark ? const Color(0xFFFF7B72) : const Color(0xFFC0392B);
    return GlassPanel(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(CupertinoIcons.exclamationmark_circle, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: color, fontSize: 13.5, height: 1.3),
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


/// 粘贴链接卡:刻意比预览卡矮 —— 一行说明 + 一个输入框 + 一颗按钮。
///
/// 输入框必须有:解析的入口是「手上有链接」,只给粘贴按钮的话,改一个字符就得去
/// 别处重来。这里留一个可编辑的框,粘贴走系统长按菜单,清除走自带按钮。
///
/// 输入框控制器和解析状态都在 [HomeShellState] 上,这张卡本身无状态 ——
/// 否则切一次 tab 输入框就空了。
class PasteLinkCard extends StatelessWidget {
  const PasteLinkCard({super.key, required this.app});

  final HomeShellState app;

  void _start() {
    // 收键盘:解析结果就在这张卡下面,键盘立着会把它挡掉
    FocusManager.instance.primaryFocus?.unfocus();
    app.startParse(app.linkController.text);
  }

  /// 粘贴:把剪贴板里的内容整条塞进输入框。
  ///
  /// 不挑内容、也不看输入框里有没有东西 —— 用户点了就是要「把剪贴板给我」。
  /// 复制的是整段分享文本也没关系:里面那条链接由 [_onLinkChanged] 顺手挑出来。
  ///
  /// 读不到(系统拦下、或剪贴板本来就是空的)要说一句:点了毫无反应等于坏掉。
  Future<void> _paste(BuildContext context) async {
    final text = await app.readClipboard();
    if (!context.mounted) return;
    if (text == null || text.trim().isEmpty) {
      showInfo(
        context,
        '没读到剪贴板里的文字',
        '如果刚才确实复制了:安卓在你切走应用之后可能已经把剪贴板清掉了,'
            '回原应用重新复制一次,再回来点粘贴。',
      );
      return;
    }
    // 换了新内容:把「完成解析」放回「开始解析」,否则新粘进来的链接点不动
    app.unlockParse();
    // 顺手预热连接:粘完多半就要点解析了
    app.parseService.warmUp();
    app.linkController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 清空输入框。解锁「完成解析」由 [_onLinkChanged] 的置空分支负责。
  void _clear() => app.linkController.clear();

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    final bool hasLink = app.linkController.text.trim().isNotEmpty;

    // 解析成功后按钮变成「完成解析」并置灰,直到用户点输入框或清空内容。
    final String label;
    final bool canStart;
    if (app.parseLocked) {
      label = '完成解析';
      canStart = false;
    } else if (app.parsing) {
      label = '解析中…';
      canStart = false;
    } else {
      label = '开始解析';
      canStart = hasLink;
    }

    return GlassPanel(
      isDark: isDark,
      child: Padding(
        // 与设置卡同一条内边距(16/13),所以两页的卡片起止线是对齐的
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
        child: Column(
          children: [
            Row(
              children: [
                GlassIconChip(
                  isDark: isDark,
                  asset: homeIcon(context, '粘贴链接.svg'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: CardHeadline(
                    isDark: isDark,
                    title: '粘贴链接',
                    subtitle: '粘贴平台分享链接',
                  ),
                ),
                const SizedBox(width: 10),
                // 右上角这两颗,样式抄历史页顶栏那排:粘贴在上、清空在下,
                // 都靠右对齐(Column 的 end),右边那条线才是齐的。
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PillAction(
                      key: const ValueKey('pasteLink.paste'),
                      asset: homeIcon(context, '粘贴.svg'),
                      label: '粘贴',
                      onTap: () => _paste(context),
                    ),
                    const SizedBox(height: 6),
                    PillAction(
                      key: const ValueKey('pasteLink.clear'),
                      asset: homeIcon(context, '清空.svg'),
                      label: '清空',
                      // 没内容就没得清:灰着,且吃掉点击
                      onTap: hasLink ? _clear : null,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: app.linkController,
              placeholder: '粘贴或输入分享链接',
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              style: TextStyle(color: foreground, fontSize: 15),
              placeholderStyle: TextStyle(color: secondary, fontSize: 15),
              // 输入框和预览区用同一档底色:首页里三块「内容区」是一个视觉层级
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0x1FFFFFFF)
                    : const Color(0x12000000),
                borderRadius: BorderRadius.circular(12),
              ),
              // 点一下输入框就把「完成解析」放回「开始解析」——
              // 用户既然又碰了输入框,说明他还想再解析一次。
              // 顺手预热连接:他接着要粘贴、再点按钮,握手别等到那时候才开始。
              onTap: () {
                app.parseService.warmUp();
                app.unlockParse();
              },
              // 自带的叉关掉:右上角已经有专门的「清空」,两个一起出现太吵
              clearButtonMode: OverlayVisibilityMode.never,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              // 空链接解析不出东西,按钮先灰着,省得点了没反应;
              // 解析中和已完成的置灰见上面的 label/canStart。
              onPressed: canStart ? _start : null,
              // 图标颜色不写死:交给 FilledButton 注入的 IconTheme,
              // 深浅两套 ColorScheme 的前景色(含 M3 深色模式的深蓝 onPrimary)都跟得上。
              icon: TintedSvgIcon(homeIcon(context, '开始解析.svg'), size: 20),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

