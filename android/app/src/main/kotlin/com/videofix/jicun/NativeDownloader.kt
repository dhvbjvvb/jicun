package com.videofix.jicun

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * 共享游标第 [claim] 次认领到的段。
 *
 * 段的下标是**文件里的位置**,和 lane 数、和"一共几条连接"都无关 —— 共享游标就是
 * 靠这一点做到"谁空谁认领下一段"的。越界(认领次数超过段数)返回 null,调用方收工。
 *
 * 之前踩过的坑:让 lane #0..#7 各只负责一个 4MB 区间,于是无论文件多大都只收到前
 * 32MB,稳定报"下载不完整"。区间必须严丝合缝地铺满 `0 until size`,这个函数是那件事
 * 的唯一出处。
 */
internal fun claimedChunk(claim: Long, size: Long, chunkBytes: Long): LongRange? {
    require(size > 0 && chunkBytes > 0 && claim >= 0)
    val start = claim * chunkBytes
    if (start >= size) return null
    return start..(minOf(size, start + chunkBytes) - 1)
}

/**
 * 每个文件分到几路:[lanes] 是这次会话的连接额度,[items] 是同一批要下的文件数。
 *
 * 同时在飞的连接数大致就是 `文件数 × 每个的路数`,所以批量下大文件时必须摊 ——
 * 否则 4 个视频会各开满 32 条。小文件本来就不分段,摊不摊都一样。
 */
internal fun lanesPerItem(lanes: Int, items: Int): Int =
    if (items <= 1) lanes else maxOf(1, lanes / items)

/**
 * 同一次认领,但**把文件末尾那段切成小段**。
 *
 * 大段在收尾时是灾难:真机实测(153MB、32 路),31 条连接在 5.9 秒里拉完 148.7MB
 * (约 25MB/s),剩下**一条**连接又拖了 8.5 秒才收完它那 4MB(494KB/s)—— 总耗时
 * 14.4 秒里有一多半是等它一个。文件末尾 [tailBytes] 那片改用 [tailChunkBytes] 一段,
 * 同一条慢连接的拖累就按 1/4 计。
 *
 * 段越小、请求越多(每段一次连接握手),所以只在尾巴上小;文件本身不够大
 * (不到尾巴的两倍)就整条按大段走,免得小文件平白多出一串握手。
 */
internal fun claimedChunkWithTail(
    claim: Long,
    size: Long,
    chunkBytes: Long,
    tailBytes: Long,
    tailChunkBytes: Long,
): LongRange? {
    require(chunkBytes > 0 && tailBytes > 0 && tailChunkBytes > 0)
    val tailFrom = if (size > tailBytes * 2) size - tailBytes else size
    val headCount = (tailFrom + chunkBytes - 1) / chunkBytes
    if (claim < headCount) return claimedChunk(claim, tailFrom, chunkBytes)
    val offset = tailFrom
    // 文件不够大时尾巴是空的(tailFrom == size),别去问一个长度为 0 的区间。
    if (offset >= size) return null
    return claimedChunk(claim - headCount, size - offset, tailChunkBytes)
        ?.let { (it.first + offset)..(it.last + offset) }
}

/**
 * 这条连接该不该换掉(掐掉,从断点另开一条续)。
 *
 * 判据是**"用了多久还没收完这一段"**,不是速率。速率要跟谁比?同一批连接之间差 20 倍
 * 是常态(实测 47KB/s ~ 2MB/s),而整体网络差的时候所有连接一样慢 —— 拿绝对速率当
 * 判据,不是误杀就是没反应。
 *
 * 为什么需要它:段级重试只在**连接断了**的时候触发。实测有一跑 153MB 用了 32.5 秒,
 * 全程**零重置**,就是 8 条连接掉到 47~150KB/s、其余 24 条都是 1~2MB/s,最后 22 秒
 * 全在等那 8 条。慢而不死,原来的机制一点办法都没有。
 *
 * 带 Range 的那条路才能轮换:整条顺序写(`start < 0`)没有断点,换连接等于从 0 重来。
 */
internal fun shouldRotateConnection(
    start: Long,
    written: Long,
    wanted: Long,
    elapsedMs: Long,
    budgetMs: Long,
): Boolean = start >= 0 && written < wanted && elapsedMs >= budgetMs

/**
 * 带 Range 的请求回 200 时,这条响应是不是**就是我们要的那一段**。
 *
 * 服务端可以忽略 Range 直接回 200 + 整条文件(RFC 7233),那种响应按偏移写会写坏,
 * 所以默认判失败。但区间本来就等于整条文件时(起点 0、长度也对得上),200 的内容正是
 * 要的那一段,没有写坏的可能。
 *
 * 实测微信视频号的 `finder.video.qq.com`:`Range: bytes=0-<size-1>` 回 200 而不是
 * 206,而 8MB 以下的文件走的正是"一个区间铺满整条"这条路 —— 小视频因此永远报
 * 「分段下载被拒 0-2497216」,解析出来也下不动。
 */
