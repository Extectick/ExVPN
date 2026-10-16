# Зависимости и лицензии

Дата первичной проверки: **2026-10-16**. Это реестр решений и обязательств; строка «планируется» не означает, что компонент уже установлен или включён в бинарник.

## Основные компоненты

| Компонент | Версия / фиксация | Лицензия | Состояние и проверка |
|---|---|---|---|
| Собственный код ExVPN | Версия приложения задаётся в manifest проекта | Apache-2.0 | Полный текст находится в корневом `LICENSE`; собственное уведомление — `NOTICE` |
| Flutter | **3.47.7**, commit `abaf9c523780a608bd46686fd5e53740a07077f8` | BSD-3-Clause; отдельные зависимости engine имеют свои лицензии | Версия/SHA-256 архива в `scripts/bootstrap/toolchain.lock.json`; [официальный LICENSE](https://github.com/flutter/flutter/blob/master/LICENSE) проверен; полный состав проверять по фактическому SDK |
| Dart SDK | **3.13.5**, поставляется с закреплённым Flutter | BSD-3-Clause; зависимости имеют отдельные лицензии | Использован для `dart analyze`/113 тестов domain-пакета; [официальный LICENSE](https://github.com/dart-lang/sdk/blob/main/LICENSE) |
| Xray-core | **v26.10.10**, исследовательский prerelease; commit `701af60772cda123492f86e383e1fdba066614a9` | MPL-2.0 | Pin в `native/core/go.mod`/`go.sum`; [LICENSE тега](https://github.com/XTLS/Xray-core/blob/v26.10.10/LICENSE), проверен; системные проверки E1 отдельно |
| libXray | Исследовательский commit `4e1f7843e6cddb750ac7abc23ef36800820a8098` | MIT | Pin записан в `native/core/config.go`; полноценная Android/iOS bridge-интеграция ещё не подтверждена; [официальный LICENSE](https://github.com/XTLS/libXray/blob/main/LICENSE) |
| Go | **1.27.2**; native module требует минимум 1.27.1 | BSD-3-Clause; сторонние модули отдельно | SDK/SHA-256 в `scripts/bootstrap/toolchain.lock.json`; [официальный LICENSE](https://go.dev/LICENSE); зависимости в `native/core/go.sum` |
| Microsoft `go-winio` | **0.6.2**, `native/windows/go.mod` / `go.sum` | MIT | Локальный LICENSE закреплённого модуля проверен; Windows named-pipe IPC. Версия и Go checksum сверяются с build info служебного EXE при сборе notices |
| WireGuard Go / Windows helpers / Wintun Go binding | **wireguard 20250521-f333402bd9cb**, **windows 1.1.1**, **wintun 20230126-0fa3db229ce2** | MIT; полные LICENSE/COPYING модулей сохраняются отдельно | Закреплены в Go graph; LICENSE/COPYING проверены локально. Binding не заменяет отдельную лицензию распространяемой DLL |
| Wintun prebuilt DLL x64 | **0.14.1**, архив и DLL SHA-256 в `scripts/windows/wintun.lock.json` | **Wintun Prebuilt Binaries License** | Полный текст из официального архива сохранён вместе с DLL; не маркировать бинарник MIT/Apache. Комплект notices включает этот текст отдельно от Go binding |
| Dart `crypto` | **3.0.7**, `packages/exvpn_domain/pubspec.lock` | BSD-3-Clause | Используется для стабильных SHA-256 ID профилей; LICENSE установленного пакета проверен локально |
| Dart `cryptography` | **2.9.0**, точный pin `packages/exvpn_updates/pubspec.yaml` / lock | Apache-2.0 | Ed25519 проверка точных байтов manifest OTA; локальные LICENSE/исходники версии проверены, копия в `packages/exvpn_updates/third_party`. SHA-256 использует тот же `crypto 3.0.7`; пакет ещё не интегрирован в app |
| Dart `pointycastle` | **4.0.0**, dev dependency `packages/exvpn_updates/pubspec.lock` | MIT | Только генерация RSA-сертификата в памяти для localhost HTTPS tests, не runtime приложения. LICENSE версии проверен и сохранён в `packages/exvpn_updates/third_party` |
| Dart `http` | **1.6.0**, `apps/exvpn/pubspec.lock` | BSD-3-Clause | HTTPS streaming/AbortableRequest; LICENSE установленного пакета проверен локально. 35 тестов bounded loader; сертификаты не обходятся |
| `flutter_secure_storage` | **11.2.0**, точный pin в app pubspec/lock | BSD-3-Clause | Проверены исходники и LICENSE установленной версии. Android Keystore RSA-OAEP/AES-GCM, resetOnError=false; Web отключён. Windows-плагин 4.2.2 остаётся transitive dependency, его неатомарный file backend не используется для подписок |
| Android NDK для зависимостей Flutter | **28.2.13676358** | Android NDK notices и лицензии отдельных компонентов | Требуется Android-сборкой JNI-зависимостей secure storage; установка использует уже принятые локальные SDK licenses. Не заменяет **27.1.12297006**, закреплённый для собственного Go/Xray JNI; оба NDK должны быть воспроизводимо доступны в CI |
| `win32` / `ffi` / `path_provider` | **6.4.0 / 2.2.0 / 2.1.6**, точные app pins | BSD-3-Clause | Локальные LICENSE проверены. Собственный Windows backend: current-user DPAPI + атомарная замена шифрованных файлов; реальный DPAPI round-trip/delete тест пройден. Детали в `SECURE_STORAGE.md` |
| Inter | Файл `apps/exvpn/assets/fonts/Inter.ttf`, SHA-256 `29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031` | SIL Open Font License 1.1 | Шрифт включён локально; полный OFL в `apps/exvpn/assets/fonts/OFL.txt`, copyright Inter Project Authors. Версия фиксируется самим файлом/хешем, не внешним CDN |
| Material Icons | Font artifact закреплённого Flutter 3.47.7 | В поставленном SDK: CC BY 4.0 | Проверен локальный `artifacts/material_fonts/materialicons_license.txt` (Attribution 4.0 International); копия в `apps/exvpn/assets/licenses/MaterialIcons.txt`, атрибуция Google в `SOURCES.md`. Проверить включение уведомлений в итоговый пакет |
| Cupertino Icons | **1.0.9**, `apps/exvpn/pubspec.lock` | MIT | Пакет используется через Flutter `CupertinoIcons`; локальный LICENSE проверен, copyright 2016 Vladimir Kharlampidi. Копия — `apps/exvpn/assets/licenses/CupertinoIcons.txt`; проверить комплект выпуска |
| Флаги стран | Локальные изображения в `apps/exvpn/assets/flags/`, источник FlagCDN | Государственная символика; происхождение/условия конкретных файлов сохраняются отдельно | Используются неизменённые флаги NL/DE/FI/PL/SE/FR. Источник и размеры записаны в `apps/exvpn/assets/SOURCES.md`; финальная проверка комплекта выпуска остаётся открытой |
| Dart `test` / `lints` | **1.33.0 / 6.1.0**, domain lock-файл | BSD-3-Clause | Только dev dependencies; LICENSE установленных пакетов проверены локально |
| Kotlin / Android Gradle plugin / Gradle | **2.4.0 / 9.1.0 / 9.3.1**, Android settings/wrapper | Apache-2.0 и лицензии транзитивных компонентов | Версии закреплены в исходниках, обе Android ABI собраны; runtime Maven notices проверяются отдельно от Go/Dart inventory |
| Shorebird | CLI/runtime/package фиксируются перед E6 | Лицензии конкретных компонентов + условия облачного сервиса | [Документация](https://docs.shorebird.dev/), [репозиторий](https://github.com/shorebirdtech/shorebird), [тарифы](https://shorebird.dev/pricing/); не объявлять сервис библиотекой с единой OSS-лицензией |
| NSIS | **3.13**, официальный SourceForge ZIP и SHA-256 в `scripts/windows/nsis.lock.json`; проверяются все распакованные файлы SDK | zlib/libpng; bzip2; CPL-1.0 для LZMA с указанным upstream исключением | Лицензия закреплённого ZIP сохранена в `native/windows/licenses/NSIS-3.13.txt` и payload. Только встроенные System/nsDialogs/nsExec; внешних plugins нет. Offline compilation прошла, unsigned development installer; установка/upgrade/rollback на Windows-стенде ещё не приняты |

Плагины защищённого хранилища, QR, проверки подписей, системные TUN-библиотеки/драйверы и Flutter packages добавляются отдельными строками после выбора конкретных версий. Не считать их автоматически покрытыми Apache-2.0 ExVPN. Итоговый реестр и SBOM должны соответствовать lock-файлам и фактическому комплекту выпуска.

## Условия подготовки бинарного выпуска

Генератор полного текста доступных notices и границы инвентаризации описаны в
[RELEASE_NOTICES.md](RELEASE_NOTICES.md). Он сверяет реальные Go build info/checksums,
сохраняет Xray source zip и не подменяет отдельный release SBOM.

- Сохранить авторские уведомления и полный текст лицензий фактически поставляемых библиотек, драйверов и runtime-компонентов.
- Для Xray/MPL-2.0 предоставить получателям доступ к соответствующим исходникам и изменениям покрытых файлов, включая точный commit и инструкции получения. Собственная Apache-лицензия не заменяет эти обязательства.
- Для libXray/MIT и BSD-компонентов включить требуемые copyright/license/disclaimer notices.
- Добавить зависимости Flutter engine, пакетов Dart, Go modules, Android build/runtime и installer plugins; не ограничиваться прямыми зависимостями.
- Сверить лицензии выбранных versions/commits повторно перед релизом: ссылки `main`/`master` в этом начальном реестре служат источниками для выбора, а не неизменяемыми доказательствами релиза.
- Сформировать SBOM и комплект уведомлений для каждого Android ABI и Windows-пакета. Сверить состав с реально упакованными файлами.
- Подписи Android/Windows, доступ к Shorebird и учётные данные магазинов хранить вне Git; проверять наличие прав и ключей до обещания релиза.

## Функциональные ориентиры

HAPP и Hiddify не входят в зависимости ExVPN. Из них не скопированы код, логотипы или дизайн-ресурсы. Перед заимствованием любого компонента требуется отдельная проверка лицензии конкретной версии; начальный план указывает на ограничения NonCommercial в [лицензии Hiddify](https://github.com/hiddify/hiddify-app/blob/main/LICENSE.md). Выбор собственного клиента не отменяет обязанности проверять все реально используемые сторонние компоненты.
