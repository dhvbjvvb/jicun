import 'package:flutter/material.dart';

/// 预览播放器的**跨页面记忆**、**暂停信号**与**恢复信号**。
///
/// 三件事都源于同一个坑:预览播放器活在页面树里,页面一重建/一销毁,播放器就跟着
/// 没了。所以位置不能只存在播放器里。
///
/// 1. [positions]:按地址记住「上次播到哪」。切到历史/设置再切回来、或者解析出
///    新地址导致播放器重建,都靠它把进度接回去 —— 而不是打回 00:00。
/// 2. [pauseRequests]:点「下载媒体」时发一次信号,让正在播的视频和音频都停下来。
///    只是暂停,播放器留着 —— 下载和预览抢带宽、抢音频焦点,让位是对的,但下载
///    一结束用户要能接着看。
/// 3. [resumeRequests]:下载那一趟结束(下完/取消/失败)时发一次,把上一条信号
///    暂停掉的播放器放回去接着播。只恢复**点下载前本来就在播**的那些:用户自己
///    按停的,不该被这个信号弄响。
class Playback {
  const Playback._();

  /// 地址 → 上次播到的位置。地址带签名,同一条媒体在一次运行里地址是稳定的。
  static final Map<String, Duration> positions = <String, Duration>{};

  /// 递增即请求暂停;两个播放区各自记住消费到哪一次,互不干扰。
  static final ValueNotifier<int> pauseRequests = ValueNotifier<int>(0);

  /// 递增即请求恢复播放。同上,两边各自记住消费到哪一次。
  static final ValueNotifier<int> resumeRequests = ValueNotifier<int>(0);

  static void requestPause() => pauseRequests.value++;

  static void requestResume() => resumeRequests.value++;

  static void remember(String url, Duration position) {
    positions[url] = position;
  }

  static Duration? recall(String url) {
    final position = positions[url];
    if (position == null || position <= Duration.zero) return null;
    return position;
  }
}

