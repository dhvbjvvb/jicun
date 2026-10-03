package com.videofix.jicun

import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

// 落盘这一步的**接缝**。
//
// 媒体库与 SAF 两条路各自要碰的 Android API(ContentResolver / MediaStore /
// DocumentsContract)留在 MediaPublisher.kt 里那两段"怎么开一个 sink"上;而**搬的规矩**
// 全在这个文件里:按 1MB 块搬、按时间节流报进度、可见性没生效就当失败、失败必撤、
// 成功才删源。
//
// 这么切是因为这些规矩错了**不会崩**,只会安静地丢一个文件、或者往相册里留半个 ——
// 正是最贵的一类错。切出来之后它们能脱网单测(见 MediaPublisherTest),而真正碰系统
// API 的那两小段本来就得真机才验得了。

/** 复制阶段的进度节流间隔。 */
internal const val COPY_REPORT_MS = 250L

/** 一个已经打开的写入通道。[copyInto] 负责关它。 */
internal interface SinkWriter : Closeable {
    /** 写一块(写完后 buffer 的 position 前进)。返回写入的字节数。 */
    fun write(buffer: ByteBuffer): Int
}

/**
 * 一个落盘目的地。
 *
 * 用「三个 lambda」而不是接口继承:测试里能就地拼一个假的,不必为每条用例写一个类。
 */
internal class PublishSink(
    /** 最终显示名(查重名之后),只用来拼报错文案。 */
    val name: String,

    /** 打开写入通道。拿不到就抛(文案与原来一致)。 */
    val open: () -> SinkWriter,

    /**
     * 让它对外可见。返回 false = 这一步没生效,调用方必须当失败。
     *
     * 媒体库那条路是**擦 IS_PENDING**:返回 false 说明那一行没改到,记录还是 pending
     * (相册看不见它)。SAF 那条路没有这一步,直接 `true`。
     */
    val makeVisible: () -> Boolean,

    /** 失败回滚:把已经建出来的记录 / 文档撤掉。 */
    val remove: () -> Unit,
)

/**
 * 把 [source] 整条搬进 [sink],按 [onProgress] 报进度(按时间节流,收尾再强制报满一次)。
 *
 * **1MB 的直接缓冲,别用 `FileChannel.transferTo`**:源在 cache、目标是 MediaStore 的
 * FUSE 文件,这条路走不了 sendfile,会退化成 8KB 一块的用户态循环(145MB 就是一万八千次
 * 系统调用)。自己拿 1MB 直接缓冲搬,系统调用次数少两个数量级。
 */
internal fun copyInto(
    source: File,
    sink: PublishSink,
    onProgress: ((copied: Long, total: Long) -> Unit)?,
) {
    val totalBytes = source.length()
    val buffer = ByteBuffer.allocateDirect(1 shl 20)
    var copied = 0L
    var lastReport = 0L
    sink.open().use { writer ->
        FileInputStream(source).channel.use { input ->
            while (true) {
                buffer.clear()
                val read = input.read(buffer)
                if (read < 0) break
                buffer.flip()
                while (buffer.hasRemaining()) writer.write(buffer)
                copied += read
                val now = System.currentTimeMillis()
                if (onProgress != null && now - lastReport >= COPY_REPORT_MS) {
                    lastReport = now
                    onProgress(copied, totalBytes)
                }
            }
        }
    }
    if (onProgress != null && copied > 0) onProgress(copied, totalBytes)
}

/**
 * 搬进 [sink],然后让它可见、删源。三条规矩各自对应一次真实事故:
 *
 * - **可见性没生效就算失败**:记录还是 pending 时,这里紧接着就会把源删掉、调用方还会
 *   报成功 —— 那就是"静默丢一个文件"。宁可报失败,让用户重下一次。
 * - **失败必撤**:把那条记录/文档删掉,否则相册里留一个打不开的壳。
 * - **成功才删源**:源是缓存里的临时文件;失败时留给调用方(它负责删掉并报错)。
 */
internal fun publishInto(
    source: File,
    sink: PublishSink,
    onProgress: ((copied: Long, total: Long) -> Unit)?,
) {
    try {
        copyInto(source, sink, onProgress)
        if (!sink.makeVisible()) {
            throw IllegalStateException("媒体库没能把这条标成可见:${sink.name}")
        }
    } catch (e: Exception) {
        sink.remove()
        throw e
    }
    source.delete()
}
