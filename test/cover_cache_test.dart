import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/cover_cache.dart';

void main() {
  group('CoverCache.keyOf', () {
    test('同一张封面换了签名,还是命中同一个键', () {
      // 上游给的封面地址每次都带一份新的签名和过期时间。整串地址做键的话,
      // 同一条视频重新解析就命中不了缓存 —— 那样这个缓存等于没做。
      const a =
          'https://p11-sign.douyinpic.com/obj/tos-cn-i-dy/abc'
          '?x-signature=AAA&x-expires=1790776800';
      const b =
          'https://p11-sign.douyinpic.com/obj/tos-cn-i-dy/abc'
          '?x-signature=BBB&x-expires=1790799999';

      expect(CoverCache.keyOf(a), CoverCache.keyOf(b));
    });

    test('不同的封面是不同的键', () {
      expect(
        CoverCache.keyOf('https://x.example/a.jpg'),
        isNot(CoverCache.keyOf('https://x.example/b.jpg')),
      );
    });

    test('没有 query 的地址照样能用', () {
      const url = 'https://x.example/a.jpg';
      expect(CoverCache.keyOf(url), CoverCache.keyOf(url));
      expect(CoverCache.keyOf(url), isNotEmpty);
    });
  });

  test('目录没准备好时 fileFor 返回 null,不抛异常', () {
    // 测试环境拿不到 path_provider,目录一直是空的 —— 这时候必须安静地
    // 退回网络图,而不是把历史页搞崩。
    expect(CoverCache.fileFor('https://x.example/a.jpg'), isNull);
  });

  test('store 在拿不到目录时安静失败', () async {
    await expectLater(CoverCache.store('https://x.example/a.jpg'), completes);
  });
}
