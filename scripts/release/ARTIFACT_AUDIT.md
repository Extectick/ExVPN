# Проверка состава артефактов ExVPN

`audit-artifact.ps1` проверяет **уже собранный неизменяемый** APK или каталог
Windows package. Он сохраняет SHA-256 файлов, результат проверки подписей,
состав Go-модулей из фактических native binaries, соответствие notices и
воспроизводимый CycloneDX 1.6 JSON. Это отдельная проверка E7-002; она не
закрывает системную приёмку VPN и не объявляет development-пакет beta.

Нужны PowerShell 7, установленный закреплённый Go из `.tools/go`; для Android —
уже установленный Android build-tools **36.0.0** и JBR. Ничего не скачивается,
не собирается, не устанавливается и не подписывается. APK/EXE не запускаются.
Входные пакеты, SDK и рабочее дерево не изменяются; вывод разрешён только в
**новый** каталог `artifacts/release-audit/`. Старые отчёты не перезаписываются.

```powershell
pwsh -NoProfile -File scripts/release/test-artifact-audit.ps1

pwsh -NoProfile -File scripts/release/audit-artifact.ps1 `
  -ArtifactPath artifacts/android/build9/ExVPN-0.1.0-9-android-development.apk `
  -OutputDirectory artifacts/release-audit/android-build9-review

pwsh -NoProfile -File scripts/release/audit-artifact.ps1 `
  -ArtifactPath artifacts/windows/package-0.1.0-9-20261016-200717-fc397634 `
  -OutputDirectory artifacts/release-audit/windows-build9-review
```

Коды завершения: `2` — проверка выполнена, но выпуск блокируется найденными
пробелами; `1` — неверные входные данные, изменившийся вход или отказ инструмента.
`0` зарезервирован для проверки без блокирующих находок. Сейчас coverage намеренно
остаётся неполным: полный Dart/Flutter/Maven состав и проверка обязательств
распространения ещё требуют отдельной реализации/проверки. Не принимать `2` за
успех release job и не включать этот gate в быстрые unit-тесты с игнорированием
exit code. Быстрый цикл запускает только synthetic fixtures.

Выходные файлы:

- `audit.json` — версия из APK manifest / Windows UI EXE и package manifest,
  SHA-256 артефакта, отпечатки исходных pins и инструментов, подпись, counts,
  native build info и стабильные коды блокирующих находок.
- `sbom.cdx.json` — CycloneDX 1.6; реальные файлы APK либо **staged** Windows
  payload, реально указанные в binaries Go-модули и отдельно помеченные
  declarations из notice inventory. `compositions.aggregate` равен `incomplete`.
  Нет выдуманных SPDX license IDs, пустого dependency graph со смыслом
  «зависимостей нет» или подмены разрешённых pub-пакетов точным runtime graph.
- `audit.txt` — краткий читаемый отчёт. Извлечённые для инспекции native `.so`
  и Xray zip (если он внутри APK) остаются рядом; это копии без исполнения.

JSON не содержит времени, случайных UUID и абсолютных локальных путей. Порядок
коллекций стабилен. Одинаковые входы и версии tooling дают одинаковые JSON-байты;
изменение checkout pins обнаруживается в отчёте. Повторная проверка входных
хешей отвергает изменения пакета, Windows payload, sidecar и pins во время
инспекции. Это проверка согласованности, а не защита от злонамеренного процесса
с правами записи на тот же компьютер.

## Что проверяется

Windows: точный file set и SHA-256 всех трёх manifest trees; версии ресурсов
`ui/exvpn.exe`; SHA installer против `artifact.json`; реальная Authenticode;
embedded Go modules/GOOS/GOARCH/Go version из **payload/service/exvpn-service.exe**
против текущих `go.mod`/`go.sum`; Wintun/MSVC DLL hashes и NSIS pins. Проверяются
полные обязательные тексты в control, а не только слова о лицензиях в README.

Android: все реальные ZIP entries, обе обязательные ABI, собственный package ID,
versionName/versionCode, debuggable, `apksigner verify`, hash каждого native
бинарника и его build info. Notice bundle распознаётся только по одному из
фиксированных путей `assets/exvpn_notices/inventory.json` или
`assets/notices/inventory.json`. Исходники Xray могут поставляться как
`sources/xray-core.zip` относительно этого bundle.

Для обоих targets: app version в inventory, все notice hashes, exact native
path/hash/module binding, Dart lock hash и locked hosted package versions/hashes,
версии основных runtime notices, собственные LICENSE/NOTICE. Xray zip заново
хешируется алгоритмом Go `h1` и сравнивается с checksum модуля в binary и pins.
Проверка отвергает traversal/ADS/дублирующиеся пути, reparse points, ZIP symlinks,
file/directory collisions, повреждённые записи и превышение размеров.

`-ExpectedSignerSha256` принимает **публичный SHA-256 сертификата** ожидаемого
издателя. Без него неизвестный подписант не считается доверенным; Android
debug signer всегда блокирует выпуск. Ключи/пароли/PFX/JKS не читаются.
`-AndroidSdkPath` и `-JavaPath` позволяют указать уже установленный tooling.

## Notice inventory и границы доказательств

Принимается schema 1 сборщика с additive fields:

```text
app.version: 0.1.0+N
dartLockSha256: SHA-256 apps/exvpn/pubspec.lock
dartPackages: [{ name, version, source: hosted, sha256 }]
nativeBinaries: [{ name: payload-relative path, sha256, go, modules }]
components: [{ name, version, scope, notices: [{ path, sha256 }], moduleSum? }]
```

Native names: `service/exvpn-service.exe` для Windows,
`lib/arm64-v8a/libexvpn.so` и `lib/x86_64/libexvpn.so` для Android. Данные из
глобального `artifacts/windows/exvpn-service.exe` или соседней сборки не
подтверждают комплект: audit читает байты выбранного артефакта.

Для проверки исправленного сборщика можно передать `-NoticesDirectory` с
отдельным bundle. Выход будет явно `external-sidecar`, с блокировкой
`external_notices_are_not_artifact_contents`. Это **не исправляет уже собранный
installer/APK** и не доказывает доставку notices его получателю.

Windows payload остаётся staged: без независимого извлечения final NSIS EXE
или сверки установленного дерева в отдельном стенде сохраняется
`nsis_embedded_payload_not_independently_verified`. Audit не запускает
установщик на компьютере разработчика и не выдаёт compiler manifest за
извлечение EXE. Необходимы отдельные Android Gradle/Maven runtime inventory,
точный Dart/Flutter runtime состав, проверка installer components и прав
распространения. Успешный `h1` подтверждает соответствие исходного ZIP
**checksum, записанному в Go binary**; происхождение всей сборки и отсутствие
локальных изменений module cache требуют clean/reproducible build evidence.

Формат: [официальная схема CycloneDX 1.6](https://github.com/CycloneDX/specification/blob/1.6/schema/bom-1.6.schema.json).
Алгоритм source checksum: [Go dirhash Hash1 / HashZip](https://github.com/golang/mod/blob/v0.30.0/sumdb/dirhash/hash.go).
Эти схемы/реализации не скачиваются audit-командой и не добавлены как runtime
зависимости приложения.
