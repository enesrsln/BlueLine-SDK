import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

tasks.test {
    // Shared with the other SDKs: ../testvectors/
    systemProperty(
        "blueline.testvectors",
        rootProject.file("../testvectors/blueline_protocol_v1.json").absolutePath,
    )
    systemProperty(
        "blueline.processingvectors",
        rootProject.file("../testvectors/blueline_processing_v1.json").absolutePath,
    )
}
