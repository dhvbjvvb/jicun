package com.videofix.jicun

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.concurrent.Executors

/**
 * 设备身份 + 硬件密钥证明(客户端那一半)。
 *
 * **为什么要有这个文件**:`/parse` 接口开在公网,谁拿到域名谁就能调 —— 一条链接解析一次
 * 要打第三方平台、占一条 request_logs、扣一份限流额度,这些成本都记在我们头上。所以给每个
 * 「装了我们 APK 的设备」发一个不可伪造的身份:
 *
 *   1. 首次启动在**安全芯片里当场生成一把不可导出的 EC P-256 私钥**(StrongBox 优先,
 *      没有就退回 TEE)。私钥永远出不了芯片,连我们自己都拿不走;
 *   2. 让芯片的公钥附一张**证明书链**(Key Attestation):Google 的根签着「这台设备、
 *      这个应用、这个挑战值下确实有过这么一把硬件密钥」。服务端拿根证书一验就知道
 *      请求是不是来自一台真的、装了正版 APK 的机器;
 *   3. 之后每个 `/parse` 请求用这把私钥签一次(canonical string,见 lib/device_identity.dart)。
 *
 * **为什么不自己造一把密钥存进 SharedPreferences**:那种密钥反编译/root 就能拷走,伪造设备
 * 零成本 —— 等于没做。芯片里的密钥不可导出,是这套方案唯一的价值所在。
 *
 * 和 MediaPublisher.kt / BackgroundPicker.kt 一样,功能自己一个文件,MainActivity 只留
 * 一行 [attach]。**不碰 Android API 的纯逻辑**(base64url、device_id 推导)提成顶层函数放在
 * 文件顶部 —— 单测(android/app/src/test/...)跑的是纯 JVM,一碰 KeyStore 就测不了。
 *
 * 协议由服务端冻结,改动必须两边一起:**签名头、待签串、device_id 的定义在
 * lib/device_identity.dart 里逐字写死了**,别只改这一边。
 */

/** 通道名。和 `jicun/downloader`、`jicun/bench` 并列(见 MainActivity.configureFlutterEngine)。 */
internal const val DEVICE_CHANNEL = "jicun/device"

/**
 * 密钥别名。
 *
 * 别名末尾带着版本后缀(`jicun_device_v1` 里的 v1):它是给**以后换算法/换参数**留的位 ——
 * 别名一改,老设备会当成「没有密钥」重新生成一把,device_id 跟着变(服务端那边等于多一台
 * 设备),但那至少是个可控的迁移;同一个别名下换参数做不到 —— AndroidKeyStore 里已存在的
 * 条目不会因为 `KeyGenParameterSpec` 变了而重建。
 */
internal const val DEVICE_KEY_ALIAS = "jicun_device_v1"

/** device_id 取 sha256 的 base64url 前多少字符(见 [deviceIdFromSpki])。 */
internal const val DEVICE_ID_LENGTH = 22

private const val ANDROID_KEYSTORE = "AndroidKeyStore"

/**
 * Key Attestation 扩展的 OID(`1.3.6.1.4.1.11129.2.1.17`,Google 的 Key Attestation 那段 ASN.1)。
 *
 * 我们**不解析**它,只看有没有 —— 有它,说明这把公钥的证书是芯片自己签出来并附了证明的
 * (StrongBox 和 TEE 都有);没有的话就是一把普通的软件密钥,不能算硬件证明。真正的解析
 * (验证签名链、比对 challenge)在服务端做,客户端解析了也没有信任价值。
 */
private const val KEY_ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17"

/**
 * 不带填充的 base64url 编码。
 *
 * 为什么不用 `android.util.Base64`:那个类只在 Android 上有,纯 JVM 单测跑不了 —— 这个函数
 * 存在的意义就是被单测盯着(device_id 的形态错一位,服务端就认不出同一台设备)。
 */
internal fun base64UrlNoPad(bytes: ByteArray): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

/** 标准 base64(带 `=` 填充)。证书链和签名都用这个 —— 协议里写的是标准编码,不是 url 安全那套。 */
internal fun base64Standard(bytes: ByteArray): String =
    Base64.getEncoder().encodeToString(bytes)

/** 解服务端下发的 base64url 挑战值。Java 的解码器容忍缺填充,所以不用先补 `=`。 */
internal fun decodeBase64Url(text: String): ByteArray =
    Base64.getUrlDecoder().decode(text.trim())

/**
 * device_id 的推导:**sha256(SPKI)** 的 base64url(无填充)取前 [DEVICE_ID_LENGTH] 个字符。
 *
 * `spki` 就是 Kotlin 里的 `key.public.encoded`(DER 编码 SubjectPublicKeyInfo)。32 字节的摘要
 * 编成 base64url 是 43 个字符,取前 22 个 ≈ 132 bit,够区分设备了。
 *
 * 日后再算一遍得到的是**同一个** device_id(公钥没变),所以重装前/后、升级前后都能对上;
 * 换一把密钥就会换一个 id —— 这正是「密钥已存在就别重建」那条约束的由来(见 [createKey])。
 */
