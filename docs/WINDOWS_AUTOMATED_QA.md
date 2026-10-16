# Windows: проверка приложения без Computer Use

Функциональные сценарии выполняются через Flutter `integration_test`, CLI
Windows Sandbox и отдельные HTTPS-процессы. Мышь, клавиатура ОС и Computer Use
не используются. Приложение создаёт настоящее Windows-окно; `tester.tap`
доставляет события непосредственно в работающий Flutter widget tree.

## Проверено 2026-10-16

См. [обезличенный отчёт](evidence/windows-flutter-sandbox-smoke.json) и
[снимок работающего Flutter UI](evidence/windows-flutter-sandbox-xhttp.png).

- NSIS обновил установленный development-пакет **0.1.0+1 → 0.1.0+2**.
- Импорт через диалог «Текст» создал одну группу из семи узлов.
- VLESS TCP, REALITY, Vision, XHTTP, XHTTP+REALITY, VMess и Shadowsocks:
  выбор строки и кнопка подключения → настоящий native bridge → IPC →
  установленная SCM-служба LocalSystem → Wintun/Xray.
- Для каждого узла отдельный `protected-probe.exe` получил HTTPS **200** по IP
  и **204** по имени; явный DNS-запрос к TUN получил ответ. Счётчики TUN и
  принимающего QA-сервера увеличились. Нет подмены `VpnBridge` или HTTP.
- Кнопка отключения завершила каждый сеанс; прямой HTTPS после последнего
  отключения работал. Framework и процесс теста завершились успешно.
- Привязка службы восстановлена к обычному ExVPN; служба работает, TUN отсутствует.
  Хостовые маршруты, DNS и firewall не менялись. Эфемерный QA-сервер остановлен.

