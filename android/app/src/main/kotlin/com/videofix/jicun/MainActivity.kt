package com.videofix.jicun

import android.content.ClipboardManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.UiModeManager
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.content.res.Resources
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * 下载不再交给系统 DownloadManager,改成 Dart 侧自己收流 —— 那样才有实时进度,
 * 卡片上的圆环和百分比才是真的,用户点「取消下载」也能当场把半个文件删掉。
 *
 * Kotlin 这边只留最后一步:把下好的文件塞进系统媒体库(相册 / 音乐 App 要能看见
 * 它,就必须走 MediaStore,不能直接往公共目录写)。
 *
 * 必须是 `open`:用户点图标起来的是它的两个子类(见 [LaunchLightActivity] /
 * [LaunchDarkActivity]),那边只负责主题,其余全继承这里。
 */
open class MainActivity : FlutterActivity() {
    /**
     * 常量。名字那套算法在 DownloadNames.kt 里(那边不碰 Android API,能单测)。
     */
    private companion object {
        const val CHANNEL = "jicun/downloader"
        /** 排障用的下载基准通道,见 configureFlutterEngine。 */
        const val BENCH_CHANNEL = "jicun/bench"

        /** 日志用。夜间模式这条路上出问题时靠它定位。 */
        const val TAG = "Jicun"

        /**
         * 主题档位落盘的两个键。
         *
         * [PREFS_NAME] / [THEME_MODE_KEY] 是 **Dart 侧**写的那一份:名字来自
         * shared_preferences 插件自己的约定(文件名固定 `FlutterSharedPreferences`,
         * 键统一加 `flutter.` 前缀)。插件写它用的是 `commit()`,本身是同步落盘的。
         *
         * [NATIVE_MODE_KEY] 是**原生侧自己**再存一份(同文件、不带 `flutter.` 前缀)。
         * 为什么要多存一份:Dart 侧发 `setThemeMode` 那条通道是"发了就不等"
         * (`invokeMethod(...).ignore()`),用户在设置里点完深浅色**紧接着**清后台时,
         * 那条通知可能在进程死掉前还没跑到 —— 下一次冷启动读到的 Dart 那份还是旧的,
         * 启动图就用错档。原生侧收到通知时顺手 `commit()` 一份,启动时就先读它:
         * 只要通知跑到过,下一档就一定读得对,不依赖 Dart 那次异步写有没有落完。
         */
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val THEME_MODE_KEY = "ui.themeMode"
        const val NATIVE_MODE_KEY = "native.themeMode"

        /**
         * 公共目录下的收藏夹名。三条最终路径是:
         * `Movies/Jicun/Video`、`Pictures/Jicun/Picture`、`Music/Jicun/Music`。
         *
         * 顶层目录只能是这几个 —— MediaStore 按媒体类型锁死了它(实测图片集合直接
         * 拒收 Download/,报 `Primary directory Download not allowed … allowed
         * directories are [DCIM, Pictures]`),换成 Download 就只有 Downloads 集合
         * 收得下,而那样文件在系统里算"下载",相册和音乐 App 不收录。
         *
         * 这三条必须和设置页「存储保存位置」写的一字不差,否则那页就是在骗用户。
         */
        const val FOLDER = "Jicun"
    }

    /** 一种媒体的类型。决定进哪个 MediaStore 集合(相册/音乐 App 靠它归档)。 */
    private enum class Media { VIDEO, IMAGE, AUDIO }

    /** 一种媒体落在哪个公共目录。 */
    private data class Kind(
        val media: Media,
        /** 相对公共存储的完整路径,例如 `Movies/Jicun/Video`。 */
        val relativePath: String,
        val fallbackMime: String,
    )

    /**
     * 排障用的基准参数(lib/bench.dart 会来问)。
     *
     * 缓存成字段而不是每次读 `intent`:app 被 `am start` 唤醒过一次之后,新 intent
     * 只是递进来,引擎不会重建 —— 那一刻读 `intent` 实测拿到的是 null。
     */
    private var benchArgs: Map<String, Any?>? = null

