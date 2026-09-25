package com.videofix.jicun

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 相册里那份名字的重名号(见 DownloadNames.kt)。
 *
 * 只测纯函数那一段 —— 真正查媒体库那半边要设备,量不到。
 */
class MainActivityNameTest {
    @Test
    fun `没被占用就原样用原名`() {
        assertEquals("标题.jpg", freeName("标题.jpg", emptySet()))
    }

    @Test
    fun `撞名时在扩展名前插一份数`() {
        assertEquals(
            "标题_2.jpg",
            freeName("标题.jpg", setOf("标题.jpg")),
        )
    }

    @Test
    fun `批次序号和重复份数是两层`() {
        // 同一批第 3 张,第二次下载
        assertEquals(
            "标题_3_2.jpg",
            freeName("标题_3.jpg", setOf("标题_3.jpg")),
        )
        // 这两条不是同一个名字:第一条是"第 1 张",第二条是"标题的第 2 份"
        assertEquals(
            "标题_1_2.jpg",
            freeName("标题_1.jpg", setOf("标题_1.jpg")),
        )
    }

    @Test
    fun `已经有两份就取第三份`() {
        assertEquals(
            "标题_3.jpg",
            freeName("标题.jpg", setOf("标题.jpg", "标题_2.jpg")),
        )
    }

    @Test
    fun `中间删掉一份留下的空号不重用`() {
        // 用户删了 `标题_2.jpg`,留下的最大号是 3 → 下一个是 4。
        // 重用 2 会让两个不同的文件先后叫同一个名字。
        assertEquals(
            "标题_4.jpg",
            freeName("标题.jpg", setOf("标题.jpg", "标题_3.jpg")),
        )
    }

    @Test
    fun `别的后缀不算占用`() {
        // 相册里允许同名不同后缀,`标题_2.png` 不该把 `标题_2.jpg` 的位置占了
        assertEquals(
            "标题_2.jpg",
            freeName("标题.jpg", setOf("标题.jpg", "标题_2.png")),
        )
    }

    @Test
    fun `标题里的点不当分隔`() {
        // `1.5 亿` 这种标题:切错了号会插进标题中间,变成 `1_2.5 亿.jpg`
        assertEquals(
            "1.5 亿播放_2.jpg",
            freeName("1.5 亿播放.jpg", setOf("1.5 亿播放.jpg")),
        )
        assertEquals(
            "1.5 亿播放" to ".jpg",
            takeExisting("1.5 亿播放.jpg"),
        )
    }

    @Test
    fun `标题里的点后面像后缀时按后缀切`() {
        assertEquals(
            "标题.第1集" to ".mp4",
            takeExisting("标题.第1集.mp4"),
        )
    }

    @Test
    fun `没有扩展名也能加号`() {
        assertEquals(
            "标题_2",
            freeName("标题", setOf("标题")),
        )
    }
}

