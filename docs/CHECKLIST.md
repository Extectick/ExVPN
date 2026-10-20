# ExVPN — проверяемый чеклист

Начало проекта: **2026-10-16**. Источник требований: [PLAN.md](PLAN.md); границы компонентов: [ARCHITECTURE.md](ARCHITECTURE.md).

`[ ]` — работа не завершена или не подтверждена; `[x]` — критерий проверен. Стабильный ID не переиспользуется. У закрытого пункта указываются дата, проверка и commit/PR. Пока изменения не закоммичены, используется явная пометка «рабочее дерево; commit ожидается»; после публикации её заменяют ссылкой. Ссылка на задачу Linear/GitHub не является доказательством проверки.

## Протоколы и WireGuard — кандидат 0.1.14+36, 2026-10-21

- [ ] **EXVPN-E3-014** — Расширить популярные безопасные форматы импорта:
  WireGuard URI/INI/current sing-box endpoints, VMess/Trojan/Shadowsocks/gRPC,
  нейтральные REALITY/TCP aliases. Критерий: import/snapshot/native parity,
  отрицательные типы/credentials/policy, реальный трафик. Рабочее дерево;
  commit ожидается. Full12/12 PASS за117,94с, app482/domain225/state92, source
  unchanged; scoped analyze clean. Platform runtime ещё не завершён.
- [ ] **EXVPN-E3-015** — Добавить MASQUE закреплённого Xray: QUIC/TLS, обязательные
  SNI/credentials, фиксированная локальная DNS-политика. Критерий: import/native
  schema и verified TLS/IPv4/IPv6/DNS, неверная auth/CA/SNI блокирует трафик,
  отсутствие direct fallback, стабильный Close/recreate. Не считать feature
  принятой по одному Config OK. Рабочее дерево; commit ожидается.
- [ ] **EXVPN-E1-013** — Проверить WireGuard через системный TUN Android/Windows:
  независимый процесс, HTTPS IPv4/IPv6/DNS, отказ сервера с сохранённой защитой,
  восстановление, несколько циклов и корректный cleanup. Userspace core fixtures
  отдельно подтверждают IPv4/IPv6 HTTPS, UDP/DNS, неверные ключи и down/up;
  они не заменяют platform leak/physical acceptance. Рабочее дерево; commit ожидается.

Общий результат: [Full](evidence/fast-validation-v0.1.14.json),
[протокольные проверки исходников](evidence/protocols36-source.json). В первом
Full11 наборов прошли, QA runner нашёл устаревший ожидаемый счётчик suites;
после исправления выполнен один итоговый неизменный Full12/12. Это не ошибка
соединения и не новая приёмка физического устройства или MASQUE TUN.

## Публикация 0.1.13+35 — 2026-10-20

- [x] Preview Android/Windows из `f243e92` опубликован без пересборки принятого
  APK. Оба подписанных package feed предлагают35; OTA-каталог revision10
  содержит новую базу, прежние базы и отзывы. Публикация сохраняет прошедший
  Full как passed и связывает его отчёт с Git/blob и SHA, вместо ложного
  not_run. Release tooling/notes: `f604e8d`;9 новых и108 прежних локальных
  publication guards прошли до последнего требования пользователя не проверять.
- [ ] Windows35 runtime, физический APK35, HyperOS «Закрыть всё» и OTA35
  apply/rollback. По прямому поручению пользователя дополнительная приёмка
  перед публикацией не выполнялась; существующие Android35 результаты сохранены.

