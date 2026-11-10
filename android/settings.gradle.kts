pluginManagement {
    includeBuild("build-logic")
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "BuntuAndroid"

include(":app")
include(":core:engine")
include(":core:domain")
include(":core:data")
include(":core:player")
include(":core:designsystem")
include(":core:platform")

include(":feature:onboarding")
include(":feature:sources")
include(":feature:live")
include(":feature:guide")
include(":feature:movies")
include(":feature:series")
include(":feature:details")
include(":feature:player")
include(":feature:search")
include(":feature:recommendations")
include(":feature:downloads")
include(":feature:profiles")
include(":feature:settings")
include(":feature:devices")

include(":benchmark")

