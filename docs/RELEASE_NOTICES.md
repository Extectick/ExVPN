# Комплект лицензий перед упаковкой

`scripts/release/collect-notices.ps1` формирует отдельный каталог с полными
лицензиями и `inventory.json`. Входом служат уже собранные Go-бинарники и
разрешённые пакеты Flutter, а не вручную составленный список названий.

```powershell
./scripts/release/collect-notices.ps1 -Target Windows -OutputDirectory artifacts/notices/windows-build-1
./scripts/release/collect-notices.ps1 -Target Android -OutputDirectory artifacts/notices/android-build-1
```

Выходной каталог должен быть новым: скрипт не удаляет старые доказательства.
Перед Windows-запуском нужны `scripts/windows/build.ps1` и
`scripts/windows/prepare-wintun.ps1`; перед Android — `native/android/build.ps1`.
`flutter pub get --enforce-lockfile` должен уже разрешить зависимости приложения.

## Что собирается

- SHA-256 каждого native binary, версия Go и фактически включённые модули из
  `go version -m -json`. Внешние replace без отдельной проверки отклоняются.
- Точные Go-исходники из module cache/download с проверкой checksum по embedded
  build info. Собираются LICENSE, COPYING, NOTICE, AUTHORS и PATENTS, включая
  вложенные уведомления. Неизвестный компонент без текста лицензии останавливает
  подготовку.
- Полный неизменённый source zip закреплённого Xray и его MPL-2.0. Исходники ExVPN
  и собственные изменения находятся в публичном репозитории.
- Flutter engine/framework, Dart/Go runtime, Inter и лицензии иконок.
- Wintun DLL: отдельный **Prebuilt Binaries License**, а не MIT-лицензия Go binding.
- Dart/pub зависимости из package config. Это консервативный список: включает
  также разрешённые dev-пакеты, поэтому не выдаётся за точный список линковки.

2026-10-16: локальные сборы завершены для Windows (120 записей) и двух Android ABI
(119 записей). Это проверка генератора на текущих сборках; новый комплект надо
собирать после изменения зависимостей/бинарников. Файлы в `artifacts/` не входят
в Git, но соответствующая папка notices включается в поставляемый пакет.

## Незакрытая часть release gate

Эта инвентаризация не является полным SBOM: Gradle/Maven runtime, отдельные NSIS
компоненты и комплект Windows runtime проверяются дополнительно по фактическому
пакету. Проверка совместимости лицензий, подписи и воспроизводимости выпуска
остаётся в E7. Наличие notices само по себе не подтверждает готовность beta.
