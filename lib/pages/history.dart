import 'package:flutter/cupertino.dart';
import 'package:jicun/cover_cache.dart';
import 'package:jicun/history_store.dart';
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/widgets.dart';

/// 历史板块:一列解析记录卡。卡片样式与间距沿用首页/设置页(GlassPanel / 20 边距 /
/// 12 间距),左边是封面,右上角横排「选择 / 全选 / 删除」。
///
/// 记录**不在本页读取**:数据由 [ShellController] 持有并在启动时预读好,
/// 这里只是画出来。本页的 State 一切走就被丢掉了,数据放这儿会每次重新读盘 ——
/// 冷启动进历史页那一下空白就是这么来的。
///
/// 选择模式是纯界面状态:切走 tab 就回到未选择状态。
///
/// 非选择模式下单击一张卡 = 带着那条链接回解析页重新解析
/// (走 [ShellController.reparseFromHistory])。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.app});

  final ShellController app;

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  /// 是否处于选择模式。只在选择模式下卡片左端才长出勾选圈。
  bool _selecting = false;

  /// 已选中的记录 id。多选,所以是集合而不是单个值。
  final Set<String> _selected = <String>{};

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      // 退出选择模式时清空选择,免得下次进来还带着上次的勾
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(HistoryEntry entry) {
    if (!_selecting) return;
    setState(() {
      if (!_selected.remove(entry.id)) _selected.add(entry.id);
    });
  }

  /// 当前列表是不是已经全部选中。全选框的「选中」态看它。
  bool _allSelected(List<HistoryEntry> list) =>
      list.isNotEmpty && _selected.length == list.length;

  /// 全选 / 取消全选。
  ///
  /// 按需求是**切换**:已经全选中了再点一次就全部取消,而不是永远只能全选。
  void _toggleSelectAll(List<HistoryEntry> list) {
    setState(() {
      if (_allSelected(list)) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(list.map((entry) => entry.id));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = <String>{..._selected};
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    // 落盘和刷新都由根 State 做 —— 列表在它那儿
    await widget.app.deleteHistory(ids);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    // 列表在根 State 上,这里只读
    final entries = widget.app.historyEntries;
    final list = entries ?? const <HistoryEntry>[];
    return ListView(
      physics: const ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, kBoardHeaderTop, 20, 120),
      children: [
        BoardHeader(
          title: '历史',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PillAction(
                asset: historyIcon(context, '选择.svg'),
                label: '选择',
                active: _selecting,
                // 没有记录可挑时按钮是灰的
                onTap: list.isEmpty ? null : _toggleSelecting,
              ),
              const SizedBox(width: 8),
              PillAction(
                asset: historyIcon(context, '全选.svg'),
                label: '全选',
                // 只有进了选择模式,全选才有意义 —— 没进之前是灰的。
                // 进了之后点一次全选中,再点一次全部取消(选中态看 _allSelected)。
                onTap: _selecting && list.isNotEmpty
                    ? () => _toggleSelectAll(list)
                    : null,
                active: _selecting && _allSelected(list),
              ),
              const SizedBox(width: 8),
              PillAction(
                asset: historyIcon(context, '删除.svg'),
                label: '删除',
                destructive: true,
                // 一个都没选就删不了
                onTap: _selected.isEmpty ? null : _deleteSelected,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (list.isEmpty)
          GlassPanel(
            isDark: isDark,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  entries == null ? '正在读取…' : '暂无解析记录',
                  style: TextStyle(color: secondary, fontSize: 14),
                ),
              ),
            ),
          )
        else
          ...list.asMap().entries.map(
            (entry) => Padding(
              padding: EdgeInsets.only(
                bottom: entry.key == list.length - 1 ? 0 : 12,
              ),
              child: HistoryCard(
                entry: entry.value,
                isDark: isDark,
                selecting: _selecting,
                selected: _selected.contains(entry.value.id),
                // 非选择模式:单击回解析页重新解析这条链接。
                // 选择模式:单击只是勾选/取消勾选。
                onTap: _selecting
                    ? () => _toggleSelected(entry.value)
                    : () => widget.app.reparseFromHistory(entry.value),
              ),
            ),
          ),
      ],
    );
  }
}

/// 历史卡的副标题:第一行「时间 · 平台」,第二行「这次解析出了什么」。
///
/// 三段挤一行放不下(可用宽度约 15 个字),交给 Text 自动换行会断在类型列表中间
/// (「视频/音频/」+「文案」),看着像渲染坏了。所以这里显式换行,让类型整体落下去。
String entrySubtitle(HistoryEntry entry) {
  final result = entry.result;
  final contents = <String>[
    if (result.hasVideo) '视频',
    if (result.hasImages) '图集',
    if (result.hasAudio) '音频',
    if (result.hasCopy) '文案',
  ].join('/');
  return <String>[
    <String>[
      shortTime(entry.parsedAt),
      if (result.platform.isNotEmpty) result.platform,
    ].join(' · '),
    if (contents.isNotEmpty) contents,
  ].join('\n');
}

