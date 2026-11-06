plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.downloads"
}

dependencies {
    implementation(project(":core:platform"))
}

