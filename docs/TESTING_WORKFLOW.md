# Быстрый цикл разработки и проверки ExVPN

Из корня проекта в PowerShell 7:

```powershell
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Changed
```

Команда сама выбирает затронутые наборы тестов, запускает до трёх независимых
процессов и записывает длительности, exit codes и итог в
`artifacts/qa/fast-<timestamp>-<id>/summary.json`. Рядом лежит отдельный `.log`
каждого набора. Любая ошибка, timeout или изменение исходников во время прогона
даёт ненулевой exit code; успешные остальные наборы не скрывают отказ.

Это быстрые поведенческие проверки: анализ Dart/Flutter, unit/widget tests,
Go unit/loopback tests и файловые сценарии установщика с mock SCM/ACL. Они не
запускают установленный VPN, службу, TUN, WFP или смену маршрутов/DNS хоста.
Приватные подписки и действующие VPN-серверы в них не участвуют.

## Режимы

```powershell
# Только показать выбор; тесты и toolchain не запускаются.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Changed -PlanOnly

# Изменения ветки относительно общей базы плюс весь текущий working tree.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Changed -BaseRef origin/main

# Все быстрые наборы, Go test-result cache отключён (-count=1).
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Full

# Меньше одновременных процессов на маломощной машине.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Changed -MaxParallel 2 -TestConcurrency 2

# Один раз после bootstrap при отсутствии dependency packages в локальном кеше.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Full -OnlineDependencies

# При изменении жизненного цикла транспорта — отдельная проверка гонок.
pwsh -NoProfile -File scripts/qa/test-xray-lifecycle.ps1 -Race -Count 5
```

Без аргументов действует `-Changed`. Он объединяет **отдельные staged и unstaged
diff**, новые неигнорируемые файлы, удаления и обе стороны переименования.
`-BaseRef` дополнительно включает committed diff от merge-base до HEAD; base
сначала разрешается в commit, не передаётся как произвольная опция Git.
Чистое дерево или только документация дают `no-code-checks-required`, а не
утверждение, что все тесты прошли. После commit без `-BaseRef` для полного
подтверждения нужен `-Full`.

| Изменение | Автоматически проверяется |
|---|---|
| `packages/exvpn_domain` или `native/core` | domain, state, Flutter app, core, оба native adapter и installer fixtures |
| `native/patches` | Xray lifecycle, затем те же потребители, что для native core |
| `packages/exvpn_client_state` | state и Flutter app |
| `packages/exvpn_updates` | updates и Flutter app |
| `apps/exvpn/lib`, тесты и assets | Flutter app |
| Android Kotlin/Gradle или `native/android` | Go Android adapter и Flutter app; JNI/JVM/APK остаются отдельным gate |
| Windows C++/CMake или `native/windows` | Go Windows adapter, Flutter app, installer fixtures; native/UI build остаётся отдельным gate |
| Toolchain, CI, scripts, неизвестный новый путь | Все быстрые наборы, включая проверку PowerShell syntax и планировщика |
| Только известные документы/изображения в `docs`/`design` | Кодовые наборы не нужны; визуальная/документальная проверка остаётся отдельной |

## Откуда берётся ускорение

- Независимые наборы выполняются параллельно в отдельных `pwsh` process. Каждый
  имеет свою рабочую директорию; по умолчанию три процесса × два test workers,
  чтобы несколько Go/Dart раннеров не запускали по числу всех CPU одновременно.
- Используются уже установленные, точно закреплённые Flutter/Dart/Go. Pins и
  совпадение app version/build проверяются перед запуском.
- Сохраняются штатные Go build/test caches. В `-Changed` успешный неизменённый
  Go package может сообщить `(cached)`, в `-Full` его тесты выполняются заново.
  Dart/Flutter tests всегда запускаются; готовый APK/EXE никогда не подставляется
  вместо проверки изменённых исходников.
- Pure Dart lanes используют bundled `dart.exe` напрямую, избегая лишнего
  Flutter startup lock. Dependency resolution по умолчанию `--offline` с
  `--enforce-lockfile`; изменять версии или lock-файлы раннеру не разрешено.
- До/после прогона вычисляется SHA-256 tracked и неигнорируемых untracked файлов.
  При параллельном редактировании результат помечается `source-changed-during-run`:
  финальную проверку запускают после завершения записи агентами.

Xray lifecycle — десятый быстрый набор: тесты из точно закреплённого исходного
ZIP проверяют закрытие gRPC/XHTTP, активные и зависшие запросы, повторные поколения
и конкурентный Dial/Close. В scripts lane также проверяются реконструкция ZIP,
отказ при подмене и сохранение offline при повторном входе в окружение.
Race detector запускается отдельно и в Windows CI; первый запуск скачивает
проверенный по SHA-256 portable w64devkit в `.tools/`, без изменения PATH машины.
Он не используется для production JNI/EXE. [Точные исходники и pin](../native/patches/README.md).