internal fun wholeFileAsRange(
    code: Int,
    start: Long,
    end: Long,
    contentLength: Long,
): Boolean = code == 200 && start == 0L && end >= 0 && contentLength == end + 1

/**
 * 服务端明确回的错误状态码。
 *
 * 和网络层的 [IOException] 分开,是因为重试的意义完全不同:连接被重置值得再试,
 * 而 403/404 再试一百次还是 403/404 —— 探针是**串行**跑的,一批地址全失效时
 * 每个白等 1.2 秒就变成了肉眼可见的"卡住"。
 */
internal class HttpStatusError(message: String) : IOException(message)

/**
 * 一段 Range 收了一半就断了:带上**已经写进文件的字节数**。
 *
 * 有它才能断点续 —— 重试不再从这一段的开头重来。这不是省事的优化,是实测出来的
 * 浪费:真机日志里一次 153MB 的下载撞了 16 次 `Connection reset`,每次都把当前这一段
 * (最多 4MB)重下一遍,白扔的流量最多能到三成,而这条链路上每路只有 ~60KB/s。
 */
internal class TransferInterrupted(val written: Long, cause: Throwable) :
    IOException(cause.message, cause)

/**
 * 断点续传的下一跳:上一跳从 [offset] 起要 `[offset]..[end]`,实际收下 [written] 字节。
 *
 * 夹在 `end + 1` 上:"收满整段之后立刻被 RST"是会发生的(服务端用 Content-Length
 * 收完就断,客户端下一次 read 拿到的不是 EOF 而是 reset)。那种情况下一跳必须正好是
 * 段尾 + 1,否则会发出 `bytes=X-(X-1)` 这种非法区间,换回来一个 416。
 */
internal fun resumeOffset(written: Long, offset: Long, end: Long): Long =
    minOf(offset + written, end + 1)

/**
 * 一段的"还要不要接着试"的账本。
 *
 * **为什么不是"固定重试 N 次"**:B 站这类 CDN 会把**每条连接**限速到播放地址里
 * `bw` 参数那个值(实测 `bw=1048423` ≈ 128KB/s,和日志里每路 60~130KB/s 对得上),
 * 并且大约每几 MB 就断一次连接。固定 3 次在长文件上必然撞上"连续三次都断在同一个
 * 位置",于是 80% 处报错 —— 而浏览器一条连接下完,说明问题不在地址。
 *
 * 按**有没有进展**算:这一次收到了字节就把连续失败清零(断在哪就从哪续),只有连续
 * [stallLimit] 次一个字节都没收到才判这一段失败。[attemptLimit] 是兜底,防止
 * "每次只前进一丁点"变成死循环。
 */
internal class ChunkAttempts(
    private val stallLimit: Int,
    private val attemptLimit: Int,
) {
    var attempts = 0
        private set

    /** 连续"一字节都没收到"的次数。 */
    var stalls = 0
        private set

    /**
     * 记一次失败,[progress] 是这一次真正收下的字节数。
     *
     * 返回 false = 该放弃这一段了。
     */
    fun noteFailure(progress: Long): Boolean {
        attempts++
        stalls = if (progress > 0) 0 else stalls + 1
        return stalls < stallLimit && attempts < attemptLimit
    }

    /** 下一次尝试前等多久:200ms 起翻倍,封顶 2s。 */
    val delay: Long get() = minOf(200L shl (stalls - 1).coerceIn(0, 4), 2000L)
}

/**
 * 试 [attempts] 次,失败就等 [delays] 里对应的一格再试,全失败抛最后一次的异常。
 *
 * 加它的理由:**链路抖动是常态**。一条 4MB 的 Range 撞上一次
 * `SocketException: Connection reset` 或读超时,原来是整条文件判失败、前面下的
 * 全扔 —— 用户看到的就是"下载有时候失败"。段是幂等重写的(每次 Range 都
 * `seek(start)` 覆盖同一区间),所以重试同一段没有任何副作用。
 *
 * [fatal] 为真时立刻抛、不重试:取消走的就是这条路(InterruptedException),重试它
 * 等于把用户的取消吃掉。
 *
 * [sleep] 和 [onRetry] 留成参数只为了测试(不然一个用例要真等 1.2 秒)。
 */
