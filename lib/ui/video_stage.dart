import 'package:flutter/cupertino.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/playback.dart';
import 'package:jicun/ui/player_ui.dart';
import 'package:video_player/video_player.dart';

/// 媒体卡的视频预览区,从 lib/pages/preview.dart 拆出来。
///
/// 单独一个文件是因为它有独立的生命周期:播放器、暂停/恢复信号、seek 节流、
/// 换链接时重建 —— 这些和「卡片怎么排」是两件事,混在一个两千行的文件里没人
/// 分得清哪几行属于播放器(见 test/video_stage_test.dart 覆盖的那条竞态)。

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
    // **先把这次要用的播放器拿在手上**,而不是在 try 里现建:catch 里要靠它认出
    // "这个异常是不是当前这个播放器的"。见下面那段说明。
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: playbackHeaders(widget.url),
    );
    _controller = controller;
    try {
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
      //
      // **但只有当前这个播放器失败才算这条链接失败**:换链接重新解析时(见
      // didUpdateWidget),上一条那个已经被 dispose 掉的播放器也会从这里抛回来
      // (真机上是 setLooping / seekTo 打到一个已经销毁的 player id),而那时
      // _controller 已经换成新的了 —— 不判一下就会把新视频标成"视频无法播放",
      // 而且只要链接不再变就永远不会自愈。同文件的 AudioStage 一直是这么判的
      // (见那边的 identical)。
      if (mounted && identical(_controller, controller)) {
        setState(() => _failed = true);
      }
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
          const ColoredBox(
            color: Color(0x99000000),
            child: Center(
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
