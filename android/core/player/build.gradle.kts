plugins {
    alias(libs.plugins.buntu.android.library)
    alias(libs.plugins.buntu.android.compose)
    alias(libs.plugins.buntu.android.hilt)
}

android {
    namespace = "com.pcoundia.buntu.core.player"
}

dependencies {
    implementation(project(":core:domain"))
    implementation(project(":core:platform"))

    api(libs.androidx.media3.common)
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.exoplayer.hls)
    implementation(libs.androidx.media3.exoplayer.dash)
    implementation(libs.androidx.media3.datasource)
    implementation(libs.androidx.media3.ui)
    api(libs.androidx.media3.session)
}

