# Windows: проверка UI без административных прав

Дата: 2026-10-17. EXVPN-E1/E5 в целом остаются открытыми.
Исправление: [a617aad](https://github.com/Extectick/ExVPN/commit/a617aad16c6e1803fcd6e1557d1c500861732e74).
Стенд: [59bbcdf](https://github.com/Extectick/ExVPN/commit/59bbcdfc85dc1a99c43703445ae491154b78167a).

## Подтверждённый результат +6

NSIS upgrade **+5 → +6** прошёл с exit 0. Полный автоматический прогон
**18:26:40–18:30:35 UTC 2026-10-16** завершился успешно без Computer Use:

- Проверен токен фактического процесса Flutter: medium, без elevation,
  административной группы/привилегий; installer owner сохранён.
- VLESS TCP, REALITY, Vision, XHTTP, XHTTP+REALITY, VMess и Shadowsocks:
  реальные HTTPS 200/204, запрос к TUN DNS, рост счётчиков, явное отключение.
- Исключение выбрано в UI. При обрыве сервера обычный процесс теряет сеть,
  исключённый получает HTTPS 200; при hard kill SCM оба блокируются.
- После restart WFP остаётся активным, UI показывает blocked, исключение
  восстановлено. Кнопка отключения возвращает HTTPS обоим процессам.
- Production binding восстановлен, служба Running; guard/TUN отсутствуют,
  хеши маршрутов/DNS совпали с исходными. Fixture остановлен. Сеть хоста не менялась.

[Обезличенный отчёт](evidence/windows-unelevated-build6.json),
[подключение](evidence/windows-unelevated-connected-build6.png),
[блокировка после рестарта](evidence/windows-unelevated-restarted-build6.png).
Установщик: 34 988 468 байт, SHA-256
`0a7654dd5cd12baedb6381b9d85a6cad0da5b74c06bf21db74dc72bd2449f00e`.
Это unsigned development-пакет, не принятый стабильный выпуск.

## Найденная ошибка +5

Предыдущие прогоны Sandbox использовали повышенный desktop token. В новом
контролируемом прогоне токен самого созданного процесса UI имел medium integrity,
`administratorToken=false`, `elevated=false`, тот же installer owner SID и не
содержал административных привилегий. Дополнительные restricting SIDs отсутствовали.

Инициализация UI не прошла. Отдельная проверка с тем же ограниченным токеном
подтвердила причину: SCM query доступен, но
`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` для настоящего SCM PID ExVPN
возвращает Win32 **5 / access denied**. Это воспроизведённый дефект +5,
а не предположение из unit tests.

## Исправление +6

После проверки запуска от LocalSystem служба добавляет в DACL **собственного
текущего процесса** одно разрешение installer-bound user SID:
`PROCESS_QUERY_LIMITED_INFORMATION` (`0x1000`). Остальные ACE сохраняются.
Повторное применение не дублирует grant; null DACL, неподходящий SID и более
широкое существующее разрешение этому SID отвергаются. DACL читается обратно
перед запуском IPC; ошибка завершает старт службы с кодом 7, без открытия VPN.

Это даёт UI доступ к имени образа процесса для проверки pipe peer. Права читать
память, дублировать handles, создавать потоки, изменять/завершать процесс или
менять его ACL не выдаются. PID, путь, access mask и ACL нельзя передать в этот
механизм по IPC или подпиской. Проверки peer PID против SCM, LocalSystem account,
точного executable path, user SID и пути клиента продолжают выполняться.

Unit tests работают с ACL в памяти и проверяют точный mask, сохранение чужого
deny/allow, отсутствие дубликатов и отказ небезопасным входным данным. Служба,
реестр HKLM, WFP и сеть хоста этими тестами не меняются. Весь Windows Go module
и vet прошли; Flutter analyze и ordinary release +6 также прошли.

## Автоматический стенд

`prepare-app-sandbox.ps1 -Unelevated` добавляет отдельный `qa-desktop.exe`.
Этот helper не попадает в обычный установщик. Запуск разрешён только в ожидаемом
guest path, с marker/nonce и тем же installer owner SID; PowerShell runner
проверяет checksums input bundle, защищённый QA tree и его manifest.

Sandbox не предоставил linked UAC token. Поэтому helper использует
`CreateRestrictedToken(DISABLE_MAX_PRIVILEGE | LUA_TOKEN)`, отключает
Administrators и устанавливает medium integrity. `SANDBOX_INERT` не используется.
До запуска Flutter проверяется токен фактически созданного suspended процесса:
нет elevation/admin group/административных privileges, owner SID совпал, integrity
medium, restricting SID count равен нулю. Только после этого поток UI продолжается.

Под impersonation того же токена проверяются query SCM/process и обязательный
`ERROR_ACCESS_DENIED` при запросе изменения конфигурации службы, записи защищённой
policy/QA metadata и отдельных прав terminate, VM read/write, duplicate handles,
create thread, set/query information, write DACL/owner для процесса службы.
Это запросы прав на handles; данные и параметры процесса ими не изменяются.

Затем настоящий Flutter UI импортирует временную подписку, подключает семь узлов,
выбирает исключение и выполняет прежний SCM fault suite. HTTPS probes наследуют
токен UI. Служба остаётся LocalSystem. Отчёты проверяют текущий nonce и реальные
token facts; отсутствие/ошибка проверки не считается успешной проверкой прав.
В конце восстанавливаются production binding/сеть и останавливается свой fixture.

Первый прогон +6 успешно инициализировал native IPC, затем отдельный консольный
HTTPS probe завершился с `0xC0000142` до сетевой проверки. Отчёт теперь различает
ошибку запуска, exit code и ошибку JSON, не раскрывая сообщения ОС/аргументы.
Тот же Go probe собран с `-ldflags=-H=windowsgui`: он работает через перенаправленный
stdio и не нуждается в консоли. После этого baseline и весь сетевой сценарий
прошли. Это исправление вспомогательного стенда; права/проверки ExVPN не менялись.

`qa-desktop.exe --probe` выполняет только проверки token/access без запуска UI
или отправки IPC-команд. Открытие pipe проверяет kernel ACL; оно само по себе
не доказывает успешную авторизацию клиента протоколом службы.

Этот метод доказывает работу без административных прав в том же профиле Windows.
Вход в отдельную стандартную учётную запись, UAC installer UX и весь диапазон
Windows 10/11 требуют отдельных проверок. Остаются также разные egress IP,
полная IPv6/DNS/UDP матрица, sleep/reboot/network change и релизная подпись.

Проверены API закреплённого `golang.org/x/sys v0.48.0`; новые зависимости не добавлены.
Первичные источники: [права процессов](https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights),
[SetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo),
[SetEntriesInAcl](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setentriesinaclw),
[CreateRestrictedToken](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken),
[CreateProcessAsUser](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw).
