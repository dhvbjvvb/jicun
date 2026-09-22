import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

/// 静图和动图的宽高比。两个素材必须同尺寸,否则切换那一刻会跳。
const double _kEggAspect = 300 / 486;

/// 连击计数:在 [window] 内凑满 [taps] 次就返回 true,并清空重新算。
///
/// 刻意不碰任何 UI —— 纯逻辑才测得干净(见 test/tap_easter_egg_test.dart),
/// 不用 pump widget 就能把窗口边界全覆盖。
class TapRally {
  TapRally({this.taps = 3, this.window = const Duration(milliseconds: 900)})
    : assert(taps > 0);

  final int taps;
  final Duration window;

  final List<DateTime> _stamps = <DateTime>[];

  /// 记一次点击。返回 true 表示这一下正好凑满 [taps] 次。
  bool register(DateTime now) {
    _stamps.removeWhere((t) => now.difference(t) > window);
    _stamps.add(now);
    if (_stamps.length < taps) return false;
    _stamps.clear();
    return true;
  }
}

/// 连点 [taps] 次触发一次:静图换成动图、放一段音效,播一轮,回到静图。
///
/// 六个实测出来的坑,别顺手改掉:
///
/// 1. **动图不会自己回到第 0 帧。** 多帧解码器把帧索引留在 codec 里,
///    `MultiFrameImageStreamCompleter.addListener` 重新挂载时只是继续
///    `getNextFrame()`,没有任何 reset。而 `AssetImage` 相等又会命中同一个
///    ImageCache 条目,所以每次触发前必须 `evict()`,否则第二次点会从半路接上。
/// 2. **静图就是动图的第 0 帧**,两层在切换那一瞬间完全重合,看不出接缝。
/// 3. **同一时刻只能显示一层。** 角色在动,动图那层盖不住静图的轮廓 —— 把两者
///    叠在 `Stack` 里,差集区域会透出底下那张,同时看见两个人(真机截图为证)。
///    所以只用**一个** `Image`,靠换 provider 换图;换图期间不留空白靠
///    `gaplessPlayback`,它会在新图解析出来之前继续画上一张。
/// 4. **所以这个 `Image` 不能挂 key。** 换了 key 就是新 Element,
///    `gaplessPlayback` 那套"留住上一张"的机制整个失效,换图瞬间角色会闪掉。
///    代价是播放中再连点三次不会重播,见 [_onTap] —— 音效也因此不会被重头放。
/// 5. **收尾不能靠定时器,也不能靠淡出。** 素材不回环(末帧和第 0 帧平均差约
///    27/255):定时器到点切回会看到姿势硬跳,交叉淡入淡出会叠出重影。唯一看
///    不出来的一刀,是在**动图自己绕回第 0 帧**那一瞬间切,见 [_watch] ——
///    所以必须数动图自己的帧,而不是数墙上时钟(挂载到真的开播之间有解码延迟)。
///    前提是素材无限循环(`repetitionCount == -1`),这条由
///    test/easter_egg_asset_test.dart 守着。
/// 6. **音效跟着动图起、跟着动图停。** 音效素材必须不长于动图
///    ([animated] 一轮的时长),否则结尾会被 [_stopSound] 切断。这里在
///    切换回静图那一刻主动停,而不是等它自己放完 —— 两者时长一致时听不出来,
///    但设备时钟有漂移,主动停能保证"图没了声音就没了"。
class TapEasterEgg extends StatefulWidget {
  const TapEasterEgg({
    super.key,
    required this.still,
    required this.animated,
    required this.sound,
    required this.width,
    this.taps = 3,
    this.window = const Duration(milliseconds: 900),
  });

  /// 静图。建议用动图第 0 帧导出,理由见类文档第 2 条。
  final String still;

  /// 动图。
  final String animated;

  /// 音效。长度不要超过 [animated] 一轮的时长,理由见类文档第 6 条。
  final String sound;

  /// 显示宽度。竖构图,高度按 [_kEggAspect] 推出来。
  final double width;

  /// 连点几次触发。
  final int taps;

  /// 连击窗口。
  final Duration window;

  @override
  State<TapEasterEgg> createState() => _TapEasterEggState();
}

class _TapEasterEggState extends State<TapEasterEgg> {
  late final TapRally _rally = TapRally(
    taps: widget.taps,
    window: widget.window,
  );

  /// 动图有多少帧。从 codec 读,不写死 —— 换素材忘了改常数的话,
  /// 收尾那一刀就会切在错误的帧上,肉眼可见。
  late final Future<int> _frameCount = _readFrameCount();

  /// 现在显示的是动图还是静图。
  bool _playing = false;

  /// 第几次触发。两次触发在异步中间态撞上时,用它在每个 await 之后作废过期的那次。
  int _run = 0;

