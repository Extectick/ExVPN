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
  sleep/resume, смена сети, исключения и падение SCM-службы не входят в этот прогон.
  Ранее выполненные отдельные системные tests остаются отдельными доказательствами.
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
