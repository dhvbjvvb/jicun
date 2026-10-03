package com.videofix.jicun

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新的原生那半边:把下好的 APK 交给系统安装器、问「安装未知应用」的权限、
 * 报本机该下哪个 ABI 的包。
 *
 * 安装包从哪下、下哪个由 Dart 侧决定(见 update_service.dart),这里只管把这台机器
 * 的实情告诉它,以及最后那一次 `Intent` 的甩锅 —— 安装本身是系统的事。
 */

/**
 * 把下好的 APK 交给系统安装器。
 *
 * 两件事不能省:
 * - **必须走 FileProvider**:Android 7 起直接把 `file://` 递给别的应用会抛
 *   FileUriExposedException,安装器根本起不来;
 * - **必须带 FLAG_GRANT_READ_URI_PERMISSION**:那个 content:// 是我们的
 *   provider 提供的,不给临时读权限,安装器打开就是 Permission Denied。
 *
 * 装完系统会自己把我们的进程换掉(覆盖安装),所以这里不需要回调什么状态。
 */
internal fun handleInstall(activity: Activity, path: String?, result: MethodChannel.Result) {
    if (path.isNullOrBlank()) {
        result.error("bad_args", "path 不能为空", null)
        return
    }
    val apk = File(path)
    if (!apk.exists()) {
        result.error("missing_file", "安装包不在了:$path", null)
        return
    }
    if (!canInstallPackages(activity)) {
        result.error("no_permission", "还没有「安装未知应用」权限", null)
        return
    }
    try {
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(
                uri,
                "application/vnd.android.package-archive",
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        activity.startActivity(intent)
        result.success(uri.toString())
    } catch (e: Exception) {
        result.error("install_failed", e.message ?: e.toString(), null)
    }
}

/**
 * 有没有「安装未知应用」的权限。Android 8 起这是每个应用单独的一项授权,
 * 没开的话系统安装器会直接拒绝,得先让用户去设置里开。
 */
internal fun canInstallPackages(context: Context): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.packageManager.canRequestPackageInstalls()
    } else {
        true
    }

/** 跳到「安装未知应用」的授权页,把我们的包名带上,用户少找一层。 */
internal fun openInstallPermissionSettings(activity: Activity): Boolean = try {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).setData(
                Uri.parse("package:${activity.packageName}"),
            ),
        )
    }
    true
} catch (e: Exception) {
    false
}

/**
 * 本机首选的 ABI,用来挑应用内更新的安装包。
 *
 * `SUPPORTED_ABIS` 的第一项就是系统认为最好的那个(64 位优先)。上游按 ABI
 * 拆了三个包,拿错的那个系统会以「应用未安装」拒掉 —— 所以这个值必须来自
 * 原生侧,不能靠猜。取不到时返回 null,Dart 侧退回通用包。
 */
internal fun primaryAbi(): String? =
    Build.SUPPORTED_ABIS.firstOrNull { it.isNotBlank() }
