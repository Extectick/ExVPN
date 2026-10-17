# Android: проверенные notices в APK

Обычная сборка включает полный доступный notice bundle и соответствующий ZIP
исходников Xray в `assets/exvpn_notices/`:

```powershell
pwsh -NoProfile -File scripts/bootstrap/build-android-debug.ps1
# CI: тот же snapshot остаётся активным для JVM-тестов Gradle.
pwsh -NoProfile -File scripts/bootstrap/build-android-debug.ps1 -RunUnitTests
```

Wrapper выполняет `flutter pub get --offline --enforce-lockfile`, затем
`prepare-android-notices.ps1` создаёт новый каталог
`artifacts/android-package-inputs/inputs-<id>/`. В него копируются обе текущие
JNI ABI; collector читает именно эти копии, создаёт
`assets/exvpn_notices`, после проверки записывается `seal.json`.
Старые каталоги не удаляются и не переиспользуются автоматически.

Подготовка notices работает с существующими Go/pub caches, без скачивания:
`GOPROXY=off`/`GOSUMDB=off` действуют только на время collection, затем прежние
значения восстанавливаются. Проверки pinned/embedded checksums сохраняются;
отсутствующий cache entry явно прерывает подготовку. Это не bootstrap SDK.
Уже существующий Gradle resolution для закреплённых Maven/JUnit зависимостей
не изменён; новый Maven/SDK dependency не добавлен.

Wrapper задаёт `EXVPN_ANDROID_PACKAGE_INPUTS` только на время Flutter/Gradle
build и опциональных JVM-тестов, затем восстанавливает переменную. Gradle берёт
JNI и Android assets из этого snapshot. `preBuild` **каждый раз** запускает
`verify-android-notices.ps1`; после сборки wrapper повторяет проверку.
Отсутствующая переменная, missing/stale seal, иной app build, изменившийся
pubspec.lock или native library, лишний файл/повреждённый notice прерывают
packaging. Незаметного перехода на глобальные JNI или старые notices нет.

Verifier пересчитывает полный file set и SHA-256, сравнивает snapshot с текущими
native inputs и исходными pins, заново читает Go build info обеих ABI,
сверяет native/app/Dart binding и Go `h1` Xray source ZIP. Самого наличия seal
или совпадения указанного в нём self-hash недостаточно. Snapshot предназначен
для одного владельца build-процесса; seal не является цифровой подписью или
доказательством происхождения всей сборки.

JNI уже собирается с `-s -w`. Для `libexvpn.so` отключён повторный AGP strip через
[`keepDebugSymbols`](https://developer.android.com/reference/tools/gradle-api/9.1/com/android/build/api/dsl/JniLibsPackaging#keepDebugSymbols()).
Он менял байты библиотек после создания inventory. Wrapper дополнительно читает
**готовый APK** и сравнивает обе JNI и каждый notice/source asset со snapshot:
изменённый/пропущенный файл, лишняя ABI или посторонний notice дают отказ.
Для обеих разрешённых ABI (`arm64-v8a`, `x86_64`) обязательны ExVPN core и Flutter
engine. Любая `.so` другой ABI, даже из зависимости, отклоняется. Поддерживается
общий APK с обеими ABI; single-ABI запрос отклоняется до начала сборки. Flutter
default ABI filtering отключён, чтобы не добавлять неподдерживаемый armv7.
38 fixtures покрывают подготовку и финальный ZIP; полный release audit остаётся
отдельным, поскольку debug APK заведомо не проходит gate подписи.

Отдельная подготовка/диагностика не вызывает Gradle и не меняет `apps/exvpn/build`:

```powershell
$inputs = ./scripts/release/prepare-android-notices.ps1
./scripts/release/verify-android-notices.ps1 -InputDirectory $inputs.InputDirectory
pwsh -NoProfile -File scripts/release/test-android-notices.ps1
```

При прямом вызове Gradle нужно явно передать свежий snapshot через указанную
переменную. Предпочтителен wrapper; для CI применять `-RunUnitTests`, а не
отдельный JVM run после восстановления environment.

После упаковки нужен независимый `audit-artifact.ps1` по **полученному APK**:
подготовленный snapshot сам по себе не доказывает включение файлов в пакет.
Полнота Gradle/Maven и Flutter runtime inventory, окончательная проверка
лицензионных обязательств и release signing остаются отдельными E7-002 gates.
Debug APK не становится подписанным beta/release из-за наличия notices.