internal fun <T> retrying(
    attempts: Int,
    delays: LongArray,
    fatal: (Throwable) -> Boolean = { false },
    sleep: (Long) -> Unit = { Thread.sleep(it) },
    onRetry: (Int, Long, Throwable) -> Unit = { _, _, _ -> },
    block: () -> T,
): T {
    require(attempts > 0) { "attempts 至少 1" }
    var last: Throwable? = null
    for (attempt in 0 until attempts) {
        try {
            return block()
        } catch (e: Throwable) {
            if (fatal(e)) throw e
            last = e
            if (attempt < attempts - 1) {
                val delay = delays.getOrElse(attempt) { delays.lastOrNull() ?: 0L }
                onRetry(attempt + 1, delay, e)
                sleep(delay)
            }
        }
    }
    throw last!!
}

/**
 * 并行 Range 下载器(原生实现)。
 *
 * 做法:
 * - 每条连接一个 Range 请求,每次拉 4MB 后继续负责区间里的下一段;
 * - 每段直接用 `RandomAccessFile.seek` 写到**目标文件的对应偏移**,不分片、不拼接 ——
 *   落盘那一步省掉了(Dart 版是下成 N 个 .part 再顺序拼,7GB 要白读白写一遍);
 * - 进度按字节累计、节流 200ms 回报一次;取消用一个 volatile 标志,每 256KB 查一次。
 *
 * 这个方法在**后台线程**跑完就返回,期间用 invokeMethod 往 Dart 推进度;UI 线程只负责
 * 把回调转出去。返回每个文件落盘的路径与 Content-Type 猜出来的后缀,扩名与入库仍由
 * Dart 侧负责(那边有 _retag 和 publish,测试也靠那两个缝)。
 */
class NativeDownloader(private val channel: MethodChannel) {

    companion object {
        /** 同时下几条文件。和 Dart 版一样取 4。 */
        private const val FILE_CONCURRENCY = 4

        /** 一条连接一次要多少字节再换下一条。 */
        private const val SEGMENT_BYTES = 4L * 1024 * 1024

        /**
         * 收尾那片的大小,以及它在里面切成多小的段。见 [claimedChunkWithTail]。
         *
         * 32MB 的尾巴按 1MB 切,最多让 32 条连接各拿一段收尾 —— 实测的慢连接
         * 只有 370~500KB/s,4MB 一段要等 8~11 秒,1MB 一段只要 2~3 秒。
         */
        private const val TAIL_BYTES = 32L * 1024 * 1024
        private const val TAIL_CHUNK_BYTES = 1L * 1024 * 1024

        /** 这么大的文件才值得分段;小的直接一条。 */
        private const val SEGMENT_FROM_BYTES = 8L * 1024 * 1024

        /**
         * 取消检查的间隔。
         *
         * 原来想在每个数据块里查,但 4MB 一段按 8KB 读就是 512 次 —— 24 条连接下这点
         * 原子读会白吃不少 CPU。256KB 查一次,取消仍然够快。
         */
        private const val CANCEL_CHECK_BYTES = 256 * 1024

        /** 进度回报节流。太密没意义,进度环本来就按百分点画。 */
        private const val PROGRESS_INTERVAL_MS = 200L

        /**
         * 一条连接最多用多久还没把当前这一段收完,就掐掉换一条。见 [shouldRotateConnection]。
         *
         * 10 秒是照着实测取的:正常连接收一段 4MB 只要 2~5 秒,10 秒还没完的基本就是
         * 被限速的那种(47~150KB/s)。调大 → 少付握手;调小 → 更快摆脱慢连接,但整体
         * 网络差时会多付几次握手。
         */
        private const val CONNECTION_BUDGET_MS = 10_000L

        /** 分段数上限,防止调用方传个荒唐的值把手机打爆。 */
        private const val MAX_SEGMENTS = 64

        /**
         * 没传分段数时的默认 lane 数。和 Dart 侧 `maxSegments` 的默认值一致。
         *
         * 别为了"少被重置"往下调:聚合速度基本和 lane 数成正比(单连接吞吐被限住),
         * 稳定性那条路由段级重试兜(见 [ChunkAttempts])。真机实测同一条 153MB 的文件:
         * 16 路快段约 13.6MB/s,32 路快段约 25MB/s —— 峰值是被连接数限住的。
         */
        private const val DEFAULT_LANES = 32

        /**
         * 请求头里的 UA。
         *
         * Java 默认发的是 `Dalvik/2.x` —— 对 CDN 的风控来说那和扫描器没区别。浏览器
         * 能下完、我们不能,UA 与 Referer 是能直接对齐的两处差异。
         */
        private const val BROWSER_UA =
            "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"

        /** 一段最多试几次(含第一次)。探针和"大小未知"那条整条下载用它。 */
        private const val ATTEMPTS = 3

        /** 每次重试前等多久。第一次短一点,第二次拉长。 */
        private val RETRY_DELAYS = longArrayOf(300, 900)

        /**
         * 一段连续几次"一个字节都没收到"才判它失败。
         *
         * 有进展就重新计数,所以这个数管的是"真的收不动了",不是"抖了几次"。
         */
        private const val STALL_LIMIT = 4

        /** 一段的尝试次数硬上限,兜住"每次只前进一丁点"的病态情况。 */
        private const val CHUNK_ATTEMPT_LIMIT = 40
    }

