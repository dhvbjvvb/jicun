import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:jicun/downloader.dart';

Future<String?> readClipboardInner() async {
  // 先走自带那条:纯文本它又快又准,而绝大多数时候剪贴板里就是纯文本。
  var text = await engineClipboardText();
  if (!hasText(text)) {
    final native = await nativeClipboardText();
    text = native.text;
    // 平台侧明明有这个方法却读空 → 可能是刚切回前台、系统还没把剪贴板交接过来,
    // 等一下再问一次。问不出来(测试、非 Android)就别白等这一下。
    if (native.available && !hasText(text)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      text = (await nativeClipboardText()).text;
    }
  }
  debugPrint('[clip] text=${text?.length ?? -1}');
  return hasText(text) ? text : null;
}

bool hasText(String? text) => text != null && text.trim().isNotEmpty;

/// 平台侧读剪贴板。
///
/// [available] 为假 = 这个方法根本不存在(测试、非 Android)。
/// 一次最多等 [kClipboardReadTimeout]:真机实测 3~20ms,卡住的平台调用不能把
/// 「粘贴」这颗按钮晾在那儿。
Future<({bool available, String? text})> nativeClipboardText() async {
  try {
    final text = await Downloader.channel
        .invokeMethod<String>('getClipboardText')
        .timeout(kClipboardReadTimeout, onTimeout: () => null);
    return (available: true, text: text);
  } catch (_) {
    return (available: false, text: null);
  }
}

const Duration kClipboardReadTimeout = Duration(milliseconds: 300);

/// Flutter 自带那条:只认 `text/plain`,当作最后的兜底。
Future<String?> engineClipboardText() async {
  try {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    return null;
  }
}

