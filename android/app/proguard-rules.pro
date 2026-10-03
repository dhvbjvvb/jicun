# R8 规则。开了 minify 之后,这里每加一条 keep 都在往回长包,所以只留真需要的,
# 并且写清为什么。
#
# 现状:app 自己的类和各插件的类都是从代码里**直接引用**的(GeneratedPluginRegistrant
# 是直接 new,不是按名字反射),清单里声明的组件 AGP 会自动保;插件自带的 consumer
# 规则(AAR 里的 proguard.txt)也已经被合并进来了。所以这里不需要为业务类写 keep。
# 真要加,先跑一次 release 包,确认是**具体哪个类**被削掉了,再把那条 keep 加上。

# 只服务于「release 崩溃栈还能读」:留着源文件名与行号表,R8 混淆之后的栈还能靠
# mapping 文件还原到具体某一行。代价是包里多几十 KB。
-keepattributes SourceFile,LineNumberTable

# 行号表留着,但不必暴露真实源文件名(名字统一成 SourceFile)。
-renamesourcefileattribute SourceFile