    private class Item(
        val url: String,
        val file: File,
    ) {
        /**
         * 这一条自己下砸了(探针失败、某条连接报错、少收字节)。
         *
         * 和 [Task.cancelled] 分开:一条失败只该放弃它自己,不能让同一批里已经下完的
         * 那几条一起陪葬 —— 用户要的是"失败的那条不留,下好的照常进相册"。
         */
        val failed = AtomicBoolean(false)
    }

    private class Task(
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        val userCancelled: AtomicBoolean = AtomicBoolean(false),
        val connections: MutableSet<HttpURLConnection> = ConcurrentHashMap.newKeySet(),
        /** 未知大小时按这个估进总量,免得进度先冲到 100% 再倒退。 */
        val total: AtomicLong = AtomicLong(1024L * 1024 * 4),
        val received: AtomicLong = AtomicLong(0),
    )

    private val counter = AtomicLong(0)
    private val tasks = ConcurrentHashMap<Long, Task>()
    private val pool = Executors.newFixedThreadPool(FILE_CONCURRENCY)
    private val main = Handler(Looper.getMainLooper())

    /**
     * 开一趟下载,**立刻返回任务 id**,真正的进度和结果走 [channel]:
     *   `dnProgress` {id, received, total}
     *   `dnDone`     {id, files:[{path,ext}], error}
     */
    fun start(rawItems: List<Map<String, Any?>>, segments: Int): Long {
        val items = rawItems.map {
            Item(
                url = it["url"] as String,
                file = File(it["path"] as String),
            )
        }
        val id = counter.incrementAndGet()
        val task = Task()
        tasks[id] = task

        pool.execute { run(id, task, items, segments) }
        return id
    }

    fun cancel(id: Long) {
        val task = tasks[id] ?: return
        task.userCancelled.set(true)
        task.cancelled.set(true)
        // 主动断开正在阻塞 read() 的连接,不必等到下一批 256KB 才响应取消。
        task.connections.toList().forEach { it.disconnect() }
    }

