plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.onboarding"
}

dependencies {
    implementation(project(":core:platform"))
}

