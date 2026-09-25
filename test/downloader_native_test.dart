import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/downloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final error in <String>['cancelled', 'IOException: 测试失败']) {
    test('原生返回 $error 时删除本次下载的临时文件', () async {
      const channel = MethodChannel('jicun/downloader');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final temp = await Directory.systemTemp.createTemp(
        'jicun_native_cleanup',
      );
      addTearDown(() => temp.deleteSync(recursive: true));

      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'downloadMany') {
          final args = (call.arguments as Map).cast<Object?, Object?>();
          final item = ((args['items'] as List).first as Map)
              .cast<Object?, Object?>();
          File(item['path'] as String).writeAsBytesSync(const <int>[1, 2, 3]);
          Timer.run(() {
            messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                MethodCall('dnDone', <String, Object?>{
                  'id': 1,
                  'result': <String, Object?>{
                    'error': error,
                    'files': const <Object?>[],
                  },
                }),
              ),
              null,
            );
          });
          return 1;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final future = Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/video',
            fileName: 'cleanup.mp4',
            kind: MediaKind.video,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
      );

      await expectLater(
        future,
        error == 'cancelled'
            ? throwsA(isA<DownloadCancelled>())
            : throwsA(isA<HttpException>()),
      );
      expect(temp.listSync(), isEmpty);
    });
  }

  test('原生乱序返回 files 时,每条仍拿到自己的后缀和类型', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_order');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String, String>{};
    final realPublish = Downloader.publishImpl;
    Downloader.publishImpl = (item, file) async {
      published[item.url] = item.fileName;
      file.deleteSync();
      return null;
    };
    addTearDown(() => Downloader.publishImpl = realPublish);

    // 真的文件头:图片认成 .jpg,视频认成 .mp4。
    final jpeg = <int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ];
    final mp4 = <int>[
      0,
      0,
      0,
      0x18,
      0x66,
      0x74,
      0x79,
      0x70,
      0x69,
      0x73,
      0x6F,
      0x6D,
      0,
      0,
      0,
      1,
    ];

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final items = [
        for (final raw in args['items'] as List)
          (raw as Map).cast<Object?, Object?>(),
      ];
      final paths = [for (final item in items) item['path'] as String];
      // 图片地址在前、视频在后,但先下完的是视频 —— 原生就按完成顺序回。
      File(paths[1]).writeAsBytesSync(mp4);
      File(paths[0]).writeAsBytesSync(jpeg);
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': null,
                'files': <Object?>[
                  <String, Object?>{
                    'path': paths[1],
                    'ext': 'video/mp4',
                    'size': mp4.length,
                  },
                  <String, Object?>{
                    'path': paths[0],
                    'ext': 'image/jpeg',
                    'size': jpeg.length,
                  },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await Downloader.nativeDownload(
      [
        DownloadItem(
          url: 'https://example.invalid/photo',
          fileName: '混合卡_1.jpg',
          kind: MediaKind.image,
        ),
        DownloadItem(
          url: 'https://example.invalid/clip',
          fileName: '混合卡_2.mp4',
          kind: MediaKind.video,
        ),
      ],
      temp: temp,
      onProgress: (_) {},
    );

    expect(published['https://example.invalid/photo'], '混合卡_1.jpg');
    expect(published['https://example.invalid/clip'], '混合卡_2.mp4');
  });

  test('相册发布完成前最多 99%,发布完成后才报 100%', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_progress');
    addTearDown(() => temp.deleteSync(recursive: true));
    final fractions = <double>[];
    final realPublish = Downloader.publishImpl;
    Downloader.publishImpl = (item, file) async {
      expect(fractions.last, 0.99);
      file.deleteSync();
      return null;
    };
    addTearDown(() => Downloader.publishImpl = realPublish);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'downloadMany') {
        final args = (call.arguments as Map).cast<Object?, Object?>();
        final item = ((args['items'] as List).first as Map)
            .cast<Object?, Object?>();
        final path = item['path'] as String;
        File(path).writeAsBytesSync(List<int>.filled(100, 0));
        Timer.run(() async {
          await messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              const MethodCall('dnProgress', <String, Object?>{
                'id': 1,
                'received': 100,
                'total': 100,
              }),
            ),
            null,
          );
          await messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              MethodCall('dnDone', <String, Object?>{
                'id': 1,
                'result': <String, Object?>{
                  'error': null,
                  'files': <Object?>[
                    <String, Object?>{
                      'path': path,
                      'ext': 'video/mp4',
                      'size': 100,
                    },
                  ],
                },
              }),
            ),
            null,
          );
        });
        return 1;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await Downloader.nativeDownload(
      [
        DownloadItem(
          url: 'https://example.invalid/video',
          fileName: 'progress.mp4',
          kind: MediaKind.video,
        ),
      ],
      temp: temp,
      onProgress: (progress) => fractions.add(progress.fraction),
    );

    expect(fractions, <double>[0.99, 1.0]);
  });

  test('原生下完了但用户已经取消:不发布,分片删掉', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_late');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final realPublish = Downloader.publishImpl;
    Downloader.publishImpl = (item, file) async {
      published.add(item.fileName);
      return 'uri://${item.fileName}';
    };
    addTearDown(() => Downloader.publishImpl = realPublish);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final item = ((args['items'] as List).first as Map)
          .cast<Object?, Object?>();
      final path = item['path'] as String;
      File(path).writeAsBytesSync(List<int>.filled(64, 7));
      // 原生是"先报结果、文件这时还在":取消标志已经立起来,文件却没被它删掉
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': null,
                'files': <Object?>[
                  <String, Object?>{
                    'path': path,
                    'ext': 'video/mp4',
                    'size': 64,
                  },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/video',
            fileName: 'late.mp4',
            kind: MediaKind.video,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
        // 用户按了取消:哪怕原生已经把整条收完,也不许进相册
        cancelled: () => true,
      ),
      throwsA(isA<DownloadCancelled>()),
    );

    expect(published, isEmpty);
    expect(temp.listSync(), isEmpty);
  });

  test('图集下载阶段取消:相册里一个都不出现', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_cancel');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final unpublished = <String>[];
    final realPublish = Downloader.publishImpl;
    final realUnpublish = Downloader.unpublishImpl;
    Downloader.publishImpl = (item, file) async {
      published.add(item.fileName);
      // 登记 = 拷进媒体库,临时文件跟着删掉
      file.deleteSync();
      return 'uri://${item.fileName}';
    };
    Downloader.unpublishImpl = (uri) async => unpublished.add(uri);
    addTearDown(() {
      Downloader.publishImpl = realPublish;
      Downloader.unpublishImpl = realUnpublish;
    });

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final items = [
        for (final raw in args['items'] as List)
          (raw as Map).cast<Object?, Object?>(),
      ];
      final paths = [for (final item in items) item['path'] as String];
      // 取消:第 1 张下成了(文件留着,进 files),第 2 张被中断(原生删掉它,
      // 不进 files)。原生只回已经下成的那条。
      File(paths[0]).writeAsBytesSync(List<int>.filled(32, 9));
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': 'cancelled',
                'files': <Object?>[
                  <String, Object?>{
                    'path': paths[0],
                    'ext': 'image/jpeg',
                    'size': 32,
                  },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/a',
            fileName: '图集_1.jpg',
            kind: MediaKind.image,
          ),
          DownloadItem(
            url: 'https://example.invalid/b',
            fileName: '图集_2.jpg',
            kind: MediaKind.image,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
      ),
      throwsA(isA<DownloadCancelled>()),
    );

    expect(published, isEmpty, reason: '取消那一刻相册里还没有东西,这一趟就什么都不留');
    expect(unpublished, isEmpty);
    expect(temp.listSync(), isEmpty, reason: '已经下完但没登记的那张也一起丢掉');
  });

  test('图集在登记途中取消:相册里只留取消前已经写进去的那张', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_mid');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final unpublished = <String>[];
    final realPublish = Downloader.publishImpl;
    final realUnpublish = Downloader.unpublishImpl;
    Downloader.publishImpl = (item, file) async {
      published.add(item.fileName);
      file.deleteSync();
      return 'uri://${item.fileName}';
    };
    Downloader.unpublishImpl = (uri) async => unpublished.add(uri);
    addTearDown(() {
      Downloader.publishImpl = realPublish;
      Downloader.unpublishImpl = realUnpublish;
    });

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final items = [
        for (final raw in args['items'] as List)
          (raw as Map).cast<Object?, Object?>(),
      ];
      final paths = [for (final item in items) item['path'] as String];
      for (final path in paths) {
        File(path).writeAsBytesSync(List<int>.filled(32, 9));
      }
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': null,
                'files': <Object?>[
                  for (final path in paths)
                    <String, Object?>{
                      'path': path,
                      'ext': 'image/jpeg',
                      'size': 32,
                    },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // 原生两条都下成了,登记途中用户按了取消:第 1 张已经写进相册(留着),
    // 第 2 张不许再写,它的临时文件跟着清掉
    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/a',
            fileName: '图集_1.jpg',
            kind: MediaKind.image,
          ),
          DownloadItem(
            url: 'https://example.invalid/b',
            fileName: '图集_2.jpg',
            kind: MediaKind.image,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
        cancelled: () => published.isNotEmpty,
      ),
      throwsA(isA<DownloadCancelled>()),
    );

    expect(published, ['图集_1.jpg']);
    expect(unpublished, isEmpty, reason: '多条时取消不回滚已经进相册的');
    expect(temp.listSync(), isEmpty);
  });

  test('单条取消:相册里不留,分片删掉', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_single');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final realPublish = Downloader.publishImpl;
    Downloader.publishImpl = (item, file) async {
      published.add(item.fileName);
      file.deleteSync();
      return 'uri://${item.fileName}';
    };
    addTearDown(() => Downloader.publishImpl = realPublish);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final item = ((args['items'] as List).first as Map)
          .cast<Object?, Object?>();
      final path = item['path'] as String;
      // 原生把它收完了(取消前就下完,所以文件留着),但用户已经按了取消:
      // 一条的情况下这条不许进相册
      File(path).writeAsBytesSync(List<int>.filled(64, 7));
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': 'cancelled',
                'files': <Object?>[
                  <String, Object?>{
                    'path': path,
                    'ext': 'video/mp4',
                    'size': 64,
                  },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/video',
            fileName: '单条.mp4',
            kind: MediaKind.video,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
      ),
      throwsA(isA<DownloadCancelled>()),
    );

    expect(published, isEmpty);
    expect(temp.listSync(), isEmpty);
  });

  test('某一条失败时,前面已经存好的不撤,失败那条不留', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_fail');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final unpublished = <String>[];
    final realPublish = Downloader.publishImpl;
    final realUnpublish = Downloader.unpublishImpl;
    Downloader.publishImpl = (item, file) async {
      // 第 2 条被媒体库拒收:这是"失败",不是"取消"
      if (item.fileName.startsWith('图集_2')) {
        throw Exception('媒体库不接受这个文件');
      }
      published.add(item.fileName);
      file.deleteSync();
      return 'uri://${item.fileName}';
    };
    Downloader.unpublishImpl = (uri) async => unpublished.add(uri);
    addTearDown(() {
      Downloader.publishImpl = realPublish;
      Downloader.unpublishImpl = realUnpublish;
    });

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final items = [
        for (final raw in args['items'] as List)
          (raw as Map).cast<Object?, Object?>(),
      ];
      final paths = [for (final item in items) item['path'] as String];
      for (final path in paths) {
        File(path).writeAsBytesSync(List<int>.filled(32, 9));
      }
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': null,
                'files': <Object?>[
                  for (final path in paths)
                    <String, Object?>{
                      'path': path,
                      'ext': 'image/jpeg',
                      'size': 32,
                    },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/a',
            fileName: '图集_1.jpg',
            kind: MediaKind.image,
          ),
          DownloadItem(
            url: 'https://example.invalid/b',
            fileName: '图集_2.jpg',
            kind: MediaKind.image,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
      ),
      throwsA(isA<Exception>()),
    );

    // 第 1 条留在相册里(不回滚),第 2 条什么都没有
    expect(published, ['图集_1.jpg']);
    expect(unpublished, isEmpty);
    expect(temp.listSync(), isEmpty);
  });

  test('原生中途失败:下成的那几条照进相册,失败的只清它自己', () async {
    const channel = MethodChannel('jicun/downloader');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final temp = await Directory.systemTemp.createTemp('jicun_native_partial');
    addTearDown(() => temp.deleteSync(recursive: true));
    final published = <String>[];
    final realPublish = Downloader.publishImpl;
    Downloader.publishImpl = (item, file) async {
      published.add(item.fileName);
      file.deleteSync();
      return 'uri://${item.fileName}';
    };
    addTearDown(() => Downloader.publishImpl = realPublish);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'downloadMany') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final items = [
        for (final raw in args['items'] as List)
          (raw as Map).cast<Object?, Object?>(),
      ];
      final paths = [for (final item in items) item['path'] as String];
      // 第 1 张下成了;第 2 张的地址报了 HTTP 500 —— 原生把它自己那份删掉,
      // files 里只回第 1 张,error 带上失败原因。
      File(paths[0]).writeAsBytesSync(List<int>.filled(32, 9));
      Timer.run(() {
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('dnDone', <String, Object?>{
              'id': 1,
              'result': <String, Object?>{
                'error': 'IOException: HTTP 500',
                'files': <Object?>[
                  <String, Object?>{
                    'path': paths[0],
                    'ext': 'image/jpeg',
                    'size': 32,
                  },
                ],
              },
            }),
          ),
          null,
        );
      });
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      Downloader.nativeDownload(
        [
          DownloadItem(
            url: 'https://example.invalid/a',
            fileName: '图集_1.jpg',
            kind: MediaKind.image,
          ),
          DownloadItem(
            url: 'https://example.invalid/b',
            fileName: '图集_2.jpg',
            kind: MediaKind.image,
          ),
        ],
        temp: temp,
        onProgress: (_) {},
      ),
      throwsA(isA<HttpException>()),
    );

    // 下成的那张留在相册里,整批没有白下
    expect(published, ['图集_1.jpg']);
    // 缓存/分片一个不剩
    expect(temp.listSync(), isEmpty);
  });

  test('启动清理:只删遗留分片,已下好的安装包留着', () async {
    final temp = await Directory.systemTemp.createTemp('jicun_native_sweep');
    addTearDown(() => temp.deleteSync(recursive: true));
    File('${temp.path}/jicun_123_0.part').writeAsBytesSync(
      List<int>.filled(16, 1),
    );
    File('${temp.path}/jicun_123_1.part').writeAsBytesSync(
      List<int>.filled(16, 1),
    );
    // 更新包下到一半的残件也算分片
    File('${temp.path}/jicun-1.0.2.apk.part').writeAsBytesSync(
      List<int>.filled(16, 1),
    );
    // 完整下好的更新包是 ApkCache 要复用的,不能清
    final apk = File('${temp.path}/jicun-1.0.2.apk')
      ..writeAsBytesSync(List<int>.filled(16, 1));
    // 封面缓存是子目录,归 CoverCache 自己管
    final covers = Directory('${temp.path}/covers')..createSync();

    expect(await Downloader.sweepLeftovers(temp: temp), 3);
    expect(
      temp.listSync().map((entry) => entry.path.split(RegExp(r'[/\\]')).last),
      unorderedEquals(<String>['jicun-1.0.2.apk', 'covers']),
    );
    expect(apk.existsSync(), isTrue);
    expect(covers.existsSync(), isTrue);
  });
}