    /** 原生下载器。第一次下载时创建(它要拿通道回推进度)。 */
    private var downloader: NativeDownloader? = null

    private fun cacheBenchArgs(source: Intent?) {
        val url = source?.getStringExtra("bench_url").orEmpty()
        val file = source?.getStringExtra("bench_file").orEmpty()
        val seq = source?.getStringExtra("bench_seq").orEmpty()
        val segments = source?.getIntExtra("bench_segments", 24) ?: 24
        // 下载器分段数(排障用)。和 bench_segments 分开:`--ei dl_segments 24` 要能
        // 单独生效,而那边的 24 是"没传"的哨兵值。
        val dlSegments = source?.getIntExtra("dl_segments", -1) ?: -1
        // 全都没传就别缓存 —— 免得把上一次的旧参数留在那儿。
        if (url.isEmpty() && file.isEmpty() && seq.isEmpty() &&
            segments == 24 && dlSegments < 0
        ) {
            benchArgs = null
            return
        }
        benchArgs = mapOf(
            "url" to url,
            "file" to file,
            "seq" to seq,
            "segments" to segments,
            "dlSegments" to dlSegments,
        )
    }

    /** 已经活着的时候被 `am start` 叫醒:新 intent 在这里更新缓存。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        cacheBenchArgs(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // **必须在 super.onCreate 之前**:这里定的是这个 Activity 的夜间模式,晚一步
        // 界面就已经按旧配置建起来了。
        applyAppNightMode(null)
        super.onCreate(savedInstanceState)
    }

    /**
     * APP 落盘的主题模式:`system` / `light` / `dark`。
     *
     * 先读原生自己那份(见 [NATIVE_MODE_KEY]),读不到再退回 Dart 那份,都没有就按
     * 跟随系统 —— 老版本升上来的用户只有 Dart 那份,这条路不能断。
     */
    private fun storedThemeMode(): String {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        prefs.getString(NATIVE_MODE_KEY, null)?.let { return it }
        return prefs.getString("flutter.$THEME_MODE_KEY", "system") ?: "system"
    }

    /**
     * 把这一档存进原生自己那份,**同步落盘**。
     *
     * 必须在收到 Dart 通知的那一刻就写完:用户点完深浅色紧接着清后台是常态,
     * 晚一拍写就可能整个丢掉(那正是启动图"跟不上"的来源)。
     */
    private fun storeThemeMode(mode: String) {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putString(NATIVE_MODE_KEY, mode)
            .commit()
    }

    /**
     * 回到前台时再对一次。
     *
     * 按应用夜间模式一旦定下,APP 的配置就**不再自己跟着手机变**了 —— 这正是它能
     * 修掉「手机深色、APP 浅色」的原因,也是代价:用户在系统设置里换了深色模式、
     * 切回 APP,APP 不会跟着变。这里补一刀。
     *
     * 跟随系统时这一刀还有个作用:把系统当前那一档重新按应用定一遍 —— 启动图在
     * onCreate 之前就画好了,用的只能是上一次留下的那一档(见 applyAppNightMode),
     * 这里写对了,下一次冷启动才是对的。
     */
    override fun onResume() {
        super.onResume()
        applyAppNightMode(null)
        // 兜底:老版本升上来、或换主题后进程没走过 setThemeMode 的,
        // 回到前台时把启动入口对到当前这一档,下次冷启动就是对的。
        syncLaunchEntry(null)
    }

