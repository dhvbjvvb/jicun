package com.videofix.jicun

import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.util.Log

/**
 * 启动那一刻的档:夜间模式 + 启用哪个 launcher 入口。
 *
 * 这两件事必须凑在一个文件里 —— 启动窗口是系统在 Activity 起来**之前**画的,
 * 它只看"被启动组件自己那份主题"和"按应用夜间模式",两者要按同一档一起改,
 * 分开写迟早有一边忘了跟([syncLaunchEntry] 和 [applyAppNightMode] 用的是同一个
 * [wantDark] 判断)。
 *
 * 纯算法那半边(拼入口类名 / 档位判断)在 LaunchActivities.kt,那边不碰 Android API。
 */

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
private const val PREFS_NAME = "FlutterSharedPreferences"
private const val THEME_MODE_KEY = "ui.themeMode"
private const val NATIVE_MODE_KEY = "native.themeMode"

/**
 * APP 落盘的主题模式:`system` / `light` / `dark`。
 *
 * 先读原生自己那份(见 [NATIVE_MODE_KEY]),读不到再退回 Dart 那份,都没有就按
 * 跟随系统 —— 老版本升上来的用户只有 Dart 那份,这条路不能断。
 */
internal fun storedThemeMode(context: Context): String {
    val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    prefs.getString(NATIVE_MODE_KEY, null)?.let { return it }
    return prefs.getString("flutter.$THEME_MODE_KEY", "system") ?: "system"
}

/**
 * 把这一档存进原生自己那份,**同步落盘**。
 *
 * 必须在收到 Dart 通知的那一刻就写完:用户点完深浅色紧接着清后台是常态,
 * 晚一拍写就可能整个丢掉(那正是启动图"跟不上"的来源)。
 */
internal fun storeThemeMode(context: Context, mode: String) {
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        .edit()
        .putString(NATIVE_MODE_KEY, mode)
        .commit()
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
internal fun applyAppNightMode(context: Context, stored: String?) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    val manager = context.getSystemService(UiModeManager::class.java) ?: return
    val storedMode = stored ?: storedThemeMode(context)
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
internal fun systemIsDark(): Boolean {
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
internal fun syncLaunchEntry(context: Context, stored: String?) {
    // debug 构建不切入口:Android Studio / flutter run 每次都是显式
    // `am start .../.LaunchLightActivity`(清单里第一个 LAUNCHER 组件)。
    // 组件的启用状态会被 PackageManager 落盘,重装(`install -r`)也保留 ——
    // 上一次在深色主题下离开,Light 就是禁用状态,下一次点运行就报
    // "Activity class ...LaunchLightActivity does not exist"(Error type 3)。
    // 开发期启动图本来就只看个大概,固定用 Light 那一档,release 才按主题切。
    // 用 applicationInfo 的 debuggable 而不是 BuildConfig:AGP 8 起默认不再
    // 生成 BuildConfig(本工程也没开 buildFeatures),引用它直接编译失败。
    val debuggable = 0 != context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE
    if (debuggable) return
    val dark = wantDark(stored ?: storedThemeMode(context), systemIsDark())
    // 先开再关:两个 broadcast 之间至少留着一个图标,免得 launcher 那一瞬间把
    // 图标(以及用户桌面上的快捷方式)当成"应用没了"处理。
    setComponentEnabled(context, ComponentName(context, launchEntryClass(context.packageName, dark)), true)
    setComponentEnabled(context, ComponentName(context, launchEntryClass(context.packageName, !dark)), false)
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
private fun setComponentEnabled(context: Context, name: ComponentName, enabled: Boolean) {
    val manager = context.packageManager
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
