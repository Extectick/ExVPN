# Local Windows toolchain

Run from the repository root in PowerShell 7:

```powershell
./scripts/bootstrap/bootstrap.ps1
. ./scripts/bootstrap/enter-environment.ps1
go version
flutter --version
flutter doctor -v
```

`toolchain.lock.json` pins official archive URLs, SHA-256 checksums, and exact versions. The bootstrap never reads a moving `latest` release when installing. It verifies checksums before extraction, stages new SDKs inside ignored `.tools/`, and refuses to overwrite another installed version. A failed download/extraction leaves the existing SDK intact. It does not install packages globally, edit the user or machine PATH, accept Android licenses, or configure a VPN.

The environment helper only changes the current PowerShell process. It uses the existing Android SDK and Android Studio's bundled JBR when available; alternate paths can be supplied as parameters. It keeps Go, pub, and Gradle caches under `.tools/cache/` and disables automatic Go toolchain switching.

Go 1.27.2 satisfies the `go 1.27` declaration in the Xray v26.10.10 module and libXray's Go 1.27.1 declaration. Flutter 3.47.7 includes Dart 3.13.5. Toolchain pins were read from the official release metadata on 2026-10-16.

For upgrades, review upstream release metadata and compatibility first, update the lock deliberately, and move the previous SDK aside explicitly. No bootstrap command recursively deletes existing SDKs.

## Verified host state, 2026-10-16

`go version`, `flutter --version --machine`, `flutter doctor -v`, PowerShell syntax validation, and a repeated bootstrap completed. Flutter recognizes Visual Studio Community 2026 and automatically chooses Android Studio's JBR 21.0.6. Its network resource checks pass.

Android SDK36/build-tools36.0.0 and NDK27.1.12297006 (own JNI) plus
NDK28.2.13676358 (Flutter plugins) are installed. Existing local SDK licenses
covered the packages; bootstrap does not automatically accept new terms.

Following explicit user authorization, the existing Visual Studio Community2026
installation now includes Desktop C++, MSVC, CMake, Windows SDK26100 and ATL.
The official installer completed with exit0 and no reboot requirement. Both
Android debug APK and full Windows Flutter debug builds now pass. The helper
script for another machine is `install-windows-build-tools.ps1`; it uses the
official installer and ordinary Windows elevation.

API36 x86_64 emulator QA is running separately. No physical Android device is
attached. Toolchain/build success does not establish protection or release
readiness; see native module READMEs and `docs/CHECKLIST.md` for runtime evidence.
The process environment helper preserves explicitly configured ANDROID_HOME and
JAVA_HOME, which permits the same scripts on disposable CI runners.
