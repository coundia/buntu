plugins {
    alias(libs.plugins.buntu.android.library)
    alias(libs.plugins.buntu.android.hilt)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.pcoundia.buntu.core.data"

    testOptions {
        unitTests.all {
            val hostJna = project(":core:engine").layout.buildDirectory.dir("host-jna").get().asFile.absolutePath
            val cargoRelease = rootProject.projectDir.parentFile.resolve("target/release").absolutePath
            it.systemProperty(
                "jna.library.path",
                listOf(hostJna, cargoRelease).joinToString(File.pathSeparator),
            )
        }
    }
}

dependencies {
    implementation(project(":core:domain"))
    implementation(project(":core:engine"))

    implementation(libs.androidx.paging.runtime)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.jna)
    testImplementation(libs.androidx.paging.common)
}
