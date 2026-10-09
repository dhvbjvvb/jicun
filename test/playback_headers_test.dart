import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/playback.dart';

/// 预览播放器与兜底抓取带的请求头,都要和下载器对齐。
///
/// 判据是实测的(2026-10-05,拿服务端真下发的那条 B 站 DASH 音轨 `…-30280.m4s`,
/// 逐个头组合试出来的状态码):**B 站的镜像域名上 Referer 和桌面 UA 缺一不可** ——
/// 把 UA 头整个去掉 403、UA 是移动版 Chrome 那份 403、是播放器自己那份
/// (ExoPlayerLib)也 403,只有桌面那份过(206)。这条音轨就是用户看到的
/// 「音频加载失败:(0) SOURCE ERROR」的来源。
void main() {
  test('B 站音频 CDN:Referer 与桌面 UA 两个都要,自家域名与 Akamai 镜像一视同仁', () {
    for (final url in const <String>[
      // 自家镜像
      'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/94/95/x-1-30280.m4s?e=1',
      'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/94/95/x-1-30280.m4s?e=1',
      'https://www.bilibili.com/a.m4s',
    ]) {
      final headers = playbackHeaders(url);
      expect(headers['Referer'], 'https://www.bilibili.com/', reason: url);
      // **必须发 UA**:以前这里刻意不塞、指望播放器自己那份能过,实测过不去。
      expect(headers['User-Agent'], kBilibiliUserAgent, reason: url);
    }
  });

  test('Akamai 上不带 upos- 前缀的主机是别人家的,一个头都不塞', () {
    expect(playbackHeaders('https://cdn.akamaized.net/a.mp4'), isEmpty);
    expect(playbackHeaders('https://x.example.akamaized.net/a.mp4'), isEmpty);
  });

  test('抖音系 CDN 的预览带浏览器 UA', () {
    final headers = playbackHeaders(
      'https://sf6-cdn-tos.douyinstatic.com/obj/ies-music/123.mp3',
    );
    expect(headers['User-Agent'], kBrowserUserAgent);
    expect(headers.containsKey('Referer'), isFalse);

    // 视频 CDN 也算抖音系
    expect(
      playbackHeaders(
        'https://v3-dy-a-x.ixigua.com/x/video/tos/cn/a.mp4',
      )['User-Agent'],
      kBrowserUserAgent,
    );
    expect(
      playbackHeaders('https://v6-hscy.ixigua.com/x.mp4')['User-Agent'],
      kBrowserUserAgent,
    );
  });

  test('认不出的主机不发任何头', () {
    expect(playbackHeaders('https://example.com/a.mp3'), isEmpty);
    expect(playbackHeaders(''), isEmpty);
  });

  test('兜底抓取:B 站那两家同样补 Referer + 桌面 UA', () {
    for (final url in const <String>[
      'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/94/95/x-1-30280.m4s?e=1',
      'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/94/95/x-1-30280.m4s?e=1',
    ]) {
      final headers = fetchHeaders(url);
      expect(headers['Referer'], 'https://www.bilibili.com/', reason: url);
      expect(headers['User-Agent'], kBilibiliUserAgent, reason: url);
    }
  });

  test('兜底抓取:认不出的主机也发一份浏览器 UA(和一直以来的行为一致)', () {
    final douyin = fetchHeaders('https://sf6-cdn-tos.douyinstatic.com/x.mp3');
    expect(douyin['User-Agent'], kBrowserUserAgent);
    expect(douyin.containsKey('Referer'), isFalse);

    expect(
      fetchHeaders('https://example.com/a.mp3')['User-Agent'],
      kBrowserUserAgent,
    );
    expect(fetchHeaders('')['User-Agent'], kBrowserUserAgent);
  });
}
