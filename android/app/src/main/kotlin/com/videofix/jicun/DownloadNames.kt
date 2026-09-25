package com.videofix.jicun

/**
 * 相册里那份名字的重名号。
 *
 * 从 MainActivity 里单拎出来,是因为它**一行 Android API 都不碰** —— 留在 Activity
 * 里的话,单测一加载那个类就会撞上没 mock 的 `View.generateViewId`。算名字的规则
 * 是这里唯一的职责,查媒体库那半边在 MainActivity.existingNames 里。
 */

/** 尾部重复份数,例如 `_2`。 */
private val SUFFIX = Regex("""^(.*)_(\d+)(\.[A-Za-z0-9]{1,8})?$""")

/** 后缀认得出才认:认不出(标题里有 `.` 的时候,`1.5 亿` 这种)不切,整串按标题算。 */
private val EXT = Regex("""\.[A-Za-z0-9]{1,8}$""")

/**
 * 把一个名字拆成"标题"和"扩展名"。
 *
 * 拆的依据是**最后那个点且后面像后缀**,不是有 `.` 就切 —— 抖音标题里
 * `1.5 亿播放` 这种太常见,切错了重名号会插到标题中间去。
 */
internal fun takeExisting(name: String): Pair<String, String> {
    val dot = name.lastIndexOf('.')
    if (dot <= 0 || !EXT.matches(name.substring(dot))) return name to ""
    return name.substring(0, dot) to name.substring(dot)
}

/**
 * [existing] 里没被占用的那个名字。
 *
 * 撞名时在标题和扩展名之间插一层数字:`标题_3.jpg` → `标题_3_2.jpg`。批次序号
 * (`_3`)是 Dart 侧拼好的,重复份数(`_2`)由这里补 —— 两层分开,读得出"第 3 张
 * 的第 2 份"。也正因为分了层,这里不会去改已经拼好的那个号。
 *
 * 取已有名字里最大的号再加一,不填空号:填了的话,同一批的第五张会顶掉用户刚删掉
 * 的第三张的位置,而那个名字他可能还记着。
 */
internal fun freeName(name: String, existing: Set<String>): String {
    if (name !in existing) return name
    val (stem, ext) = takeExisting(name)
    var top = 0
    for (item in existing) {
        val match = SUFFIX.matchEntire(item) ?: continue
        if (match.groupValues[1] != stem) continue
        if (match.groupValues[3] != ext) continue
        val n = match.groupValues[2].toIntOrNull() ?: continue
        if (n > top) top = n
    }
    // 无后缀的那个名字本身就是**第一份**,所以第一次撞名给的是 `_2` 而不是 `_1`:
    // Dart 侧拼的批次序号从 1 起(`标题_1`、`标题_2`),重复份数从 2 起,两层的起点
    // 不同,但各自都是"第几"的意思,分开看都读得通。
    var next = top.coerceAtLeast(1) + 1
    // ponytail: 号只往上加,得已有几千个同名的极端情况才转得动;真撞上再换成拼
    // 时间戳,不值得现在就写。
    while ("${stem}_$next$ext" in existing) next++
    return "${stem}_$next$ext"
}
