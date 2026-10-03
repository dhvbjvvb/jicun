package com.videofix.jicun

import android.content.ClipboardManager
import android.content.Context

/**
 * 读剪贴板里的文字,读不到返回 null。
 *
 * **为什么不直接用 Dart 的 `Clipboard.getData`**:Flutter 引擎在 Android 侧
 * 只认 `text/plain` 那一种 MIME。从浏览器复制的链接常常只带 `text/html`,
 * 从相册/文件管理器复制的只带 `text/uri-list` —— 这些内容的剪贴板明明是满的,
 * 引擎却回 null,APP 只好说一句"剪贴板里没有内容"(实测就是这么报的)。
 *
 * 两处细节:
 * - 用系统的 `coerceToText`,html / uri / intent 都能转成文字;
 * - **挨条往下找**:剪贴板里可能有好几项,第一项是图片之类的空文本时,
 *   后面那项才是能用的文字。只看第一项会白白报"没有内容"。
 */
internal fun clipboardText(context: Context): String? {
    val manager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
    val clip = manager.primaryClip ?: return null
    for (index in 0 until clip.itemCount) {
        val item = clip.getItemAt(index) ?: continue
        val text = item.coerceToText(context)?.toString()
        if (!text.isNullOrBlank()) return text
    }
    return null
}
