# Зависимости и лицензии

Дата первичной проверки: **2026-10-16**. Это реестр решений и обязательств; строка «планируется» не означает, что компонент уже установлен или включён в бинарник.

## Основные компоненты

Независимая доставка 0.1.10+31 сохраняет прежние pinned Flutter/engine/updater,
`cryptography`/`crypto` и Python cryptography 46.0.5. Новых зависимостей нет.
Собственные адаптер, каталог и build scripts — Apache-2.0. Открытый updater
и diff tool используются с прежними лицензиями/исходниками и полным набором
notices; самостоятельная доставка не отменяет обязательств этих компонентов.

Кандидат 0.1.9+30, 2026-10-20: SOCKS/HTTP и userspace WireGuard используют
уже закреплённые пакеты Xray, WireGuard Go и gVisor. Новых Go/Dart dependencies
и обновления ядра нет. WireGuard Go `v0.0.0-20250521234502-f333402bd9cb` и
gVisor `89a5d21be8f0` присутствовали в notice inventory базы29; для новых
бинарников полный комплект notices/SBOM формируется повторно по их bytes.
Kernel WireGuard, OpenVPN и TUIC в поставку не добавляются.

Android APK updater 0.1.5, 2026-10-19: Dart `cryptography` **2.9.0**
(Apache-2.0) становится прямой runtime-зависимостью приложения для проверки
Ed25519. Версия уже закреплена и используется в runtime через `exvpn_updates`;
новой версии/дистрибутива не добавляется. APK identity/signer и системная
установка используют Android PackageManager и AndroidX FileProvider из уже
имеющегося AndroidX Core. Python signer обоих feed использует прежние
закреплённые CPython/cryptography wheels, с разными domain/platform.

Экспорт launcher-иконок 0.1.4: локальный dev-only скрипт использует Pillow
**12.2.0**, лицензия **MIT-CMU** по metadata установленного дистрибутива. В пакет
приложения библиотека не включается; коммитятся только PNG/XML, полученные из
существующей утверждённой маски белки. Для воспроизведения экспорта использовать
эту же версию (`python -m pip install Pillow==12.2.0`). Новых runtime-зависимостей
Android/Flutter/Go не добавлено.

Отдельные инструменты публикации Windows feed, 2026-10-18: CPython **3.13.16**
(PSF), `cryptography` **46.0.5** (Apache-2.0 OR BSD-3-Clause), `cffi` **2.0.0**
(MIT) и `pycparser` **3.0** (BSD-3-Clause). Только CI signing job, в приложение
не включаются. Все три Windows x64 wheels закреплены SHA-256 в
`scripts/release/windows-feed-requirements.txt`, установка с `--require-hashes
--no-deps`; setup-python также закреплён commit. WinRT PNG encoder и Android
PackageManager/Bitmap используют системные API, новых runtime-зависимостей
для иконок нет.

