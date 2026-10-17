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

Последний `doctor --json`: **5 из 6 validators PASS**, все пять проверяемых URL
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

## Оставшаяся интеграция

Проект ExVPN привязан, доступ подтверждён. Для реального цикла остаются отдельный
ключ подписи патчей и первый полный пакет с Shorebird engine. Релизы, патчи и
ключи ещё не создавались. Обычные development APK/Windows-пакеты ExVPN
не принимают Dart OTA; наличие updater package этого не меняет.

Дальнейший порядок:

1. Проверить release tooling для отдельного Shorebird engine: полный native
   payload, notices, build/version и корректный channel должны быть связаны
   с точным новым пакетом; обычный Flutter binary переиспользовать нельзя.
2. Подготовить отдельную пару RSA PEM для патчей. При `shorebird release`
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
