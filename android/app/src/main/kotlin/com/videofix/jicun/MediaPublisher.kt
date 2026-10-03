package com.videofix.jicun

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * 文件最终落到哪去:媒体库(相册 / 音乐 App 要能看见)或用户自选的 SAF 目录。
 *
 * 下载本身不在这里 —— 那条路在 Dart 侧收流(见 MainActivity 的类注释),
 * Kotlin 只留最后一步的搬运:[handlePublish] 登记 + 复制、[unpublish] 撤回、
 * 以及配套的重名号与 MIME。查重名那半边要碰 Android API,纯算名字的规则在
 * DownloadNames.kt。
 */

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
internal const val FOLDER = "Jicun"

/** 选自定义存储目录的系统界面(见 [FolderPicker])。 */
internal const val REQ_PICK_FOLDER = 9001

/** 一种媒体的类型。决定进哪个 MediaStore 集合(相册/音乐 App 靠它归档)。 */
internal enum class Media { VIDEO, IMAGE, AUDIO }

/** 一种媒体落在哪个公共目录。 */
internal data class Kind(
    val media: Media,
    /** 相对公共存储的完整路径,例如 `Movies/Jicun/Video`。 */
    val relativePath: String,
    val fallbackMime: String,
)

/**
 * 媒体类型 → 集合 + 完整相对路径 + MIME 兜底。未知类型按视频处理。
 *
 * 每条路径的顶层目录都要和它登记的集合对得上,否则 MediaStore 直接拒收。
 */
internal fun kindOf(kind: String?): Kind = when (kind) {
    "audio" -> Kind(Media.AUDIO, "Music/$FOLDER/Music", "audio/mp4")
    "image" -> Kind(Media.IMAGE, "Pictures/$FOLDER/Picture", "image/jpeg")
    else -> Kind(Media.VIDEO, "Movies/$FOLDER/Video", "video/mp4")
}

/**
 * 发布任务的执行线程。
 *
 * **不能在主线程上搬**:登记进媒体库要把整个文件复制一遍(实测出现过 145MB 的实拍),
 * 而平台通道的回调就跑在主线程上 —— 搬一次就是整屏冻结、进度卡正好钉在 99%,搬够
 * 5 秒系统还会弹 ANR。所以复制与登记放到这条线程上,结果再回主线程交给 Dart。
 *
 * 单线程:发布本来就是一条一条来的(Dart 侧逐条 await),串行顺手保证了
 * 「查一次重名 → 建一个文档」之间不会有两条同时挤进同一个名字。
 */
private val publishPool = Executors.newSingleThreadExecutor { task ->
    Thread(task, "jicun-publish").apply { isDaemon = true }
}

/// 回主线程调 [MethodChannel.Result]:它只能在 platform 线程上调。
private val publishMain = Handler(Looper.getMainLooper())

/**
 * 把临时目录里的文件登记进系统媒体库。
 *
 * 参数检查留在调用线程(便宜的一次 stat),重活挪去 [publishPool],结果由
 * [publishMain] 回给 Dart —— 为什么不能在主线程上搬,见上面那段说明。
 *
 * [onCopyProgress] 在复制过程中**按时间节流**回报 `(已写字节, 整条字节)`,收尾再强制
 * 报一次。Dart 那边靠它让进度环在"搬进相册"这一段也一直在走,而不是钉在某个百分比
 * (见 lib/downloader.dart 里"一个任务要搬两遍字节"的说明)。
 * 它是在 [publishPool] 线程上被调用的 —— 切线程由调用方(通道那层)负责。
 *
 * 失败时把临时文件删掉:留着它用户既看不到也删不掉,只会白占空间。
 */
internal fun handlePublish(
    context: Context,
    path: String?,
    fileName: String?,
    kind: String?,
    treeUri: String?,
    result: MethodChannel.Result,
    onCopyProgress: ((copied: Long, total: Long) -> Unit)? = null,
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
    // 后台线程不该攥着 Activity:换成 application context(要的只有 contentResolver)。
    val appContext = context.applicationContext
    publishPool.execute {
        val outcome = runCatching {
            // 用户给这个分类选过自定义目录就走 SAF,否则照旧登记媒体库。
            if (treeUri.isNullOrBlank()) {
                publish(appContext, source, fileName, kindOf(kind), onCopyProgress)
            } else {
                publishToTree(
                    appContext,
                    source,
                    fileName,
                    kindOf(kind),
                    Uri.parse(treeUri),
                    onCopyProgress,
                )
            }
        }
        publishMain.post {
            outcome.fold(
                onSuccess = { uri -> result.success(uri.toString()) },
                onFailure = { error ->
                    source.delete()
                    result.error("publish_failed", error.message ?: error.toString(), null)
                },
            )
        }
    }
}

/**
 * 把 tree uri 说成人话:`primary:Movies/我的视频` → `内部存储/Movies/我的视频`,
 * 别的卷(通常是 SD 卡)带上卷号。取不到就退回 uri 本身。
 */
