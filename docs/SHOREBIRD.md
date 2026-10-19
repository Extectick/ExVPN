# Shorebird: подготовка Dart OTA

## Реальный цикл 0.1.8+29, 2026-10-19 — в работе

Пользователь поручил выпустить настоящую Android/Windows базу, подписанный
Dart-патч и проверить откат. Версия базы — **0.1.8+29 / beta**. CLI 1.6.129,
Flutter 5bef02a, engine 4b936a0 и существующие APK/RSA ключи сохраняются.
Будущие совместимые Dart/UI изменения должны проходить patch workflow;
native/assets/plugins/engine изменения требуют нового полного базового пакета.

OAuth CLI подтверждён, тариф free, overage=0. Через официальный OpenAPI и
`shorebird api` создана служебная учётная запись роли `developer`; её ключ
действителен до 2027-10-19 и сохранён через `gh` в protected environment
`demo-release` как `SHOREBIRD_TOKEN`. Там же сохранён существующий RSA patch key
после проверки против public pin. Локальная резервная копия CI token защищена
DPAPI и ACL; значения ключей/учётные данные в Git не входят. Платный план
и новые signing identities не создавались.

Android QA владеет только emulator-5582; Windows QA — установленным ExVPN.
Сетевая VPN-матрица не повторяется. Решающий OTA gate: неизменные bytes
APK/EXE/base + реальные current/next номера SDK + Dart `uiRevision` 0→1→0
после холодного запуска. Нулевой/base snapshot сам по себе не доказывает
здоровую native-конфигурацию updater. Реальная облачная публикация и
runtime-приёмка пока не выполнены; EXVPN-E6-004 остаётся открыт.

Подготовка принята 2026-10-19: final Full **12/12 PASS за 120,30 с**,
373 app tests, source fingerprint неизменен.
[Full](evidence/fast-validation-shorebird28.json),
[pipeline guards](evidence/shorebird28-pipeline.json),
[runtime notices closure](evidence/shorebird28-notice-closure.json).
Первый Full выявил устаревший список suite dispatch (25 вместо29) после
добавления OTA-проверок; список расширен без удаления прежних наборов.
Подготовлены отдельные `shorebird.yml` (base/patch/rollback) и
`shorebird-publish.yml` (публикация тех же bytes после реальной приёмки).
Патч сохраняет версию базы, требует чистый Git и только допустимые Dart-изменения;
изменения native/assets/dependencies отклоняются. Оба фактических номера патчей
проверяются перед откатом. CI сохраняет обезличенную cloud recovery-квитанцию
даже при последующей ошибке упаковки; повтор требует readback.

Попытка base CI39239871468 (`0b45f9c`, source tag `v0.1.7`) отказала до
native/package build и cloud registration. Причина воспроизведена локальным
prepare без сборки приложения: CLI1.6.129 не поддерживает `shorebird flutter
precache`. Нужно вызвать `flutter.bat precache` из строго закреплённого SDK.
Тег не перемещается; подготовка исправляется для **0.1.8+29**. Реальные пакеты
или патчи 0.1.7 в этом цикле не опубликованы.
[Фактический отказ CI и локальное воспроизведение](evidence/shorebird28-sdk-prepare-failure.json).

Исправленный prepare фактически выполнен последовательно для Windows и Android:
оба `ready/complete`, CLI/Flutter/engine pins совпали. Приложение не собиралось,
cloud API не вызывался. [Проверка SDK](evidence/shorebird29-sdk-prepare.json),
[101 targeted guards](evidence/shorebird29-prepare-guards.json). Публичный отчёт
CI теперь содержит только фиксированные phase/errorCode; raw diagnostics остаются
приватными. Тег 0.1.8 создаётся после успешной сборки и аудита базы.

Итоговый Full для исправленной 0.1.8+29: **12/12 PASS за 126,30 с**,
373 app tests, source fingerprint неизменен.
[Отчёт](evidence/fast-validation-shorebird29.json). Нативная сетевая приёмка
не повторялась. Android +26 сохранён opaque backup на принадлежащем QA emulator;
Windows +27 штатно вышел через tray/Dart flush, служба сохранена. Проверенная
смена темы и возврат доказали обычный Roaming namespace; shadow не переносится.

