package com.videofix.jicun

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** 选自定义背景图的系统界面(见 [BackgroundPicker])。 */
internal const val REQ_PICK_IMAGE = 9002

/**
 * 自定义背景图:从系统文件管理选一张,复制进应用私有目录,把绝对路径给 Dart。
 *
 * 选图是系统界面,异步;所以结果先挂起来,等 onActivityResult 回来再交付。
 * 挂着的状态从 MainActivity 挪到这里 —— 两次回调本来就只跟这一个流程有关。
 */
internal class BackgroundPicker(private val activity: Activity) {
    /** 系统界面还开着时,把 Dart 那次调用的 result 挂在这儿。 */
    private var pending: MethodChannel.Result? = null

    /**
     * 打开系统文件管理选一张图片做背景。
     *
     * 用 ACTION_OPEN_DOCUMENT 而不是相册的 ACTION_PICK:需求要的是「手机厂商的文件
     * 管理」,这条路各家 ROM 都能起来。拿回来的是 content uri,必须复制进应用目录 ——
     * Flutter 的 Image.file 读不了 content uri,而且那个读授权也可能被回收。
     */
    fun pick(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "已经有一个选图界面开着", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            pending = result
            activity.startActivityForResult(intent, REQ_PICK_IMAGE)
        } catch (e: Exception) {
            pending = null
            result.error("pick_failed", e.message ?: e.toString(), null)
        }
    }

    /** 背景图选择器回来了:取消回 null,选中就把图复制进应用目录、回绝对路径。 */
    fun onResult(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            result.success(copyImage(uri))
        } catch (e: Exception) {
            result.error("copy_failed", e.message ?: e.toString(), null)
        }
    }

    /**
     * 把选中的图片复制到应用私有目录,返回绝对路径。
     *
     * **每次都用唯一文件名**(createTempFile),不覆盖固定名。两个坑都在这:
     *
     * 1. 换图不立即生效:Flutter 的图片缓存按「路径」命中,同名覆盖后 `Image.file`
     *    拿到的还是缓存里那张旧图 —— 用户点了新图,界面纹丝不动。
     * 2. 重启打回默认:Dart 侧换图前会按偏好里的旧路径删一次文件;新旧同名时删的
     *    就是刚写好的新图,偏好却指向它,下次冷启动只能退回默认背景。
     *
     * 唯一名把两件事一起解决。写成功之后再清掉目录里其它旧图(刚写的这张不动);
     * 万一写失败,旧图还在,至少不会把用户已有的背景弄丢。扩展名按 Content-Type 定,
     * 读不出图片直接抛,让上层给用户一句提示。
     */
    private fun copyImage(uri: Uri): String {
        val dir = File(activity.filesDir, "background")
        if (!dir.exists()) dir.mkdirs()
        val ext = activity.contentResolver.getType(uri)
            ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            ?: "jpg"
        val target = File.createTempFile("bg_", ".$ext", dir)
        try {
            activity.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("读不到选中的图片")
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        // 新图已经落盘,再把旧的清掉,给应用目录瘦身。
        dir.listFiles()?.forEach { if (it != target) it.delete() }
        return target.absolutePath
    }
}
