# Windows: трей и жизненный цикл окна

В **0.1.0+14** реализован трей. Исходники: собственный Win32
`TrayIcon`, канал `exvpn/tray` и общий `DesktopTrayController`. Новый Flutter
plugin не добавляется. Служба, IPC, TUN и WFP используют прежний контракт.

## Поведение

- Крестик сворачивает окно в трей. VPN-служба продолжает работу.
- Активация значка мышью/клавиатурой и повторный запуск ExVPN возвращают окно.
- Меню показывает фазу, полученную от существующего `VpnController`, и отдельные
  команды «Подключить VPN» / «Отключить VPN». Команда не является переключателем.
- Connect доступен только при подтверждённом disconnected, выбранном реальном
  профиле и отсутствии другой операции. Перед действием запрашивается состояние
  службы; изменение выбора или устаревшая команда отменяет действие.
- При blocked доступно явное Disconnect. Ошибка IPC не означает disconnected
  и не даёт разрешения на Connect из трея.
- «Выйти из ExVPN» открывает окно с пояснением: выход не меняет работу службы.
  Пользователь подтверждает выход; перед завершением сохраняются подписки.
  Ошибка/тайм-аут записи оставляет приложение открытым. Для отключения VPN
  применяется отдельная явная команда.
- Перед обновлением/удалением нужно выбрать «Выйти из ExVPN» в трее. Скрытое
  окно продолжает владеть mutex приложения, поэтому installer безопасно
  отклоняет maintenance при работающем UI. Сам maintenance затем выполняет
  явное отключение службы по своему прежнему контракту.
- Подписки, имена узлов, адреса, IP и секреты не передаются в shell tooltip/menu.
  Канал получает только фиксированную фазу и два bool-флага доступности команд.

## Win32

Значок использует `NOTIFYICON_VERSION_4`, собственный существующий ICO и
`LoadIconMetric`; Common-Controls v6 указан в manifest. После `TaskbarCreated`
значок создаётся заново, в том числе после смены DPI основной панели задач.
Если значок недоступен, окно не остаётся скрытым: Close открывает обычное
подтверждение выхода. Удаление значка/освобождение HICON выполняется при
завершении окна. Выход из вложенного message loop контекстного меню откладывает
уничтожение окна до закрытия меню.

Основания API: [NOTIFYICONDATAW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw),
[Shell_NotifyIcon](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyicona),
[TaskbarCreated](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar),
[TrackPopupMenu](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-trackpopupmenu).

## Проверка и оставшиеся границы

17 focused Dart tests проверяют native state, устаревшие/повторные команды,
изменение выбора, блокировку при OTA-операции, отказ IPC, выход/отмену/ошибку
сохранения, освобождение controller и сериализацию обновлений значка.
`flutter analyze` прошёл без замечаний. Независимый review проверил команды,
native lifetime и границу shell/VPN. Это не системная приёмка трея.

Windows release UI и unsigned NSIS development installer собраны из неизменных
исходников. Из EXE независимо извлечены и сверены 265 payload-файлов, две
maintenance scripts и закреплённые NSIS plugins. Пять release blockers, включая
подпись и незавершённую проверку лицензий, сохраняются.
[Отчёт сборки, отказов подготовки и аудита](evidence/windows-tray-build14.json).

После source freeze общий Full выполнил **10/10 наборов за 96,93 с**, включая
465 Dart/Flutter tests и прежние Go/installer/QA checks; Go result cache отключён,
исходники до/после совпали. [Отчёт](evidence/fast-validation-build14-tray.json).

GitHub CI того же +14 также завершил Android и Windows native build/test jobs
успешно. [CI evidence](evidence/ci-build14-tray.json). Это не заменяет проверки
установленного приложения ниже.

До закрытия EXVPN-E5-003 нужны реальные проверки установленного +14 в Windows:
обычный token, close/show, commands через службу и независимый HTTPS,
клавиатура, Explorer restart, DPI/несколько мониторов и выход при работающем
VPN. Сборка/автоматические tests не доказывают эти сценарии. Дизайн/DPI/IME и
полная E1 остаются открытыми. Исходники:
[e90e66b](https://github.com/Extectick/ExVPN/commit/e90e66bb59e1c2cc893eec8408b545e759fe3ddf).
