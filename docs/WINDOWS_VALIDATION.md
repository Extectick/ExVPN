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
- Сборка уведомлений собрала 136 компонентов; отдельно сохранены NSIS/MSVC terms.
  Это не завершённый release SBOM или проверка всего набора обязательств beta.
- Первый полный clean-checkout CI Android/Windows:
  [38880672529](https://github.com/Extectick/ExVPN/actions/runs/38880672529),
  исходники `f6cd4c4`; job Windows и выгрузка development bundle успешны.

Итоговый локальный установщик `ExVPN-0.1.0-1-windows-x64-development.exe`,
34 908 753 байта; SHA-256
`22cdfa1c1d71a859a7dad34c1a770f0732ce839c3486465b0a60d5b10780a553`.
Он не подписан Authenticode и не прошёл системную установку; сетевые испытания
по умолчанию отключены. Исходники упаковки: `scripts/windows/installer`.

Снимки: [главный экран](../design/qa/windows-native/2026-10-16-release-squirrel.jpg),
[версии](../design/qa/windows-native/2026-10-16-versions.jpg),
[отмена выбора QR](../design/qa/windows-native/2026-10-16-qr-picker-cancel.jpg).
Показываемая версия ядра сейчас является pin native adapter; запрос версии
фактически установленной службы требуется отдельно в E6.

## Изолированный стенд

`scripts/windows/prepare-sandbox.ps1` подготовил `.wsb`, но не запускал его.
В гостя передаётся только read-only payload установщика и отдельная пустая
записываемая папка результатов; репозиторий, `.private` и clipboard не передаются.
Guest runner проверяет установку/SCM/ACL, recovery, restart, uninstall и снимки
DNS/маршрутов до и после. Сетевые VPN-испытания выключены: даже успех этого
сценария не закрывает TUN/WFP/crash/upgrade-приёмку.

Включение компонента Windows Sandbox без перезагрузки завершилось `0x800F0831`.
Пользователь отдельно разрешил DISM RestoreHealth через Windows Update без
перезагрузки. На момент этой записи восстановление выполняется. Перезагрузка
требует отдельного согласования. Полные системные журналы остаются локальными.

Открыты: настоящий Windows TUN/HTTPS, DNS/IPv6 leak matrix, исключения и аварии
службы, установка/upgrade/rollback/uninstall, sleep/resume, Windows10 и подпись
выпуска. Подробные инструкции подготовки: [INSTALLER.md](../native/windows/INSTALLER.md).
