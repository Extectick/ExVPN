# Shorebird: подготовка Dart OTA

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

Даже успешное отображение «Базовый выпуск» подтверждает лишь локальное
поведение UI. Native-функции current/next закреплённого updater возвращают
`0` и при внутренней ошибке чтения; наличие FFI-символов не доказывает успешную
инициализацию updater. Поэтому такие проверки не закрывают native configuration,
проверку подписи, доставку или rollback.
[Закреплённый C API](https://github.com/shorebirdtech/updater/blob/70ff1e336798474e39586d3f5ac2ca386ef32d9e/library/src/c_api/dart.rs#L65).

## Оставшаяся интеграция

Проект ExVPN привязан, доступ и локальные ключи подготовлены. Облачные релизы
и патчи ещё не созданы. Обычные development APK/Windows-пакеты ExVPN
не принимают Dart OTA; наличие updater package этого не меняет.

Дальнейший порядок:

1. Завершить полный native/linker и Maven inventory и проверку лицензионных
   обязательств. Хеши нового engine, payload, notices и build/version уже
   связаны с точными пакетами +16; обычный Flutter binary переиспользовать нельзя.
2. Сохранить и проверить резервную копию отдельной пары RSA для патчей. При `shorebird release`
   обязательно передать `--public-key-path`; при `shorebird patch` —
   соответствующий `--private-key-path`. Это отдельные ключи от Ed25519 данных,
   подписи APK и Windows Authenticode.
3. Установить полный подписанный beta-пакет, затем проверить подписанный
   Dart hotfix на Android и Windows. Отказ неправильной/отсутствующей подписи,
   изоляция каналов и rollback должны подтверждаться работающим приложением.
4. Не применять перезапуск автоматически при активном VPN. Изменения Go,
   Kotlin, C++, plugins, разрешений и Flutter engine доставлять полным пакетом.
5. Проверить реализованный экран фактической идентичности патча на целевых
   Android/Windows пакетах; unit/widget tests не подтверждают engine runtime.

`release --dry-run` также требует проекта/учётных данных и не считается
офлайн-проверкой без обращения к сервису. Подготовка CLI не подтверждает
воспроизводимость будущего Shorebird-пакета, его notices или магазинную приёмку.

Источники: [закреплённый CLI](https://github.com/shorebirdtech/shorebird/tree/9fe1370bdd1d2f117cc08c57ae416b794ed92440),
[подпись патчей](https://docs.shorebird.dev/code-push/guides/patch-signing/).
