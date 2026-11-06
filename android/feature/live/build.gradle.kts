plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.live"
}

dependencies {
    implementation(project(":core:player"))
    implementation(libs.androidx.paging.runtime)
    implementation(libs.androidx.paging.compose)
    testImplementation(libs.turbine)
}

