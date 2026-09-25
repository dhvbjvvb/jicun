import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/playback.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/ui/widgets.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

/// 预览卡的差异只有标题、图标、中间那块预览区和底部那颗动作按钮,其余全同,
/// 所以做成一份。动作按钮跟着内容走:画面、声音、图集、混合是「下载媒体」,
/// 文字是「复制文案」。
///
/// 具体显示哪几张由 [forResult] 按解析结果决定,不是全部画出来。
enum PreviewKind {
  media('媒体预览', '视频画面', '媒体预览.svg', '下载媒体', '下载媒体.svg'),
  gallery('图集预览', '图片列表与缩略图', '图集预览.svg', '下载媒体', '下载媒体.svg'),
  mixed('混合预览', '视频与图片', '混合预览.svg', '下载媒体', '下载媒体.svg'),
  audio('音频预览', '音频预览与下载', '音频预览.svg', '下载媒体', '下载媒体.svg'),
  text('文案预览', '描述文案', '文案预览.svg', '复制文案', '复制文案.svg');

  const PreviewKind(
    this.title,
    this.subtitle,
    this.icon,
    this.action,
    this.actionIcon,
  );

  final String title;
  final String subtitle;
  final String icon;

  /// 底部按钮的文字,同时用作「还没接后端」提示的标题。
  final String action;
  final String actionIcon;

  /// 这次解析该显示哪几张卡 —— 有什么才显示什么。
  ///
  /// 不能直接画 [values]:上游对每条链接都会回填一堆字段(标题兜底、首图兜底),
  /// 照着全集画出来就有「有卡没内容」—— 一条纯视频链接底下挂着空的图集预览。
  ///
  /// 既有视频又有图片时只给一张 [mixed]:**不拆成媒体卡 + 图集卡两张**,
  /// 混合链接的内容就摆在混合卡这一条缩略图里,不用上下对着看两条。
  ///
  /// 顺序跟枚举声明一致,免得卡片跳来跳去。
  static List<PreviewKind> forResult(ParseResult result) => <PreviewKind>[
    if (result.hasVideo && result.hasImages)
      mixed
    else ...[
      if (result.hasVideo) media,
      if (result.hasImages) gallery,
    ],
    // 视频自带音轨,所以有视频就有音频卡 —— 音源见 [ParseResult.audioSource]
    if (result.hasPlayableAudio) audio,
    // 只看描述:描述为空就没有文案卡,标题和作者不单独撑起一张卡
    if (result.hasCopy) text,
  ];

  /// 解析成功后这张卡默认是否摊开。
  ///
  /// 有内容的缩略图卡先摊开让人直接看到内容;音频和文案默认收起 ——
  /// 一屏同时展开四张卡会把页面撑得很长,而这两张点一下就能看/听。
  /// 卡片是否出现不受这个影响,收起的卡一样在列表里。
  bool get defaultExpanded => this == media || this == gallery || this == mixed;
}

/// 一张预览卡。
///
/// 每张卡自己管开合:点标题行滑出/缩回预览区,手感与「系统主题」卡同一套曲线
/// (见 [Reveal])。默认展开 —— 首页第一眼就该看到三块预览,而不是三个折叠条。
class PreviewCard extends StatefulWidget {
  const PreviewCard({
    super.key,
    required this.kind,
    required this.result,
    required this.app,
  });

  final PreviewKind kind;

  /// 解析结果。null 时三块内容区都还是骨架(外层 Reveal 这时也不会展开)。
  final ParseResult? result;

  /// 根 State。下载结束要发系统通知,而开关在「通知管理与下载」页里、存在根 State 上。
  final HomeShellState app;

  @override
  State<PreviewCard> createState() => PreviewCardState();
}

class PreviewCardState extends State<PreviewCard> {
  /// 初始开合状态按卡片类型定:媒体和图集默认摊开,音频和文案默认收起。
  /// 用户点过后就以他自己的选择为准。
  late bool _expanded = widget.kind.defaultExpanded;

  /// 用户自己动过开合没有。
  ///
  /// 没动过时开合跟着内容走:卡片类型会随解析结果换(有视频有图片时媒体卡换成
  /// 混合卡,见 [forResult]),State 是按位置复用的,不跟就会带着上一张卡的状态 ——
  /// 媒体卡默认摊开、混合卡也默认摊开,却显示成收起的一条。
  /// 动过之后就以用户的选择为准,解析第二次不该把他收起的卡又弹开。
  bool _userToggled = false;

