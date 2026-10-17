# Android runtime dependency inventory

Для уже готового AAB есть дополнительная быстрая offline-проверка:
[`android-aab-dependencies.ps1`](ANDROID_AAB_DEPENDENCIES.md) связывает
записанные AGP binary hashes с точными локальными AAR/JAR. Она не запускает
Gradle и не заменяет следующий collector, POM/licenses или привязку APK.

Из корня проекта после обычного bootstrap и dependency resolution. Режим по
умолчанию использует только сетью не пользующийся Gradle `--offline`:

```powershell
pwsh -NoProfile -File scripts/release/android-runtime-inventory.ps1 -Variant debug
```

Обычный Flutter остаётся выбором по умолчанию (`-FlutterRuntime ordinary`).
Для отдельного закреплённого Shorebird SDK есть явный offline-режим:

```powershell
pwsh -NoProfile -File scripts/release/android-runtime-inventory.ps1 -FlutterRuntime shorebird -Variant release
```

Общий `Get-ReleaseFlutterRuntime` проверяет выбранные SDK/CLI pins, engine,
build mode и cached runtime inputs до snapshot и повторно между фазами.
Исходники Flutter Gradle tooling и SDK plugins берутся из выбранного SDK;
SDK-записи `package_config.json` должны указывать на него же, иначе сбор
отклоняется. В графе сохраняются его identity и storage origin. Произвольный
`FLUTTER_STORAGE_BASE_URL` родительского процесса не наследуется: для ordinary
действует штатный Google storage, для Shorebird — только
`https://download.shorebird.dev`. Окружение родителя не меняется.

Shorebird поддерживается только с `-Variant release` и **без**
`-PrepareMetadataFrom`. Существующий seed и policy подготовки POM относятся
к ordinary Flutter; это сочетание отвергается до создания output/cache и
запуска дочернего процесса с кодом
`android_inventory_shorebird_prepared_metadata_unsupported`.
Новый metadata policy требует отдельной проверки; автоматического fallback нет.
Поддержка selector сама по себе не означает успешный сбор фактического
Shorebird-графа и не связывает его с APK/AAB. Результат остаётся
`COLLECTED_INCOMPLETE`; release audit и его blockers не изменяются.

Для уже проверенных входов debug +13 есть явный **prepared-input workflow**:

```powershell
pwsh -NoProfile -File scripts/release/android-runtime-inventory.ps1 -Variant debug `
  -PrepareMetadataFrom scripts/release/android-runtime-inventory-seed.json