  ImageStream? _stream;
  ImageStreamListener? _watcher;

  /// 音效预热的播放器。触发时只 seek + play,不重新准备 ——
  /// 现建一个再 `setAsset` 会有几十毫秒解码延迟,和画面错开。
  AudioPlayer? _player;
  bool _soundReady = false;

  @override
  void initState() {
    super.initState();
    // 提前把帧数和音效准备好(都是异步几十毫秒),第一次点击时一般已经好了。
    unawaited(_frameCount);
    _player = AudioPlayer();
    unawaited(_preloadSound());
  }

  @override
  void dispose() {
    _run += 1;
    _detach();
    final player = _player;
    _player = null;
    _soundReady = false;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<int> _readFrameCount() async {
    final data = await rootBundle.load(widget.animated);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final count = codec.frameCount;
    codec.dispose();
    return count;
  }

  Future<void> _preloadSound() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.setAsset(widget.sound);
      if (!mounted || _player != player) return;
      _soundReady = true;
    } catch (_) {
      // 音效加载失败不该连累彩蛋:静音播完就是。
      _soundReady = false;
    }
  }

  /// 跑一段播放器操作,顺手把异常吃掉 —— 音效出问题不该让画面遭殃。
  void _withSound(Future<void> Function(AudioPlayer player) body) {
    final player = _player;
    if (player == null || !_soundReady) return;
    unawaited(() async {
      try {
        await body(player);
      } catch (_) {
        _soundReady = false;
      }
    }());
  }

  void _startSound() {
    _withSound((player) async {
      await player.seek(Duration.zero);
      await player.play();
    });
  }

  /// 停但不清空:用 pause + 归零而不是 stop,`stop()` 会释放平台资源,
  /// 下次触发得重新准备,又变回有延迟。
  void _stopSound() {
    _withSound((player) async {
      await player.pause();
      await player.seek(Duration.zero);
    });
  }

  void _detach() {
    final watcher = _watcher;
    if (watcher != null) {
      _stream?.removeListener(watcher);
      _watcher = null;
      _stream = null;
    }
  }

  void _onTap() {
    if (!_rally.register(DateTime.now())) return;
    // 播放中不重入:重播必须换 Element 才能让 Image 重新 resolve,
    // 而换 Element 就丢了 gaplessPlayback,角色会闪一下。
    // 顺带也就满足了"播放中继续连点不会把音效重头放"。见类文档第 4 条。
    if (_playing) return;
    unawaited(_play());
  }

  Future<void> _play() async {
    final run = ++_run;
    _detach();
    final frames = await _frameCount;
    if (!mounted || run != _run) return;
    final provider = AssetImage(widget.animated);
    // 见类文档第 1 条:不清缓存就回不到第 0 帧。
    await provider.evict();
    if (!mounted || run != _run) return;
    setState(() => _playing = true);
    _startSound();
    _watch(run, provider, frames);
  }

  /// 盯着动图自己的帧发射。
  ///
  /// 第 1 次回调是第 0 帧,第 `frames` 次是末帧,第 `frames + 1` 次就是**第二圈
  /// 的第 0 帧** —— 那一帧和静图重合,在这一刻换回静图、把音效也停掉,肉眼和
  /// 耳朵都听不出切换。这里必须用同一个 provider resolve,才能和 `Image` 命中
  /// 同一个 ImageCache 条目、共享同一份帧回调。见类文档第 3、5、6 条。
  void _watch(int run, AssetImage provider, int frames) {
    final stream = provider.resolve(ImageConfiguration.empty);
    var seen = 0;
    late final ImageStreamListener watcher;
    watcher = ImageStreamListener((ImageInfo _, bool _) {
      seen += 1;
      if (seen <= frames || run != _run) return;
      stream.removeListener(watcher);
      if (_watcher == watcher) {
        _watcher = null;
        _stream = null;
      }
      _stopSound();
      if (mounted) setState(() => _playing = false);
    });
    _stream = stream;
    _watcher = watcher;
    stream.addListener(watcher);
  }

  @override
  Widget build(BuildContext context) {
    // 这里刻意不看系统「减弱动态效果」:这一下是用户连点三次主动要的,
    // 掐掉等于彩蛋没反应。要改成尊重系统设置,在这里判断 disableAnimations 即可。
    return GestureDetector(
      // 素材是抠过背景的,透明区域也得能点中,所以必须是 opaque。
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: SizedBox(
        width: widget.width,
        child: AspectRatio(
          aspectRatio: _kEggAspect,
          child: Image.asset(
            _playing ? widget.animated : widget.still,
            fit: BoxFit.contain,
            // 见类文档第 3、4 条:单层 + 留住上一张。别加 key,别改成 Stack。
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}
