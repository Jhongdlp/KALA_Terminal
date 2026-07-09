allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Some plugins (e.g. file_picker) hardcode an older compileSdk than the
    // transitive AndroidX libraries they pull in now require (androidx.lifecycle
    // needs API 36). Force every Android plugin subproject to compile against 36
    // so the AAR-metadata check passes. compileSdk only affects compile-time
    // APIs; runtime behavior stays governed by each module's targetSdk.
    // Registered here (before the evaluationDependsOn block below forces
    // evaluation) so the callback lands while the subproject is still unevaluated.
    afterEvaluate {
        val androidExtension = extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            androidExtension.compileSdkVersion(36)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
