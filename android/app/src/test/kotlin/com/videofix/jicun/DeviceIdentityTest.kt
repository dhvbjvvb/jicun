package com.videofix.jicun

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * device_id 的推导与 base64url 编码(见 DeviceIdentity.kt)。
 *
 * 只测**一行 Android API 都不碰**的那一段:真正生成密钥、签名的部分要安全芯片,纯 JVM 单测
 * 里跑不了(那是设备上的事,见文件头说明)。而这两个函数的形态是协议的一部分 —— 服务端按
 * device_id 认设备、按 base64url 解挑战值,错一位不会崩,只会让服务端**认不出同一台设备**,
 * 所以得在这里锁死。
 *
 * 那两个"魔数"不是随手编的,是固定输入的 sha256 再 base64url 的结果;换了算法/换了截取
 * 长度,这里就会红。
 */
class DeviceIdentityTest {
    @Test
    fun `base64url 无填充 且用 url 安全字符表`() {
        // 0xFB 0xFF 0xBF 这一组正好逼出标准表里那两个特殊字符(+ /),它们正是 url 安全表要换掉的
        val odd = byteArrayOf(0xFB.toByte(), 0xFF.toByte(), 0xBF.toByte())
        assertEquals("-_-_", base64UrlNoPad(odd))
        assertEquals("+/+/", base64Standard(odd))

        // 填充:两个字节标准编码带一个 `=`,url 那套不留(44 字符的 nonce 之所以是 22 字符就靠它)
        assertEquals("AAA=", base64Standard(byteArrayOf(0, 0)))
        assertEquals("AAA", base64UrlNoPad(byteArrayOf(0, 0)))
    }

    @Test
    fun `挑战值 base64url 解回来 缺填充也认`() {
        // 22 字符 / 16 字节,就是服务端下发的那副样子
        val nonce = "AAECAwQFBgcICQoLDA0ODw"
        val decoded = decodeBase64Url(nonce)
        assertEquals(16L, decoded.size.toLong())
        assertEquals(0L, decoded.first().toLong())
        // 带填充的写法一样要认:两种都是合法的 base64url,服务端给哪种我们都不该挂
        assertEquals(16L, decodeBase64Url("$nonce==").size.toLong())
    }

    @Test
    fun `device_id 是 sha256 的 base64url 前 22 个字符`() {
        assertEquals(
            "cmqGRgCA3vR2TBI8-GYEbm",
            deviceIdFromSpki("jicun-spki-vector".toByteArray(Charsets.UTF_8)),
        )
        // 空输入也算一个向量:它顺手证明"算的是 sha256 而不是直接编公钥"
        assertEquals("47DEQpj8HBSa-_TImW-5JC", deviceIdFromSpki(ByteArray(0)))
    }

    @Test
    fun `长度固定 22 且换个公钥就换一个 id`() {
        val empty = deviceIdFromSpki(ByteArray(0))
        assertEquals(22L, empty.length.toLong())
        assertEquals(DEVICE_ID_LENGTH.toLong(), empty.length.toLong())
        assertNotEquals(empty, deviceIdFromSpki(byteArrayOf(1)))
        // base64url 的字符集里不能出现 `+` `/` `=`:那两个是标准表的东西,进了 id 服务端就没法当
        // 路径/参数用
        assertEquals(empty, empty.filter { it.isLetterOrDigit() || it == '-' || it == '_' })
    }

    @Test
    fun `通道名和密钥别名是协议的一部分`() {
        // 别名一改 = 所有设备重新生成密钥 = device_id 全换了。改之前先想清楚。
        assertEquals("jicun/device", DEVICE_CHANNEL)
        assertEquals("jicun_device_v1", DEVICE_KEY_ALIAS)
    }
}
