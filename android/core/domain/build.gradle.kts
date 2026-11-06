plugins {
    alias(libs.plugins.buntu.kotlin.jvm)
}

dependencies {
    api(libs.androidx.paging.common)
    implementation(libs.hilt.core)
}