  @override
  void didUpdateWidget(PreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_userToggled) _expanded = widget.kind.defaultExpanded;
  }

  /// 已选中的缩略图下标(媒体卡的多视频、图集卡的图片共用这一份)。
  final Set<int> _selected = <int>{};

  /// 上一次算出来的可选条目。列表换了(重新解析)就清空选中 ——
  /// 否则会按旧下标选中新链接里的图/视频。
  List<String> _lastItems = const [];

  /// 卡片底部的可选条目:媒体卡是多视频的地址,图集卡是图片地址,
  /// 混合卡是视频地址加图片地址。音频/文案返回空。
  List<String> _items(ParseResult? result) {
    if (result == null) return const [];
    return switch (widget.kind) {
      PreviewKind.media =>
        result.hasMultiVideo
            ? [for (final v in result.videoItems) v.url]
            : const [],
      PreviewKind.gallery => result.imageUrls,
      PreviewKind.mixed => [for (final e in mixedMedia(result)) e.url],
      _ => const [],
    };
  }

  /// 有两条以上媒体才带选中逻辑:一条就一颗直接能下的「下载媒体」按钮。
  bool _needsSelection(ParseResult? result) => _items(result).length > 1;

  bool get _allSelected =>
      _selected.isNotEmpty && _selected.length == _lastItems.length;

  /// 同步条目列表。
  ///
  /// initState 里也要跑一次(那时 widget 已经有了),所以这里不 setState。
  void _syncItems(List<String> items) {
    // 同一条链接里点选不该被清掉:只有列表真变了才重置
    if (_sameItems(items)) return;
    _lastItems = items;
    _selected.clear();
  }

  bool _sameItems(List<String> items) {
    if (items.length != _lastItems.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i] != _lastItems[i]) return false;
    }
    return true;
  }

  void _toggleTile(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(Iterable<int>.generate(_lastItems.length));
      }
    });
  }

  /// 选中的媒体地址,按下标排序(顺序就是列表里的顺序)。
  List<String> get _selectedUrls => [
    for (final i in _selected.toList()..sort()) _lastItems[i],
  ];

  /// 卡片底部那颗动作按钮当前能不能按。
  ///
  /// - 没解析出结果:不能按(灰);
  /// - 一条链接两条以上媒体:必须选中至少一条才能下(灰);
  /// - 只有一条媒体:直接能下。
  bool get _canAct {
    final result = widget.result;
    if (result == null) return false;
    return !_needsSelection(result) || _selected.isNotEmpty;
  }

  /// 卡片底部那颗动作按钮。媒体/音频/图集/混合是下载,文案是复制。
  Future<void> _runAction() async {
    final result = widget.result;
    if (result == null) return;

    if (widget.kind == PreviewKind.text) {
      await Clipboard.setData(ClipboardData(text: result.copyText));
      if (!mounted) return;
      showInfo(context, '已复制', '标题与文案已复制到剪贴板。');
      return;
    }

    // 文案卡已经在上面返回了,剩下的都是「下载媒体」
    //
    // 有分辨率可选时先问一句再下:上游(第二个)会把同一条视频的多个码流都列出来,
    // 用户点下载就是要挑一档。media-parser 的结果没有这份列表,这里直接跳过 ——
    // 弹窗只在有得选的时候出现。
    var qualityUrl = _selectedQualityUrl(result);
    final qualities = qualityUrl == null
        ? const <VideoQuality>[]
        : _qualityChoice(result);
    if (qualities.isNotEmpty) {
      final picked = await showQualityPicker(context, qualities: qualities);
      // 弹窗是异步的:回来时这个卡片可能已经被重新解析换掉了。
      if (!mounted) return;
      if (picked == null) return; // 用户关掉了:不下载
      qualityUrl = picked.url;
    }

    final items = _itemsToDownload(result, qualityUrl: qualityUrl);
    if (items.isEmpty) {
      showInfo(context, '没有可下载的内容', '先选中要下载的媒体。');
      return;
    }
    // 开始下载就把正在播的预览停掉:视频和音频都在播的时候,下载会和它们抢
    // 带宽和音频焦点。只是暂停,位置留在当前进度上 —— 下载跑完由
    // [_startDownload] 发一次恢复信号,点下载前在播的那些接着播。
    Playback.requestPause();
    await _startDownload(result.title, items);
  }

  /// 这次下载该给用户哪几档清晰度。
  ///
  /// 只有「正在下的就是那条主视频」时才有得选:合集卡里选中两条视频时,两条各有
  /// 各的清晰度列表,一次弹窗说不清下的是哪条 —— 那种情况按原地址下,不弹。
  ///
  /// 音频卡走的是 [ParseResult.audioSource](接口单独给的那份音轨),也不是视频,
  /// 同样不弹。
  List<VideoQuality> _qualityChoice(ParseResult result) {
    if (widget.kind == PreviewKind.audio) return const [];
    final video = result.primaryVideo;
    if (video == null || !video.hasQualityChoice) return const [];
    // 媒体卡的多视频:选中的必须就是第一条主视频。
    if (widget.kind == PreviewKind.media && result.hasMultiVideo) {
      final picked = _selectedUrls;
      if (picked.length != 1 || picked.first != result.primaryVideoUrl) {
        return const [];
      }
    }
    return video.qualities;
  }

  /// 单条视频那一路现在用的地址。null = 这次没有可选的清晰度。
  ///
  /// 判据和 [_qualityChoice] 一致:只有「正在下的就是主视频」才算。
  String? _selectedQualityUrl(ParseResult result) =>
      _qualityChoice(result).isEmpty ? null : result.primaryVideoUrl;

  /// 这次要下哪几条。
  ///
  /// [qualityUrl] 是用户在清晰度弹窗里选的那一档;非空时替换掉主视频的原地址
  /// (只有单条视频那一路会传)。
  ///
  /// 两条以上先选的规则:下的是选中的那些,不是全部(见 [_needsSelection])。
  /// 混合卡的视频和图片混在一条里,所以类型按每条自己的算,不能整批用一种。
  List<DownloadItem> _itemsToDownload(
    ParseResult result, {
    String? qualityUrl,
  }) {
    // 标题里带的媒体后缀先剥掉:有的平台标题就是文件名(抖音这条实测是
    // `…挪威冬日高画.mp4`),不去掉的话下面再拼一次后缀就变成 `…高画mp4.mp4`。
    final rawTitle = stripMediaExtension(result.title);

    /// 解析期按地址猜的后缀。收尾时下载器会按文件头改成真的 —— 猜错不影响相册里的
    /// 结果,只影响临时名。所以这里只关心**猜出来的后缀有多长**:[safeFileName] 要
    /// 把它和序号一起从 66 字节的上限里扣掉,不然拼出来的名字会超(见那里的说明)。
    String guessExt(String url, MediaKind kind) =>
        kind == MediaKind.video ? urlExt(url, 'mp4') : imageExt(url);

    /// 这一批第 [index] 条的名字(下标从 0 起)。
    ///
    /// 后缀是逐条猜的,但整批共用一个字节预算:按最长的那条留,否则同一批的标题会
    /// 被截成两种长度,看着像两批东西。序号只在有两条以上时才加。
    String nameOf(List<String> urls, List<MediaKind> kinds, int index) {
      final exts = [
        for (var i = 0; i < urls.length; i++) guessExt(urls[i], kinds[i]),
      ];
      final reserved = exts.fold('', (a, b) => a.length >= b.length ? a : b);
      final stem = safeFileName(
        rawTitle,
        ext: reserved,
        index: urls.length > 1 ? index + 1 : 0,
      );
      return '$stem.${exts[index]}';
    }

    List<DownloadItem> pack(
      List<String> urls,
      MediaKind Function(int index) kindOf,
    ) {
      final kinds = [for (var i = 0; i < urls.length; i++) kindOf(i)];
      return [
        for (var i = 0; i < urls.length; i++)
          DownloadItem(
            url: urls[i],
            fileName: nameOf(urls, kinds, i),
            kind: kinds[i],
          ),
      ];
    }

    return switch (widget.kind) {
      PreviewKind.gallery => () {
        final urls = result.imageUrls;
        final picked = _needsSelection(result) ? _selectedUrls : urls;
        return pack(picked, (_) => MediaKind.image);
      }(),
      PreviewKind.mixed => () {
        // 下载地址与缩略图网格同序,但视频那格是视频地址而不是封面(见 [mixedMedia])
        final entries = mixedMedia(result);
        // 两条以上要先选:一条视频 + 一张图也算两条,一样要走选中
        final picked = _needsSelection(result)
            ? [
                for (var i = 0; i < entries.length; i++)
                  if (_selected.contains(i)) entries[i],
              ]
            : entries;
        return pack([
          for (final e in picked) e.url,
        ], (i) => picked[i].isVideo ? MediaKind.video : MediaKind.image);
      }(),
      // 媒体的多视频卡走缩略图选中
      PreviewKind.media when result.hasMultiVideo => pack(
        _selectedUrls,
        (_) => MediaKind.video,
      ),
      // 单条视频 / 音频卡:播什么就下什么。音频卡下的是接口给的那份独立音频文件
      // (audio_url),不是整个视频 —— 后台里那份是现成的,没必要下一整个 MP4。
      // 视频那一路用 primaryVideoUrl:实况帖的 video_url 是 null,地址在实况里。
      _ => () {
        final isAudio = widget.kind == PreviewKind.audio;
        // 视频那一路:用户在清晰度弹窗里选过就用他选的那档,否则用 primaryVideoUrl
        // (实况帖的 video_url 是 null,地址在实况里)。音频卡不吃 qualityUrl ——
        // 那档是视频的码流,下音频时不弹窗,这里也不会传进来。
        final url = isAudio
            ? result.audioSource
            : (qualityUrl ?? result.primaryVideoUrl);
        if (url == null) return <DownloadItem>[];
        // 音源是视频本身时(接口没给 audio_url)按视频存:Video 目录 + video/mp4。
        // 按音频存会让媒体库拿到一段 audio/mp4 的视频流,归档和播放都不对。
        final asVideo = !isAudio || !result.hasStandaloneAudio;
        final ext = urlExt(url, asVideo ? 'mp4' : 'mp3');
        return [
          DownloadItem(
            url: url,
            fileName: '${safeFileName(rawTitle, ext: ext)}.$ext',
            kind: asVideo ? MediaKind.video : MediaKind.audio,
          ),
        ];
      }(),
    };
  }

  /// 打开下载进度卡片,把这几条下完。
  ///
  /// 进度卡片自己管取消和关闭;这里只管把结果告诉它、失败时给一句人话,
  /// 顺带按「通知管理与下载」页里的开关发一条系统通知。
  Future<void> _startDownload(String title, List<DownloadItem> items) async {
    final app = widget.app;
    await showDownloadProgressCard(
      context,
      title: title,
      total: items.length,
      run: (onProgress, cancelled) async {
        try {
          await Downloader.saveAll(
            items,
            onProgress: onProgress,
            cancelled: cancelled,
          );
        } on DownloadCancelled {
          // 取消也算失败的一种:相册里什么都没有,和网络失败的结果一样,
          // 所以照发「下载失败」通知(发不发还是「通知管理与下载」里那个开关说了算)。
          // 卡片那边不当成错误:取消是用户自己按的,直接关掉就行。
          await app.notifyDownloadFinished(
            ok: false,
            title: title,
            error: '已取消',
          );
          rethrow;
        } catch (error) {
          await app.notifyDownloadFinished(
            ok: false,
            title: title,
            error: downloadErrorMessage(error),
          );
          rethrow; // 卡片还要靠这个异常把状态标成失败、弹出那句提示
        } finally {
          // 这一趟结束了(下完/取消/失败)才把预览放回去 —— 不是卡片关掉就放:
          // 用户可以先收起卡片让下载在后台继续,那时候恢复预览又和下载抢带宽了。
          Playback.requestResume();
        }
        await app.notifyDownloadFinished(ok: true, title: title);
      },
    );
  }

  /// 卡片副标题。
  ///
  /// 音频卡按音源改口:放接口给的那份独立音频时是「试听提取出的音频」;
  /// 只有接口没给 audio_url、退回视频本身时才叫「视频原声」。
  String _subtitle(ParseResult? result) {
    if (widget.kind == PreviewKind.audio && result != null) {
      return result.hasStandaloneAudio ? widget.kind.subtitle : '视频原声';
    }
    return widget.kind.subtitle;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    // 解析结果换了就把选中清掉(同一条链接内点选不受影响)
    _syncItems(_items(widget.result));
    final selectable = _needsSelection(widget.result);
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() {
              _userToggled = true;
              _expanded = !_expanded;
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
              child: Row(
                children: [
                  GlassIconChip(
                    isDark: isDark,
                    asset: homeIcon(context, widget.kind.icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: CardHeadline(
                      isDark: isDark,
                      title: widget.kind.title,
                      subtitle: _subtitle(widget.result),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 收起时这里就是这张卡的「当前值」,与系统主题卡同一位置
                  Text(
                    _expanded ? '' : (widget.result == null ? '未解析' : '已解析'),
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PreviewStage(
                    kind: widget.kind,
                    isDark: isDark,
                    result: widget.result,
                    selected: _selected,
                    onTapTile: _toggleTile,
                  ),
                  const SizedBox(height: 14),
                  // 两条以上媒体:左边多一颗「全选媒体」,右边才是下载。
                  // 全选中之后这颗按钮改口叫「取消全选」—— 用户才知道再点一次
                  // 是取消,而不是继续全选。
                  if (selectable)
                    Row(
                      children: [
                        Expanded(
                          child: CardActionButton(
                            isDark: isDark,
                            label: _allSelected ? '取消全选' : '全选媒体',
                            icon: '全选媒体.svg',
                            active: _allSelected,
                            onPressed: _toggleAll,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: CardActionButton(
                            isDark: isDark,
                            label: widget.kind.action,
                            icon: widget.kind.actionIcon,
                            onPressed: _canAct ? _runAction : null,
                          ),
                        ),
                      ],
                    )
                  else
                    CardActionButton(
                      isDark: isDark,
                      label: widget.kind.action,
                      icon: widget.kind.actionIcon,
                      onPressed: _canAct ? _runAction : null,
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

/// 预览区。解析前是占位骨架:高度按各自内容定死,解析出结果后原地替换内容即可,
/// 卡片不会因为内容多寡而上下跳。
class PreviewStage extends StatelessWidget {
  const PreviewStage({
    super.key,
    required this.kind,
    required this.isDark,
    required this.result,
    required this.selected,
    required this.onTapTile,
  });

  final PreviewKind kind;
  final bool isDark;

  /// 解析结果。null 时三块内容区都还是骨架。
  final ParseResult? result;

  /// 缩略图条里已选中的下标。跟着 [PreviewCardState] 走。
  final Set<int> selected;
  final ValueChanged<int> onTapTile;

  @override
  Widget build(BuildContext context) {
    // 占位底:比卡片玻璃再深/浅一档,把内容区和标题区分开
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    final parsed = result;

    return switch (kind) {
      // 视频画面:一条视频是真正的播放器(见 [VideoStage]),两条以上就是
      // 横向封面缩略图 —— 需求里多视频与多图走同一套排版,播放组件取消掉。
      // 封面用接口给的:那是这一条自己的首帧图;接口没给就退化成播放占位图标。
      PreviewKind.media =>
        parsed != null && parsed.hasMultiVideo
            ? GalleryStage(
                isDark: isDark,
                entries: [
                  for (final v in parsed.videoItems)
                    (url: v.coverUrl ?? '', isVideo: true),
                ],
                selected: selected,
                onTapTile: onTapTile,
                emptyHint: '这条链接没有视频画面',
                unit: '个',
              )
            : VideoStage(
                isDark: isDark,
                // 走 previewVideoUrl 而不是 primaryVideoUrl:预览要的是**低码率**
                // 那一档,不是主地址。上游那条 8K 原画是 34.7 Mbps,预览播放器
                // 按秒缓冲,几十秒就把 Java 堆吃光(真机 tombstone 实测 OOM)。
                // 下载仍然按用户在清晰度弹窗里选的那一档走,两者互不影响。
                url: parsed?.previewVideoUrl ?? '',
                coverUrl: parsed?.primaryVideoCoverUrl,
              ),
      // 音频:一块能按的播放器。见 [AudioStage] —— 不是波形图。
      PreviewKind.audio => AudioStage(
        isDark: isDark,
        url: parsed?.audioSource ?? '',
      ),
      // 图集:横向缩略图条。两条以上要选中才能下载,见 [PreviewCardState]。
      // 没有图集内容(纯视频链接)时给一句话,不留一块空占位让人猜是不是加载失败。
      PreviewKind.gallery => GalleryStage(
        isDark: isDark,
        entries: [
          for (final url in parsed?.imageUrls ?? const <String>[])
            (url: url, isVideo: false),
        ],
        selected: selected,
        onTapTile: onTapTile,
        emptyHint: '这条链接没有图集内容',
        unit: '张',
      ),
      // 混合:视频封面和图片排在一条缩略图里,视频那几格右下角带播放标识。
      // 数两样一起数,所以量词不写死。
      PreviewKind.mixed => GalleryStage(
        isDark: isDark,
        entries: parsed == null
            ? const <({String url, bool isVideo})>[]
            : galleryEntries(parsed),
        selected: selected,
        onTapTile: onTapTile,
        emptyHint: '这条链接没有解析出媒体',
        unit: '项',
      ),
      // 文案卡只放描述文案。标题和作者不上卡片(副标题已经写明是「描述文案」),
      // 描述为空时这张卡根本不会被建出来(见 [forResult])。
      // 文字区最多 12 行、超过就出滚动条,见 [CopyStage]。
      PreviewKind.text =>
        parsed == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                  child: _textSkeleton(secondary),
                ),
              )
            : CopyStage(isDark: isDark, text: parsed.desc),
    };
  }

  /// 文案卡的骨架:五条,最后一条短一截,看着就是一段落。
  Widget _textSkeleton(Color secondary) => Column(
    children: [
      for (final (i, width) in const [
        (0, 1.0),
        (1, 0.92),
        (2, 0.84),
        (3, 0.66),
        (4, 0.38),
      ]) ...[
        if (i > 0) const SizedBox(height: 10),
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: width,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
              color: secondary.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ],
    ],
  );
}

/// 文案内文字区最多显示多少行。超过就锁这么高,右侧出滚动条。
const int kCopyMaxLines = 12;

/// 文案预览区:整块只放描述文案。
///
/// 两种排法,按真实行数二选一:
/// - **不超过 12 行**:窗口跟着文字走,有几行就几行,不留空白;
/// - **超过 12 行**:窗口锁死在 12 行高,右侧出一根滚动条,上下滑动看全文。
///
/// 这里**不能**用 `maxLines` + ellipsis 截断 —— 那是把后面的文案直接丢掉。
/// 实测一条长文案在 App 上只显示到一半,接口返回的其实是完整的。
class CopyStage extends StatefulWidget {
  const CopyStage({super.key, required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  State<CopyStage> createState() => CopyStageState();
}

class CopyStageState extends State<CopyStage> {
  final ScrollController _scroll = ScrollController();

  static const double _fontSize = 14;
  static const double _lineHeight = 1.5;

  /// 一行占的高度。字号 × 行高倍数。
  static const double _lineBox = _fontSize * _lineHeight;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color foreground = settingsPalette(widget.isDark).foreground;
    final fill = widget.isDark
        ? const Color(0x1FFFFFFF)
        : const Color(0x12000000);
    final style = TextStyle(
      color: foreground.withValues(alpha: 0.86),
      fontSize: _fontSize,
      height: _lineHeight,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 先用同一套样式量一遍,数出真实行数 —— 要不要锁高、要不要出滚动条
        // 全看它。不量的话这两种情况在布局前根本分不出来。
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.computeLineMetrics().length > kCopyMaxLines;

        final text = Text(widget.text, style: style);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            // 不满 12 行时不设上限,窗口自然收缩到文字高度
            constraints: BoxConstraints(
              maxHeight: overflows
                  ? _lineBox * kCopyMaxLines
                  : double.infinity,
            ),
            child: overflows
                // 用 CupertinoScrollbar 而不是 Material 的 Scrollbar:
                // 这个文件的 material 导入是 show 白名单,没带 Scrollbar;
                // 而且整个 App 就是 Cupertino 风格,滚动条也跟着一致。
                ? CupertinoScrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      // 右边多留一点,免得滚动条压在字上
                      padding: const EdgeInsets.fromLTRB(14, 16, 10, 16),
                      child: text,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    child: text,
                  ),
          ),
        );
      },
    );
  }
}

/// 从地址里取一个像样的扩展名,取不到就用 [fallback]。
///
/// 不能一律写死:抖音图集常见 .jpeg / .webp,音频有 .mp3 / .m4a,视频是 .mp4 ——
/// 扩展名和 MIME 一起决定媒体库把它归到哪、能不能被相册或播放器正确打开。
String urlExt(String url, String fallback) {
  final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  if (segments.isEmpty) return fallback;
  final last = segments.last;
  final dot = last.lastIndexOf('.');
  if (dot < 0) return fallback;
  final ext = last.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : fallback;
}

/// 图集图片的扩展名。见 [urlExt]。
String imageExt(String url) => urlExt(url, 'jpg');

/// 缩略图网格里的一格:一条地址 + 它是不是视频。
///
/// 视频那几格的封面用接口给的首帧,右下角压一个播放标识和图片区分开。
typedef MediaThumb = ({String url, bool isVideo});

/// 混合卡的缩略图条目:视频在前、图片在后。
///
/// 顺序和 [PreviewCardState._items] 必须一致 —— 选中状态是按这里的下标存的,
/// 两边错了就会「点第一格选中第三格」。
List<MediaThumb> galleryEntries(ParseResult result) => <MediaThumb>[
  for (final v in result.videoItems) (url: v.coverUrl ?? '', isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 混合卡里真正要下载的东西。顺序与 [galleryEntries] 一一对应(选中按同一个下标
/// 存),但视频那一格给的是**视频地址**,不是封面。
///
/// 封面是给网格显示的 jpg。拿它当视频下,文件名会按地址取到 `.jpg`、MIME 变成
/// image/jpeg,而 kind 还是 video —— 媒体库直接拒收:
/// `publish_failed: MIME type image/jpeg cannot be inserted into
/// content://media/external_primary/video/media`。
List<({String url, bool isVideo})> mixedMedia(ParseResult result) => [
  for (final v in result.videoItems) (url: v.url, isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 预览区的缩略图条:一条横向缩略图,底下一行数量。
///
/// 图集用图片,两个以上视频用视频封面 —— 需求就是这两种走同一套排版。
/// 高度写死 96:横向列表在竖向列表里必须有确定高度;竖向滚动与横向滚动各管各的,
/// 手势不会互相抢。
///
/// [selectable] 为真(两条以上媒体)时点一下缩略图切换选中,选中的角标是
/// 中心一个圆圈加勾;单选一条的链接不带到选中逻辑,点图也不选中。
class GalleryStage extends StatelessWidget {
  const GalleryStage({
    super.key,
    required this.isDark,
    required this.entries,
    required this.selected,
    required this.onTapTile,
    required this.emptyHint,
    required this.unit,
  });

  static const double _tileWidth = 72;
  static const double _tileHeight = 96;

  final bool isDark;
  final List<MediaThumb> entries;
  final Set<int> selected;
  final ValueChanged<int> onTapTile;

  /// 没有内容时显示的那句话。
  final String emptyHint;

  /// 数量后面那个量词:「张」/「个」/「项」。
  final String unit;

  /// 两条以上才有「选中」这回事:一条链接只有一条媒体时,点图不选中,
  /// 底部也直接给一颗能按的「下载媒体」。
  bool get _selectable => entries.length > 1;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);

    if (entries.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SizedBox(
          height: _tileHeight,
          child: Center(
            child: Text(
              emptyHint,
              style: TextStyle(color: secondary, fontSize: 13),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _tileHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => GalleryTile(
              isDark: isDark,
              thumb: entries[index],
              width: _tileWidth,
              height: _tileHeight,
              selectable: _selectable,
              selected: selected.contains(index),
              onTap: () => onTapTile(index),
              // 视频封面不是一张能看的图,不给眼睛(它自己那格已经有播放标识)。
              onPreview: entries[index].isVideo
                  ? null
                  : () => _openPreview(context, entries[index].url),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '共 ${entries.length} $unit',
          style: TextStyle(color: secondary, fontSize: 12.5),
        ),
      ],
    );
  }

  /// 点缩略图右下角那只眼睛:开一个窗口看这张图的原片。
  ///
  /// 传进去的就是这一格自己那条地址 —— 上游给的图集地址本来就是原图,没有另给一条
  /// 缩略图地址。窗口里按图片自己的分辨率解码(`Image.network` 不传 cacheWidth),
  /// 不是把 72 宽的缩略图拉大。
  void _openPreview(BuildContext context, String url) {
    unawaited(
      showGlassLayer<void>(
        context,
        builder: (_) => ImageViewerDialog(url: url),
      ),
    );
  }
}

/// 缩略图条里的一格。
///
/// 静态展示时就是一个圆角图;可选中时整格可点,选中后中央压一层圆圈加勾,
/// 并给整格描一圈强调色边 —— 缩略图横条在深色玻璃上,单靠中心圈不够显眼。
class GalleryTile extends StatelessWidget {
  const GalleryTile({
    super.key,
    required this.isDark,
    required this.thumb,
    required this.width,
    required this.height,
    required this.selectable,
    required this.selected,
    required this.onTap,
    required this.onPreview,
  });

  final bool isDark;
  final MediaThumb thumb;
  final double width;
  final double height;
  final bool selectable;
  final bool selected;
  final VoidCallback onTap;

  /// 点右下角那只眼睛的回调。null = 这格不是图片(视频封面),不给眼睛。
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);

    // 尺寸写死:横向列表里 Stack 的 fit 是 expand,不给死宽度它就问父级要,
    // 而父级给的是无限宽 —— 直接崩在 layout 上。
    final tile = SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: fill,
              // 单张挂了不影响整条:退回一块占位图标(图和视频用不同的)
              child: Image.network(
                thumb.url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    thumb.isVideo
                        ? CupertinoIcons.play_circle_fill
                        : CupertinoIcons.photo,
                    size: 22,
                    color: secondary.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ),
          // 视频那几格右下角压一个播放标识,一眼分得出哪格是视频、哪格是图片。
          if (thumb.isVideo)
            Positioned(
              right: 4,
              bottom: 4,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x8C000000),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    CupertinoIcons.play_fill,
                    size: 11,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
          // 图片那几格右下角压一只眼睛,和视频的播放标识同一处、同一套底(半透明黑圆
          // 加白色图形),一眼分得出这格是图片、点它能看大图。
          //
          // 触摸区比标识本身大一圈(标识 17,这里 29):11 像素的图形手指按不准。
          // 这层在 Stack 里排在后面,命中最先落到它身上,外层那颗「点图选中」不会
          // 被一起触发。
          if (onPreview != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                button: true,
                label: '查看大图',
                child: GestureDetector(
                  onTap: onPreview,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(8, 8, 4, 4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0x8C000000),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(
                          CupertinoIcons.eye_fill,
                          size: 11,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                // 边框压在圆角图上会被裁掉一角,半径比图大 2:角上刚好露满
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent, width: 2),
              ),
            ),
          if (selected)
            Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  border: Border.all(
                    color: const Color(0xFFFFFFFF),
                    width: 1.6,
                  ),
                ),
                child: const Icon(
                  CupertinoIcons.check_mark,
                  size: 16,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
        ],
      ),
    );

    if (!selectable) return tile;
    return GestureDetector(
      onTap: onTap,
      // 缩略图是缩略图,不是按钮:点击反馈给在选中角标上,不铺水波纹
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }
}

/// 点缩略图右下角那只眼睛弹出来的大图预览。
///
/// 窗口里是**这张图的原片**:`Image.network` 不传 cacheWidth,解码器按图片自己的
/// 分辨率解,不是把 72 宽的缩略图拉大。加载中、加载失败时窗口一样高 —— 高度按
/// 屏幕算死,面板不给大图撑得上下跳。
///
/// 图下面那颗「关闭」是需求里指定的出口;头部右上角那颗叉是这套弹窗本来就有的,
/// 两条路都关得掉。
class ImageViewerDialog extends StatelessWidget {
  const ImageViewerDialog({super.key, required this.url});

  /// 原片地址。
  final String url;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 图片占屏幕的 58%,再留 200 给头部、关闭按钮和面板内边距 —— 横屏或小屏上
    // 面板(Column,不滚动)会装不下那么多行,撑破就是一条黄黑警告带。
    final imageHeight = math.min(screenHeight * 0.58, screenHeight - 200);

    return PopupShell(
      title: '图片预览',
      icon: homeIcon(context, '图集预览.svg'),
      // 比普通提示卡宽:300 宽的面板里那张图只剩 272,看不出"大图"
      maxWidth: 380,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: fill,
              child: SizedBox(
                width: double.infinity,
                height: imageHeight,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(child: CupertinoActivityIndicator()),
                  // 地址多半带签名、会过期,下来就退回一个占位图,别让窗口空着
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      CupertinoIcons.photo,
                      size: 34,
                      color: secondary.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}


/// 一秒级的时间文本(mm:ss)。超过一小时会自然变成三位的分,不做特殊处理。
String clock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 播放控件外面那层渐变底。
///
/// 音频卡整块都是这个渐变;媒体卡的播放行现在也套同一层 —— 两处的播放控件
/// 看起来才是一套东西,而不是一个有底一个光秃秃。
class PlaybackPanel extends StatelessWidget {
  const PlaybackPanel({super.key, required this.isDark, required this.child});

  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0x3D2E6BD6), Color(0x14000000)]
              : const [Color(0x2E1677FF), Color(0x0A1677FF)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: child,
      ),
    );
  }
}

/// 播放控件一行:播放/暂停 + 可拖的进度条 + 已播/总时长。
///
/// 音频和视频共用 —— 两边的播放语义完全一样,只有外面那层壳不同
/// (都套 [PlaybackPanel],音频上面没有画面,视频上面是 16:9 画面)。
class PlaybackRow extends StatelessWidget {
  const PlaybackRow({
    super.key,
    required this.isDark,
    required this.playing,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onToggle,
    required this.onSeek,
  });

  final bool isDark;
  final bool playing;
  final Duration position;

  /// 还没读出时长时为 null(音频要等 setUrl 完成,视频要等 initialize 完成)。
  final Duration? duration;

  /// 播放器可用才亮;没地址或加载失败时整行是灰的。
  final bool enabled;
  final VoidCallback onToggle;

  /// 拖进度条。参数是目标位置。
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final total = duration;

    return Row(
      children: [
        PlainTap(
          onTap: enabled ? onToggle : null,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? accent : secondary.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: Icon(
              playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              size: 18,
              // 深色模式的强调色是亮蓝,压白图标会糊;那里换成近黑
              color: isDark ? const Color(0xFF10161F) : const Color(0xFFFFFFFF),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              ScrubBar(
                position: position,
                duration: total,
                onSeek: onSeek,
                accent: accent,
                track: secondary.withValues(alpha: 0.28),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    clock(position),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                  const Spacer(),
                  Text(
                    total == null ? '--:--' : clock(total),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可拖可点的进度条。
///
/// 触摸区给到 20 高(而不是那 4 个像素),否则手指根本按不准;
/// 位置按整个宽度等比换算成时间。
class ScrubBar extends StatelessWidget {
  const ScrubBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.accent,
    required this.track,
  });

  final Duration position;
  final Duration? duration;
  final ValueChanged<Duration> onSeek;
  final Color accent;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = duration?.inMilliseconds ?? 0;
        final width = constraints.maxWidth;
        final fraction = total <= 0
            ? 0.0
            : (position.inMilliseconds / total).clamp(0.0, 1.0);

        void seekTo(double dx) {
          if (total <= 0 || width <= 0) return;
          final f = (dx / width).clamp(0.0, 1.0);
          onSeek(Duration(milliseconds: (f * total).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seekTo(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
          child: SizedBox(
            height: 20,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: track)),
                      // 宽度直接算出来,不用 Expanded(flex:):fraction 为 0 时
                      // flex 也是 0,而 flex 0 的子项在 Row 里会退化成「按自身尺寸」,
                      // 进度条会整根跳到满格。
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: width * fraction,
                        child: ColoredBox(color: accent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 媒体预览区:16:9 的视频播放器。
///
/// 画面读出来之前用**封面当首帧**:接口在 `cover_url` 里给了封面,却空着窗口写
/// 「无封面」很怪。真没有封面时才退化成那句话。
///
/// 左右滑动画面可以调进度,和下面进度条走同一套 seek 逻辑。
class VideoStage extends StatefulWidget {
  const VideoStage({super.key, required this.isDark, required this.url, this.coverUrl});

  final bool isDark;
  final String url;

  /// 封面地址。当首帧占位用,拿不到就写「无封面」。
  final String? coverUrl;

  @override
  State<VideoStage> createState() => VideoStageState();
}

class VideoStageState extends State<VideoStage> {
  VideoPlayerController? _controller;
  bool _failed = false;

  /// seek 是异步的。拖动时每一帧都发一次会把播放器塞满,上一个没回来就丢新的。
  bool _seeking = false;

  /// 这一条视频的播放位置只接回去一次,别把用户后来的拖动也覆盖掉。
  bool _restored = false;

  /// 消费到第几次暂停/恢复信号了。只处理比自己新的那些。
  int _seenPause = 0;
  int _seenResume = 0;

  /// 点「下载媒体」那一刻这条视频在不在播。在播的话,下载结束要接着播。
  bool _resumeAfterDownload = false;

  /// 当前播放器有没有接上暂停信号。
  bool _listeningPause = false;

  @override
  void initState() {
    super.initState();
    _seenPause = Playback.pauseRequests.value;
    _seenResume = Playback.resumeRequests.value;
    Playback.pauseRequests.addListener(_onPauseRequest);
    Playback.resumeRequests.addListener(_onResumeRequest);
    _listeningPause = true;
    _load();
  }

  @override
  void didUpdateWidget(VideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换一条链接重新解析时,这个 State 会被复用(同类型、同位置),initState 不会
    // 再跑。不在这里换掉播放器,画面和时长就一直停在上一条视频上。
    if (oldWidget.url != widget.url) {
      _controller?.dispose();
      _controller = null;
      _failed = false;
      _seeking = false;
      _restored = false;
      _resumeAfterDownload = false;
      _load();
    }
  }

  /// 点「下载媒体」时收到一次信号:**暂停**,播放器留着。
  ///
  /// 早先这里是直接把播放器 dispose 掉(当时预览播的是 8K 原画,缓冲几十秒就是
  /// 上百 MB,和下载抢内存)。现在预览走的是最低码率那一档(见
  /// [ParseResult.previewVideoUrl]),占的内存很小,于是改成暂停:下载结束还能
  /// 接着看,画面停在原处,不用重新缓冲。
  ///
  /// 位置先记下来,万一播放器后来还是得重建,`Playback.recall` 靠着它接回原处。
  void _onPauseRequest() {
    final request = Playback.pauseRequests.value;
    if (request == _seenPause) return;
    _seenPause = request;
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isInitialized) {
      Playback.remember(widget.url, controller.value.position);
    }
    _resumeAfterDownload = controller.value.isPlaying;
    controller.pause();
  }

  /// 下载那一趟结束了:点下载前在播的话,接着播。
  void _onResumeRequest() {
    final request = Playback.resumeRequests.value;
    if (request == _seenResume) return;
    _seenResume = request;
    if (!_resumeAfterDownload) return;
    _resumeAfterDownload = false;
    _controller?.play();
  }

  Future<void> _load() async {
    if (widget.url.isEmpty) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setLooping(true);
      // 这条视频上次播到哪就接回哪 —— 切走再切回来不该打回 00:00。
      final remembered = Playback.recall(widget.url);
      if (remembered != null && !_restored) {
        _restored = true;
        await controller.seekTo(remembered);
      }
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      // 平台插件缺失(测试环境)或地址取不到,都退化成一块占位,
      // 不能让一张卡把整页搞崩。
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 画面还没出来时的占位:有封面就铺封面,没有才写字。
  ///
  /// 加载失败也走这里 —— 黑框比封面难看,而且封面本来就是这张视频的内容。
  /// 失败时在封面上压一层暗底加一句说明,别让人以为是在加载。
  Widget _poster(Color secondary) {
    final cover = widget.coverUrl;
    Widget caption(String text) => Center(
      child: Text(text, style: TextStyle(color: secondary, fontSize: 13)),
    );

    if (cover == null) return caption(_failed ? '视频无法播放' : '无封面');

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          cover,
          fit: BoxFit.cover,
          // 封面是带签名的临时地址,过一段时间会 403 —— 那时退回那句话。
          errorBuilder: (_, _, _) => caption(_failed ? '视频无法播放' : '无封面'),
        ),
        if (_failed)
          ColoredBox(
            color: const Color(0x99000000),
            child: const Center(
              child: Text(
                '视频无法播放',
                style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    if (_listeningPause) {
      Playback.pauseRequests.removeListener(_onPauseRequest);
      Playback.resumeRequests.removeListener(_onResumeRequest);
    }
    // 离开页面前把进度记下来:页面被销毁时播放器也跟着没了,下次要靠这个接回去。
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      Playback.remember(widget.url, controller.value.position);
    }
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _seekTo(Duration target) async {
    final controller = _controller;
    if (controller == null || _seeking) return;
    _seeking = true;
    try {
      await controller.seekTo(target);
    } catch (_) {
      // 播放器已随页面销毁时会抛,忽略。
    } finally {
      _seeking = false;
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = settingsPalette(isDark).secondary;
    final controller = _controller;

    if (controller == null || _failed) {
      return Column(
        children: [
          _frame(_poster(secondary)),
          const SizedBox(height: 12),
          PlaybackPanel(
            isDark: isDark,
            child: PlaybackRow(
              isDark: isDark,
              playing: false,
              position: Duration.zero,
              duration: null,
              enabled: false,
              onToggle: () {},
              onSeek: (_) {},
            ),
          ),
        ],
      );
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final ready = value.isInitialized;
        final duration = ready ? value.duration : null;
        // 每一帧都记一下播到哪了。销毁时再读一次是异步的、可能来不及,
        // 所以以这里为准。
        if (ready && value.position > Duration.zero) {
          Playback.remember(widget.url, value.position);
        }

        // 封面一直铺到画面真的开始走为止。
        //
        // 两个都不能用「初始化完成」:初始化只代表容器解析完了,离能看还差得远。
        // 也不能只用 isPlaying:按下播放那一刻 isPlaying 就为真,而高码率视频
        // (实测一条 8K 的缓冲了近一分钟)在这之后还要等很久才有第一帧 ——
        // 那时把封面淡掉,用户看到的就是一大片黑。
        // position > 0 说明画面已经在走了,这时候换上去才正好接上。
        final showFrame = ready && value.position > Duration.zero;

        // 比窗口还宽的视频用 cover 铺满,去掉上下黑边;比窗口窄的(竖屏短视频)
        // 保持 contain —— 竖屏视频在 16:9 窗口里 cover 会被裁成中间一条。
        final videoAspect = value.size.height > 0
            ? value.size.width / value.size.height
            : 0.0;
        final tooWide = ready && videoAspect > 16 / 9;

        return Column(
          children: [
            _frame(
              Stack(
                fit: StackFit.expand,
                children: [
                  if (ready)
                    FittedBox(
                      fit: tooWide ? BoxFit.cover : BoxFit.contain,
                      child: SizedBox(
                        width: value.size.width,
                        height: value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  // 封面压在画面上,开始播放后淡出 —— 淡出这 320ms 正好留给
                  // 首帧解码,不然按下播放会先闪一下黑。
                  AnimatedOpacity(
                    opacity: showFrame ? 0 : 1,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOut,
                    child: IgnorePointer(child: _poster(secondary)),
                  ),
                  // 左右滑动画面调进度。放最上层,免得手势被视频层吃掉。
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          if (duration == null ||
                              duration.inMicroseconds <= 0 ||
                              constraints.maxWidth <= 0) {
                            return;
                          }
                          final delta = Duration(
                            microseconds:
                                (details.delta.dx /
                                        constraints.maxWidth *
                                        duration.inMicroseconds)
                                    .round(),
                          );
                          final target = value.position + delta;
                          _seekTo(
                            target < Duration.zero
                                ? Duration.zero
                                : (target > duration ? duration : target),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            PlaybackPanel(
              isDark: isDark,
              child: PlaybackRow(
                isDark: isDark,
                playing: value.isPlaying,
                position: value.position,
                duration: duration,
                enabled: true,
                onToggle: _toggle,
                onSeek: _seekTo,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 16:9 的画面框,圆角与底色和另外几块预览区一致。
  Widget _frame(Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(color: const Color(0xFF000000), child: child),
    ),
  );
}

/// 音频预览区:真的播放器。
///
/// 播放/暂停、时长、可拖的进度条都由 [AudioPlayer] 驱动 ——
/// 之前那颗只切换图形的假按钮已经换掉了。
class AudioStage extends StatefulWidget {
  const AudioStage({super.key, required this.isDark, required this.url});

  final bool isDark;
  final String url;

  @override
  State<AudioStage> createState() => AudioStageState();
}

class AudioStageState extends State<AudioStage> {
  AudioPlayer? _player;
  bool _failed = false;

  /// 这一条音频的位置只接回去一次。
  bool _restored = false;

  /// 消费到第几次暂停/恢复信号了。
  int _seenPause = 0;
  int _seenResume = 0;

  /// 点「下载媒体」那一刻这条音频在不在播。在播的话,下载结束要接着播。
  bool _resumeAfterDownload = false;

  @override
  void initState() {
    super.initState();
    _seenPause = Playback.pauseRequests.value;
    _seenResume = Playback.resumeRequests.value;
    Playback.pauseRequests.addListener(_onPauseRequest);
    Playback.resumeRequests.addListener(_onResumeRequest);
    _load();
  }

  @override
  void didUpdateWidget(AudioStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同 VideoStage:换链接重新解析时 State 会被复用,不在这里换播放器的话
    // 听到的还是上一条视频的音源(实测:换了链接时长还停在上一条的 00:17)。
    if (oldWidget.url != widget.url) {
      _player?.dispose();
      _player = null;
      _failed = false;
      _restored = false;
      _resumeAfterDownload = false;
      _load();
    }
  }

  /// 点「下载媒体」时收到一次信号:暂停(理由同 [VideoStageState._onPauseRequest])。
  void _onPauseRequest() {
    final request = Playback.pauseRequests.value;
    if (request == _seenPause) return;
    _seenPause = request;
    final player = _player;
    if (player == null) return;
    Playback.remember(widget.url, player.position);
    _resumeAfterDownload = player.playing;
    player.pause();
  }

  /// 下载那一趟结束了:点下载前在播的话,接着播。
  void _onResumeRequest() {
    final request = Playback.resumeRequests.value;
    if (request == _seenResume) return;
    _seenResume = request;
    if (!_resumeAfterDownload) return;
    _resumeAfterDownload = false;
    _player?.play();
  }

  Future<void> _load() async {
    if (widget.url.isEmpty) return;
    try {
      final player = AudioPlayer();
      _player = player;
      await player.setUrl(widget.url);
      // 上次播到哪就接回哪,切走再切回来不打回 00:00。
      final remembered = Playback.recall(widget.url);
      if (remembered != null && !_restored) {
        _restored = true;
        await player.seek(remembered);
      }
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    Playback.pauseRequests.removeListener(_onPauseRequest);
    Playback.resumeRequests.removeListener(_onResumeRequest);
    final player = _player;
    if (player != null) {
      Playback.remember(widget.url, player.position);
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    if (player.playing) {
      await player.pause();
    } else {
      // 播完再按就从头开始,否则按下去没反应。
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final player = _player;

    return PlaybackPanel(
      isDark: isDark,
      child: player == null || _failed
          ? PlaybackRow(
              isDark: isDark,
              playing: false,
              position: Duration.zero,
              duration: null,
              enabled: false,
              onToggle: () {},
              onSeek: (_) {},
            )
          : StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, stateSnapshot) {
                final state = stateSnapshot.data;
                final playing =
                    (state?.playing ?? false) &&
                    state?.processingState != ProcessingState.completed;
                return StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, positionSnapshot) {
                    final position = positionSnapshot.data ?? Duration.zero;
                    // 每一帧记一下播到哪(销毁时再读是异步的,可能来不及)。
                    if (position > Duration.zero) {
                      Playback.remember(widget.url, position);
                    }
                    return PlaybackRow(
                      isDark: isDark,
                      playing: playing,
                      position: position,
                      duration: player.duration,
                      enabled: true,
                      onToggle: _toggle,
                      onSeek: (target) => player.seek(target),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 三张预览卡底部那颗动作按钮(下载媒体 / 复制文案)。做成次级按钮(淡底 + 强调色
/// 文字):同一屏里出现三次,全用实心主色会把首页压成一片蓝,主按钮只留给「开始解析」。
class CardActionButton extends StatelessWidget {
  const CardActionButton({
    super.key,
    required this.isDark,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final bool isDark;
  final String label;
  final String icon;

  /// 解析结果还没出来、或者还没选中媒体时传 null,按钮自动置灰。
  final VoidCallback? onPressed;

  /// 「全选媒体」专用:全部选中时压一层强调色底,一眼看出当前是全选状态。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        // 两颗按钮并排时文字要收着点,否则「全选媒体 + 下载媒体」在小屏上会换行
        padding: const EdgeInsets.symmetric(horizontal: 10),
        backgroundColor: active
            ? accent.withValues(alpha: isDark ? 0.30 : 0.18)
            : (isDark ? const Color(0x1FFFFFFF) : const Color(0x141257C9)),
        foregroundColor: accent,
      ),
      onPressed: onPressed,
      // 颜色跟着上面的 foregroundColor 走,不写死
      icon: TintedSvgIcon(homeIcon(context, icon), size: 20),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

