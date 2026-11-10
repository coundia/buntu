plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.buntu.android.compose)
    alias(libs.plugins.buntu.android.hilt)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.pcoundia.buntu"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.pcoundia.buntu"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
    }

    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            isUniversalApk = true
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
            isDebuggable = false
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":core:engine"))
    implementation(project(":core:domain"))
    implementation(project(":core:data"))
    implementation(project(":core:player"))
    implementation(project(":core:designsystem"))
    implementation(project(":core:platform"))

    implementation(project(":feature:onboarding"))
    implementation(project(":feature:sources"))
    implementation(project(":feature:live"))
    implementation(project(":feature:guide"))
    implementation(project(":feature:movies"))
    implementation(project(":feature:series"))
    implementation(project(":feature:details"))
    implementation(project(":feature:player"))
    implementation(project(":feature:search"))
    implementation(project(":feature:recommendations"))
    implementation(project(":feature:downloads"))
    implementation(project(":feature:profiles"))
    implementation(project(":feature:settings"))
    implementation(project(":feature:devices"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.window)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.hilt.work)
    ksp(libs.androidx.hilt.compiler)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.androidx.profileinstaller)
    implementation(libs.kotlinx.collections.immutable)

    testImplementation(libs.junit)
}

