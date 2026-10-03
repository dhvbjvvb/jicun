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

    @Test
    fun `查重名的 LIKE 模式把下划线转义掉`() {
        // 批次序号就是 `标题_1`:不转义的话 `_` 会匹配任意单个字符,
        // `标题X1` 也算命中 —— 查重名等于没查。
        assertEquals("标题\\_1%", likePrefixPattern("标题_1"))
    }

    @Test
    fun `百分号和反斜杠也要转义 且顺序不能反`() {
        // 反斜杠必须**先**换:`%` 换成 `\%` 之后,那个新加的反斜杠不能再被换一次。
        assertEquals("100\\%\\_真实\\\\标题%", likePrefixPattern("100%_真实\\标题"))
        // 换个说法锁同一件事:除了结尾那个 `%`,模式里不该再有没被转义的通配符。
        assertEquals(1L, unescapedWildcards(likePrefixPattern("100%_真实\\标题")))
    }

    @Test
    fun `查重名的查询条件必须带 ESCAPE`() {
        // SQLite 的 LIKE **没有**默认转义符。少了这句 `ESCAPE`,上面那几个 `\_` 里的
        // 反斜杠只是个普通字符,模式成了「中间含一个反斜杠」→ 对 `标题_1` 永远查不到,
        // 补号静默失效(MediaPublisher.existingNames 那条路)。查不到不报错,所以只有
        // 这条用例能挡住它。
        assertEquals(
            "relative_path=? AND _display_name LIKE ? ESCAPE '\\'",
            namePrefixSelection("relative_path", "_display_name"),
        )
    }

    /** 数一遍模式里**没被转义**的 LIKE 通配符。转义符后面的那个字符不算。 */
    private fun unescapedWildcards(pattern: String): Long {
        var count = 0L
        var i = 0
        while (i < pattern.length) {
            if (pattern[i] == '\\') {
                i += 2
                continue
            }
            if (pattern[i] == '%' || pattern[i] == '_') count++
            i++
        }
        return count
    }
}

