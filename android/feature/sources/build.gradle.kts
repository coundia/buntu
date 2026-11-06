plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.sources"
}

dependencies {
    implementation(project(":core:platform"))
}

