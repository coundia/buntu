plugins {
    alias(libs.plugins.buntu.android.library)
    alias(libs.plugins.buntu.android.compose)
}

android {
    namespace = "com.pcoundia.buntu.core.designsystem"
}

dependencies {
    api(libs.androidx.compose.material3.windowSizeClass)
    api(libs.androidx.compose.material.icons)
    api(libs.androidx.tv.material)
    api(libs.androidx.tv.foundation)
    implementation(libs.coil.compose)
}