    /**
     * 只在系统确认界面已经隐藏后同步 launcher 入口。
     *
     * 主题切换本身也可能触发 onStop/onStart;如果在那里禁用当前 Activity,
     * 部分 ROM 会把应用送进“应用信息”页。TRIM_MEMORY_UI_HIDDEN 只在真正离开
     * 前台后回调,此时切换入口不会影响当前可见任务。
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_UI_HIDDEN) {
            syncLaunchEntry(null)
        }
    }

    /**
     * 把 APP 内的「主题与外观」写进系统的**按应用夜间模式**。
     *
     * APP 里显式选了浅色/深色时:用 `UiModeManager.setApplicationNightMode`
     * (API 31+)把这一档按应用定死,APP 自己的资源(NormalTheme 那个窗口)才跟着走。
     * 31 以下的机器没有这个 API,那边维持系统自己的行为。
     *
     * **启动图不靠这条路了** —— 那条路在部分 ROM 上不跟手(手动换档后紧接着的冷启动
     * 仍旧画旧档,vivo 实测),现在由 [syncLaunchEntry] 换启动入口解决。
     *
     * 「跟随系统」时**不能**只调 `setApplicationNightMode(MODE_NIGHT_AUTO)`:
     * AUTO 在 UiModeManagerService 里映射成 `UI_MODE_NIGHT_UNDEFINED`,取消覆盖这件事
     * 要等这次 Activity 跑起来才落到系统里 —— 改完紧接着的那次冷启动,资源还是上一档
     * (真机实测:浅色系统 + 从深色切到跟随系统,第一次冷启动仍旧是深色,第二次才对)。
     * 按应用夜间模式**没有**"清除覆盖"的 API(`setApplicationNightMode` 只收
     * AUTO/CUSTOM/NO/YES)。所以这里把系统当前那一档读出来,直接按应用定成同一档:
     * 效果等于跟随系统,而且**下一次冷启动就是对的**。
     *
     * 代价(有意的):APP 没运行的时候用户去系统设置里换了深浅,再冷启动的那一次,
     * APP 自己的资源还是上一次离开时的档;进 APP 一跑(onResume 会把那一档再写一遍)
     * 之后,下一次启动就跟着系统了。
     *
     * [stored] 为空时读落盘的值(冷启动那条路);用户在 APP 里换主题时由 Dart 侧把
     * 新值直接传进来(见 setThemeMode 那条通道)。
     */
    private fun applyAppNightMode(stored: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val manager = getSystemService(UiModeManager::class.java) ?: return
        val storedMode = stored ?: storedThemeMode()
        val mode = if (wantDark(storedMode, systemIsDark())) {
            UiModeManager.MODE_NIGHT_YES
        } else {
            UiModeManager.MODE_NIGHT_NO
        }
        Log.i(
            TAG,
            "夜间模式:APP=$storedMode(stored=${stored != null}) → 按应用设为 $mode",
        )
        try {
            manager.setApplicationNightMode(mode)
        } catch (e: Exception) {
            // 个别 ROM 上这条路走不通:不该因为主题让 APP 起不来。
            Log.w(TAG, "设置按应用夜间模式失败:$e")
        }
    }

