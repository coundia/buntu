plugins {
    alias(libs.plugins.buntu.android.library)
    alias(libs.plugins.buntu.android.hilt)
}

android {
    namespace = "com.pcoundia.buntu.core.engine"

    testOptions {
        unitTests.all {
            val hostJna = layout.buildDirectory.dir("host-jna").get().asFile.absolutePath
            val cargoRelease = rootProject.projectDir.parentFile.resolve("target/release").absolutePath
            it.systemProperty(
                "jna.library.path",
                listOf(hostJna, cargoRelease).joinToString(File.pathSeparator),
            )
        }
    }
}

val buildRustCore by tasks.registering(Exec::class) {
    description = "Compiles Rust cnd-core for Android ABIs and generates UniFFI Kotlin bindings."
    group = "rust"
    workingDir = rootProject.projectDir.parentFile
    commandLine("bash", "scripts/build-android.sh")
}

dependencies {
    api(libs.jna) {
        artifact {
            type = "aar"
        }
    }
    testImplementation(libs.jna)
}
