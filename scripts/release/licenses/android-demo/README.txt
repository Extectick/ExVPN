ExVPN 0.1.0+18 demo: Android Maven notice supplements

This ZIP accompanies the exact APK identified in apk-binding.json. Its
android-maven-inputs.json records the original AAR/JAR and POM inputs captured
from releaseRuntimeClasspath in the same assembleRelease invocation. These are
build inputs, not the final set of classes retained by R8.

license-inventory.json maps exact coordinates, binary/POM hashes, and source
archive provenance to full texts in texts/. The text collection is deliberately
overinclusive: it retains all 65 non-Flutter components of the existing pinned
input inventory, including development components which a release can omit.
A license's inclusion does not apply it to unrelated code. The original
copyright/license comments are preserved verbatim; Apache 2.0 is supplied in
full, together with embedded notices, EPL, BSD and MIT texts where applicable.
The checker annotations use the MIT grant identified in their upstream license;
the complete upstream document is retained for context. Tink's shaded Protocol
Buffers 33.6 BSD license is explicitly included using Tink 1.23.0's exact source
dependency declaration. Source archive URLs and hashes permit retrieval of the
corresponding published source. Source archives themselves are not in this ZIP.

Flutter engine and ExVPN/Dart/Go/plugin notices, including the modified Xray
source archive, are distributed in the APK's separately verified
assets/exvpn_notices bundle. Its audit is a separate required publication check.
This supplement does not close stable release license/SBOM acceptance, assert
a complete final link graph, or change the stable audit's releaseReady=false.

The collector performs no downloads or Gradle invocation. Unknown coordinates,
different POM/artifact bytes, missing license text, and tampered inputs fail.
The Gradle observer is opt-in via EXVPN_DEMO_MAVEN_GRAPH; its local file paths
are stripped from this public archive and report.
