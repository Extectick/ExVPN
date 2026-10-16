# ExVPN — Flutter-клиент

Общий интерфейс Android, Windows, Linux и iOS; web используется как стенд визуальной проверки. Реализуется выбранный пользователем графитовый макет с янтарным акцентом, контурной белкой, кнопкой подключения и сворачиваемыми группами подписок.

Это технический прототип с native bridge Android/Windows. Android VpnService, TUN и реальный HTTPS проверены в эмуляторе; Windows-служба/IPC/установщик реализованы и собраны, системная приёмка ещё открыта. Состояние подключения приходит от службы. Web используется для визуальной проверки и не перенаправляет трафик браузера через VPN.

## Запуск из рабочего каталога

В PowerShell 7, из корня `V:\GitProjects\ExVPN`:

```powershell
. ./scripts/bootstrap/enter-environment.ps1
Set-Location apps/exvpn
flutter pub get --enforce-lockfile
flutter run -d chrome
```

Скрипт использует локальные Flutter **3.47.7** / Dart **3.13.5**, закреплённые в `scripts/bootstrap/toolchain.lock.json`, и меняет окружение только текущего процесса. Зависимости приложения закреплены `pubspec.lock`. Версия приложения задаётся в `pubspec.yaml` как SemVer и build number.

Первый обычный запуск открывает пустое состояние без вымышленных подписок. Android сохраняет подписки через Keystore, Windows — через DPAPI; запись защищена журналом. Ошибка защищённого backend не включает открытое хранение. В web данные остаются только в памяти. Для визуальной проверки заполненного экрана можно явно включить синтетические примеры:

```powershell
flutter run -d chrome --dart-define=EXVPN_DEMO=true
```

Для web доступен также параметр `?demo=1` в URL локального стенда. Примерные серверы и задержки демонстрационные; они не подтверждают реальное соединение.

## Проверка и сборка web-стенда

Из `apps/exvpn`:

```powershell
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn
```

Статика находится в `build/web`. Для локального просмотра:

```powershell
python -m http.server 8127 --bind 127.0.0.1 --directory build/web
```

Открыть `http://127.0.0.1:8127/`; для заполненного экрана — `http://127.0.0.1:8127/?demo=1`. Проверять узкую и широкую ширину окна, сворачивание групп, выбор узла, импорт, пустое состояние и темы. Скриншоты стенда не заменяют испытания физического Android-устройства и Windows-приложения.

HTTPS-загрузчик отказывает при редиректах, превышении 2 MiB, ошибке UTF-8 и истечении общего 15-секундного таймаута. В web сторонний провайдер должен разрешать CORS; отказ браузера отображается безопасной сетевой ошибкой. Прокси для обхода CORS не добавлен. Реальные ключи, URL подписок и приватные профили нельзя помещать в исходники, команды, скриншоты или опубликованные журналы.

## Нативные хосты и ограничения сборки

- **Android:** минимум Android 11 / API 30. Собственное ядро использует NDK `27.1.12297006`, app/plugins — `28.2.13676358`. В manifest объявлены VpnService и foreground service; cleartext HTTP отключён. SDK подготовлен, APK с arm64-v8a/x86_64 собран. Команды подготовки JNI и APK: [native/android/README.md](../../native/android/README.md); фактическая матрица: [ANDROID_VALIDATION.md](../../docs/ANDROID_VALIDATION.md). Debug APK не является подписанным release; физическое устройство ещё не проверено.
- **Windows:** MSVC, CMake, Windows SDK и ATL установлены. Flutter debug/release x64, Go-служба и NSIS development installer собраны. Служба/драйвер на рабочем ПК не устанавливались; В Sandbox прошли install/ACL/recovery/restart/uninstall без активного VPN; TUN/WFP/upgrade остаются открытыми. Команды: [native/windows/README.md](../../native/windows/README.md), результаты: [WINDOWS_VALIDATION.md](../../docs/WINDOWS_VALIDATION.md).
- **Linux:** сборка `flutter build linux` выполняется на Linux после подготовки Flutter toolchain. Заголовок окна — ExVPN; системный VPN-адаптер и упаковка относятся к E8.
- **iOS:** display name — ExVPN. Для сборки требуются macOS/Xcode и отдельная настройка signing/entitlements; Packet Tunnel ещё не реализован. Проверочные сборки на Windows невозможны.

Назначение bundle/application IDs и подпись магазинных выпусков подлежат отдельной проверке. Flutter launcher icons не являются утверждённым комплектом иконок выпуска. Web metadata уже использует ExVPN и графитовую тему; ссылки на шаблонные Flutter favicon/PWA icons отключены до экспорта утверждённой белки.

Импорт PNG/JPEG QR требует подтверждения перед добавлением или загрузкой ссылки.
Экран версий поддерживает подписанные данные OTA; доверенные endpoint/key задаются
при сборке, доставка по умолчанию выключена. Реальный Android QA откат проверен,
production доставка и Shorebird ещё не настроены. Подробности:
[QR_IMPORT.md](../../docs/QR_IMPORT.md), [DATA_UPDATES.md](../../docs/DATA_UPDATES.md).

Состояние этапов и критерии готовности: [`docs/CHECKLIST.md`](../../docs/CHECKLIST.md), архитектура: [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md). E1 остаётся открытым до системных испытаний протоколов, исключений, DNS и kill switch.
