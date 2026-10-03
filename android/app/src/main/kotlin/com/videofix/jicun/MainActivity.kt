package com.videofix.jicun

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 日志用。夜间模式这条路上出问题时靠它定位。 */
internal const val TAG = "Jicun"

/**
 * 下载不再交给系统 DownloadManager,改成 Dart 侧自己收流 —— 那样才有实时进度,
 * 卡片上的圆环和百分比才是真的,用户点「取消下载」也能当场把半个文件删掉。
 *
 * Kotlin 这边只留最后一步:把下好的文件塞进系统媒体库(相册 / 音乐 App 要能看见
 * 它,就必须走 MediaStore,不能直接往公共目录写)。
 *
 * 必须是 `open`:用户点图标起来的是它的两个子类(见 [LaunchLightActivity] /
 * [LaunchDarkActivity]),那边只负责主题,其余全继承这里。
 *
 * 这个类只管三件事:引擎起来时挂通道、生命周期里把主题与启动入口跟住、把通道上的
 * 调用转发给各自的实现。实现按功能拆在旁边几个文件里,每块的"为什么"写在那边:
 * - [handlePublish] / [unpublish] / [kindOf] / 选自定义存储目录 → MediaPublisher.kt
 * - 选自定义背景图 → BackgroundPicker.kt
 * - 应用内更新(APK 交给系统安装器 / ABI)→ UpdateInstaller.kt
 * - 夜间模式与启动入口 → LaunchEntryController.kt
 * - 读剪贴板 → ClipboardBridge.kt
 */
open class MainActivity : FlutterActivity() {
    /**
     * 常量。名字那套算法在 DownloadNames.kt 里(那边不碰 Android API,能单测)。
     */
    private companion object {
        const val CHANNEL = "jicun/downloader"
        /** 排障用的下载基准通道,见 configureFlutterEngine。 */
        const val BENCH_CHANNEL = "jicun/bench"
    }

    /**
     * 排障用的基准参数(lib/bench.dart 会来问)。
     *
     * 缓存成字段而不是每次读 `intent`:app 被 `am start` 唤醒过一次之后,新 intent
     * 只是递进来,引擎不会重建 —— 那一刻读 `intent` 实测拿到的是 null。
     */
    private var benchArgs: Map<String, Any?>? = null

    /** 原生下载器。第一次下载时创建(它要拿通道回推进度)。 */
    private var downloader: NativeDownloader? = null

    /** 选目录 / 选背景图那两个系统界面:挂着的 result 跟着各自实现走。 */
    private val folderPicker by lazy { FolderPicker(this) }
    private val backgroundPicker by lazy { BackgroundPicker(this) }

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
        applyAppNightMode(this, null)
        super.onCreate(savedInstanceState)
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
        applyAppNightMode(this, null)
        // 兜底:老版本升上来、或换主题后进程没走过 setThemeMode 的,
        // 回到前台时把启动入口对到当前这一档,下次冷启动就是对的。
        syncLaunchEntry(this, null)
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
            syncLaunchEntry(this, null)
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
        // 通道提成具名变量:`publish` 那条路要在复制过程中反向推进度(dnCopyProgress),
        // 得能从回调里拿到同一个通道。
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel
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
                                    // 开 / 关下载保活(前台服务 + 唤醒锁):退到后台下载被系统
                                    // 杀掉,是这条路上最贵的一次失败。
                                    onActiveChanged = { active ->
                                        DownloadKeepAlive.sync(this, active)
                                    },
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
                    // 启动清扫要知道哪些分片是**正在写的**(见 ActiveDownloads):保活让进程
                    // 活下来之后,重建的 Dart 引擎会把在下的分片误当成上次的孤儿。
                    "activeDownloads" -> result.success(ActiveDownloads.snapshot())
                    // 选一个自定义存储目录(SAF)。返回 {uri, label};用户取消返回 null。
                    "pickFolder" -> folderPicker.pick(result)
                    // 选一张自定义背景图(系统文件管理)。返回复制后的绝对路径或 null。
                    "pickBackgroundImage" -> backgroundPicker.pick(result)
                    "publish" -> handlePublish(
                        this,
                        call.argument("path"),
                        call.argument("fileName"),
                        call.argument("kind"),
                        call.argument("treeUri"),
                        result,
                        // 复制过程中回报字节数:让 Dart 的进度环在"搬进相册"这一段也一直在走
                        // (见 MediaPublisher.handlePublish 的说明)。
                        // **必须回主线程推**:这个回调是在 publishPool 线程上被调用的。
                        onCopyProgress = { copied, total ->
                            runOnUiThread {
                                try {
                                    channel.invokeMethod(
                                        "dnCopyProgress",
                                        mapOf("copied" to copied, "total" to total),
                                    )
                                } catch (_: Throwable) {
                                    // 对端没了(页面已销毁)就丢掉这一帧,别把复制带走 ——
                                    // 与 NativeDownloader 里推进度那两处同一个道理。
                                }
                            }
                        },
                    )
                    // 取消/失败时把这一趟已经登记的条目撤回:否则图集下到一半取消,
                    // 相册里会留下前几张。见 Downloader.nativeDownload 的兜底。
                    "unpublish" -> unpublish(this, call.argument("uri"), result)
                    "installApk" -> handleInstall(this, call.argument("path"), result)
                    // 装上「安装未知应用」的权限没有,得用户自己去系统设置里开。
                    // 传给 Dart 那边,好在点「更新」的时候先问
                    "canInstallApk" -> result.success(canInstallPackages(this))
                    "openInstallPermission" -> {
                        result.success(openInstallPermissionSettings(this))
                    }
                    // 「粘贴」用:见 clipboardText 的说明 —— Flutter 引擎那套只认
                    // text/plain,从浏览器/相册复制来的内容会被它读成"空"
                    "getClipboardText" -> result.success(clipboardText(this))
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
                        storeThemeMode(this, mode)
                        applyAppNightMode(this, mode)
                        // 启动图看的是"启用了哪个启动入口",不是按应用夜间模式:
                        // 这里不切,下次冷启动画的还是旧入口那一档。
                        syncLaunchEntry(this, mode)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 选目录 / 选背景图那两个系统界面回来了(实现见 FolderPicker / BackgroundPicker)。 */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK_FOLDER -> folderPicker.onResult(resultCode, data)
            REQ_PICK_IMAGE -> backgroundPicker.onResult(resultCode, data)
        }
    }
}