/// 「今天 22:52」这种短时间。副标题只有一行,塞不下完整日期时间。
String shortTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = today
      .difference(DateTime(time.year, time.month, time.day))
      .inDays;
  final clock =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  if (days <= 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  return '${time.month} 月 ${time.day} 日';
}

/// 一条记录卡:勾选圈(仅选择模式)+ 封面 + 标题副标题。
class HistoryCard extends StatelessWidget {
  const HistoryCard({
    super.key,
    required this.entry,
    required this.isDark,
    required this.selecting,
    required this.selected,
    required this.onTap,
  });

  final HistoryEntry entry;
  final bool isDark;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final result = entry.result;
    return GlassPanel(
      isDark: isDark,
      child: PlainTap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SelectDot(
                visible: selecting,
                selected: selected,
                isDark: isDark,
              ),
              CoverSlot(isDark: isDark, coverUrl: result.coverUrl),
              const SizedBox(width: 14),
              Expanded(
                // 右侧文字区锁成「标题两行 + 副标题两行」的高度。
                // 不锁的话标题占一行还是两行会把卡片撑成两种高度,列表参差不齐。
                // 高度由 CardHeadline 自己的字号行高算出来,不写死数字。
                child: SizedBox(
                  height: CardHeadline.fourLineHeight,
                  child: CardHeadline(
                    isDark: isDark,
                    // 标题为空的情况少见(接口会用正文兜底),但真出现时
                    // 留一张没有名字的卡比留个空字符串好。
                    title: result.title.isEmpty ? '未命名' : result.title,
                    subtitle: entrySubtitle(entry),
                    // 时间 · 平台 · 类型,一行放不下
                    subtitleMaxLines: 2,
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

/// 卡片左端那个勾选圈。只在选择模式下出现 —— 出现/消失走和卡片展开同一套曲线,
/// 靠宽度伸缩(和 [Reveal] 是一个路子,只是方向横过来)。
class SelectDot extends StatelessWidget {
  const SelectDot({
    super.key,
    required this.visible,
    required this.selected,
    required this.isDark,
  });

  final bool visible;
  final bool selected;
  final bool isDark;

  static const double _size = 22;

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final secondary = settingsPalette(isDark).secondary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: visible ? 1 : 0),
      duration: visible ? kRevealExpand : kRevealCollapse,
      curve: visible ? kRevealExpandCurve : kRevealCollapseCurve,
      builder: (context, t, child) => ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: t < 0 ? 0 : t,
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 空心 → 选中后填色 + 白勾
            color: selected ? accent : const Color(0x00000000),
            border: Border.all(
              color: selected
                  ? accent
                  : secondary.withValues(alpha: selected ? 1 : 0.55),
              width: 1.6,
            ),
          ),
          child: selected
              ? const Icon(
                  CupertinoIcons.check_mark,
                  size: 14,
                  color: Color(0xFFFFFFFF),
                )
              : null,
        ),
      ),
    );
  }
}

/// 封面位。
///
/// 底下那层占位**一直在**,图下来了再淡入盖上去。
/// 之前是「有地址就直接画 Image」——图没下来之前那块位置是空的,只有一层灰底,
/// 看着就是"灰块 → 图片"硬切一下,很割裂。
///
/// 优先用磁盘缓存的本地文件:这是「重启 App 直接进历史页也能立刻看到封面」的关键。
/// 内存缓存救不了冷启动,只有落盘才行。
class CoverSlot extends StatelessWidget {
  const CoverSlot({super.key, required this.isDark, this.coverUrl});

  static const double width = 96;
  static const double height = 60;

  final bool isDark;
  final String? coverUrl;

  /// 有本地文件就从文件解码(快,不走网络);没有才联网并淡入。
  ///
  /// [cacheWidth] 是关键:存下来的是原图(封面动辄上千像素),而这里只显示 96 宽。
  /// 不告诉解码器目标尺寸的话,它会老老实实解一张全尺寸位图再缩 —— 那点时间
  /// 就是冷启动进历史页看到的那一下空白。给了解码器就能直接降采样。
  Widget _cover(String url, int cacheWidth) {
    final file = CoverCache.fileFor(url);
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        // 判断存在之后到真正解码之间,系统可能把缓存目录回收了 —— 退回占位
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      // 已经有帧了就淡入。同步命中内存缓存(wasSynchronouslyLoaded)时不用淡
      // —— 那时候本来就该直接是图,淡一下反而闪。
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          child: child,
        );
      },
      // 上游给的封面是带签名的临时地址,过一段时间会 403。
      // 历史记录会长期留着,所以出错时让底下那层占位露出来就行。
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final url = coverUrl;
    // 按屏幕物理像素给解码尺寸:别解一张全尺寸图再缩
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Icon(
                  CupertinoIcons.play_circle_fill,
                  size: 24,
                  color: secondary.withValues(alpha: 0.45),
                ),
              ),
              if (url != null) _cover(url, cacheWidth),
            ],
          ),
        ),
      ),
    );
  }
}

