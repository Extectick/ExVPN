# Проверки и сборки CI

Workflow `.github/workflows/verify.yml` подготовлен для push, pull request и
ручного запуска. Два изолированных `windows-2025` job проверяют Android и Windows
из одного checkout и при необходимости собирают native-пакеты. Первый успешный run и границы его проверки приведены ниже;
успех сборки не является системной приёмкой VPN.

Push, изменяющий только `docs/**`, `design/**`, `README.md`, `AGENTS.md` или
`CONTRIBUTING.md`, не запускает заново долгие native-сборки и не отменяет уже
идущий прогон кода. Остальные push запускают оба job. Для pull request фильтра нет:
обязательные проверки всегда получают результат; ручной запуск сохранён.
Семантика фильтра: [GitHub workflow paths-ignore](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

В запущенном workflow `scripts/ci/build-impact.ps1` разрешает пропустить только
native-сборку для push, содержащего исключительно известные QA-файлы и
сопутствующие документы. Хотя бы один QA-файл обязателен. Анализ, Dart/Flutter,
Go test/vet, lifecycle/race и применимые platform unit tests сохраняются.
В таком прогоне нет новых APK/EXE и выгрузки native artifacts; успех не является
новым доказательством сборки приложения.

Selector читает все commits диапазона `before..after`, проверяет точный HEAD,
полную историю и чистое дерево. Product-код, toolchain/CI/build scripts,
lock-файлы, notices, неизвестный путь, удаление/переименование, merge,
недоступная база или ошибка Git требуют полной сборки. Pull request и ручной
запуск всегда полные. Allowlist находится в `build-impact-lib.ps1`; разрешать
целые каталоги `scripts/qa` или `native` нельзя.

Дополнение 2026-10-17: allowlist расширен ровно на десять уже проверяемых
файлов Windows TCP teardown и Android offline PCAP. Новые соседние файлы,
controller, зависимости и toolchain по-прежнему требуют native-сборки.
**131** selector/graph/JUnit fixtures прошли, включая смешанный push,
удаление, переименование и изменение product-кода с последующим откатом.
Фактический QA-only run на GitHub остаётся незакрытым критерием E7-006.

Граница фильтра событий: GitHub применяет `paths-ignore` к конечному diff до
запуска selector. Поэтому push, чей конечный diff содержит только документы,
не запускает workflow даже при промежуточном изменении и откате product-кода.
Это не даёт нового результата CI. Если конечный diff запускает workflow,
selector видит промежуточное изменение product-кода и требует полную сборку.
Это сохраняет прежнее правило: обновление отчёта не отменяет текущую сборку.

Android QA-only выполняет `:app:testDebugUnitTest` отдельным Gradle invocation.
Единственное исключение — `:app:verifyExVpnPackageInputs`: пакет здесь не
собирается, а обычные APK-сборки сохраняют эту обязательную проверку. До
исполнения проверяется task graph, после — свежие JUnit XML без failures,
errors или skips и отсутствие APK/AAB/`libexvpn.so`. SDK/API/build-tools и
NDK28 для штатных Flutter dependencies сохраняются; NDK27 и обе ExVPN JNI ABI
в этой ветке не собираются.

Локальная проверка 2026-10-17: **92** selector/graph/JUnit fixtures прошли,
в чистом archive checkout новый helper выполнил **8/8 JVM tests за 43,13 с**
(включая dry-run). Использованы уже установленные SDK и dependency caches.
Первый helper-прогон отказался засчитать JUnit XML из-за PowerShell adapter
collision атрибута `name`; исправление покрыто реалистичным fixture.
[Доказательство, hashes и ограничения](evidence/ci-build-impact-build11.json).
Проверка QA-only ветки на холодном GitHub runner пока не выполнена; локальное
время нельзя выдавать за измеренное ускорение CI.

Полная ветка нового selector подтверждена в [run 38982631039](https://github.com/Extectick/ExVPN/actions/runs/38982631039)
на [2b9bd54](https://github.com/Extectick/ExVPN/commit/2b9bd5408edde6bf5cb14ad956ac077632558218):
оба job выбрали `full_production_or_unknown_path`, `skip_native_build=false`.
Windows завершился за **9 мин 55 с**, Android — за **17 мин 26 с**; проверки,
сборки и выгрузка development artifacts прошли. Это ожидаемое поведение для
изменений самих CI scripts. [Обезличенное доказательство](evidence/ci-acceleration-build11.json).
Запуск не подтверждает пропуск native-сборки на QA-only push и не закрывает E7-006.

Скрипт `scripts/ci/verify.ps1 -Target Checks|Android|Windows` проверяет точные
Flutter/Go pins, lock-файлы Dart, анализ, все unit/widget/loopback-тесты,
Go checksums и vet. Android дополнительно собирает обе JNI ABI и APK;
Windows — UI, службу и проверенный Wintun archive. Команды не устанавливают
службу/драйвер и не меняют WFP, маршруты или DNS хоста.

Для **+11** полный [run 38979241913](https://github.com/Extectick/ExVPN/actions/runs/38979241913)
на [292d3dc](https://github.com/Extectick/ExVPN/commit/292d3dc05f1b694a26ca9e2cb30953850e5b8373)
завершился **SUCCESS**: Windows — 9 мин 11 с, Android — 18 мин 48 с.
Анализ, тесты, native-сборки и выгрузка development artifacts прошли.
[Точные jobs, длительности и хеши архивов](evidence/ci-build11.json).
Первый прогон обнаружил CRLF в синтетическом valid-patch fixture; исправление
нормализует только этот fixture, а production-проверка LF остаётся строгой.
Windows runtime-проверка закрытия соединений ведётся отдельно; успех CI её
не подтверждает.

Для следующих CI runs добавлены три независимых кеша через
`actions/cache` **6.1.0**, commit
`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`:

- Только два точно названных ZIP Flutter/Go. Ключ содержит OS/архитектуру и
  хеши toolchain lock/bootstrap. Bootstrap всегда заново сверяет SHA-256
  архивов перед распаковкой; распакованные SDK не кешируются.
- Go module/build cache. Ключ дополнительно содержит Android/Windows target,
  все три module/checksum пары и Xray patch/lock; job не конкурируют за один
  неполный compiler cache. `go mod verify`, readonly и `test -count=1` остаются.
- Pub cache с ключом по закреплённому SDK и четырём pubspec.lock. Проверка
  lock-файлов, анализ и тесты не пропускаются при cache hit.

Нет fallback `restore-keys`, cross-OS archive, Gradle cache, приватных данных,
готовых пакетов или signing keys. Лимиты/оплата GitHub не менялись. Первый run
может быть cold miss; измеренного cache-hit ускорения пока нет.

Flutter и Go скачиваются с официальных URL с SHA-256 из toolchain lock.
Android packages: API36, build-tools36.0.0, NDK27.1.12297006 для собственного
ядра, NDK28.2.13676358 для Flutter plugins. Gradle/AGP/Kotlin закреплены в
Android source. Runner предоставляет JDK21 и VS C++/ATL/CMake/Windows SDK;
его образ обновляется GitHub, поэтому полная побитовая воспроизводимость
пока не заявляется. Новые SDK licenses автоматически не принимаются.

Workflow использует только `contents: read`; Git credentials не остаются в
checkout. Нет `pull_request_target`, signing secrets, приватной подписки,
production endpoints или публикации release. Actions закреплены полными SHA,
проверенными в официальных repositories: checkout7.0.1, upload-artifact6.0.0
и cache6.1.0.
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
