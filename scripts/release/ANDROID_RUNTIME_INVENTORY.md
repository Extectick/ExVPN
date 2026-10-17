# Android runtime dependency inventory

Из корня проекта после обычного bootstrap и dependency resolution:

```powershell
pwsh -NoProfile -File scripts/release/android-runtime-inventory.ps1 -Variant debug
```

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
Launcher JVM options очищаются только внутри процесса и восстанавливаются;
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
Это диагностический запуск сохранённого снимка с исправленным host postprocessor;
новый запуск штатной команды с пустым private cache отдельно не подтверждён.
Автоматический online fallback не добавлялся. Привязка входного графа к готовому
APK и остальные release gates остаются открытыми.