internal fun treeLabel(uri: Uri): String = try {
    val docId = DocumentsContract.getTreeDocumentId(uri)
    val volume = docId.substringBefore(':', "")
    val path = docId.substringAfter(':', docId).trim('/')
    when {
        volume == "primary" -> "内部存储/$path"
        volume.isEmpty() -> path
        else -> "$volume/$path"
    }
} catch (e: Exception) {
    uri.toString()
}

/**
 * 把 [handlePublish] 登记过的条目删掉(取消/失败时回滚)。
 *
 * 删的是媒体库条目,不只是文件:留着条目的话相册里会有一个打不开的壳。
 * 已经不在(用户自己删了、或系统已经清理)不算失败 —— 结果要的是"它不在了"。
 */
internal fun unpublish(context: Context, uri: String?, result: MethodChannel.Result) {
    if (uri.isNullOrBlank()) {
        result.error("bad_args", "uri 不能为空", null)
        return
    }
    try {
        val target = Uri.parse(uri)
        // SAF 建出来的文档走 DocumentsContract 删;媒体库条目走 resolver.delete。
        if (DocumentsContract.isDocumentUri(context, target)) {
            DocumentsContract.deleteDocument(context.contentResolver, target)
        } else {
            context.contentResolver.delete(target, null, null)
        }
        result.success(null)
    } catch (e: Exception) {
        result.error("unpublish_failed", e.message ?: e.toString(), null)
    }
}

/**
 * 写进 MediaStore 的相对路径,并复制内容。
 *
 * Q 及以上只能这么写公共目录 —— 直接 File 写到 /sdcard/Movies 会被拒。
 * [MediaStore.MediaColumns.IS_PENDING] 是给媒体扫描器的信号:标 1 时相册不看
 * 这个文件,写完擦成 0 才对外可见,避免读到只写了一半的图/视频。
 *
 * 搬运的规矩(按块搬、报进度、失败必撤、成功才删源)在 [publishInto] 里;这里只负责
 * "怎么开这个 sink":插一条 pending 行 → 写 → 擦 pending → 出错撤行。
 */
private fun publish(
    context: Context,
    source: File,
    fileName: String,
    kind: Kind,
    onProgress: ((copied: Long, total: Long) -> Unit)?,
): Uri {
    val resolver = context.contentResolver
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
    val finalName = nextFreeName(context, collection, kind.relativePath, fileName)
    val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, finalName)
        put(MediaStore.MediaColumns.MIME_TYPE, mimeTypeOf(finalName, kind))
        put(MediaStore.MediaColumns.RELATIVE_PATH, kind.relativePath)
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }
    val uri = resolver.insert(collection, values)
        ?: throw IllegalStateException("媒体库不接受这个文件:$finalName")
    val copyStarted = System.currentTimeMillis()
    publishInto(
        source,
        PublishSink(
            name = finalName,
            open = {
                val output = resolver.openFileDescriptor(uri, "w")
                    ?: throw IllegalStateException("拿不到写入流:$finalName")
                val stream = ParcelFileDescriptor.AutoCloseOutputStream(output)
                // 目标是 FUSE 文件:直接缓冲 + FileChannel 写。**别绕 OutputStream** ——
                // 把它包装成通道会把 1MB 切成 8KB 一块(见 copyInto 的说明)。
                val channel = stream.channel
                object : SinkWriter {
                    override fun write(buffer: ByteBuffer): Int = channel.write(buffer)

                    override fun close() {
                        channel.close()
                        stream.close()
                    }
                }
            },
            makeVisible = {
                // 归零那一下没改到行 = 记录还是 pending(相册看不见它):返回 false,
                // publishInto 会当失败处理并把这条撤掉。
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null) > 0
            },
            remove = { resolver.delete(uri, null, null) },
        ),
        onProgress,
    )
    // 这一行是给"最后为什么慢"用的:网络那一段的耗时在 jicun-dl 里,搬进媒体库
    // 的耗时在这里,两边一对就知道尾巴花在哪。
    Log.i(
        TAG,
        "publish ${source.length() / (1 shl 20)}MB 搬进媒体库用时 " +
            "${System.currentTimeMillis() - copyStarted}ms → $finalName",
    )
    return uri
}

/**
 * 把文件写进用户选的那个 SAF 目录。
 *
 * 和 [publish] 的区别:**不登记媒体库** —— 相册/音乐 App 未必收录,这是用户
 * 选「任意文件夹」时接受的代价。直接在那个 tree 里建文档再写;返回值是文档 uri,
 * 取消/失败时靠它删。
 *
 * 搬运的规矩同样在 [publishInto] 里;SAF **没有** IS_PENDING 那一步,建出来就可见。
 */
