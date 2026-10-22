# Совместимость параметров подписки — 2026-10-22

Исходники: `d07968c98ed3e4ca95ac403d8ab379989ab14922`, задача **EXVPN-E3-016**.
Приватная подписка дала 36 записей: 34 VLESS/REALITY/Vision TCP и две Hysteria2.
Форматы уже были реализованы, но строгий импорт отвергал явный TCP `headerType=none`
и Hysteria2 `fm.quicParams`. До изменения: 0 профилей/36 неподдержанных;
после: **36 профилей/0 замечаний**, native Compile36/36.
URL, адреса серверов, ключи и исходные записи не входят в Git или отчёт.

## Импорт и нативный контракт

- `headerType=none` принимается только для TCP/raw и канонизируется в прежний
  профиль без заголовка. Другие значения, конфликты и повторные параметры
  отвергаются; HTTP-маскировка не удаляется молча.
- Hysteria2 URI и Xray JSON принимают один `quicParams` через закрытый
  `QuicOptions`. Передаются congestion `bbr`/`reno`, начальные/максимальные
  receive windows, idle timeout и keepalive. Значения и сочетания проверяются
  отдельно в Dart, сохранённом snapshot и Go.
- Stream windows: 16KiB–16MiB; connection windows: 16KiB–64MiB; idle timeout:
  4–120с; keepalive: 2–60с и меньше idle. Ноль сохраняет default ядра;
  initial не превышает max, stream max не превышает connection max.
- Нейтральный `debug=false` потребляется при импорте. `debug=true`, неизвестные
  поля, произвольные TCP/UDP masks, логирование, файлы, маршруты, DNS, listeners
  и TLS bypass не входят в нормализованный контракт. `brutal` без отдельно
  реализованных rate-параметров не принимается.
- Существующие TLS/SNI/REALITY keys и Vision flow сохраняются. Проверка
  исходных и нормализованных значений всех 36 записей не выявила расхождений.

Официальный формат: [Xray FinalMask](https://xtls.github.io/en/config/transports/finalmask.html).
Проверены исходники именно закреплённого `v1.260327.1-exvpn.6`; SDK, зависимости,
`go.mod`/`go.sum` и patch lock не менялись.

## REALITY и браузерный отпечаток edge

У всех 34 VLESS-записей задан `fp=edge`. В закреплённом uTLS этот alias означает
устаревший **Edge85**. Добавленный локальный тест воспроизвёл отказ HTTPS как с
обычным short ID, так и с пустым; прежний Chrome/REALITY проходил.

В компиляторе ExVPN только **REALITY + edge** получает современный Chromium
ClientHello через закреплённый `chrome` alias. Исходный fingerprint `edge`
остаётся в сохранённом профиле, а эффективный wire fingerprint отличается.
Это явное правило совместимости, а не повтор после отказа или отключение TLS.
Обычный TLS с `edge` сохраняет прежнее значение. SNI, public key, short ID,
spiderX и проверка REALITY не меняются; неверный ключ по-прежнему блокируется.
Адаптер нужно пересмотреть при смене закреплённого uTLS.

Справка: [Xray TLS fingerprints](https://xtls.github.io/en/config/transports/tls.html),
[закреплённый uTLS](https://github.com/refraction-networking/utls/blob/aa6edf4b11af/u_common.go).

## Проверка и ограничения

- Пять новых domain tests и две state-регрессии: URI/Base64/Xray JSON,
  канонический ID, сохранение/восстановление, ошибки типов/границ и отказ
  произвольных provider fields. Итоговые domain244/state94 PASS.
- Локальный HTTPS через Hysteria2 с двумя вариантами QUIC tuning: по три
  Close/recreate цикла, независимый destination hit, отказ при неверном SNI.
  REALITY: standard/Vision и два Edge/Vision случая, включая пустой short ID;
  неверный peer key не достигает назначения. Все эти тесты PASS.
- Итоговый Full после исправления Edge: **11/12 lanes PASS за171,30с**, source
  unchanged; app509 и analyzer clean. Native core остаётся failed из-за двух
  прежних MASQUE regressions: IPv6 HTTPS EOF и UDP deadline exceeded. Тесты не
  удалены и не ослаблены. Начальный Full278,61с также сохранён; его test-only
  analyzer notices исправлены до итогового прогона.
- Все 20 разных VLESS TCP endpoints доступны на уровне TCP. Внешний HTTPS
  через VLESS не подтверждён, в том числе после Edge-адаптера и с числовым
  HTTPS destination. TCP connect/Compile не являются доказательством VPN.
- Один Hysteria2-профиль дал два HTTPS200 в четырёх ранних запросах к числовой
  цели; затем итоговая матрица36/36 снова завершилась отказами соединения.
  Работоспособность и стабильность предоставленных серверов не приняты.
  Причина внешних отказов не установлена; нужен сравнительный результат
  другого клиента в той же сети либо дополнительная серверная диагностика.

[Обезличенная матрица](evidence/provider-transport-20261022.json),
[итоговый Full](evidence/provider-transport-final-full-20261022.json),
[начальный Full](evidence/provider-transport-initial-full-20261022.json).

Испытания использовали authenticated loopback SOCKS и не меняли TUN, firewall,
DNS или маршруты Windows. Новая приёмка Android/Windows TUN, DNS, IPv6,
kill switch и физических устройств не проводилась; E1 остаётся открытым.
APK/EXE, установленное приложение и production feeds не менялись.

Нативная schema и компилятор изменены: доставка требует **новой полной базы
Android/Windows**. Dart-only OTA старой базы39 отклонит новые QUIC fields на
старой нативной границе. Публикация и стабильная приёмка остаются отдельными
этапами; этот отчёт не разрешает обходить release gates.
