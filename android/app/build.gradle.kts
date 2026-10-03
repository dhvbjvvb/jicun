import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名。凭据放在 android/key.properties(不进版本库),keystore 放在
// android/app/ 下。
//
// 缺文件时的行为:**产出 release 产物的任务直接失败**(守卫在文件末尾)。以前是静默
// 退回 debug 签名 —— 那样能产出一个装得上、却因为签名不对既不能上架也不能覆盖安装的
// "release" 包,而且一句提示都没有。本机想用 debug 签名跑一次 release,显式给
// `-PallowDebugSigning=true`。
val keystoreProperties = Properties()
// 凭据文件的位置可以用 -PkeystorePropertiesFile=... 换掉:守卫那条失败路径靠它来测
// (拿一个不存在的路径跑一次 assembleRelease,必须红)。默认就是标准位置。
val keystoreFile = providers.gradleProperty("keystorePropertiesFile")
    .getOrElse("key.properties")
val keystorePropertiesFile = rootProject.file(keystoreFile)
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

/** 显式放行:本机用 debug 签名跑 release。别拿这种包去分发。 */
val allowDebugSigning = providers.gradleProperty("allowDebugSigning").orNull == "true"

android {
    namespace = "com.videofix.jicun"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // applicationId 定了**别改**:改了等于换一个应用 —— 同样的签名也覆盖安装不上,
        // 相册里已登记的文件还挂在旧包名上。
        applicationId = "com.videofix.jicun"
        // 最低 Android 10(API 29)。**别再往下调**:发布进相册那条路只写了分区存储
        // (MediaStore 的 RELATIVE_PATH / IS_PENDING / getContentUri(volume))那一套 API,
        // 29 以下没有它们 —— 调回 24~28 的话,那些机器上文件下得下来却存不进相册
        // (insert 拒收,或者 getContentUri(String) 抛 NoSuchMethodError,那条 Error
        // 连 catch (Exception) 都兜不住)。要支持老系统得先补一条 pre-Q 的发布路径。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用正式签名,否则退回 debug。缺凭据又要打包时,末尾那条
            // 守卫会先失败 —— 这里的兜底只为 `-PallowDebugSigning=true` 那条路留着。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 代码与资源压缩。上面那条决定包**能不能发**,这两句决定包有多大:不压缩的话,
            // Kotlin 侧只用在一两个分支里的类、以及没有任何引用的资源都会原样进包。
            // 规则文件见 android/app/proguard-rules.pro(每条 keep 都写了为什么)。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")
    // org.json 在 Android 上由系统提供,但**单测(纯 JVM)里是个空壳**:
    // 调用会抛 "Method ... not mocked"。读下载器测试向量
    // (tool/download_logic_vectors.json,见 DownloadLogicVectorsTest)要用真的
    // JSONObject,所以这里显式带一个实现。
    testImplementation("org.json:json:20240303")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}


/**
 * 缺签名凭据就不许产出 release 产物。
 *
 * 不能在上面那个块里直接抛:那是**配置阶段**,debug 构建、单测、`flutter analyze`
 * 都会路过,那时候抛会把无关的活一起打死。所以挂到真正打包 release 的任务自己的
 * doFirst 上 —— 只有真要产出 release 产物时才失败。
 *
 * 任务名按「assemble/bundle + Release 结尾」认:`assembleRelease`、`bundleRelease`
 * 都在内,`assembleReleaseUnitTest`(跑的是单测)不在内。
 */
tasks.configureEach {
    val producesRelease = (name.startsWith("assemble") || name.startsWith("bundle")) &&
        name.endsWith("Release")
    if (!producesRelease) return@configureEach
    doFirst {
        if (hasReleaseKey || allowDebugSigning) return@doFirst
        throw GradleException(
            "缺签名凭据:$keystorePropertiesFile\n" +
                "  · 要发版:按 README「构建」一节建好 android/key.properties 与 keystore;" +
                "这两个文件都不进版本库。\n" +
                "  · 只想在本机跑一次 release:-PallowDebugSigning=true" +
                "(产物是 debug 签名,别拿去分发)。",
        )
    }
}

