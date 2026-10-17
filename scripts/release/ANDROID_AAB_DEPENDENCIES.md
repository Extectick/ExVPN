# Быстрая проверка Maven-входов внутри AAB

`android-aab-dependencies.ps1` читает готовый AAB и за несколько секунд
сопоставляет записанные AGP SHA-256 с локальными AAR/JAR. Gradle, сборка
приложения, скачивание зависимостей и установка пакета не запускаются.
Это проверка входов, о которых сообщил сборщик; она не определяет классы,
оставшиеся после R8, и не заменяет лицензии, подпись или проверку VPN.

```powershell
pwsh -NoProfile -File scripts/release/android-aab-dependencies.ps1 `
  -AabPath artifacts/shorebird/<build>/ExVPN-0.1.0+16-shorebird-beta.aab `
  -ExpectedSha256 <sha256-этого-aab> `
  -OutputDirectory artifacts/qa/aab-inspection-new

pwsh -NoProfile -File scripts/release/test-android-aab-dependencies.ps1
# Дополнительно проверить настоящий protobuf parser из установленного AGP:
pwsh -NoProfile -File scripts/release/test-android-aab-dependencies.ps1 -WithPinnedParser
```

Нужны PowerShell 7, JDK 21+ и уже имеющиеся три JAR из Gradle cache.
`android-aab-dependencies.lock.json` фиксирует AGP 9.1.0, protobuf-java 3.25.5,
Gson 2.13.2 и SHA-256 каждого файла. Путь JDK и cache можно передать явно;
скачивание и автоматический выбор другой версии не предусмотрены.

Чтение `dependencies.pb` выполняет штатный generated parser AGP. Его schema
сверяется с закреплённым хешем [официального исходника](https://android.googlesource.com/platform/tools/base/+/2b8e201cce105f143339212b276c2f0eafb60b93/build-system/gradle-core/src/main/proto/app_bundle_dependencies_metadata.proto).
Ограничены размер, глубина protobuf, число узлов и рёбер. Неизвестные поля,
неверные типы, дубли координат, плохие индексы, пути, архивные ссылки и
дубли ZIP entries отклоняются. Повторные рёбра допустимы: AGP создаёт их
при объединении вариантов; их число сохраняется в результате.

Сопоставление требует точного GAV, classifier, имени AAR/JAR и SHA-256.
Недоступный, изменённый или неоднозначный binary вызывает отказ. Если сам
AGP не указал digest, запись остаётся в `unbound`; существование POM не
превращается в доказательство отсутствия binary. Пустой Maven-граф запрещён.
URL репозиториев попадают в decoded JSON только в виде хешей.

Выход разрешён только в новый каталог `artifacts/qa/`:

- `binding.json` — AAB/PB/schema/tool hashes, совпавшие binaries,
  незавершённые записи и явные границы проверки.
- `decoded.json` — структурированный граф, прочитанный из конкретного AAB.
- `inputs-local.json` — локальные пути и контрольные суммы для повторной
  проверки; не переносить в публичные доказательства.
- `dependencies.pb` — копия прочитанной записи; `failure.json` при отказе.

Код 0 означает завершение этой ограниченной инспекции. `status` всегда
сохраняет `LICENSE_COVERAGE_INCOMPLETE`. Код 1 означает отказ. Данные не
снимают blockers общего `audit-artifact.ps1` автоматически. Доказательство
одного AAB нельзя приписывать отдельно собранному APK, даже если версия
совпадает: APK требует собственной связи с тем же build invocation либо
проверенного получения из этого AAB.

Синтетические проверки сопоставления/ZIP включены в быстрый `scripts` lane.
Проверка generated parser включается явно, поскольку для неё нужны
закреплённые Gradle JAR; обычные unit tests их не скачивают.
