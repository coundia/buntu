plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.settings"
}

dependencies {
    implementation(project(":core:platform"))
}

