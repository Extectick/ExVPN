# Windows: проверка приложения без Computer Use

Функциональные сценарии выполняются через Flutter `integration_test`, CLI
Windows Sandbox и отдельные HTTPS-процессы. Мышь, клавиатура ОС и Computer Use
не используются. Приложение создаёт настоящее Windows-окно; `tester.tap`
доставляет события непосредственно в работающий Flutter widget tree.

## Дополнение 2026-10-17: сохранение исключений

NSIS upgrade **+3 → +4** и повторный полный Flutter/SCM fault run прошли.
Выбранное в UI исключение теперь сохраняется после аварии и рестарта службы,
а также после явного отключения. WFP оставался активным до disconnect, затем
маршруты/DNS и production client binding восстановились; fixture остановлен.
См. [отчёт +4](evidence/windows-policy-build4.json),
[снимок после аварии](evidence/windows-policy-after-crash-build4.png) и
[хранилище политики](WINDOWS_POLICY.md). Исходники:
[c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73).

На **+5** отдельный тест повреждения и явного сброса policy также прошёл:
настоящая SCM/DPAPI запись повреждена после protected backup, UI показал ошибку,
повторное чтение не перезаписало данные, кнопка сброса восстановила список и
состояние. Повторный запуск службы/QA UI подтвердил сохранение; encrypted baseline
и production binding восстановлены, network fingerprint совпал. Upgrade +4 → +5
успешен. [Отчёт](evidence/windows-policy-recovery-build5.json),
[ошибка UI](evidence/windows-policy-corrupt-build5.png),
[после сброса](evidence/windows-policy-reset-build5.png),
[исходники fd08979](https://github.com/Extectick/ExVPN/commit/fd089794723f1db0ede022e01804b4026e90de80).
Протокольный suite в этом отдельном прогоне +5 не запускался.

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

Повтор **16:47:39–16:51:26 UTC** прошёл после штатного NSIS upgrade
**0.1.0+2 → 0.1.0+3**, exit 0. Весь сценарий протоколов/отказов повторён;
`transport_unreachable` и `guard_recovered` теперь доходят до UI как разрешённые
коды. Вместо общей ошибки показаны причина потери сервера и объяснение блокировки
после рестарта; для активной блокировки кнопка называется «Отключить».
[Отчёт +3](evidence/windows-scm-failure-build3.json),
[обрыв сервера](evidence/windows-server-outage-build3.png),
[рестарт](evidence/windows-scm-restarted-build3.png).
Исправление [e22a748](https://github.com/Extectick/ExVPN/commit/e22a748dd1fde206dd4fed8208e93b329636b652);
стенд после upgrade [f83ab84](https://github.com/Extectick/ExVPN/commit/f83ab845515d7f9a0208422d06458de2076c6d9c).
18 релевантных Flutter tests, analyze, ordinary/QA Windows Release и NSIS build
прошли; неизвестные native-коды/сообщения по-прежнему не раскрываются.
Установщик +3: 34 932 972 байта, SHA-256
`51b7c1327b3e4dcc58ab5afbba6dc7c46f5837f034135f894e2bda1904661f05`.
Он остаётся unsigned development; release gate защиты не изменён.

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
  и SCM crash относятся только к описанному TCP/IPv4 сценарию. Сохранность настроек
  исключений подтверждена отдельным повтором +4; старые +2/+3 этого не проверяли.
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
   Для повтора с существующим QA tree — `-Action Refresh`. Обычный UI должен
   быть закрыт, TUN отсутствовать. После upgrade допускается рост build с тем же
   owner SID и восстановленным production binding; новый бинарник службы должен
   совпасть с protected installed manifest. На прежнем build изменение service
   SHA-256 запрещено. Downgrade отвергается. Если служба обновилась, Refresh
   выполняется до Prepare координатора, чтобы принять проверенный новый manifest.
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

## Повреждение и восстановление policy

Для отдельного storage/UI сценария подготовить bundle командой
`scripts/windows/prepare-app-sandbox.ps1 -Installer <development-exe> -PolicyRecovery`.
Этот режим компилирует `windows_policy_test.dart` в отдельном каталоге, проверяет
совпадение app version/build с установщиком и задаёт `policyRecovery=reset`.
`-IncludeFaults` и `-PolicyRecovery` взаимоисключающие. Private mapping и
протокольный fixture этому тесту не нужны; input/output mappings и Setup/Refresh
выполняются по той же методике. Build уже должен быть установлен.

Запуск: `scripts/windows/run-app-policy-sandbox.ps1 -SandboxId <id>
-BundleDirectory <path>`. Координатор проверяет гостя/nonce, сохраняет сетевой
baseline, повреждает только фиксированное значение собственной policy, запускает
UI reset, перезапускает SCM и запускает UI reopen. Guest helper проверяет
LocalSystem, owner SID, полный manifest, service hash и ACL перед изменением.
Только encrypted backup хранится в protected Program Files гостя, не в общей
папке результатов. В `finally` восстанавливаются policy и production binding,
сверяются сеть/guard/TUN. Успех требует двух `frameworkPassed`/`passed`,
`policy-coordinator.passed=true`, `cleanupPassed=true` и нулевого exit code.