Прогон: **15:56:08–15:56:48 UTC**. Установщик SHA-256:
`953099aa4456979239dc64c3626feb921b9c66f5d10893f42f5b9f13e7d3b630`.
Он unsigned/development, не стабильный выпуск.
Исходники стенда: [625a875](https://github.com/Extectick/ExVPN/commit/625a875).
Повторная привязка QA после восстановления и повторный Restore также прошли.
Локальная проверка исходников: Flutter analyze без замечаний, 19 релевантных
widget/update tests, 2 теста границ fixture bind, Go vet и PowerShell parse прошли.

## Состав и границы стенда

Дополнительный прогон отказов **16:27:44–16:31:29 UTC** прошёл на том же
установленном пакете +2. [Отчёт](evidence/windows-scm-failure-smoke.json),
[подключение с исключением](evidence/windows-scm-exclusion-connected.png),
[состояние после рестарта службы](evidence/windows-scm-restarted-blocked.png).
Исходники: [1575305](https://github.com/Extectick/ExVPN/commit/1575305923c37b9c1f41721d6b07ad11fe133824).

| Сценарий | Защищаемый executable | Исключённый executable | Состояние UI |
|---|---|---|---|
| VPN работает | HTTPS 200 | HTTPS 200 | connected |
| Сервер остановлен | Ошибка сети | HTTPS 200 | reconnecting |
| Реальный SCM PID аварийно завершён | Ошибка сети | Ошибка сети | error |
| SCM запущен снова | Ошибка сети | Ошибка сети | blocked |
| Явное отключение кнопкой | HTTPS 200 | HTTPS 200 | disconnected |

Исключение выбрано через настоящий экран настроек из списка работающих процессов.
Два отдельных probe executable запрашивали HTTPS одновременно. Ошибки запуска
процесса/JSON не считаются доказательством блокировки. Read-only WFP observer
подтвердил сохранение собственного guard после hard kill установленной службы.
Он проверяет наличие принадлежащих ExVPN фильтров, а не полноту четырёх WFP layers.
После Restore служба Running с исходным client path; TUN и guard отсутствуют,
хеш отсортированных маршрутов IPv4/IPv6 и DNS совпадает с исходным.

`apps/exvpn/integration_test/windows_sandbox_test.dart` — отдельная точка входа,
собираемая в отдельной копии исходников под `artifacts/windows/`. Обычный
установщик содержит `lib/main.dart`, а QA-код не подменяет установленный UI.
Используются production `ExVpnApp`, `VpnController`, C++ bridge и установленный
бинарник Go-службы. Служба временно привязывается к точному пути защищённого
QA executable с прежним owner SID; проверка PID/SID/пути IPC остаётся включённой.
Исходная SCM-команда сохраняется в защищённом каталоге гостя и восстанавливается.

Изолированные mappings:

| Папка гостя | Доступ | Содержимое |
|---|---|---|
| `C:\ExVPN-App-QA` | read-only | QA bundle, установщик, checksums, скрипты |
| `C:\ExVPN-App-QA-Results` | write | Обезличенные отчёты и PNG |
| `C:\ExVPN-App-QA-Private` | read-only | Только эфемерная подписка текущего fixture |

`native/android/cmd/qa-server` обслуживает также Sandbox: bind только на явно
указанный IPv4 локального виртуального интерфейса. Wildcard/чужие адреса отвергаются.
Сервер доступен с этого интерфейса, credentials случайные и хранятся в `.private`.
Подробности — [README fixture](../native/android/cmd/qa-server/README.md).

Тест проверяет настоящий туннель, но не полную матрицу приёмки:

- QA запущен с административным desktop token Sandbox; ordinary-user IPC ещё
  не принят. Служба по-прежнему LocalSystem.
- Эфемерный сервер находится на хосте; baseline и VPN имеют один внешний IP.
  Разные IP обычного/исключённого приложения этой топологией не доказаны.
- Trojan/Hysteria2, UDP, полный IPv6/DNS packet capture, холодный кеш Xray,
  sleep/resume, перезагрузка и смена сети остаются открытыми. Проверенные исключения
  и SCM crash относятся только к описанному TCP/IPv4 сценарию; сохранность настроек
  исключений после аварии этим тестом не доказана.
- Используется временный `AppController` без persistence. Хранилище, QR/picker,
  OTA и повторный запуск обычного UI этим сценарием не приняты.
- Ввод текста синтезирует штатный Flutter test IME. Системная клавиатура/IME,
  UAC, accessibility, оконная рамка, DPI и визуальная оценка человеком не проверены.
  PNG сняты с `RenderRepaintBoundary` настоящего работающего приложения.
- `processCrashProtection=false` — намеренный release gate незавершённого E1,
  а не измерение состояния WFP. Тест не меняет этот gate ради зелёного результата.
- Это Windows-доказательство; физический Android и новая Android-сборка +2
  требуют своих проверок.

## Повторный запуск

Все команды `guest-*` выполняются **только внутри одноразового Sandbox**.
Они проверяют фиксированные пути, host/guest separation, token, manifest и
принадлежность службы. На хосте запрещены установка сервиса, запуск тестового
entry point и изменение сети. Полный репозиторий/вся `.private` не шарятся.

1. Собрать обычный Windows Release из `apps/exvpn`, затем запустить
   `scripts/windows/build-installer.ps1`. Build number должен быть выше
   установленного для проверки upgrade. Дождаться `artifact.json` с SHA-256.
2. Выполнить `scripts/windows/prepare-app-sandbox.ps1 -Installer <absolute-path>`.
   Скрипт только компилирует QA bundle и пишет `artifacts/windows/app-qa-latest.json`.
   SDK/lock фиксированы; `pub get --offline --enforce-lockfile` запрещает дрейф.
3. Подготовить свежий fixture на адресе host vEthernet, доступном гостю. Передать
   только его `.private`-каталог read-only; не печатать содержимое подписки.
4. Через `wsb share --id <guest-id>` добавить три mappings из таблицы; только
   результатам дать `--allow-write`. Убедиться, что ExVPN отключён.
5. `wsb exec --run-as ExistingLogin`: `guest-app-upgrade.ps1 -ConfirmDisposableGuest`.
   Нужен desktop administrator; NSIS намеренно отвергает неподходящий token owner.
   Если требуемый build уже установлен, upgrade пропустить.
6. `wsb exec --run-as System`: `guest-app-qa.ps1 -Action Setup -ConfirmDisposableGuest`.
   Для повтора с существующим QA tree — `-Action Refresh`; версия службы должна
   оставаться той же. Обычный UI должен быть закрыт, TUN отсутствовать.
7. `wsb exec --run-as ExistingLogin`: `guest-app-launch.ps1 -ConfirmDisposableGuest`.
   Ждать завершения, читать `flutter-report.json` и `exit-report.json`.
   Успех требует **frameworkPassed=true, allProtocolsPassed=true, exitCode=0**.
8. **В finally**, в том числе после неудачи теста: System запускает
   `guest-app-qa.ps1 -Action Restore -ConfirmDisposableGuest`. Проверить
   `restore-report.json`; при отказе ownership check остановиться для диагностики,
   не сбрасывать глобальные DNS/firewall. Остановить только собственный fixture PID.

Для PowerShell-процессов гостя используются `-NoProfile -NonInteractive
-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\<script>`.
ExecutionPolicy меняется только в процессе запуска. Окно Flutter создаётся самим
приложением; им не управляет Computer Use. Raw exception dumps и заполненный
диалог импорта не публикуются. Отчёт пропускает только известные поля и fixture names.

Для проверки отказов добавить `-IncludeFaults` при подготовке bundle. После
первоначального Setup/Restore использовать на хосте
`scripts/windows/run-app-faults-sandbox.ps1 -SandboxId <id> -BundleDirectory <path>
-FixtureProcessId <pid> -FixtureStartedUtc <start-time>`. Он выполняет Prepare,
Refresh и запуск UI; управляет только тремя фиксированными действиями в порядке
`stop-fixture → crash-service → restart-service`. Запросы/ответы содержат nonce
текущего прогона и номер шага; произвольные команды из гостя не исполняются.
Путь и время старта fixture проверяются до остановки. В `finally` выполняются
восстановление production binding и сверка сети, даже если UI test не прошёл.
Для успеха обязательны `faultsPassed`, `frameworkPassed`, `allProtocolsPassed`,
`cleanupPassed` и нулевой exit code. Каждый повтор использует свежий nonce и
новые эфемерные credentials; stale output не считается текущим результатом.
