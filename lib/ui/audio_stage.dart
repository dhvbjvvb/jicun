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
      // 带上请求头:平台的 CDN 有的按 Referer / UA 放行(见 [playbackHeaders],
      // 两个头缺一不可的那种就是 B 站)
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
      // 流式加载被播放器的 HTTP 栈掐了(实测报 `(0) SOURCE ERROR`,即
      // ExoPlaybackException.TYPE_SOURCE)。下载器那条路是通的 —— 改用本地缓存再放。
      if (error is PlayerException && AudioStage.localCacheFallback) {
        setState(() {
          _failed = true;
          _error = '正在改用本地缓存…';
        });
        final fetched = await fetchAudioPreviewFile(widget.url);
        // 抓的过程中用户可能换了链接 / 关掉了卡片:那样就别再动这个播放器。
        if (!mounted || !identical(_player, player)) return;
        final cached = fetched.file;
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
        } else if (fetched.reason.isNotEmpty) {
          // 兜底也没成:把它的理由一起留在卡上。原来这里还是那句 `(0) SOURCE ERROR`
          // —— 那句话把 403、超时、文件太大全糊成一团,排障时只能靠猜(见
          // [fetchAudioPreviewFile] 的说明)。
          message = '$message(本地缓存:${fetched.reason})';
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

/// [fetchAudioPreviewFile] 的结果:[file] 拿不到时,[reason] 说明为什么。
///
/// 为什么要把理由带出来:兜底失败时卡上留的原来还是流式那次的原文(一句
/// `(0) SOURCE ERROR`),403、超时、文件太大全糊成一团,排障只能靠猜。
typedef AudioPreviewFetch = ({File? file, String reason});

/// 预览音频缓存的**总体积预算**:120MB。
///
/// 这条路的产物是缓存目录里的一份**完整音频**,而缓存目录在 data 分区 —— 一条几小时的
/// 直播回放能到几百 MB,那不是「能预览」,是把手机塞满。所以按**整个目录**封顶:每抓成
/// 一条就回头收一次,超了淘汰最久没用过的那几条(见 `_trimCache`)。
const int kPreviewAudioCacheLimitBytes = 120 * 1024 * 1024;

/// 音频预览的本地缓存:流式加载失败时,改用下载器那套(Dart 的 HttpClient +
/// **下载器同款请求头** + 重试)把整段音频抓到缓存文件再放。
///
/// 为什么需要它:有些 CDN 在部分机型/网络下会让 ExoPlayer 报 `(0) SOURCE ERROR`
/// (ExoPlaybackException.TYPE_SOURCE),而**同一地址下载器却能下** —— 差别在播放器的
/// HTTP 栈(默认 8s 超时、不重试,带的请求头也不一样)。下载器走通了,就用它那套兜底。
///
/// **请求头必须和下载器一字不差**(见 `fetchHeaders`):这条路的全部理由就是「下载器过
/// 得去、播放器过不去」,而这里曾经图省事发的是浏览器 UA —— B 站的镜像域名只认桌面 UA
/// + Referer,于是兜底三次全 403,卡上留下的还是那句看不懂的 `(0) SOURCE ERROR`。
///
/// [budgetBytes] 只给测试调小 —— 不然验「超了淘汰最旧的」要真下 120MB。见
/// [kPreviewAudioCacheLimitBytes]。
Future<AudioPreviewFetch> fetchAudioPreviewFile(
  String url, {
  int budgetBytes = kPreviewAudioCacheLimitBytes,
}) async {
  if (url.isEmpty) return (file: null, reason: '');
  final Directory dir;
  try {
    dir = Directory('${(await getTemporaryDirectory()).path}/preview_audio');
    await dir.create(recursive: true);
  } catch (_) {
    // 测试环境里 path_provider 没有实现;拿不到缓存目录就当这次兜底不可用。
    return (file: null, reason: '');
  }
  final file = File(
    '${dir.path}/${previewAudioCacheKey(url)}.${_audioExtOf(url)}',
  );
  // 已经抓过一次就复用(大小对不上当没抓到)。顺手把时间戳推到现在:淘汰看的是
  // 「最久没用过」,用过一次就不该还按旧文件算。
  if (await file.exists() && await file.length() > 0) {
    await _touch(file);
    await _trimCache(dir, keep: file, budgetBytes: budgetBytes);
    return (file: file, reason: '');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var reason = '';
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        // 和下载器同款:认得出的平台补 Referer + 桌面 UA(见 `fetchHeaders`)。
        for (final header in fetchHeaders(url).entries) {
          request.headers.set(header.key, header.value);
        }
        // 和下载器同一条理由:要的是原始字节,不要任何一层压缩。
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != 200 && response.statusCode != 206) {
          reason = 'HTTP ${response.statusCode}';
          await response.drain<void>();
          continue;
        }
        final part = File('${file.path}.part');
        if (await part.exists()) await part.delete();
        final written = await _fetchInto(response, part);
        if (written == 0) {
          // 收成空文件:当这一趟没成,半截文件不留。
          await part.delete();
          continue;
        }
        await part.rename(file.path);
        // 多了一条就收一次目录:预算之内留着,超了从最久没用过的开始删。
        await _trimCache(dir, keep: file, budgetBytes: budgetBytes);
        return (file: file, reason: '');
      } catch (error, stack) {
        // 这一趟不行就再来一趟;三次都不行交给调用方报错。
        reason = '$error';
        swallow('audio.fetch', error, stack);
      }
    }
  } finally {
    client.close(force: true);
  }
  return (file: null, reason: reason);
}

