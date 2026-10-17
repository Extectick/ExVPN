# Windows — сборка и границы проверки

Дата: 2026-10-16. Это development build, не принятая beta. Служба ExVPN,
драйвер TUN, WFP, маршруты и DNS на рабочем ПК не устанавливались и не менялись.

Актуальные проверки без Computer Use: [WINDOWS_AUTOMATED_QA.md](WINDOWS_AUTOMATED_QA.md).
В Sandbox проверены семь вариантов протоколов через Flutter/SCM/Wintun,
исключение, обрыв сервера и аварийное завершение установленной службы.
Доказательства ниже сохраняют историю отдельных артефактов; они не означают
закрытия E1/E5 или готовность подписанного релиза.

## Подтверждено

В **+12** обновление установленного development-пакета **+11 → +12** прошло
с exit 0. После исправления порядка `Close → Suspend` выполнены **9/9** циклов
gRPC/XHTTP/XHTTP+REALITY в одном процессе SCM: обычный пользовательский UI,
настоящий HTTPS/DNS, положительный контроль активных сокетов, затем нулевые
активные peer после Disconnect в прежнем 10-секундном gate. Cleanup и отдельный
postcheck подтвердили production binding, owner, 264 установленных файла,
исходные маршруты/DNS, отсутствие TUN/guard и тестовых процессов.
[Отчёт и SHA-256 установщика](evidence/windows-lifecycle-build12.json).

Полная команда заняла **353,16 с**; интервал host coordinator — **348,164 с**.
Это разные интервалы, ни один не является измерением FIN/RST latency.
Рост process resources сохранён в отчёте; конечный тест не доказывает отсутствие
утечек памяти. Повторная полная crash/IPv6/exclusions/sleep-resume матрица +12
не выполнялась. Установщик остаётся **unsigned development**.

- Flutter release x64 собран с собственным ICO белки. Нативное окно запускается
  без административных прав; экран «Версии и обновления» проверен визуально.
- Системный выбор PNG/JPEG открывается и отменяется. Полный Windows-поток
  QR preview → импорт ещё не подтверждён; декодер и dialog проверены тестами,
  Android-поток проверен отдельно.
- Go tests/vet, непривилегированный named-pipe roundtrip и отказ постороннему
  executable пройдены. Это не IPC-приёмка установленной LocalSystem-службы.
- NSIS 3.13: offline compilation `/NOCONFIG /WX`, PS5.1 payload inspection,
  manifest/path/no-overwrite checks пройдены. В комплект добавлены три необходимые
  app-local Microsoft CRT DLL с закреплёнными хешами и проверкой Authenticode.
  Глобальный VC runtime не устанавливался.
- После отдельного review исправлено восстановление при частичном удалении
  предыдущей версии и удаления приложения. Тринадцать PS5.1 сценариев используют реальные файлы и Windows
  FileShare locks; SCM/ACL/регистрация подменены тестовыми реализациями. Проверены
  удаление mock SCM и части файлов до отказа, восстановление недостающих старых
  файлов, сохранность unknown/modified/locked replacement, успех и отказ explicit
  rollback, partial uninstall на заблокированной второй DLL и отказ удаления
  регистрации после удаления всех файлов. Uninstall сохраняет проверенный
  защищённый backup до удаления SCM/файлов. Невозможность восстановления явно возвращает `INCOMPLETE` и сохраняет
  backup. Неизменённую заблокированную DLL не удаляют и не перезаписывают.
  `scripts/ci/verify.ps1` запускает suite через Windows PowerShell 5.1 для Windows/Checks.
- Общий mutex `Global\ExVPN.PackageMaintenance.v1` сериализует установку разных
  пользователей до чтения installed state. Mock multi-instance проверки прошли:
  одинаковое имя при разных IPC owner SID, немедленный busy, отказ при чужом
  owner/ACL. Реальное elevated поведение mutex/SCM/ACL ещё требует гостевого теста.
- Сборка уведомлений собрала 136 компонентов; отдельно сохранены NSIS/MSVC terms.
  Это не завершённый release SBOM или проверка всего набора обязательств beta.