    private fun run(
        id: Long,
        task: Task,
        items: List<Item>,
        segments: Int,
    ) {
        val files = java.util.Collections.synchronizedList(
            ArrayList<Map<String, Any?>>(items.size),
        )
        var error: String? = null
        try {
            val lanes = if (segments <= 0) DEFAULT_LANES else minOf(segments, MAX_SEGMENTS)
            // 每条文件分到的路数:批量下大文件时按文件数把额度摊薄。
            //
            // 不摊的话 4 个 100MB 的视频会同时开出 4 × [lanes] 条连接(默认 32 就是
            // 128 条),那是拿去撞 CDN 并发上限的 —— 而总量本来就这么多,摊开只是把
            // 连接分给不同的文件。图集那种小文件本来就不分段(见 SEGMENT_FROM_BYTES),
            // 不受影响。
            val perItem = lanesPerItem(lanes, items.size)
            val lanesPool = Executors.newFixedThreadPool(minOf(perItem, items.size * perItem))
            try {
                // 先探一遍大小与类型:总量要用来画进度,那个 Content-Type 稍后给 Dart 定后缀。
                //
                // **探针失败只算这一条失败**:原来是整批一起抛,一个地址挂了会让同批
                // 其他条目一条都下不成。现在标记它自己,后面跳过它继续下别的。
                val sizes = LongArray(items.size)
                val types = arrayOfNulls<String>(items.size)
                for ((i, item) in items.withIndex()) {
                    if (task.cancelled.get()) throw InterruptedException()
                    try {
                        // 探针也重试:一次抖动不该让整条链接作废(见 [retrying])。
                        val probe = retrying(
                            attempts = ATTEMPTS,
                            delays = RETRY_DELAYS,
                            fatal = {
                                it is InterruptedException ||
                                    it is HttpStatusError ||
                                    task.cancelled.get()
                            },
                            onRetry = { n, delay, e ->
                                android.util.Log.w(
                                    "jicun-dl",
                                    "探针第 $n 次失败,${delay}ms 后重试 ${item.url}: $e",
                                )
                            },
                        ) { probe(task, item.url) }
                        sizes[i] = probe.first
                        types[i] = probe.second
                    } catch (e: InterruptedException) {
                        throw e
                    } catch (e: Throwable) {
                        item.failed.set(true)
                        if (error == null) error = describe(e)
                        android.util.Log.w(
                            "jicun-dl",
                            "探针失败,跳过 ${item.file.name}: $e",
                        )
                    }
                }
                task.total.set(sizes.sum().coerceAtLeast(1))
                android.util.Log.i(
                    "jicun-dl",
                    "开跑: items=${items.size} lanes=$lanes sizes=${sizes.joinToString()} " +
                        "total=${task.total.get()}",
                )

                // 只等真正会跑的那几条:探针就失败的不占坑
                val pending = items.count { !it.failed.get() }
                val latch = CountDownLatch(pending)
                val firstError = AtomicLong(0)
                for ((i, item) in items.withIndex()) {
                    if (item.failed.get()) continue
                    lanesPool.execute {
                        try {
                            val got = downloadItem(id, task, item, sizes[i], perItem)
                            files.add(
                                mapOf(
                                    "path" to item.file.absolutePath,
                                    "ext" to (types[i] ?: ""),
                                    // 期望大小交回 Dart:让那边能独立核一遍"落地字节
                                    // 是否等于承诺的大小"。原生这层的校验一旦有洞
                                    // (预分配撑大文件长度就是这么漏过去的),那道
                                    // 校验能挡住"弹成功通知、相册里却是坏文件"。
                                    "size" to got,
                                ),
                            )
                        } catch (e: Throwable) {
                            firstError.compareAndSet(0, 1)
                            if (task.userCancelled.get()) {
                                error = "cancelled"
                            } else if (e !is InterruptedException) {
                                // 带上异常类型:光有 message 的话,"少收了 96MB 就报完"
                                // 这种问题看不出是哪一层抛的(IOException?SocketTimeout?)。
                                error = describe(e)
                            }
                        } finally {
                            latch.countDown()
                        }
                    }
                }
                latch.await()
                if (firstError.get() != 0L && error == null) error = "下载失败"
            } finally {
                lanesPool.shutdown()
            }
        } catch (e: InterruptedException) {
            error = "cancelled"
        } catch (e: Throwable) {
            error = if (task.userCancelled.get()) {
                "cancelled"
            } else {
                describe(e)
            }
        } finally {
            tasks.remove(id)
            if (error != null) {
                // 失败时只删**没下成**的那几条:已经下完的那几条留着交给 Dart 登记
                // —— 用户要的是"失败的那条不留,同批里下好的照常进相册"。
                //
                // **用户取消是另一回事**:取消只要"取消那一刻已经出现在相册里的",
                // 所以这一批临时文件全删(含已经下完、还没轮到登记的那几条)。相册里
                // 那部分由 Dart 决定撤不撤(单条撤回,多条留着)。
                val cancelled = task.userCancelled.get()
                val done = files.mapNotNull { it["path"] as? String }.toSet()
                items.forEach { item ->
                    if (!cancelled && item.file.absolutePath in done) return@forEach
                    item.file.delete()
                }
            }
        }
        postDone(id, mapOf("error" to error, "files" to files))
    }

    /** 异常 → 给 Dart 看的一句话。带上类型,不然"哪一层抛的"看不出来。 */
    private fun describe(e: Throwable): String =
        "${e.javaClass.simpleName}: ${e.message ?: e.toString()}"

    /**
     * 状态码 → 异常。
     *
     * 4xx 是"这个地址本身不行了"(403 签名过期、404 没了),重试没有意义,归
     * [HttpStatusError] 让 [retrying] 立刻放弃;5xx 是服务端的临时毛病(502/503),
     * 归普通 [IOException] 让它再试一次。
     */
    private fun httpError(code: Int, detail: String = ""): IOException =
        if (code in 400..499) {
            HttpStatusError("HTTP $code$detail")
        } else {
            IOException("HTTP $code$detail")
        }

    /**
     * 这条地址该带哪个 Referer。认不出平台就返回 null(不动请求头)。
     *
     * B 站的 `upos-<地区>-mirror<..>.bilivideo.com` 这类镜像域名是按 Referer 白名单
     * 放行的 —— 浏览器带着 `https://www.bilibili.com/` 请求,所以能下;我们原来既没有
     * Referer 也没有浏览器 UA,能连上但更容易被中间层掐断(用户实测:浏览器全程不断,
    * App 下到 80% 报"网络中断")。把这两件浏览器本来就有的事补齐,是差异最小的一步。
     */
    private fun platformReferer(url: String): String? {
        val host = runCatching { URL(url).host?.lowercase() }.getOrNull() ?: return null
        return when {
            host.endsWith("bilivideo.com") || host.endsWith("bilibili.com") ->
                "https://www.bilibili.com/"
            else -> null
        }
    }

