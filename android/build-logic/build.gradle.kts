plugins {
    `kotlin-dsl`
}

group = "com.pcoundia.buntu.buildlogic"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
    compileOnly(libs.compose.gradlePlugin)
    compileOnly(libs.ksp.gradlePlugin)
    compileOnly(libs.hilt.gradlePlugin)
}

gradlePlugin {
    plugins {
        register("androidLibrary") {
            id = "buntu.android.library"
            implementationClass = "com.pcoundia.buntu.buildlogic.BuntuAndroidLibraryPlugin"
        }
        register("androidCompose") {
            id = "buntu.android.compose"
            implementationClass = "com.pcoundia.buntu.buildlogic.BuntuAndroidComposePlugin"
        }
        register("androidHilt") {
            id = "buntu.android.hilt"
            implementationClass = "com.pcoundia.buntu.buildlogic.BuntuAndroidHiltPlugin"
        }
        register("androidFeature") {
            id = "buntu.android.feature"
            implementationClass = "com.pcoundia.buntu.buildlogic.BuntuAndroidFeaturePlugin"
        }
        register("kotlinJvm") {
            id = "buntu.kotlin.jvm"
            implementationClass = "com.pcoundia.buntu.buildlogic.BuntuKotlinJvmPlugin"
        }
    }
}

