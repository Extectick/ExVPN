# Быстрый цикл разработки и проверки ExVPN

После runtime-исправления повторного VPN consent: **12/12 PASS за 141,67 с**,
335 app tests, source unchanged; [Full](evidence/fast-validation-v0.1.4-retry.json).
20 isolated JVM tests и два новых UI/controller сценария доказывают красное
idle-состояние и повтор без лишнего Disconnect; существующий/неизвестный владелец
остаётся консервативным. Повторный APK/runtime gate ещё ожидается.
[Найденный runtime отказ](evidence/android-candidate25-runtime-partial.json).

После исправления APK ZIP verifier: **12/12 PASS за 136,33 с**, 333 app tests,
source unchanged; [финальный Full](evidence/fast-validation-v0.1.4-packaging.json).
90 artifact-audit и 47 Android-notice fixtures подтвердили различие регистра
ресурсов APK, отказ точных дубликатов/traversal и прежние Windows/Go guards.
Первый preview workflow39140860058 завершился ошибкой Android packaging;
публикация была пропущена, тег не создавался. Сохранённый APK source6d2e947
прошёл 35 JVM tests; его runtime и новый CI-выпуск учитываются отдельно.
[Причина остановки](evidence/android-candidate25-build-attempt.json).

Кандидат 0.1.4+25, 2026-10-18: **12/12 PASS за 293,54 с**, 333 app tests,
source fingerprint before/after совпал. [Full](evidence/fast-validation-v0.1.4.json).
Отдельно 15 isolated Android consent JVM tests и resource link прошли;
новая APK/runtime проверка ещё выполняется и не подменяется этим прогоном.
Прогон выполнялся параллельно с web build; контролируемого сравнения
производительности нет.

