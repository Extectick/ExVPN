# Проверки и сборки CI

Workflow `.github/workflows/verify.yml` подготовлен для push, pull request и
ручного запуска. Два изолированных `windows-2025` job собирают Android и Windows
из одного checkout. Первый успешный run и границы его проверки приведены ниже;
успех сборки не является системной приёмкой VPN.

Push, изменяющий только `docs/**`, `design/**`, `README.md`, `AGENTS.md` или
`CONTRIBUTING.md`, не запускает заново долгие native-сборки и не отменяет уже
идущий прогон кода. Любой исходник, build/CI-скрипт, lock-файл или упаковываемое
лицензионное уведомление запускает оба job. Для pull request фильтра нет:
обязательные проверки всегда получают результат; ручной запуск сохранён.
Семантика фильтра: [GitHub workflow paths-ignore](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

Скрипт `scripts/ci/verify.ps1 -Target Checks|Android|Windows` проверяет точные
Flutter/Go pins, lock-файлы Dart, анализ, все unit/widget/loopback-тесты,
Go checksums и vet. Android дополнительно собирает обе JNI ABI и APK;
Windows — UI, службу и проверенный Wintun archive. Команды не устанавливают
службу/драйвер и не меняют WFP, маршруты или DNS хоста.

Flutter и Go скачиваются с официальных URL с SHA-256 из toolchain lock.
Android packages: API36, build-tools36.0.0, NDK27.1.12297006 для собственного
ядра, NDK28.2.13676358 для Flutter plugins. Gradle/AGP/Kotlin закреплены в
Android source. Runner предоставляет JDK21 и VS C++/ATL/CMake/Windows SDK;
его образ обновляется GitHub, поэтому полная побитовая воспроизводимость
пока не заявляется. Новые SDK licenses автоматически не принимаются.

Workflow использует только `contents: read`; Git credentials не остаются в
checkout. Нет `pull_request_target`, signing secrets, приватной подписки,
production endpoints или публикации release. Actions закреплены полными SHA,
проверенными в официальных repositories: checkout7.0.1 и upload-artifact6.0.0.
Основание: [GitHub secure use](https://docs.github.com/en/actions/reference/security/secure-use).

Артефакты явно названы **debug/development**, хранятся семь дней. Debug APK
подписывается временным debug key runner и не является совместимым каналом
обновления пользовательской beta. Windows bundle ещё не является установщиком.
Для EXVPN-E7-002 нужен отдельный защищённый выпуск с постоянной подписью,
лицензиями/SBOM, приёмкой сети и проверкой обновления предыдущего пакета.

Первый clean-checkout [run 38878852742](https://github.com/Extectick/ExVPN/actions/runs/38878852742)
16 октября 2026 выявил ошибку чтения версии: первый старт Flutter печатает
bootstrap progress даже при `--version --machine`, поэтому JSON parsing падал
до тестов в обоих jobs. `flutter-version.ps1` сначала отдельно инициализирует CLI,
затем проверяет exit code и строгий JSON второго вызова. Проверены cold-start
fixture, ошибки обоих вызовов и настоящий закреплённый SDK. Исправление подтверждено
полным успешным [run 38880672529](https://github.com/Extectick/ExVPN/actions/runs/38880672529)
на commit `f6cd4c4`: Android и Windows прошли проверки, сборку и выгрузку
development artifacts. Последующие изменения требуют собственного CI run;
эта проверка не подтверждает системные VPN-права, установщик или release signing.

2026-10-17: полный [run 38961456222](https://github.com/Extectick/ExVPN/actions/runs/38961456222)
на [f2c5c5e](https://github.com/Extectick/ExVPN/commit/f2c5c5e795782adbded8b6e30817d58bf3b88a45)
для **0.1.0+9** завершился **SUCCESS** в обоих jobs, включая Android/Windows
development artifacts. Он покрывает VLESS Encryption/Sudoku и состояние этого
commit. Последующие lifecycle QA scripts и release audit требуют собственного
прогона; зелёный CI не закрывает протокольную/сетевую приёмку и подпись beta.

Для **+10** опубликованы [924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479)
и [run 38969281066](https://github.com/Extectick/ExVPN/actions/runs/38969281066).
Он завершился **SUCCESS**: Windows 7 мин 56 с, Android 14 мин 50 с, анализ,
тесты, обе native-сборки и загрузка development artifacts прошли.
[Обезличенное доказательство](evidence/ci-build10.json). Docs-only push `7da4c1c`
не создал новый run и не отменил сборку. Локальные native builds и итоговые
быстрые проверки также прошли: [37,77 с, девять наборов](evidence/fast-validation-build10.json).
Android +10 также прошёл [обновление и настоящий HTTPS в эмуляторе](evidence/android-upgrade-build10.json).

Локальный общий прогон 2026-10-16 после QR/OTA/installer исправлений завершился
успешно: 113 domain, 25 state, 31 updates и 124 Flutter tests, чистый анализ;
Go verify/test/vet всех трёх модулей. Для `Checks`/`Windows` добавлен отдельный
запуск PS5.1 installer tests: 13 recovery-сценариев с настоящими блокировками
файлов, manifest/path проверки и mock machine mutex. SCM/ACL подменены,
установка на хосте не производится. Источники installer/CI:
[8d8e48b](https://github.com/Extectick/ExVPN/commit/8d8e48b).

Полный clean-checkout [run 38885825613](https://github.com/Extectick/ExVPN/actions/runs/38885825613)
на [6fe2d3a](https://github.com/Extectick/ExVPN/commit/6fe2d3a288493b57ce9a7aa698a9df087f2fc50e)
завершился **SUCCESS** на обеих платформах: Windows 7m35s, Android 15m21s.
Он включает QR/OTA/authoring tests и installer failure checks этого commit.
После него добавлены native Android bounded QR reader и Windows WFP/SCM fixes
([fe48846](https://github.com/Extectick/ExVPN/commit/fe488467b9946b8f9ca79aad6d2a8bb777d25130),
[b2f4e42](https://github.com/Extectick/ExVPN/commit/b2f4e427075af5f5592904f0f6fdbdc82755af54)).
Локально прошли 133 Flutter tests, analyze, 8 JVM reader tests и APK build;
Windows Go test/vet, service build и PS5.1 ACL/manifest/13 recovery/mutex checks.
Android CI теперь дополнительно выполняет `:app:testDebugUnitTest`.
Отдельно прошёл реальный install/recover/restart/uninstall в Sandbox, что не
заменяет сетевые испытания. Полный [run 38913723317](https://github.com/Extectick/ExVPN/actions/runs/38913723317)
на `a26b653` успешно завершил Android и Windows, включая JVM reader tests.
Следующие WFP GUID/DNS исправления `c50f5cd` и новый Sandbox-стенд `9fdf035`
прошли локальные Go test/vet, service build и сборку NSIS. Полный
[run 38918417589](https://github.com/Extectick/ExVPN/actions/runs/38918417589)
на `98ad92a` завершился успешно на Android и Windows. Новый Windows hostname
bootstrap требует собственного прогона; этот зелёный CI его не покрывает.
