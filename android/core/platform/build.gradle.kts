plugins {
    alias(libs.plugins.buntu.android.library)
    alias(libs.plugins.buntu.android.hilt)
}

android {
    namespace = "com.pcoundia.buntu.core.platform"
}

dependencies {
    implementation(project(":core:domain"))

    api(libs.androidx.work.runtime)
    implementation(libs.androidx.hilt.work)
    ksp(libs.androidx.hilt.compiler)

    implementation(libs.androidx.tv.provider)
    implementation(libs.androidx.media3.session)
    implementation(libs.zxing.core)
    api(libs.androidx.metrics.performance)
    api(libs.androidx.window)
}