Последний общий прогон 2026-10-18, исходники
[3d4e363](https://github.com/Extectick/ExVPN/commit/3d4e363fc8d6a75d2006f7e043585589005f68c8):
**12/12 PASS за 100,72 с**, 308 app tests, source fingerprint не изменился.
Сохранены прежние suite/host пары; добавлены проверки трёх режимов и release-feed.
[Full](evidence/fast-validation-v0.1.3.json),
[Android JVM boundary](evidence/android-owner-build24.json),
[отдельный API30 runtime](evidence/android-routing24-runtime.json).
Full остаётся поведенческой проверкой: сборка, настоящая сеть, физическое
устройство и цикл установки проверяются отдельно. APK23 прошёл Full, но runtime
обнаружил неверное include; исправление подтверждено APK24. Успех unit-тестов
не заменяет это разделение.

После добавления чистых Android selectors, 2026-10-17: **11/11 PASS за
241,75 с**, Go result cache отключён, исходники не менялись во время проверки.
В scripts/CI сохранены все 17 прежних suite/host пар и добавлена одна новая.
61 selector check и независимый review прошли; четыре сохранённых UI tree
повторно разобраны без запуска гостя. Отфильтрованный список, помещающийся
на экране, больше не обязан быть `scrollable=true`. Helper не выполняет
ADB-действий; перед следующим runtime его нужно подключить к сценарию и
сохранить свежие проверки состояния. Этот результат не заменяет прежние
Android INDETERMINATE и не подтверждает Save/DNS.
[Full](evidence/fast-validation-build17-selectors.json),
[selectors](evidence/android-exclusions-selectors-build17.json),
[код 1884fae](https://github.com/Extectick/ExVPN/commit/1884fae804a17b8fe9fdf41eecaf9fd09332427d).
Длительность измерена для этого запуска; коэффициент ускорения не заявляется.
Повторный [CI 39039182575](https://github.com/Extectick/ExVPN/actions/runs/39039182575)
на `1884fae` запущен; на момент записи итог ещё не получен. Предыдущий успешный
CI ниже относится к исходникам собранных +17 пакетов и не заменяет этот запуск.

Проверка +17 после остановки source writers, 2026-10-17: **11/11 PASS за
125,52 с**, Go result cache отключён, source fingerprint неизменен.
Включены новый поиск исключений и Windows session lifecycle `exvpn.5`.
[Отчёт](evidence/fast-validation-build17.json). Сборка и runtime-проверки
новых пакетов выполняются отдельно; время этого прогона не является SLA.

Тот же исходный commit `2cd1f71` прошёл обе полные native CI lanes:
Android — 20 мин 46 с, Windows — 11 мин 11 с. Android lane включает JVM tests.
Эти development-сборки используют обычный Flutter; локальные Shorebird-пакеты
проверены отдельно. [CI +17](evidence/ci-build17.json).

Отдельный разбор сохранённых Windows receipts выявил, что 13 успешных UI-шагов
+16 заняли 225,375 с в host coordinator при 16,156 с внутренних semantic
операций и 6,516 с компиляции. Baseline/final/cleanup установки +17 заняли
188,138 с внутри гостя. Чистое время WSB, hashing и CIM отдельно не измерено;
нельзя приписывать им разницу таймеров или считать DLL исправлением прежнего
pre-reservation timeout. Root сверил 98 входных файлов.
[Измерения](evidence/windows-qa-timing-build17.json).

Следующий кандидат ускорения — один dispatch для заданной последовательности
UI-шагов с прежними проверками каждого шага, дедлайнами и остановкой при отказе.
До изменения длинных baseline функций нужны отдельные таймеры вокруг них.
Это предложение, не внедрённое ускорение; сетевые проверки не кэшируются.

Из корня проекта в PowerShell 7:

```powershell
# Во время разработки — только затронутые проверки.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Changed

# После сведения изменений агентов — все быстрые проверки.
pwsh -NoProfile -File scripts/qa/run-fast-validation.ps1 -Full
```

2026-10-17: в общий `android-lifecycle-tools.ps1` перенесены наблюдение
ConnectivityService и обработка системного VPN-разрешения. **192 focused
checks PASS**; новый parser также прочитал сохранённые реальные +16 состояния
0 → 1 VPN с подтверждённым владельцем → 0. Неполный вывод не считается
отсутствием VPN. Consent требует принятой команды Connect, точного свежего
системного диалога и выполняет один tap; неизвестный результат не повторяется.
Это общие helper-функции для следующих runners, без нового запуска эмулятора.
[Доказательство](evidence/android-common-observers.json),
[исходники](https://github.com/Extectick/ExVPN/commit/f3b7471224f797f82b5e54082a064d46b6a5d2e4).

Общий прогон после этих helpers и собственных updater notices — **11/11 PASS
за 160,59 с**, исходники не менялись, Go result cache выключен.
[Отчёт](evidence/fast-validation-updater-notices.json). Последующий collector
транзитивных лицензий требует отдельного итогового прогона.

После standalone crate collector и signing backup tool итоговый Full —
**11/11 PASS за 459,07 с**, source unchanged, Go result cache выключен.
Backup tool дополнительно прошёл 18 локальных проверок на синтетических ключах;
он не входит в CI и требует PowerShell 7.6/.NET 10. Это измерение конкретного
прогона, не контролируемое сравнение производительности.
[Отчёт](evidence/fast-validation-release-preparation.json).

Команда сама выбирает затронутые наборы тестов, запускает до трёх независимых
процессов и записывает длительности, exit codes и итог в
`artifacts/qa/fast-<timestamp>-<id>/summary.json`. Рядом лежит отдельный `.log`
каждого набора. Любая ошибка, timeout или изменение исходников во время прогона
даёт ненулевой exit code; успешные остальные наборы не скрывают отказ.
В `scripts.log` и `ci.log` строки `EXVPN_SUITE_TIMING` дополнительно содержат
время каждого служебного набора, версию PowerShell и результат; приватные
аргументы или содержимое fixtures в эти строки не входят.

Это быстрые поведенческие проверки: анализ Dart/Flutter, unit/widget tests,
Go unit/loopback tests и файловые сценарии установщика с mock SCM/ACL. Они не
запускают установленный VPN, службу, TUN, WFP или смену маршрутов/DNS хоста.
Приватные подписки и действующие VPN-серверы в них не участвуют.

Последний прогон после разделения очереди, 2026-10-17: **11/11 за 82,03 с**,
source fingerprint неизменен, Go result cache отключён. Все прежние 16 пар
«проверка/PowerShell host» сохранены; `test-build-impact.ps1` выполняется в
отдельной `ci` lane под тем же общим лимитом трёх процессов. До разделения
измеренный Full занимал 89,90 с, из них 35,173 с — этот набор. Это наблюдения
на текущем компьютере при возможной разной нагрузке, не универсальный benchmark.
[Замер каждого набора](evidence/fast-validation-suite-timing-build14.json),
[Full после разделения](evidence/fast-validation-ci-lane-build14.json).

37 проверок планировщика, все 2048 комбинаций выбранных lanes и реальный
coordinator с отказами дочерних Android/CI процессов подтверждают сохранность
выбора и обработки ошибок. Когда выбирается `scripts`, добавляется `ci`;
повторного выполнения перенесённого набора нет. Тайм-ауты, проверка изменения
исходников и отдельные native/runtime gates сохраняются.
[Исходники db17725](https://github.com/Extectick/ExVPN/commit/db177258de41ae050f131cb0a4c38689ba5e748e).

После разделения очередей обе native CI lanes также завершились успешно:
Windows — 5 мин 46 с, Android — 12 мин 2 с. APK и Windows development bundle
загружены в artifacts этого запуска. Это длительности полных CI jobs, не
локального быстрого цикла и не доказательство системной приёмки.
[CI evidence](evidence/ci-parallel-validation-build14.json).

После добавления непрерывных DNS-интервалов, 2026-10-17: **10/10 за 86,60 с**,
source fingerprint неизменен, Go result cache отключён. Четыре новые offline
регрессии прошли вместе с остальным набором. Повторный разбор сохранённого +13
PCAP воспроизвёл шесть открытых DNS-пакетов до Disconnect и один в переходе;
новый VPN-сеанс не запускался. [Full](evidence/fast-validation-continuous-dns-build14.json),
[reparse](evidence/android-dns-continuous-parser-build13.json),
[исходники](https://github.com/Extectick/ExVPN/commit/b27b685).

После этого CI также завершил обе полные native lanes: Windows 7 мин 34 с,
Android 15 мин 41 с. Это отдельное доказательство сборок, а не длительность
локального быстрого цикла или приёмка VPN.
[CI evidence](evidence/ci-continuous-dns-build14.json).

Прогон **+14 после source freeze**, 2026-10-17: **10/10 наборов за 96,93 с**,
465 Dart/Flutter tests, Go/installer/QA checks PASS; Go result cache отключён,
fingerprint исходников совпал. Добавлены 17 поведенческих тестов tray.
[Отчёт](evidence/fast-validation-build14-tray.json),
[код](https://github.com/Extectick/ExVPN/commit/e90e66bb59e1c2cc893eec8408b545e759fe3ddf).
Это длительность конкретного прогона; обязательные native/runtime gates отдельно.

На установленном Windows +13 выполнено read-only обнаружение UI без Computer Use.
UIA показал только Window/Pane; закреплённый Flutter предоставляет дерево MSAA.
`AccessibleObjectFromWindow(OBJID_CLIENT)` обнаружил 18 узлов за 427 мс, bounded
child завершился за 3187 мс. 32 private evidence hashes проверены координатором;
21 native/network поле и пустое production storage не изменились. Это только
чтение: действия, ввод текста и maintenance ещё не проверены. Caller имел
admin token; обычный установленный EXE не означает unelevated acceptance.
[Отчёт и ограничения](evidence/windows-msaa-discovery-build13.json).

Следующий законченный этап MSAA — обычный установленный Windows +13:
**11/11 шагов импорта/выбора/удаления подписки за 132,542 с**, включая setup и
cleanup. Продуктовый бинарник не менялся, Computer Use и VPN не запускались.
Это отдельный runtime UI-сценарий, не часть быстрого `-Full`.
[Доказательство и сохранённые отказы стенда](evidence/windows-msaa-import-remove-build13.json).

CI исходников +14 с треем успешно завершил обе native lanes — Android и Windows.
Системная проверка установленного трея, DNS и release-подпись остаются отдельными
критериями. [CI evidence](evidence/ci-build14-tray.json).

Последний общий прогон +13 после добавления Android Instrumentation и аудита
упакованных файлов, 2026-10-17: **10/10 наборов за 115,59 с**, source fingerprint
совпал, Go result cache отключён. Прошли 448 Dart/Flutter tests и Go/installer
checks, 52 Java UI-сценария (826 assertions), 81 Android lifecycle fixture,
129 inventory fixtures и 72 artifact audit fixtures. Это расширенный набор,
выполненный одновременно с отдельной инвентаризацией Gradle; его время не является
коэффициентом ускорения прежнего набора. [Полный отчёт](evidence/fast-validation-build13-instrumentation.json).
Android runtime, подготовкой зависимостей и независимым review занимались разные
агенты; общий Full запущен координатором после завершения записи исходников.

Предыдущий общий прогон +13 после изменения очереди, 2026-10-17:
**10/10 наборов за 87,11 с**, 448 Dart/Flutter tests и все Go/installer/QA checks
PASS; source fingerprint совпал, Go result cache отключён. Тяжёлые независимые
`scripts`, `app`, `core` запускаются первыми при прежнем лимите трёх процессов.
Выбранное множество тестов сохраняется; это проверено для всех 1024 подмножеств
и в запуске настоящего coordinator с ошибкой дочернего процесса и source drift.
В отчёте отдельно записаны `selectedLanes` и `executionOrder`.
[Отчёт](evidence/fast-validation-build13-scheduling.json),
[исходники](https://github.com/Extectick/ExVPN/commit/2670357).
В этот прогон также вошли 67 обновлённых Android metadata fixtures.

Предыдущий общий прогон +13 после исправления Sandbox-стенда, 2026-10-17:
**10/10 наборов за 127,43 с**, без Go result cache и изменения исходников.
Проверены 448 Dart/Flutter tests, Go verify/test/vet, Xray lifecycle и installer;
147 CI selector cases и 54 Windows subscription fixtures под PS7/PS5.1.
[Отчёт](evidence/fast-validation-build13-qa.json),
[исходники](https://github.com/Extectick/ExVPN/commit/dce2942).
Это полный прогон параллельно с изолированными системными стендами; его время
не является измеренным коэффициентом ускорения относительно предыдущего.

Предыдущий общий прогон +13, 2026-10-17: **10/10 наборов за 111,93 с**, без
Go result cache и изменения исходников. Прошли 192 domain, 57 state, 31 updates
и 168 Flutter tests, Go verify/test/vet, Xray lifecycle, installer и QA fixtures.
В том числе проверены 144 CI selector cases, 54 быстрых Android inventory cases
и Windows subscription validators под PS7/PS5.1. Отдельные 92 проверки с
реальным синтетическим Gradle repo подтверждают dependency pin и изоляцию.
[Отчёт](evidence/fast-validation-build13.json),
[проверенный код](https://github.com/Extectick/ExVPN/commit/03b5d6c).
Новые standalone Windows subscription QA файлы включены в точный CI allowlist;
их отдельное изменение не требует native rebuild, все тесты сохраняются.
Android APK и Windows installer/QA bundles собирались независимыми владельцами;
общий app build-каталог передавался между ними последовательно.

Windows QA bundles теперь всегда содержат одинаковый набор вспомогательных
файлов. Это устраняет отказ при смене transport/subscriptions на одном read-only
Sandbox mapping; точный manifest по-прежнему отклоняет лишние файлы и подмену.
Оба immutable bundles переупакованы за 17,416 с без Flutter/Go rebuild с проверкой
исходников и SHA-256 переиспользованных бинарников. Реальный E3-сценарий прошёл
через два процесса и DPAPI за 98,984 с, включая setup/cleanup; первый отказ
сохранён в [отчёте](evidence/windows-subscriptions-build13.json).

Android +13 проверялся независимо от Windows; UI подписок и транспорт разделены
на два bounded сценария с отдельными baseline/cleanup. UI прошёл за 191,583 с.
Транспорт подтвердил первое HTTPS через gRPC, но остановился на UIAutomator
timeout перед Disconnect; повторные циклы не засчитаны. Такая автоматизация
сокращает ручное управление, но отказ стенда остаётся отдельным результатом.
[Доказательства](evidence/android-runtime-build13.json).

Следующий Android-прогон использовал отдельный QA Instrumentation helper:
свежий semantic snapshot, единственная обычная кнопка Connect/Disconnect и
проверка нового состояния без ожидания окончания анимации. Нет retry-click при
неизвестном исходе и остановки ExVPN вместо Disconnect. В активном VPN private
driver запрещает UIAutomator XML. **4/4 цикла gRPC/XHTTP PASS за 50,442 с**,
весь прогон с boot/setup/cleanup — **177 с**. Независимый UID подтвердил HTTPS,
DNS и VPN transport; проверены native service, peer drain и возврат прямой сети.
[Отчёт](evidence/android-transport-semantics-build13.json),
[helper и ограничения](../scripts/qa/android-https-probe/README.md),
[исходники](https://github.com/Extectick/ExVPN/commit/2259bb7).
Прежний timeout сохранён; physical-device, IPv6/leak/fault gates остаются.

Предыдущий общий прогон, 2026-10-17: **10/10 наборов за 106,66 с**, все Go tests
выполнены заново, fingerprint исходников совпал. В общий runner и CI добавлены
offline DNS capture fixtures, nonce-проба Android и Windows teardown fixtures
под PS7/PS5.1; проверены 131 CI selector/graph/JUnit fixtures и строгие границы
IPv6 Hop-by-Hop parser. [Отчёт](evidence/fast-validation-build12-qa.json),
[исходники](https://github.com/Extectick/ExVPN/commit/ea9f2ca).
Три агента независимо выполняли Windows QA, Android QA и review; итоговый Full
выполнил координатор после завершения записи исходников. Это длительность
конкретного расширенного набора, не измеренный коэффициент ускорения.
Реальные проверки Android/Windows проходили параллельно на отдельных стендах.
Чистый Android JVM helper отдельно прошёл 8/8 за 43,13 с без APK/JNI; локальные
SDK/dependency caches сохранены. Эти измерения относятся к разным проверкам и
не являются коэффициентом ускорения полной сборки CI.

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
| Только известные документы/изображения в `docs`/`design` или JSON-отчёты в `docs/evidence` | Кодовые наборы не нужны; визуальная/документальная проверка остаётся отдельной |

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
и конкурентный Dial/Close. В `exvpn.4` добавлены memory-only gVisor/DNS пакеты,
закрытие TUN UDP workers и ошибки частичного запуска. В scripts lane также проверяются реконструкция ZIP,
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

CI сохраняет clean-checkout анализ/тесты. Product-изменения, неизвестные пути,
pull request и ручной запуск требуют обе JNI ABI, APK/JVM tests и Windows
UI/service build. Только подтверждённый QA-only push может пропустить native
packaging, сохранив JVM и остальные проверки; такой run не даёт новых APK/EXE.
[Правила выбора и граница docs-only trigger](CI.md).

Фактический QA-only run 2026-10-17 прошёл обе платформы: Windows **6 мин 14 с**,
Android **12 мин 53 с**, 6/6 точных cache hits, 8 свежих JVM tests и 0 artifacts.
[Отчёт](evidence/ci-qa-only-build12.json). Полная ветка со сборками также
прошла отдельно; разные объёмы workflow не являются сравнительным benchmark.

Нативные функции, Kotlin/C++, TUN, IPv4/IPv6/DNS,
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
Android QA-probe, 12 проверок DNS nonce и 14 проверок UTF-8/размера/хеша быстрого
ввода. Offline PCAP parser использует уже закреплённый Go graph без новой
зависимости; Windows teardown helpers проверяются под PS7 и PS5.1. Сеть и
установленный VPN для этих fixtures не используются.

DNS-анализ дополнительно принимает непрерывные `protectedIntervals` между
фактическими маркерами VPN: UDP/TCP53 считаются также в промежутках между
фазами. Явный флаг покрытия границ захватом не заменяет проверку packet drops
или UID. `PARSED` остаётся результатом разбора, не успешной проверкой утечек.
Регрессии проверяют границы, промежутки, IPv4/IPv6, UDP/TCP и неполный capture.
[Формат и ограничения](../scripts/qa/android-dns-capture/README.md).

В scripts lane и CI добавлены лёгкие проверки Android runtime inventory:
точные версии/engine, граф связей, хеши и отрицательные fixtures. Полное Gradle
разрешение dependency graph запускается отдельной командой; быстрые тесты его
не повторяют. Проверка готового APK отклоняет также dependency-only ABI без
VPN-ядра/Flutter engine — это граница упаковки, а не VPN runtime acceptance.

JSON-отчёты под `docs/evidence` классифицируются как документация, как и в CI.
Произвольный `docs/configuration.json` или `runner.json.ps1` по-прежнему требует
всех наборов. Смешанное изменение отчёта и кода сохраняет проверки кода.
Эта граница входит в 31 проверку планировщика.

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
`scripts/qa/android-lifecycle-tools.ps1`. 134 Windows и 19 Android синтетических
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
