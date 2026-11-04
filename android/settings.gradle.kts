pluginManagement {
    repositories {
        google()
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

rootProject.name = "BlueLineSDK-Android"

// Pure JVM: protocol constants, packet parsers, session/gap tracking. No Android dependency.
include(":blueline-core")
// Android BLE layer: scanner, device, permissions. Skipped with -Pblueline.coreOnly=true
// so the core tests run on a machine with only a JDK (no Android SDK).
if (providers.gradleProperty("blueline.coreOnly").orNull != "true") {
    include(":blueline-android")
}
