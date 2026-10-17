# Комплект лицензий перед упаковкой

`scripts/release/collect-notices.ps1` формирует отдельный каталог с полными
лицензиями и `inventory.json`. Входом служат уже собранные Go-бинарники и
разрешённые пакеты Flutter, а не вручную составленный список названий.

```powershell
# Use the service and license from the exact payload being packaged.
./scripts/release/collect-notices.ps1 -Target Windows `
  -NativeBinaries artifacts/windows/<package>/payload/service/exvpn-service.exe `
  -WintunLicensePath artifacts/windows/<package>/payload/service/Wintun-LICENSE.txt `
  -OutputDirectory artifacts/notices/windows-build-N

# Both libraries must come from the intended APK staging directory or APK.
./scripts/release/collect-notices.ps1 -Target Android `
  -NativeBinaries @('<staging>/arm64-v8a/libexvpn.so','<staging>/x86_64/libexvpn.so') `
  -OutputDirectory artifacts/notices/android-build-N
```

Выходной каталог должен быть новым: скрипт не удаляет старые доказательства.
Перед Windows-запуском нужны `scripts/windows/build.ps1` и
`scripts/windows/prepare-wintun.ps1`; перед Android — `native/android/build.ps1`.
`flutter pub get --enforce-lockfile` должен уже разрешить зависимости приложения.

## Что собирается

- SHA-256 каждого native binary, версия Go и фактически включённые модули из
  `go version -m -json`. Внешние replace без отдельной проверки отклоняются.
  Входы задаются явно: глобальная папка последней сборки больше не выбирается
  автоматически. Проверяются pinned Go, платформа, build mode и обе Android ABI;
  две копии одной ABI отклоняются. В отчёт попадают только пути внутри payload.
- Точные Go-исходники из module cache/download с проверкой checksum по embedded
  build info. Собираются LICENSE, COPYING, NOTICE, AUTHORS и PATENTS, включая
  вложенные уведомления. Неизвестный компонент без текста лицензии останавливает
  подготовку.
- Полный source ZIP, соответствующий фактически включённому Xray, и его MPL-2.0.
  Для `-exvpn.N` дополнительно включаются patch, lock и уведомление о модификации;
  их хеши и Go h1 сверяются до упаковки и при аудите пакета. Исходный upstream
  архив остаётся неизменным; модифицированный модуль получает отдельную версию.
  [Реконструкция исходников](../native/patches/README.md).
- Flutter engine/framework, Dart/Go runtime, Inter и лицензии иконок.
- Wintun DLL: отдельный **Prebuilt Binaries License**, а не MIT-лицензия Go binding.
- Dart/pub зависимости из package config, сверенные с `pubspec.lock`, точными
  каталогами hosted cache, name/version исходного pubspec и сохранёнными SHA-256
  архивов. Отсутствие, повтор, несовпадение версии/источника/хеша останавливает
  сбор. Парсер принимает только используемый generated lockfile format;
  неподдерживаемые источники не пропускаются. Это консервативный список,
  включающий dev-пакеты, а не точная линковка. Проверка cache metadata не
  заменяет независимую проверку содержимого исходного архива.
- Версия ExVPN читается из pubspec и сверяется с отображаемой идентичностью.
  `app.version`, хеши lock/config и `dartPackages` записываются рядом с notices.
  Windows packaging также отклоняет переданную готовую папку notices, если
  её app/build, Dart lock или native SHA-256 не соответствуют текущему payload.

2026-10-16: локальные сборы завершены для Windows (120 записей) и двух Android ABI
(119 записей). Это проверка генератора на текущих сборках; новый комплект надо
собирать после изменения зависимостей/бинарников. Файлы в `artifacts/` не входят
в Git, но соответствующая папка notices включается в поставляемый пакет.

2026-10-17: обнаружено, что старый генератор записывал `0.1.0+1` даже для +9.
Исправлены версия, явные native inputs и проверка Dart lock. 23 поведенческие
регрессии (`scripts/release/test-notice-inputs.ps1`) прошли; из immutable +9
service собраны 140 notices, из двух библиотек, извлечённых из immutable +9 APK,
— 139. Исправленные sidecar-каталоги проверяют генератор; они **не заменяют**
содержимое старых APK/установщика. Новые notices требуют новой упаковки.
Доказательства локально: `artifacts/notices/windows-build9-corrected-20261016-203055`
и `artifacts/notices/android-build9-input-20261016-203126-notices`.
Исходники сборщика и аудита: [dd7a221](https://github.com/Extectick/ExVPN/commit/dd7a221).

Обычная [Android-сборка](../scripts/release/ANDROID_NOTICES.md) теперь создаёт
свежий snapshot JNI/notices и проверяет его перед Gradle, после Gradle и по
содержимому готового APK. Отдельный Gradle-вызов без snapshot проверенно
отклоняется. 29 синтетических проверок прошли. Первая +10 выявила повторный AGP
strip обеих библиотек: исходный APK и неудачный аудит сохранены, кандидат не
устанавливался. После отключения повторного strip кандидат 2 содержит **139
компонентов / 218 assets**, обе точные JNI и соответствующий source ZIP Xray.
Независимый audit готового APK не нашёл notice/native-binding ошибок; остались
шесть блокировок release signing и неполного состава/лицензионной проверки.
Локальные evidence: `artifacts/release-audit/build10-android` (отказ) и
`artifacts/release-audit/build10-android-candidate2` (исправленная комплектация).
Это development-кандидаты одной ещё не опубликованной версии `0.1.0+10`;
хеш исправленного APK — `51903e3e943fe1608ed375eeaf46d5730369566ed119ab28d12b782a1699448c`.
[Доказательства](evidence/android-packaging-build10.json), исходники:
[b8dd91d](https://github.com/Extectick/ExVPN/commit/b8dd91da531c09449f98e17bcc9cfa2d5f7444da).

Windows +10 после reconnect/socket исправлений собран из
[924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479).
Payload содержит 140 notice-компонентов и 219 notice/source файлов; SHA-256
службы совпадает с inventory, Xray source ZIP соответствует linked checksum.
[Обезличенный аудит](evidence/windows-packaging-build10.json) сохраняет шесть
release blockers. Проверены SHA/signature установщика и отдельный staged payload;
независимое извлечение EXE всё ещё не выполнено. Это development, не beta.

## Незакрытая часть release gate

Локальный **+13/exvpn.4** прошёл проверку native/notice binding. В готовом APK
теперь ровно `arm64-v8a` и `x86_64`, обе с точными `libexvpn.so` и
`libflutter.so`; лишняя dependency-only ABI исключена. В Windows staged payload
222 notice/source файла, закреплённый source ZIP совпадает с Go checksum службы.
[Android](evidence/android-packaging-build13.json),
[Windows](evidence/windows-packaging-build13.json). Android debug-signed,
Windows unsigned; это development packages с открытыми release blockers.

Готовый Windows EXE +13 дополнительно проверен независимым извлечением через
закреплённый 7-Zip 26.04: **265/265 payload-файлов**, обе maintenance-программы
внутри Uninstall.exe и шесть вхождений NSIS plugins/bitmap совпали по размеру и
SHA-256. Полный audit занял **6,463 с**, 72 synthetic fixtures прошли.
[Обезличенное доказательство](evidence/windows-nsis-build13.json).
Предыдущий отказ из-за исходного пути MUI2 bitmap сохранён; исправлено только
соответствие имени `modern-wizard.bmp` исходному `win.bmp` закреплённого NSIS.
EXE и Uninstall.exe не исполнялись, исходный пакет не изменён. Проверка снимает
только blocker независимого извлечения payload; пять release blockers остаются,
exit code — 2, SBOM по-прежнему incomplete. Поведение installer instructions,
установки, upgrade и удаления требует отдельной системной проверки.
Исходники: [dfe753e](https://github.com/Extectick/ExVPN/commit/dfe753e2efc9ab9be7d4d830255332d3749b8196).

Для Gradle/Maven добавлен отдельный offline [runtime inventory](../scripts/release/ANDROID_RUNTIME_INVENTORY.md).
Он собирает разрешённый граф и хеши входов без APK/JNI, явно оставляя открытыми
проверки готового APK и лицензий. Фиксированный Flutter SDK сам по себе не
закрепляет три dynamic debug зависимости `integration_test`; actual collector
выявил этот отказ. Такой отказ не снимает ни один release blocker.

Три зависимости закреплены в проекте без изменения SDK; 92 проверки прошли.
Первый actual offline run остановился на POM query. Этот отказ сохранён в
[историческом отчёте](evidence/android-runtime-inventory-build13.json).
Последующая диагностика выявила отсутствие подходящего offline artifact index,
а затем некорректное ожидание 40-значного ключа кеша: Gradle удаляет ведущие нули
SHA1. Исправленный postprocessor проверяет ключ по реальным байтам; 67 fixtures
PASS, включая подмену и неоднозначность. [Исходники](https://github.com/Extectick/ExVPN/commit/1181e1a).

После отдельной подготовки точных 68 POM и 9 parent/BOM метаданных сохранённый
snapshot прошёл строгую offline-инвентаризацию за 13,672 с: 68 Maven-компонентов,
6 проектов, 279 связей, 34 AAR и 32 JAR. Старые отказы и snapshot сохранены.
[Отчёт](evidence/android-runtime-inputs-build13.json). Это диагностическая
проверка разрешённых входов: новый запуск штатной команды с пустым private cache,
связь графа с готовым APK, project binaries и лицензионная проверка ещё не закрыты.

Теперь явный режим `-PrepareMetadataFrom` подтверждён новым snapshot и изначально
пустым private cache: 77 точных POM подготовлены за 19,837 с; отдельный строгий
offline graph прошёл за 110,423 с, весь workflow — 148,158 с. Совпали 68 Maven,
6 project-компонентов, 279 связей и хеши 34 AAR / 32 JAR. Проверены неизменность
исходников и состава snapshot; 129 fixtures и четыре Gradle guard-сценария PASS.
[Отчёт](evidence/android-runtime-prepared-build13.json),
[исходники](https://github.com/Extectick/ExVPN/commit/541be0d).
Первый отказ guard пустого Gradle-проекта сохранён; после исправления проверены
точные стадии отказа, а не только ненулевой exit code. Этот prepared-input режим
использует существующий read-only dependency cache и не доказывает холодный
bootstrap. По умолчанию collector остаётся offline, автоматического сетевого
fallback нет. APK/JNI не собирались; привязка к APK и остальные release gates
остаются открытыми.

Эта инвентаризация не является полным SBOM: Gradle/Maven runtime, отдельные NSIS
компоненты и комплект Windows runtime проверяются дополнительно по фактическому
пакету. Проверка совместимости лицензий, подписи и воспроизводимости выпуска
остаётся в E7. Наличие notices само по себе не подтверждает готовность beta.

Добавлена отдельная [проверка фактических артефактов](../scripts/release/ARTIFACT_AUDIT.md)
с CycloneDX 1.6 и ненулевым exit code при неполной готовности. 41 synthetic
fixture прошла; четыре SBOM +9 соответствуют официальной JSON schema, повтор
Windows даёт побайтно одинаковые отчёты. [Сводка](evidence/release-audit-build9.json)
сохраняет найденные пробелы: Android без полного notice bundle, старые Windows
notices, development signing, неполный runtime состав и независимая сверка NSIS.
Исправленные sidecars проходят binding, но не считаются содержимым старых пакетов.