| Компонент | Версия / фиксация | Лицензия | Состояние и проверка |
|---|---|---|---|
| Windows WinINET / Crypt32 | Системные API Windows 10/11; SDK 10.0.26100.0 текущего закреплённого toolchain | Компоненты ОС Microsoft; DLL не переупаковываются | Собственный adapter +19 управляет пользовательским системным proxy и шифрует backup через DPAPI. Новых Dart/Go зависимостей нет. [Контракт](SYSTEM_PROXY.md) |
| Собственный код ExVPN | Версия приложения задаётся в manifest проекта | Apache-2.0 | Полный текст находится в корневом `LICENSE`; собственное уведомление — `NOTICE` |
| Собственный Windows app updater | `native/appupdater`, Go **1.27.2**, только стандартная библиотека | Apache-2.0; Go BSD-3-Clause | Отдельный helper; Win32 Shell32/Advapi32/Kernel32/Ole32 поставляются ОС. Installer/notices/audit связывают точный хеш helper и Go runtime license. [Контракт](WINDOWS_APP_UPDATES.md) |
| Python `cryptography` (только offline release tool) | **46.0.5**, проверено в локальном metadata | Apache-2.0 OR BSD-3-Clause | Используется `sign-windows-update.py`, в приложение/установщик не включается; приватный seed только `.private/` |
| Windows notification area API | Системные Shell32/User32/Common-Controls v6 в поддерживаемых Windows 10/11; SDK закреплён локальным toolchain | Компоненты ОС Microsoft; не переупаковываются | Собственный tray adapter в +14; manifest запрашивает Common-Controls v6 для LoadIconMetric. Нового Flutter plugin/стороннего исходника нет. [Контракт и API](WINDOWS_TRAY.md) |
| Flutter | **3.47.7**, commit `abaf9c523780a608bd46686fd5e53740a07077f8` | BSD-3-Clause; отдельные зависимости engine имеют свои лицензии | Версия/SHA-256 архива в `scripts/bootstrap/toolchain.lock.json`; [официальный LICENSE](https://github.com/flutter/flutter/blob/master/LICENSE) проверен; полный состав проверять по фактическому SDK |
| Dart SDK | **3.13.5**, поставляется с закреплённым Flutter | BSD-3-Clause; зависимости имеют отдельные лицензии | Использован для `dart analyze`/113 тестов domain-пакета; [официальный LICENSE](https://github.com/dart-lang/sdk/blob/main/LICENSE) |
| Xray-core | **26.10.10-exvpn.5**, собственный transport/TUN lifecycle patch поверх commit `701af60772cda123492f86e383e1fdba066614a9`; Go module `v1.260327.1-exvpn.5` | MPL-2.0, включая изменённые covered files | [Patch, pin и реконструкция](../native/patches/README.md); исходный LICENSE сохранён; binary/source `h1` проверяется при комплектации, системный E1 отдельно |
| libXray | Исследовательский commit `4e1f7843e6cddb750ac7abc23ef36800820a8098` | MIT | Исследовательский pin записан в `native/core/config.go`; текущие Android/Windows используют собственный Go-адаптер прямо к Xray. libXray не входит в runtime graph и не должен выдаваться за упакованный компонент; [официальный LICENSE](https://github.com/XTLS/libXray/blob/main/LICENSE) |
| Go | **1.27.2**; native module требует минимум 1.27.1 | BSD-3-Clause; сторонние модули отдельно | SDK/SHA-256 в `scripts/bootstrap/toolchain.lock.json`; [официальный LICENSE](https://go.dev/LICENSE); зависимости в `native/core/go.sum` |
| Microsoft `go-winio` | **0.6.2**, `native/windows/go.mod` / `go.sum` | MIT | Локальный LICENSE закреплённого модуля проверен; Windows named-pipe IPC. Версия и Go checksum сверяются с build info служебного EXE при сборе notices |
| Go offline root bundle | **`golang.org/x/crypto/x509roots/fallback v0.0.0-20261005185213-c3db4df58582`**, уже закреплённая transitive dependency Xray | BSD-3-Clause (код модуля); происхождение корней — NSS, указано upstream в `bundle/roots.go` | Локальные LICENSE и исходники проверены. Windows bootstrap и HTTPS healthcheck копируют non-system pool Xray с ограничениями корней; OS trust/AIA fallback не используется. Версия обновляется только с проверенным native пакетом, не через подписку. Полный LICENSE включается сборщиком notices |
| WireGuard Go / Windows helpers / Wintun Go binding | **wireguard 20250521-f333402bd9cb**, **windows 1.1.1**, **wintun 20230126-0fa3db229ce2** | MIT; полные LICENSE/COPYING модулей сохраняются отдельно | Закреплены в Go graph; LICENSE/COPYING проверены локально. Binding не заменяет отдельную лицензию распространяемой DLL |
| Wintun prebuilt DLL x64 | **0.14.1**, архив и DLL SHA-256 в `scripts/windows/wintun.lock.json` | **Wintun Prebuilt Binaries License** | Полный текст из официального архива сохранён вместе с DLL; не маркировать бинарник MIT/Apache. Комплект notices включает этот текст отдельно от Go binding |
| Dart `crypto` | **3.0.7**, `packages/exvpn_domain/pubspec.lock` | BSD-3-Clause | Используется для стабильных SHA-256 ID профилей; LICENSE установленного пакета проверен локально |
| Dart `cryptography` | **2.9.0**, точный pin `packages/exvpn_updates/pubspec.yaml` / app lock | Apache-2.0 | Ed25519 проверка точных байтов manifest OTA; локальные LICENSE/исходники версии проверены, копия в `packages/exvpn_updates/third_party`. SHA-256 использует тот же `crypto 3.0.7`; native app интеграция реализована, production доставка по умолчанию отключена |
| Dart `pointycastle` | **4.0.0**, dev dependency `packages/exvpn_updates/pubspec.lock` | MIT | Только генерация RSA-сертификата в памяти для localhost HTTPS tests, не runtime приложения. LICENSE версии проверен и сохранён в `packages/exvpn_updates/third_party` |
| Dart `http` | **1.6.0**, `apps/exvpn/pubspec.lock` | BSD-3-Clause | HTTPS streaming/AbortableRequest; LICENSE установленного пакета проверен локально. 35 тестов bounded loader; сертификаты не обходятся |
| `file_selector` / `zxing2` | **1.1.0 / 0.2.4**, точные app pins | BSD-3-Clause | Системный выбор PNG/JPEG и локальное чтение QR. LICENSE установленных версий сохранены в `apps/exvpn/assets/licenses/FileSelector.txt` и `ZXing2.txt`; ограничения памяти/размера и подтверждение перед импортом описаны в `QR_IMPORT.md` |
| Dart `image` | **4.12.0**, только app dev dependency | MIT | Генерация синтетических QR fixtures для тестов. Изображения пользователя декодирует Flutter engine после проверки размеров; Dart image не используется runtime-импортом. LICENSE установленной версии проверен; release notices отдельно перечисляет dev dependencies |
| `flutter_secure_storage` | **11.2.0**, точный pin в app pubspec/lock | BSD-3-Clause | Проверены исходники и LICENSE установленной версии. Android Keystore RSA-OAEP/AES-GCM, resetOnError=false; Web отключён. Windows-плагин 4.2.2 остаётся transitive dependency, его неатомарный file backend не используется для подписок |
| Android NDK для зависимостей Flutter | **28.2.13676358** | Android NDK notices и лицензии отдельных компонентов | Требуется Android-сборкой JNI-зависимостей secure storage; установка использует уже принятые локальные SDK licenses. Не заменяет **27.1.12297006**, закреплённый для собственного Go/Xray JNI; оба NDK должны быть воспроизводимо доступны в CI |
| `win32` / `ffi` / `path_provider` | **6.4.0 / 2.2.0 / 2.1.6**, точные app pins | BSD-3-Clause | Локальные LICENSE проверены. Собственный Windows backend: current-user DPAPI + атомарная замена шифрованных файлов; реальный DPAPI round-trip/delete тест пройден. Детали в `SECURE_STORAGE.md` |
| Inter | Файл `apps/exvpn/assets/fonts/Inter.ttf`, SHA-256 `29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031` | SIL Open Font License 1.1 | Шрифт включён локально; полный OFL в `apps/exvpn/assets/fonts/OFL.txt`, copyright Inter Project Authors. Версия фиксируется самим файлом/хешем, не внешним CDN |
| Noto Sans SC | Полный variable TTF из Google Fonts, commit **`47d54ca1ebb14fd864695f1d39dc734f39017c33`**; SHA-256 **`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`**, 17 772 300 bytes | SIL Open Font License 1.1; Copyright 2014–2021 Adobe, Reserved Font Name “Source” | Неизменённый официальный шрифт подключён локально как fallback китайских глифов. Полный upstream OFL сохранён в `apps/exvpn/assets/fonts/NotoSansSC-OFL.txt`; URL и license hash — `assets/SOURCES.md`. Без CDN. Включение новых OFL в выпускные notices проверяется отдельно перед выпуском |
| Noto Sans Arabic | Полный variable TTF из того же Google Fonts commit **`47d54ca1ebb14fd864695f1d39dc734f39017c33`**; SHA-256 **`63111b5b2e074dd48cc67692e0a2726d86ee94c1c37fe8598257b7b4e87e869e`**, 844 676 bytes | SIL Open Font License 1.1; Copyright 2022 The Noto Project Authors | Неизменённый официальный шрифт подключён локально как fallback арабских глифов. Полный upstream OFL сохранён в `apps/exvpn/assets/fonts/NotoSansArabic-OFL.txt`; URL и license hash — `assets/SOURCES.md`. Без CDN. Включение новых OFL в выпускные notices проверяется отдельно перед выпуском |
| Material Icons | Font artifact закреплённого Flutter 3.47.7 | В поставленном SDK: CC BY 4.0 | Проверен локальный `artifacts/material_fonts/materialicons_license.txt` (Attribution 4.0 International); копия в `apps/exvpn/assets/licenses/MaterialIcons.txt`, атрибуция Google в `SOURCES.md`. Проверить включение уведомлений в итоговый пакет |
| Cupertino Icons | **1.0.9**, `apps/exvpn/pubspec.lock` | MIT | Пакет используется через Flutter `CupertinoIcons`; локальный LICENSE проверен, copyright 2016 Vladimir Kharlampidi. Копия — `apps/exvpn/assets/licenses/CupertinoIcons.txt`; проверить комплект выпуска |
| Флаги стран — flag-icons | **7.5.0**, resolved commit **`7aa5b2bdddd570ece62c812c0cb588ccdc099e2e`** | MIT, Copyright (c) 2013 Panayiotis Lipiridis | 257 официальных SVG 4:3 преобразованы в локальные PNG 160×120; новые runtime dependencies не добавлены. Полный LICENSE проверен и сохранён в `apps/exvpn/assets/licenses/FlagIcons.txt`, подключён к LicenseRegistry. Archive SHA-256 и способ повторения — `assets/SOURCES.md`; выпускные notices требуют отдельной проверки |
| Dart `test` / `lints` | **1.33.0 / 6.1.0**, domain lock-файл | BSD-3-Clause | Только dev dependencies; LICENSE установленных пакетов проверены локально |
| Flutter `integration_test`, `flutter_driver`, `fuchsia_remote_debug_protocol` | SDK **3.47.7**, тот же закреплённый commit Flutter | BSD-3-Clause | Dev dependencies для отдельного Windows Sandbox entry point; корневой LICENSE и заголовки исходников SDK проверены. Обычная Windows-сборка использует `lib/main.dart`; QA executable хранится отдельно |
| Транзитивные зависимости integration tests: `file`, `process`, `sync_http`, `webdriver` | **7.0.1 / 5.0.5 / 0.3.1 / 3.1.0**, `apps/exvpn/pubspec.lock` | BSD-3-Clause для первых трёх; Apache-2.0 для webdriver | LICENSE установленных версий проверены; входят в инвентаризацию dev dependencies, не являются VPN-ядром |
| Kotlin / Android Gradle plugin / Gradle | **2.4.0 / 9.1.0 / 9.3.1**, Android settings/wrapper | Apache-2.0 и лицензии транзитивных компонентов | Версии закреплены в исходниках, обе Android ABI собраны; runtime Maven notices проверяются отдельно от Go/Dart inventory |
| AndroidX Test runner / rules / Espresso core | **1.3.0 / 1.2.0 / 3.3.0**, `android/exvpn-integration-test-pins.gradle.kts` | Полные лицензии и транзитивный комплект подлежат отдельной проверке | Уже использовавшиеся входы `integration_test`: вместо трёх upstream dynamic selectors проект задаёт exact strict versions и app constraints. Неизвестное изменение upstream selector и несовместимый app pin вызывают отказ; constraints сами не добавляют зависимости. Это закрепление наблюдённых Maven inputs, не доказательство состава готового APK |
| JUnit / Hamcrest Core | **4.13.2 / 1.3**, Android `testImplementation`; Hamcrest закреплён в JUnit POM | EPL-1.0 / BSD-3-Clause | Только JVM-тесты ограниченного QR reader, в APK не входят. Полные лицензии upstream тегов сохранены в `apps/exvpn/android/licenses/` |
| Shorebird CLI | **1.6.129**, commit `9fe1370bdd1d2f117cc08c57ae416b794ed92440`; Flutter fork `5bef02a16146a0effc07da4acccaafe90a2739ce`, engine `4b936a0c03e13389ddfb1ac48823f187964975c2` | CLI: Apache-2.0 или MIT; Flutter/runtime components и облачный сервис имеют отдельные условия | Проверены LICENSE-APACHE/LICENSE-MIT и SHA-256 upstream lock/entry point; [pin](../scripts/bootstrap/shorebird.lock.json), [подготовка и ограничения](SHOREBIRD.md). CLI — отдельный dev SDK. В +16 подготовлен выбор Shorebird runtime с notices именно его framework/Dart/engine и проверкой фактических engine bytes; обычные пакеты +15 его не содержат. Полный linker SBOM и реальный signed patch остаются отдельными gates |
| Shorebird native updater | Commit **`70ff1e336798474e39586d3f5ac2ca386ef32d9e`**, выбранный закреплённым engine DEPS | Apache-2.0 или MIT; transitive crates и Rust runtime имеют отдельные обязательства | Обе полные собственные лицензии и Cargo.lock сохранены с SHA-256/size/Git blob в [pin](../scripts/release/shorebird-updater-notices.lock.json). Offline collector проверяет точный committed DEPS и допускает только его LF/CRLF checkout. [Код 110a39b](https://github.com/Extectick/ExVPN/commit/110a39b1d155411a2382b8d40fe16028c0ed99d3), Full 11/11 PASS за 160,59 с. Полнота crate/Rust notices и связь всего графа с бинарником не подтверждены; прежние +16 пакеты не переупакованы |
| `shorebird_code_push` | **2.0.7**, точный pin и SHA-256 archive `32df9946782c6ca95d7065c7f2156df74675e931b816d0dc391a3d8f8917930f` в app lock | MIT | LICENSE и исходники именно 2.0.7 проверены; LICENSE SHA-256 `1847e0e0698142ed4347c1441a9fa81c8fbddd44b1d8bbcd5e3647f991759d7f`. Existing `ffi`/`meta` pins не изменились. Полный текст входит в стандартный сбор notices из pub cache; новый engine этим пакетом не устанавливается. [Контракт](SHOREBIRD.md) |
| GitHub Actions cache | **6.1.0**, commit `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` | MIT, GitHub, Inc. and contributors, 2018 | [LICENSE закреплённого commit](https://github.com/actions/cache/blob/55cc8345863c7cc4c66a329aec7e433d2d1c52a9/LICENSE) и соответствие tag проверены. Только CI-инструмент, не runtime APK/EXE; точные кеши и сохраняемые проверки описаны в [CI.md](CI.md) |
| NSIS | **3.13**, официальный SourceForge ZIP и SHA-256 в `scripts/windows/nsis.lock.json`; проверяются все распакованные файлы SDK | zlib/libpng; bzip2; CPL-1.0 для LZMA с указанным upstream исключением | Лицензия закреплённого ZIP сохранена в `native/windows/licenses/NSIS-3.13.txt` и payload. Только встроенные System/nsDialogs/nsExec; внешних plugins нет. Offline compilation прошла, unsigned development installer; установка/upgrade/rollback на Windows-стенде ещё не приняты |
| Microsoft C++ runtime x64 | **14.51.36247.0**, release toolset **14.51.36231**, VS Community **18.7.11903.348**; 3 DLL и SHA-256 в `scripts/windows/msvc-runtime.lock.json` | Microsoft Software License Terms, отдельные proprietary Distributable Code; не Apache-2.0 | App-local `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`; Microsoft Authenticode/version/import scan проверены. Полные terms и исходный DOCX hash сохранены в `native/windows/licenses/`; [список разрешённых файлов](https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution). Внешний выпуск требует соблюдения distributor/end-user terms; чистый guest UI ещё не проверен. Системный CRT не устанавливается |

Плагины защищённого хранилища, QR, проверки подписей, системные TUN-библиотеки/драйверы и Flutter packages добавляются отдельными строками после выбора конкретных версий. Не считать их автоматически покрытыми Apache-2.0 ExVPN. Итоговый реестр и SBOM должны соответствовать lock-файлам и фактическому комплекту выпуска.

## Инструменты проверки

2026-10-18: локальный Windows-пакет 0.1.0+20 содержит **145 component notices**.
Collector дополнен Noto Sans SC/Arabic OFL и flag-icons MIT; новые лицензии
поставляются и как assets с LicenseRegistry. UI/engine/native binding пакета
проверен штатным build-installer, без повторного полного release-аудита.

Android release-аудит повторяет штатное удаление debug symbols из
`libflutter.so` инструментом `llvm-strip --strip-unneeded` из установленного
**NDK r28c / 28.2.13676358**. Windows `llvm-strip.exe` закреплён SHA-256
`2d411db64e0b45508775e9e8fd436fb6e0af814a9dfbf8aea8fc37ce436c435c`.
Это локальный build/audit tool, не дополнительная библиотека APK.
Проверен поставленный LLVM NOTICE (Apache-2.0 WITH LLVM-exception и notices
отдельных компонентов), SHA-256
`f96f763beb66a7ba7a667647fc64c0226ace875e590c831fdd9579ec1c1d91e1`;
полный NDK `NOTICE.toolchain` имеет SHA-256
`789714a9076571c580cf531bdcebec776a4d889c12c3c1108adafc6e4338710a`.
Проверка сравнивает результат преобразования с готовым APK, сохраняя факт
отличия от исходных SDK bytes; неизвестное несовпадение не принимается.

Для `go test -race` на Windows используется **w64devkit 2.10.1** (GCC 16.2.0),
официальный release asset и SHA-256 закреплены в
[`scripts/qa/race-compiler.lock.json`](../scripts/qa/race-compiler.lock.json).
Архив распаковывается в `.tools/`; это тестовый SDK, в APK/установщик и production
JNI/EXE он не входит. Сохраняются поставленные `COPYING.MinGW-w64-runtime.txt` и
информация о компонентах набора. Лицензии отдельных инструментов не заменяются
Apache-2.0 проекта. [Исходники и состав закреплённой версии](https://github.com/skeeto/w64devkit/tree/v2.10.1).

## Условия подготовки бинарного выпуска

Для offline-чтения Maven metadata AAB повторно используются локальные build
dependencies: **AGP 9.1.0**, **protobuf-java 3.25.5**, **Gson 2.13.2**.
Три JAR и protobuf schema закреплены в
[`android-aab-dependencies.lock.json`](../scripts/release/android-aab-dependencies.lock.json).
Это инструменты инспекции; новый код не добавляет их в runtime ExVPN и не
распространяет JAR. Локальные POM AGP/Gson декларируют Apache-2.0; отсутствие
`licenses` в child POM protobuf не трактуется как отсутствие обязательств.
Полная проверка runtime Maven notices остаётся отдельной.
[Методика](../scripts/release/ANDROID_AAB_DEPENDENCIES.md).

2026-10-17: notices дополнены полным `sky_engine/LICENSE`, сверенным с Git blob
выбранного закреплённого Flutter commit. Ссылочный platform markdown сохранён,
но больше не является единственным engine notice. Тесты отвергают удалённый,
подменённый и взятый из другого SDK текст. В неизменных пакетах Shorebird +16
отдельно проверен `NOTICES.Z`: все 1588 текстов / 1694 пары «имя–текст» из
этого aggregate уже присутствуют. Это не доказывает полноту Rust updater
или всех runtime dependencies. [Проверка](evidence/flutter-engine-notices-build16.json).

Для независимого offline-аудита готового NSIS installer закреплён **7-Zip 26.04**
([официальный релиз](https://github.com/ip7z/7zip/releases/tag/26.04)). Bootstrap
`7zr.exe` используется только для извлечения 7z.exe/7z.dll/License.txt из
официального архива; Windows-установка не выполняется. Download digests,
извлечённые файлы и source archive закреплены в
[`archive-inspector.lock.json`](../scripts/release/archive-inspector.lock.json).
Это инструмент проверки, он не включается в APK/EXE ExVPN. Полный текст
лицензий именно этого архива сохранён в
[`7zip-26.04.txt`](../scripts/release/licenses/7zip-26.04.txt): LGPL-2.1-or-later,
дополнительные BSD-уведомления и unRAR restriction для соответствующих частей.
Хеши не подменяют подпись издателя; обязанности runtime ExVPN не закрываются
лицензией инструмента проверки.

В 0.1.0+7 приложение прямо использует уже закреплённый Dart `crypto` **3.0.7**
(BSD-3-Clause) для HMAC идентификатора установки по HTTPS origin. Версия не
изменена; dependency перенесена из dev в runtime, app lock обновлён. Секрет
остаётся в существующем Keystore/DPAPI backend. В комплект Windows +7 собрано
140 component notices; это не закрывает отдельную задачу финального SBOM.

Генератор полного текста доступных notices и границы инвентаризации описаны в
[RELEASE_NOTICES.md](RELEASE_NOTICES.md). Он сверяет реальные Go build info/checksums,
сохраняет Xray source zip и не подменяет отдельный release SBOM.

- Сохранить авторские уведомления и полный текст лицензий фактически поставляемых библиотек, драйверов и runtime-компонентов.
- Для Xray/MPL-2.0 предоставить получателям доступ к соответствующим исходникам и изменениям покрытых файлов, включая точный commit и инструкции получения. Собственная Apache-лицензия не заменяет эти обязательства.
- Для libXray/MIT и BSD-компонентов включить требуемые copyright/license/disclaimer notices.
- Добавить зависимости Flutter engine, пакетов Dart, Go modules, Android build/runtime и installer plugins; не ограничиваться прямыми зависимостями.
- Сверить лицензии выбранных versions/commits повторно перед релизом: ссылки `main`/`master` в этом начальном реестре служат источниками для выбора, а не неизменяемыми доказательствами релиза.
- Сформировать SBOM и комплект уведомлений для каждого Android ABI и Windows-пакета. Сверить состав с реально упакованными файлами.
- Подписи Android/Windows, доступ к Shorebird и учётные данные магазинов хранить вне Git; проверять наличие прав и ключей до обещания релиза.

## Функциональные ориентиры

HAPP и Hiddify не входят в зависимости ExVPN. Из них не скопированы код, логотипы или дизайн-ресурсы. Перед заимствованием любого компонента требуется отдельная проверка лицензии конкретной версии; начальный план указывает на ограничения NonCommercial в [лицензии Hiddify](https://github.com/hiddify/hiddify-app/blob/main/LICENSE.md). Выбор собственного клиента не отменяет обязанности проверять все реально используемые сторонние компоненты.

## Комплект демо 0.1.0+18

`actions/download-artifact` v7 закреплён commit
`37930b1c2abaa49bbe596cd826c3c89aef350131`; полный LICENSE этого commit проверен
(MIT). Это CI-инструмент, не компонент APK/EXE. Остальные actions сохраняют
существующие точные pins.

Три MSVC DLL не обновлены: CI извлекает их из официального immutable VSIX,
URL/размер/SHA-256 в `scripts/windows/msvc-runtime-ci.lock.json`.
Установщик сохраняет полные Microsoft terms и предлагает отдельные условия
для этих компонентов. VSIX и dumpbin не включаются в релиз.

Android Maven supplement: 66 закреплённых компонентов, 61 полный текст;
точные POM/artifact hashes и provenance в
`scripts/release/licenses/android-demo/inventory.json`. Состав консервативно
шире release-графа; same-build observer проверяет фактически выбранные входы.
Tink shaded Protobuf включён отдельно. Это проверка уведомлений входных
зависимостей, а не утверждение о полном post-R8 SBOM. Стабильный лицензионный
аудит остаётся открытым. Обычный Flutter не включает native Shorebird updater.

## Комплект Shorebird Preview 0.1.7+28

2026-10-19 подготовлен отдельный offline source-notice supplement для точных
Flutter `5bef02a16146a0effc07da4acccaafe90a2739ce`, engine
`4b936a0c03e13389ddfb1ac48823f187964975c2`, native updater
`70ff1e336798474e39586d3f5ac2ca386ef32d9e` и наблюдавшегося Rust source
`b940084d7eb6a299eb4bfeb8e34901bc051e7ac4`.
[Pin и хеш inventory](../scripts/release/shorebird-runtime-notices.lock.json)
связывают 200 файлов: полные опубликованные тексты из консервативного набора
282 crates, проверенные дополнения из точных исходных commits, собственные
лицензии/`COPYRIGHT`/`REUSE.toml`/`license-metadata.json` Rust и исходные архивы,
требуемые отдельными выбранными лицензиями. Полные исходные Rust metadata
сохранены без объявления compiler-only компонентов частью приложения.

`comde 0.3.1` объявляет `Apache-2.0 OR MIT`, но его точный опубликованный crate
не содержит полного LICENSE, NOTICE или copyright-текста. Выбрана объявленная
ветка Apache-2.0: приложен полный стандартный Apache-текст с явным происхождением
и полный исходный crate с SHA-256; авторство не придумано и этот текст не
выдаётся за отсутствующий файл upstream. Из 282 source records без полных
текстов остаются `sacabase`/`sacapart` из отдельного patch CLI и `vex-sdk`,
который точный Rust std manifest ограничивает `target_os="vexos"`.
Эти три записи явно отмечены как не входящие в рассматриваемые Android/Windows
runtime roots. Все 200 узлов консервативного updater production/build closure
имеют тексты; это source-closure, а не доказательство окончательной линковки.

`collect-notices.ps1` добавляет этот комплект только при явном Shorebird runtime;
ordinary-сборки и прежние лицензии не меняются. Новый offline checker проверяет
точный набор, хеши и runtime binding, отклоняет подмену/лишние файлы и сохраняет
`exactLinkedMembership=false`, `completePostLinkSbom=false`,
`stableReleaseReady=false`. Проверено: 220 focused checks, без SDK, сборки,
установки или облачной публикации. Включение комплекта в фактические APK/NSIS
проверяется отдельно перед распространением.

Для same-build Android Maven supplement добавлен явный
`prepare-demo-maven-notices.ps1 -FlutterRuntime shorebird`. Он использует
закреплённый Shorebird engine вместо ordinary engine и сохраняет прежние
проверки всех non-Flutter GAV/POM/AAR/JAR и полных текстов. Runtime selection
входит в sidecar ZIP; неподдержанный компонент или другой engine вызывают отказ.
41 synthetic checks прошли; сам helper не запускает Gradle и не создаёт APK.
Это отдельная Preview-policy, не изменение stable inventory/аудита.
