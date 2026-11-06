plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.details"
}

dependencies {
    implementation(project(":core:platform"))
    implementation(libs.coil.compose)
}

