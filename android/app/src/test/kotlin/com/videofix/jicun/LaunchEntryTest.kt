package com.videofix.jicun

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 启动入口那一档的算法(见 LaunchActivities.kt)。
 *
 * 只测纯函数那一段 —— 切组件要设备,量不到(那半边靠
 * test/splash_params_test.dart 把清单里的类名和这里的拼法对上)。
 */
class LaunchEntryTest {
    @Test
    fun `选了深色就启用深色那个入口`() {
        assertEquals(
            "com.videofix.jicun.LaunchDarkActivity",
            launchEntryClass("com.videofix.jicun", dark = true),
        )
        assertTrue(wantDark("dark", systemNight = false))
    }

    @Test
    fun `选了浅色就启用浅色那个入口,系统是深色也不跟`() {
        assertEquals(
            "com.videofix.jicun.LaunchLightActivity",
            launchEntryClass("com.videofix.jicun", dark = false),
        )
        assertFalse(wantDark("light", systemNight = true))
    }

    @Test
    fun `跟随系统就按系统当前那一档`() {
        assertTrue(wantDark("system", systemNight = true))
        assertFalse(wantDark("system", systemNight = false))
    }

    @Test
    fun `读不出偏好或存的是脏值都按跟随系统`() {
        // 老版本升上来、偏好文件被清掉、存进来看不懂的字符串 —— 都别把用户
        // 锁在某一档上。
        assertTrue(wantDark(null, systemNight = true))
        assertFalse(wantDark(null, systemNight = false))
        assertTrue(wantDark("Dark", systemNight = true))
        assertFalse(wantDark("", systemNight = false))
    }

    @Test
    fun `应用 id 换了入口名也跟着换`() {
        assertEquals(
            "com.videofix.jicun.LaunchDarkActivity",
            launchEntryClass("com.videofix.jicun", dark = true),
        )
    }
}

