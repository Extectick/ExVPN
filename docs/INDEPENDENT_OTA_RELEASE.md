# Быстрый выпуск UI после принятия базы 0.1.10+32

Эти команды — шаблоны для оператора. Ничего здесь не запускалось. Подставить
SHA принятой базы, очередной номер патча, следующую общую revision каталога и
локальные пути. Ключи и значения secrets не выводить. Source должен быть clean
и committed; SemVer/build, native/assets/plugins/dependencies/engine базы не менять.

## GitHub Actions: собрать только AOT UI

```powershell
$BaseSource = '<SHA принятой 32-базы>'
$PatchNumber = '<следующий номер патча этой базы>'
gh workflow run independent-ota.yml --repo Extectick/ExVPN --ref main `
  -f operation=patch -f version=0.1.10+32 -f target=Both `
  -f base_source_commit=$BaseSource -f patch_number=$PatchNumber
```

`base_run_id` оставлен пустым намеренно: workflow берёт постоянные
`ExVPN-0.1.10-32-{android,windows}-ota-inputs.zip` из неизменяемого `v0.1.10`,
а не требует очередной native build или неистёкший Actions artifact.
Он проверяет защищённые inputs и точные compiler pins, затем kernel/gen_snapshot,
RSA подпись и diff. Shorebird API/account, Gradle/CMake/service/JNI не нужны.
CI загружает `independent-patch-{Android,Windows}-<UI source SHA>`; это ещё не публикация.

## Локально: тот же AOT с DPAPI-ключом только в памяти

```powershell
./scripts/ota/build-ui-patch.ps1 -BaseReceipt $WindowsBaseReceipt `
  -Target Windows -PatchNumber $PatchNumber `
  -ProtectedPrivateKeyPath .private/signing/shorebird/beta-private.dpapi
./scripts/ota/build-ui-patch.ps1 -BaseReceipt $AndroidBaseReceipt `
  -Target Android -PatchNumber $PatchNumber `
  -ProtectedPrivateKeyPath .private/signing/shorebird/beta-private.dpapi
```

`$WindowsBaseReceipt`/`$AndroidBaseReceipt` — `base-receipt.json` из принятых
баз или распакованных проверенных capsules. В локальном режиме приватный PEM
не создаётся. Два builder последовательно владеют общей Flutter build-директорией.
На холодном CI dependency cache отдельно вызывается `prepare-driver.ps1
-BaseReceipt ... -OnlineDependencies`; обычный AOT builder работает offline.

## Подписать каталог, опубликовать неизменяемые diff и затем pointer

Предыдущий `dart-updates.json` брать из актуального `ota-beta`, проверять подпись
и передавать `--previous`, чтобы сохранить все базы и накопленные отзывы.
`$CatalogSeedPath` — существующий защищённый локальный файл Ed25519 seed в `.private`;
это отдельная от RSA подпись каталога. Ключ не передавать аргументом как текст.

```powershell
$AssetTag = 'ota-0.1.10-32-p' + $PatchNumber
python scripts/ota/catalog.py --base-receipt $WindowsBaseReceipt `
  --base-receipt $AndroidBaseReceipt --patch-receipt $WindowsPatchReceipt `
  --patch-receipt $AndroidPatchReceipt --asset-tag $AssetTag `
  --previous $PreviousCatalog --revision $NextCatalogRevision `
  --key-file $CatalogSeedPath --output $NewCatalog
python scripts/ota/publish-catalog.py --catalog $NewCatalog `
  --base-receipt $WindowsBaseReceipt --base-receipt $AndroidBaseReceipt `
  --patch-receipt $WindowsPatchReceipt --patch-receipt $AndroidPatchReceipt `
  --asset-tag $AssetTag --publish
```

Publisher сначала сверяет RSA/хеши receipts, закрепляет immutable tag на UI source
commit, загружает diff без clobber, проверяет GitHub digests и только затем обновляет
маленький подписанный `ota-beta/dart-updates.json` с read-back. Существующие полные
APK/EXE и `v0.1.10` остаются теми же. До продвижения нужны релевантный UI smoke и
проверка применения; уже принятые неизменённые native/VPN матрицы не повторять.

## Отозвать патч и выполнить cold rollback

```powershell
python scripts/ota/catalog.py --base-receipt $WindowsBaseReceipt `
  --base-receipt $AndroidBaseReceipt --previous $NewCatalog `
  --withdraw $PatchNumber --revision $RollbackCatalogRevision `
  --key-file $CatalogSeedPath --output $RollbackCatalog
python scripts/ota/publish-catalog.py --catalog $RollbackCatalog `
  --base-receipt $WindowsBaseReceipt --base-receipt $AndroidBaseReceipt --publish
```

Revision всегда увеличивать; отозванный номер этой базы повторно не использовать.
Клиент должен получить отзыв, после чего нужен холодный запуск. Native updater
сам выбирает допустимый код; ручное удаление файлов updater не является проверкой отката.

Каталог действует не более 30 дней (по умолчанию 14): заранее подписывать новый
преемник с увеличенной revision и прежней историей, даже если UI не менялся.

## Когда нужен полный APK/EXE

Новые изображения, шрифты и глифы в урезанных icon fonts также являются
изменением ресурсов. Их нельзя доставить одним AOT-патчем; для UI-патча
использовать уже включённые ресурсы или отрисовку средствами Dart.

Только при изменениях защищённых native/assets/plugins/dependencies/engine или
SemVer/build, когда builder останавливается с incompatibility. Новая подписанная
база проходит отдельные build/package/runtime gates; её принятые байты и capsules
публикуются без подмены ordinary Flutter сборкой. Патч — исполняемый подписанный
AOT через закреплённый updater, а не произвольный пакет конфигурации VPN.