internal fun deviceIdFromSpki(spki: ByteArray): String =
    base64UrlNoPad(MessageDigest.getInstance("SHA-256").digest(spki))
        .take(DEVICE_ID_LENGTH)

/**
 * 生成设备密钥。[strongBox] 为真时要求落在 StrongBox 里(独立安全芯片),否则普通 TEE。
 *
 * 两个参数都不能省:
 * - `setAttestationChallenge`:没有它,证书链里就没有 Key Attestation 扩展,服务端验不了;
 * - `setUserAuthenticationRequired(false)`:签名发生在**后台的解析请求**上,那时没有锁屏解锁
 *   的动作,要求认证的话每次请求都会抛 UserNotAuthenticatedException。
 */
internal fun generateDeviceKey(challenge: ByteArray, strongBox: Boolean) {
    val builder = KeyGenParameterSpec.Builder(DEVICE_KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
        .setDigests(KeyProperties.DIGEST_SHA256)
        .setUserAuthenticationRequired(false)
        .setAttestationChallenge(challenge)
    if (strongBox) builder.setIsStrongBoxBacked(true)
    val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
    generator.initialize(builder.build())
    generator.generateKeyPair()
}

/**
 * 设备身份。状态只有一份(密钥在系统密钥库里,是**全应用唯一**的),所以是 `object`。
 *
 * 四个方法(名字即 Dart 侧 `invokeMethod` 的字符串):
 * - `deviceId` → device_id,没有密钥返回 null;
 * - `createKey` → 生成密钥(已存在就复用),回 `{deviceId, attested, certificateChain}`;
 * - `certificateChain` → 证书链(叶→根)的 base64 列表,没有密钥返回 null;
 * - `sign` → 用硬件私钥签一段 payload(Dart 那边已 base64 的 canonical string),回 DER 签名的
 *   base64。
 *
 * 外加一个 `androidApi`:证明请求体里要带 `android_api`(服务端按它做策略/统计),而 Dart 侧
 * 拿不到这个整数 —— `Platform.operatingSystemVersion` 的字符串形态各引擎版本不一样,拿它去
 * 正则匹配是在赌。
 */
internal object DeviceIdentity {
    /**
     * 干活的线程。
     *
     * 生成密钥(StrongBox 上实测可以到几百毫秒)和签名都要过系统密钥库,放主线程做会顶掉
     * 首帧附近的一两帧 —— 而这活是启动时后台发起的,完全没必要占主线程。单线程够用:调用
     * 一个接一个来,没有并发。
     */
    private val work = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "jicun-device").apply { isDaemon = true }
    }

    private val main by lazy { Handler(Looper.getMainLooper()) }

    /**
     * 缓存的 KeyStore 实例。
     *
     * 签名的调用频率是**每个解析请求一次**,而 `KeyStore.getInstance(...).load(null)` 每次都要
     * 重新拿一遍 provider 句柄。缓存一份,签名失败时再丢(见 [signB64] —— 密钥被系统作废之后,
     * 老实例可能一直不认这个别名)。
     */
    @Volatile
    private var store: KeyStore? = null

    /** 供 MainActivity 一行接入(见 configureFlutterEngine)。 */
    fun attach(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                // 参数在这里就读出来:MethodCall 是不可变的,handler 返回之后结果我们留着,
                // 换到别的线程上再读也一样(但仍然只在主线程读一次,省得两边都碰它)。
                val method = call.method
                val challenge = call.argument<String>("challenge")
                val payload = call.argument<String>("payload")
                // 重登时挑战值变了 → Dart 侧会带这个开关,要求把这把废密钥清掉重建
                // (见 createKey 的说明)。字符串而不是布尔:这条通道的参数一直是字符串。
                val rebuild = call.argument<String>("rebuild") == "true"
                work.execute { dispatch(method, challenge, payload, rebuild, result) }
            }
    }

    /** 在 [work] 上跑,结果回主线程交付。 */
    private fun dispatch(
        method: String,
        challenge: String?,
        payload: String?,
        rebuild: Boolean,
        result: MethodChannel.Result,
    ) {
        val outcome = runCatching {
            when (method) {
                "deviceId" -> existingDeviceId()
                "androidApi" -> Build.VERSION.SDK_INT
                "deviceInfo" -> deviceInfo()
                "createKey" -> createKey(challenge ?: "", rebuild)
                "certificateChain" -> certificateChain()
                "sign" -> signB64(payload ?: "")
                else -> throw IllegalArgumentException("没有这个方法:$method")
            }
        }
        main.post {
            outcome.fold(
                onSuccess = { value ->
                    // 交付时引擎可能已经没了(用户在首次启动的几百毫秒里就退出了):那一下会抛
                    // MissingPluginException 之类的运行时异常,丢掉就是 —— 与推进度那两处同一个道理。
                    try {
                        result.success(value)
                    } catch (_: Throwable) {
                    }
                },
                onFailure = { error ->
                    Log.w(TAG, "设备身份 $method 失败:${briefReason(error)}")
                    try {
                        // 只说「失败了」,不把异常塞回 Dart:这条路整个是静默降级的,
                        // Dart 侧拿不到头就不加签名头,功能不能因此变差。
                        result.error("device_error", briefReason(error), null)
                    } catch (_: Throwable) {
                    }
                },
            )
        }
    }

    /** 已经存在的 device_id;没有密钥就是 null。 */
    private fun existingDeviceId(): String? {
        val leaf = leafCertificate() ?: return null
        return deviceIdFromSpki(leaf.publicKey.encoded)
    }

    /**
     * 机型(自述值),回 `{manufacturer, model}`。
     *
     * **为什么和 createKey 分开**:那条「App 升级后刷新版本号 / 机型」的路(见
     * device_identity.dart 的 _postRefresh)不该碰密钥 —— 它只要报一下机型,没必要为此去
     * 读(甚至生成)设备密钥。值来自 Build.MANUFACTURER / Build.MODEL,取不到就是空串。
     *
     * **为什么要在证明书之外另报一份**:证明书里那份 attestationIdBrand/Device/Product 很多
     * 机器根本不提供 —— 实测小米 API 36 的证书里它就是空的(同一张证书里 rootOfTrust 一切
     * 正常)。后台要「认出这是哪台机器」,只能靠这里。明确一点:这是**自述值**,服务端只拿它
     * 做显示,不当任何证据用(见 src/api/device.py 的 _client_device_info)。
     */
    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to (Build.MANUFACTURER ?: ""),
        "model" to (Build.MODEL ?: ""),
    )

    /** 证书链(base64,叶→根)。Kotlin 这边 `getCertificateChain` 就是这个顺序,**不要反转**。 */
    private fun certificateChain(): List<String>? =
        deviceChain()?.map { base64Standard(it.encoded) }

    /**
     * 生成或复用设备密钥,回 `{deviceId, attested, certificateChain}`。
     *
     * **已存在就绝不重建**:重建会换掉公钥,device_id 跟着换 —— 服务端那边等于凭空多出一台
     * 新设备,老 id 的统计和限流记录全断在原地。挑战值是**第一次生成时**用的那一个,后面的
     * 签名直接复用这把密钥,不再重新证明(证明只要做一次,服务端也已经存下了那张证书链)。
     *
     * **唯一的例外是 [rebuild]** —— 重登时挑战值换了,而证书里那个挑战值是**写死的**:
     * 继续用旧密钥的话,服务端验挑战值那一关必然不过(CHALLENGE_INVALID),这台设备就再也
     * 登记不上,用户看到的是「本接口仅供官方App使用,请更新到最新版本」而升级、重装都没用
     * (线上实测 2026-10-06:一台上过安全芯片、链也验得通的手机卡在这里)。所以那种情况下
     * 宁可换一个 device_id:走到这一步的设备本来就还没有可用身份,不重建才是死路。
     * Dart 侧只在「没有身份」那条路上带这个开关,刷新机型/版本号时不带(见 device_identity.dart
     * 的 _register)。
     */
    private fun createKey(challengeText: String, rebuild: Boolean): Map<String, Any?> {
        val challenge = if (challengeText.isEmpty()) ByteArray(0) else decodeBase64Url(challengeText)
        if (rebuild) {
            Log.w(TAG, "挑战值变了,清掉旧别名重建设备密钥")
            runCatching { keyStore().deleteEntry(DEVICE_KEY_ALIAS) }
            store = null
        }
        ensureDeviceKey(challenge)

        // 读证书链这一步**必须能自愈**。线上实测过一次:重装之后「挑战值拿到了,却始终
        // 没有 attest」—— 卡的就是这里。deviceChain() 用的是**缓存下来的 KeyStore 实例**,
        // 而那个实例可能还不认刚生成的别名(signB64 里为同一个坑已经写过一次丢缓存重试,
        // 这里当时漏了)。三种情况依次往下兜:
        var chain = deviceChain().orEmpty()
        if (chain.isEmpty()) {
            Log.w(TAG, "读完证书链是空的,丢掉缓存的 KeyStore 实例再读一次")
            store = null
            chain = deviceChain().orEmpty()
        }
        if (chain.isEmpty()) {
            // 还是空:这个别名已经废了(密钥在、证书链读不出来,谁也签不了它)。
            // 清掉重建一把 —— 宁可换一个 device_id(服务端那边会多出一行,旧行删掉即可),
            // 也好过这台设备永远停在「请更新到最新版本」上,还得重装一次才能好。
            Log.w(TAG, "证书链仍然读不到,清掉这个别名重建")
            runCatching { keyStore().deleteEntry(DEVICE_KEY_ALIAS) }
            store = null
            ensureDeviceKey(challenge)
            chain = deviceChain().orEmpty()
        }
        val leaf = chain.firstOrNull()
            ?: throw IllegalStateException("密钥库里没有证书链")
        return mapOf(
            "deviceId" to deviceIdFromSpki(leaf.publicKey.encoded),
            // 有 Key Attestation 扩展 = 这把公钥是硬件签出来并附了证明的(StrongBox 或 TEE)。
            "attested" to (leaf.getExtensionValue(KEY_ATTESTATION_OID) != null),
            "certificateChain" to chain.map { base64Standard(it.encoded) },
            // 机型那份走 deviceInfo():它自己带说明,而且刷新那条路也要用同一条(不碰密钥)。
        ) + deviceInfo()
    }

    /**
     * 保证设备密钥存在(StrongBox 优先,TEE 兜底)。
     *
     * 抽出来是因为它有两个调用点:正常生成,以及下面「别名废了、清掉重建」那条自愈路。
     * 两处的退避逻辑必须一模一样,不然迟早漂。
     */
    private fun ensureDeviceKey(challenge: ByteArray) {
        val current = keyStore()
        if (current.containsAlias(DEVICE_KEY_ALIAS)) return
        try {
            generateDeviceKey(challenge, strongBox = true)
            Log.i(TAG, "设备密钥已生成(StrongBox)")
        } catch (error: Throwable) {
            // StrongBox 是「声明支持但常常用不了」的东西:不少机器根本没有独立安全芯片,
            // 有的 ROM 支持却会抛 ProviderException 之类的别的异常 —— 所以这里**不是**
            // 只 catch StrongBoxUnavailableException,而是任何异常都退回普通 TEE 再来一次。
            // TEE 也是硬件密钥,Key Attestation 照样成立,只是安全等级低一档。
            Log.w(TAG, "StrongBox 生成失败,退回 TEE:${briefReason(error)}")
            // 上一次可能已经留下了半个条目(密钥库状态不确定),先清掉再生成。
            runCatching { current.deleteEntry(DEVICE_KEY_ALIAS) }
            generateDeviceKey(challenge, strongBox = false)
        }
    }

    /**
     * 签一段 payload(UTF-8 的 canonical string,Dart 侧已 base64 标准编码)。
     *
     * 回的是 **DER** 编码的 ECDSA-SHA256 签名 —— `SHA256withECDSA` 出来的就是这个(协议要的
     * 也是这个),不是 P1363 那种定长 `r||s`,别换 provider/算法。
     */
    private fun signB64(payloadText: String): String {
        val payload = Base64.getDecoder().decode(payloadText)
        return try {
            rawSign(payload)
        } catch (error: Throwable) {
            // 密钥被系统作废(换锁屏方式、恢复出厂设置、安全芯片被重置…)之后,缓存下来的
            // KeyStore 实例可能一直不认这个别名 —— 丢一次缓存重取再试一遍。还不行就交给
            // Dart 静默降级(不加签名头),但至少别让一次过期缓存把后面所有请求都毒死。
            Log.w(TAG, "签名失败,重取密钥库再试一次:${briefReason(error)}")
            store = null
            rawSign(payload)
        }
    }

    private fun rawSign(payload: ByteArray): String {
        val entry = keyStore().getEntry(DEVICE_KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("设备密钥不存在")
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(entry.privateKey)
        signature.update(payload)
        return base64Standard(signature.sign())
    }

    /** 证书链(叶→根)。`getCertificateChain` 的顺序就是叶→根,协议要的也是这个顺序。 */
    private fun deviceChain(): List<X509Certificate>? {
        val current = keyStore()
        if (!current.containsAlias(DEVICE_KEY_ALIAS)) return null
        return current.getCertificateChain(DEVICE_KEY_ALIAS)
            ?.filterIsInstance<X509Certificate>()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun leafCertificate(): X509Certificate? = deviceChain()?.firstOrNull()

    private fun keyStore(): KeyStore {
        store?.let { return it }
        synchronized(this) {
            store?.let { return it }
            val opened = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            store = opened
            return opened
        }
    }
}

/** 异常的一句话说明。回给 Dart 的那句用它,挑得出是哪一类失败就行。 */
private fun briefReason(error: Throwable): String = buildString {
    append(error.javaClass.simpleName)
    error.message?.let { append(": ").append(it) }
    val cause = error.cause
    if (cause != null && cause !== error) append(" ← ").append(cause.javaClass.simpleName)
}
