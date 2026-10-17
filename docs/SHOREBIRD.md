# Shorebird: подготовка Dart OTA

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

Для реального цикла нужны доступ к проекту ExVPN в Shorebird, отдельный ключ
подписи патчей и первый полный пакет с Shorebird engine. Облачный проект,
релизы, патчи и ключи на этапе подготовки не создавались. Обычные development
APK/Windows-пакеты ExVPN ещё не принимают Dart OTA.

Дальнейший порядок:

1. Привязать подтверждённый проект ExVPN, зафиксировать `shorebird.yaml` и
   dependency lock используемого updater package; секреты остаются вне Git.
2. Подготовить отдельную пару RSA PEM для патчей. При `shorebird release`
   обязательно передать `--public-key-path`; при `shorebird patch` —
   соответствующий `--private-key-path`. Это отдельные ключи от Ed25519 данных,
   подписи APK и Windows Authenticode.
3. Установить полный подписанный beta-пакет, затем проверить подписанный
   Dart hotfix на Android и Windows. Отказ неправильной/отсутствующей подписи,
   изоляция каналов и rollback должны подтверждаться работающим приложением.
4. Не применять перезапуск автоматически при активном VPN. Изменения Go,
   Kotlin, C++, plugins, разрешений и Flutter engine доставлять полным пакетом.
5. Показать фактическую идентичность Dart patch независимо от app/build,
   core и data revision. Недоступный updater не выдаёт вымышленный patch 0.

`release --dry-run` также требует проекта/учётных данных и не считается
офлайн-проверкой без обращения к сервису. Подготовка CLI не подтверждает
воспроизводимость будущего Shorebird-пакета, его notices или магазинную приёмку.

Источники: [закреплённый CLI](https://github.com/shorebirdtech/shorebird/tree/9fe1370bdd1d2f117cc08c57ae416b794ed92440),
[подпись патчей](https://docs.shorebird.dev/code-push/guides/patch-signing/).