- Первый полный clean-checkout CI Android/Windows:
  [38880672529](https://github.com/Extectick/ExVPN/actions/runs/38880672529),
  исходники `f6cd4c4`; job Windows и выгрузка development bundle успешны.

Локальный установщик до гостевой проверки `ExVPN-0.1.0-1-windows-x64-development.exe`,
**34 903 877 байт**; SHA-256
`02d9ad5e12c761ece44550cac4c46f00ee2b24289d82a0fcbdb5c8ddfb73ccd2`.
Каталог новой сборки:
`artifacts/windows/package-0.1.0-1-20261016-100920-4c6df497`.
Он не подписан Authenticode и не прошёл системную установку; сетевые испытания
по умолчанию отключены. Исходники упаковки: `scripts/windows/installer`.

Сборка до исправления uninstall (34 913 591 байт), SHA-256
`d54ab5578f8f11662854443c991a55d48bee5912ddc0e20f9b80712ac86b4740`,
сохранена без изменения в `package-0.1.0-1-20261016-100028-bd3b1f4e`.
Ещё более ранний установщик 34 908 753 байта с SHA-256
`22cdfa1c1d71a859a7dad34c1a770f0732ce839c3486465b0a60d5b10780a553`
сохранён без изменения в `package-0.1.0-1-20261016-093532-dcec63af`.
Это разные development артефакты одного app build, не тестовая пара версий для
upgrade. Payload нового установщика проверен PS5.1; исходники package scripts
совпадают с упакованными файлами по SHA-256. Компиляция `/NOCONFIG /WX` успешна.

Снимки: [главный экран](../design/qa/windows-native/2026-10-16-release-squirrel.jpg),
[версии](../design/qa/windows-native/2026-10-16-versions.jpg),
[отмена выбора QR](../design/qa/windows-native/2026-10-16-qr-picker-cancel.jpg).
Показываемая версия ядра сейчас является pin native adapter; запрос версии
фактически установленной службы требуется отдельно в E6.

## Изолированный стенд: реальная установка (2026-10-16)

После разрешённой перезагрузки Sandbox 0.8.107.0 работает на Windows11 Pro
25H2 26200.9711. В гостя передаётся read-only пакет и отдельный каталог результатов;
репозиторий, `.private`, clipboard и периферия не передаются. На хосте
ExVPNService отсутствует. История подготовки: [SANDBOX_SETUP.md](SANDBOX_SETUP.md).

Первый запуск старого пакета выявил ошибку старта службы: результат
`FwpmFilterGetByKey0` оказался `0xffffffff80320003`, а сравнение ожидало
`0x80320003`. Теперь WFP результаты нормализуются как DWORD. Вторая проверка
обнаружила неверное сравнение строки ACL: SCM раскрывает GENERIC_ALL.
Теперь установщик и QA проверяют фактические права трёх ожидаемых principals;
избыточные права, дополнительные principals и неожиданные ACE отклоняются.
Go tests/vet и PS5.1 manifest/ACL/13 recovery/mutex tests прошли.

Исправленный пакет **34 911 581 байт**, SHA-256
`ce628f2b86d589d8d8e8ed20c98f42963cfdaa49433ca4e31c241775b9e36568`,
`artifacts/windows/package-0.1.0-1-20261016-140033-bb3a9336/ExVPN-0.1.0-1-windows-x64-development.exe`.
Он содержит исправленную службу/установщик и ранее проверенную release-сборку UI;
номер app build не менялся. Это unsigned development package, не beta или
версионная пара для upgrade. Исходники: [b2f4e42](https://github.com/Extectick/ExVPN/commit/b2f4e427075af5f5592904f0f6fdbdc82755af54).

Чистый bundle `artifacts/windows/sandbox-20261016-140217-fc13e6d9` прошёл
14:02:50–14:04:38 UTC:

- Проверка изоляции и хешей входных файлов.
- Silent install, точные файлы/защищённые ACL, LocalSystem SCM и Running.
- Проверка service DACL: SYSTEM/Administrators full, Interactive read/query only.
- Явный recovery останавливает службу; последующий запуск возвращает Running.
- Uninstall удаляет принадлежащие пакету деревья, службу и регистрацию.
- Хеши снимков маршрутов и DNS гостя до/после совпадают.

[Обезличенный результат](evidence/windows-sandbox-installer-smoke.json).
`networkTesting=false`: TUN не поднимался и защитные фильтры не активировались.
Это подтверждает работоспособность упаковки, а не сетевую приёмку.

Открыты: UI↔установленная служба, настоящий Windows TUN/HTTPS, DNS/IPv6,
исключения и аварии службы, version-pair upgrade/rollback, удаление после
активного VPN, sleep/resume, Windows10 и подпись выпуска.

Win32 API возвращает [DWORD](https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmfiltergetbykey0);
инструкции стенда: [INSTALLER.md](../native/windows/INSTALLER.md).

## Реальный TUN и отказы на диагностическом стенде (2026-10-16)

В открытом пользователем Sandbox выполнен production `Controller → WindowsGuard →
StartTunnel`, размещённый в отдельном QA executable. В приложение этот executable
не входит. Два других процесса выполняли HTTPS с обычной проверкой TLS, без
proxy и привязки сокетов к физическому интерфейсу. Один путь явно исключён.
Тестовый VLESS TCP-сервер находится в том же привилегированном QA-процессе,
слушает только loopback и выводит запросы через исходный физический интерфейс
гостя. Его единственный health hostname разрешается до захвата трафика,
имитируя DNS удалённого сервера. Секреты генерируются в памяти и не экспортируются.

Стенд обнаружил и проверил два исправления:

- WFP отклонял условия с `0x80320002`: три GUID отличались от Microsoft SDK.
  Регрессионный тест сверяет все используемые системные GUID с независимо
  установленным `fwpmu.h`, не меняя сеть тестовой машины.
- DNS на собственном адресе TUN доставлялся локально в Windows. Отдельный peer
  внутри каждого TUN subnet возвращает запросы в Xray; DNS остаётся перед
  исключениями и отправляется через VPN.

HTTPS 200 по числовому IP и 204 по доменному имени прошёл в обоих процессах.
TUN/fixture counters ненулевые. При закрытии VLESS-сервера оба HTTPS-запроса
защищаемого процесса отказали, исключённый сохранил доступ. Контроллер перешёл
в `reconnecting/transport_unreachable`. Очистка кеша Windows DNS Client повторила
результат; внутренний кеш Xray не очищался, поэтому это не полная проверка DNS
с холодным кешем. При hard kill QA-процесса TUN исчез, WFP остался, оба процесса
потеряли доступ. Explicit disconnect/recover удалил принадлежащие ExVPN фильтры,
восстановил HTTPS и исходные хеши маршрутов/DNS.

[Обезличенный отчёт](evidence/windows-sandbox-network-smoke.json).
Исходники исправлений: [c50f5cd](https://github.com/Extectick/ExVPN/commit/c50f5cd),
стенда: [9fdf035](https://github.com/Extectick/ExVPN/commit/9fdf035).
Команды находятся в `scripts/windows/sandbox/guest-system-qa.ps1` и требуют
подготовленного гостя, read-only input и отдельного writable output.

Новый пакет **34 905 498 байт**, SHA-256
`00f9331ba0f6a9be80756adcf19bb999215f9c23c6628b1f9863f2c0bd4677af`,
сохранён в `artifacts/windows/package-0.1.0-1-20261016-143621-2d5b8640`.
Установка с явно разрешённым network testing прошла, LocalSystem-служба и
процесс Flutter UI запущены. Пользователь остановил Computer Use нажатием Esc;
визуальная проверка и UI↔SCM connect/disconnect не приняты. Sandbox desktop token
имеет права администратора; эти испытания не подтверждают сценарий обычного
пользователя. На хосте ExVPNService отсутствует.

Остаются открыты: все протоколы и удалённый egress с разными IP, DNS/IPv6 capture,
уже открытые соединения при аварии, SCM crash, sleep/resume, смена сети, Windows10,
upgrade/rollback/uninstall после активного VPN и подписанный выпуск.

## Защищённое разрешение hostname (2026-10-16)

В службу добавлен endpoint DoH под ограниченным динамическим WFP-разрешением,
создаваемым после persistent guard и закрываемым до TUN. Подписка не меняет
резолвер, интерфейс или политику доступа. TLS bootstrap и healthcheck используют
офлайн-корни закреплённого Xray. Unit/config/lease/SDK tests, Go vet и service build
прошли. Исходники: [713b1a0](https://github.com/Extectick/ExVPN/commit/713b1a0ebb990e7b32a32e7544385fbc793bdc84).

Отдельный guest smoke подтвердил настоящий DoH A/AAAA, блокировку независимого
executable, запрет другого IP/порта, сохранение guard после закрытия разрешения
и восстановление HTTPS после disarm. Служба гостя восстановлена в Running,
TUN отсутствует. [Результат](evidence/windows-bootstrap-smoke.json),
[устройство механизма и открытая матрица](WINDOWS_DNS_BOOTSTRAP.md).
TUN/SCM не участвовали именно в этом smoke; он не подтверждает сквозной hostname VPN.

Пересобран unsigned development installer **34 945 907 байт**:
`artifacts/windows/package-0.1.0-1-20261016-151625-ec6fad76/ExVPN-0.1.0-1-windows-x64-development.exe`,
SHA-256 `7d4d0270c0c694722dcbdc755ede8d38682a33a46b2d182275aedc342bd2d715`.
В нём новый native service и прежняя проверенная release-сборка Flutter UI.
Payload/manifest и 136 component notices проверены сборкой NSIS. Этот пакет
ещё не устанавливался в гостя; там остаётся предыдущий пакет с SHA-256 `00f9331…`.
Это не подписанная beta и не принятая пара версий для upgrade.