/// 把整个缓存目录收进 [budgetBytes]:从**最久没用过**的开始删,直到装得下。
///
/// 两条例外,都是刻意的:
/// - [keep] 是这一趟要交出去的那份(也正被播放器放着),**永远不删** —— 删了就是
///   「刚抓完的文件不见了」。所以一个自己就超过预算的大文件会先留在盘上,等下一次
///   抓取时以「最旧」的身份被淘汰掉;
/// - 删不动(被占用、没权限)就收手 —— 这里只是省空间,不该连累播放。
Future<void> _trimCache(
  Directory dir, {
  required File keep,
  required int budgetBytes,
}) async {
  try {
    // 拿文件名(不是整条路径)认「这一趟要交出去的那份」:临时目录的路径在这边是
    // `\` 拼的,而调用方那份是拿 `/` 拼的(见 [fetchAudioPreviewFile])—— 比整条
    // 路径会在 Windows 上认不出来,刚抓好的那条就会被自己删掉(实测踩过)。
    final keepName = keep.uri.pathSegments.last;
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((file) => file.uri.pathSegments.last != keepName)
            .toList()
          // 最久没用过的排前面。同一次运行里连着写的两条时间戳可能撞在一起,那种情况
          // 再按名字定序 —— 顺序本身不重要,重要的是**有个确定的顺序**,别让淘汰随
          // 文件系统的调度碰运气。
          ..sort((a, b) {
            final byTime = a.statSync().modified.compareTo(
              b.statSync().modified,
            );
            return byTime != 0 ? byTime : a.path.compareTo(b.path);
          });
    var total = 0;
    for (final file in dir.listSync().whereType<File>()) {
      total += file.statSync().size;
    }
    for (final file in files) {
      if (total <= budgetBytes) break;
      final size = file.statSync().size;
      file.deleteSync();
      total -= size;
    }
  } catch (error, stack) {
    // 收不动无所谓:下次抓成一条时再收一次。
    swallow('audio.trim', error, stack);
  }
}

/// 把文件的时间戳推到现在 —— 淘汰按「上次用过」算,不是「最早写下」。
Future<void> _touch(File file) async {
  try {
    await file.setLastModified(DateTime.now());
  } catch (error, stack) {
    // 推不动也不影响播放,只是这一条的淘汰次序会偏。
    swallow('audio.touch', error, stack);
  }
}

/// 把响应体写进 [target],返回写了多少字节(0 = 空响应)。
Future<int> _fetchInto(HttpClientResponse response, File target) async {
  final sink = target.openWrite();
  var written = 0;
  try {
    await for (final block in response) {
      written += block.length;
      sink.add(block);
    }
    await sink.flush();
    return written;
  } finally {
    await sink.close();
  }
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
  // B 站那条 DASH 音轨叫 `.m4s`,内容却是标准的 fMP4(实测文件头 `ftypiso5…moov…mp4a`,
  // 服务端给的 Content-Type 是 video/mp4)—— 照抄后缀会得到一个谁也认不出的名字,
  // 它其实就是 `.m4a`。
  if (ext == 'm4s') return 'm4a';
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
