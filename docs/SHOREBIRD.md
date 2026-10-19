# Shorebird: подготовка Dart OTA

Исправление инструмента отката, 2026-10-20: PowerShell должен передавать
`--app-id`, `--release-version`, `--patch-number` тремя отдельными аргументами.
Прежняя конкатенация останавливала CLI до облачной мутации. Точные некомпилируемые
rollback/policy/test helpers допускают обслуживание без замены базового пакета;
build wrappers, SDK/signing pins, dependencies, native, assets и build identity
по-прежнему запрещены в Dart-патче. Upstream native/assets diff checks включены.
Изменение одних helpers не считается Dart-патчем. 298 pipeline guards PASS;
общий Full приложения и сборки не повторялись.

## Реальный цикл 0.1.8+29 — подписанный OTA roundtrip принят, 2026-10-20

Приняты обе локальные официальные базы source **`5bddc777` (C7)**, release
**908884**. CLI **1.6.129**, Flutter **5bef02a**, engine **4b936a0**, прежние APK
signer и RSA public pin сохранены. Actual apply уже подтверждён на Windows и
Android emulator. Повреждённый кэш и облачный rollback обоих номеров приняты;
публичный Preview опубликован и прошёл независимый download/feed audit.

| Артефакт | Подтверждённое состояние |
|---|---|
| Android | APK/AAB C7; прежний cert `2a43…7093`, APK v2; 437 receipt records, 427 notices, 199 Shorebird notice files; fresh JVM 47 tests / 7 suites |
| Windows | 283 UI files из исходного cloud E8, source упаковки C7; 730 NSIS payload files, 199 Shorebird notice files; развитие service/helper не объявляется byte-equivalent старой установке |
| Общие проверки | Strict key/policy, APK/AAB AOT binding, pinned engine transform, JNI, notices, SBOM и filemaps приняты; обе базы физически скопированы в защищённый локальный backup с внешним SHA manifest |

Android после успешного первого upload завершён package-only recovery над
сохранёнными APK/AAB. Исходные gates runtime/notices/AOT/signature/identity/Maven/
Preview audit/source/filemaps сохранены; JVM взят из независимой свежей XML
сверки. Повторных Flutter build/upload для promotion не было.
[Подтверждённые hashes и происхождение](evidence/shorebird29-cloud-package-patch.json).

Подписанные beta-патчи source **`0d9fdf22`** содержат изменение доступности
заголовка Home и `uiRevision` 0→1; SemVer/build базы прежние. Guard принял только
три Dart/test файла, без native/assets overrides:

| Платформа | Patch number | Patch ID |
|---|---:|---:|
| Windows x64 | 1 | 731624 |
| Android arm64/x64 | 2 | 731631 |

Full перед QA-патчем: **12/12 PASS, 374 app tests, 235,6 с**, fingerprint
неизменен. Серверная проверка в одинаковом контексте Windows x64 и Android x64:
beta возвращает свой патч с проверенной RSA, stable не возвращает патч.
[Windows](evidence/shorebird29-server-channel-windows.json),
[Android](evidence/shorebird29-server-channel-android.json). Она не изменяла track
клиента и не выполняла update/restart. Отдельно проверен Android ARM64
[server-context/RSA](evidence/shorebird29-server-channel-android-arm64.json).