    /** 认得出平台就补齐 Referer + 浏览器 UA。见 [platformReferer]。 */
    private fun applyPlatformHeaders(conn: HttpURLConnection, url: String) {
        val referer = platformReferer(url) ?: return
        conn.setRequestProperty("Referer", referer)
        conn.setRequestProperty("User-Agent", BROWSER_UA)
    }

    /** 探大小:要 1 个字节,从 Content-Range 或 Content-Length 读总长度。 */
    private fun probe(task: Task, url: String): Pair<Long, String?> {
        if (task.cancelled.get()) throw InterruptedException()
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Range", "bytes=0-0")
            connectTimeout = 20000
            readTimeout = 30000
            applyPlatformHeaders(this, url)
        }
        task.connections.add(conn)
        try {
            if (task.cancelled.get()) throw InterruptedException()
            val code = conn.responseCode
            val type = conn.contentType
            val range = conn.getHeaderField("Content-Range")
            val length = when {
                code == 206 -> range?.substringAfterLast('/')?.toLongOrNull() ?: 0L
                code == 200 -> conn.contentLengthLong
                else -> throw httpError(code)
            }
            android.util.Log.i(
                "jicun-dl",
                "probe → HTTP $code Content-Range=$range Content-Length=" +
                    "${conn.getHeaderField("Content-Length")} ⇒ size=$length",
            )
            return Pair(length, type)
        } finally {
            task.connections.remove(conn)
            conn.disconnect()
        }
    }

    /** 一个文件:按 [segments] 条连接并行拉,每条拉到一段就换下一条。 */
    private fun downloadItem(
        id: Long,
        task: Task,
        item: Item,
        size: Long,
        segments: Int,
    ): Long {
        if (size <= 0) {
            // 大小未知(有些 CDN 不回 Content-Length):老实拉整条,一条连接。
            //
            // 这条也重试,但**只能整条重来** —— 不知道总长就算不出断点,重试即从头再
            // 下一遍(已知长度那条路是按 4MB 段重试的,代价小得多)。抖动一次就全废
            // 比多下一遍更糟,所以这里认这个代价。
            return retrying(
                attempts = ATTEMPTS,
                delays = RETRY_DELAYS,
                fatal = {
                    it is InterruptedException || it is HttpStatusError || stopped(task, item)
                },
                onRetry = { n, delay, e ->
                    android.util.Log.w(
                        "jicun-dl",
                        "整条下载第 $n 次失败,${delay}ms 后从头重来: $e",
                    )
                },
            ) { downloadRange(id, task, item, -1L, -1L) }
        }
        item.file.parentFile?.mkdirs()
        // 预分配到目标大小。
        //
        // **注意它和"假成功"的关系**:预分配会把文件长度直接撑到目标大小,所以
        // **绝不能**拿"文件长度够不够"当完整性判据 —— 那会永远通过,中途失败也
        // 被当成下完,用户相册里就是坏文件(实测塌过这个坑)。完整性一律看下面
        // `written`(实际写进去的字节数)。既然判据不看长度,预分配就只是性能选项:
        // 让文件系统一次把块分配好,后面的随机写不用再逐块分配。
        RandomAccessFile(item.file, "rw").use { it.setLength(size) }

        val lanes = if (size < SEGMENT_FROM_BYTES) 1 else segments
        val latch = CountDownLatch(lanes)
        val lanesPool = Executors.newFixedThreadPool(lanes)
        val written = AtomicLong(0)
        // **谁空谁认领下一段**的共享游标,而不是"每条 lane 分一块固定的 1/16"。
        //
        // 固定切分的毛病是**尾巴**:总耗时 = 最慢那条 lane 的耗时。真机实测(153MB,
        // 16 路,29 秒):前 9.5 秒 13 条 lane 就跑完了各自的 9.5MB(合计 124MB,
        // 约 13MB/s),剩下 3 条慢连接又拖了 18 秒,而且那 18 秒**只有 3 条连接在
        // 干活**,速度掉到 1.6MB/s。用户看到的就是"最后很慢很慢"。
        //
        // 共享游标之后,先空出来的 lane 会继续认领后面的段,慢连接只拖住它手里那
        // 4MB,拖不住整条文件的尾巴 —— 上面那种情况能快到一倍。
        val cursor = AtomicLong(0)
        var failure: Throwable? = null
        try {
            for (lane in 0 until lanes) {
                lanesPool.execute {
                    try {
                        var chunks = 0
                        var laneBytes = 0L
                        while (true) {
                            if (stopped(task, item)) throw InterruptedException()
                            val chunk = claimedChunkWithTail(
                                cursor.getAndIncrement(),
                                size,
                                SEGMENT_BYTES,
                                TAIL_BYTES,
                                TAIL_CHUNK_BYTES,
                            ) ?: break
                            val start = chunk.first
                            val chunkEnd = chunk.last
                            // 这一段的续传位置,以及这一段已经落盘的字节数(含重试前收到的
                            // 部分)。两者都是这一段的局部量:`written`(整条文件的累计)只在
                            // 这一段彻底了结之后加一次,不然重试会把字节数重复计进完整性校验。
                            var offset = start
                            var chunkDone = 0L
                            val tries = ChunkAttempts(STALL_LIMIT, CHUNK_ATTEMPT_LIMIT)
                            // **只要还在往前收就继续试**,不是"固定试 3 次":见 [ChunkAttempts]。
                            // 断在哪里就从哪里续,所以重试的代价只有一次连接握手。
                            chunk@ while (true) {
                                var progress = 0L
                                try {
                                    progress = downloadRange(id, task, item, offset, chunkEnd)
                                    chunkDone += progress
                                    offset += progress
                                } catch (e: InterruptedException) {
                                    throw e
                                } catch (e: HttpStatusError) {
                                    throw e
                                } catch (e: IOException) {
                                    // 收了一半就断的那种,异常里带着"已经写进去多少"。
                                    progress = if (e is TransferInterrupted) e.written else 0L
                                    val before = offset
                                    offset = resumeOffset(progress, offset, chunkEnd)
                                    chunkDone += offset - before
                                    // 已经收满整段(刚收完就被 RST):当成功,别再要一次 ——
                                    // 再要一次就是 `bytes=X-(X-1)` 那种非法区间。
                                    if (offset > chunkEnd) break@chunk
                                    if (!tries.noteFailure(progress)) throw e
                                    android.util.Log.w(
                                        "jicun-dl",
                                        "段 $start-$chunkEnd 第 ${tries.attempts} 次失败," +
                                            "${tries.delay}ms 后从 $offset 续" +
                                            "(已收 $chunkDone/${chunkEnd - start + 1}): $e",
                                    )
                                    Thread.sleep(tries.delay)
                                    continue@chunk
                                }
                                if (stopped(task, item)) throw InterruptedException()
                                if (offset > chunkEnd) break@chunk
                                // 没抛异常却一个字节都没收到(服务端干净地提前收尾):同一本账,
                                // 否则下一次请求还是同样的空响应,这里会空转成死循环。
                                if (progress == 0L) {
                                    if (!tries.noteFailure(0)) {
                                        throw IOException("这一段收不动:$offset-$chunkEnd")
                                    }
                                    Thread.sleep(tries.delay)
                                }
                            }
                            // 段是"要么整段落盘、要么抛异常"的:收满了才会走到这里。
                            // 记一次数就对得上,完整性检查(总字节 vs 文件大小)才靠得住。
                            if (chunkDone != chunkEnd - start + 1) {
                                throw IOException("这一段没收满:$chunkDone/${chunkEnd - start + 1}")
                            }
                            written.addAndGet(chunkDone)
                            laneBytes += chunkDone
                            chunks++
                        }
                        android.util.Log.i(
                            "jicun-dl",
                            "lane#$lane 退出 chunks=$chunks bytes=$laneBytes",
                        )
                    } catch (e: Throwable) {
                        synchronized(this@NativeDownloader) {
                            if (failure == null) failure = e
                        }
                        // 只作废这一条:同一批里别的文件不跟着停(见 [stopped])
                        item.failed.set(true)
                    } finally {
                        latch.countDown()
                    }
                }
            }
            latch.await()
        } finally {
            lanesPool.shutdown()
        }
        failure?.let { throw it }
        if (stopped(task, item)) throw InterruptedException()
        // 少收了字节就是残件 —— 宁可报错也别把坏文件交给相册
        if (written.get() < size) {
            throw IOException("下载不完整 ${written.get()}/$size")
        }
        return size
    }

    /**
     * 这一条是不是该停了。
     *
     * 两种情况:用户取消(整批)或这一条自己已经砸了(见 [Item.failed])。分开的理由是
     * 「一条失败不能连累同批其他条目」—— 原来两条共用一个 `task.cancelled`,一张图
     * 失败会让整批一起放弃,已经下完的那几条也跟着被删。
     */
    private fun stopped(task: Task, item: Item): Boolean =
        task.cancelled.get() || item.failed.get()

    /** 收一个 Range 区间(两端都给 -1 就是整条)。直接 seek 写到目标文件的对应偏移,返回收到多少字节。 */
    private fun downloadRange(
        id: Long,
        task: Task,
        item: Item,
        start: Long,
        end: Long,
    ): Long {
        if (stopped(task, item)) throw InterruptedException()
        val conn = (URL(item.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20000
            readTimeout = 30000
            applyPlatformHeaders(this, item.url)
        }
        task.connections.add(conn)
        try {
            if (task.cancelled.get()) throw InterruptedException()
            if (start >= 0) {
                conn.setRequestProperty("Range", "bytes=$start-$end")
            }
            val code = conn.responseCode
            // 服务端不认 Range 会回 200 + 整个文件,那样按偏移写会写坏,直接判失败;
            // 回的这一整条正好就是要的那一段时另算(见 [wholeFileAsRange])。
            val wholeFile = wholeFileAsRange(code, start, end, conn.contentLengthLong)
            if (start >= 0 && code != 206 && !wholeFile) {
                throw httpError(code, " (分段下载被拒 $start-$end)")
            }
            if (code != 200 && code != 206) throw httpError(code)
            android.util.Log.i(
                "jicun-dl",
                "range $start-$end → HTTP $code, 声明 ${conn.contentLengthLong}",
            )

            var written = 0L
            val connStarted = System.currentTimeMillis()
            try {
                conn.inputStream.use { input ->
                    RandomAccessFile(item.file, "rw").use { out ->
                        if (start >= 0) out.seek(start)
                        val buffer = ByteArray(64 * 1024)
                        var sinceCheck = 0
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            out.write(buffer, 0, read)
                            written += read
                            sinceCheck += read
                            if (sinceCheck >= CANCEL_CHECK_BYTES) {
                                sinceCheck = 0
                                // 检查点只做两件轻活:累计字节 + 判取消。
                                //
                                // **不要在这里推通道**:24 条连接、每条每 256KB 就
                                // post 一次的话,每秒上百次跨线程调用会把主线程压住,
                                // 反过来拖慢下载(实测:加了这一步之后速度从 52 掉到
                                // 20 多)。推给 Dart 的进度由 reportProgress 自己按
                                // 时间节流(200ms)。
                                reportProgress(id, task, CANCEL_CHECK_BYTES.toLong(), force = false)
                                if (stopped(task, item)) throw InterruptedException()
                                // 这一路太慢就掐掉换一条:断点续传兜底,已收的字节不
                                // 会白费(见 [shouldRotateConnection])。
                                val elapsed = System.currentTimeMillis() - connStarted
                                if (shouldRotateConnection(
                                        start,
                                        written,
                                        if (start >= 0) end - start + 1 else -1L,
                                        elapsed,
                                        CONNECTION_BUDGET_MS,
                                    )
                                ) {
                                    throw TransferInterrupted(
                                        written,
                                        IOException("这一路用了 ${elapsed}ms 还没收完,换一条连接续"),
                                    )
                                }
                            }
                        }
                        // 收尾把不足一个检查窗口的零头也报上去(这次强制推一次)
                        if (sinceCheck > 0) {
                            reportProgress(id, task, sinceCheck.toLong(), force = true)
                        }
                    }
                }
            } catch (e: InterruptedException) {
                throw e
            } catch (e: IOException) {
                // 带 Range 的那条路能续传,所以把"收了多少"带出去;整条顺序写
                // (`start < 0`)没有偏移可续,原样抛,免得日志里多一层没用的包装。
                if (written == 0L || start < 0) throw e
                throw TransferInterrupted(written, e)
            }
            return written
        } finally {
            task.connections.remove(conn)
            conn.disconnect()
        }
    }

    /**
     * 累计进度,并按时间节流推给 Dart。
     *
     * [force] 为真时跳过节流 —— 一段收尾那一发必须推出去,否则进度会卡在上一格。
     */
    private fun reportProgress(id: Long, task: Task, delta: Long, force: Boolean) {
        val received = task.received.addAndGet(delta)
        if (!force) {
            val now = System.currentTimeMillis()
            if (now - lastReport < PROGRESS_INTERVAL_MS) return
            lastReport = now
        }
        // 通道调用一律包住:它在后台线程上跑,抛出去没人接的话会直接 abort 整个
        // 进程(报 "debuggerd handler as signal handler" 那种,没有 Java 栈可看)。
        // 进度只是锦上添花 —— 推不出去就当没这一帧,绝不能让它把下载连同进程带走。
        try {
            main.post {
                try {
                    channel.invokeMethod(
                        "dnProgress",
                        mapOf(
                            "id" to id,
                            "received" to received,
                            "total" to task.total.get(),
                        ),
                    )
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
        }
    }

    /** 结果回调同样包住 —— 理由见 [reportProgress]。 */
    private fun postDone(id: Long, result: Map<String, Any?>) {
        try {
            main.post {
                try {
                    channel.invokeMethod("dnDone", mapOf("id" to id, "result" to result))
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
        }
    }

    private var lastReport = 0L
}