```

Этот аргумент разрешает отдельную подготовку публичных POM-метаданных. Без него
online-процесс не создаётся; неуспех offline-проверки никогда не включает fallback.
Это не автоматический cold bootstrap новых зависимостей. Закреплённые SDK,
runtime AAR/JAR и исходные POM должны уже находиться в read-only dependency cache.
Каждый вызов создаёт новый snapshot и изначально пустой private Gradle user home.

Публичный schema1 seed содержит 68 runtime GAV, 9 parent/BOM GAV, размеры и
SHA-256 POM/AAR/JAR, 18 metadata edges, variant/Flutter/engine identity и два
fingerprint. В нём нет абсолютных путей, журналов, URL провайдеров или секретов.
`locally_observed_gradle_inputs` означает наблюдённые локальные байты, а не
подпись или независимое подтверждение издателя. Полный локальный resolved graph
и произвольные JSON/envelope как seed не принимаются.

Перед сетью проверяются исходные Android/plugin/Flutter-Gradle деревья,
pubspec/lock/toolchain и engine inputs. Их portable fingerprint — SHA-256
от ordinal-sorted UTF-8 строк `identity<TAB>sha256<LF>`. Generated package paths,
collector и cache paths не входят в этот fingerprint, но продолжают входить
в отдельные локальные seals и проверки неизменности. Новые файлы в исходных
деревьях также проверяются. POM читаются с ограничением 8 MiB, DTD и внешние
entities запрещены. Только буквальные точные parent/BOM coordinates, не более
64 дополнительных компонентов и 8 уровней; cycles, неизвестные profile imports,
неразрешённые свойства и изменение bytes/closure приводят к отказу до сети.

Online-подготовка запускает только `:prepareExactPoms` в отдельном минимальном
проекте без Android/Flutter plugins и dependency graph. Фиксированы Google Maven,
Maven Central и Flutter storage; `includeVersion` допускает только GAV из seed
и проверенной closure. Произвольный repository URL не принимается. RO cache
отключён только у этого дочернего процесса: Gradle должен создать POM bytes и
artifact index именно в private cache. Загруженные POM обязаны совпасть с seed.

Затем отдельный процесс запускает строгий `--offline` inventory исходного
snapshot. Сравниваются GAV, variants, requested selectors/edges, project build
script hashes и runtime/POM bytes с semantic fingerprint seed. `.module`
candidates не считаются доказательством выбранного metadata source. И online,
и offline процесс ограничены 180 секундами и 32 MiB на каждый поток журнала;
при превышении завершается только принадлежащее вызову дерево процессов.
Исходные и перенесённые inputs сверяются между фазами и после них. Ни успех
подготовки, ни совпавший seed не снимают APK/license/release gates.

Seed не обновляется автоматически. Его изменение — отдельный reviewed шаг:
сохранить строгий граф и source seal, проверить закреплённые новые GAV/bytes и
literal metadata closure, подготовить path-free manifest и перепроверить его
с новым изолированным offline запуском. При mismatch текущая команда сохраняет
отказ в новом каталоге и останавливается, не перезаписывая прежние доказательства.

Инструмент использует закреплённый Gradle 9.3.1 и `--offline`. Он создаёт
новый snapshot Android-проекта, исходников plugins и Flutter Gradle tooling
в `artifacts/qa/`, отделяет Gradle user/project caches и читает существующий
dependency cache через `GRADLE_RO_DEP_CACHE`. Существующие SDK и проектные
build-каталоги не используются для записи результатов. Не запускать одновременно
с изменением входных исходников или обновлением зависимостей.

Единственная задача приложения — `:app:exvpnRuntimeInventory`. Она получает
выбранный `debugRuntimeClasspath` или `releaseRuntimeClasspath`, точные GAV,
варианты и рёбра графа, SHA-256 AAR/JAR/POM и исходники project plugins.
Flutter Gradle tooling может компилироваться как included build; APK, JNI,
project plugin AAR и код приложения не собираются.

До и после выполнения сверяются содержимое и состав исходных деревьев и
snapshot, включая добавленные файлы. Переносы путей записываются отдельно.
Launcher JVM options очищаются только в окружении дочернего процесса;
фактический Gradle user home проверяется против изолированного каталога.
Динамические/changing зависимости, неизвестные типы
компонентов, неразрешённые зависимости и чужая версия Flutter engine приводят
к отказу. Диагностика unresolved содержит только безопасные координаты и классы
ошибок; полный Gradle log остаётся локальным.

Успех называется `COLLECTED_INCOMPLETE`: это граф разрешённых входов, а не
подтверждение состава готового APK. Не подтверждены линковка/shrinking,
project binaries, полный комплект лицензий, независимая проверка издателя,
подпись выпуска и системная приёмка. Найденный в кеше `.module` помечается
кандидатом; он не доказывает, какой metadata source выбрал Gradle.
DSL ABI filters — входная конфигурация; итоговые ABI проверяются отдельно
по готовому APK штатным packaging guard.

Быстрые отрицательные fixtures входят в общий runner и CI:

```powershell
pwsh -NoProfile -File scripts/release/android-runtime-inventory-test.ps1
# Отдельная проверка самого Gradle collector на синтетическом offline repo.
pwsh -NoProfile -File scripts/release/android-runtime-inventory-test.ps1 -WithGradleFixture
```

2026-10-17: реальные debug попытки выявили три плавающих зависимости pinned
Flutter `integration_test`. Проектный `exvpn-integration-test-pins.gradle.kts`
закрепляет наблюдённые runner 1.3.0, rules 1.2.0 и Espresso core 3.3.0 до
resolution; SDK не изменён. 92 отдельные проверки, включая запуск того же
Gradle script и отказ при конфликте root/transitive constraints, прошли.
Полный actual inventory требует отдельного успешного отчёта. Результаты и
отказы сохраняются в отдельных папках, повтор не перезаписывает предыдущую
попытку; release blockers автоматически не снимаются.

Позднее сохранённый debug snapshot прошёл строгую offline-проверку: 68 Maven
компонентов, 6 проектов и 279 связей. Для этого отдельно подготовлены точные POM
в private cache, включая 9 parent/BOM метаданных. Наличие файлов в read-only кеше
само по себе не обеспечивало offline artifact index. Исправлен разбор сокращённых
SHA1 cache keys; 67 быстрых fixtures PASS.
[Отчёт](../../docs/evidence/android-runtime-inputs-build13.json).
Это исторический диагностический запуск сохранённого снимка с исправленным host
postprocessor. Новый prepared-input путь проверяется отдельно; наличие его
исходников само по себе не доказывает actual run. Автоматический online fallback
не добавлялся. Привязка входного графа к готовому
APK и остальные release gates остаются открытыми.