/**
 * 生成物的「构建模式残留」:直接调 gradle 打 release 之前,把插件注册器里的 dev 依赖行去掉。
 *
 * Flutter 把插件注册器写在**同一个路径**
 * (`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`),内容却按
 * 构建模式不同:release 模式会剔掉 dev 依赖(Flutter 自己的判据在 flutter_tools 的
 * `flutter_plugins.dart`:「Filter out dev dependencies for release builds」),debug/profile
 * 会带上;而 Flutter 的 Gradle 插件(PluginHandler)也只给**非 release 变体**加 dev 依赖插件的
 * 编译依赖。两者一撞就是:
 *
 *   1. 在 gradle 里跑过一次 debug(单测、assembleDebug)→ 文件是 debug 形态(点名
 *      `integration_test`);
 *   2. 再直接 `gradlew :app:assembleRelease` → release 变体编译到这份文件,而它的编译类路径上
 *      没有 integration_test → `javac` 报
 *      `package dev.flutter.plugins.integration_test does not exist`。
 *
 * **只有绕过 flutter、直接调 gradle 才会踩到**:走 `flutter build apk --release` 时 Flutter
 * 自己会先按 release 重写这份文件(实测 `--config-only --release` 也会重写)。而 gradle 那两个
 * `compileFlutterBuild*` 任务**不写**它 —— 所以只得在这里补上那次重写。
 *
 * 只删 dev 依赖那几行,别的字节不动 —— 与 Flutter release 形态的产物逐字节一致(拿
 * `flutter build apk --release --config-only` 的结果当对照比过)。判据与 Flutter 相同:
 * `.flutter-plugins-dependencies` 里 `dev_dependency == true` 的 Android 插件。
 */
val stripDevPluginRegistrations by tasks.registering {
    description = "release 编译前去掉插件注册器里的 dev 依赖行(见上面那段说明)"
    val registrant = layout.projectDirectory
        .file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
    // .flutter-plugins-dependencies 在 Flutter 工程根(android 的上一级)
    val pluginsMeta = rootProject.layout.projectDirectory
        .file("../.flutter-plugins-dependencies")
    // 可能不存在(干净检出、还没跑过 pub get)。那种情况下这个任务什么都不做,所以标
    // optional —— 否则 Gradle 会在执行前就以「输入文件不存在」失败,里面的兜底判断
    // 根本走不到。
    inputs.file(pluginsMeta).withPropertyName("pluginsDependencies").optional()
    outputs.file(registrant).withPropertyName("registrant")
    doLast {
        val file = registrant.asFile
        if (!file.exists()) return@doLast
        if (!pluginsMeta.asFile.exists()) {
            logger.warn(
                "没有 ${pluginsMeta.asFile}:跳过 dev 依赖行清理。" +
                    "要是 release 编译报 integration_test 找不到,先跑一次 `flutter pub get`。",
            )
            return@doLast
        }
        val meta = groovy.json.JsonSlurper().parse(pluginsMeta.asFile) as? Map<*, *>
        val androidPlugins =
            ((meta?.get("plugins") as? Map<*, *>)?.get("android") as? List<*>).orEmpty()
        // 注意:这里的条目只有 name / path / native_build / dependencies / dev_dependency ——
        // **没有** package / class。所以只能按插件名认行(一个注册块里 `add(new …)` 与
        // `Log.e(…)` 两行都带着插件名)。
        val devNames = androidPlugins.mapNotNull { entry ->
            val plugin = entry as? Map<*, *> ?: return@mapNotNull null
            val name = plugin["name"] as? String
            if (plugin["dev_dependency"] == true && name != null) name else null
        }.toSet()
        if (devNames.isEmpty()) return@doLast
        val lines = file.readText().split("\n").toMutableList()
        var removedBlocks = 0
        var i = 0
        while (i < lines.size) {
            val isAddLine = lines[i].contains("add(new ") && devNames.any { it in lines[i] }
            if (!isAddLine) {
                i++
                continue
            }
            // 一个插件一个 5 行的注册块(模板固定,见 flutter_plugins.dart 的
            // _androidPluginRegistryTemplateNewEmbedding):
            //     try { / add(new …); / } catch (Exception e) { / Log.e(TAG, …); / }
            // 形状对不上就不动:留给编译期报出来,别把文件改坏。
            val shapeOk = i >= 1 && i + 3 < lines.size &&
                lines[i - 1].trim() == "try {" &&
                lines[i + 1].trim().startsWith("} catch (Exception e)") &&
                lines[i + 2].trim().startsWith("Log.e(TAG,") &&
                lines[i + 3].trim() == "}"
            if (!shapeOk) {
                logger.warn(
                    "插件注册器的形状与预期不一致,没敢动它。" +
                        "release 编译若报 dev 依赖找不到,请改走 `flutter build apk --release`。",
                )
                return@doLast
            }
            repeat(5) { lines.removeAt(i - 1) }
            removedBlocks++
            i -= 1
        }
        if (removedBlocks == 0) return@doLast
        file.writeText(lines.joinToString("\n"))
        logger.lifecycle(
            "插件注册器去掉 $removedBlocks 个 dev 依赖的注册块:$devNames" +
                "(只有直接调 gradle 打 release 才会走到这一步)",
        )
    }
}

// 挂到 release 的编译上:Kotlin 与 Java 的编译都把这个文件当源文件,两个都要声明依赖 ——
// 否则 Gradle 的校验会直接判失败(「uses this output ... without declaring a dependency」)。
// 只挂 release —— profile/debug 本来就该带 dev 依赖,不动。
tasks.matching {
    it.name == "compileReleaseJavaWithJavac" || it.name == "compileReleaseKotlin"
}.configureEach {
    dependsOn(stripDevPluginRegistrations)
}