[Выпуск](https://github.com/Extectick/ExVPN/releases/tag/v0.1.13),
[квитанция](evidence/release-v0.1.13.json). Это не закрывает общий E1/stable.

## Android permission setup — 0.1.13+35, 2026-10-20

Дополнение **EXVPN-E4-006**: 9 focused recovery/DTO/lifecycle tests PASS и scoped
analyze без замечаний. API36 на старой 0.1.12+34 подтверждает настоящий consent
и HTTPS через VPN из отдельного UID; другой Always-on без lockdown воспроизводит
скрытую отмену и точное старое сообщение об отсутствии разрешения.
Добавлены recovery с крестиком, явный retry, фиксированные VPN/app settings,
публичный admin restriction и последовательный необязательный notification prompt.
На этом этапе исправленный APK и Redmi15 пользователя ещё не были приняты;
последующие наблюдения приведены ниже. Общий критерий остаётся открытым.
[Контракт](ANDROID_VPN_PERMISSION_SETUP.md).
Итоговый Full после freeze всех исходников: **12/12 PASS, 101,31с**, app476 tests,
fingerprint unchanged. [Отчёт](evidence/fast-validation-android-consent35.json).
Первый Full нашёл устаревшее ожидание сообщения и начальную арбитражную ошибку
full/staged OTA; исправления и 48 focused regressions вошли в итоговый прогон.
[API36 baseline](evidence/android-consent34-api36-baseline.json) не является
приёмкой нового APK или физического Redmi.
Исходники начального recovery `f39b681`.

Дополнение **EXVPN-E4-006/E4-001**, физический Redmi15/API36: на установленной
0.1.12+34 найден другой Always-on в пространстве ExVPN. После его отключения
пользователем появился системный запрос; grant, foreground service и owned VPN
network наблюдены. Уведомление разрешено и содержит «Отключить». Свежий swipe
только ExVPN сохранил службу/TUN, exit-info unchanged. Исторические OEM clean exits
не объявляются исправленными. Новый UI9 даёт три шага настройки и notification
settings, read notification не вызывает VPN prepare. Приёмка финального APK35
приведена ниже; Force stop/Task Manager Stop не обходятся. Общие E1/E4 открыты.
[Контракт и точные границы](ANDROID_VPN_PERMISSION_SETUP.md).

Итог UI9 после freeze всех агентов: **12/12 PASS, 104,54с, app482 tests**,
fingerprint unchanged. [Full](evidence/fast-validation-android-guidance35-ui9.json).
Отдельные15 focused tests подтверждают явный retry, три шага, одно напоминание,
постоянную строку notification settings и отсутствие VPN prepare при notification
read. [Промежуточный runtime и физические наблюдения](evidence/android-consent35-intermediate-runtime.json)
точно отделяют опубликованный34 и промежуточный35/UI8 от итогового35/UI9.

Проверенные подэтапы **EXVPN-E4-006/E4-001**, 2026-10-20, исходники `f243e92`,
финальный подписанный Android APK35/UI9:

- [x] API36: настоящая отмена, три шага помощи, VPN settings, возврат без
  auto-connect, явный retry и настоящее системное разрешение.
- [x] Напоминание открывает только уведомления ExVPN; после системного
  переключателя строка в приложении обновляется до Enabled.
- [x] После удаления двух карточек ExVPN служба остаётся foreground; отдельный
  UID получает HTTPS200 через VPN с отличающимся внешним IPv4 и успешный DNS.
- [x] Настоящая кнопка уведомления «Отключить» убирает службу и VPN-сеть,
  не открывая Activity.
- [ ] Физическая приёмка35, свежий HyperOS «Закрыть всё» и полная IPv6/DNS/security
  матрица. На телефоне оставлена работающая34; общий E1 не закрыт.

[Финальное доказательство](evidence/android-guidance35-api36-runtime.json),
[уведомление](evidence/android35-vpn-notification.png). При фиксации этого runtime
кандидат был локальным. Последующий выпуск обеих платформ описан выше.

## Обновление 0.1.12+34 с ручной приёмкой пользователя — 2026-10-20

- [ ] **EXVPN-E6-019** — Проверять новые версии при открытии/возврате/разворачивании
  приложения. В исходниках добавлены lifecycle/focus и native Windows shown,
  coalescing5с и сериализация busy/check/prepared. Критерий: реальный клиент
  находит опубликованное обновление без полного перезапуска и не повторяет
  installer/native handoff. По запросу пользователя тесты/runtime не запускаются;
  принятие пользователем ожидается. Исходники `ec1a443`, выпуск0.1.12+34.
- [ ] **EXVPN-E6-020** — Android background APK download и восстановление после
  разрыва сети. В исходниках private persisted JobScheduler, Range partial и
  восстановление прогресса; SHA/size/Ed25519 offer и APK signer guards сохранены.
  Критерий: загрузка продолжается в фоне и после восстановления сети, повреждённый
  пакет не устанавливается. Тесты/runtime не запускаются по запросу пользователя;
  приёмка на его телефоне ожидается. Исходники `ec1a443`, выпуск0.1.12+34.

Дополнение **EXVPN-E4-006**: foreground consent coordinator убирает прежний
ложный lifecycle-отказ через1,2с; только настоящий grant разрешает запуск службы,
реальный отказ не повторяется автоматически. Критерий системного запроса на
проблемном телефоне остаётся открытым; по запросу проверки не выполнялись.
Новая версия требует полной native-базы, совместимые дальнейшие UI — AOT-патчи.
Публикация выполнена2026-10-20: один Windows build3мин5с и один Android build3мин39с,
JVM/tests/runtime не запускались; подпись/упаковка и publisher binding сохранены.
Immutable tag `v0.1.12` указывает на `ec1a443`; оба full-update feeds рекламируют
0.1.12+34, подписанный OTA-каталог revision9 содержит новую базу без тестового патча.
[Выпуск](https://github.com/Extectick/ExVPN/releases/tag/v0.1.12),
[точные пакеты и статус ручной приёмки](evidence/release-v0.1.12-manual.json).
Эти сведения подтверждают публикацию, а не выполнение открытых критериев выше.

## Совместимость и резервные серверы — 2026-10-20

- [x] **EXVPN-E3-013** — Поддержать дополнительные протоколы закреплённого Xray.
  Проверено 2026-10-20: строгие SOCKS5 TCP/TLS, HTTP/HTTPS CONNECT и WireGuard
  (один peer, userspace) проходят импорт, снимки, native-проверку и HTTPS через
  независимые управляемые endpoints; WireGuard проверен по IPv4/IPv6.
  Full финального `c20da08`: 12/12 PASS, 398 app, 206 domain, 84 state tests,
  fingerprint unchanged. Исходники `19a017d`, упаковка `c20da08`.
  [Отчёт](evidence/fast-validation-v0.1.9.json), [границы](releases/0.1.9.md).
  Это проверка реализации, не приёмка каждого протокола на физических устройствах.
  SOCKS/HTTP блокируют UDP, включая исключённые приложения, кроме локальной
  обработки DNS. TUIC/OpenVPN отсутствуют в этом ядре и не добавлены.
- [x] **EXVPN-E3-011** — Строгий импорт показанных расширений Xray/Hiddify.
  Критерий: keepalive и XUDP/WS нормализованы, privileged socket options и
  insecure отклонены, снимок сохраняет типизированные поля, заглушка не становится
  сервером. Проверено: 201 domain и 82 state tests PASS; реальные примеры
  27/2/1 записей, native Compile 30/30. HTTPS через loopback подтвердился 4/18;
  остальные подключения рабочими не объявлены. Исходники: `1d99998`.
  [Контракт](SUBSCRIPTION_COMPATIBILITY_AND_FAILOVER.md),
  [обезличенные результаты](evidence/subscription-compatibility-20261020.json).
- [x] **EXVPN-E3-012** — Локальная automatic group и native supervisor в исходниках.
  Критерий: явное включение пользователем, максимум32 без усечения,
  native HTTPS-состояния, пауза после обхода, сохранение guard/TUN в ветке замены,
  отмена/epoch, отсутствие direct fallback и остановка на ошибках защиты.
  Проверено: Go native suites, 21 controller automatic tests в составе
  398 app tests, 5 Kotlin policy tests; C++ compile и Kotlin host typecheck.
  Full прошёл 11 lanes; app остановился на двух lint-скобках, исправлен и целиком
  повторён: analyzer clean, 398 PASS. Повтор остальных11 lanes не выполнялся.
  Это source/synthetic-проверки, не runtime-приёмка VPN. Исходники: `1d99998`.
  [Границы](SUBSCRIPTION_COMPATIBILITY_AND_FAILOVER.md).
- [ ] **EXVPN-E1-012** — Проверить native primary→backup на Android/Windows с TUN.
  Критерий: отдельный стенд, реальный HTTPS при отказе основного и закрытом UI,
  полный отказ группы, IPv4/IPv6/DNS и исключения во время замены, смена сети,
  отмена без позднего подключения. Требуется новая Shorebird-база: изменения
  Kotlin/Go/C++ нельзя доставить Dart-патчем базы0.1.8+29. Физический Android и
    общая E1-приёмка остаются открытыми. Установленный клиент хоста не менялся.
    2026-10-20: ограниченные TUN-матрицы приняты для точных CI-пакетов0.1.9+30
    (`f98b75d`): Android VpnService, Windows production Controller и отдельный
    установленный SCM/UI. HTTPS IPv4/IPv6, primary→backup, полный отказ группы,
    числовой прямой IPv4 исключения и bounded DNS observations подтверждены.
    [Android](evidence/android30-failover-runtime.json),
    [Windows Controller](evidence/windows30-failover-runtime.json),
    [Windows SCM](evidence/windows30-installed-runtime.json).
    Коммиты51079e9/c53094f/aecd17d. Смена underlay, поздняя отмена, физический
    Android и положительный контроль native IPv6 underlay ещё не приняты;
    отметка задачи не закрывается этими ограниченными результатами.

## Сводка этапов

- [x] **EXVPN-E6-016** — Принять и опубликовать новую Shorebird-базу0.1.9+30
  после расширения native-протоколов. Проверено2026-10-20: base `f98b75d`,
  CI39319816470, signed patches Windows1/732154 и Android2/732166 из `1be30d5`,
  cloud rollback39328414028. На обеих платформах реально наблюдались UI1→UI2→UI1
  и current/next, данные и байты базы сохранены; холодные запуски подтверждены,
  автоматический Windows restart не заявляется. Коммитыb6556b0/f3c6238.
  [SDK гейт](evidence/shorebird30-runtime-qa.json),
  [публичный аудит](evidence/shorebird30-public-download-audit.json),
  [Preview](https://github.com/Extectick/ExVPN/releases/tag/v0.1.9).
  Публикационный CI получил403 на историческом target commit; завершён тот же
  скрипт через локальный авторизованный gh без пересборки и новых прав CI.
  Полная E1/stable-приёмка этим пунктом не закрывается.

- [x] **EXVPN-E6-015** — Выпускать подписанные Android/Windows Dart-патчи через
  GitHub Actions поверх принятой базы 0.1.8+29. Критерий: hosted Android preflight
  принят без отключения strip/signature/native/assets guards; оба CI job публикуют
  проверенные подписанные патчи, receipts привязаны к исходникам и базе; SDK
  применяют фактические новые номера. Проверено 2026-10-20: commit
  [`8acc0af0`](https://github.com/Extectick/ExVPN/commit/8acc0af0a830267a1470b171b81544e92ffc5c87),
  [run39309178502 SUCCESS](https://github.com/Extectick/ExVPN/actions/runs/39309178502)
  обе платформы. Windows **№3/id731963**, Android **№4/id731975**, beta;
  RSA4096/AOT binding приняты для Windows x64 и Android x64/ARM64. Actual SDK
  current/next **3/3** и **4/4**, uiRevision **1**, restartRequired=false;
  прежние base/native bytes и Android UID сохранены. Full374/12 переиспользован
  по равенству Dart inputs, 160 input checks/job PASS. Windows повторная
  byte continuity пользовательских данных не заявляется: helper не завершился;
  перезапуск наблюдался извне, exit0 не подтверждён. Android проверен в эмуляторе.
  [Квитанции и границы](evidence/shorebird29-ci-patch-delivery.json).
  Повторные установщики, полный VPN runtime и уже принятый rollback не запускались.

Цикл **0.1.8+29 / Shorebird beta**, 2026-10-20: базовый commit `5bddc777`,
Dart-патч `0d9fdf22`, исправление CLI-отката `4a2262f3`. Настоящий SDK Windows
**0→1→0**, Android **0→2→0**, `uiRevision` **0→1→0**, прежние пакеты и данные
подтверждены. Один повреждённый байт Android cached AOT отвергнут подписью;
полный SDK state восстановлен и patch2 повторно исполнен до общего отката.
Full Dart-патча: **12/12 PASS,374 app tests,235,6с**; maintenance:298 guards PASS.
[Runtime](evidence/shorebird29-runtime-qa.json), [roundtrip](evidence/shorebird29-roundtrip.json),
[проверки](evidence/shorebird29-accepted-patch-full.json).

- [x] **EXVPN-E6-012** — Настоящая Shorebird-база Android/Windows0.1.8+29.
  2026-10-20, commits `5bddc777` / `0d9fdf22`: cloud908884, прежний APK signer,
  strict RSA pin, runtime notices/AOT/JNI/SBOM/filemaps и реальные SDK приняты.
  Windows compiled UI source E8 / packaging source C7 явно разделены.
  [Пакеты](evidence/shorebird29-cloud-package-patch.json).
- [x] **EXVPN-E6-013** — Подписанный Dart-патч применён на обеих платформах.
  2026-10-20, `0d9fdf22`: Windows №1/id731624, Android №2/id731631; actual SDK
  current/next1/1 и2/2/ui1 после холодного запуска. Android tampered cached AOT
  отклонён native подписью, полный SDK restore доказан. RSA/beta/stable проверены
  для Windows x64 и Android x64/arm64. [Roundtrip](evidence/shorebird29-roundtrip.json).
- [x] **EXVPN-E6-014** — Облачный откат обоих фактических номеров к базе.
  2026-10-20, `4a2262f3`: cloud readback и холодные SDK current/next=null/ui0
  на обеих платформах; данные и пакеты сохранены. SDK null нормализован в0
  только в publisher gate. [Runtime](evidence/shorebird29-runtime-qa.json).
- [x] **EXVPN-E7-013** — Публичный Preview и два подписанных full-update feed.
  2026-10-20, publisher source `ae4acee1`, immutable tag `v0.1.8` / `5bddc777`.
  Принятые базы импортированы run39293255636 и опубликованы
  [workflow39294754335](https://github.com/Extectick/ExVPN/actions/runs/39294754335)
  без rebuild. Все 18 public assets, 17 checksum records, 16 manifest rows,
  exact base receipts, runtime QA и оба Ed25519 feed прошли download/hash/domain/
  expiry-проверки. [Релиз](https://github.com/Extectick/ExVPN/releases/tag/v0.1.8),
  [независимый аудит](evidence/release-v0.1.8.json).
  Физический Android, E1, точный post-link SBOM, Windows Authenticode и
  стабильная VPN-приёмка остаются открытыми. Hosted Android patch preflight и
  выпуск signed-патчей через Actions приняты отдельно в E6-015.

Выпуск **0.1.6+27**, 2026-10-19: итоговый Full **12/12 PASS за 126,78 с**,
373 app tests, fingerprint неизменен; tag `v0.1.6`, исходники `ae35c9a`.
Android и Windows собраны и опубликованы одним release workflow39226424305;
15 публичных файлов и оба подписанных beta feed прошли независимую сверку.
[Состав версии](releases/0.1.6.md), [Full](evidence/fast-validation-v0.1.6.json),
[доставка](evidence/release-v0.1.6.json). Preview; E1 и стабильная приёмка открыты.

- [x] **EXVPN-E7-007** — Выпустить 0.1.0 Demo для Android и Windows через
  GitHub Actions. Поручение пользователя: 2026-10-17. Критерий: обе сборки +18
  получены одним workflow, APK подписан прежним release-ключом, Windows явно
  unsigned/prerelease, версии/хеши/notices/source проверены; опубликованные
  файлы скачаны и сверены. Не заменяет стабильные E7-002–004.
  Подготовлены отдельный workflow, инструкции и проверки демо:
  [код ed040da](https://github.com/Extectick/ExVPN/commit/ed040da61e5265634eb5f63f5ab5f100ac77fda8).
  Full 11/11 PASS за 164,91 с, исходники неизменны;
  [отчёт](evidence/demo18-fast-validation.json). Demo policy 33, Maven 29,
  Android builder 68, MSVC pure 41 checks PASS. Независимый review завершён.
  Первый CI остановлен до публикации на NSIS checksum и отсутствии release
  JVM task в AGP9. [Отчёт](evidence/demo18-first-ci-failure.json).
  Исправлены AGP release JVM task, распознавание `minSdkVersion`, точный
  `listenablefuture:1.0` release input, проверяемые зеркала NSIS и чтение
  черновика по GitHub ID. [Исходники 6466b70](https://github.com/Extectick/ExVPN/commit/6466b7096c43f3d7442bfe55a513d180485596dd).
  Заключительный [Full](evidence/demo18-final-fast-validation.json): **11/11 PASS,
  79,61 с**, fingerprint совпал, Go result cache выключен. Локальные APK
  post-build gates (8/8 JVM tests, подпись, notices) и полный Windows builder
  прошли; [доказательства](evidence/demo18-local-packaging.json). Эти локальные
  пакеты не подменяют результат workflow.
  **Выполнено 2026-10-17:** [workflow 39049490539](https://github.com/Extectick/ExVPN/actions/runs/39049490539)
  на `6466b70` завершился SUCCESS: Android, Windows и публикация.
  [Релиз v0.1.0-demo](https://github.com/Extectick/ExVPN/releases/tag/v0.1.0-demo)
  опубликован как prerelease. Все **15 файлов скачаны**, 15 GitHub digests,
  14 записей SHA256SUMS и 13 manifest assets сверены; APK +18/minSDK30/target36
  прошёл apksigner с прежним release-сертификатом. Windows — NotSigned,
  разрешение сетевых тестов требует явного opt-in. [Итоговое доказательство](evidence/demo18-published.json).
  Стабильная приёмка, физический Android, полный SBOM и Dart OTA не закрыты.

| Этап | Состояние | Что требуется для закрытия |
|---|---|---|
| E0 | В работе | Проверенные локальные документы, GitHub и состояние зеркала Linear |
| E1 | Открыт | Реальные Android/Windows VPN, исключения, DNS и kill switch |
| E2 | Частично реализован, приёмка открыта | Выбранный Flutter UI реализуется по поручению пользователя до E1; нужны итоговые скриншоты и Android/Windows проверка |
| E3 | Частично реализован | Парсер/снимок, HTTPS, обновление, защищённое хранилище и QR из изображения реализованы; полная платформенная приёмка ещё требуется |
| E4 | Открыт | Android-клиент и испытания на физическом устройстве |
| E5 | Открыт | Windows-клиент, служба, WFP и жизненный цикл установки |
| E6 | Открыт | Подписанные данные/Dart OTA и реальные обновления/откаты |
| E7 | Открыт | Общая beta и подписанные пакеты |
| E8 | Открыт | Linux на Ubuntu 22.04/24.04 |
| E9 | Открыт | iOS Packet Tunnel, TestFlight и системная приёмка |

## E0 — Документация и организация

- [x] **EXVPN-E0-001** — Сохранить согласованный план, архитектуру и чеклист с постоянными ID. Критерий: три Markdown-документа отражают платформы, протоколы, защиту, OTA и этапы без приватных входных данных. Доказательство: 2026-10-16, документы созданы и взаимно связаны; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).
- [x] **EXVPN-E0-002** — Добавить README, правила разработки и шаблон PR. Критерий: описаны E1 gate, доказательства проверок и защита приватных данных. Доказательство: 2026-10-16, `README.md`, `AGENTS.md`, `.github/PULL_REQUEST_TEMPLATE.md`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).
- [x] **EXVPN-E0-003** — Добавить Apache-2.0, NOTICE и начальный реестр лицензий. Критерий: полный официальный текст лицензии, Xray/MPL-2.0, libXray/MIT, Flutter/BSD-3-Clause и незакреплённые зависимости обозначены честно. Доказательство: 2026-10-16, `LICENSE` загружен с apache.org; первичные LICENSE трёх компонентов проверены; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).
- [x] **EXVPN-E0-004** — Подготовить GitHub-репозиторий `Extectick/ExVPN`, remote и начальную историю. Зависимости: E0-001–003. Критерий: репозиторий доступен, remote совпадает, опубликованный commit содержит только разрешённые материалы; записать commit/URL. Доказательство 2026-10-16: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) опубликован в main; remote проверен. Следующий commit связывает чеклист с исходниками. CI запущен, его успешность отмечается отдельно в E7.
- [ ] **EXVPN-E0-005** — Подключить Linear и создать зеркало этапов/задач. Зависимость: доступ к коннектору. Критерий: проект и ссылки на задачи с теми же ID; MD остаётся источником состояния. Повторная проверка 2026-10-16: `list_teams` вернул `USER_NOT_LOGGED_IN`; зеркало не создано.
- [x] **EXVPN-E0-006** — Проверить ignore-правила и отсутствие приватных данных перед первой публикацией. Критерий: `.private/`, SDK/cache/build/signing не попадают в Git; staged diff и секрет-скан проверены без вывода секретов. Доказательство 2026-10-16: 329 файлов initial snapshot проверены; совпадений с приватным провайдером/token, PEM private keys и PAT patterns нет. `git check-ignore` подтвердил исключение приватных данных, SDK и APK/EXE. Whitespace-замечания остались только в неизменённых сторонних лицензиях. [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).

## E1 — Технический прототип и обязательный gate

Прогресс +16, 2026-10-17: неизменный подписанный Shorebird APK в API30
эмуляторе провёл один VLESS/XHTTP/REALITY профиль через настоящий VpnService.
Независимый UID подтвердил HTTPS200/204, VPN transport и другой внешний IPv4;
обычный Disconnect восстановил исходный выход. Собственная группа удалена,
системные настройки сохранены, исходный другой эмулятор не затронут.
107,256 с; root сверил 453 файла, 0 расхождений.
[Отчёт](evidence/android-shorebird-provider-build16.json),
[экран](evidence/android-shorebird16-provider-connected.png).
IPv6/DNS leaks/exclusions/fault в этом запуске не проверены; E1 остаётся открыт.
Код APK: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).

Дополнение EXVPN-E1-009, 2026-10-17: отдельный additive DNS listener control
прошёл за 73,495 с; один synthetic DNS API call сопоставлен с точным full nonce,
UID/netId и callback time. PID подтверждён отдельно querylog/live observations,
в callback его нет. Очистка PASS, исходное устройство/настройки/store сохранены.
PCAP/VPN в этом control не запускались; девять прежних неоднозначных wire
запросов не переатрибутированы, DNS gate остаётся открытым.
[Доказательство](evidence/android-dns-additive-control.json). Исходники и запись доказательств: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).

Диагностика EXVPN-E1-009, 2026-10-17: два ограниченных запуска отдельного
Android API30 AVD не дождались завершения загрузки ОС. DNS observer не
запускался, разрешение и UID callback не проверены. Обе очистки PASS;
прежний DNS gate остаётся INDETERMINATE. [Доказательства](evidence/android-dns-listener-preflight.json).

Диагностика EXVPN-E1-009, 2026-10-17: отдельный Android DNS requester control
PASS за 59,230 с — один вызов обычного приложения сопоставлен с UID, наблюдаемым
PID, netId и временем в querylog. VPN не запускался; прежние DNS-пакеты остаются
без подтверждённого владельца. [Доказательство](evidence/android-dns-positive-control-confirmed-build13.json).
Общий E1/DNS gate остаётся открытым; отчёт [c582a6e](https://github.com/Extectick/ExVPN/commit/c582a6e).

- [ ] **EXVPN-E1-001** — Провести инвентаризацию и закрепить Flutter/Dart, Go, Android SDK/NDK/JDK и Windows C++ toolchain. Зависимость: E0-001. Критерий: воспроизводимые версии, контрольные суммы/commits, команды установки и результаты doctor/build; нет плавающего `latest`.
- [ ] **EXVPN-E1-002** — Проверить Xray v26.10.10 и закрепить способ линковки через собственный Go-адаптер. Зависимость: E1-001. Критерий: ядро собирается для Android/Windows, лицензии и pins записаны; TUN, Hysteria2 и Android owner hook проверены в выбранных исходниках. libXray сохранён как исследованный исходный вариант, но не runtime-зависимость.
- [ ] **EXVPN-E1-003** — Создать общий контракт VpnBridge и технический стенд подключения. Зависимость: E1-002. Критерий: команды/состояния/ошибки типизированы, UI не выставляет фиктивный `connected`, повторные команды не создают конкурирующие туннели.
- [x] **EXVPN-E1-004** — Получить предоставленную приватную тестовую подписку и обезличенную матрицу профилей. Критерий: формат/число/типы записей известны без раскрытия адреса/ключей; либо зафиксирован конкретный повторяемый внешний отказ. Доказательство 2026-10-16: две повторные HTTPS-попытки завершились connect timeout до HTTP, тело не получено; DNS во второй попытке разрешился, TCP/TLS не установились. [Обезличенный отчёт](evidence/provider-availability.md). Импорт и подключения провайдера не подтверждены; закрыта проверка доступности с документированным отказом. [b430a9b](https://github.com/Extectick/ExVPN/commit/b430a9b).
- [ ] **EXVPN-E1-005** — Проверить VLESS/REALITY, XHTTP, VMess, Trojan, Shadowsocks, Hysteria2. Зависимости: E1-002–004 и доступные тестовые серверы для каждого варианта. Критерий: реальный HTTPS через каждый вариант, ожидаемый внешний IP, UDP там, где заявлен; отсутствующие варианты остаются открытыми.
  Проверка входных данных 2026-10-17: сохранённый ответ второго провайдера содержит 32 VLESS. Инвентаризация локальных ответов/fixtures не нашла внешних Trojan/Hysteria2 с подтверждённым TLS; по одной записи найдены только в старом синтетическом стенде. Новых запросов провайдерам и изменений настроек не было. [Обезличенный отчёт](evidence/android-protocol-inventory-build11.json). Это ограничение тестовых данных, а не результат соединения; код продукта [ad9b257](https://github.com/Extectick/ExVPN/commit/ad9b2579245b68b66bc2f9364b1d7cd5d8a8192f), инструменты QA [bbce9ea](https://github.com/Extectick/ExVPN/commit/bbce9eaf54e341b5a258e14cf72464b18d16284c).
  Дополнение 2026-10-16: Windows Flutter/SCM/TUN в Sandbox без Computer Use прошёл VLESS TCP/REALITY/Vision/XHTTP/XHTTP+REALITY, VMess и SS: независимый HTTPS 200/204, DNS и рост счётчиков на обоих концах. Локальный fixture делит внешний IP с baseline; разные egress, Trojan/Hy2 и UDP не приняты. [Отчёт](evidence/windows-flutter-sandbox-smoke.json), [методика](WINDOWS_AUTOMATED_QA.md), исходники [625a875](https://github.com/Extectick/ExVPN/commit/625a875).
- [ ] **EXVPN-E1-006** — Проверить Android TUN, socket protection и определение владельца. Зависимость: E1-003. Критерий: физическое Android 11+ устройство, обычное/исключённое приложение одновременно имеют ожидаемые разные маршруты; неизвестный/shared owner не обходит VPN.
- [ ] **EXVPN-E1-007** — Проверить Windows TUN, службу и безопасный IPC. Зависимость: E1-003. Критерий: UI без elevation, запросы постороннего клиента отклоняются, классификация приложения не основана только на имени executable.
  Дополнение 2026-10-17: +6 подтвердил реальный Flutter/IPC/SCM/TUN с medium token UI без elevation/admin privileges, семь вариантов HTTPS/DNS и fault suite. Исправлен отказ query SCM-процесса, более широкие права проверенно запрещены. [Отчёт и ограничения](WINDOWS_UNELEVATED.md), [JSON](evidence/windows-unelevated-build6.json), исправление [a617aad](https://github.com/Extectick/ExVPN/commit/a617aad16c6e1803fcd6e1557d1c500861732e74), стенд [59bbcdf](https://github.com/Extectick/ExVPN/commit/59bbcdfc85dc1a99c43703445ae491154b78167a). Полная матрица IPC/отдельный стандартный logon остаются открытыми.
  Дополнение 2026-10-16: production C++ bridge ↔ установленная LocalSystem SCM-служба ↔ Wintun проверены автоматическим Flutter entry point. QA path временно привязан с прежним SID и затем восстановлен; защита IPC не подменялась. Desktop token Sandbox административный, поэтому критерий UI без elevation этим прогоном не закрыт. Доказательства и исходники: [625a875](https://github.com/Extectick/ExVPN/commit/625a875), [отчёт](WINDOWS_AUTOMATED_QA.md).
- [ ] **EXVPN-E1-008** — Проверить Android lockdown и Windows persistent WFP при отказах. Зависимости: E1-006–007. Критерий: обрыв сервера, авария ядра/службы, запуск UI заново, смена сети и sleep/resume не дают прямого выхода защищаемого приложения.
  Дополнение 2026-10-17, Windows +10: после реального upgrade +9 → +10 прошли семь HTTPS/DNS сценариев, server outage с живым исключением, hard kill/restart SCM с persistent guard и explicit disconnect. Отдельный внешний XHTTP/REALITY профиль автоматически восстановил HTTPS/DNS после guest Ethernet down/up; +9 в том же сценарии зависал. Cleanup обоих прогонов вернул точный DNS/routes baseline, guard/TUN отсутствуют. [Fault report](evidence/windows-runtime-faults-build10.json), [network report](evidence/windows-network-recovery-build10.json), [контракт и ограничения](WINDOWS_RECONNECT.md), исходники [924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479). Смена физических NIC, sleep/resume, IPv6 и непрерывный leak capture остаются открытыми.
  Дополнение 2026-10-17, Android +9/API30: закрытие Activity сохранило HTTPS через VPN; после выключения/возврата Wi-Fi и mobile data HTTPS восстановился за 3509 мс. После reboot эмулятора Always-on подключился до открытия UI. Авария процесса сохранила lockdown, но автоматический перезапуск не произошёл в трёх наблюдениях; ручное подключение восстановило HTTPS. Диагностика указывает на удаление записи службы при обработке смерти VPN Binder в Android 11; универсальное исправление не заявляется. Исходные системные настройки восстановлены. [Доказательства](evidence/android-lifecycle-build9.json), [разбор и ограничения](ANDROID_VALIDATION.md). Физическое устройство, sleep/resume и полная IPv6/DNS матрица остаются открытыми. Проверенный APK: [f5901bc](https://github.com/Extectick/ExVPN/commit/f5901bc7d0b61d22f555bc760cbfcb5e3c85de81); production-код при lifecycle QA не менялся.
  Дополнение 2026-10-16: Flutter integration test без Computer Use выбрал исключение в UI и проверил реальные HTTPS-процессы. При остановке fixture защищаемый процесс блокируется, исключённый получает HTTP 200. Hard kill установленной LocalSystem SCM-службы блокирует оба; рестарт сохраняет blocked, явное отключение восстанавливает HTTPS. WFP observer подтвердил guard после аварии; итоговые route/DNS hashes совпали с исходными. Смена сети, reboot/sleep, полная IPv6/DNS матрица и физический Android остаются открытыми. [Отчёт](evidence/windows-scm-failure-smoke.json), исходники [1575305](https://github.com/Extectick/ExVPN/commit/1575305923c37b9c1f41721d6b07ad11fe133824).
- [ ] **EXVPN-E1-009** — Проверить DNS/IPv4/IPv6 и исключения с холодным DNS-кешем. Зависимости: E1-006–008. Критерий: нет незаявленного прямого DNS/IPv6, неизвестный владелец не получает direct; ограничения исключений в аварии описаны.
  Дополнение 2026-10-17, Android +16: новый DNS attribution сценарий остановлен
  до Connect на обходе списка исключений (`qa_exclusion_inventory_incomplete`);
  HTTPS/DNS/capture не запускались. Отдельная очистка за 81,903 с удалила
  тестовую группу, подтвердила оба QA-приложения без исключений, исходные
  настройки и отсутствие VPN; собственный AVD остановлен. Root сверил 471 + 255
  файлов, расхождений нет. [Попытка и отдельная очистка](evidence/android-shorebird16-dns-attempt.json).
  [Запись af05c0b](https://github.com/Extectick/ExVPN/commit/af05c0b).
  Пункт остаётся открытым.
  Дополнение 2026-10-17: новый Android +13 сценарий завершил четыре фазы за
  369,283 с. При обрыве защищённый HTTPS/DNS отказал, исключённый HTTPS прошёл;
  Disconnect восстановил исходный выход. Непрерывный интервал содержит 9 UDP53
  пакетов: три из пяти запросов сопоставлены с NetworkMonitor, два остаются
  неоднозначными. Исходный strict=false/INDETERMINATE сохранён, cleanup PASS;
  986 файлов и 30 файлов addendum сверены. [Полный запуск](evidence/android-dns-fault-continuous-build13.json),
  [отдельная корреляция](evidence/android-dns-attribution-addendum-build13.json).
  Доказательства: [1fd0bd5](https://github.com/Extectick/ExVPN/commit/1fd0bd55b876a0251e803fc1123390546442568b).
  Проверка Android +13, 2026-10-17: защищённый numeric HTTPS при остановке
  сервера отказал, исключённый UID получил HTTPS 200 при живом VPN. Непрерывный
  capture, включая промежутки между фазами, обнаружил три открытых DNS-запроса
  и три ответа до Disconnect. UID не установлен: strict DNS gate FAILED;
  исходный запуск INDETERMINATE. Отдельный cleanup-only PASS подтвердил пустые
  подписки/исключения, прежние настройки, отсутствие службы и остановку своего
  гостя; результат исходной попытки не повышен. [Отчёт](evidence/android-dns-exclusions-build13.json),
  [экран после очистки](evidence/android-dns-exclusions-build13-cleanup.png).
  APK +13 неизменен, SHA и build-input fingerprint приведены в отчёте;
  исходники APK — [36c6094](https://github.com/Extectick/ExVPN/commit/36c6094603ee92ae3724db8c7784a4e819d70347).
  Нужны атрибуция DNS к UID,
  физическое устройство, global IPv6 и остальные условия E1-009.
  Попытка Android +11, 2026-10-17: DNS nonce probe и offline PCAP parser проверены синтетическими fixtures, но реальный capture не начался: console текущего эмулятора разрешила только имя файла внутри AVD вне `.private`. Ни одной фазы DNS/VPN не выполнено, результат отсутствия утечек — NOT_TESTED. Подписки, выбор, reverse и настройки восстановлены, прямой HTTPS подтверждён. [Отчёт](evidence/android-dns-capture-build11.json), QA исходники [084feb6](https://github.com/Extectick/ExVPN/commit/084feb60a77c794c476874b84c435c2861a9b099). Штатный startup `-tcpdump` найден в локальной справке, поддержка абсолютного приватного пути ещё не проверена.
  Частичная DNS-проверка 2026-10-17: отдельный приватный API30 AVD с неизменным APK +11 подтвердил baseline и connected HTTPS. После обрыва fixture ADB перестал отвечать, fault/restoration не завершены; гость штатно остановлен, исходный эмулятор сохранён. Узкий IPv6 Hop-by-Hop parser fix прошёл 7 Go tests/vet и independent review, не ослабляя отказ на TLV/fragment/unsupported chains. Первый offline reparse обработал 207 пакетов, но остался INDETERMINATE из-за позднего DNS-ответа. [Отчёт](evidence/android-dns-clean-build11.json), [QA source](https://github.com/Extectick/ExVPN/commit/ea9f2ca). DNS leak gate открыт.
  Следующий ограниченный стенд 2026-10-17: четыре фазы без ADB reverse прошли за 150,044 с; final parser прочитал 1255 пакетов. Baseline/restoration DNS controls присутствуют, connected/fault cleartext DNS не наблюдается; numeric HTTPS при обрыве отказал под VPN, explicit disconnect восстановил direct HTTPS/IP. Cleanup PASS. [Отчёт](evidence/android-dns-directalias-build11.json), тот же APK +11 и [QA commit](https://github.com/Extectick/ExVPN/commit/ea9f2ca). Global IPv6, физический Android и полный leak audit остаются открытыми.
- [ ] **EXVPN-E1-010** — Собрать Android и Windows технические пакеты и закрыть gate. Зависимости: E1-001–009, E1-011. Критерий: отчёт с версиями, устройствами, командами и обезличенными доказательствами; сборка без системных испытаний не закрывает этот пункт.
  Пакеты +12, 2026-10-17: Windows installer собран и прошёл upgrade/9 циклов; Android APK обеих ABI собран за 166,154 с с прежним debug signer и неизменными inputs. 8 Android JVM results были UP-TO-DATE, не новым выполнением. Затем тот же Android APK прошёл upgrade +11 → +12, cold restore, HTTPS 200/204 через TUN и cleanup за 137,532 с в отдельном API30 x86_64 emulator. [Android build](evidence/android-build12.json), [Android runtime](evidence/android-upgrade-build12.json), [Windows build/runtime](evidence/windows-lifecycle-build12.json); source [ea9f2ca](https://github.com/Extectick/ExVPN/commit/ea9f2ca), product fix [402245f](https://github.com/Extectick/ExVPN/commit/402245f8e701610f8ef8bafc6eebe365d7c30940). Оба пакета development; активный VPN при upgrade, физический Android и полная системная приёмка открыты.
- [ ] **EXVPN-E1-011** — Ограничить жизненный цикл upstream transport caches при повторном создании ядра. Зависимость: E1-002. Критерий: старое ядро не оставляет gRPC/XHTTP владельцев, фоновые повторные подключения или растущие ресурсы; параллельный Dial/Close не воскрешает завершённого владельца; Android и Windows проверены отдельно. Наблюдение 2026-10-17: закреплённый Xray хранит gRPC ClientConn/XHTTP XmuxManager в process-global maps после Instance.Close. Windows lease закрывает sockets и изолирует поколения, но не освобождает эти upstream objects. [Контракт, точные источники и следующий шаг](WINDOWS_RECONNECT.md); готовность не подтверждена.
  Android +13, 2026-10-17: **4/4 цикла gRPC/XHTTP PASS**, тот же процесс приложения,
  четыре поколения ядра, HTTPS/DNS независимого UID и отсутствие службы/peers
  после каждого штатного Disconnect. Циклы 50,442 с, весь прогон 177 с.
  Instrumentation заменяет только управление обычной кнопкой; native/network
  доказательства независимы. Полная ресурсная/IPv6/fault матрица и физическое
  устройство остаются открытыми. [Отчёт](evidence/android-transport-semantics-build13.json),
  [QA исходники](https://github.com/Extectick/ExVPN/commit/2259bb7).
  Дополнение 2026-10-17: отдельно воспроизведён retained DNS/UDP worker в TUN
  `exvpn.3` (3/3). `exvpn.4` владеет отменой и завершением UDP workers, включая
  частичные ошибки Start. Девять новых tests ×5, общий pinned race ×5/vet и
  native verify/unit/vet PASS; ZIP/h1 воспроизводимы. [Исходники](https://github.com/Extectick/ExVPN/commit/0493c89),
  [доказательства](evidence/xray-tun-lifecycle-exvpn4.json). Платформенный runtime
  нового ядра и ограниченность всех ресурсов ещё не подтверждены.
  Исправление Windows +12, 2026-10-17: Close предшествует обязательному Suspend, при ошибках владелец и persistent guard сохраняются; гонка Shutdown/Disconnect закрыта. Focused/race ×10/vet и независимое review прошли. [Исходники](https://github.com/Extectick/ExVPN/commit/402245f8e701610f8ef8bafc6eebe365d7c30940), [Full 10/10 за 93,06 с](evidence/fast-validation-build12.json). Последующий runtime +12 подтвердил 9/9 циклов gRPC/XHTTP/XHTTP+REALITY и cleanup после upgrade +11 → +12; [отчёт](evidence/windows-lifecycle-build12.json). Конечный прогон не доказывает отсутствие роста памяти; E1 остаётся открытым.
  Уточнение Windows 2026-10-17: TCP-синхронизация A/B/C подтвердила EOF/peer drain за 26 мс в A и при сохранённом self-permit в B. Только Suspend перед Close в C оставил host Established за пределами 10 с (381 наблюдение), при исчезнувшем guest tuple. Контроль не продлевает deadline; cleanup прошёл. [Отчёт](evidence/windows-teardown-tcp-build11.json), [QA commit](https://github.com/Extectick/ExVPN/commit/173cdf0d99552eae5c1e8bf0e35b5c72c4d8daf5). На момент этой диагностики product fix ещё не проверялся; последующий +12 runtime приведён выше.
  Диагностика Windows 2026-10-17: отдельный A/B/C helper подтвердил baseline A Established и EOF; gate наблюдателя занял 1 мс после контрольной отметки, не всю длительность Close. B остановился на синхронизации файлов стенда, C не выполнялся. Причина сохранения VPN peer не доказана, production не менялся. Проверена очистка с исходными SCM/service hash/routes/DNS, без TUN/guard. [Отчёт](evidence/windows-teardown-diagnosis-build11.json), QA исходники [5ca1b36](https://github.com/Extectick/ExVPN/commit/5ca1b3633b81f463ac8f19bd166a5c373187c22c). Прежний runtime FAIL сохраняется.
  Прогресс +11, 2026-10-17: закреплён `v1.260327.1-exvpn.3`, исходный ZIP/patch/изменённый модуль связаны SHA-256 и Go h1. Stock regression воспроизвёл retained sockets в четырёх сценариях; финальный `Runtime.Close` прошёл шесть транспортов по три поколения с независимым живым ядром. 26 upstream test functions, race ×5 и vet PASS; 61 source-proxy, 35 notice и 35 Android snapshot fixtures PASS. [Контракт](XRAY_LIFECYCLE.md), [доказательство](evidence/xray-lifecycle-build11.json). Android API30 прошёл шесть циклов gRPC/XHTTP в одном процессе, независимый HTTPS, закрытие peer sockets, cold restore и cleanup; [отчёт](evidence/android-lifecycle-build11.json). Windows: после подтверждённого активного socket тот же SCM process закрывает клиентское соединение, но server-side peer остаётся Established более 10 с; gate остаётся FAIL, cleanup прошёл. [Все попытки](evidence/windows-lifecycle-build11.json). Исходники продукта [ad9b257](https://github.com/Extectick/ExVPN/commit/ad9b2579245b68b66bc2f9364b1d7cd5d8a8192f); изменения наблюдателя — [afdd24e](https://github.com/Extectick/ExVPN/commit/afdd24e399f3d0e3f118f03816379ce63d2b5a25). Физический Android и общий E1 gate остаются открытыми.

## E2 — Дизайн

- [x] **EXVPN-E2-024** — Неподдерживаемые подключения видны неактивными строками.
  Проверено 2026-10-20: приглушённые флаг/название/протокол и отметка
  «Не поддерживается» поверх строки; нельзя выбрать, подключить или пропинговать.
  В рабочие профили/авто-резерв такие записи не попадают. Ошибки загрузки
  остаются отдельными; unsupported не создаёт красный «!». Источник `1798355`.
  210 domain / 90 state tests и analyze этих пакетов PASS; 3 целевых widget tests
  PASS. Web build124,2с, браузер dark/large и light/medium, нажатие не меняет
  Амстердам; console errors0. [Доказательства](evidence/unsupported-connections-ui.json),
  [снимки](../design/screenshots/unsupported-connections/).
  Full попытка не является общим gate: параллельный writer поменял исходники,
  промежуточный lifecycle код не компилировался. Его владелец поправил cast;
  чужие native/lifecycle изменения этим пунктом не приняты, Full не повторялся.
  Snapshotv3 остаётся совместимым: после cold restore неподдерживаемые записи
  имеют «Подключение N» до refresh; исходный raw/endpoint не сохраняется.
  Полных APK/EXE, установок и публикации в этой UI-задаче не было.

- [x] **EXVPN-E2-023** — Меню отдельной подписки и автопинг видимых подключений в web-дизайне.
  Проверено 2026-10-20: вместо количества подключений — три точки с редактированием
  названия/HTTPS-ссылки и удалением с подтверждением. Сохраняются выбранный сервер,
  рабочие профили, автоматическое/ручное имя; revision отсеивает старый HTTP/candidate.
  Автопинг запускается по видимой области и событиям (открытие, конец прокрутки,
  раскрытие, возврат), не таймером. Два запроса, cache success 5 мин/failure 30 с,
  dedup host/port, 256 endpoint/512 display результатов; hidden/connecting без новых probes.
  Hysteria2/WireGuard — нейтральное тире, TCP не выдаётся за проверку VPN.
  12 targeted tests PASS и analyze8files clean. В браузере dark/light, dropdown,
  edit-save, delete-cancel и автопинг без кнопки, console errors0 приняты.
  Источник `67a19c8`, восстановлен точно в `a139643` после принятия базы33.
  Дополнение `c033c29`: demo endpoints не запускают native probes без симулятора.
  Эти изменения не включены в APK/EXE33 по выбору пользователя; следующий отдельный
  совместимый AOT-патч: номер2/UI6, SemVer/build остаётся 0.1.11+33.
  Общий прогон восстановленного UI (`c033c29`) PASS: 12/12 групп за 123,75 с,
  465 app tests; fingerprint исходников не менялся. [Полный отчёт](evidence/subscription-menu-autoping-full.json).
  E2-009/physical и выпуск патча остаются открытыми.
  [Доказательства](evidence/subscription-menu-autoping.json), synthetic-only
  [снимки](../design/screenshots/subscription-menu-autoping/).

- [x] **EXVPN-E2-022** — Прямой переключатель защиты, ограниченные «Логи», плотный список и прогресс обновления.
  Проверено 2026-10-20: Settings без отдельного диалога защиты; «Логи» с закреплённой
  кнопкой «Скопировать» и очисткой. До 64 значимых событий за 30 минут, автоочистка,
  schema2 с allowlist, без ссылок, ключей, имён приложений/подписок и содержимого
  трафика; отчёт до 64 KiB. Строки серверов 48 px с промежутком 2 px.
  Во время проверки/скачивания/установки кнопка целиком становится прогрессом,
  без видимого текста и процентов, общий виджет с верхней полосой обновления.
  Общий Full **12/12 PASS, 418 app tests, 115,73 с**, fingerprint неизменен;
  дополнительно 11 targeted logs tests, Android 9 JVM и Windows pure/race/vet.
  После последнего замечания о высоте изменены только updater UI и его тест:
  Сначала 56 px во всех состояниях, 8 targeted tests/analyzer PASS, из них 4 новые
  геометрические регрессии dark/light × text scale 1/1,5; browser bounding height PASS.
  Full после этого изолированного уточнения не повторялся.
  В браузере приняты dark/medium, light/minimal, прямой toggle в макете и copy.
  [Доказательства](evidence/settings-protection-logs.json), [просмотр](DESIGN_PREVIEW.md).
  Последнее уточнение 2026-10-20: высота снижена до 40 px, иконка 18 px,
  штатный LinearProgressIndicator по всей поверхности; 8 updater tests/analyzer
  PASS и равные browser bounds до/при загрузке. Другие suites не повторялись.
  [Квитанция компактности](evidence/updates-compact-action.json).
  Исходники: `3a8b9b7`, компактность `d1caebe`. Приёмка native ниже остаётся открытой.

- [ ] **EXVPN-E5-010** — Принять переключаемый Windows Kill Switch на новой native-базе.
  Исходники 2026-10-20: default ON, защищённая owner-DPAPI настройка, setter только
  при полностью отключённом VPN. OFF сохраняет динамические WFP block filters
  живой службы; ON — persistent. Recovered persistent guard не снимается из-за OFF;
  `enabled=false, active=true` допустим. 90 pure checks, 11 новых tests race×10,
  vet и общий Full PASS. [Source-квитанция](evidence/windows-connection-protection-source.json).
  Открыто: C++ compile, настоящий DPAPI read/write, WFP/service-crash/recovery,
  сохранность исключений/DNS/HTTPS и установленный UI. Требуется новая полная база;
  существующий APK/EXE и OTA feed в этом цикле не менялись.

- [ ] **EXVPN-E4-007** — Принять системный Android Kill Switch через новый переключатель.
  Исходники 2026-10-20: `isAlwaysOn && isLockdownEnabled` читаются из живой VpnService;
  без службы `enabled=null`, UI не показывает включённую защиту. Оба направления
  переключения открывают VPN Settings; приложение не меняет ОС вместо пользователя.
  9 адресных JVM-тестов PASS, [квитанция](evidence/android-connection-protection-jvm.json).
  Открыты Activity compile/new-base integration, возврат из системных настроек и
  устройство. E1 и общая физическая Android-приёмка не закрываются.

- [x] **EXVPN-E2-021** — Единая кнопка на странице «Версии и обновления».
  Проверено 2026-10-20: одна автоматическая проверка при входе с повтором,
  общий full/patch updater, прогресс, автоматический handoff в widget-тесте,
  краткий отказ/повтор; ниже только приложение и ядро. Проверки: 4 новых
  widget-теста и 4 адаптированных OTA UI-теста PASS, targeted analyzer чист;
  browser dark/medium и light/minimal, визуальная загрузка и пересоздание.
  Windows restart guard допускает только read-only updates route, другие
  диалоги сохраняют блокировку. Нативная установка нового UI не заявляется;
  Android Dart auto-restart сохраняет прежнее native-ограничение.
  [Просмотр и границы](DESIGN_PREVIEW.md), [доказательство](evidence/updates-page-unified-design.json).
  Исходники: [1eb2c42](https://github.com/Extectick/ExVPN/commit/1eb2c42f240ec372dfc1ed984952956bc31395cf); проверки и снимки приняты.

- [x] **EXVPN-E2-020** — Постоянное название над вкладками, автозаполнение и две QR-иконки.
  Критерий: поле с иконкой одинаково во всех вкладках; HTTPS из буфера и имя
  провайдера подставляются, ручное имя/новый источник защищены от позднего ответа;
  QR содержит изображение (файл/буфер) и камеру. Проверено 2026-10-19: три focused
  autofill tests PASS, targeted analyzer без замечаний, IAB minimal400×440:
  synthetic Clipboard URL → ExVPN Demo, сохранение поля при смене вкладки,
  image menu и две иконки без overflow. Console error отсутствует.
  Исходники `96444e3`; [снимки](../design/screenshots/import-autofill/),
  [сверка](../design-qa.md), [ограничения](DESIGN_PREVIEW.md).
  Реальная камера не проверена; web camera реализована, native camera и бинарный
  image clipboard Windows/Android остаются открытыми в E3-005. Нет APK/EXE,
  Full, установки, публикации или CI; версия и опубликованные теги прежние.

- [x] **EXVPN-E2-019** — Упростить импорт и модальные окна minimal в веб-дизайне.
  Критерий: minimal открывает настройки/серверы/импорт на всю область приложения,
  medium сохраняет компактный диалог; Ссылка / Текст / QR, раскрываемое название,
  одна основная кнопка и крестик; unsupported не создаёт значок, refresh failure
  создаёт красный «!». Проверено 2026-10-19: IAB, light, minimal400×440 и medium440×760,
  вкладки/название/закрытие и симуляция refresh; console error отсутствует.
  Исходники `12aa7aa`, [снимки](../design/screenshots/compact-import/),
  [визуальная сверка](../design-qa.md), [порядок просмотра](DESIGN_PREVIEW.md).
  Только дизайн: без native-сборок, Full, установки, публикации или смены версии.
  Parser/pending policy не изменены; реальное применение совместимой части
  подписки и приёмка Windows/Android этим пунктом не закрываются.

- [x] **EXVPN-E2-001** — Подготовить Product Design brief и три изображения-концепции главного экрана/белки. Критерий: графит/янтарь, большая кнопка сверху по центру, список серверов снизу; варианты доступны для сравнения. Проверка 2026-10-17: все три сохранённых исходных изображения открыты и просмотрены, brief и ссылки доступны в [design/README.md](../design/README.md). Созданы в [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7). Пользователь прямо разрешил реализацию выбранного UI до завершения E1. Системная и визуальная приёмка работающего приложения учитывается в E2-003/005.
- [x] **EXVPN-E2-002** — Зафиксировать выбранный пользователем визуальный эталон. Зависимость: E2-001. Критерий: записан выбор, tokens темы, типографика, размеры и формы; нет самовольной замены направления. Проверка записи 2026-10-17: последний выбор 2026-10-16 сохранён в [approved-close-wordmark.png](../design/concepts/approved-close-wordmark.png), маленькая контурная белка и близкий белый ExVPN. Сохранены обновление слева от плюса, группы подписок, отсутствие точек и CTA только при нуле подписок. Токены исходников записаны в [design/README.md](../design/README.md); источник [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7). Итоговая сверка работающего UI относится к E2-005 и остаётся открытой.
- [ ] **EXVPN-E2-003** — Проработать светлую тему, разрешения, пустой список и все состояния VPN. Зависимость: E2-002. Критерий: карты Android/Windows, читаемые ошибки, поддержка клавиатуры/доступности, честное отображение OS lockdown.
- [ ] **EXVPN-E2-005** — Реализовать выбранный Flutter UI и проверить его как отдельный стенд. Зависимость: явное поручение пользователя 2026-10-16; native VPN-приёмка остаётся в E1/E4/E5. Критерий: исходники, рабочие тёмная/светлая темы, группы/выбор, импорт/обновление/удаление, пустое состояние, узкая/широкая ширина и обезличенные скриншоты; нет ложного `connected`. Прогресс: `apps/exvpn`, `packages/exvpn_client_state`; 15 widget-тестов пройдены по отчёту проверки, финальные дополнительные проверки кнопки и визуальные снимки ещё выполняются. Итоговое доказательство должно быть сохранено в `design/design-qa.md` и `design/screenshots/`; до его оформления пункт открыт. исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).

- [x] **EXVPN-E2-006** — Упростить Windows-экран и подготовить живой просмотр
  трёх форматов без выпуска пакетов. Поручение: 2026-10-18. Критерий:
  компактная симметричная шапка, три переключателя, таймер внутри кнопки,
  отсутствие лишних подписей, замечания по «!», прокрутка и общий масштаб.
  Проверено 2026-10-18 в браузере на тех же Flutter widgets: minimal/medium/large,
  таймер/свечение, масштаб, прокрутка/раскрытие и диалог замечаний.
  Анализ четырёх изменённых Dart-файлов — No issues found.
  [Инструкция](DESIGN_PREVIEW.md), [снимки](../design/screenshots/windows-layouts/overview.jpg),
  [визуальный отчёт](../design-qa.md). Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).
  По явному ограничению пользователя Full, VPN-тесты, native/release builds
  и GitHub workflow не запускались. Это не закрывает E1/E2-005/E4/E5.
- [ ] **EXVPN-E2-007** — Проверить новые пропорции реального Windows-окна.
  Зависимость: E2-006. Критерий:
  3 размера, растяжение за все края, DPI/смена монитора, корректный центр и
  доступные элементы. Host-код `exvpn/window.setLayout` реализован.
  По новому поручению 2026-10-18 обычный Windows-клиент 0.1.0+18 собран
  за 29,8 с и скопирован в отдельный локальный комплект; установщик,
  VPN-тесты, Full и публикация не запускались. После подтверждённого пользователем
  штатного выхода старого UI новая сборка запущена из локального комплекта:
  окно «ExVPN» создано, процесс отвечает. Single-instance mutex не обходился.
  [Доказательство сборки](evidence/windows-design-build-20261018.json).
  Приёмка всех режимов, краёв и DPI пока открыта.
  Следующая редакция: установленный UI обновлён через UAC и запущен из
  Program Files; проверены путь нового процесса, отвечающее окно и совпадение
  EXE/AOT с новой сборкой. Процесс службы не перезапускался.
  [Установленный запуск](evidence/windows-installed-design-20261018.json).
  Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).

- [x] **EXVPN-E2-008** — Доработать действия списка и отключённую кнопку в
  предпросмотре. Проверено 2026-10-18: обновление без chooser/dialog, короткое
  верхнее уведомление с именем подписки, пинг-иконка слева от обновления,
  зелёный/жёлтый/красный текст 42/168/342 мс, исходный цвет диска и Space Gray в off,
  немедленное снятие света после отключения под курсором.
  [Снимки](../design/screenshots/windows-actions/), [описание](DESIGN_PREVIEW.md),
  [обезличенный отчёт](evidence/windows-actions-preview-20261018.json).
  Анализ изменённых Dart-файлов чистый. Макетные действия не обращаются к сети;
  VPN-тесты, Full и native/release builds не запускались. Рабочее дерево;
  Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).
- [ ] **EXVPN-E2-009** — Проверить пакетные действия на обычном Windows-клиенте:
  реальные URL, частичный отказ/сохранение, TCP/DNS deadlines и отмена при выходе.
  Исходники bulk refresh и ограниченного TCP latency probe подготовлены;
  UDP-only/Hysteria2 измерение пока недоступно. Ожидает следующего разрешённого
  функционального прогона, без заявлений о работоспособности VPN по ping.

- [ ] **EXVPN-E2-010** — Принимать выбор подключения в модальном окне малого
  режима, закрепить шапку списка и сократить сообщения. Критерий: выбор не
  меняет формат/размер, закрытие X/Escape и фокус внутри окна; прокручиваются
  только группы; частичные обновления сохраняют предыдущий список, без длинного
  диалога замены. Исходники двух Dart-файлов реализованы, целевой analyze чистый.
  Windows build прошёл за 24,8 с, установленный UI запущен. Резервная копия
  и manifest сохранены; 8 файловых сценариев helper прошли без системных изменений.
  Пользовательская проверка последней редакции в Windows ещё требуется.
  [Доказательства](evidence/windows-installed-design-20261018.json).
  Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).

- [ ] **EXVPN-E2-011** — Принять светлую бело-голубую тему, белую кнопку с
  голубым ON-свечением, промежутки строк и выбор PROXY/VPN под кнопкой в трёх
  Windows-форматах. Исходники и targeted analyze готовы, Windows +19 собран;
  установлен и открыт 2026-10-18 с новым EXE/AOT;
  последняя визуальная приёмка в реальном окне ещё требуется. Тёмная тема
  сохраняет прежнюю палитру. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).

- [x] **EXVPN-E2-012** — Выполнить последнюю редакцию дизайна в браузерном
  стенде. Критерий: три формата, круглый input без glow, фактура светлой кнопки,
  общие sliding switchers, флаги, упрощённые настройки, темы/редактор основных
  цветов и выбор языка. Проверка 2026-10-18: браузерные screenshots и действия
  RU/EN/ZH/AR, live custom palette, минимальный/средний/большой режимы; targeted
  analyze main/preview/src/presentation_models — No issues found. Обнаруженные
  minimal overflow 3 px, отсутствующие глифы иконок/китайского текста исправлены
  и повторно просмотрены. Верхние иконки унифицированы, иконки форматов 20 px,
  у групп симметричные зазоры 8 px. [Отчёт](../design-qa.md),
  [доказательства](evidence/windows-design-polish-20261018.json).
  Только UI preview; native/Android приёмка не закрыта. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).
- [ ] **EXVPN-E2-013** — Собрать и принять собственную рамку Windows и плавный
  resize на установленном приложении. Зависимость: E2-012; следующий отдельно
  разрешённый native цикл. Проверить drag, resize всех краёв/углов, уменьшение
  до min, 100/125/150/200% DPI, разные мониторы, minimize/tray-close, keyboard,
  startup и смену системного языка Windows/Android. Исходники подготовлены,
  native build/runtime не выполнялись по ограничению текущего задания.
  До приёмки не утверждать устранение Windows resize jitter. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).
  Прогресс 2026-10-18: пользователь разрешил сборку/обновление. +20 успешно
  собран (50,9 с), установлен поверх +19 и открыт от обычного пользователя.
  Read-only Win32: window/client 440×760 при 96 DPI, full-client frame true;
  installed EXE/AOT/service hashes совпадают с payload. Плавность/все три
  режима/DPI остаются на пользовательской визуальной приёмке; сетевые тесты
  и Full не запускались. [Отчёт](evidence/windows-design-build20.json).
- [x] **EXVPN-E2-014** — По отдельному поручению собрать и обновить установленный
  Windows-клиент новым дизайном. Критерий: возрастающий build, успешный installer,
  сохранённая rollback-копия и ordinary-user запуск из Program Files.
  Проверка 2026-10-18: 0.1.0+20, installer exit 0, PID UI 47856 responding,
  SCM Running; бинарники совпадают с payload. Это запуск для визуальной проверки,
  не завершение E2-013/VPN-приёмки. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).

- [x] **EXVPN-E2-015** — Подготовить web-дизайн обновления приложения и локальных
  проблем подписки. Критерий: три темы с «Я дизайнер», название текущего языка,
  scoped ошибка/повтор у группы без общей subscription-ошибки, полоса 24 px
  available → progress → simulated restart/new version при прежнем размере окна.
  Проверка 2026-10-18: браузерные действия и screenshots в
  `design/screenshots/windows-update-design/`; RU settings, group error/detail,
  download и итоговый Settings 0.1.1/build21 — только макет. Целевой analyze шести
  файлов без замечаний; Windows/APK builds, VPN tests, Full и установка не
  запускались. Реальная доставка/подпись/rollback/restart остаются в E6.
  Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).

## E3 — Подписки и хранилище

- [x] **EXVPN-E3-001** — Реализовать типизированную нормализацию URI, Base64 и поддерживаемого Xray JSON. Зависимость: контракт E1. Критерий: таблица протоколов, синтетические успешные/ошибочные fixtures, неизвестные записи и неправильные типы не исчезают молча. Доказательство: 2026-10-16, `packages/exvpn_domain`, `dart analyze` без замечаний, 113 тестов парсера/снимка пройдены; VLESS/REALITY/XHTTP/WS/gRPC, VMess, Trojan, SS SIP002/legacy, Hysteria2, JSON projection, ошибочные типы, дубликаты, границы и обезличенные ошибки. исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7). Реальные соединения этим не подтверждены.
- [x] **EXVPN-E3-002** — Добавить ограниченную HTTPS-загрузку и несколько подписок. Зависимость: E3-001. Критерий: проверка сертификата, ограничение времени/размера, ручное и шестичасовое обновление; нет токенов в исключениях/логах. Доказательство 2026-10-16: 35 тестов `SubscriptionLoader`, 6 тестов `SubscriptionRefresh`, widget-потоки нескольких групп; анализ чистый. HTTPS-only с обычной проверкой сертификатов, 15 секунд, 2 MiB фактических байтов, отказ redirect/partial206, строгий UTF-8, отмена и безопасные ошибки. Источники хранятся защищённо; запуск обновляет URL-группы старше шести часов, параллельные запросы объединяются. Mock HTTP не является доказательством доступности приватного провайдера. исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).
- [x] **EXVPN-E3-003** — Добавить атомарное обновление и последний рабочий список. Зависимость: E3-002. Критерий: timeout, повреждённый/пустой ответ и частичные ошибки сохраняют рабочие данные и показывают причину. Доказательство 2026-10-16: `SubscriptionSnapshot`, монотонная ревизия группы, сериализованный `SubscriptionPersistence` и зашифрованный журнал `SubscriptionStore`; тесты повреждённых/частичных ответов, поздних ответов, обрыва фаз записи, восстановления и backend failure пройдены. Подписка восстановилась после cold start Android; Windows DPAPI round-trip/tamper/delete проверены. Это не испытание физического отключения питания/повреждения носителя. исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7).
- [ ] **EXVPN-E3-004** — Интегрировать защищённое хранилище Android/Windows. Зависимость: E3-001. Критерий: credentials не лежат открытым текстом; unavailable secure backend не даёт тихого fallback; проверены перезапуск и удаление подписки.
  Дополнение 2026-10-17: обычный установленный Windows +13 прошёл 11 шагов
  импорта/выбора/удаления с настоящим DPAPI-хранилищем за 132,542 с без Computer
  Use; исходное пустое хранилище и сеть восстановлены. Cold restart этим
  сценарием не проверялся; пункт остаётся открытым.
  [Отчёт](evidence/windows-msaa-import-remove-build13.json), commit [c0b6dc9](https://github.com/Extectick/ExVPN/commit/c0b6dc9).
  Дополнение 2026-10-17: Windows service policy сохраняется отдельно через LocalSystem DPAPI/HKLM с проверяемым ACL и owner SID. Build +4 подтвердил сохранение исключений после hard kill/restart и disconnect; повреждённая запись не становится пустой автоматически. [Контракт](WINDOWS_POLICY.md), [отчёт](evidence/windows-policy-build4.json), исходники [c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73). Полный сценарий хранения подписок этим не закрывается.
  Прогресс: Android Keystore, Windows DPAPI и журнал реализованы; backend unit/fault-тесты и реальный DPAPI проверены, cold start Android проверен. Полный пользовательский сценарий удаления/перезапуска в Windows и физический Android остаются в приёмке. Native Android cache последнего сеанса/исключений реализован отдельно и сейчас проходит lifecycle QA.
- [ ] **EXVPN-E3-005** — Добавить QR, вставку текста и безопасную диагностику. Зависимости: E2, E3-001–004. Критерий: реальные пользовательские потоки импорта; экспорт ошибок обезличен и не содержит ключей/URL подписки.
  Прогресс 2026-10-16: импорт PNG/JPEG QR с подтверждением до сетевого запроса/добавления, 15 decoder/widget tests PASS, включая защиту от сложных ложных QR и зависшего файлового провайдера; безопасная диагностика с явным копированием и allowlist полей проверена тестами. Android picker/cancel/preview/Add/cold restart пройдены; Windows picker/cancel пройдены, полный импорт ещё открыт. Камера пока не реализована. См. `QR_IMPORT.md`; исходники [a88f75b](https://github.com/Extectick/ExVPN/commit/a88f75b), доказательства [c03e0e3](https://github.com/Extectick/ExVPN/commit/c03e0e3).
  Дополнение 2026-10-16: Android чтение перенесено перед eager-copy стороннего picker в собственный bounded reader: 5 MiB / 20 секунд, одна операция на процесс, независимые cancel/close. 8 JVM и 24 QR Flutter tests прошли, полный app suite — 133. API30 cancel/preview/oversize/retry и VLESS TCP/HTTPS нового APK подтверждены: [android-qr-bounded-smoke.json](evidence/android-qr-bounded-smoke.json). Touch-наблюдение, API36 нового picker и физический телефон остаются открытыми. Исходники: [fe48846](https://github.com/Extectick/ExVPN/commit/fe488467b9946b8f9ca79aad6d2a8bb777d25130).

Дополнение к E3, 2026-10-17:

- [x] **EXVPN-E3-006** — Поддержать HWID challenge подписки без аппаратных серийных номеров, тихой ротации ID или импорта служебного ответа. Критерий: один повтор того же HTTPS URL в исходный deadline, отдельные ошибки лимита/хранилища, устойчивый ID по origin из защищённого секрета, последний рабочий список сохранён при отказе. Проверено: 155 app tests, реальный DPAPI round-trip, live Dart HTTPS, обычный Android +7 импорт URL с HWID и 26 профилями. [Доказательства и границы](PROVIDER_COMPATIBILITY.md). Исходники: [f9313f3](https://github.com/Extectick/ExVPN/commit/f9313f31fe388f30f1c38d0f5837b86fc65b7f9b), QA: [8fa4b5d](https://github.com/Extectick/ExVPN/commit/8fa4b5dbb4545894e26617c91a5bba1bb284e9f2).
- [ ] **EXVPN-E3-007** — Добавить строго типизированную поддержку VLESS encryption MLKEM и FinalMask sudoku, обнаруженных в четырёх записях новой подписки. Зависимость: E1-002, E3-001. Критерий: валидация каждого поддержанного поля на Dart/native границе, сохранение peer authentication, отрицательные тесты и настоящий HTTPS. Произвольный provider JSON в stream/routing не передаётся. Две записи Vision без TLS/REALITY не исправлять скрытым отключением flow.
  Прогресс 2026-10-17: модель, URI/JSON/native/snapshot поддержка реализованы;
  192 domain +46 state тестов и 24 loopback HTTPS комбинации прошли, проверены
  неправильные ключи/маски, с которыми HTTPS-назначение не достигается. Настоящая подписка
  импортируется 30/32, но новые четыре узла не прошли внешний HTTPS (0/4).
  Пункт остаётся открыт до подтверждения этих подключений на клиенте.
  [Границы и доказательства](VLESS_ENCRYPTION.md).
  Исходники: [f5901bc](https://github.com/Extectick/ExVPN/commit/f5901bc7d0b61d22f555bc760cbfcb5e3c85de81).
- [x] **EXVPN-E3-008** — Уточнить диагностику отдельных отклонённых записей и частичного обновления. Критерий: безопасный номер записи/причина, явное решение пользователя о частичной замене, отсутствие незаметной потери рабочего списка. В +7 показано число шести отказов; ручное Android-обновление сохранило список, точная причина не снята в runtime-отчёте.
  Прогресс 2026-10-17: реализованы безопасные причины по индексам и подтверждение
  точного нормализованного кандидата. Фоновое обновление сохраняет старый список;
  новый запрос, удаление, перезапуск и поздний HTTP не применяют устаревшее согласие.
  11 новых state tests и 35 focused Flutter tests PASS, analyze без замечаний;
  проверены отмена/подтверждение, persistence round-trip, HTTP race и 40 причин
  на узком экране с увеличенным шрифтом. Контракт: [ARCHITECTURE.md](ARCHITECTURE.md).
  Windows runtime +13 PASS: два процесса реального Flutter UI, current-user
  DPAPI, отмена сохраняет три записи/выбор, явная замена оставляет одну запись
  с безопасными причинами 2/3, cold restore и удаление через UI. QA entry point
  использует отдельный каталог хранения; default AppData/native IME не проверены.
  [Отчёт](evidence/windows-subscriptions-build13.json),
  [снимок](evidence/windows-subscriptions-build13-review.png).
  Android API30 runtime +13, 2026-10-17: отдельный UI-прогон PASS за 191,583 с.
  Отмена сохраняет три записи/выбор; явное согласие оставляет одну с причинами
  2/3; новый процесс восстанавливает принятый список и те же шифрованные данные.
  QA-группа удалена, сервис отсутствует, прямой HTTPS восстановлен. После
  незавершившегося за 15 с штатного закрытия принудительно остановлены только
  принадлежащие стенду процессы эмулятора; исходный эмулятор не менялся.
  [Отчёт](evidence/android-runtime-build13.json),
  [подтверждение](evidence/android-subscriptions-build13-review.png),
  [cold restore](evidence/android-subscriptions-build13-restored.png).
  Физическое устройство и независимый транспортный lifecycle gate не входят
  в этот результат; полный E1 остаётся открытым.
  Исходники: [b2cc272](https://github.com/Extectick/ExVPN/commit/b2cc272).

## E4 — Android-клиент

2026-10-17, первая попытка +17: same-signer upgrade +16 → +17 прошёл,
точные APK/UID/dataDir проверены. Поиск остановлен тестовым selector до ввода
и Connect: Android XML содержит единственное поле, но не содержит его label.
Причина отсутствия label в dumper/engine пока неизвестна; accessibility не
принята. Отдельная очистка прошла за 81,452 с: QA-группа удалена, выбранных
исключений ноль, нет VPN/service, настройки ОС сохранены, owned AVD остановлен.
Исходный INDETERMINATE не заменён PASS. Root сверил 403 + 264 файла.
[Upgrade и границы проверки](evidence/android-upgrade-search-build17.json),
[исходники](https://github.com/Extectick/ExVPN/commit/2cd1f71404d4516ad22312d8722f98ef4867eda3).

Во второй попытке +17 реальный ввод запроса и фильтрация двух QA-приложений
подтверждены свежим Android XML; Save и переключение исключения не выполнялись.
Сценарий ошибочно требовал `scrollable=true`, хотя после фильтрации содержимое
поместилось целиком. До Connect/DNS он не дошёл. Отдельный cleanup PASS за
91,028 с вернул пустые группы/исключения и остановил owned AVD; исходный
INDETERMINATE сохранён. Root сверил 400 + 268 evidence-файлов.
[Вторая попытка и причина](evidence/android-search-runtime-build17.json).

Для следующего прогона подготовлен общий selector: 61 synthetic check и
read-only replay четырёх сохранённых UI tree PASS, независимый review без
замечаний. Контейнер определяется по поиску и общему счётчику; короткий
непрокручиваемый список допускается без разрешения свайпа. Неоднозначные,
скрытые и неверные targets отклоняются. ADB-действий и нового сетевого
прогона нет; интеграция helper в следующий runtime-сценарий ещё требуется.
[Проверки](evidence/android-exclusions-selectors-build17.json),
[код 1884fae](https://github.com/Extectick/ExVPN/commit/1884fae804a17b8fe9fdf41eecaf9fd09332427d).

- [ ] **EXVPN-E4-001** — Реализовать VpnService, системное разрешение, foreground notification и полный жизненный цикл. Зависимости: E1–E3. Критерий: служба независима от Activity, видимый статус достоверен, повторный старт/stop безопасен.
  Прогресс 2026-10-16: Kotlin VpnService + TUN/JNI и общий Dart bridge реализованы; обе JNI ABI и debug APK собраны. В эмуляторе API36 после системного согласия независимое приложение получило HTTPS204 через TUN; реальные счётчики увеличились. Сохранённая подписка восстановилась после force-stop/cold start. Полный жизненный цикл и физическое устройство ещё проверяются; пункт открыт.
- [ ] **EXVPN-E4-002** — Добавить исключения по package/UID и отображение системной защиты. Зависимость: E4-001. Критерий: package lifecycle не расширяет исключение, настройки lockdown доступны, системное поведение не обещается как управляемое приложением.
  Дополнение +17, 2026-10-17: общий Android/Windows экран получил поиск по
  названию и package/path, общий счётчик выбранных. Скрытые и отсутствующие
  в отфильтрованном списке исключения сохраняются при Save; ошибки чтения
  не показывают ложный нулевой выбор. 10 widget tests/analyze PASS, включая
  телефон 360×640 с клавиатурой, доступность строки и Save. В установленном
  +17 подтверждены ввод и фильтрация; переключение/Save ещё не приняты.
  [Код 464c0a5](https://github.com/Extectick/ExVPN/commit/464c0a5),
  [проверки](evidence/exclusions-search-build17.json). Полный пункт открыт.
- [ ] **EXVPN-E4-003** — Реализовать интерфейс по выбранному эталону. Зависимости: E2, E4-001–002. Критерий: главный экран, подписки, настройки и ошибки проверены на физическом устройстве; сохранены обезличенные скриншоты.
- [ ] **EXVPN-E4-004** — Выполнить Android regression на минимальной и актуальной ОС. Зависимости: E4-001–003. Критерий: смена Wi-Fi/mobile, экран выключен, закрытие UI, перезапуск процесса, авария ядра, DNS/IPv6 и явное отключение в lockdown.
  Прогресс 2026-10-16: добавлен отдельный Android11/API30 smoke на том же APK, что API36. Подтверждены VLESS TCP/HTTPS через TUN, отказ при остановке прокси, Blocked и восстановление direct после явного отключения. Остальная API30 матрица и физическое устройство ещё не проверены; [ANDROID_VALIDATION.md](ANDROID_VALIDATION.md).

## E5 — Windows-клиент

2026-10-17, +17: штатный upgrade +16 → +17 в Sandbox прошёл с exit 0;
точный payload и работа SCM-службы проверены. Сеть, пустое хранилище и 20
прежних backup-копий сохранены, появилась одна backup-копия +16. Отдельная
очистка пяти служебных QA-файлов прошла; UI/VPN этот сценарий не запускал.
Root сверил 43 файла доказательств. [Upgrade](evidence/windows-upgrade-build17.json),
[исходники](https://github.com/Extectick/ExVPN/commit/2cd1f71404d4516ad22312d8722f98ef4867eda3).

- [ ] **EXVPN-E5-001** — Реализовать службу, установку/запуск, ACL IPC и управление ядром. Зависимости: E1–E3. Критерий: минимальные привилегии UI, валидация команд на стороне службы, устойчивое состояние после рестарта.
  Дополнение 2026-10-17: NSIS +5 → +6 и полный installed SCM fault run при ограниченных правах UI прошли; QueryLimited grant только owner SID, readback до IPC, контроль процесса/запись HKLM запрещены. После hard kill/restart guard сохранился, исключение восстановлено, explicit disconnect/cleanup вернули сеть. [Протокол](WINDOWS_UNELEVATED.md), исходники [a617aad](https://github.com/Extectick/ExVPN/commit/a617aad16c6e1803fcd6e1557d1c500861732e74), [59bbcdf](https://github.com/Extectick/ExVPN/commit/59bbcdfc85dc1a99c43703445ae491154b78167a). Общий E5 этим не закрывается.
  Дополнение 2026-10-17: durable policy и неизвестное состояние при storage error реализованы; полная повторная проверка +4 на настоящей LocalSystem SCM-службе сохранила выбранное исключение и guard после аварии. Go tests/vet, 20 Flutter tests/analyze прошли. [Отчёт](evidence/windows-policy-build4.json), [c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73).
  Прогресс 2026-10-16: Go SCM-служба и C++ Flutter adapter реализованы; x64 service build и unprivileged named-pipe roundtrip/отказ чужому executable пройдены. Установлены VS C++/CMake/Windows SDK/ATL; полный Flutter debug build прошёл. Реализована классификация владельца соединения собственным адаптером: неоднозначный UDP не становится исключением, TCP проверяет полный tuple. На хосте служба/драйвер не установлены. В Sandbox после исправления WFP DWORD результата подтверждены установка LocalSystem-службы, Running, права и restart; Сквозная проверка UI↔SCM/TUN выполнена позднее отдельным QA entry point (см. E1-007); ordinary-user token и вся матрица E5 остаются открытыми. Исходники: [b2f4e42](https://github.com/Extectick/ExVPN/commit/b2f4e427075af5f5592904f0f6fdbdc82755af54).
- [ ] **EXVPN-E5-002** — Реализовать TUN, DNS, маршруты, persistent WFP и исключения. Зависимость: E5-001. Критерий: тесты аварий и утечек пройдены; фильтры блокируют после падения процесса службы.
  Дополнение 2026-10-17, Windows +16: обычный Connect создал TUN/WFP, но
  до независимого HTTPS сценарий отказал на сравнении DPAPI ciphertext.
  При однократном обычном Disconnect служба неожиданно завершилась (7034,
  SCM 1067); действительный process exit code/stack не захвачены, причина
  неизвестна. Отдельное восстановление PASS за 101,554 с: служба Running,
  штатный UI exit 0, нет TUN/WFP/подписок, сеть и 20 backups сохранены.
  Root сверил 489 файлов. [Доказательства и ограничения](evidence/windows-shorebird16-service-exit.json).
  [Запись af05c0b](https://github.com/Extectick/ExVPN/commit/af05c0b).
  Сбой не считается исправленным.
  Последующий отдельный +16 прогон подтвердил независимые HTTPS200/204,
  изменённый внешний IPv4, explicit TUN DNS и обычное отключение с возвратом
  исходного IP/сети. Удержанный дескриптор SCM подтвердил тот же живой процесс.
  Общий сценарий REFUSED на последующем QA-выходе до C# stage; отдельный
  штатный Exit/cleanup PASS за 67,758 с. Root сверил 398 файлов. Прежняя
  авария не отменена; IPv6/leaks/exclusions/fault не проверялись.
  [Сетевые проверки и отдельная очистка](evidence/windows-shorebird16-network.json).
  Дополнение 2026-10-17: persistence исключений после аварии теперь подтверждена в +4; все семь прежних протокольных сценариев и SCM fault run прошли повторно. Остальные границы E1/E5 сохраняются. [Отчёт](evidence/windows-policy-build4.json), [снимок](evidence/windows-policy-after-crash-build4.png), [c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73).
  Дополнение 2026-10-16: проверка аварии теперь выполнена и на установленной SCM-службе через production Flutter bridge. Выбор точного executable в UI, одновременные probes, обрыв сервера, hard kill SCM, restart и явное восстановление прошли. Полная приёмка не закрыта: ordinary-user token, отдельный egress IP, UDP/IPv6/DNS leak capture и persistence исключений после аварии требуют продолжения. [Методика](WINDOWS_AUTOMATED_QA.md), [1575305](https://github.com/Extectick/ExVPN/commit/1575305923c37b9c1f41721d6b07ad11fe133824).
  Прогресс hostname DNS 2026-10-16: реализован DoH endpoint bootstrap под временными WFP-разрешениями после persistent guard, до TUN; original hostname/SNI/Host сохранены. Unit/config/lease/SDK tests и реальный отдельный Sandbox WFP/DoH smoke прошли: независимый executable блокируется, посторонние IP/port блокируются, закрытие разрешения сохраняет guard, disarm восстанавливает HTTPS. Сквозной hostname VPN через SCM, packet capture, TTL/network-change и bootstrap crash открыты. [Детали](WINDOWS_DNS_BOOTSTRAP.md), [результат](evidence/windows-bootstrap-smoke.json), исходники [713b1a0](https://github.com/Extectick/ExVPN/commit/713b1a0ebb990e7b32a32e7544385fbc793bdc84).
  Прогресс 2026-10-16: в Sandbox собственный диагностический процесс с production Controller/WindowsGuard/Xray провёл реальный HTTPS 200/204 через TUN. Исправлены три WFP GUID и адреса DNS, совпадавшие с локальным IP адаптера. При обрыве VLESS-сервера защищаемый процесс блокируется, исключённый продолжает HTTPS; после hard kill диагностического процесса оба блокируются, WFP сохраняется. Явное отключение/восстановление снимает фильтры, возвращает HTTPS; хеши маршрутов/DNS совпадают с исходными. Это не SCM/UI-приёмка, не проверка разных внешних IP и не полный IPv6/DNS leak test. [Доказательства](evidence/windows-sandbox-network-smoke.json), исходники [c50f5cd](https://github.com/Extectick/ExVPN/commit/c50f5cd), стенд [9fdf035](https://github.com/Extectick/ExVPN/commit/9fdf035).
- [ ] **EXVPN-E5-003** — Добавить интерфейс по эталону, трей и reconnect. Зависимости: E2, E5-001–002. Критерий: проверен работающий Windows UI, клавиатура, DPI, закрытие окна и управление из трея.
  Прогресс 2026-10-17: в +14 реализован собственный Win32 tray, Close→hide, show, отдельные Connect/Disconnect через общий controller и подтверждённый выход из UI с сохранением подписок. 17 focused tests и analyzer PASS; общий Full — 10/10 за 96,93 с, 465 Dart/Flutter tests. Windows EXE/installer собраны, независимый payload audit PASS; реальная установленная +14 tray/DPI/клавиатурная приёмка ещё не выполнена. [Контракт и доказательства](WINDOWS_TRAY.md), [e90e66b](https://github.com/Extectick/ExVPN/commit/e90e66bb59e1c2cc893eec8408b545e759fe3ddf).
  Дополнение 2026-10-17: установленный +10 medium-token UI прошёл переход reconnecting → connected при guest Ethernet down/up без действий пользователя; timer начинается заново после HTTPS verification. [Отчёт и обезличенные снимки](evidence/windows-network-recovery-build10.json), исходники [924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479). Это частичный runtime smoke, не окончательная дизайн/DPI/клавиатурная приёмка.
  Дополнение 2026-10-17: +5 показал storage error в настоящем UI, повторное чтение не сбрасывало данные; явный сброс убрал ошибку и сохранился после SCM restart. [Отчёт](evidence/windows-policy-recovery-build5.json), [скриншот](evidence/windows-policy-corrupt-build5.png), [fd08979](https://github.com/Extectick/ExVPN/commit/fd089794723f1db0ede022e01804b4026e90de80). Трей/DPI/системный IME остаются открытыми.
  Дополнение 2026-10-16: build +3 различает потерю транспорта и guard после рестарта службы, показывает действие «Отключить». Повторный Flutter/SCM fault run подтвердил коды и тексты на работающем UI; сетевые проверки/cleanup прошли. 18 релевантных tests и analyze пройдены. [Отчёт +3](evidence/windows-scm-failure-build3.json), [скриншот](evidence/windows-scm-restarted-build3.png), исходники [e22a748](https://github.com/Extectick/ExVPN/commit/e22a748dd1fde206dd4fed8208e93b329636b652).
  Дополнение 2026-10-16: реальный Flutter UI импортировал семь узлов, выбрал строки, подключил/отключил каждый через native service. [Снимок XHTTP](evidence/windows-flutter-sandbox-xhttp.png) снят с работающего RenderRepaintBoundary, не из web demo. Трей, DPI, системный IME и полный reconnect этой проверкой не закрываются. Исходники [625a875](https://github.com/Extectick/ExVPN/commit/625a875).
- [ ] **EXVPN-E5-004** — Подготовить NSIS upgrade/uninstall и восстановление сети. Зависимости: E5-001–003. Критерий: чистая установка, upgrade, неудачный upgrade и uninstall не оставляют чужие/повреждённые DNS, маршруты, фильтры; чужие правила сохраняются.
  Дополнение 2026-10-17: настоящий NSIS rollback **+13 → +12** и recovery
  **+12 → +13** прошли с проверкой полного payload и восстановления сети.
  Первый запуск остановился на несовместимом QA token owner, второй — на
  ошибке совместного чтения журнала стенда. Independent HTTPS/DNS и locked-file
  upgrade/uninstall в этих попытках не достигнуты. Исходные REFUSED сохранены;
  финальная очистка PASS, прежние backups не изменены. [Частичный отчёт](evidence/windows-maintenance-build13-partial.json).
  Дополнение 2026-10-17: upgrade **+4 → +5** прошёл exit 0; после отдельного storage recovery run encrypted baseline, production binding, маршруты/DNS восстановлены, guard/TUN отсутствуют. [Отчёт](evidence/windows-policy-recovery-build5.json), [fd08979](https://github.com/Extectick/ExVPN/commit/fd089794723f1db0ede022e01804b4026e90de80).
  Дополнение 2026-10-17: NSIS upgrade **+3 → +4** с обновлением service binary прошёл exit 0. QA Refresh принимает новый бинарник только по защищённому installed manifest при сохранённых owner SID/production binding; обходов IPC ACL нет. После fault run сеть восстановлена. [Отчёт](evidence/windows-policy-build4.json), [c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73).
  Дополнение 2026-10-16: NSIS upgrade **+2 → +3** завершился exit 0; owner SID и service binary сохранены. После повторного теста отказов служба Running с production client path, TUN/guard отсутствуют, route/DNS hashes совпали. [Обезличенный отчёт](evidence/windows-scm-failure-build3.json), стенд [f83ab84](https://github.com/Extectick/ExVPN/commit/f83ab845515d7f9a0208422d06458de2076c6d9c).
  Дополнение 2026-10-16: реальный silent NSIS upgrade **0.1.0+1 → +2** в Sandbox завершился exit 0, owner SID сохранён. После семи VPN-сеансов и повторной QA-привязки production SCM-команда восстановлена, служба Running, TUN отсутствует, HTTPS после disconnect работает. Forced-failure upgrade/rollback и полная network-diff матрица остаются открытыми. [Отчёт](evidence/windows-flutter-sandbox-smoke.json), исходники [625a875](https://github.com/Extectick/ExVPN/commit/625a875).
  Прогресс 2026-10-16: development NSIS пересобран; partial upgrade/uninstall восстанавливают подтверждённый предыдущий пакет, machine-wide mutex не допускает параллельную установку разных owner. 13 файловых failure-сценариев и проверки manifest/mutex прошли под PS5.1; SCM/ACL подменены в тестах. [8d8e48b](https://github.com/Extectick/ExVPN/commit/8d8e48b). После второй перезагрузки Sandbox работает. Чистый install/ACL/recovery/restart/uninstall прошёл, хеши маршрутов/DNS гостя совпали; исправлены WFP DWORD и проверка раскрытых SCM-прав. [Результат](evidence/windows-sandbox-installer-smoke.json), [подробности](WINDOWS_VALIDATION.md). TUN, crash, version-pair upgrade/rollback и удаление после активного VPN ещё открыты. Исходники: [b2f4e42](https://github.com/Extectick/ExVPN/commit/b2f4e427075af5f5592904f0f6fdbdc82755af54).

- [x] **EXVPN-E5-005** — Сохранять Windows-исключения между запусками службы и дать явное восстановление при повреждении. Зависимость: реализация SCM/IPC E5-001. Критерий: owner-bound encrypted policy, отсутствие тихого пустого списка при ошибке, сохранность исключения после crash/restart/disconnect, видимый UI reset и reopen. Доказательство 2026-10-17: 10 Go tests хранения/состояния + весь Windows module/vet, 20 Flutter tests/analyze, реальный LocalSystem SCM +4 и UI recovery +5 прошли. Guard не снимается восстановлением настроек; системные изменения ограничены Sandbox. [Контракт и границы](WINDOWS_POLICY.md), [crash +4](evidence/windows-policy-build4.json), [recovery +5](evidence/windows-policy-recovery-build5.json); исходники [c3061b4](https://github.com/Extectick/ExVPN/commit/c3061b489608cc37b767479436a2bac16f0b5a73), [fd08979](https://github.com/Extectick/ExVPN/commit/fd089794723f1db0ede022e01804b4026e90de80). Общий E5 и испытания реального диска/потери питания остаются открытыми.

- [x] **EXVPN-E5-006** — Исключить обращения к Wintun после `EndSession` при
  закрытии туннеля. Зависимость: E5-001–002. Критерий: retained packet и
  concurrent Read/Write/Wait/Close проходят deterministic/race tests;
  установленный новый пакет подтверждает HTTPS и обычное отключение без
  завершения SCM-службы, с восстановлением сети. Проверено 2026-10-17:
  source RED воспроизведён, исправление, race ×10 и независимое ревью пройдены.
  Установленный +17 подтвердил HTTPS200/204, TUN DNS, смену/возврат IPv4,
  Disconnect и normal UI exit0 с тем же удерживаемым процессом SCM-службы.
  Cleanup PASS; root независимо сверил 393 evidence-файла.
  [Runtime +17](evidence/windows-network-build17.json). Один профиль/цикл;
  это не закрывает общие E1/E5 и не доказывает причину прежней аварии +16.
  [Контракт и границы](WINDOWS_TUN_LIFETIME.md),
  [код d9444db](https://github.com/Extectick/ExVPN/commit/d9444db).
  Общий [Full +17](evidence/fast-validation-build17.json): 11/11 PASS за
  125,52 с, source fingerprint неизменен, Go result cache выключен.
  Полные CI lanes пакетного commit `2cd1f71` также PASS: Android 20 мин 46 с,
  Windows 11 мин 11 с. [CI +17](evidence/ci-build17.json).

- [x] **EXVPN-E5-007** — Реализовать режимы и атомарное нативное переподключение
  как отдельный проверяемый backend. Проверено 2026-10-18: 34 focused Dart checks,
  native/windows unit, focused race и vet; реальный HTTP/HTTPS CONNECT через
  независимый loopback VLESS peer, TLS trust rejection, статистика и закрытие.
  VPN-смена сервера сохраняет guard; recovered/unclean guard запрещает PROXY.
  Служба +19 собрана. [Контракт и границы](SYSTEM_PROXY.md).
  [Проверки и установленный запуск +19](evidence/windows-proxy-build19.json).
  Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98). Это не закрывает E1/полную системную приёмку.

- [ ] **EXVPN-E5-008** — Принять установленный Windows PROXY/VPN: WinINET,
  восстановление чужих/PAC-настроек, переключение/аварии, штатный exit,
  upgrade/uninstall и отсутствие прямого обхода при VPN-переподключении.
  Подготовлены C++ journal/WinINET bridge, recovery при недоступной службе и
  блокировка обслуживания с активным proxy lease. 11 fake C++ сценариев прошли;
  это не проверка реальных WinINET-настроек Windows. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98).
  Установщик +19 применён с exit0, пакет EXE/AOT/service сверены; новый UI
  отвечает, SCM-служба Running. [Доказательство](evidence/windows-proxy-build19.json).

## E6 — Версии и обновления

Пакеты +17, 2026-10-17: Android release APK/AAB и Windows development NSIS
собраны. Same-signer +16/+17, `exvpn.5`, updater policy и состав пакетов
проверены; root сверил 26 package и 20 native evidence файлов. Android audit
сохраняет три release blockers, Windows — пять. Сборки не закрывают runtime
и OTA-критерии. [Отчёт](evidence/packages-build17.json),
[native](evidence/native-build17.json),
[исходники 2cd1f71](https://github.com/Extectick/ExVPN/commit/2cd1f71404d4516ad22312d8722f98ef4867eda3).

Отдельный AAB +17: 52 библиотеки, 48 digest совпали, четыре без digest;
offline 8,339 с, без Gradle/сети. Root сверил 57 inputs и восемь output-файлов.
Отдельный APK и полная лицензионная проверка этим не покрыты.
[Доказательства](evidence/android-aab-metadata-build17.json).

- [ ] **EXVPN-E6-001** — Реализовать четыре идентичности версий и beta/stable. Зависимости: E3–E5. Критерий: SemVer/build, core pin, data revision и Dart patch показаны независимо; проверены совместимость и запрет downgrade вне политики отката.
- [ ] **EXVPN-E6-002** — Реализовать signed manifest Ed25519 и SHA-256 файлов данных. Зависимость: E6-001. Критерий: неверная подпись/хеш, несовместимость, выход пути, обрыв и нехватка места отклоняются до активации.
- [ ] **EXVPN-E6-003** — Добавить staging, атомарную активацию и последний рабочий набор. Зависимость: E6-002. Критерий: обновление не прерывает активный VPN; сбой на каждом шаге сохраняет работоспособность; rollback новой подписанной ревизией проверен.
- [x] **EXVPN-E6-004** — Подключить Shorebird и включить обязательную подпись патчей. Зависимость: доступ к сервису/ключам и E6-001. Критерий: реальный release → signed patch → update → rollback Android/Windows, каналы изолированы; native change требует полного выпуска.
  Принято2026-10-20, база `5bddc777`, patch `0d9fdf22`, rollback helper `4a2262f3`:
  реальные signed update/restart/rollback Android и Windows, RSA/channel checks,
  native rejection tampered cache и сохранение данных. [Runtime](evidence/shorebird29-runtime-qa.json).
  E1/физический Android/Authenticode/stable не закрываются этим OTA gate.

  Дополнение 2026-10-17: Windows +16 прошёл отдельный cold reopen → versions
  → normal Exit с фактическим кодом 0 за 227,199 с. Cleanup PASS, payload,
  сеть, служба, storage и 20 backups сохранены. Root сверил 130 файлов.
  [Доказательства](evidence/windows-shorebird-base16-cold-exit.json).
  Предыдущий частичный exit PASS/следующий cold NOT_RUN остаётся REFUSED
  из-за sharing violation команды стенда; 85 файлов сверены отдельно.
  [Прежний отказ](evidence/windows-shorebird-base16-exit-partial.json).
  Native updater/configuration и облачный signed patch/rollback не доказаны.
  Код пакета: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).
  Runtime +16, 2026-10-17: Android API30 показал версии/base/beta до и после
  настоящего cold reopen за 76,980 с; подписанный APK, UID/dataDir и настройки
  ОС проверены. [Отчёт](evidence/android-shorebird-base16-runtime.json),
  [снимок](evidence/android-shorebird16-versions.png).
  Windows upgrade +13 → +16 прошёл, но первый переход к версиям дал timeout,
  UI исчез без сохранённого exit code; причина и updater остаются открытыми.
  [Отчёт Windows](evidence/windows-shorebird-base16-first-attempts.json).
  Повторное непрерывное наблюдение подтвердило экран сборки 16/base/beta;
  стенд отказал на MSAA role и изменении MainWindowHandle. Исходный UI
  оставался жив на 300-секундном deadline и последующем read-only postcheck.
  Сеть/служба/storage/20 backups неизменны; UI и два QA receipts оставлены,
  cleanup, graceful exit и cold reopen не подтверждены. Это не crash verdict.
  [Наблюдение Windows](evidence/windows-shorebird-base16-continuous-owner.json).
  Надпись base сама по себе не доказывает успешную native-конфигурацию:
  current/next C API допускает `0` при ошибке чтения. E6 не закрыт.
  Код базы: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f); проверка SDK: [c227570](https://github.com/Extectick/ExVPN/commit/c2275700c0b849bba47c468c06e1412ddb1993a7).
  Подготовка +16, 2026-10-17: локальные раздельные Android/patch signing keys,
  строгая updater policy, pinned dry-run wrapper без cloud publication и
  runtime-specific notices/seal/audit. Настоящие Shorebird базы собраны с
  dry-run без облачной публикации: Android APK/AAB и unsigned Windows NSIS.
  Подпись APK и обе ABI движка проверены, Android strip
  воспроизводится аудитором; Windows payload сверяется извлечением из EXE.
  84 + 44 + 72 целевых проверки PASS; финальный Full **11/11 за 111,44 с**,
  493 Dart/Flutter-теста и Go без result cache, fingerprint совпал.
  [Базы и release blockers](evidence/shorebird-base-build16.json),
  [Full](evidence/fast-validation-shorebird-build16-final.json),
  [контракт и ограничения](SHOREBIRD.md). Исходники и запись доказательств: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).
  Реальные подписанные patch/rollback и изоляция каналов пока не подтверждены.
  Дополнение +15, 2026-10-17: пользователь завершил CLI login, проект ExVPN
  создан на free account; doctor 6/6 PASS. В клиент добавлены ручные SDK
  check/download, реальные current/next patch, обработка rollback/ошибок и
  неизменяемый подпиской build track. Автоматического перезапуска VPN нет.
  [Контракт](SHOREBIRD.md), [doctor](evidence/shorebird-project-doctor.json).
  Full: **11/11 за 121,65 с**, **493 Dart/Flutter-теста**, Go без result cache;
  fingerprint совпал. [Проверки +15](evidence/fast-validation-shorebird-build15.json).
  Signed release/patch/rollback и
  изоляция каналов на устройствах пока не подтверждены. Исходники:
  [30af3e6](https://github.com/Extectick/ExVPN/commit/30af3e6619e13e5b9ceeca9d540b578fa9ac8696).
  Дополнение 2026-10-17: CLI 1.6.129 добавлен в user PATH; на прежнем commit
  исправлены branch/upstream для doctor и путь к тому же JBR 21.0.6.
  Doctor: 5/6 validators PASS, пять URL доступны; остаётся конфигурация проекта.
  OAuth ожидал пользователя и завершился тайм-аутом; cloud app/release/patch не
  создавались. [Доказательство](evidence/shorebird-user-install-doctor.json).
  Доказательства: [1fd0bd5](https://github.com/Extectick/ExVPN/commit/1fd0bd55b876a0251e803fc1123390546442568b).
  Подготовка 2026-10-17: отдельный CLI 1.6.129 закреплён commit/lock/entry-point hashes и успешно запущен; `doctor --json` выявил ожидаемые ограничения detached pin и отсутствие app config, несмотря на exit 0. Cloud app/release/patch/ключи не создавались. [Контракт](SHOREBIRD.md), [доказательство](evidence/shorebird-cli-preflight.json), исходники [aaaf6f4](https://github.com/Extectick/ExVPN/commit/aaaf6f43826508cea252c1fd0018c98b087bbde2). Это не проверка Dart OTA.
- [x] **EXVPN-E6-007** — Реализовать и проверить локальные контракты полного Windows updater. Критерий: строгая подпись/метаданные/байтовая загрузка/кеш/протокол, сериализация обновлений, guarded restart и атомарный отказ установки при активной службе покрыты автономными проверками; helper включён в пакет. Проверка 2026-10-18: 54 helper checks, 29 controller tests, lifecycle/tray и installer fixtures PASS; итоговый Full **12/12 за 86,49 с**, 284 app tests, fingerprint неизменен. Кандидат **0.1.0+21** установлен вручную поверх +20, четыре основных бинарных компонента совпали с payload, service Running и UI открыт; installed helper check — exit0/upToDate/stderr0. Это базовая установка, не полный цикл E6-006. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98). [Доказательства](evidence/windows-app-updater-build21.json), [Full](evidence/fast-validation-app-updater-build21.json).
- [ ] **EXVPN-E6-006** — Подключить верхнюю полосу к реальным источникам обновлений Windows. Зависимости: E6-001/004/005. Критерий: подписанная HTTPS-доставка, реальная загрузка и повторное открытие новой версии; отмена UAC и отказ установки показаны корректно; активный VPN не отключается установщиком. Прогресс 2026-10-18: production controller, dedicated helper/ключ, фиксированный feed, проверка подписи/размера/хеша, guarded restart и упаковка реализованы. Локальные fixtures не заменяют полный цикл; пункт открыт. Исходники: [5b41a1c](https://github.com/Extectick/ExVPN/commit/5b41a1c070aa1d19675d9af3aabb1939a097fe98). [Контракт](WINDOWS_APP_UPDATES.md).
- [ ] **EXVPN-E6-005** — Проверить полное обновление APK/Windows. Зависимости: E4–E5, ключи подписи. Критерий: сохранены подписки/настройки, идентичность подписи, непрерывность защиты и явный безопасный перезапуск ядра.
  Дополнение 2026-10-17: Windows Sandbox maintenance matrix +12/+13 PASS,
  63 этапа/17 UI-шагов за 1222,735 с, включая 65,440 с cleanup. Проверены
  rollback, locked-file upgrade/uninstall с восстановлением, успешный upgrade,
  обычный Stop с persistent guard и заблокированным HTTPS, удаление в таком
  состоянии и чистая переустановка. HTTPS/DNS и encrypted storage проверены
  до/после; 14 прежних backups сохранены, сеть гостя восстановлена. Root
  повторно сверил 329 private files: 0 расхождений. Это отдельные immutable
  +12/+13; +16 и changed public IP этим стендом не подтверждены. Успешное
  удаление при ещё работающем VPN, power loss/disk-full/IPv6 и release signing
  остаются открытыми. [Отчёт](evidence/windows-maintenance-build13.json).
  Исходники и запись доказательств: [e707d94](https://github.com/Extectick/ExVPN/commit/e707d942c5bfd01075ba57f512b6aabec954980f).

Прогресс E6 от 2026-10-16: библиотека подписанных данных реализована и прошла
24 runtime-теста и 7 тестов офлайн-подготовки пакета, анализ чистый. Проверены
реальный loopback HTTPS, неверный TLS/signature/hash,
ошибки записи, восстановление/rollback, конкурирующие процессы и отказ активации
при изменении состояния VPN. Flutter-экран версий/подготовки/применения реализован;
19 новых OTA app tests прошли после дополнительной проверки восстановления состояния. Доверенные endpoint/key задаются при сборке; по умолчанию
доставка отключена. Реальная HTTPS-доставка QA-пакета, запрет применения при
работающем VPN, отмена, применение, cold recovery и откат новой ревизией
проверены в Android API36; ключ отдельный тестовый, не production.
См. [ANDROID_VALIDATION.md](ANDROID_VALIDATION.md) и [DATA_UPDATES.md](DATA_UPDATES.md).
Исходники интеграции: [a88f75b](https://github.com/Extectick/ExVPN/commit/a88f75b),
инструмента подписи: [0ff73cf](https://github.com/Extectick/ExVPN/commit/0ff73cf).
Production signing/delivery, Windows native OTA и Shorebird остаются открытыми.
Платформенные доказательства QR/OTA: [c03e0e3](https://github.com/Extectick/ExVPN/commit/c03e0e3).

## E7 — Общая beta

- [x] **EXVPN-E6-017** — Независимая доставка подписанных Dart-патчей и быстрые сборки.
  Критерий: одна база Android/Windows 0.1.10+32 со всеми текущими UI-изменениями;
  реальные independent apply/cold launch/withdraw/cold rollback, неизменные
  APK/EXE и пользовательские данные; replay/signature/compatibility отказ закрыт;
  AOT-only workflow без Cloud API и source-bound cache service/JNI.
  2026-10-20: 12/12 Full, 447 app tests, 61 свежий JVM test PASS;
  AOT-only патчи Windows 38,52 с / Android двух ABI 69,05 с без Cloud/Gradle/CMake.
  Реальные SDK/UI 2→3→2 и patch null→1→null подтверждены в Sandbox и x64 AVD,
  данные и APK/EXE неизменны. Перезапуски ручные; автоматический handoff и физический
  Android не приняты. Опубликована [0.1.10+32 Preview](https://github.com/Extectick/ExVPN/releases/tag/v0.1.10);
  независимое скачивание 20 assets подтвердило хеши, Android signer, оба feeds,
  каталог 6 и два комплекта AOT для будущих patch jobs. Источники `f99ea90`,
  патч `440fc3d`, runtime-доказательства `0975de4`; E6-008 и E1 остаются открытыми.
  [План](INDEPENDENT_OTA_PLAN.md), [runtime](evidence/independent32-runtime.json),
  [ограничения](evidence/independent32-scope.json),
  [публичный аудит](evidence/independent32-public-download-audit.json).

- [x] **EXVPN-E7-006** — Не пересобирать native-пакеты в CI при доказанных QA-only изменениях, сохранив все тесты. Зависимость: E7-001, E7-005. Критерий: консервативный selector отклоняет неизвестные изменения/ошибки Git, Android выполняет самостоятельные JVM tests без APK/JNI, фактический QA-only GitHub run проходит обе платформы без выгрузки native artifacts; product/PR/manual run остаётся полным.
  Доказательство 2026-10-17: [run 38991041038](https://github.com/Extectick/ExVPN/actions/runs/38991041038) на [8b24160](https://github.com/Extectick/ExVPN/commit/8b24160fd06dff2daff1651da20c769804cb1da6) прошёл обе платформы: Windows 374 с, Android 773 с. Actual selector и повторная проверка подтвердили QA-only; 6/6 exact cache HIT, 8 свежих JVM tests, 143-task graph, отсутствие native outputs и 0 uploaded artifacts. [Отчёт](evidence/ci-qa-only-build12.json). Полный +12 run также прошёл обе платформы: [cold-cache отчёт](evidence/ci-build12-cold-cache.json). Разные объёмы workflow не сравниваются как контролируемый benchmark.
  Дополнение 2026-10-17: 131 selector/graph/JUnit fixtures PASS; десять точных диагностических файлов добавлены в allowlist, соседние/смешанные изменения сохраняют полную сборку. Добавлены закреплённые CI-кеши архивов SDK, Go и Pub с обязательной повторной проверкой. [Правила](CI.md); исходники [dfaf4ad](https://github.com/Extectick/ExVPN/commit/dfaf4ad5fb83a0ae3d8606a2189187803e713042).
  Полная ветка 2026-10-17: [run 38982631039](https://github.com/Extectick/ExVPN/actions/runs/38982631039) на [2b9bd54](https://github.com/Extectick/ExVPN/commit/2b9bd5408edde6bf5cb14ad956ac077632558218) прошёл обе платформы; selector сохранил native-сборки для изменений CI. Windows — 595 с, Android — 1046 с. [Отчёт](evidence/ci-acceleration-build11.json). Этот run проверял полную ветку; QA-only подтверждена отдельно выше.
  Предварительная локальная проверка 2026-10-17: 92 selector/graph/JUnit fixtures PASS; точный Android helper в чистом source archive прошёл 8/8 за 43,13 с, SDK/dependency caches общие. Независимый review не оставил замечаний. [Доказательство](evidence/ci-build-impact-build11.json), [правила и docs-only граница](CI.md). Исходники [9d035ae](https://github.com/Extectick/ExVPN/commit/9d035aee717604dafa31e0b2818b3767bfac0efe). Этот локальный результат сам по себе не закрывал фактический GitHub QA-only gate.

- [x] **EXVPN-E7-005** — Ускорить локальную проверку и разделить разработку между агентами. Зависимость: E1 toolchain, E7-001. Критерий: одна команда выбирает тесты с учётом зависимостей, параллельно запускает готовые Dart/Flutter/Go runners, сохраняет результаты и не скрывает ошибки/изменения исходников; итоговый полный быстрый прогон проходит после завершения записи агентами. Системная приёмка остаётся отдельной.
  Последний Full, 2026-10-17: **11/11 за 241,75 с**, source fingerprint
  неизменен, Go result cache отключён. Сохранены прежние 17 script/host пар
  и добавлен Android selector suite; 61 focused check, replay и независимый
  review PASS. Windows и Android стендами управляли разные агенты; root
  выполнил Full после завершения записи исходников.
  [Отчёт](evidence/fast-validation-build17-selectors.json),
  [код 1884fae](https://github.com/Extectick/ExVPN/commit/1884fae804a17b8fe9fdf41eecaf9fd09332427d).
  Сетевые проверки +17 выше учитываются отдельно; полный E1 остаётся открытым.
  2026-10-17: Android observer и system-consent guards перенесены в общий
  QA helper. 192 focused checks PASS, read-only replay трёх настоящих +16
  dumps совпал с исходным результатом; продукт/эмулятор не изменялись.
  [Проверки](evidence/android-common-observers.json),
  [код](https://github.com/Extectick/ExVPN/commit/f3b7471224f797f82b5e54082a064d46b6a5d2e4).
  Дополнение +15, 2026-10-17: **11/11 за 121,65 с**, 493 Dart/Flutter-теста,
  Go result cache отключён; source fingerprint совпал. [Отчёт](evidence/fast-validation-shorebird-build15.json),
  исходники [30af3e6](https://github.com/Extectick/ExVPN/commit/30af3e6619e13e5b9ceeca9d540b578fa9ac8696).
  Это измерение полного прогона, не сравнение ускорения при одинаковой нагрузке.
  Дополнение 2026-10-17: измерены все 16 служебных наборов; CI fixtures вынесены
  в независимую очередь существующего runner. Итоговый Full после freeze —
  **11/11 за 82,03 с**, fingerprint совпал, Go result cache отключён. Прежние
  suite/host пары сохранены ровно один раз; 37 planner checks, 2048 комбинаций,
  отказы Android/CI и source drift прошли. Android, Windows и runner/review
  выполнялись разными владельцами. [Отчёт](evidence/fast-validation-ci-lane-build14.json),
  исходники [db17725](https://github.com/Extectick/ExVPN/commit/db177258de41ae050f131cb0a4c38689ba5e748e).
  Обе native CI lanes на 06a2689 также PASS: Windows 346 с, Android 722 с;
  development artifacts загружены. [Отчёт](evidence/ci-parallel-validation-build14.json).
  Предыдущий Full для +13, 2026-10-17: **115,59 с, 10/10 PASS**, source fingerprint совпал,
  Go result cache отключён. 448 Dart/Flutter tests, 52 Java UI-сценария,
  81 Android lifecycle, 129 metadata и 72 artifact audit fixtures PASS.
  Android runtime, dependency preparation и независимый review разделены между
  агентами; coordinator проверил общее дерево после freeze. [Отчёт](evidence/fast-validation-build13-instrumentation.json),
  исходники [541be0d](https://github.com/Extectick/ExVPN/commit/541be0d).
  Это длительность расширенного набора при отдельном Gradle inventory, не
  сравнительный коэффициент ускорения.
  Оптимизация очереди +13, 2026-10-17: **87,11 с, 10/10 PASS**, 448 Dart/Flutter
  tests, свежие Go checks и неизменные исходники. Долгие независимые наборы
  запускаются первыми; все 1024 подмножества сохраняют точный состав. Повторно
  подтверждены отказы при child error/source drift. 67 metadata fixtures PASS.
  [Отчёт](evidence/fast-validation-build13-scheduling.json),
  [исходники](https://github.com/Extectick/ExVPN/commit/2670357).
  Повтор +13 после исправления Sandbox staging, 2026-10-17: **127,43 с,
  10/10 PASS**, source fingerprint совпал, Go result cache отключён. 147 CI
  selector fixtures, 54 Windows subscription fixtures под PS7/PS5.1; реальные
  Android/Windows стенды выполнялись отдельными владельцами. Оба Windows QA
  bundle переупакованы за 17,416 с с проверкой неизменности бинарников.
  [Отчёт](evidence/fast-validation-build13-qa.json),
  [исходники](https://github.com/Extectick/ExVPN/commit/dce2942).
  Итог +13, 2026-10-17: **111,93 с, 10/10 PASS**, source fingerprint совпал,
  Go result cache отключён. 448 Dart/Flutter tests, Go/Xray, installer и
  инструментальные проверки прошли; 144 CI selector cases сохраняют полный
  gate для product/неизвестных путей. Windows, Android и dependency review
  разделены между агентами. [Отчёт](evidence/fast-validation-build13.json),
  исходники [03b5d6c](https://github.com/Extectick/ExVPN/commit/03b5d6c).
  Итог после CI/PCAP review, 2026-10-17: **106,66 с, 10/10 PASS**, source fingerprint совпал, Go result cache отключён. 131 CI selector/graph/JUnit fixtures, строгий TLV/extension parser и остальные наборы прошли. [Отчёт](evidence/fast-validation-build12-qa.json), исходники [ea9f2ca](https://github.com/Extectick/ExVPN/commit/ea9f2ca). Runtime шёл отдельно и не заменял эти тесты; длительность не выдаётся за контролируемый коэффициент ускорения.
  Прогон +12, 2026-10-17: **93,06 с, 10/10 PASS**, source fingerprint совпал, Go result cache отключён. [Отчёт](evidence/fast-validation-build12.json), product commit [402245f](https://github.com/Extectick/ExVPN/commit/402245f8e701610f8ef8bafc6eebe365d7c30940). Пакеты и системная приёмка проверяются отдельно.
  Предыдущий общий прогон, 2026-10-17: **89,93 с, 10/10 PASS**, source fingerprint совпал, Go result cache отключён. Новые Android DNS/PCAP и Windows teardown fixtures включены в локальный runner и CI; 31 planner check сохраняет обязательные тесты кода и пропускает только отчёты. Три агента разделили Android, Windows и read-only review; coordinator выполнил Full после source freeze. [Отчёт](evidence/fast-validation-build11-diagnostics.json), исходники [bbce9ea](https://github.com/Extectick/ExVPN/commit/bbce9eaf54e341b5a258e14cf72464b18d16284c). Runtime ограничения остаются отдельными; скорость разных наборов не сравнивается как контролируемый benchmark.
  Предыдущий общий прогон, 2026-10-17: **93,90 с, 10/10 PASS**, source fingerprint совпал, Go result cache отключён. Windows observer — 134 checks (включая реальный PS5.1), CI selector/graph/JUnit — 92 checks. Три агента независимо выполняли Windows runtime, CI/JVM реализацию и read-only review; root выполнил один общий Full после source freeze. [Отчёт](evidence/fast-validation-build11-acceleration.json). Проверенные исходники [9d035ae](https://github.com/Extectick/ExVPN/commit/9d035aee717604dafa31e0b2818b3767bfac0efe). Автоматизация воспроизводит незакрытый Windows runtime отказ, не скрывая его успешными unit tests.
  Итог QA +11, 2026-10-17: десять наборов прошли за **73,70 с**, fingerprint совпал, Go `-count=1`; Windows helpers — 78 проверок. Повторное использование Sandbox mapping и отдельные папки runId проверены; valid patch fixture исправлен для CRLF checkout без ослабления production validator. Review исправил запись диагностики вне разрешённого корня при неверном marker. [Full](evidence/fast-validation-build11-qa-final.json), [CRLF](evidence/xray-patch-crlf-build11.json), исходники [932cd0f](https://github.com/Extectick/ExVPN/commit/932cd0f04b4bc1e2ed0ae80a98f04d425b419eea).
  Дополнение +11, 2026-10-17: полный прогон десяти наборов прошёл за **70,74 с**, source fingerprint совпал; Go test-result cache отключён. Добавлены lifecycle/race проверки закреплённого Xray, 61 source-proxy fixture и 19 Android +51 Windows lifecycle helper checks. Координатор проверяет точное множество результатов и отклоняет ошибку child/source drift. Android и Windows runtime выделены разным агентам с отдельными стендами и процессами fixture. [Отчёт](evidence/fast-validation-build11.json); исходники [ad9b257](https://github.com/Extectick/ExVPN/commit/ad9b2579245b68b66bc2f9364b1d7cd5d8a8192f). Этот расширенный набор не является измерением ускорения прежнего набора +10.
  Доказательство 2026-10-17: три агента разделили native core tests/builds,
  Dart/state/Android QA и быстрый координатор; Windows проверял координатор.
  Финальный `-Full` всех девяти наборов прошёл за **29,08 с**, без Go test-result
  cache, fingerprint исходников совпал. 192 domain +46 state +31 updates
  +155 Flutter tests, Go verify/test/vet, installer fixtures, 26 planner,
  2 coordinator failure и 38 JVM QA checks прошли. Android QA ввод 10648 байт
  занял **836 мс**, readback совпал; другое приложение отклонено, файл удалён.
  [Методика](TESTING_WORKFLOW.md), [full report](evidence/fast-validation-build9.json),
  [Android input](evidence/android-fast-input-build9.json), исходники
  [24901d4](https://github.com/Extectick/ExVPN/commit/24901d4121b578ccc87cff590d1b9791e21085b4).
  Дополнение +10: итоговый `-Full` на [924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479) — **37,77 с**, девять наборов PASS, fresh Go tests, fingerprint совпал; добавлены 23+41+29 release-tooling fixtures и Windows lifetime/reconnect tests. [Отчёт](evidence/fast-validation-build10.json). Native Windows/Android QA и сборки выполнялись независимыми владельцами; docs-only push больше не отменяет native CI ([84489a2](https://github.com/Extectick/ExVPN/commit/84489a2)). Полная системная приёмка не сокращена.

- [x] **EXVPN-E7-001** — Настроить CI для анализа, тестов и Android/Windows сборок. Зависимость: E0 GitHub, E1 toolchain. Критерий: clean checkout проходит pipeline; secrets не включены в job output; версии и lock-файлы воспроизводимы.
  2026-10-17: после AAB inspector и full engine notices обе полные jobs
  [39027899156](https://github.com/Extectick/ExVPN/actions/runs/39027899156) прошли:
  Windows 501 с, Android 1018 с; development artifacts выгружены.
  [Отчёт](evidence/ci-release-inventory-build16.json),
  [код](https://github.com/Extectick/ExVPN/commit/7c5357baa9da66a1438d54b80f35d693dc1af7f4).
  Это ordinary Flutter CI; последующие QA/notices edits и Shorebird OTA
  требуют своих проверок.
  2026-10-17, +16: полный [run 39024609151](https://github.com/Extectick/ExVPN/actions/runs/39024609151)
  на [37b65b5](https://github.com/Extectick/ExVPN/commit/37b65b5085a6617c5a1996214fcdea3627b7c8e6)
  прошёл Android (17:19) и Windows (6:20), включая сборки и development artifacts.
  Исправлены выбор SDK и корневая ссылка hosted runner; оба прежних отказа
  сохранены. [Доказательства](evidence/ci-build16.json). Это не Shorebird OTA
  или системная VPN-приёмка; E1/E6/E7-002 остаются открытыми.
  CI +13, 2026-10-17: [run 38996842672](https://github.com/Extectick/ExVPN/actions/runs/38996842672)
  на `36c6094` — **SUCCESS**: Windows 11:45, Android 14:58, tests/build/upload.
  [Отчёт](evidence/ci-build13.json) сохраняет точный commit и digest двух
  development artifacts. Локальные пакеты проверены отдельно:
  [Android](evidence/android-packaging-build13.json),
  [Windows](evidence/windows-packaging-build13.json). Signing/release gate открыт.
  Прогресс: `.github/workflows/verify.yml`, `scripts/ci/verify.ps1`, `docs/CI.md`; workflow YAML и PowerShell синтаксис проверены, локальный общий прогон подтвердил 113 domain + 25 state + 86 app тестов и чистый анализ. Core tests/vet после новых protocol fixtures пройдены отдельно. Первый run 38878852742 выявил ошибку cold-start Flutter CLI, исправленную в f6cd4c4. Повторный [run 38880672529](https://github.com/Extectick/ExVPN/actions/runs/38880672529) на [f6cd4c4](https://github.com/Extectick/ExVPN/commit/f6cd4c4ed9f42f8ede0f1df772843f3724b6441e) полностью success: Android/Windows checks, builds и выгрузка development artifacts. Последующие изменения требуют собственного run; beta и системные испытания остаются открытыми.
  CI дополнение 2026-10-16: текущие QR/OTA/installer исправления прошли полный Android/Windows [run 38885825613](https://github.com/Extectick/ExVPN/actions/runs/38885825613) на [6fe2d3a](https://github.com/Extectick/ExVPN/commit/6fe2d3a288493b57ce9a7aa698a9df087f2fc50e). Это доказательство E7-001, не подпись или готовность beta.
  CI дополнение 2026-10-17: Android/Windows [run 38961456222](https://github.com/Extectick/ExVPN/actions/runs/38961456222) на [f2c5c5e](https://github.com/Extectick/ExVPN/commit/f2c5c5e795782adbded8b6e30817d58bf3b88a45) завершился success для +9. Последующие изменения release tooling и восстановления сети требуют собственного run.
  CI +10: [run 38969281066](https://github.com/Extectick/ExVPN/actions/runs/38969281066) на [924493a](https://github.com/Extectick/ExVPN/commit/924493a511547bb2b4c93262ab93df82fe127479) — **SUCCESS**, Windows 7:56, Android 14:50; tests/build/upload прошли. [Отчёт](evidence/ci-build10.json). Docs-only push не запустил дубликат и не отменил сборку. Это development artifacts, не подписанная beta.
  CI +11, 2026-10-17: [run 38979241913](https://github.com/Extectick/ExVPN/actions/runs/38979241913) на [292d3dc](https://github.com/Extectick/ExVPN/commit/292d3dc05f1b694a26ca9e2cb30953850e5b8373) — **SUCCESS**, Windows 9:11, Android 18:48; tests/build/upload прошли. [Отчёт](evidence/ci-build11.json). Это проверка данного commit; последующие QA/CI-изменения и системная приёмка имеют отдельные результаты.
- [ ] **EXVPN-E7-002** — Подготовить лицензии/SBOM, подпись и артефакты beta. Зависимости: E4–E6, доступ к ключам. Критерий: APK и Windows installer подписаны; полный комплект уведомлений соответствует бинарникам; исходники MPL доступны.
  2026-10-17: пользователь уточнил страну издателя — Казахстан, частный
  разработчик. [Варианты Authenticode](WINDOWS_SIGNING_OPTIONS.md) сравнивают
  Certum OSS/Standard, SSL.com IV/eSigner, SignPath и ограничения Microsoft.
  Покупок/заявок нет; выдача сертификата ещё не подтверждена.
  Затем пользователь отложил выбор платной подписи; Windows остаётся development.
  2026-10-17: collector получил обе собственные
  лицензии native updater с exact DEPS/Cargo.lock binding. По отчёту агента
  166 notice +72 audit +44 Android checks PASS; отдельные stdout этих прогонов
  не сохранены. Actual copy branch для обоих SDK сохранил два точных текста;
  root сверил 16 файлов исходников/доказательств. [Отчёт](evidence/shorebird-updater-own-notices.json).
  [Код 110a39b](https://github.com/Extectick/ExVPN/commit/110a39b1d155411a2382b8d40fe16028c0ed99d3).
  [Общий Full](evidence/fast-validation-updater-notices.json): 11/11 PASS
  за 160,59 с, source fingerprint неизменен, Go result cache выключен.
  Crate/Rust closure, переупаковка и E7-002 остаются открытыми.
  2026-10-17: отдельный collector проверил 282 точных crate-архива и собрал
  507 полных файлов уведомлений. Первый сбор: 80,389 с / 35,9 MB;
  повтор без сети: 15,809 с, inputs unchanged. 43 focused +166 existing
  checks PASS, root сверил 7 исходников и 2438 файлов доказательств.
  У 15 crates нет standalone license texts; nested/vendor coverage и Rust
  aggregate не подтверждены. Candidate не включён в production notices,
  release gate не менялся. [Отчёт](evidence/shorebird-updater-crate-notices.json).
  [Код 7cad456](https://github.com/Extectick/ExVPN/commit/7cad456).
  [Итоговый Full](evidence/fast-validation-release-preparation.json):
  11/11 PASS за 459,07 с, source unchanged, Go result cache выключен.
  Исследование exact source revisions подготовило 14 полных текстов для 11
  из 15 crates с отсутствующими notices; 94 файла независимо сверены root.
  Четыре crates и Rust aggregate остаются неразрешёнными; production collector
  не изменён. [Дополнения](evidence/shorebird-updater-source-supplements.json).
  2026-10-17: подготовлен [инструмент резервирования](SIGNING_BACKUP.md)
  Android/Shorebird ключей. Реальный backup и восстановление в другой
  Windows-идентичности ещё не выполнены; требование остаётся открытым.
  18 synthetic checks PASS, Java keytool подтвердил alias; независимое review
  закрыто после исправления повторного чтения при Restore.
  [Код ed5c656](https://github.com/Extectick/ExVPN/commit/ed5c656),
  [проверки](evidence/signing-backup-tool.json).
  2026-10-17: для updater закреплён source-lock inventory из 257 registry
  crates и 3 workspace nodes. Это исходный набор, не доказанная итоговая
  линковка; archive licenses ещё не проверены. Rust source marker во всех
  трёх engine совпал, но compiler/build provenance им не подтверждается.
  Root сверил 77 файлов, 0 расхождений.
  [Исследование и оставшиеся пробелы](evidence/shorebird-updater-source-inventory.json).
  2026-10-17: добавлен готовый offline AAB inspector — 52 GAV, 48 точных
  AAR/JAR совпадений, четыре записи без digest явно оставлены unbound;
  проверка заняла около трёх секунд, Gradle не запускался. Отдельно исправлена
  поставка полного engine LICENSE и проверены тексты NOTICES.Z в +16.
  Общий release gate остаётся открытым; данные AAB не перенесены на отдельно
  собранный APK. [AAB tool](evidence/android-aab-binding-tool-build16.json),
  [engine notices](evidence/flutter-engine-notices-build16.json).
  Код [7c5357b](https://github.com/Extectick/ExVPN/commit/7c5357baa9da66a1438d54b80f35d693dc1af7f4).
  [Full](evidence/fast-validation-release-inventory.json): 11/11 PASS за
  144,37 с, Go result cache выключен, исходники неизменны. Первый прогон
  с отказом теста дочернего процесса сохранён; production limits не ослаблены.
  2026-10-17: Android inventory получил явный selector закреплённого Shorebird
  release SDK; 157 + 106 focused checks PASS. Подготовка POM старой policy для
  Shorebird запрещена; граф и привязка APK/AAB пока не получены, E7-002 открыт.
  [Отчёт](evidence/android-inventory-shorebird-selector.json),
  [код 8908ca2](https://github.com/Extectick/ExVPN/commit/8908ca237124c7bdfca1f8661fa1ded077f5e7e8).
  Отдельное чтение неизменённого AAB +16: 52 Maven-записи и 48 digest,
  все 48 совпали с локальными AAR/JAR; четыре записи остаются без digest.
  Официальная схема AGP 9.1.0 и границы проверки подтверждены. Это ещё не
  полный inventory и не привязка отдельно собранного APK; E7-002 открыт.
  [Исследование](evidence/android-aab-dependency-metadata-build16.json).
  Дополнение 2026-10-17: `app.so` готового Windows +14 совпал с cached AOT output.
  733 сохранённых Flutter input hashes проверены реальным pinned-алгоритмом;
  для 896 входов исторических хешей нет. Это неполное доказательство build inputs,
  не runtime link graph; release blocker сохранён. [Отчёт](evidence/flutter-build-input-metadata-build14.json).
  Доказательства: [1fd0bd5](https://github.com/Extectick/ExVPN/commit/1fd0bd55b876a0251e803fc1123390546442568b).
  Дополнение 2026-10-17: явный prepared-input режим прошёл в новом private cache:
  77 POM, затем строгий offline граф из 68 Maven + 6 проектов / 279 связей совпал
  с закреплённым seed. Подготовка 19,837 с, offline 110,423 с, всего 148,158 с;
  129 fixtures и четыре Gradle guard-сценария PASS. Существующий dependency cache
  читается отдельно; это не холодный bootstrap, сборка APK или полный SBOM.
  [Отчёт](evidence/android-runtime-prepared-build13.json),
  исходники [541be0d](https://github.com/Extectick/ExVPN/commit/541be0d).
  Дополнение 2026-10-17: в готовом Windows EXE +13 независимо извлечены и сверены **265/265 payload-файлов**, обе maintenance-программы встроенного Uninstall.exe и шесть NSIS plugins/bitmap. Полный offline audit — **6,463 с**, 72 fixtures PASS. Установщик не исполнялся; снят только blocker проверки упакованных файлов, пять release blockers и системная приёмка остаются. [Отчёт](evidence/windows-nsis-build13.json); исходники [dfe753e](https://github.com/Extectick/ExVPN/commit/dfe753e2efc9ab9be7d4d830255332d3749b8196).
  Прогресс 2026-10-17: добавлен read-only аудит неизменяемых APK/Windows packages, проверка подписей, фактических native modules, hashes/notices и детерминированный CycloneDX 1.6 SBOM. 41 синтетический сценарий прошёл; четыре SBOM прошли официальную JSON schema. Проверка +9 закономерно блокирует выпуск: Windows unsigned, APK debug-signed, неполное покрытие лицензий; старый Windows notice inventory имел +1, Android bundle отсутствовал. Исправленный сборщик связывает version/lock/конкретные native inputs и прошёл 23 fixtures; отдельные sidecars не объявлены содержимым старых пакетов. [Отчёт](evidence/release-audit-build9.json), [методика](../scripts/release/ARTIFACT_AUDIT.md), [комплектация](RELEASE_NOTICES.md), исходники [dd7a221](https://github.com/Extectick/ExVPN/commit/dd7a2214a4894993698c7cc79083c4d50bcb455c). В +10 binding исправлен: [Android](evidence/android-packaging-build10.json), [Windows](evidence/windows-packaging-build10.json); release signing и полный SBOM/лицензионный gate остаются открытыми.
- [ ] **EXVPN-E7-003** — Выполнить общую матрицу приёмки. Зависимости: E7-001–002. Критерий: все заявленные протоколы, IPv4/IPv6/DNS, исключения, аварии, обновления и UI Android/Windows доказаны; отсутствующие устройства/серверы не помечены пройденными.
  Дополнение 2026-10-17, Android +10: обычное обновление +9 → +10 в API30 emulator сохранило три подписки и выбранный профиль после cold restart. Независимый UID подтвердил реальный XHTTP/REALITY HTTPS204/200 и другой IPv4; disconnect вернул исходный выход, настройки ОС не изменились. [Отчёт](evidence/android-upgrade-build10.json), [комплектация APK](evidence/android-packaging-build10.json), исходники [b8dd91d](https://github.com/Extectick/ExVPN/commit/b8dd91da531c09449f98e17bcc9cfa2d5f7444da). Активный VPN во время upgrade, физическое устройство и полная матрица остаются открытыми.
- [ ] **EXVPN-E7-004** — Опубликовать инструкции установки, настройки защиты, обновления и восстановления. Зависимость: E7-003. Критерий: пользователь может установить beta и понять фактическую защиту; известные ограничения перечислены; опубликованный release проверен скачиванием.

## E8 — Linux

- [ ] **EXVPN-E8-001** — Реализовать системный адаптер и packaging Linux. Зависимость: E7. Критерий: Flutter UI, служба, routes/DNS/защита и безопасное отключение на Ubuntu 22.04/24.04.
- [ ] **EXVPN-E8-002** — Проверить функции и жизненный цикл пакета на обеих Ubuntu. Зависимость: E8-001. Критерий: протоколы, IPv4/IPv6/DNS, исключения, reboot/upgrade/uninstall и UI подтверждены отдельно от Windows.

## E9 — iOS

- [ ] **EXVPN-E9-001** — Подготовить macOS/Xcode, идентификаторы, signing и Network Extension entitlement. Зависимость: E7 и Apple account. Критерий: воспроизводимая подписанная сборка устройства без приватных ключей в Git.
- [ ] **EXVPN-E9-002** — Реализовать Packet Tunnel и платформенные capabilities. Зависимость: E9-001. Критерий: реальный трафик и системный жизненный цикл проверены; не обещаются недоступные consumer per-app исключения.
- [ ] **EXVPN-E9-003** — Проверить OTA, UI и ограничения iOS; подготовить TestFlight. Зависимость: E9-002. Критерий: устройство, смена сети/фон/ошибки, требования магазина и подписанный TestFlight build; факт отправки не равен одобрению.

## Журнал доказательств

2026-10-17, частично **E1/E3/E5**, сборка **0.1.0+13/exvpn.4**: Windows upgrade
+12 → +13, E3 UI/DPAPI cold restore и девять transport циклов PASS.
После каждого Disconnect отсутствуют активные peer/client sockets, TUN/guard;
маршруты/DNS восстановлены. Финальная проверка installed files/binding/owner PASS.
[Отчёт](evidence/windows-lifecycle-build13.json),
[UI](evidence/windows-subscriptions-build13.json). E1, полная ресурсная матрица
и release signing остаются открытыми; [исходники ядра](https://github.com/Extectick/ExVPN/commit/0493c89),
[стенд](https://github.com/Extectick/ExVPN/commit/dce2942).

2026-10-17, частично **E1/E3/E4/E5**, сборка **0.1.0+9**: 30/32 профиля,
Android API30 upgrade/cold restart и настоящий XHTTP HTTPS с отдельным UID
подтверждены. Windows ordinary-user UI/SCM: два выбранных узла прошли сразу,
третий дал `tunnel_unreachable` и прошёл один отдельный повтор; обе попытки и
успешное восстановление сети сохранены. Четыре новых Encryption/Sudoku узла
по-прежнему не подтвердили внешний HTTPS. [Отчёт](evidence/provider-build9.json),
[границы](VLESS_ENCRYPTION.md), исходники
[f5901bc](https://github.com/Extectick/ExVPN/commit/f5901bc7d0b61d22f555bc760cbfcb5e3c85de81).

2026-10-17, частично **E1-004/005/007/009, E3-001–004, E4, E5**: сборка
**0.1.0+7**, новая настоящая подписка: 32 записи / 26 импортировано. Полный
core SOCKS-прогон 26 профилей дал HTTPS 204 у трёх XHTTP/REALITY. Все три затем
прошли Windows ordinary-user UI → SCM/TUN с другим внешним IPv4, HTTPS 200/204,
DNS, счётчиками и полным cleanup. На Android API30 emulator обычный APK сам
получил HWID-подписку; один профиль дал независимому UID HTTPS 200/204, другой
IPv4 и DNS. Cold start сохранил список; после disconnect прямой IPv4 восстановился.
IPv6 HTTPS не подтверждён, 23 принятых узла и шесть отклонённых остаются открытыми.
[Отчёт](PROVIDER_COMPATIBILITY.md), [JSON](evidence/provider-build7.json),
[Windows screenshot](evidence/windows-provider-build7.png).
155 app / 116 domain tests, Go tests/vet, release Windows/debug Android и обе JNI ABI
пройдены. Исходники: [f9313f3](https://github.com/Extectick/ExVPN/commit/f9313f31fe388f30f1c38d0f5837b86fc65b7f9b), QA: [8fa4b5d](https://github.com/Extectick/ExVPN/commit/8fa4b5dbb4545894e26617c91a5bba1bb284e9f2). Предыдущий CI `7db56df` завершился
успешно на Windows и Android; к новой сборке это подтверждение не переносится.

| Дата | Задачи | Результат | Commit / PR / артефакт |
|---|---|---|---|
| 2026-10-16 | E0-001–003 | Созданы план, архитектура, чеклист, правила, шаблон PR, лицензия и начальный реестр зависимостей. Реальный VPN не заявлен проверенным. | исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | E3-001; частично E3-003 | `dart analyze`: No issues found. `dart test`: 113 passed. Контракты/парсер/снимок без HTTP, secure storage или native VPN. | `packages/exvpn_domain`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | Частично E3-002 | `flutter test test/subscription_loader_test.dart`: 35 passed; targeted `dart analyze`: No issues found. MockClient, без загрузки реальной приватной подписки. | `apps/exvpn`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | Частично E2-005 | 15 widget-тестов UI пройдены по отчёту проверки; итоговые дополнительные проверки и визуальные доказательства ещё оформляются. Native VPN и системная защита не проверены. | `apps/exvpn/test/widget_test.dart`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | E2-005: свечение кнопки | Возвращены мягкое янтарное свечение и волна 640 мс без обрезки. 7 тестов кнопки пройдены, включая пиксели за всеми четырьмя краями и затухание; всего 57 тестов приложения. `flutter analyze` и release web build пройдены. В браузере проверена окружность на экране 426×922. Платформенная приёмка остаётся открытой. | `design/screenshots/mobile-glow.png`, `design/screenshots/power-glow.png`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | Частично E3-002–004 | Secure journal, Windows DPAPI round-trip/tamper/delete и Android cold start проверены. 6 refresh-тестов, 11 controller-тестов и 2 native UI-теста; анализ приложения чистый. Проверены устаревшие ответы, сериализация политик и сброс статистики. | `SECURE_STORAGE.md`, `apps/exvpn/test/`; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |
| 2026-10-16 | Частично E1-006–009, E4-001–002 | API36 emulator: независимый UID получил HTTPS204 с vpnTransport=true. После остановки synthetic VLESS-сервера защищённый UID не получил numeric HTTPS, исключённый UID получил HTTPS200 через тот же TUN. Это доказательство маршрутизации при обрыве сервера, не всех протоколов/аварий ядра/lockdown/физического устройства. | APK SHA256 `4357cc199b3dbef814295b0ae3d55cfaa81e5b969c40cedffb69f3096645e376`; подробный runtime-отчёт дополняется; исходники: [47a9847](https://github.com/Extectick/ExVPN/commit/47a9847cfeac19492c77b7bd3442cf06221a4bc7) |

Новые доказательства добавлять обезличенными. Полные приватные входные данные и журналы сохранять вне репозитория; в таблице достаточно результата, версии, платформы и безопасного идентификатора проверки.


## Цикл 0.1.6 — выпуск обновлённого интерфейса, 2026-10-19

- [x] **EXVPN-E3-010** — Автоматически применять поддерживаемую часть подписки
  без предупреждений о неподдерживаемых записях. Критерий: >=1 валидный профиль,
  только unsupportedProtocol/unsupportedFeature/ignoredLocalConfiguration;
  malformed/empty/network сохраняют рабочие данные. Метаданные атомарны,
  неизвестные local/security настройки не импортируются. Прогресс: 78 state
  tests PASS (13 новых), targeted analyze PASS. Проверено 2026-10-19: final
  Full **12/12 PASS за 126,78 с**, 373 app tests, source unchanged;
  [отчёт](evidence/fast-validation-v0.1.6.json).
  Исходники: [ae35c9a](https://github.com/Extectick/ExVPN/commit/ae35c9ae2bcff26dac6a0a37d743a446ba6e2d35).
- [x] **EXVPN-E7-012** — Опубликовать 0.1.6+27 в существующий канал обновлений.
  Критерий: один финальный Full на замороженных исходниках, подписанный Android,
  Windows package, immutable v0.1.6, обе platform jobs и оба подписанных feed,
  проверка публичных hashes/состава/версий. Без повторной сетевой VPN-матрицы:
  native core/служба/маршруты не менялись. Дублирующий development CI подавляется
  в release commit; manual release workflow сохраняет собственные проверки.
  Windows unsigned остаётся Preview, E1 и native camera не закрываются.
  Final Full 12/12 PASS; tag `v0.1.6` на `ae35c9a` создан.
  [Release workflow 39226424305](https://github.com/Extectick/ExVPN/actions/runs/39226424305)
  **SUCCESS**, обе сборки и публикация. Проверено 2026-10-19: все **15 assets**
  скачаны, GitHub digests/sizes и 14 checksum entries совпали; APK +27/min30/target36,
  прежний release signer, 47 fresh JVM tests, notices/SBOM/source bindings,
  Ed25519 Windows и Android beta feeds PASS. Source CI отдельно не запускался:
  проверки выполнены самим release workflow; локальные native builds не дублировались.
  [Релиз](https://github.com/Extectick/ExVPN/releases/tag/v0.1.6),
  [независимый аудит](evidence/release-v0.1.6.json). Установка/runtime в этом
  цикле не повторялись; stableReady=false, Windows unsigned.

## Цикл 0.1.5 — полные обновления, 2026-10-19

- [ ] **EXVPN-E6-008** — Исправить Windows handoff и подтвердить установленное
  обновление. Критерий: generated staging path проходит те же строгие проверки
  worker; неверный путь/ACL/hash не принимаются; pipe-handshake, отказ и реальный
  переход старого UI через UAC в новую версию подтверждены. Найдено на установленной
  0.1.3+24: правильный пакет 0.1.4+25 скачан, но staging 40 ошибочно сравнивался
  с 39. Prepare-only воспроизвёл отказ без commit/выхода/установки. Native
  regression tests и vet PASS. Установленный 0.1.5+26 check/restart подтверждён
  из обычного Explorer; полный автоматический package OTA остаётся открыт.
  Исходники: [c7e169a3](https://github.com/Extectick/ExVPN/commit/c7e169a3c483b2b4ac4f2ee0703ebd388c2857db).
  [Диагноз](evidence/windows-update-0.1.5-diagnosis.json).
  2026-10-20, 0.1.10+32: настоящий Dart-патч скачан/проверен и SDK next=1,
  но автоматический restart-ui вернул `handoff_failed` после secure staging.
  Ручной штатный cold launch подтвердил current=1/UI3 и последующий отзыв/UI2;
  это не закрывает автоматический handoff. [Область](evidence/independent32-scope.json).
- [x] **EXVPN-E6-010** — Восстановить установленный Windows-клиент и проверить
  настоящий helper restart отдельно от package OTA. Критерий: публичный installer
  совпадает с проверенными bytes/hash; old UI закрыт без force-kill; новая версия,
  service Running, helper check, accepted/old-exit/new-process подтверждены.
  Проверено 2026-10-19: 0.1.3+24 → публичный 0.1.5+26 через UAC; helper
  exit0/upToDate; Explorer-parent unelevated runner получил accepted, тот же
  detached worker запустил новый UI после выхода прежнего. Native source c7e169a3.
  [Установка](evidence/windows-bootstrap26-local.json),
  [restart](evidence/windows26-installed-restart.json). Прямой Codex CLI выявил
  MSIX AppData redirection; correct Explorer context подтверждён отдельно.
  Source/ACL/finalPath guards сохранены. Полный package OTA этим не закрыт.
- [ ] **EXVPN-E6-009** — Добавить Android полные APK updates. Критерий: отдельный
  подписанный feed, platform/domain/expiry/build/compatibility и HTTPS/size/hash
  проверки; private staging; native package/version/release signer PIN; явное
  разрешение источника и системная установка; отмена/повтор не блокируют UI.
  Требуется реальное обновление с сохранением данных в эмуляторе отдельно от
  unit-тестов; физическое устройство остаётся общей приёмкой. Предыдущие ordinary
  APK не имели full backend, нужен один ручной bootstrap. Реализация c7e169a3
  прошла Full и 47 JVM tests; signed APK/feed опубликованы. Реальное обновление
  из production feed в публичный +26 и сохранение данных подтверждены в E6-011.
  Отмена системного installer в runtime ещё не проверена; пункт остаётся открыт.
  [Сборка](evidence/android-candidate26-build.json), [доставка](evidence/release-v0.1.5.json).
- [x] **EXVPN-E6-011** — Подтвердить настоящий Android APK upgrade и сохранение
  данных отдельно от отмены установки. Критерий: production feed, реальная
  загрузка, разрешение источника и системный installer без подмены native guards;
  установленный публичный APK, UID и синтетические данные совпадают с ожидаемыми.
  Проверено 2026-10-19: API30, публичный 0.1.5+26, точный SHA-256, прежний UID,
  три группы, выбранное подключение и exclude/count1 сохранены. Native idle и
  отсутствие ошибки подтверждены. Исходники c7e169a3; закрытый QA baseline
  72c34b56 меняет только два файла версии на 0.1.4+25 и не является старым
  публичным +25. [Отчёт](evidence/android-updater26-runtime.json).
  Отмена installer и физический телефон этим пунктом не закрываются.
- [ ] **EXVPN-E7-010** — Выпустить 0.1.5+26 Preview с исправленным updater.
  Критерий: Full после заморозки исходников, Android/Windows сборки, runtime gates,
  новый immutable tag, обе CI платформы, опубликованные файлы и оба подписанных
  feed проверены скачиванием. Windows Authenticode и E1 не закрываются этим выпуском.
  2026-10-19: Full 12/12 PASS, 366 app tests, 216,79 с, source unchanged;
  [отчёт](evidence/fast-validation-v0.1.5.json). Native сборки, immutable tag
  v0.1.5 на c7e169a3 и публичная доставка проверены. Windows bootstrap/restart
  и Android upgrade подтверждены в E6-010/011; полный Windows package OTA и
  runtime-отмена Android installer остаются открытыми.
- [x] **EXVPN-E7-011** — Проверить публичную доставку 0.1.5+26 отдельно от установки.
  Критерий: обе CI-платформы, source/tag, все файлы и checksums, APK signer,
  notices/SBOM и оба Ed25519 feed соответствуют фактическим пакетам. Проверено
  2026-10-19: source CI39210164029 и release CI39210171570 PASS; 15 assets,
  14 checksum entries, 226 notice-файлов, APK SDK30/36, 47 JVM tests, подпись
  Android и оба domain-separated feed PASS. Windows unsigned, Preview.
  Исходники: c7e169a3. [Доказательство](evidence/release-v0.1.5.json).
  Установленный handoff, настоящий Android upgrade и E1 сюда не входят.

## Цикл 0.1.4 — подписки и разрешения, 2026-10-18

- [x] **EXVPN-E2-017** — Компактное дерево подписок и ясное состояние ошибки.
  Критерий: выбранный пользователем эталон, отступ24, простые ветки без точек,
  collapse/selection/minimal picker, локальная ошибка без полосы повтора,
  красная кнопка blocked/error без автоматического снятия защиты. Проверено
  2026-10-18: 7 focused tree/error tests, отдельный pixel/gesture test красной
  кнопки и браузерный просмотр dark/light/large/minimal. У ошибки refresh не
  меняется положение серверной строки. [Сверка](../design-qa.md),
  [снимок](../design/screenshots/subscription-tree-large-dark-final.png).
  Исходники: [6d2e947](https://github.com/Extectick/ExVPN/commit/6d2e947699b5b6f347dd07bb6f7ba246ca2ad8d4). Native визуальная приёмка отдельно.
  Финальный Full: 12/12, 333 app tests, 293,54 с, source unchanged;
  [отчёт](evidence/fast-validation-v0.1.4.json).
- [x] **EXVPN-E3-009** — Необязательное название и метаданные провайдера.
  Критерий: HTTP/base64/body/filename, ручной override, безопасный fallback,
  atomic partial update, последний рабочий список/имя и миграция snapshot.
  Проверено 2026-10-18: 65 client-state tests, app metadata/loader/refresh/store
  tests и независимый read-only review. Snapshot v2 читает v1, обратное понижение
  не поддерживается. [Контракт](ARCHITECTURE.md). Исходники:
  [6d2e947](https://github.com/Extectick/ExVPN/commit/6d2e947699b5b6f347dd07bb6f7ba246ca2ad8d4).
- [ ] **EXVPN-E4-006** — Android consent и launcher icon. Критерий: новый подписанный
  APK, fresh grant/deny/back/retry/already-granted без застревания, launcher белка,
  отключение/cleanup и отсутствие ложного connected на отказавшем сервере.
  Прогресс 2026-10-18: 20 isolated JVM tests и aapt2 compile/link PASS.
  API33 notification/themed icon и физический телефон остаются отдельной проверкой.
  На сохранённом APK source6d2e947 подтверждены настоящий первый диалог,
  отсутствие службы до согласия и красное состояние отказа. Найден UX blocker:
  после отказа предлагался Disconnect вместо прямого retry. Исправлен нативный
  авторитетный idle-контракт, при существующем/неизвестном владельце guard
  сохраняется. 20 isolated JVM и повторный Full 12/12, 335 app tests PASS.
  [Исходное наблюдение](evidence/android-candidate25-runtime-partial.json),
  [Full](evidence/fast-validation-v0.1.4-retry.json).
  Исправленный подписанный APK [576a392](https://github.com/Extectick/ExVPN/commit/576a39244c77259b6ff91312cadf988d6f1471eb)
  прошёл 40 JVM tests и реальную API30 проверку: deny → немедленный retry без
  Disconnect → системный диалог → grant → native connecting; already-granted
  не показывает запрос. Проверены белка в launcher, красный retry, отключение
  и cleanup. [Runtime](evidence/android-candidate25-runtime.json),
  [build](evidence/android-candidate25-build.json),
  [иконка](evidence/android-launcher25.png), [отказ](evidence/android-consent25-red-retry.png).
  Back на исходном API30 диалоге не закрывал окно ОС; patched Back и поздний
  callback не воспроизведены runtime, поэтому полный критерий остаётся открытым.
- [x] **EXVPN-E2-018** — Закрытие нижних окон за содержимое. Критерий: reusable scope,
  short/long list, scroll-before-dismiss, малый/отменённый жест, fling, wheel и
  однократное закрытие проверены, затем реальный Android жест в Settings.
  Проверено 2026-10-18: integration widget test настоящего SettingsSheet,
  analyzer и 13 focused gesture tests PASS.
  На первом APK медленный и быстрый жесты за содержимое не закрывали Settings.
  Найдена регрессия unknown input в touch-only guard; добавлены contact kinds
  и порог30% для доступного жеста из центра. 13 focused tests, затем Full12/12,
  340 app tests за94,63 с PASS. [Full](evidence/fast-validation-v0.1.4-gestures.json).
  Повторный подписанный APK source
  [576a392](https://github.com/Extectick/ExVPN/commit/576a39244c77259b6ff91312cadf988d6f1471eb)
  прошёл API30: короткое движение оставляет окно, медленный жест из центра
  на 332 dp за 2 с и быстрый жест закрывают; scrolled list сначала прокручивается,
  положение ручки неизменно. [Runtime](evidence/android-candidate25-runtime.json),
  [во время жеста](evidence/android-modal25-mid-pull.png),
  [после закрытия](evidence/android-modal25-dismissed.png).
  Отдельно скачанный публичный APK e8b1f2f5 установлен с совпадением base.apk hash:
  запуск и один медленный жест из центра также PASS.
  [Публичный APK](evidence/android-published-v0.1.4-smoke.json),
  [кадр жеста](evidence/android-published-v0.1.4-center-mid.png).
  Проверка выполнена через ADB, без Computer Use. Физическое касание на телефоне
  остаётся общей приёмкой устройства, не подтверждено эмулятором.
- [x] **EXVPN-E7-009** — Выпуск 0.1.4 Preview Android/Windows. Критерий: финальный Full,
  чистый source commit, новый неизменяемый tag, обе CI-платформы, прежняя APK
  подпись, скачанные assets/hash и подписанный beta feed. Проверено 2026-10-18:
  опубликован 0.1.4+25 Preview. E1/общая стабильность этим не закрываются.
  Финальный Full 12/12 PASS; подписанный native build с 40 JVM tests и scoped runtime
  прошли. Новый tag v0.1.4 закреплён на
  [576a392](https://github.com/Extectick/ExVPN/commit/576a39244c77259b6ff91312cadf988d6f1471eb);
  source CI39145319784 и release CI39145366138 прошли на обеих платформах.
  Все 15 файлов скачаны: 14 checksum entries, 13 manifest records, notices/SBOM,
  фактическая v2-подпись APK и 40 JVM tests, Windows Ed25519 beta feed и привязка
  установщика подтверждены. [Аудит](evidence/release-v0.1.4.json),
  [скачать](https://github.com/Extectick/ExVPN/releases/tag/v0.1.4).
  Исходный неуспешный runtime сохранён отдельно. Windows остаётся без Authenticode;
  опубликованные ограничения лицензий/runtime inventory не сняты.
  Дополнительный smoke публичного APK прошёл на API30: установленный хеш,
  запуск и закрытие Settings из центра; без повторения сетевой матрицы.
  [Протокол](evidence/android-published-v0.1.4-smoke.json).
  Первая попытка Android packaging остановлена на ложной case-insensitive
  коллизии `res/zR.png`/`res/zr.png`; та попытка не была опубликована. Исправлен только
  явный APK-mode verifier. 90 audit/47 notice fixtures и повторный Full 12/12
  за 136,33 с PASS. [Отчёт](evidence/fast-validation-v0.1.4-packaging.json),
  [сохранённая неуспешная попытка](evidence/android-candidate25-build-attempt.json).

## Цикл 0.1.3 — настройки, маршрутизация и доставка, 2026-10-18

- [x] **EXVPN-E2-016** — Компактные настройки и выбор приложений. Критерий:
  скруглённый hover, три режима, закреплённый поиск в 400×440, подтверждение очистки,
  ленивые иконки и пользовательский текст обновлений проверены поведенчески и
  в работающем интерфейсе. Проверено 2026-10-18: 52 профильных UI-теста,
  400×440 и browser preview, затем настоящий API30 Android с нативными иконками,
  поиском и подтверждением очистки. [Hover preview](evidence/settings-hover-preview-routing.png),
  [Android +24](evidence/android-routing24-app-icons.png). UI-исходники:
  [5da3ea7](https://github.com/Extectick/ExVPN/commit/5da3ea7511eb2bfdb82557648560adf470a09d8b).
  Финальный Full 12/12, 308 app tests, 100,72 с; новый native runtime учитывается отдельно.
- [ ] **EXVPN-E4-005** — Три режима Android с подтверждённым UID и замена сервера
  без закрытия TUN. Критерий: unit/JVM и два независимых UID в emulator показывают
  правильный маршрут и отказ защищённого трафика при outage; сохранение выбора и
  отмена устаревшей цели подтверждены. Физическое устройство остаётся отдельным
  E4/E7 gate. Прогресс 2026-10-18: disabled/exclude прошли на двух UID;
  include выявил legacy owner boundary, поэтому публикация 0.1.2 отменена.
  Исправлены известные невыбранные UID и appId рабочего профиля; 12 focused JVM
  tests PASS; подписанный APK +24 прошёл все 20 JVM tests.
  APK24: include — выбранный UID через VPN, невыбранный напрямую; остановка
  fixture блокирует только защищаемый UID; exclude pair и четыре восстановления
  direct HTTPS200 прошли. [Runtime](evidence/android-routing24-runtime.json),
  [версии](evidence/android-routing24-versions.png). Живая замена сервера/отмена
  и удержание TUN при ней этим прогоном не приняты, поэтому пункт остаётся открытым.
  Исходники:
  [3d4e363](https://github.com/Extectick/ExVPN/commit/3d4e363fc8d6a75d2006f7e043585589005f68c8).
- [ ] **EXVPN-E5-009** — Windows modes/family anchors и смена цели при подключении.
  Критерий: mode/persistence/strict IPC/unknown-owner/family-negative tests и
  изолированная матрица реального HTTPS с отключением fixture и восстановлением
  исходной сети проходят. Обычный установленный SCM/IPC и полная E1 приёмка не
  подменяются controller harness. Прогресс 2026-10-18: unit/loopback/race,
  сборка Windows и CI прошли. Sandbox не получил устойчивый HTTPS ещё до TUN;
  матрица остаётся открытой. [Отчёт](evidence/windows-routing23-runtime-blocker.json).
  Исходники: [8d8ceee](https://github.com/Extectick/ExVPN/commit/8d8ceee235066a7f7cdae3fe0c4f0684388a1839).
- [x] **EXVPN-E7-008** — Опубликовать проверенные 0.1.3 Preview Android/Windows и
  подписанный Windows beta feed через GitHub workflow. Критерий: исходники/новый
  тег неизменяемы, CI прошёл, APK подписан прежним ключом, все опубликованные
  bytes/hash/notices проверены скачиванием, feed Ed25519 совпадает с доверенным
  ключом и новым установщиком. Выполнено 2026-10-18: оба workflow и обе платформы
  PASS, все 15 GitHub assets и 14 SHA256SUMS entries проверены скачиванием,
  APK release-signed, Ed25519 feed совпадает с установщиком. Установленная +21
  вернула available → ready для +24; handoff/установка/перезапуск не запускались.
  [Выпуск](https://github.com/Extectick/ExVPN/releases/tag/v0.1.3),
  [CI](evidence/ci-v0.1.3.json), [bytes/feed](evidence/release-v0.1.3.json),
  [installed updater](evidence/installed-updater-v0.1.3.json).
  Скачанный публичный APK независимо проверен apksigner/aapt2, установлен через
  install-r; установленный хеш совпал, запуск/версии/сохранение политики PASS,
  новых crash markers и активного VPN нет.
  [Published APK smoke](evidence/android-published-v0.1.3-smoke.json).
  Тег `v0.1.3` закреплён на
  [3d4e363](https://github.com/Extectick/ExVPN/commit/3d4e363fc8d6a75d2006f7e043585589005f68c8);
  v0.1.1/v0.1.2 не менялись. Windows unsigned остаётся prerelease, E1/E4/E5/E6/E7
  общие критерии стабильности этим пунктом не закрыты.

## Автоматический перезапуск OTA, 0.1.11+33 — 2026-10-20

- [x] **EXVPN-E6-018** — Автоматически применить и отозвать подписанный Dart/AOT
  на Windows и Android с настоящей сменой VM без ручного cold restart. Критерий:
  разрешённый native handoff, новый процесс, правильный current/next и UI revision,
  неизменные база и пользовательские данные; активная VPN-служба Windows не
  затронута, Android ждёт безопасного idle. Проверено 2026-10-20: одна новая
  native-база обеих платформ, 456 app и 66 JVM tests PASS; настоящий подписанный
  патч и отзыв каталогов 7/8 сами заменили процессы: UI 4→5→4, current 0→1→0.
  Android API30 emulator: APK/UID/3 файла данных сохранены; Windows Sandbox:
  6 fingerprints и служба/PID сохранены. Ручного cold restart и правок SDK-кэша
  не было. [Контракт](OTA_RESTART.md), [runtime](evidence/independent33-runtime.json),
  [автоматический цикл](evidence/independent33-auto-restart.json).
  Исходники: [c566866](https://github.com/Extectick/ExVPN/commit/c5668668da0dd48628cd060b0abd5795e44ddde4).
  Публикация выполнена отдельным шагом без пересборки:
  [0.1.11+33 Preview](https://github.com/Extectick/ExVPN/releases/tag/v0.1.11),
  неизменяемый tag `v0.1.11` на `c566866`. Независимый
  [аудит публичных файлов](evidence/independent33-public-download-audit.json)
  подтвердил точные принятые APK/EXE, 20 assets/19 checksums, подписи Android и
  обоих full-update feeds, каталог 8 и обе capsules. Проверочный патч №1 отозван.
  Физический Android, Authenticode и E1 этим пунктом не закрываются. UI-меню
  подписок и автопинг сохранены для отдельного следующего патча №2, не включены
  в опубликованные APK/EXE.
