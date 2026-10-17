// SPDX-License-Identifier: Apache-2.0
import org.gradle.api.artifacts.ExternalModuleDependency

// Flutter 3.47.7's integration_test declares these three api dependencies with
// dynamic versions. Pin the declarations before they participate in a graph;
// selecting an exact version with a separate constraint would leave the
// original dynamic requested selector intact. The values preserve locally
// observed build inputs; this does not constitute an APK/license attestation.
val exVpnIntegrationTestPins = mapOf(
    "androidx.test:runner" to ("1.2+" to "1.3.0"),
    "androidx.test:rules" to ("1.2+" to "1.2.0"),
    "androidx.test.espresso:espresso-core" to ("3.3+" to "3.3.0"),
)

findProject(":integration_test")?.configurations?.configureEach configuration@{
    if (name != "api") return@configuration
    dependencies.withType(ExternalModuleDependency::class.java).configureEach dependency@{
        val pin = exVpnIntegrationTestPins["$group:$name"] ?: return@dependency
        val declared = versionConstraint
        check(!isChanging && declared.requiredVersion == pin.first &&
            declared.strictVersion.isEmpty() && declared.preferredVersion.isEmpty() &&
            declared.rejectedVersions.isEmpty() && declared.branch == null) {
            "exvpn_integration_test_dependency_selector_changed"
        }
        // Gradle 9.3.1 strictly() replaces both requiredVersion and strictVersion.
        version { strictly(pin.second) }
        because("ExVPN pins the reviewed integration_test runtime dependency inputs")
    }
}

// A direct app strict declaration can otherwise override a transitive
// project's strict declaration. Root constraints make such conflicts fail;
// constraints do not introduce modules absent from the application's graph.
findProject(":app")?.let { appProject ->
    appProject.configurations.configureEach configuration@{
        if (name != "implementation") return@configuration
        exVpnIntegrationTestPins.forEach { (module, pin) ->
            appProject.dependencies.constraints.add("implementation", module) {
                version { strictly(pin.second) }
                because("ExVPN requires the same reviewed integration_test runtime inputs at the app boundary")
            }
        }
    }
}
