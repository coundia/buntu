package com.pcoundia.buntu.buildlogic

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType

/**
 * PRD-37 § 2.1 & § 12:
 * Every `:feature:*` module has ONE screen/journey responsibility, exposes immutable `UiState` via
 * a shared Phone/TV `ViewModel`, and depends ONLY on `:core:domain` & `:core:designsystem`
 * (never `:core:engine` and never another `:feature:*`).
 */
class BuntuAndroidFeaturePlugin : Plugin<Project> {
    override fun apply(target: Project) {
        with(target) {
            pluginManager.apply("buntu.android.library")
            pluginManager.apply("buntu.android.compose")
            pluginManager.apply("buntu.android.hilt")

            val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
            dependencies {
                add("implementation", project(":core:domain"))
                add("implementation", project(":core:designsystem"))

                add("implementation", libs.findLibrary("androidx.activity.compose").get())
                add("implementation", libs.findLibrary("androidx.lifecycle.runtime.compose").get())
                add("implementation", libs.findLibrary("androidx.lifecycle.viewmodel.ktx").get())
                add("implementation", libs.findLibrary("androidx.lifecycle.viewmodel.compose").get())
                add("implementation", libs.findLibrary("androidx.hilt.navigation.compose").get())
                add("implementation", libs.findLibrary("androidx.tv.material").get())
            }
        }
    }
}
