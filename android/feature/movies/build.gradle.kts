plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.movies"
}

dependencies {
    implementation(libs.androidx.paging.runtime)
    implementation(libs.androidx.paging.compose)
}