Реальный SDK после холодного запуска показал Windows current/next **1/1**,
Android **2/2**, `uiRevision=1`; базовые bytes и пользовательские данные сохранены.
[Actual apply](evidence/shorebird29-device-apply.json). **E6-012 подтверждён**.
Неизменяемый tag `v0.1.8` закреплён на C7.
[Публичный Preview](https://github.com/Extectick/ExVPN/releases/tag/v0.1.8) выпущен
workflow [39294754335](https://github.com/Extectick/ExVPN/actions/runs/39294754335)
на publisher source `ae4acee1` без rebuild. Все 18 скачанных assets, 17 checksum
records, 16 manifest rows, прежние APK/EXE/receipts и оба Ed25519 feed проверены.
[Аудит](evidence/release-v0.1.8.json).

На Android один байт cached AOT отвергнут при native проверке подписи, SDK
загрузил базу/ui0. Затем восстановлены оба SDK roots целиком, включая bytes,
modes, UID/GID, SELinux, pointers, tombstones и downloads; снова исполнен
patch2/ui1. После облачного rollback №2 Android и №1 Windows реальные SDK
вернулись к current/next=null и `uiRevision=0`. Подписки, оформление, UID и
базовые APK/EXE/AOT неизменны. Патчи №1/№2 отозваны намеренно после QA.
[Полный roundtrip](evidence/shorebird29-roundtrip.json),
[publisher gate](evidence/shorebird29-runtime-qa.json).
**E6-004, E6-012–014 и E7-013 приняты.**
Физический Android, E1, точный post-link SBOM, Windows Authenticode и стабильная
VPN-приёмка остаются открытыми.

Отдельное ограничение CI39278332213: Windows recovery принят, Android остановлен
до app build/upload в analyzer preflight: буквальные SDK aliases/file IDs
сохранены, analyzer exit0, но `expectedMetadataListed=false`. Вывод analyzer на
ephemeral runner не сохранился, точная причина неизвестна. Это не доказательство
отказа фактически собранного локального APK. Фактический локальный выпуск
использовал прежние SDK pins и strip-validation; повторного cloud upload не было.

Локальные patch-сборки сохраняют точные bytes assets своей базы. Два textassets
`assets/flags/countries.txt` и `assets/licenses/FlagIcons.txt` имеют CRLF в
принятой Windows-базе и LF в Android. Перед Windows patch выполнена только
эквивалентная newline-нормализация checkout к bytes базы с чистым Git/index;
перед Android восстановлен LF. `--allow-asset-diffs` не применялся. Из shared
build cache удалены только stale web-generated `AssetManifest.bin.json` и
`NOTICES`, не исходники. CI Android analyzer preflight остаётся отдельно
неподтверждённым: synthetic subprocess exit0 без ожидаемой metadata; точная
причина исходного отказа не установлена.

Принятые локальные базы переданы в CI без пересборки: import run
**39293255636**, artifact names `shorebird-base-{Android,Windows}-5bddc7770acd5446ca0c579857f9d1c7b2b1ada3`.
Независимый повторный download подтвердил исходные receipts, exact 438/288 files,
все filemap/binary hashes. Это `local_accepted_import`, **не CI compilation**;
Windows compiled E8 / packaging C7 и Android compiled C7 сохранены. Срок CI
хранения — 90 дней, до 2027-01-17T17:20:23Z; protected local backup остаётся.
[Import proof](evidence/shorebird29-ci-base-import.json). Временные draft/tag
удалены только после независимой сверки; immutable `v0.1.8` не менялся.
Будущие patch/publish используют этот `base_run_id` вместе с отдельными actual
runtime receipts. Для чтения draft понадобился ephemeral builtin token
`contents:write`; единственный import job выполнял только GET, без SDK, signing,
cloud release mutations или environment secrets.

Full точного patch source0d9f:12/12 PASS,374app tests,235,6с;
[receipt](evidence/shorebird29-accepted-patch-full.json). Компиляция AOT нужна и
при OTA; пользователю доставляется signed delta, не новый APK/EXE.


## Проект и клиент, 2026-10-17

Пользователь завершил вход в CLI. Проверка аккаунта подтвердила тариф **free**;
штатный `shorebird init --display-name ExVPN` создал один проект **ExVPN**.
`apps/exvpn/shorebird.yaml` содержит публичный app ID и `auto_update: false`;
ключи и учётные данные в репозиторий не добавлены. Повторный `doctor --json`
прошёл **6/6 validators**, все пять URL доступны; тот же результат подтверждён
из основного `V:/GitProjects/ExVPN/apps/exvpn`. [Доказательство](evidence/shorebird-project-doctor.json).
Первая попытка init в новой рабочей копии остановилась до создания проекта из-за
отсутствующих ignored Gradle wrapper files; использованы точные локальные копии
wrapper закреплённого проекта. APK ради init не пересобирался.

В **+15** подключён `shorebird_code_push 2.0.7` с точным archive hash в lock.
Экран «Версии и обновления» читает текущий и следующий патчи при открытии;
старт приложения не ждёт updater. Даже создание SDK, читающее синхронный engine
lock, выполняется вне UI isolate. Проверка сети и загрузка запускаются вручную.
Показаны отдельно доступное обновление, загруженный патч, откат к базе и ошибка
чтения. Недоступный обычный Flutter engine не считается базовым патчем 0.

Успешный `update()` сам по себе не доказывает загрузку: SDK также возвращает
успех, когда обновления нет или другой updater занят. UI сверяет `readNextPatch`.
После ошибки check/download старые сведения инвалидируются и перечитываются
локально: check мог уже запланировать rollback. Сырые ошибки SDK не выводятся.
SDK не даёт отменить операцию; спустя 30 секунд появляется пояснение, но busy
снимается только после её фактического завершения. Конкурирующей загрузки нет.

Канал задаётся при сборке `--dart-define=EXVPN_DART_UPDATE_TRACK=beta` либо
`stable` (по умолчанию). Иное значение отключает доставку, не переключает
незаметно на stable. Подписка и настройки пользователя этот параметр не меняют.
В обоих SDK-вызовах передаётся один канал. Это **ещё не доказательство изоляции
каналов**: Shorebird track switch не удаляет установленный патч другого track.
Базовые beta/stable-выпуски и переходы между ними требуют отдельной проверки.

В клиенте нет команды автоматического перезапуска/выхода/отключения VPN из
updater. Подготовленный патч применяется только при полном новом запуске
движка. Закрытие Windows-окна в трей таким запуском не является.

Проверены controller/SDK failures, rollback в базу и предыдущий номер,
повторные команды, disposal, долгий вызов, widget flows и узкий экран с крупным
текстом. Реальный adapter на обычном Flutter test engine подтвердил unavailable.
Эти проверки не заменяют release → signed patch → restart → rollback на
Android/Windows. Работа с публичным Shorebird runtime ещё не проверена.

После интеграции в основное рабочее дерево полный быстрый прогон прошёл
**11/11 наборов за 121,65 с**, включая **493 Dart/Flutter-теста** и Go-проверки
без result cache. Отпечаток исходников до/после совпал. Независимый review
16 файлов клиента не выявил замечаний. [Результаты +15](evidence/fast-validation-shorebird-build15.json).
GitHub CI для +15 также завершил обе native development сборки успешно:
[Android и Windows](evidence/ci-build15.json). Они используют обычный Flutter.

## Установка для пользователя, 2026-10-17

По новому запросу пользователя проверена существующая установка **1.6.129** и
добавлен её `bin` в пользовательский PATH. В новом PowerShell команда `shorebird`
доступна напрямую. Действующая политика `RemoteSigned` уже разрешала запуск;
политика выполнения и системный Git config не менялись.

Исправлены две конкретные проблемы установки:

- Вместо detached HEAD создана локальная ветка `codex/exvpn-1.6.129`, связанная
  с `origin/stable`. Commit и закреплённые хеши остались прежними; автоматического
  обновления исходников не было. Проверка актуальности в `doctor` теперь проходит.
- CLI добавлял лишние кавычки к пути `java.exe` с пробелами. Это воспроизведено
  отдельно; штатная `shorebird flutter config --jdk-dir` теперь указывает на
  существующий короткий путь того же Android Studio JBR. SHA-256 Java совпал,
  SDK не менялся; `doctor` теперь сообщает **Java 21.0.6**. Настройка `jdk-dir`
  относится к пользовательской конфигурации Flutter.

На этом промежуточном шаге `doctor --json`: **5 из 6 validators PASS**, все пять проверяемых URL
доступны, Gradle **9.3.1**. Единственный оставшийся validator — отсутствие
`shorebird.yaml` в assets. У пользователя уже есть аккаунт, но локальный OAuth
завершился тайм-аутом ожидания подтверждения в браузере. Проект ExVPN, release,
patch и ключи этой попыткой не создавались. После завершённого входа нужно
инициализировать именно `apps/exvpn`, затем повторить doctor. Старые результаты
ниже сохранены как история. [Текущая проверка](evidence/shorebird-user-install-doctor.json),
[официальная установка и вход](https://docs.shorebird.dev/getting-started/).

## Первоначальный preflight

2026-10-17: отдельно установлен и запущен официальный CLI **1.6.129**.
Команда `--version --json` завершилась с exit 0 и подтвердила закреплённые
Flutter/engine revisions. CLI lock-файл после bootstrap не изменился.
Это подготовка инструмента; **EXVPN-E6-004 остаётся открытым**.

`doctor --json` тоже вернул exit 0, но в его JSON два неуспешных validator:
проверка актуальности не поддерживает detached `HEAD`, а в приложении ещё нет
`shorebird.yaml`. Поэтому exit 0 здесь **не означает готовность release**.
Пять проверяемых служебных URL доступны; permission, отсутствие старого
`keepDebugSymbols`, Xcode setting и tracked locks прошли. Java version в этом
отчёте отсутствует. `doctor --fix`/`upgrade` не запускались; точный pin сохранён.
[Обезличенное доказательство](evidence/shorebird-cli-preflight.json).

## Закреплённые исходники

[`shorebird.lock.json`](../scripts/bootstrap/shorebird.lock.json) содержит
commit CLI, хеши entry point, dependency lock и лицензий, а также отдельные
Shorebird Flutter/engine commits. SDK находится в `.tools/shorebird-1.6.129`,
его Pub cache — в `.tools/cache/shorebird-pub`. Текущий SDK приложения
из `toolchain.lock.json` не заменяется. Одинаковый номер Flutter не означает
одинаковый engine или совместимость обычного APK с Dart-патчами.

Для воспроизведения используется официальный Git-репозиторий: создать новый
каталог из поля `cli.folder`, настроить в нём `core.autocrlf=false`, добавить
`cli.repository`, выполнить `fetch --depth 1 --no-tags origin <cli.revision>`
и `checkout --detach FETCH_HEAD`. До запуска сверить `HEAD`, SHA-256
`bin/shorebird.ps1` и `pubspec.lock` с lock-файлом. Не обновлять существующий
checkout автоматически и не переключаться на плавающую ветку.

Для работы `doctor` после проверки pin можно создать локальную
`codex/exvpn-1.6.129` на том же commit и указать `origin/stable` как upstream.
Обновление remote refs не обновляет рабочую копию. Перед release/patch снова
проверять точный commit/lock; `shorebird upgrade` требует отдельного пересмотра pin.

Из корня ExVPN в отдельном PowerShell-процессе:

```powershell
$env:PUB_CACHE = Join-Path (Get-Location) '.tools/cache/shorebird-pub'
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
& ./.tools/shorebird-1.6.129/bin/shorebird.ps1 --version --json
```

Первый запуск скачивает закреплённый Flutter/Dart и зависимости CLI. После него
повторно сверить lock и фактические revisions из JSON. Bootstrap upstream может
сообщить о новых версиях зависимостей: это не разрешение выполнять `upgrade`.
Предупреждение о `core.longpaths` не является основанием менять системный Git
config. Локальный запуск завершился успешно без такой настройки.

## Подготовка подписанной базы +16, 2026-10-17

Добавлен `scripts/release/shorebird-release.ps1 -Target Android|Windows`.
Он выполняет только официальный online `--dry-run`, без публикации в облако.
Проверяются точные checkout/lock/engine и готовый кеш CLI: холодный либо
устаревший кеш отклоняется до сборки, чтобы upstream bootstrap не запускал
неявные `git fetch` и `dart pub get`. App dependencies разрешаются offline с
`--enforce-lockfile`; исходный lock и updater policy сверяются после сборки.
Android затем использует штатный `--pub` при build: в закреплённом Flutter
именно он запускает release-генерацию plugin registrant. При `--no-pub`
первая AAB-сборка сохранила dev-only `integration_test` в Java и отказала;
между AAB и APK Shorebird снова генерирует обычные служебные файлы.
Поэтому ручное редактирование generated Java не применяется. Flutter может
повторно проверить зависимости через сеть; изменение lock вызывает отказ
до принятия артефакта. Windows сохраняет `--no-pub`.

База использует `beta`, `auto_update: false`, `patch_verification: strict` и
явный public key. Закрытый разбор исходного и упакованного YAML не принимает
дополнительный endpoint, неизвестные/повторные ключи, aliases и другие policy.
Упакованный public key должен совпадать с ожидаемым. Канал также входит в
Dart-код патча: beta-патч нельзя просто продвинуть в stable и объявить каналы
изолированными. Для будущей stable-базы нужен отдельный полный выпуск.

Однократно выполнен `scripts/release/prepare-signing.ps1`. Созданы отдельные
Android RSA-3072 PKCS12 и RSA-4096 для подписи Shorebird-патчей. Ключи находятся
в `.private/signing`, доступ ограничен текущим пользователем и SYSTEM.
Пароль Android и private key Shorebird защищены Windows DPAPI CurrentUser;
в Git входят только public PEM/certificate. Проверены расшифровка DPAPI,
подпись/проверка синтетического сообщения, отказ изменённого сообщения и ACL.
Повторный запуск не заменяет существующие ключи. DPAPI-файлы не являются
переносимой резервной копией: до стабильного выпуска требуется отдельное
защищённое резервирование и проверка восстановления. Windows Authenticode
certificate пока не подготовлен.

Для переносимого backup подготовлен локальный
[Export/Verify/Restore инструмент](SIGNING_BACKUP.md): стандартные PKCS#12 и
зашифрованный PKCS#8, проверка доверенных публичных идентичностей, восстановление
только в новый каталог. Реальные ключи этим инструментом ещё не экспортированы.

Gradle требует все четыре signing-параметра вместе; частичная конфигурация
запрещена, скрытого debug-signing для release нет. Новая Android release
идентичность отличается от прежних debug APK: их обновление поверх без
переустановки не обещается. Непрерывный upgrade проверяется отдельно между
пакетами, подписанными одним release-ключом.

Notices/seal/audit явно различают `ordinary` и `shorebird`, фиксируют фактические
engine/Dart hashes и соответствующие лицензии. Windows engine DLL должна
побайтно совпадать с закреплённым SDK. Для Android аудитор сам извлекает
закреплённый engine из SDK JAR, повторяет `llvm-strip --strip-unneeded` из
точно закреплённого NDK и сверяет результат с APK. Обе ABI +16 подтверждены;
подмена хеша оставляет engine неподтверждённым. `rawSdkBytesMatched=false`
сохраняется, итоговый метод — `verified_ndk_strip`. Неизвестное несовпадение
остаётся release blocker. Исторические build manifest и pre-build seal
не переписываются после появления нового checker: отдельный финальный аудит
ссылается на тот же неизменённый APK. Целевые проверки: 84 notices/runtime,
44 Android seal и 72 audit cases PASS. Исходники и запись доказательств: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).
Полный цикл release → patch →
restart → rollback этим результатом ещё не подтверждён. Настоящие Android
APK/AAB и Windows база +16 затем собраны закреплённым Shorebird CLI с
`--dry-run`; облачный release не создавался. Android APK успешно прошёл
`apksigner verify`, signer совпал с сохранённым public certificate; manifest
подтверждает `0.1.0+16`, minSdk 30 и две ABI. Для Windows независимо извлечены
и сверены 267 файлов NSIS payload, обе maintenance-программы и engine DLL.
Windows Authenticode отсутствует.
[Точные хеши и границы проверки](evidence/shorebird-base-build16.json).
Финальный Full +16 после изменения checker: **11/11 за 111,44 с**,
**493 Dart/Flutter-теста**, Go без result cache; fingerprint до/после совпал.
Отдельный review кеша CLI: 23/23 случая.
[Финальный результат](evidence/fast-validation-shorebird-build16-final.json),
[предыдущий прогон](evidence/fast-validation-shorebird-build16.json).
Финальный аудит APK сохраняет три blockers: Maven runtime inventory,
полный Dart/Flutter linker inventory и проверка лицензионных обязательств.
Windows дополнительно требует подпись и завершение development release gate.

Для следующего шага inventory добавлен явный `ordinary|shorebird` selector:
закреплённые SDK/CLI/engine проверяются до сбора, source/plugin paths должны
соответствовать выбранному SDK. Shorebird допускает только release/offline;
подготовка POM по прежней ordinary-policy отклоняется до создания файлов.
157 inventory и 106 runtime/notices fixtures PASS, оба настоящих SDK проверены
чтением. Сам граф зависимостей и связь с APK/AAB этим шагом не получены;
release blockers сохранены. [Доказательства](evidence/android-inventory-shorebird-selector.json),
[исходники 8908ca2](https://github.com/Extectick/ExVPN/commit/8908ca237124c7bdfca1f8661fa1ded077f5e7e8).

Из неизменённого AAB +16 отдельно прочитана встроенная AGP metadata:
52 Maven-координаты, 48 SHA-256 исходных AAR/JAR, 229 связей графа.
Все 48 хешей совпали с локальным кешем; четыре записи не содержат digest.
Схема из AGP 9.1.0 совпала с закреплённой официальной схемой, повторная
сериализация дала те же байты. Это основа будущей привязки inventory именно
к AAB по GAV+SHA, а не полный SBOM или проверка кода после R8. Отдельно
собранный APK не получает эту привязку по совпадению версии или текущих
промежуточных файлов. Сборки и сетевое разрешение зависимостей не запускались;
все release blockers сохранены. [Исследование AAB](evidence/android-aab-dependency-metadata-build16.json).

## Проверки установленной базы +16

Android API30 x86_64: проверены уже установленный подписанный release APK,
настоящий экран версий и повторный запуск после подтверждённого завершения
старого процесса. За 76,980 с, включая 6,530 с завершения стенда, UI дважды
показал сборку 16, базовый Dart-выпуск, канал beta и активную кнопку ручной
проверки. Root осмотрел [снимок после повторного запуска](evidence/android-shorebird16-versions.png).
Установка, очистка данных, проверка облака и VPN не запускались. UID/dataDir
совпали, настройки ОС не менялись; равенство содержимого private storage не
проверялось. Два предшествующих отказа стенда сохранены отдельно: разбор
CRCRLF в ответе emulator console и объединённых Flutter accessibility labels.
Они не считались ошибками продукта и не заменялись успешным результатом.
[Полный обезличенный результат Android](evidence/android-shorebird-base16-runtime.json):
368 файлов доказательств повторно сверены root, без расхождений.

2026-10-17, код базы [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f). Обычное обновление Windows
+13 → +16 в выделенном Sandbox завершилось успешно: полный payload, привязка
службы, исходная сеть и 19 прежних backup-копий сохранены, добавлена одна новая.
Запуск UI и настройки прошли, но следующий semantic-шаг превысил 15 секунд;
к моменту диагностики процесс UI уже отсутствовал. Код его завершения не был
сохранён, записей о crash в проверенном окне Application log нет. Причина
остаётся неизвестной; состояние updater и cold reopen этим запуском не
подтверждены. Исходный отказ cleanup сохранён, отдельная проверенная очистка
удалила только пять файлов своего стенда. Root сверил 112 файлов доказательств.
[Результаты первых попыток Windows](evidence/windows-shorebird-base16-first-attempts.json).

Повторный Windows-прогон удерживал исходный process handle непрерывно.
Экран действительно открылся: сохранены labels сборки 16, базового Dart-выпуска,
канала beta и активной кнопки проверки. Стенд ожидал другой MSAA role заголовка;
39 чтений дерева прошли без COM-ошибок, но predicate завершился отказом.
Затем cleanup guard отказал из-за изменившегося `Process.MainWindowHandle`,
хотя исходные main/Flutter HWND продолжали существовать и принадлежать тому же
процессу. UI остался жив после 300 с наблюдения; exit code не получен,
graceful exit и cold reopen не проверены. Это не доказательство crash.
Отдельный read-only postcheck за 58,468 с подтвердил неизменность payload,
службы, сети, пустого storage и 20 backup-копий. UI оставлен открытым,
два защищённых файла этого стенда сохранены; cleanup остаётся незавершённым.
Повторных UI-действий, принудительного завершения, VPN или облачных запросов
не было. [Результат наблюдения](evidence/windows-shorebird-base16-continuous-owner.json).
Скриншот не снимался; эти данные не являются визуальной приёмкой layout.

Последующие отдельные проверки +16, 2026-10-17:

- Существующий Windows UI завершился штатно с наблюдаемым кодом 0.
  Дальнейшая передача команды стенда получила sharing violation до запуска
  нового UI; весь тот прогон остался REFUSED. [Исходный частичный результат](evidence/windows-shorebird-base16-exit-partial.json).
- Новый single-generation прогон за **227,199 с** прошёл cold reopen,
  Settings → Versions, чтение base/beta и обычный Exit с подтверждением,
  удерживаемым process handle и кодом 0. Cleanup PASS: собственные receipts
  удалены, payload/служба/сеть/storage/20 backups сохранены. Меню открывалось
  адресным tray callback; настоящий жест Shell и layout не проверялись.
  [Результат Windows](evidence/windows-shorebird-base16-cold-exit.json).
- Тот же подписанный Android APK выполнил реальный VLESS/XHTTP/REALITY цикл
  за **107,256 с**: независимый UID подтвердил HTTPS200/204, VPN transport
  и смену внешнего IPv4. После обычного Disconnect исходный IP восстановился,
  service/активная VPN network отсутствовали, собственная группа удалена.
  Настройки ОС сохранены; выданное системное согласие на VPN оставлено.
  Гость остановлен после сетевой очистки; равенство private storage bytes
  не утверждается. [Android VPN](evidence/android-shorebird-provider-build16.json),
  [подключённый экран](evidence/android-shorebird16-provider-connected.png).

Root независимо сверил соответственно **85, 130 и 453** файла доказательств:
хеши и размеры совпали. Старые отказы не заменены успешными результатами.
Это проверки неизменных пакетов из [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f),
без cloud release/patch. Android IPv6, DNS leaks, exclusions/fault/lockdown
в последнем прогоне не проверялись; физическое устройство и E1/E6 открыты.

Даже успешное отображение «Базовый выпуск» подтверждает лишь локальное
поведение UI. Native-функции current/next закреплённого updater возвращают
`0` и при внутренней ошибке чтения; наличие FFI-символов не доказывает успешную
инициализацию updater. Поэтому такие проверки не закрывают native configuration,
проверку подписи, доставку или rollback.
[Закреплённый C API](https://github.com/shorebirdtech/updater/blob/70ff1e336798474e39586d3f5ac2ca386ef32d9e/library/src/c_api/dart.rs#L65).

## Базы +17, 2026-10-17

Собраны Android AAB/APK и Windows NSIS с `exvpn.5` и новым поиском исключений.
APK подписан тем же release-сертификатом, что +16; Windows остаётся unsigned
development. В обоих пакетах проверены `auto_update=false`, обязательная
подпись патча и точный public key. Android engine связан с закреплённым SDK
через проверенное удаление отладочной информации NDK, Windows engine совпал
байт-в-байт. Это проверка содержимого, не инициализации native updater.

Root независимо сверил 26 файлов package evidence и 20 файлов native evidence.
Оба аудита вернули exit 2: Android сохраняет три blocker по inventory/лицензиям;
Windows — пять, включая подпись издателя. Выбор платной подписи отложен
пользователем. Облачный release/patch не публиковался.
[Пакеты](evidence/packages-build17.json), [native](evidence/native-build17.json).
Исходники: [2cd1f71](https://github.com/Extectick/ExVPN/commit/2cd1f71404d4516ad22312d8722f98ef4867eda3).

Отдельное offline-чтение AAB +17 заняло 8,339 с: 52 библиотеки, 48 совпавших
хешей входных AAR/JAR и четыре записи без producer digest. Root перепроверил
57 входов и восемь файлов результата. Это не связывает отдельно собранный APK
с Maven-графом и не закрывает лицензионные обязательства.
[AAB metadata](evidence/android-aab-metadata-build17.json).

## Оставшиеся ограничения после 0.1.8

- Физический Android и E1: настоящий VPN/security acceptance не заменён OTA QA.
- Точный post-link состав Rust/SBOM и stable audit остаются отдельными gates;
  принятые packages содержат закреплённый консервативный комплект notices.
- Windows Authenticode отложен пользователем, пакеты публикуются как Preview.
- Hosted Android analyzer preflight CI39278332213 не принят: исходный отказ
  не воспроизведён, дополнительная диагностика остановлена до сборок. Реальные
  локальные signed release/patch/rollback проверены; CI import не называется сборкой.
- Перед следующим CI patch использовать `base_run_id=39293255636`, C7 и ту же
  версию0.1.8+29. Артефакты Actions истекают2027-01-17; защищённые локальные
  базовые receipts/patch-inputs сохранены и допускают повторный hash-bound import.
- Native/plugins/engine/permissions/assets обновляются полным пакетом. Перезапуск
  интерфейса не выполняется автоматически при активном VPN.
