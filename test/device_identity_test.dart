import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/api_host.dart';
import 'package:jicun/device_identity.dart';
import 'package:jicun/ui/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备身份(见 lib/device_identity.dart)。
///
/// 这里盯的是**协议**那半边:待签串逐字长什么样、摘要怎么算、什么时候**不**加头。
/// 原生那边(真生成密钥、真签名)在设备上,单测里只能用假通道 —— 假的正好可以把
/// 「Dart 到底把哪段串交给原生签」抓下来核对。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kDeviceChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 一个形状对的 device_id(真值由硬件公钥推出来,见 DeviceIdentity.kt)。
  const deviceId = 'cmqGRgCA3vR2TBI8-GYEbm';

  /// 22 字符的 nonce,和协议里那个长度一致。
  const nonce = 'AAECAwQFBgcICQoLDA0ODw';

  /// 一条带百分号编码的原始查询串 —— 签名里是它的 sha256,必须**原样**参与摘要。
  const rawQuery = 'url=https%3A%2F%2Fv.douyin.com%2Fabc%2F';

  /// `sha256Hex(rawQuery)`(独立算出来的一组固定值,不是拿被测代码算的)。
  const rawQueryHash =
      '029e75eed0dacadeef3fea95bd128180701710fe94db6a68cc424e726a2a4ee7';

  setUp(() {
    // 每个用例从「没注册过」开始。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetDeviceIdentityCache();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    deviceClientFactory = defaultDeviceClient;
    resetDeviceIdentityCache();
  });

  group('待签串(canonical string)', () {
    test('六行、\\n 连接、结尾没有换行,顺序一字不差', () {
      final payload = canonicalPayload(
        method: 'GET',
        path: '/parse',
        rawQuery: rawQuery,
        timestamp: '1700000000',
        nonce: nonce,
        deviceId: deviceId,
      );

      expect(
        payload,
        'GET\n'
        '/parse\n'
        '$rawQueryHash\n'
        '1700000000\n'
        '$nonce\n'
        '$deviceId',
      );
      // 拆分出来逐段核一遍:顺序错了上面那条也会红,但这条能一眼看出错在哪一段
      expect(payload.split('\n'), <String>[
        'GET',
        '/parse',
        rawQueryHash,
        '1700000000',
        nonce,
        deviceId,
      ]);
      expect('\n'.allMatches(payload).length, 5, reason: '六行之间只有五个换行');
      expect(payload.endsWith('\n'), isFalse, reason: '结尾多一个换行服务端就算不过');
    });

    test('没有查询串时对空字符串求摘要(不是跳过、也不是 null)', () {
      expect(
        sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      final payload = canonicalPayload(
        method: 'GET',
        path: '/parse',
        rawQuery: '',
        timestamp: '1',
        nonce: nonce,
        deviceId: deviceId,
      );
      expect(payload.split('\n').length, 6);
      expect(
        payload.split('\n')[2],
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      // 空查询串那一行**不能是空的**:它是摘要,不是原文
      expect(payload.split('\n')[2], isNotEmpty);
    });

    test('方法一律大写;路径不含域名和查询串', () {
      final payload = canonicalPayload(
        method: 'get',
        path: '/parse',
        rawQuery: rawQuery,
        timestamp: '1',
        nonce: nonce,
        deviceId: deviceId,
      );
      expect(payload.split('\n').first, 'GET');
      expect(payload.split('\n')[1], '/parse');
    });

    test('sha256 摘要用已知向量锁住(小写十六进制)', () {
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(sha256Hex('中文'), matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('nonce', () {
    test('22 字符 base64url、每次都不一样、没有填充', () {
      final first = deviceNonce();
      final second = deviceNonce();
      expect(first.length, 22);
      expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(first.contains('='), isFalse);
      expect(first, isNot(second), reason: '服务端靠它挡重放,不能是固定值');
    });
  });

  /// 让设备处于「已注册」状态。
  ///
  /// 落盘 device_id、原生确认密钥还在,然后走**真正的** [ensureDeviceIdentity] —— 这一步
  /// 不是多余的:[deviceHeaders] 只认内存里那份 id(见 lib/device_identity.dart),而内存
  /// 那份只有 ensureDeviceIdentity 会填。用例顺便把这件事也钉住。
  Future<void> useRegisteredDevice({
    Future<Object?> Function(MethodCall call)? onSign,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefsDeviceId: deviceId,
      // 版本也写当前这个。不写的话会顺带触发「升级补登记」,这几条关于签名头的用例就
      // 会多跑一条跟它们无关的路 —— 而且那一步用的是**真实** client(defaultDeviceClient),
      // 等于让单元用例去打线上接口。
      kPrefsDeviceVersion: '3.2.8+18',
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sign') {
        return onSign == null ? 'MEUCIQfakeSignature==' : await onSign(call);
      }
      if (call.method == 'deviceId') return deviceId;
      return null;
    });
    await ensureDeviceIdentity();
  }

  group('deviceHeaders', () {
    test('未注册时返回空 Map,而且不该去问原生要签名', () async {
      var signCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'sign') signCalls++;
        return null;
      });

      expect(await deviceHeaders('GET', '/parse', rawQuery), isEmpty);
      expect(signCalls, 0);
    });

    test('注册过之前不吃偏好存储:拿不到头就照常发,不能卡在那一读上', () async {
      // 这条盯的不是功能而是**死活**:签名头是每个请求都要过的一条路,它一旦反过来
      // 依赖 SharedPreferences,在没人应答那个通道的环境里就会永远等下去(实测解析页
      // 的 widget 用例整片超时)。落盘里有 id 也不算数 —— 那份 id 要由
      // ensureDeviceIdentity 放进内存才作数。
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
      });

      expect(await deviceHeaders('GET', '/parse', rawQuery), isEmpty);
    });

    test('注册后四个头齐全,交给原生签的就是那六行', () async {
      String? signed;
      await useRegisteredDevice(
        onSign: (call) async {
          final args = call.arguments as Map<Object?, Object?>;
          signed = utf8.decode(base64.decode(args['payload']! as String));
          return 'MEUCIQfakeSignature==';
        },
      );

      final headers = await deviceHeaders('GET', '/parse', rawQuery);

      expect(headers.keys.toSet(), <String>{
        kDeviceHeaderName,
        kDeviceHeaderTs,
        kDeviceHeaderNonce,
        kDeviceHeaderSig,
      });
      expect(headers[kDeviceHeaderName], deviceId);
      expect(headers[kDeviceHeaderSig], 'MEUCIQfakeSignature==');
      expect(int.tryParse(headers[kDeviceHeaderTs]!), isNotNull);
      expect(headers[kDeviceHeaderNonce]!.length, 22);

      // 关键的一条:交给原生签的那段串,拿头里的 ts/nonce 自己拼一遍必须**完全相同**。
      // 服务端就是照这个思路重算的 —— 差一个字符签名就算不过。
      expect(
        signed,
        canonicalPayload(
          method: 'GET',
          path: '/parse',
          rawQuery: rawQuery,
          timestamp: headers[kDeviceHeaderTs]!,
          nonce: headers[kDeviceHeaderNonce]!,
          deviceId: deviceId,
        ),
      );
      expect(signed!.split('\n').last, deviceId);
    });

    test('原生签名失败时返回空 Map,不抛给调用方', () async {
      await useRegisteredDevice(
        onSign: (call) async =>
            throw PlatformException(code: 'device_error', message: '设备密钥不存在'),
      );

      // 服务端现在是 log 模式:拿不到头就**不加头**,请求照发。这条路绝不能抛。
      expect(await deviceHeaders('GET', '/parse', rawQuery), isEmpty);
    });

    test('原生回了空签名时同样不加头', () async {
      await useRegisteredDevice(onSign: (_) async => '');

      expect(await deviceHeaders('GET', '/parse', rawQuery), isEmpty);
    });
  });

  group('ensureDeviceIdentity', () {
    /// 假原生:挑战值那一步之后能给出密钥和证书链,`deviceId` 按脚本回答。
    void stubNative({String? nativeId}) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'deviceId':
            return nativeId;
          case 'androidApi':
            return 34;
          case 'createKey':
            // 证书链**叶到根**:原生 getCertificateChain() 给的就是这个顺序,不许反转。
            return <String, Object?>{
              'deviceId': deviceId,
              'attested': true,
              'certificateChain': <String>['LEAFCERT', 'ROOTCERT'],
              // 原生从 Build.MANUFACTURER / Build.MODEL 取,取不到给空串
              'manufacturer': 'Xiaomi',
              'model': '23127PN0CC',
            };
          default:
            return null;
        }
      });
    }

    test('首次注册:挑战值 → 生成密钥 → 交证书链 → 落盘 device_id', () async {
      final requests = <http.Request>[];
      deviceClientFactory = () => MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/device/challenge') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'retcode': 200,
              'succ': true,
              'data': <String, Object?>{'nonce': nonce, 'expires_in': 300},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'retcode': 200,
            'succ': true,
            'data': <String, Object?>{'device_id': deviceId, 'attested': 1},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      stubNative();

      await ensureDeviceIdentity();

      expect(requests, hasLength(2));
      // 两个端点都按 apiUrl 拼,域名跟着当前生效的那个走(服务端能换域名)
      expect(requests.first.method, 'GET');
      expect(requests.first.url.host, apiHost);
      expect(requests.first.url.path, '/device/challenge');
      expect(requests.last.method, 'POST');
      expect(requests.last.url.path, '/device/attest');
      expect(requests.last.headers['content-type'], contains('application/json'));
      expect(jsonDecode(requests.last.body), <String, Object?>{
        // 叶到根,不许反转
        'cert_chain': <String>['LEAFCERT', 'ROOTCERT'],
        // 用例环境拿不到 package_info,走的是兜底常量(= pubspec 的 version)
        'app_version': '3.2.8+18',
        'android_api': 34,
        // 机型:证明书里那份 attestationId* 很多机器不给,后台认设备只能靠原生上报的这两项
        'manufacturer': 'Xiaomi',
        'model': '23127PN0CC',
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsDeviceId), deviceId);
      expect(prefs.getInt(kPrefsDeviceAttestedAt), isNotNull);
      expect(prefs.getString(kPrefsDeviceVersion), '3.2.8+18');
      expect(prefs.getInt(kPrefsDeviceLastAttempt), isNotNull);
    });

    test('已经注册过就直接返回:一次请求都不发', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        // 版本也是当前这个 —— 否则会走「升级补登记」那条路,那就不叫幂等了
        kPrefsDeviceVersion: '3.2.8+18',
      });
      stubNative(nativeId: deviceId);
      var built = 0;
      deviceClientFactory = () {
        built++;
        return MockClient((_) async => http.Response('{}', 200));
      };

      await ensureDeviceIdentity();

      expect(built, 0, reason: '幂等:幂等的那条路上不该有任何网络请求');
      // 走的是**内存/落盘**那条,后面拼头不用再问一遍
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'sign') return 'SIG';
        return null;
      });
      expect(await deviceHeaders('GET', '/parse', ''), isNotEmpty);
    });

    test('App 升级后补登记一次:密钥没变,id 也不变', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        // 落盘的是上一版上报的版本
        kPrefsDeviceVersion: '3.2.7+17',
      });
      stubNative(nativeId: deviceId);
      final paths = <String>[];
      deviceClientFactory = () => MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode(<String, Object?>{
            'succ': true,
            'data': request.url.path == '/device/challenge'
                ? <String, Object?>{'nonce': nonce}
                : <String, Object?>{'device_id': deviceId},
          }),
          200,
        );
      });

      await ensureDeviceIdentity();

      // 机型/版本只在登记那一刻上报,不补这一次后台就永远看不到
      expect(paths, <String>['/device/challenge', '/device/attest']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsDeviceId), deviceId,
          reason: '密钥没变 → id 也不变,不会在后台多出一台设备');
      expect(prefs.getString(kPrefsDeviceVersion), '3.2.8+18',
          reason: '版本刷新成当前这个,下次启动就不再补了');
      // 补过之后仍然能签:身份是完整的
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'sign') return 'SIG';
        return null;
      });
      expect(await deviceHeaders('GET', '/parse', ''), isNotEmpty);
    });

    test('版本没变就不补登记:一次请求都不发', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        kPrefsDeviceVersion: '3.2.8+18',
      });
      stubNative(nativeId: deviceId);
      var built = 0;
      deviceClientFactory = () {
        built++;
        return MockClient((_) async => http.Response('{}', 200));
      };

      await ensureDeviceIdentity();

      expect(built, 0, reason: '版本没变就不该有任何网络请求');
    });

    test('补登记失败:老的 id 照旧留着,不会把设备弄成没身份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        kPrefsDeviceVersion: '3.2.7+17',
      });
      stubNative(nativeId: deviceId);
      // 注册这条路整个挂掉(挑战值就失败)
      deviceClientFactory = () => MockClient((_) async => http.Response('{}', 503));

      await ensureDeviceIdentity();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsDeviceId), deviceId,
          reason: '密钥还在,id 就还能签 —— enforce 模式下清掉它等于让这台设备全量 403');
    });

    test('补登记和首次注册共用退避:刚试过就不再打接口', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        kPrefsDeviceVersion: '3.2.7+17',
        kPrefsDeviceLastAttempt: DateTime.now().millisecondsSinceEpoch,
      });
      stubNative(nativeId: deviceId);
      var built = 0;
      deviceClientFactory = () {
        built++;
        return MockClient((_) async => http.Response('{}', 200));
      };

      await ensureDeviceIdentity();

      expect(built, 0, reason: '退避是共用的:升级不能变成绕过退避、每次启动都打接口的口子');
    });

    test('落盘的 id 还在但密钥没了:清掉重新注册', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
      });
      // 原生说没有密钥(deviceId 为 null):那条落盘的记录已经签不出东西了
      stubNative(nativeId: null);
      final paths = <String>[];
      deviceClientFactory = () => MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode(<String, Object?>{
            'succ': true,
            'data': request.url.path == '/device/challenge'
                ? <String, Object?>{'nonce': nonce}
                : <String, Object?>{'device_id': deviceId},
          }),
          200,
        );
      });

      await ensureDeviceIdentity();

      expect(paths, <String>['/device/challenge', '/device/attest']);
    });

    test('失败后短期内不再重试(时间戳落盘;没身份时是 10 秒那一档)', () async {
      stubNative();
      var built = 0;
      deviceClientFactory = () {
        built++;
        // 服务端还没上线:挑战值这一趟就失败
        return MockClient((_) async => http.Response('not json', 502));
      };

      await ensureDeviceIdentity();
      expect(built, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsDeviceId), isNull, reason: '没注册成功就不该有 id');
      expect(prefs.getInt(kPrefsDeviceLastAttempt), isNotNull);

      // 第二次(比如用户重启 APP):退避期内一次请求都不发
      resetDeviceIdentityCache();
      await ensureDeviceIdentity();
      expect(built, 1);
    });

    test('没登记成功过:10 秒后就能再试(不再等 6 小时)', () async {
      // 退避分两档。没身份的设备现在等于废的(每个请求都被服务端拒),按 6 小时退避
      // 就是让他白等 —— 装完/重装后第一次启动恰恰最容易失败。
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceLastAttempt: DateTime.now().millisecondsSinceEpoch - 11000,
      });
      stubNative();
      final paths = <String>[];
      deviceClientFactory = () => MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode(<String, Object?>{
            'succ': true,
            'data': request.url.path == '/device/challenge'
                ? <String, Object?>{'nonce': nonce}
                : <String, Object?>{'device_id': deviceId},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      await ensureDeviceIdentity();

      expect(paths, <String>['/device/challenge', '/device/attest'],
          reason: '11 秒前试过就该再试了(短的那一档是 10 秒)');
    });

    test('只是版本变了要补登记:退避仍然是 6 小时那一档', () async {
      // 反面:这台设备的身份是好的,重登只是为了刷新机型/版本号 —— 失败了大可 6 小时后再来。
      // 两档不能混:共用一个短退避的话,「升级」就成了绕过退避、每次启动都打接口的口子。
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPrefsDeviceId: deviceId,
        kPrefsDeviceVersion: '3.2.7+17',                                        // 版本对不上 → 想补登记
        kPrefsDeviceLastAttempt: DateTime.now().millisecondsSinceEpoch - 11000, // 11 秒前试过
      });
      stubNative(nativeId: deviceId);
      var built = 0;
      deviceClientFactory = () {
        built++;
        return MockClient((_) async => http.Response('{}', 200));
      };

      await ensureDeviceIdentity();

      expect(built, 0, reason: '身份没问题,11 秒不够 —— 这一档是 6 小时');
    });

    test('attest 失败不抛异常,也不落盘 device_id', () async {
      stubNative();
      deviceClientFactory = () => MockClient((request) async {
        if (request.url.path == '/device/challenge') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{'nonce': nonce},
            }),
            200,
          );
        }
        // 服务端拒了(比如证书链验不过):retdesc 只进日志
        return http.Response(
          jsonEncode(<String, Object?>{
            'succ': false,
            'retdesc': '证书链校验失败',
          }),
          400,
        );
      });

      await ensureDeviceIdentity();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsDeviceId), isNull);
      // 没有 id → 不加头,解析照常
      expect(await deviceHeaders('GET', '/parse', ''), isEmpty);
    });

    test('awaitDeviceIdentity:等的是「已经在跑」那次登记,回来时身份就绪', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      resetDeviceIdentityCache();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'sign':
            return 'SIG';
          case 'deviceId':
            return deviceId;
          case 'androidApi':
            return 34;
          case 'createKey':
            return <String, Object?>{
              'deviceId': deviceId,
              'attested': true,
              'certificateChain': <String>['LEAFCERT'],
            };
          default:
            return null;
        }
      });
      final paths = <String>[];
      deviceClientFactory = () => MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode(<String, Object?>{
            'succ': true,
            'data': request.url.path == '/device/challenge'
                ? <String, Object?>{'nonce': nonce}
                : <String, Object?>{'device_id': deviceId},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final registration = ensureDeviceIdentity(); // 启动那把火:不 await
      await awaitDeviceIdentity();

      expect(paths, <String>['/device/challenge', '/device/attest'],
          reason: '应该等它办完,而不是空手回来');
      expect(await deviceHeaders('GET', '/parse', ''), isNotEmpty);
      await registration;
    });

    test('awaitDeviceIdentity:没跑过启动流程时(用例环境)绝不补登记', () async {
      // 这条是**守卫**用例,不是功能用例:补登记那条路要读偏好存储,而 widget 用例会直接
      // pump 一个页面、不跑启动流程。没有 [_startedThisProcess] 这道守卫,那些用例就会从
      // 解析路径去打真实网络(踩过,整片 widget 用例超时)。resetDeviceIdentityCache() 连
      // 「启动跑过没有」一起清掉,所以这里模拟的正是那种环境。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      resetDeviceIdentityCache();
      var built = 0;
      deviceClientFactory = () {
        built++;
        return MockClient((_) async => http.Response('{}', 200));
      };

      await awaitDeviceIdentity();

      expect(built, 0, reason: '登记的唯一入口是启动那次;解析这条路不该顺手起一个');
      expect(await deviceHeaders('GET', '/parse', ''), isEmpty);
    });


    test('awaitDeviceIdentity:设备没身份时会补起一次登记(不能只等下一次启动)', () async {
      // 线上现场:重装(或密钥作废)之后登记失败过一次 —— 这台设备于是没有身份,服务端在
      // enforce 下把它每个请求都拒掉。旧行为是「等下一次启动」,而启动又被 6 小时退避挡着,
      // 用户只能反复撞同一面墙。现在:退避短(10 秒)+ 请求路径补一次。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      resetDeviceIdentityCache();
      var attempts = 0;
      deviceClientFactory = () {
        attempts++;
        // 挑战值这一趟就一直失败,模拟「登记办不成」
        return MockClient((_) async => http.Response('not json', 502));
      };

      await ensureDeviceIdentity();
      expect(attempts, 1, reason: '启动那次先记一笔(顺便把 _startedThisProcess 立起来)');

      // 等价于「等了 10 秒」:没身份时退避就是这么短
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kPrefsDeviceLastAttempt,
          DateTime.now().millisecondsSinceEpoch - 11000);

      await awaitDeviceIdentity();

      expect(attempts, 2, reason: '没身份时要在这里补一次,而不是干等下一次启动');
    });
    test('awaitDeviceIdentity:登记卡住时最多等 timeout,不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      resetDeviceIdentityCache();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'deviceId') return deviceId;
        return null;
      });
      // 登记的应答永远不来(比 timeout 长得多)
      deviceClientFactory = () => MockClient(
          (_) => Future<http.Response>.delayed(const Duration(seconds: 2)));

      final registration = ensureDeviceIdentity();
      final started = DateTime.now();
      await awaitDeviceIdentity(timeout: const Duration(milliseconds: 120));
      final waited = DateTime.now().difference(started);

      expect(waited, lessThan(const Duration(seconds: 3)),
          reason: '卡住也不能把用户吊在这儿等一个不会来的响应');
      expect(await deviceHeaders('GET', '/parse', ''), isEmpty);
      expect(registration, isNotNull);
    });
  });

  group('版本号', () {
    test('兜底版本号必须和 pubspec 的 version 一致', () {
      // device_identity.dart 里的 _fallbackAppVersion 是硬编码的:它只在拿不到 package_info
      // 时用(用例环境,或者插件异常),而它和 pubspec 之间**只能靠这条用例**绑住。
      // 换版本号时忘了同步,真机在插件出问题时就会报一个旧版本给服务端 —— 这种不一致
      // 最难发现,所以钉在这里。
      //
      // ⚠️ 只比 pubspec 里的那一行。**设备上看到的版本号可能更长**:用 --split-per-abi
      // 出包时 Flutter 会按 ABI 给 versionCode 加 1000×ABI(见 android/app/build.gradle.kts
      // 里那段注释),arm64-v8a 的包在设备上就是 `3.2.8+2018`(本地合并后的 manifest 实测:
      // debug=18、armeabi-v7a=1018、arm64-v8a=2018)。那是 Flutter 的预期行为,不是配置错。
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
      expect(match, isNotNull, reason: 'pubspec.yaml 里没找到 version:');
      expect(match!.group(1), '3.2.8+18',
          reason: 'pubspec 的版本改了,就把 device_identity.dart 里的 _fallbackAppVersion '
                  '和这条断言一起改 —— 两边必须一致');
    });
  });
}
