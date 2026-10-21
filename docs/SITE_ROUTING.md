# Сайты, IP и локальные пресеты

Поручение 2026-10-21: отдельный пункт настроек «Сайты и IP», аналогичный
маршрутизации приложений. Пользователь выбрал для России **VPN только для
выбранных сайтов**, остальные распознанные адреса напрямую. Это самостоятельная
локальная политика, подписка не может её изменить.

## Поведение

- «Выключено» сохраняет список, но не применяет его.
- «Исключения» направляет указанные домены/IP напрямую, остальное через VPN.
- «Только эти» направляет указанные адреса через VPN, остальные подтверждённые
  соединения напрямую. Неизвестный владелец или нераспознанный домен остаётся VPN;
  отсутствие SNI/ECH не является разрешением на direct.
- Домен включает поддомены. Поддерживаются IPv4, IPv6 и CIDR. Поле добавления
  также принимает HTTP(S) URL и нормализует его до домена. Произвольные схемы,
  regex, geosite, конфигурации провайдера и URL с credentials не принимаются.
  Международные домены вводятся в Punycode.
- Явное включение в VPN в любой из двух политик (приложения/сайты) приоритетнее
  прямого исключения другой политики. Неизвестный/system/shared Android UID не
  получает direct. DNS остаётся через VPN, без скрытого fallback.
- HTTP/TLS/QUIC sniffing применяется только для маршрутизации (`routeOnly`), не
  меняет исходный IP назначения или tuple проверки владельца. Прямой UDP-поток
  сохраняет исходный IP:порт и подтверждённого владельца; изменение закрывает
  association. Пользовательский трафик в логи не записывается.
- Правила меняются при отключённом соединении. Windows PROXY явно отказывает
  при активной политике сайтов; настройки предназначены для VPN/TUN.

Вход в форму показывает российский стартовый набор как черновик. Он применяется
только после «Сохранить». В существующей установке правила сами не включаются.
Поиск/режим/добавление закреплены сверху, прокручивается только список.
Сохранение своего пресета изменяет библиотеку отдельно от применённой политики.

## Пресеты и источники

Ревизия **2026-10-21**: «Россия · основные сервисы», «Видео», «Мессенджеры»,
«Соцсети», «ИИ-сервисы». Основной набор объединяет остальные. Это редактируемый
стартовый список популярных сервисов, не полный и не автоматически обновляемый
реестр блокировок; доступность зависит от провайдера и региона.

