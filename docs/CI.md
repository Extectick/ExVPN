# Проверки и сборки CI

Workflow `.github/workflows/verify.yml` подготовлен для push, pull request и
ручного запуска. Два изолированных `windows-2025` job собирают Android и Windows
из одного checkout. До первого успешного GitHub run это конфигурация, а не
доказательство воспроизводимости или закрытия EXVPN-E7-001.

Скрипт `scripts/ci/verify.ps1 -Target Checks|Android|Windows` проверяет точные
Flutter/Go pins, lock-файлы Dart, анализ, все unit/widget/loopback-тесты,
Go checksums и vet. Android дополнительно собирает обе JNI ABI и APK;
Windows — UI, службу и проверенный Wintun archive. Команды не устанавливают
службу/драйвер и не меняют WFP, маршруты или DNS хоста.

Flutter и Go скачиваются с официальных URL с SHA-256 из toolchain lock.
Android packages: API36, build-tools36.0.0, NDK27.1.12297006 для собственного
ядра, NDK28.2.13676358 для Flutter plugins. Gradle/AGP/Kotlin закреплены в
Android source. Runner предоставляет JDK21 и VS C++/ATL/CMake/Windows SDK;
его образ обновляется GitHub, поэтому полная побитовая воспроизводимость
пока не заявляется. Новые SDK licenses автоматически не принимаются.

Workflow использует только `contents: read`; Git credentials не остаются в
checkout. Нет `pull_request_target`, signing secrets, приватной подписки,
production endpoints или публикации release. Actions закреплены полными SHA,
проверенными в официальных repositories: checkout7.0.1 и upload-artifact6.0.0.
Основание: [GitHub secure use](https://docs.github.com/en/actions/reference/security/secure-use).

Артефакты явно названы **debug/development**, хранятся семь дней. Debug APK
подписывается временным debug key runner и не является совместимым каналом
обновления пользовательской beta. Windows bundle ещё не является установщиком.
Для EXVPN-E7-002 нужен отдельный защищённый выпуск с постоянной подписью,
лицензиями/SBOM, приёмкой сети и проверкой обновления предыдущего пакета.

Первый clean-checkout [run 38878852742](https://github.com/Extectick/ExVPN/actions/runs/38878852742)
16 октября 2026 выявил ошибку чтения версии: первый старт Flutter печатает
bootstrap progress даже при `--version --machine`, поэтому JSON parsing падал
до тестов в обоих jobs. `flutter-version.ps1` сначала отдельно инициализирует CLI,
затем проверяет exit code и строгий JSON второго вызова. Проверены cold-start
fixture, ошибки обоих вызовов и настоящий закреплённый SDK. После исправления
нужен новый успешный clean-checkout run; локальные проверки его не заменяют.
