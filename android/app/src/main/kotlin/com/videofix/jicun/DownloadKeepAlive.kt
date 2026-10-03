package com.videofix.jicun

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager

/** 下载器那条日志前缀,和 NativeDownloader 用同一个,排障时一起看。 */
private const val TAG_DL = "jicun-dl"

/**
 * 下载期间的保活:前台服务 + 唤醒锁。
 *
 * 为什么需要:下载跑在**应用进程**里的线程池上(见 NativeDownloader),退到后台之后
 * 进程优先级掉到最低 —— 链接正下到一半也可能被系统清掉,用户回来只看到一次失败。
 * 前台服务把进程提到「正在为用户做事」那一档,系统不再随手回收它。
 *
 * 为什么还要唤醒锁:前台服务管的是**进程**不被杀,不管 CPU 睡不睡。下载以网络等待
 * 为主,CPU 睡了连接还在(内核管着),但接收窗口满了之后没人读,速度会掉成涓流 ——
 * 拿一把 PARTIAL 锁把 CPU 钉住,免得「后台下得比前台慢一大截」变成新的报障。
 *
 * 两样都**只在真的有下载在跑的时候**开着:最后一个任务收尾就停服务,通知栏不留一条
 * 挂着的常驻通知(那是另一类报障)。
 *
 * 保活带来的副作用已经处理:进程活下来、Dart 引擎却重建过时,启动清扫会把正在写的
 * 分片当成孤儿删掉 —— 名单在 [ActiveDownloads],Dart 侧清扫按它跳过(见
 * lib/downloader.dart 的 sweepLeftovers)。
 *
 * 已知边界:用户把应用从「最近任务」里划掉,进程会活着、下载也会下完,但那时 Flutter
 * 引擎已经没了,`dnDone` 递不出去,文件停在缓存里由下次启动的清扫收掉 —— 白下一场。
 * 要让它有意义得加「进度落盘 + 重进应用续跑」,那是另一件事。
 */
internal object DownloadKeepAlive {
    /**
     * [active] 是还没跑完的任务数(排队中的也算)。0 表示可以收摊了。
     *
     * 失败只记日志:保活是**加分项**,没起来就该退回「前台能下、后台可能被杀」的老
     * 行为,不能让下载本身挂在这儿。
     */
    fun sync(context: Context, active: Int) {
        val app = context.applicationContext
        val intent = Intent(app, DownloadKeepingService::class.java)
        try {
            if (active > 0) app.startForegroundService(intent) else app.stopService(intent)
        } catch (e: Throwable) {
            android.util.Log.w(TAG_DL, "下载保活没起来(下载照常):$e")
        }
    }
}

/**
 * 保活用的前台服务。它没有业务逻辑,只负责「把进程钉在前台」+ 按住 CPU。
 *
 * 那条通知是前台服务的**必需项**(系统要求用户看得见这件事),所以它不承担业务提醒:
 * 「下好了 / 下失败了」在 Dart 侧那条通知通道上(见 lib/ui/notifications.dart)。
 */
class DownloadKeepingService : Service() {
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 必须在几秒内叫出来,否则系统直接判 ANR/干掉服务。
        startForeground(NOTIFICATION_ID, buildNotification())
        holdCpu()
        // 被系统杀掉之后别自己重启:重启出来的服务没有下载在跑,只会留一条假通知。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseCpu()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /** 静默档通知:它的作用是「让系统看见有前台服务」,不是喊用户。 */
    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "下载进行中", NotificationManager.IMPORTANCE_MIN),
            )
        }
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("正在下载")
            .setContentText("切到别的应用也会继续")
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
        // 点通知回到应用:走 launcher 那个入口,免得主题落到另一档(启动入口为什么要
        // 分成两个组件,见 AndroidManifest 里的说明)。
        packageManager.getLaunchIntentForPackage(packageName)?.let { open ->
            builder.setContentIntent(
                PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE),
            )
        }
        return builder.build()
    }

    /**
     * 按住 CPU。
     *
     * **不设超时是有意的**:下载要多久说不准,而锁的寿命跟着服务走 —— 最后一个任务
     * 收尾就 [DownloadKeepAlive.sync] 停服务,进程被杀时内核也会把锁一起收走,所以不会
     * 出现「没人管着的锁一直耗电」那种事。
     */
    private fun holdCpu() {
        if (wake != null) return
        val power = getSystemService(PowerManager::class.java)
        wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseCpu() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
    }

    private companion object {
        const val CHANNEL_ID = "jicun-download"
        const val NOTIFICATION_ID = 0x4A1
        const val WAKE_TAG = "jicun:download"
    }
}
