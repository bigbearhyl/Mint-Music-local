allprojects {
    repositories {
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        maven { url = uri("https://cache-redirector.jetbrains.com/dl.google.com/dl/android/maven2/") }
        maven { url = uri("https://cache-redirector.jetbrains.com/repo1.maven.org/maven2/") }
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    if (project.name == "app") {
        val newSubprojectBuildDir = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

// 兼容老旧第三方插件（如 on_audio_query_android 1.1.0）：它们仍用 AndroidManifest 的
// `package` 属性而没有在 build.gradle 里声明 namespace，AGP 8 会直接报错。
// 这里在 AGP 插件应用后立刻从清单里补 namespace（必须早于 AGP 自己的 afterEvaluate
// 建变体）。用反射是因为根工程脚本的 classpath 里没有 AGP 类（AGP 只在
// settings.gradle 的 plugins 块里声明、apply false）。
fun fillNamespaceFromManifest(project: Project) {
    val androidExt = project.extensions.findByName("android") ?: return
    val extClass = androidExt.javaClass
    val getNamespace = extClass.methods.firstOrNull {
        it.name == "getNamespace" && it.parameterCount == 0
    } ?: return
    if (getNamespace.invoke(androidExt) != null) return
    val setNamespace = extClass.methods.firstOrNull {
        it.name == "setNamespace" && it.parameterCount == 1
    } ?: return
    val manifestFile = project.file("src/main/AndroidManifest.xml")
    if (!manifestFile.exists()) return
    val match = Regex("""package\s*=\s*"([^"]+)"""").find(manifestFile.readText()) ?: return
    setNamespace.invoke(androidExt, match.groupValues[1])
}

subprojects {
    pluginManager.withPlugin("com.android.library") { fillNamespaceFromManifest(project) }
    pluginManager.withPlugin("com.android.application") { fillNamespaceFromManifest(project) }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
