# VLESS Encryption и TCP Sudoku

Дата: 2026-10-17. Изменения входят в development-сборку **0.1.0+9**.
Xray остаётся закреплён на `701af60772cda123492f86e383e1fdba066614a9`;
зависимости и доверенные сертификаты не менялись.

## Реализация

Нормализованный профиль получил необязательный `encryption` с проверяемой
грамматикой VLESS Encryption и `transport.tcpSudoku` с типизированными
параметрами. URI `fm` и Xray JSON `streamSettings.finalmask` разбираются
по белому списку; произвольный FinalMask/stream JSON в ядро не передаётся.

- Encryption: `mlkem768x25519plus`, режимы `native`, `xorpub`, `random`,
  `0rtt`/`1rtt`; от одного до четырёх канонических Base64URL public keys
  длиной 32 или 1184 байта. При импорте проверяется каноничность ML-KEM
  coefficients: первые 1152 байта содержат 12-битные значения <3329,
  последние 32 байта — seed. Нативная граница независимо проверяет
  encapsulation key через стандартную библиотеку Go.
- Padding: до 15 чередующихся тройных параметров probability/min/max,
  probability 0–100, min ≤ max, первый length с probability 100 и min ≥35,
  сумма максимальных lengths ≤65553 байта, отдельный gap ≤1000 мс.
  Более широкие входы отклоняются явно, а не ограничиваются молча.
- Sudoku: один TCP mask для VLESS; пароль до 4096 UTF-8 байт без control
  characters, ASCII/entropy режим, до четырёх восьмисимвольных таблиц,
  padding 0–100 с min ≤ max. Старые snake_case aliases нормализуются;
  конфликт aliases, неизвестные поля, UDP masks и цепочки masks отклоняются.
- Sudoku сам по себе не обеспечивает аутентификацию. Профиль требует
  TLS/REALITY либо VLESS Encryption. Vision без любого из этих механизмов
  по-прежнему не принимается; `flow` никогда не удаляется для обхода отказа.
- Поля участвуют в ID профиля, передаются через существующий защищённый
  native bridge и сохраняются в защищённом снимке. ID старых профилей без
  дополнительных полей не изменились. Исправлен также restart Hysteria2:
  codec снимка теперь принимает нормализованный transport `hysteria`.
- Явный `null` для сохранённых `encryption`/`tcpSudoku` отклоняется как
  повреждение снимка; отсутствие полей у старого профиля остаётся допустимым.

Ошибки не включают входные ключи/пароли. Отдельная регрессия проверяет
Base64 exception: стандартный decoder мог включать ключ в сообщение;
теперь наружу выходит только фиксированная безопасная ошибка.

Первичные источники, проверенные вместе с закреплёнными исходниками:
[VLESS grammar](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/infra/conf/vless.go),
[Encryption authentication](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/proxy/vless/encryption/client.go),
[FinalMask schema](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/infra/conf/transport_finalmask.go),
[Sudoku implementation](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/transport/internet/finalmask/sudoku/table.go).

## Проверка

- **192 domain tests** и **46 client_state tests**: URI/JSON equivalence,
  безопасные отказы, bounds, сохранение и восстановление, стабильные старые ID.
- Новая native-матрица: **24 варианта** (3 режима ×2 RTT ×2 типа ключа
  ×Sudoku/без него), по два настоящих HTTPS-соединения к независимому
  loopback target. Отдельно два Vision/Sudoku options сценария и восемь
  отказов при неправильном ключе, пароле маски, UUID либо отсутствии маски.
  Контрольный правильный клиент получает HTTPS; неправильный не достигает
  назначения. Target certificate проверяется в памяти теста, системное
  хранилище доверия и production trust не меняются.
- Focused native suite занял **0,485 с**, `go vet` прошёл. Полный набор
  включает более долгие ранее существовавшие проверки REALITY/TLS.
- Настоящий сохранённый ответ предоставленной подписки теперь импортируется
  как **30/32**, включая четыре Encryption/Sudoku записи. Две записи
  Vision без защиты остаются отклонёнными.
- Четыре новых провайдерских профиля проверены HTTPS через loopback SOCKS:
  **0/4 прошли**. Дополнительный TCP probe дал 3/4 reachable;
  одна запись не установила TCP за 4 секунды, другая при отдельной
  диагностике завершила прокси handshake с EOF. Причина внешнего отказа
  не установлена; ошибка клиента/несовместимость peer не исключены.
  Это не доказательство неработоспособности провайдера в других сетях.

Следовательно, успешные локальные протокольные тесты не закрывают E1 и
приёмку четырёх реальных узлов. Установленный Android/Windows клиент,
TUN, DNS/IPv6, исключения и аварии требуют собственных доказательств.
История +7 с тремя подтверждёнными внешними XHTTP узлами сохранена в
[предыдущем отчёте](PROVIDER_COMPATIBILITY.md).

Исходники: [f5901bc](https://github.com/Extectick/ExVPN/commit/f5901bc7d0b61d22f555bc760cbfcb5e3c85de81).

## Установленная сборка +9

[Обезличенный отчёт](evidence/provider-build9.json) связывает исходники с
SHA-256 APK/установщика и сохраняет в том числе неуспешную попытку.

- Android API30 emulator: обычное обновление +8 → +9 сохранило 30 профилей и
  две ошибки импорта. Независимый UID подтвердил HTTPS 200/204 через TUN,
  разрешение DNS и изменение внешнего IPv4 на XHTTP/REALITY узле. После
  отключения вернулся исходный IPv4; cold restart сохранил список и ошибки.
- Windows Sandbox: NSIS +8 → +9, LocalSystem-служба и Flutter UI с ограниченными
  правами. В первом прогоне узлы 4/25 подтвердили HTTPS, DNS через TUN и другой
  внешний IPv4; узел 7 вернул `tunnel_unreachable`, UI показал blocked.
  Один отдельный повтор узла 7 прошёл. Начальный отказ не скрыт и не считается
  чистым результатом 3/3 с первой попытки.
- Обе Windows-попытки завершили explicit disconnect/cleanup: TUN и guard сняты,
  маршруты/DNS совпали с исходными, production service binding восстановлен.

Это проверка трёх XHTTP/REALITY узлов Windows и одного Android, а не подтверждение
четырёх Encryption/Sudoku узлов. DNS resolution не доказывает отсутствие утечек;
полная IPv4/IPv6/DNS, crash/lockdown и физическая Android-приёмка остаются открытыми.
