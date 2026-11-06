plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.player"
}

dependencies {
    implementation(project(":core:player"))
    implementation(project(":core:platform"))
    testImplementation(libs.turbine)
}