Для исследования сопоставлены [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains)
и [RunetFreedom](https://github.com/runetfreedom/russia-v2ray-rules-dat).
Их конфигурации и DAT-файлы не включены в приложение. Выбранные сервисные домены
адаптированы из MIT
[v2fly/domain-list-community](https://github.com/v2fly/domain-list-community/tree/497bef95124ac98a70ed865bb8aaaa8e9a4ff66e),
строго commit `497bef95124ac98a70ed865bb8aaaa8e9a4ff66e`.
Сети Telegram сверены с [официальным списком](https://core.telegram.org/resources/cidr.txt)
2026-10-21. MIT-текст сохранён в assets, Flutter LicenseRegistry и release
collector; SHA-256 `b9d84a22870d3f21c91a4c6e410c9cc51d00902f5233ad0c84011479244bf7d2`.
Внешние списки или маршруты не скачиваются в фоне.

## Контракт и хранение

Schema1: `{schema, policy:{mode,rules}, savedPresets:[{id,name,policy}], selectedPreset}`.
Закрытые exact-case ключи, обязательные типы/поля, уникальные канонические правила,
до1024 правил в политике,8 своих пресетов,2048 правил суммарно и512KiB JSON
с Go-compatible HTML escaping. ID: `[a-z0-9][a-z0-9._-]{0,63}`, имя до80 Unicode
scalar values без control/format/bidi. Windows IPC и persisted envelope используют
одинаковый strict core decoder. Ошибка чтения или неизвестный durable outcome
записи не разрешает подключение со старой либо сброшенной политикой.

Windows: отдельное DPAPI-хранилище с owner/purpose binding и initialized marker,
сохранение до подтверждения UI; snapshot на connect/reconnect/failover.
Android: отдельный encrypted record/Keystore alias, invalidated cache перед I/O,
captured resume schema4 с проверкой текущей durable policy; старые schema1–3
мигрируют только через validated state. `startRouted` и capability schema исключают
молчаливое игнорирование политики старой `.so`.

## Проверки и оставшиеся гейты

Focused Go/core/Windows/Android, Dart model, widget/controller/channel tests и
standalone Kotlin policy/owner/recovery выполнены. Host typecheck25 production
Kotlin файлов API36 выполнен с `R.drawable` stub; это не APK/JNI-проверка.
Веб-дизайн использует синтетические данные и отдельный design bridge.
Исходники `ed56b07` поверх protocol-кандидата `2d0d4a0`. Полный запуск дал
11/12 PASS за121,08с с неизменными исходниками и491 app tests; scripts остановился
на Git -C path limit в глубоком временном каталоге. Только этот fixture выполнен
по короткому SUBST-пути к тем же файлам (61 PASS); оставшиеся12 script suites
успешно завершены по исходному пути. Короткий alias удалён. Это составная проверка,
не единый Full12/12; [отчёт](evidence/site-routing-validation.json) сохраняет и
исходный отказ. Светлый/тёмный минимальный и Arabic RTL preview проверены без
overflow/ошибок console. Настоящая VPN-сеть в этом цикле не менялась.
После этого исправлена только навигация прямого URL design preview: под формой
сохраняется домашний экран, «Сохранить»/«Назад» возвращают на него. Этот отдельный
preview-only шаг проверен analyzer и живым браузером, без повторения продуктовых
тестов и native-сборок; production UI/native не менялись. Изображения обновлены.

Перед выпуском нужны Windows C++/native package и Android JNI/APK, реальное
encrypted persistence/restore и TUN-матрица домен/IP/CIDR/IPv4/IPv6/DNS, ECH/unknown
owner, конфликт app/site и UDP reassociation в изолированном стенде. Физическая
Android-приёмка не заменяется host tests. E1 остаётся открытым.
Изменены native API и asset: нужен **новый полный Shorebird base**, Dart-only patch
поверх старой базы не поддерживает эту функцию. Версия/тег/публикация данным
изменением не назначаются.

Интеграция 2026-10-21 после освобождения общего каталога: main `d504ba2` принял
`33e9166`, `514b7be`, `c24a259`. Все47 исходников функции совпали с проверенной
изолированной веткой; чужие protocol/QA/release записи сохранены. Preview передан
в `V:\GitProjects\ExVPN\artifacts\site-routing-preview-c24a259`, HTTP8128 отвечает200.
Опубликованный `v0.1.14` по-прежнему указывает на `e5c9db2`: функция сайтов в
пакеты36 не попала. Новых native сборок, системной установки или повторной
сетевой приёмки при переносе не было.

2026-10-21 по следующему поручению пользователя опубликован Preview **0.1.15+37**
из `0d8c001`: JNI arm64/x64, Windows service/C++ UI и пакеты собраны по одному разу.
Один новый итоговый Full12/12 PASS, actual Android JVM74 PASS; оба подписанных
package feed предлагают37, OTA-каталог revision12. Это завершает упаковку функции,
но не открытые runtime-критерии **EXVPN-E1-014**: TUN/IPv4/IPv6/DNS/owner/UDP,
реальное encrypted restore и физический Android. Полный E1/stable не закрыт.
[Квитанция выпуска](evidence/release-v0.1.15.json).

## Реальный TUN — 2026-10-21

Без Computer Use и повторной сборки базы37 выполнены отдельные Android/Windows
матрицы. Android API36: сохранение политики через production UI, реальный TUN и
отдельный UID сетевого probe; exclude/include домена и IPv4/CIDR, IPv6 через VPN
и по прямому исключению, отказ сервера без direct fallback у защищённых запросов.
Сохранённая encrypted policy восстановлена после idle process restart. Это
положительный roundtrip, не destructive recovery или физический телефон.

Windows Sandbox: production controller, WFP и TUN с memory policy fixture,
independent default-network HTTPS и различающимся хешем remote exit. Прошли
доменные и IPv4 правила обоих режимов, IPv6 CIDR include, fresh DNS A/AAAA и
потеря сервера. Физические counters53/853 равны0 в connected/outage, отдельная
калибровка положительна. Это counters, не payload capture. Прямого IPv6 у underlay
нет; успешное прямое IPv6 исключение здесь не принято. Installed SCM IPC/DPAPI
и runtime unknown/shared owner этим harness не проверяются. После тестов
служба и хеши маршрутов/DNS восстановлены, TUN/guard/QA processes сняты.

Матрица выявила ошибку pinned `.5`: TLS ClientHello с ECH до или после outer SNI
в доменном include получал прямой маршрут. Положительный ordinary SNI control
дал5 исходящих физических пакетов, оба ECH тоже5, missing-SNI control0.
В закреплённом `.6` полный ClientHello разбирается до публикации домена; ECH,
GREASE, duplicate SNI и malformed tail оставляют его unknown. Два новых тестовых
файла проверяют TLS и защищённый QUIC Initial:27 подслучаев PASS за4,14с.
Старый lifecycle patch сохранён побайтно, upstream/dependencies не менялись.
Повторён только Windows ECH subset: ordinary SNI5 исходящих, ECH до/после0,
missing-SNI0. В одном окне был1 запоздавший входящий пакет; нулевой считается
именно исходящий target traffic. Криптографическая ECH negotiation не принята.

Первый Android startup PCAP не показал положительные DNS/TCP controls; исходный
capture и INDETERMINATE сохранены. Новый guest tcpdump захватывает одновременно
eth0/wlan0, ждёт готовности, подтверждает прямые контроли до/после и границы часов.
DNS37 принят только в наблюдаемом активном TUN-окне39,678с: физические запросы53=0,
контрольные DNS видны на wlan0, VPN transport виден на eth0. В расширенном окне
есть два ответа до старта; startup/shutdown DNS не принят. ECH bypass `.5`
подтверждён на обеих платформах, а не только host parser tests.

Опубликован ровно один новый APK и EXE **0.1.16+38**, source `f7d7ce6`, UI11;
старые пакеты/тег37 не менялись. После freeze один Full12/12 PASS за204,96с,
Android JVM74 PASS. Exact38 APK установлен-r: SHA/ZIP native entry совпали,
UID и политика сохранились. Actual TUN ECH before/after/no-SNI дали0 физических
target packets на обеих NIC; ordinary SNI сохранил direct с положительным exact
fixture control. Numeric HTTPS через VPN до/после прошёл, стенд очищен.
Это synthetic routing proof, не криптографическая ECH negotiation.

Подписанные package feeds предлагают38, OTA-каталог revision13 сохраняет базы
и отзывы. TUN-проверка не заменяет подписанный OTA apply/rollback roundtrip.
Общий E1/EXVPN-E1-014, физические устройства, Windows SCM/DPAPI и direct IPv6,
unknown/shared owner, app/site conflict, UDP reassociation и destructive recovery
остаются открытыми. ECH fix: `e553400`; source base: `f7d7ce6`.
[Квитанция выпуска](evidence/release-v0.1.16.json).
[Обезличенный отчёт](evidence/site-routing-tun-20261021.json).