private fun publishToTree(
    context: Context,
    source: File,
    fileName: String,
    kind: Kind,
    treeUri: Uri,
    onProgress: ((copied: Long, total: Long) -> Unit)?,
): Uri {
    val resolver = context.contentResolver
    val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
    val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
    val finalName = nextFreeNameInTree(context, treeUri, treeDocId, fileName)
    val docUri = DocumentsContract.createDocument(
        resolver,
        parent,
        mimeTypeOf(finalName, kind),
        finalName,
    ) ?: throw IllegalStateException("这个目录不收新文件:$finalName")
    publishInto(
        source,
        PublishSink(
            name = finalName,
            open = {
                val out = resolver.openOutputStream(docUri, "w")
                    ?: throw IllegalStateException("拿不到写入流:$finalName")
                // SAF 给的是流(拿不到 FileChannel),所以把直接缓冲拷进一个复用数组再写 ——
                // 同样是 1MB 一块,和媒体库那条路一个量级。
                var scratch = ByteArray(0)
                object : SinkWriter {
                    override fun write(buffer: ByteBuffer): Int {
                        val length = buffer.remaining()
                        if (scratch.size < length) scratch = ByteArray(length)
                        buffer.get(scratch, 0, length)
                        out.write(scratch, 0, length)
                        return length
                    }

                    override fun close() = out.close()
                }
            },
            makeVisible = { true },
            remove = {
                try {
                    DocumentsContract.deleteDocument(resolver, docUri)
                } catch (ignored: Exception) {
                    // 删不掉也不能盖住真正的失败原因
                }
            },
        ),
        onProgress,
    )
    return docUri
}

/**
 * SAF 目录里没被占用的名字。查同目录的子项,撞名规则和 [nextFreeName] 一样
 * (在扩展名前补 `_n`)。查询失败就按原名建,交给提供方自己处理冲突。
 */
private fun nextFreeNameInTree(
    context: Context,
    treeUri: Uri,
    treeDocId: String,
    fileName: String,
): String {
    val existing = try {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            treeDocId,
        )
        val names = mutableSetOf<String>()
        context.contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val column = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            while (cursor.moveToNext()) {
                cursor.getString(column)?.let { names.add(it) }
            }
        }
        names
    } catch (e: Exception) {
        Log.w(TAG, "SAF 查重名失败,按原名建:${e.message}")
        return fileName
    }
    return freeName(fileName, existing)
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
    context: Context,
    collection: Uri,
    relativePath: String,
    fileName: String,
): String {
    val existing = try {
        existingNames(context, collection, relativePath, fileName)
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
 *
 * 模式里的通配符要转义、查询上要带 `ESCAPE`,这两件事都不能省 —— 省了就是「永远
 * 查不到重名」,不报错。拼法在 [likePrefixPattern] / [namePrefixSelection] 里(纯
 * 函数,有单测)。
 */
private fun existingNames(
    context: Context,
    collection: Uri,
    relativePath: String,
    fileName: String,
): Set<String> {
    val names = mutableSetOf<String>()
    val projection = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME)
    // Android 10 以下没有 RELATIVE_PATH 这一列,查询会直接抛。那条路上返回空集,
    // 也就是"没查到重名",退回系统自己插 (1) 的老行为。
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return names
    val selection = namePrefixSelection(
        MediaStore.MediaColumns.RELATIVE_PATH,
        MediaStore.MediaColumns.DISPLAY_NAME,
    )
    val pattern = likePrefixPattern(takeExisting(fileName).first)
    context.contentResolver.query(
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

/**
 * 选自定义存储目录(SAF)。系统目录选择器是异步的,所以把 result 挂起来,
 * 等 onActivityResult 回来再回。
 *
 * 返回 `{uri, label}`:uri 是 tree uri(已经 takePersistableUriPermission,
 * 重启后还能写),label 是给界面看的可读路径。用户取消回 null。
 *
 * 挂着的状态从 MainActivity 挪到这里:那条通道的两次回调(发起来 / 收结果)
 * 本来就只跟这一个流程有关,状态跟着走才不会被顺手改坏。
 */
internal class FolderPicker(private val activity: Activity) {
    /** 系统界面还开着时,把 Dart 那次调用的 result 挂在这儿。 */
    private var pending: MethodChannel.Result? = null

    fun pick(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "已经有一个目录选择界面开着", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            pending = result
            activity.startActivityForResult(intent, REQ_PICK_FOLDER)
        } catch (e: Exception) {
            pending = null
            result.error("pick_failed", e.message ?: e.toString(), null)
        }
    }

    /** 目录选择器回来了:授权持久化后把 {uri, label} 回给 Dart。取消回 null。 */
    fun onResult(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        // 不 take 的话这个授权只活到进程结束,下次冷启动写就失败。
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: Exception) {
            Log.w(TAG, "持久化目录授权失败:${e.message}")
        }
        result.success(
            mapOf(
                "uri" to uri.toString(),
                "label" to treeLabel(uri),
            ),
        )
    }
}