Нового task framework, собственной системы кэширования сборок или плавающих
dependencies нет. Используются готовые команды [`go test`](https://pkg.go.dev/cmd/go#hdr-Test_packages),
[`dart test`](https://dart.dev/tools/dart-test) и Flutter test. Go определяет
валидность своего кеша по входам компиляции/теста; результаты runtime-проверок
VPN из прошлого сеанса таким кешем не считаются.

## Полный gate сохраняется

`-Full` означает **все быстрые наборы**, а не готовый выпуск. Перед пакетом/приёмкой
остаются существующие независимые команды:

```powershell
pwsh -NoProfile -File scripts/ci/verify.ps1 -Target Android
pwsh -NoProfile -File scripts/ci/verify.ps1 -Target Windows
```

CI продолжает делать clean-checkout анализ/тесты, обе JNI ABI, APK/JVM tests и
Windows UI/service build. Нативные функции, Kotlin/C++, TUN, IPv4/IPv6/DNS,
исключения, crash/lockdown, обновление, удаление и подпись не закрываются быстрым
прогоном. Для них используются [Windows CLI Sandbox](WINDOWS_AUTOMATED_QA.md),
[Android ADB/emulator](ANDROID_VALIDATION.md), [provider matrix](PROVIDER_COMPATIBILITY.md)
и физическое устройство по `CHECKLIST.md`.

При работе нескольких агентов каждому назначается своя область файлов.
Изменение общего контракта сначала согласуется между владельцами domain/core/UI.
Один координатор запускает итоговый общий прогон. За каждым эмулятором/Sandbox
отвечает один агент; Windows и Android можно проверять параллельно. Агенты
могут запускать собственные unit tests; одновременно
менять общий стенд, устанавливать разные сборки или запускать native UI build
в одной build-директории нельзя.

Регрессии выбора проверяет `scripts/qa/test-fast-validation-plan.ps1`:
dependency closure, неизвестные пути, реальные staged/unstaged/untracked/delete/
rename Git-сценарии, Unicode, BaseRef и выявление изменения нового исходника.
Fixture создаётся только в игнорируемом `artifacts/qa`; index проекта не меняется.
`test-fast-validation-runner.ps1` запускает настоящий координатор с синтетическими
workers в отдельном fixture: exit 7 одного child и запись исходника во время
прогона должны дать разные ошибочные результаты и ненулевой exit code.
В `scripts` также входят 24 синтетические JVM-проверки парсера IPv4 независимого
Android QA-probe и 14 проверок UTF-8/размера/хеша быстрого ввода; сеть и
установленный VPN для них не используются.

Длинные Android-подписки в стенде вводятся готовым API `ACTION_SET_TEXT` вместо
тысяч событий `adb input text`. Отдельный QA APK проверяет package/focus и точный
readback длины/SHA-256; production APK не получает тестовых hooks. Ввод идёт из
`.private/` через ADB stdin, не через аргументы команды или системный clipboard.
[Команда и ограничения](../scripts/qa/android-https-probe/README.md#fast-focused-text-input).

## Первые измерения, 2026-10-17

После исправления повторного использования Sandbox и Windows CRLF fixture
`-Full` прошёл за 71,91 с. Review затем обнаружил ошибку каталога диагностики
при неверном marker: исправлена публикация пути только после проверки, добавлена
регрессия. Итоговый `-Full` прошёл за **73,70 с**: десять наборов, Go `-count=1`,
одинаковый fingerprint до/после. Windows helpers расширены до 78 проверок;
исходники production APK/установщика не менялись.
[Итоговый отчёт](evidence/fast-validation-build11-qa-final.json).
CI отдельно выявил CRLF в valid synthetic patch here-string; нормализован только
этот пример, 61 проверка прошла и при разборе LF, и при разборе CRLF исходника.
[Проверка](evidence/xray-patch-crlf-build11.json), [первый CI отказ](evidence/ci-build11-first-failure.json).

Для +11 расширенный `-Full` содержит **10 наборов** и прошёл за **70,74 с**:
192 domain, 46 state, 31 updates, 156 Flutter tests, Go verify/test/vet,
26 upstream lifecycle test functions, installer/tooling fixtures. Go test-result
cache отключён, source fingerprint до/после совпал.
[Обезличенный отчёт](evidence/fast-validation-build11.json).
Отдельный race ×5 прошёл для четырёх пакетов изменённого Xray.
Новый объём включает реконструкцию и отказы source proxy, поэтому цифра не
сравнивается как ускорение с более коротким набором +10.

Windows lifecycle driver — `scripts/qa/run-windows-transport-lifecycle.ps1`:
готовый Flutter integration runner выполняет циклы в одном UI/SCM процессе,
CLI Sandbox наблюдает очистку TUN/WFP/DNS/routes и завершение peer sockets.
Android использует отдельный ADB/probe driver и
`scripts/qa/android-lifecycle-tools.ps1`. 78 Windows и 19 Android синтетических
проверок этих helpers входят в `scripts` и CI; они сами не запускают VPN.
Результаты настоящих циклов привязываются к хешу APK/установщика отдельно.

Windows lifecycle повторно использует одну writable mapping, проверенную
nonce read/write challenge; каждый запуск пишет в собственную папку runId.
Готовая reservation допускает upgrade перед запуском, но начатые/завершённые
результаты нельзя перезаписать. Это устраняет необходимость пересоздавать
Sandbox из-за запрета CLI переназначать существующую writable mapping.
[Порядок запуска](WINDOWS_AUTOMATED_QA.md#повторные-подключения-grpcxhttp).

Android +11 выполнил шесть циклов gRPC/XHTTP за 181,99 с суммарно, включая
проверку независимым HTTPS probe и очистку после каждого отключения.
Ввод двух synthetic profiles занял 417 мс с проверкой точного readback.
[Runtime evidence](evidence/android-lifecycle-build11.json).

Два последовательных `-Changed` на одном неизменном рабочем дереве выбрали все
девять наборов, потому что добавлялись сами QA-скрипты. Оба завершились PASS:

| Прогон | Реальное время | Сумма времени отдельных процессов | Go packages из test cache |
|---|---:|---:|---:|
| Первый | 78,08 с | 196,18 с | 0 |
| Повтор на том же дереве | 24,54 с | 44,68 с | 4 |

Проверены 191 domain, 43 state, 31 updates и 155 Flutter tests, анализ,
verify/test/vet трёх Go-модулей, installer fixtures и 26 planner regressions.
Число workers: `MaxParallel=3`, `TestConcurrency=2`. В обоих отчётах fingerprint
до/после совпал:
`1e3b83eeddea31a8ed8df28e6240cc3e0083d5e2c4ddb7889a315c0bd3a94e3e`.
Локальные отчёты: `artifacts/qa/fast-20261016-194723-0e4d40f4/summary.json` и
`artifacts/qa/fast-20261016-194919-37752b65/summary.json` (в именах UTC).

Эти цифры относятся к **первым двум прогонам**, до добавления двух coordinator
failure regressions и исправления empty-array режима `-Full`. Это измерение
локального цикла, а не коэффициент ускорения старого CI или времени сборки APK/EXE.

Финальный `-Full` для **+9** после сведения исходников всех агентов прошёл за
**29,08 с**, с `-count=1` для Go (0 cached test packages) и совпадающим source
fingerprint. 192 domain +46 state +31 updates +155 Flutter tests, Go checks,
installer fixtures, 26 planner, 2 coordinator и 38 JVM QA checks прошли.
[Обезличенный отчёт](evidence/fast-validation-build9.json). После этого менялись
только документация и файлы доказательств, исходники проверенного кода сохранены.

На API30 эмуляторе final QA helper ввёл **10648 байт за 836 мс**. SHA-256/длина
readback и независимое чтение UI совпали; системные Settings получили отказ
`wrong_window_package` за 696 мс, временный файл удалён. Первоначальная гонка
готовности Flutter semantics исправлена bounded polling свежего дерева и
оставлена в истории [runtime evidence](evidence/android-fast-input-build9.json).
Проверка не добавляла подписку и закончилась отключённым VPN.

Исходники инструмента: [24901d4](https://github.com/Extectick/ExVPN/commit/24901d4121b578ccc87cff590d1b9791e21085b4).
Правила разделения работы закреплены в [AGENTS.md](../AGENTS.md).

## Повторное измерение на +10

2026-10-17 итоговый `-Full` на исходниках
[924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479)
прошёл за **37,77 с**. Все девять наборов PASS, Go `-count=1`, ни одного cached
test package; fingerprint до/после совпал. Одновременно собирались Windows
service/installer. Это измерение на более широком наборе проверок и при другой
нагрузке, поэтому оно не сравнивается как регрессия скорости с +9.
[Обезличенный отчёт](evidence/fast-validation-build10.json).

Сохранились 192 domain +46 state +31 updates +155 Flutter tests, Go verify/test/vet,
installer, planner/coordinator и JVM QA checks. Добавлены 23 проверки входов
notices, 41 проверка audit и 29 snapshot/APK-проверок. Windows suite дополнительно
проверяет отмену reconnect, ошибки cleanup, смену поколения и реальный loopback
обмен TCP/WS/gRPC/XHTTP/Hysteria2 с запретом DNS старого поколения. Это по-прежнему
не заменяет проверку установленного VPN.

В CI [84489a2](https://github.com/Extectick/ExVPN/commit/84489a2) исключает только
push с документацией/дизайн-изображениями из повторной native-сборки. Pull request
не фильтруются. [Точные пути и ограничения](CI.md).