    /**
     * 系统现在是不是深色;读不到按浅色(系统默认)。
     *
     * 读的是系统资源那份配置(`Resources.getSystem()`),不是 app 被按应用定死之后
     * 那一档 —— 后者会把「跟随系统」永久钉在第一次读到的值上。也**不用**
     * `UiModeManager.getNightMode()`:手机用**定时深色**(如 22:00–07:00)时它返回
     * 的是 `MODE_NIGHT_CUSTOM`/`AUTO` 而不是 `MODE_NIGHT_YES`,按它判断「跟随系统」
     * + 定时深色会被定成浅色,启动图就和手机对不上 —— 之前那版就是这么错的。
     * 系统资源的 uiMode 是定时计划落定后的实际档,跟手机状态栏看到的一致。
     */
    private fun systemIsDark(): Boolean {
        return try {
            val uiMode = Resources.getSystem().configuration.uiMode
            (uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        } catch (e: Exception) {
            Log.w(TAG, "读系统夜间模式失败,按浅色处理:$e")
            false
        }
    }

    /**
     * 把 launcher 入口切到跟当前主题同一档的那个启动组件(见 [LaunchActivities.kt])。
     *
     * 为什么非切不可:启动窗口是系统在 Activity 起来之前画的,它按**被启动组件自己的
     * 主题**取资源。主题里带 night 限定符时,取的就是系统那一档 —— 用户在 app 里手动
     * 换档、系统那边没变,启动图就还是上一档(真机实测:vivo 上
     * `setApplicationNightMode` 拉不回来,小米 / 模拟器上能)。两个启动组件各挂一份
     * 写死不跟 night 走的主题,启用哪个就是哪一档 —— 从换档那一刻起就定了,跟系统
     * 深浅、跟 ROM 怎么实现按应用夜间模式都无关,API 31 以下一样有效。
     *
     * 「跟随系统」时按系统当前那一档挑,和 [applyAppNightMode] 用同一个判断
     * ([wantDark]),两边不会打架。
     */
    private fun syncLaunchEntry(stored: String?) {
        // debug 构建不切入口:Android Studio / flutter run 每次都是显式
        // `am start .../.LaunchLightActivity`(清单里第一个 LAUNCHER 组件)。
        // 组件的启用状态会被 PackageManager 落盘,重装(`install -r`)也保留 ——
        // 上一次在深色主题下离开,Light 就是禁用状态,下一次点运行就报
        // "Activity class ...LaunchLightActivity does not exist"(Error type 3)。
        // 开发期启动图本来就只看个大概,固定用 Light 那一档,release 才按主题切。
        // 用 applicationInfo 的 debuggable 而不是 BuildConfig:AGP 8 起默认不再
        // 生成 BuildConfig(本工程也没开 buildFeatures),引用它直接编译失败。
        val debuggable = 0 != applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE
        if (debuggable) return
        val dark = wantDark(stored ?: storedThemeMode(), systemIsDark())
        // 先开再关:两个 broadcast 之间至少留着一个图标,免得 launcher 那一瞬间把
        // 图标(以及用户桌面上的快捷方式)当成"应用没了"处理。
        setComponentEnabled(ComponentName(this, launchEntryClass(packageName, dark)), true)
        setComponentEnabled(ComponentName(this, launchEntryClass(packageName, !dark)), false)
    }

    /**
     * 开 / 关一个组件(这里就是那两个启动入口)。已经是这个状态就什么都不做。
     *
     * 为什么带这个判断:[syncLaunchEntry] 每次 onResume 都会跑,而
     * `setComponentEnabledSetting` 会落盘并给 launcher 发一次 package-changed ——
     * 无脑调就是白让 launcher 重排一遍图标。
     *
     * 没被显式设过时查清单里的默认值,**必须带 MATCH_DISABLED_COMPONENTS**:默认关着的
     * 那个入口不带这个 flag 查不到(抛 NameNotFoundException),于是"要开它"这一步会
     * 被静默跳过 —— 两个入口都不开,launcher 里一个图标都不剩(真机上踩到过)。
     * 查不出来就当"得写一遍",宁可多写一次也不能什么都不做。
     *
     * 失败只记日志:主题这条路不该让 APP 起不来。
     */
    private fun setComponentEnabled(name: ComponentName, enabled: Boolean) {
        val manager = packageManager
        val currently = try {
            when (manager.getComponentEnabledSetting(name)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
                else -> manager.getActivityInfo(
                    name,
                    PackageManager.MATCH_DISABLED_COMPONENTS,
                ).enabled
            }
        } catch (e: Exception) {
            Log.w(TAG, "读启动入口 ${name.className} 的状态失败,按需要写一遍:$e")
            null
        }
        if (currently == enabled) return
        try {
            manager.setComponentEnabledSetting(
                name,
                if (enabled) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                // DONT_KILL_APP:关掉的很可能就是当前这个启动入口,不能顺手把进程杀了。
                PackageManager.DONT_KILL_APP,
            )
            Log.i(TAG, "启动入口:${name.className} enabled=$enabled")
        } catch (e: Exception) {
            Log.w(TAG, "切换启动入口 ${name.className} 失败:$e")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cacheBenchArgs(intent)
        // 下载基准的触发通道(只用于排障,见 lib/bench.dart):
        //   adb shell am start -n com.videofix.jicun/.MainActivity \
        //     --es bench_url "<地址>" --ei bench_segments 24
        // 参数在 cacheBenchArgs 里缓存,**不直接读 intent** —— app 已经被 am start
        // 唤醒过之后,新 intent 只是递进来,那一刻读 intent 可能什么都读不到(实测
        // 拿到 null)。缓存一份,后续每次问都给同一份。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BENCH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "get") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(benchArgs)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 并行 Range 下载(原生实现)。**开工就返回任务 id**,进度和结果
                    // 走同一个通道反向推:dnProgress / dnDone。见 NativeDownloader。
                    "downloadMany" -> {
                        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                        val segments = call.argument<Int>("segments") ?: 16
                        if (items.isEmpty()) {
                            result.error("bad_args", "items 不能为空", null)
                        } else {
                            if (downloader == null) {
                                downloader = NativeDownloader(
                                    MethodChannel(
                                        flutterEngine.dartExecutor.binaryMessenger,
                                        CHANNEL,
                                    ),
                                )
                            }
                            result.success(downloader!!.start(items, segments))
                        }
                    }
                    "cancelDownload" -> {
                        // StandardMessageCodec 会把较小的 Dart int 解成 Integer,不能
                        // 强转 Long,否则取消调用会在这里失败且原生下载继续运行。
                        val id = (call.argument<Number>("id"))?.toLong() ?: 0L
                        downloader?.cancel(id)
                        result.success(null)
                    }
                    "publish" -> handlePublish(
                        call.argument("path"),
                        call.argument("fileName"),
                        call.argument("kind"),
                        result,
                    )
                    // 取消/失败时把这一趟已经登记的条目撤回:否则图集下到一半取消,
                    // 相册里会留下前几张。见 Downloader.nativeDownload 的兜底。
                    "unpublish" -> handleUnpublish(call.argument("uri"), result)
                    "installApk" -> handleInstall(call.argument("path"), result)
                    // 装上「安装未知应用」的权限没有,得用户自己去系统设置里开。
                    // 传给 Dart 那边,好在点「更新」的时候先问
                    "canInstallApk" -> result.success(canInstallPackages())
                    "openInstallPermission" -> {
                        result.success(openInstallPermissionSettings())
                    }
                    // 「粘贴」用:见 clipboardText 的说明 —— Flutter 引擎那套只认
                    // text/plain,从浏览器/相册复制来的内容会被它读成"空"
                    "getClipboardText" -> result.success(clipboardText())
                    // 应用内更新用:这台机器该下哪个 ABI 的包。release 里同时挂了
                    // 拆分包和通用包,Dart 侧按这个值挑(见 update_service.dart)。
                    "supportedAbi" -> result.success(primaryAbi())
                    // APP 里换了「主题与外观」:当场把启动入口和原生那一档都改掉。
                    //
                    // 不能只等下次 onCreate 读偏好 —— 启动图是系统在 Activity 起来
                    // **之前**画的:改完主题紧接着冷启动一次,画的就是这一刻的组件/
                    // 配置状态。这里当场改掉,下一次冷启动才是对的。
                    //
                    // 先同步落盘再动系统:见 [storeThemeMode] —— 用户点完立刻清后台时,
                    // 晚一步写就可能丢。
                    "setThemeMode" -> {
                        val mode = call.argument<String>("mode") ?: "system"
                        storeThemeMode(mode)
                        applyAppNightMode(mode)
                        // 启动图看的是"启用了哪个启动入口",不是按应用夜间模式:
                        // 这里不切,下次冷启动画的还是旧入口那一档。
                        syncLaunchEntry(mode)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把临时目录里的文件登记进系统媒体库。
     *
     * 失败时把临时文件删掉:留着它用户既看不到也删不掉,只会白占空间。
     */
    private fun handlePublish(
        path: String?,
        fileName: String?,
        kind: String?,
        result: MethodChannel.Result,
    ) {
        if (path.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("bad_args", "path 与 fileName 不能为空", null)
            return
        }
        val source = File(path)
        if (!source.exists()) {
            result.error("missing_file", "临时文件不在了:$path", null)
            return
        }
        try {
            val uri = publish(source, fileName, kindOf(kind))
            result.success(uri.toString())
        } catch (e: Exception) {
            source.delete()
            result.error("publish_failed", e.message ?: e.toString(), null)
        }
    }

    /**
     * 把 [handlePublish] 登记过的条目删掉(取消/失败时回滚)。
     *
     * 删的是媒体库条目,不只是文件:留着条目的话相册里会有一个打不开的壳。
     * 已经不在(用户自己删了、或系统已经清理)不算失败 —— 结果要的是"它不在了"。
     */
    private fun handleUnpublish(uri: String?, result: MethodChannel.Result) {
        if (uri.isNullOrBlank()) {
            result.error("bad_args", "uri 不能为空", null)
            return
        }
        try {
            contentResolver.delete(Uri.parse(uri), null, null)
            result.success(null)
        } catch (e: Exception) {
            result.error("unpublish_failed", e.message ?: e.toString(), null)
        }
    }

    /**
     * 媒体类型 → 集合 + 完整相对路径 + MIME 兜底。未知类型按视频处理。
     *
     * 每条路径的顶层目录都要和它登记的集合对得上,否则 MediaStore 直接拒收。
     */
    private fun kindOf(kind: String?): Kind = when (kind) {
        "audio" -> Kind(Media.AUDIO, "Music/$FOLDER/Music", "audio/mp4")
        "image" -> Kind(Media.IMAGE, "Pictures/$FOLDER/Picture", "image/jpeg")
        else -> Kind(Media.VIDEO, "Movies/$FOLDER/Video", "video/mp4")
    }

    /**
     * 写进 MediaStore 的相对路径,并复制内容。
     *
     * Q 及以上只能这么写公共目录 —— 直接 File 写到 /sdcard/Movies 会被拒。
     * [MediaStore.MediaColumns.IS_PENDING] 是给媒体扫描器的信号:标 1 时相册不看
     * 这个文件,写完擦成 0 才对外可见,避免读到只写了一半的图/视频。
     */
    private fun publish(source: File, fileName: String, kind: Kind): Uri {
        val resolver = contentResolver
        val collection = when (kind.media) {
            Media.AUDIO ->
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            Media.IMAGE ->
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            Media.VIDEO ->
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        // 重名自己补号,**不交给系统**:同一张图第二次下载时 MediaStore 会自己插一个
        // `名字 (1).jpg`,那个格式各个 ROM 未必一样,而且和批次序号混在一起(同一批
        // 第 3 张重下会变成 `标题_3 (1).jpg`,一眼读不出是第几张的第几份)。
        // 统一成 `标题_3_2.jpg`:前面那层是批次序号,后面那层是重复份数。
        val finalName = nextFreeName(collection, kind.relativePath, fileName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, finalName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeTypeOf(finalName, kind))
            put(MediaStore.MediaColumns.RELATIVE_PATH, kind.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("媒体库不接受这个文件:$finalName")
        val copyStarted = System.currentTimeMillis()
        try {
            val output = resolver.openFileDescriptor(uri, "w")
                ?: throw IllegalStateException("拿不到写入流:$finalName")
            FileInputStream(source).channel.use { input ->
                ParcelFileDescriptor.AutoCloseOutputStream(output).channel.use { target ->
                    // **别用 `FileChannel.transferTo`**:源在 cache、目标是 MediaStore 的
                    // FUSE 文件,这条路走不了 sendfile,Android 的 FileChannel 会退化成
                    // 8KB 一块的用户态循环 —— 145MB 就是一万八千次系统调用,每次都要过
                    // 一趟 FUSE。这一段正是"网络明明下完了、进度卡在 99% 很久"的那个
                    // 大头:它不在网络上,是在往相册里搬。自己拿 1MB 的直接缓冲搬,
                    // 系统调用次数少两个数量级。
                    val buffer = ByteBuffer.allocateDirect(1 shl 20)
                    while (true) {
                        buffer.clear()
                        if (input.read(buffer) < 0) break
                        buffer.flip()
                        while (buffer.hasRemaining()) target.write(buffer)
                    }
                }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        // 这一行是给"最后为什么慢"用的:网络那一段的耗时在 jicun-dl 里,搬进媒体库
        // 的耗时在这里,两边一对就知道尾巴花在哪。
        Log.i(
            TAG,
            "publish ${source.length() / (1 shl 20)}MB 搬进媒体库用时 " +
                "${System.currentTimeMillis() - copyStarted}ms → $finalName",
        )
        source.delete()
        return uri
    }

    /**
     * 这个目录里没被占用的那个名字。
     *
     * 撞名时在标题和扩展名之间插一层数字:`标题_3.jpg` → `标题_3_2.jpg`。批次序号
     * (`_3`)是 Dart 侧拼好的,重复份数(`_2`)由这里补 —— 两层分开,读得出"第 3 张
     * 的第 2 份"。
     *
     * **只查不写,查不到就用原名**:这是相册里的一个优化,查询失败(个别 ROM 上
     * 查询被拒)不该让整次下载失败 —— 退回系统自己插 `(1)` 的老行为,总比没文件强。
     */
    internal fun nextFreeName(
        collection: Uri,
        relativePath: String,
        fileName: String,
    ): String {
        val existing = try {
            existingNames(collection, relativePath, fileName)
        } catch (e: Exception) {
            Log.w(TAG, "查重名失败,按原名登记:$e")
            return fileName
        }
        return freeName(fileName, existing)
    }

    /**
     * 这个目录下所有`标题*`的名字。
     *
     * 选择条件是 `DISPLAY_NAME LIKE '标题%'` —— 覆盖面比只取已有的 `标题_N` 宽,
     * 免得用户自己改过名字的文件被当成没占用。
     */
    private fun existingNames(
        collection: Uri,
        relativePath: String,
        fileName: String,
    ): Set<String> {
        val names = mutableSetOf<String>()
        val projection = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME)
        // Android 10 以下没有 RELATIVE_PATH 这一列,查询会直接抛。那条路上返回空集,
        // 也就是"没查到重名",退回系统自己插 (1) 的老行为。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return names
        val selection =
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?"
        // LIKE 的通配符要转义,否则标题里的 `_`(文件名里太常见了)会匹配任意字符
        val pattern = takeExisting(fileName).first
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_") + "%"
        contentResolver.query(
            collection,
            projection,
            selection,
            arrayOf(relativePath, pattern),
            null,
        )?.use { cursor ->
            val column = cursor.getColumnIndexOrThrow(
                MediaStore.MediaColumns.DISPLAY_NAME,
            )
            while (cursor.moveToNext()) {
                cursor.getString(column)?.let { names.add(it) }
            }
        }
        return names
    }

    /** 显式给 MIME:媒体库按它归档,拿不到扩展名就按类型兜底,别退化成"文档"。 */
    private fun mimeTypeOf(fileName: String, kind: Kind): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: kind.fallbackMime
    }

    // ────────────────────────── 应用内更新 ──────────────────────────

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
    private fun handleInstall(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "path 不能为空", null)
            return
        }
        val apk = File(path)
        if (!apk.exists()) {
            result.error("missing_file", "安装包不在了:$path", null)
            return
        }
        if (!canInstallPackages()) {
            result.error("no_permission", "还没有「安装未知应用」权限", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
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
            startActivity(intent)
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: e.toString(), null)
        }
    }

    /**
     * 有没有「安装未知应用」的权限。Android 8 起这是每个应用单独的一项授权,
     * 没开的话系统安装器会直接拒绝,得先让用户去设置里开。
     */
    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** 跳到「安装未知应用」的授权页,把我们的包名带上,用户少找一层。 */
    private fun openInstallPermissionSettings(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).setData(
                    Uri.parse("package:$packageName"),
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
    private fun primaryAbi(): String? =
        Build.SUPPORTED_ABIS.firstOrNull { it.isNotBlank() }

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
    private fun clipboardText(): String? {
        val manager =
            getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return null
        val clip = manager.primaryClip ?: return null
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index) ?: continue
            val text = item.coerceToText(this)?.toString()
            if (!text.isNullOrBlank()) return text
        }
        return null
    }
}

