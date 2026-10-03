import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/playback.dart';

/// 预览播放器带的请求头要和下载器对齐:抖音系 CDN 发浏览器 UA,B 站发 Referer 且不塞 UA。
void main() {
  test('抖音系 CDN 的预览带浏览器 UA', () {
    final headers = playbackHeaders(
      'https://sf6-cdn-tos.douyinstatic.com/obj/ies-music/123.mp3',
    );
    expect(headers['User-Agent'], kBrowserUserAgent);
    expect(headers.containsKey('Referer'), isFalse);

    // 视频 CDN 也算抖音系
    expect(
      playbackHeaders('https://v3-dy-a-x.ixigua.com/x/video/tos/cn/a.mp4')['User-Agent'],
      kBrowserUserAgent,
    );
    expect(
      playbackHeaders('https://v6-hscy.ixigua.com/x.mp4')['User-Agent'],
      kBrowserUserAgent,
    );
  });

  test('B 站只发 Referer,不发 UA', () {
    final headers = playbackHeaders('https://upos-sz.bilivideo.com/a.m4s');
    expect(headers['Referer'], 'https://www.bilibili.com/');
    expect(headers.containsKey('User-Agent'), isFalse);
  });

  test('认不出的主机不发任何头', () {
    expect(playbackHeaders('https://example.com/a.mp3'), isEmpty);
    expect(playbackHeaders(''), isEmpty);
  });
}
