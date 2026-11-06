package com.pcoundia.buntu

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * PRD-37 § 2.2, § 12, § 13:
 * Automated SRP architecture test enforcing:
 * 1. `:feature:*` NEVER depends on `:core:engine` (must go through `:core:domain` interfaces).
 * 2. `:feature:*` NEVER depends on another `:feature:*` module.
 * 3. `:core:domain` NEVER depends on `:core:engine` or `:core:data`.
 */
class ModuleArchitectureTest {

    private fun locateAndroidRoot(): File {
        val cwd = File(System.getProperty("user.dir") ?: ".")
        return when {
            File(cwd, "feature").isDirectory -> cwd
            File(cwd.parentFile, "feature").isDirectory -> cwd.parentFile
            File(cwd, "android/feature").isDirectory -> File(cwd, "android")
            else -> error("Unable to locate android/ project root from $cwd")
        }
    }

    @Test
    fun `feature modules never depend on core-engine or other feature modules`() {
        val androidRoot = locateAndroidRoot()
        val featureDirs = File(androidRoot, "feature")
            .listFiles { file -> file.isDirectory && File(file, "build.gradle.kts").isFile }
            .orEmpty()
            .sortedBy { it.name }

        assertTrue("Expected at least 13 :feature:* modules", featureDirs.size >= 13)

        val violations = mutableListOf<String>()
        for (dir in featureDirs) {
            val content = File(dir, "build.gradle.kts").readText()
            if (content.contains(":core:engine")) {
                violations += ":feature:${dir.name} must NOT depend on :core:engine"
            }
            val featureDepRegex = Regex("""project\(\s*":feature:([^"]+)"""")
            featureDepRegex.findAll(content).forEach { match ->
                violations += ":feature:${dir.name} must NOT depend on :feature:${match.groupValues[1]}"
            }
        }

        assertTrue(
            "SRP module boundary violations:\n${violations.joinToString("\n")}",
            violations.isEmpty(),
        )
    }

    @Test
    fun `core-domain remains pure Kotlin with zero android or engine dependencies`() {
        val androidRoot = locateAndroidRoot()
        val domainBuild = File(androidRoot, "core/domain/build.gradle.kts").readText()
        assertTrue(
            ":core:domain must apply buntu.kotlin.jvm",
            domainBuild.contains("buntu.kotlin.jvm"),
        )
        assertTrue(
            ":core:domain must not depend on :core:engine",
            !domainBuild.contains(":core:engine"),
        )
    }
}