Base run39242872001 отказал ещё до SDK: оба runner получили101 PASS, но
test script оставил LASTEXITCODE от намеренно ошибочного внешнего fixture.
Исправлены только success-exit двух тестовых драйверов; фактическая Actions
обёртка теперь даёт0 при101+34 PASS, а проваленный assertion по-прежнему1.
[Проверка](evidence/shorebird29-actions-exit.json). SDK/package/cloud в этом run
не запускались, версия0.1.8+29 ещё не занята. Состав и поведение продукта
не менялись; уже пройденный Full не повторялся ради exit-state драйвера.

Base run39243607109 (`265c3f0`) прошёл Checks, SDK preparation и native build,
но release guard отказал из-за изменённого checkout до сборки UI и обращения
к cloud registration. Причина изменения пока не установлена. Добавлены ранние
clean gates и ограниченная публичная квитанция с относительными путями/хешами;
отказ при грязном дереве сохраняется. Отдельная операция `diagnose` запускает
только Windows Checks без Shorebird SDK, native build, signing или публикации.
123 targeted synthetic checks через Actions harness дали exit0; Full и native
сборки для этой диагностики не повторялись.
[Проверка guard и диагностического режима](evidence/shorebird29-source-diagnosis.json).

Свежий локальный fixture точного дерева265c3f0 воспроизвёл изменение шести
generated plugin registrant/CMake файлов Linux/Windows сразу после обычного
Flutter `pub get`. Исходные blob и результат имеют одинаковый код; меняются
CRLF→LF, `git diff` пуст, но `status` остаётся M. Для этих шести точных путей
закреплён `text eol=lf`. Контрольная fresh checkout→pub get воспроизводит отказ;
после attrs тот же цикл чистый, raw SHA-256 файлов не изменился. Ничего не
добавлялось в ignore, release guard не ослаблен. Новые тесты приложения или
native сборки не запускались ради изменения формата checkout.
[Контроль и исправление](evidence/shorebird29-eol-fix.json).

CI diagnose39246721973 независимо подтвердил ровно эти шесть файлов
([квитанция](evidence/shorebird29-ci-source-receipt.json)); последующий
base39247684410 прошёл clean gates обеих платформ. Windows был собран и
зарегистрирован как release908884, затем package audit отказал; Android
остановился в notice collector до вызова release. Причина: inventory требует
raw SHA60089d1c crate-pin JSON, а Git хранил нормализованный blob2a19db06.
Для этого единственного checksum-pinned файла закреплены исходные raw bytes
через `-text`; `-whitespace` отключает только style-предупреждения о его CRLF.
SHA и содержание JSON остаются строго проверяемыми, зависимости не меняются.
Fresh commit/archive/checkout и offline source notice validation двух платформ
прошли. [Проверка байтов](evidence/shorebird29-cratepin-eol.json).

Облачный Windows release прочитан обратно, его win_archive4043762 скачан и
проверен по hash/size; 283 извлечённых файла побайтно совпали с архивом.
Повторная сборка/загрузка UI не выполняется. Подготавливается explicit recovery
упаковки: отдельный compiledSourceCommit=e8cba9f и новый sourceCommit упаковки,
с отказом при любых различиях компилируемых исходников, SDK, ключей или assets.
Доставка пользователям, signed patch и runtime rollback пока не подтверждены.
[Фактический отказ и восстановление исходных bytes](evidence/shorebird29-packaging-recovery.json).

Recovery implementation source freeze прошёл targeted guards: 192 pipeline,
34 publication,177+43 notice inputs,220 runtime notice,41 Maven; parse и
Actions child exit0. Общий Full затем прошёл **12/12 за140,41с**, без изменения
source fingerprint. [Guards](evidence/shorebird29-recovery-guards.json),
[Full](evidence/fast-validation-shorebird29-recovery.json). Review cold-cache
пути потребовал отдельного locked app dependency resolve перед offline wrapper;
это CI preparation, повторная полная проверка продукта для него не требуется.

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

## Оставшаяся интеграция

Для native updater отдельно сохранён exact Cargo.lock inventory:
257 registry crates и 3 workspace nodes. Это консервативный исходный набор,
а не список доказанно слинкованных зависимостей. Все три engine +16 содержат
один Rust source marker; подходящий source найден, установленный локальный
Rust другой версии для notices не использован. Полные crate notices и Rust
runtime aggregate остаются открытыми.
[Source inventory и границы](evidence/shorebird-updater-source-inventory.json).

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
