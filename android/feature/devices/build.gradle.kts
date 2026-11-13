plugins {
    alias(libs.plugins.buntu.android.feature)
}

android {
    namespace = "com.pcoundia.buntu.feature.devices"
}


dependencies {
    // QR code scanner and encoder (household invite), device capabilities (TV or phone).
    implementation(project(":core:platform"))
}
