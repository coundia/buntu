plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.player"
}

dependencies {
    implementation(project(":core:player"))
    implementation(project(":core:platform"))
    // Thumbnails of the "À suivre" list under the video in portrait.
    implementation(libs.coil.compose)
    testImplementation(libs.turbine)
}

