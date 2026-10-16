# Windows — сборка и границы проверки

Дата: 2026-10-16. Это development build, не принятая beta. Служба ExVPN,
драйвер TUN, WFP, маршруты и DNS на рабочем ПК не устанавливались и не менялись.

## Подтверждено

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

Итоговый локальный установщик `ExVPN-0.1.0-1-windows-x64-development.exe`,
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

## Изолированный стенд

`scripts/windows/prepare-sandbox.ps1` подготовил `.wsb`, но не запускал его.
Актуальный bundle: `artifacts/windows/sandbox-20261016-101046-951998fe/ExVPN-installer-qa.wsb`;
SHA-256 `.wsb`: `8373f72be382d11728299c8cfe63509bd6b620d5a50d58f196305fc602552bc8`.
Он ссылается на новую сборку с восстановлением при upgrade/rollback/uninstall
и machine-wide mutex.
В гостя передаётся только read-only payload установщика и отдельная пустая
записываемая папка результатов; репозиторий, `.private` и clipboard не передаются.
Guest runner проверяет установку/SCM/ACL, recovery, restart, uninstall и снимки
DNS/маршрутов до и после. Сетевые VPN-испытания выключены: даже успех этого
сценария не закрывает TUN/WFP/crash/upgrade-приёмку.

Включение компонента Windows Sandbox без перезагрузки завершилось `0x800F0831`.
Пользователь отдельно разрешил DISM RestoreHealth через Windows Update без
перезагрузки. По результату host setup от 2026-10-16 восстановление завершилось
ошибкой `0x800f0915`: необходимые repair contents недоступны. `NoRestart=true`,
перезагрузка не требуется результатом операции и не выполнялась. Новая попытка
Sandbox ждёт подходящего repair source; подготовленный `.wsb` не запускался.
Полные системные журналы остаются локальными.

Открыты: настоящий Windows TUN/HTTPS, DNS/IPv6 leak matrix, исключения и аварии
службы, установка/upgrade/rollback/uninstall, sleep/resume, Windows10 и подпись
выпуска. Подробные инструкции подготовки: [INSTALLER.md](../native/windows/INSTALLER.md).
