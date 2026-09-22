package com.example.untitled

/**
 * 两个**启动入口**:一个主题一档。
 *
 * 用户点的图标就是这两个组件之一(见 AndroidManifest 里那段),各自挂一份写死不跟
 * night 走的静态启动主题 —— 启动窗口是系统在 Activity 起来之前画的,它只看被启动
 * 组件自己的主题,所以「启用哪个组件」就等于「启动图是哪一档」,和系统的深浅无关。
 * 哪一档由 [MainActivity.syncLaunchEntry] 按落盘的主题切。
 *
 * 这里除了名字什么都不加:Flutter 引擎、`jicun` 那几条通道、下载器全在
 * [MainActivity] 上,继承即可(那两条 `applyAppNightMode` / `syncLaunchEntry` 也
 * 一并继承)。
 */
class LaunchLightActivity : MainActivity()

class LaunchDarkActivity : MainActivity()

/**
 * 该启用哪个启动入口。
 *
 * 纯函数,只有一处拼名字的地方 —— MainActivity 按它切组件,而
 * test/splash_params_test.dart 拿它和 AndroidManifest.xml 里写的那两个类名对照,
 * 防止哪天重命名只在一边改了(那种错编译器不报,只有点图标才看得出来)。
 */
fun launchEntryClass(packageName: String, dark: Boolean): String =
    "$packageName." + if (dark) "LaunchDarkActivity" else "LaunchLightActivity"

/**
 * 主题档 + 系统当前是不是深色 → 走深色那一档吗。
 *
 * `dark`/`light` 是用户在「主题与外观」里显式选的;其余(含读不出来、老版本留下的
 * 脏值)一律按**跟随系统**处理。[systemNight] 由调用方从 UiModeManager 取。
 */
fun wantDark(storedMode: String?, systemNight: Boolean): Boolean = when (storedMode) {
    "dark" -> true
    "light" -> false
    else -> systemNight
}
