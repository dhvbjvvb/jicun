import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:jicun/failure.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/playback.dart';
import 'package:jicun/ui/player_ui.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// 音频卡的预览播放区,从 lib/pages/preview.dart 拆出来。
///
/// 和视频那块的形状一样(播放器 + 暂停/恢复信号),但兜底路径完全不同:它多一条
/// 「流式加载失败就改用下载器那套把整段抓到本地再放」的路(见
/// [fetchAudioPreviewFile]),连缓存命名也一起放着,所以两个文件不合并。

/// 音频预览区:真的播放器。
///
/// 播放/暂停、时长、可拖的进度条都由 [AudioPlayer] 驱动 ——
/// 之前那颗只切换图形的假按钮已经换掉了。
class AudioStage extends StatefulWidget {
  const AudioStage({super.key, required this.isDark, required this.url});

  /// 流式加载失败时是否改用本地缓存兜底(见 [_load])。
  ///
  /// **只给测试关**:widget 测试用的是假时钟,真实网络 I/O 的 Future 不会被它推进,
  /// 兜底会把用例挂在 pending 上。生产永远是 true。
  @visibleForTesting
  static bool localCacheFallback = true;

  final bool isDark;
  final String url;

  @override
  State<AudioStage> createState() => AudioStageState();
}

class AudioStageState extends State<AudioStage> {
  AudioPlayer? _player;
  bool _failed = false;

  /// 加载失败的原文,原样显示在卡上(见 [_load])。
  String _error = '';

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
      _error = '';
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
    final player = AudioPlayer();
    _player = player;
    // **先把这一行交出去**,别等 setUrl:它要等远端把头几个字节吐回来(小文件几十
    // 毫秒,一条几十分钟的音频要等播放器把索引读完才算得出时长)。原来非等它 await
    // 完才 setState,那段时间整行是灰的、时长是空的 —— 用户点了没反应,以为坏了。
    // 点播放也不用等:just_audio 会记下这次 play,加载完自己开始。
    if (mounted) setState(() {});
    try {
      // 带上请求头:平台的 CDN 有的按 Referer 放行(见 [playbackHeaders])
      await player.setUrl(widget.url, headers: playbackHeaders(widget.url));
      // 上次播到哪就接回哪,切走再切回来不打回 00:00。
      final remembered = Playback.recall(widget.url);
      if (remembered != null && !_restored) {
        _restored = true;
        await player.seek(remembered);
      }
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      // 把原文留在卡上:静默灰着的话,用户看到的只是「点了没反应」,连是 403 还是
      // 超时都问不出来。
      if (!mounted) return;
      var message = '$error';
      // 流式加载被播放器的 HTTP 栈掐了(抖音音乐 CDN 实测报 `(0) SOURCE ERROR`,
      // 即 ExoPlaybackException.TYPE_SOURCE)。下载器那条路是通的 —— 改用本地缓存再放。
      if (error is PlayerException && AudioStage.localCacheFallback) {
        setState(() {
          _failed = true;
          _error = '正在改用本地缓存…';
        });
        final cached = await fetchAudioPreviewFile(widget.url);
        // 抓的过程中用户可能换了链接 / 关掉了卡片:那样就别再动这个播放器。
        if (!mounted || !identical(_player, player)) return;
        if (cached != null) {
          try {
            await player.setFilePath(cached.path);
            final remembered = Playback.recall(widget.url);
            if (remembered != null && !_restored) {
              _restored = true;
              await player.seek(remembered);
            }
            if (mounted && identical(_player, player)) {
              setState(() {
                _failed = false;
                _error = '';
              });
            }
            return;
          } catch (fallbackError) {
            message = '$fallbackError';
          }
        }
      }
      if (mounted && identical(_player, player)) {
        setState(() {
          _failed = true;
          _error = message;
        });
      }
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

    final Widget row = player == null || _failed
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
                  // 时长单独接一条流:`setUrl` 返回时它多半还没算出来(播放器得先把
                  // 文件头读完),而 positionStream 没播之前根本不发事件 —— 只读一次
                  // `player.duration` 的话时长会一直空着,得等下一次重建才补上。
                  return StreamBuilder<Duration?>(
                    stream: player.durationStream,
                    builder: (context, durationSnapshot) => PlaybackRow(
                      isDark: isDark,
                      playing: playing,
                      position: position,
                      duration: durationSnapshot.data ?? player.duration,
                      enabled: true,
                      onToggle: _toggle,
                      onSeek: player.seek,
                    ),
                  );
                },
              );
            },
          );

    return PlaybackPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '音频加载失败:$_error',
              style: TextStyle(
                color: Palette.of(isDark).danger,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 音频预览的本地缓存:流式加载失败时,改用下载器那套(Dart 的 HttpClient + 浏览器 UA
/// + 重试)把整段音频抓到缓存文件再放。
///
/// 为什么需要它:抖音的 `*.douyinstatic.com` 在部分机型/网络下,ExoPlayer 会报
/// `(0) SOURCE ERROR`(ExoPlaybackException.TYPE_SOURCE),而**同一地址下载器却能下**
/// —— 差别在播放器的 HTTP 栈(默认 8s 超时、不重试)。下载器走通了,就用它那套兜底。
Future<File?> fetchAudioPreviewFile(String url) async {
  if (url.isEmpty) return null;
  final Directory dir;
  try {
    dir = Directory('${(await getTemporaryDirectory()).path}/preview_audio');
    await dir.create(recursive: true);
  } catch (_) {
    // 测试环境里 path_provider 没有实现;拿不到缓存目录就当这次兜底不可用。
    return null;
  }
  final file = File(
    '${dir.path}/${previewAudioCacheKey(url)}.${_audioExtOf(url)}',
  );
  // 已经抓过一次就复用(大小对不上当没抓到)。
  if (await file.exists() && await file.length() > 0) return file;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, kBrowserUserAgent);
        // 和下载器同一条理由:要的是原始字节,不要任何一层压缩。
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.drain<void>();
          continue;
        }
        final part = File('${file.path}.part');
        if (await part.exists()) await part.delete();
        await response.pipe(part.openWrite());
        if (await part.length() == 0) {
          await part.delete();
          continue;
        }
        await part.rename(file.path);
        return file;
      } catch (error, stack) {
        // 这一趟不行就再来一趟;三次都不行交给调用方报错。
        swallow('audio.fetch', error, stack);
      }
    }
  } finally {
    client.close(force: true);
  }
  return null;
}

/// 缓存文件的扩展名:照抄 URL 上的后缀(播放器认它挑解码器),认不出就用 `.mp3`。
String _audioExtOf(String url) {
  final last = Uri.tryParse(url)?.pathSegments.isNotEmpty == true
      ? Uri.parse(url).pathSegments.last
      : '';
  final dot = last.lastIndexOf('.');
  final ext = dot >= 0 && dot < last.length - 1
      ? last.substring(dot + 1).toLowerCase()
      : '';
  const known = <String>['mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac', 'mp4'];
  return known.contains(ext) ? ext : 'mp3';
}

/// 缓存文件名:URL 的 FNV-1a 32 位十六进制。够短、稳定,不引额外的 hash 依赖。
String previewAudioCacheKey(String url) {
  var hash = 0x811C9DC5;
  for (final unit in url.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
