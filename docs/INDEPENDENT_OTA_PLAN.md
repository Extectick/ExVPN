# Независимые обновления ExVPN

2026-10-20. Целевая миграция: **0.1.10+31 Preview**. План принят к реализации
по запросу пользователя; отметки означают проверенные результаты, не намерения.

## Решение

Сохраняем закреплённые Flutter/SDK/updater, строгую RSA4096-проверку
AOT и существующие подписанные APK/EXE обновления. Убираем зависимость доставки
и выпуска Dart-патчей от аккаунта, API и квот Shorebird Cloud. Собственный Flutter
движок не пишем. Это наш совместимый адаптер, не официальный self-host Shorebird.

Независима **доставка от Cloud/API/аккаунта**, а не весь toolchain. Dart SDK fork
Shorebird остаётся закрытым и используется как закреплённый prebuilt-компилятор;
CLI/updater и части engine открыты. Нельзя обещать полную воспроизводимость
сборки runtime из публичных исходников. Перед публикацией проверяются условия
распространения именно используемых бинарников, закреплённый SDK сохраняется
для следующих сборок. [Официальная архитектура](https://docs.shorebird.dev/code-push/system-architecture/).

| Вариант | Вывод |
|---|---|
| Shorebird Cloud | Уже работает, но сохраняет облачную зависимость и прежний цикл CLI |
| Velopack / WinSparkle | Не решают Android; требуют миграции Windows-службы/упаковки |
| APK/EXE binary delta | Ускоряет передачу, не устраняет AOT/Gradle/CMake для UI |
| Новый интерпретатор или Flutter engine | Слишком большая область безопасности и сопровождения |
| Открытый pinned updater + свой подписанный каталог и локальный адаптер | Выбран: бесплатно, без отдельного сервера, прежняя проверка исполняемого AOT |

Каталог и неизменяемые патчи хранятся в GitHub Releases. GitHub можно заменить
другим доверенным HTTPS-хранилищем через новый базовый выпуск; произвольные
адреса подписок никогда не становятся источниками обновлений.

## Контракт безопасности

- Каталог: Ed25519, отдельный domain `ExVPN/dart-update/v1\0`, pinned key,
  canonical JSON, срок, возрастающая revision, app/base/engine/compatibility,
  platform/ABI/channel, полные размеры и SHA256 патча, cumulative withdrawal.
- Патч: открытый pinned patch.exe создаёт binary diff; RSA PKCS1/SHA256 над
  ASCII lowercase SHA256 полного нового AOT. Native updater проверяет подпись
  восстановленного кода; подпись каталога не заменяет эту проверку.
- Dart-адаптер держит **127.0.0.1:57791, shared=false** весь срок процесса.
  Только известные POST check/events и проверенный binary GET. До успешного
  bind и проверки каталога SDK network operation запрещена. Занятый порт
  отключает только Dart OTA. Автоматические engine checks выключены.
- SDK вызывается в отдельном isolate, операции сериализованы. После timeout
  порт не освобождается для позднего FFI; дальнейшие OTA calls блокируются.
- Native startup добавляет loopback в process-only NO_PROXY/no_proxy, сохраняя
  остальные значения. Системный proxy/firewall/DNS не меняется.
- Скачанный diff ограничен по размеру и проверен до выдачи SDK; подписанное
  состояние каталога сохраняется до разрешающего ответа. Неверные подписи,
  replay, equivocation и отменённый номер не активируются.
- API events принимает только ограниченный запрос и отбрасывает его; random
  client ID не сохраняется и не отправляется в облачную аналитику. При раннем
  старте patched engine возможна локальная events-попытка до Dart bind.

## Быстрые сборки

UI-патч: pinned kernel + gen_snapshot для нужного ABI, без Gradle, CMake,
JNI/service build или cloud CLI. Native/assets/plugins/dependencies/engine и
SemVer/build должны совпасть с принятой базой; иначе требуется новый APK/EXE.
JNI и Windows service используют content-addressed кэш завершённых результатов:
источники, Go/NDK, checksums/pins, ABI и flags; повторное использование только
после сверки хешей файлов. Изменение версии интерфейса само по себе не требует
повторной компиляции неизменного VPN-ядра.

Android native-код остаётся внутри подписанного APK с системной установкой.
Windows privileged maintenance остаётся в проверенном installer/handoff.
Скрытой загрузки новых native executable из writable app data не вводим.

## Проверяемые этапы

- [ ] Строгий каталог, replay/withdrawal и локальный protocol adapter.
- [ ] Ранняя native NO_PROXY и кэш JNI/service с проверкой результата.
- [ ] Локальные AOT-only build/sign/withdraw commands без Shorebird API.
- [ ] Одна новая подписанная база обеих платформ со всеми текущими UI-правками.
- [ ] Реальный independent patch → cold launch → withdrawal → cold rollback
  на Android-эмуляторе и Windows Sandbox, сохранение данных и байтов базы.
- [ ] Публичные пакеты и собственные feeds проверены скачиванием/подписями.

Полные ранее принятые VPN-матрицы повторно не запускаются без изменения
затрагиваемой логики. Новые native-настройки Kill Switch требуют отдельного
ограниченного smoke. E1, физический Android, native IPv6 underlay и Windows
Authenticode остаются отдельными критериями стабильного выпуска.

## Первичные источники

- [FAQ Shorebird: unsupported self-host](https://docs.shorebird.dev/code-push/faq/).
- [Pinned updater config](https://github.com/shorebirdtech/updater/blob/70ff1e336798474e39586d3f5ac2ca386ef32d9e/library/src/config.rs).
- [Pinned network protocol](https://github.com/shorebirdtech/updater/blob/70ff1e336798474e39586d3f5ac2ca386ef32d9e/library/src/network.rs).
- [Pinned patch tool](https://github.com/shorebirdtech/updater/blob/70ff1e336798474e39586d3f5ac2ca386ef32d9e/patch/src/main.rs).
- [Pinned signer](https://github.com/shorebirdtech/shorebird/blob/9fe1370bdd1d2f117cc08c57ae416b794ed92440/packages/shorebird_cli/lib/src/code_signer.dart).
- [Android native executable restrictions](https://developer.android.com/about/versions/10/behavior-changes-10).
