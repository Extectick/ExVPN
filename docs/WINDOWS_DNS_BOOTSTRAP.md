# Windows: защищённое разрешение имени VPN-сервера

Дата: **2026-10-16**. Статус: **реализован в Windows-службе, отдельный WFP/DoH smoke пройден в Sandbox**. Сквозное подключение к VPN по hostname через установленную службу ещё не принято; E1/E5 остаются открытыми. Исходники: [713b1a0](https://github.com/Extectick/ExVPN/commit/713b1a0ebb990e7b32a32e7544385fbc793bdc84). Эти испытания не меняют маршруты, DNS или WFP рабочего хоста.

## Подтверждённое исходное состояние

- `validateTunnelProfile` принимает hostname без сетевых обращений. `WindowsTunnelFactory` разрешает его под уже поставленной защитой. Публичный `BuildTunnelConfig` без внутреннего подтверждённого mapping по-прежнему отклоняет hostname: обход проверки через произвольную конфигурацию отсутствует.
- `native/windows/controller.go:connect` выполняет `Arm → WindowsTunnelFactory → PermitTunnel → HTTPS Verify`. Для hostname factory выполняет ограниченный DoH, закрывает его разрешения и затем запускает TUN. Постоянные WFP-блокировки появляются **до** bootstrap. Существующие временные физические разрешения рабочего туннеля создаются только после успешного запуска TUN.
- `native/windows/guard_windows.go:PermitTunnel` требует AppID executable службы и LocalSystem. TUN-разрешения привязаны к локальному и next-hop/arrival интерфейсам. Обычное приложение, в том числе UI, физического разрешения службы не получает.
- Общий DNS идёт через `dns-query → proxy`; правила DNS предшествуют исключениям. `direct-excluded` использует `ForceIP`. Неизвестный/неоднозначный владелец соединения направляется в proxy. Bootstrap не должен менять эти инварианты.
- Исследован точный Xray commit `701af60772cda123492f86e383e1fdba066614a9`, версия `26.10.10`, и локальный Go `1.27.2`. Исследование исходников не доказывает отсутствие сетевых утечек на целевой ОС.

Перенос разрешения имени до `Arm()` создаёт незащищённый период. Обычный системный DNS после `Arm()` блокируется. Ни один вариант не используется как обход ограничения.

## Реализованный жизненный цикл

1. Проверить нормализованный профиль без сетевого обращения. Для hostname отделить проверку схемы/поддерживаемых полей от построения финальной конфигурации с уже полученными адресами. Команда `validate` не должна запускать bootstrap или менять WFP.
2. Поставить сохраняющиеся блокирующие фильтры. Определить пригодный внешний интерфейс и его текущий LUID/index без изменения таблицы маршрутизации. Не принимать ExVPN TUN или loopback как внешний интерфейс.
3. Открыть отдельную **динамическую** WFP-сессию bootstrap. Разрешить только пересечение условий: AppID службы, SYSTEM, конкретный локально заданный IP резолвера, TCP/443, выбранный интерфейс. Не создавать широкое разрешение службы на этой стадии. Не добавлять разрешение Windows DNS Client, `svchost.exe` или обычным приложениям.
4. Отдельным ограниченным HTTPS-клиентом запросить A/AAAA только для endpoint выбранного профиля. Ответ относится к текущему поколению подключения. Отмена, ошибка сертификата, отсутствие допустимых адресов или истечение срока завершают попытку без прямого fallback.
5. Закрыть HTTP body, активные/idle соединения и динамическую bootstrap-сессию. Сохраняющиеся блокировки остаются. Передать ядру проверенный внутренний набор адресов и исходный логический hostname.
6. Продолжить существующий порядок: запуск TUN, разрешения рабочего туннеля/службы, HTTPS-проверка, затем `connected`. При неудаче сохранять `blocked` и стабильный обезличенный код ошибки.

WFP поддерживает условия executable, user identity, remote IP/port, protocol и interface на нужных ALE-слоях; динамические объекты удаляются при завершении сессии. Создание выбранных фильтров и явное закрытие проверены в Sandbox; аварийное завершение именно во время bootstrap ещё открыто. [Условия по слоям](https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-conditions-available-at-each-filtering-layer), [идентификаторы условий](https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-condition-identifiers-), [динамические сессии](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_session0).

## Ограниченный DoH-клиент

URL, порт, TLS-имя, числовой IP резолвера и доверенные корни задаёт локальная политика ExVPN. Подписка не может их менять. Сейчас это `https://cloudflare-dns.com/dns-query`, проверяемое TLS-имя `cloudflare-dns.com`, соединение только с `1.1.1.1:443`. Дополнительных резолверов и системного fallback нет. Сеть только с IPv6, недоступный Cloudflare и локальная DNS-зона возвращают явный отказ подключения; это ограничения текущей реализации.

- `POST` с DNS wire format, `Content-Type` и `Accept: application/dns-message`; запрос содержит один вопрос A либо AAAA для выбранного hostname. Не использовать generic HTTP/DNS proxy API в IPC.
- `DialContext` соединяется только с разрешённым числовым IP. `Proxy=nil`, редиректы запрещены, cookies отсутствуют. Отдельный transport не переиспользует чужие соединения и после попытки полностью закрывается.
- Общий deadline, ограниченные connect/TLS/header timeouts и предел ответа 64 KiB. Проверять HTTP status/media type, DNS response/question/class/type, RCODE, число записей и связанность CNAME-цепочки. Ограничить CNAME глубиной 8 и числом адресов; игнорировать несвязанные additional records.
- Нормализовать IPv4-mapped адреса; отклонять unspecified, multicast, loopback и собственные адреса TUN. Политику private-unicast согласовать с поддержкой частных VPN endpoint, не заменять её неявным публичным-only фильтром. Невозможность разрешить имя частной зоны публичным DoH — явная несовместимость; системный DNS не становится fallback.
- Не делать SRV/TXT/HTTPS/SVCB discovery, search-suffix expansion, mDNS или LLMNR. Не передавать EDNS Client Subnet.
- Между попытками подключения кеша нет: каждая новая factory-попытка запрашивает A/AAAA заново. Минимальный TTL сохраняется для диагностики, без clamp. Текущий core получает неизменяемый снимок адресов; в системный DNS-кеш он не записывается.
- Автоматическое обновление снимка по TTL/смене сети ещё не реализовано. После изменения адреса VPN endpoint требуется новое подключение. Монитор состояния повторяет HTTPS-проверку текущего core, но не выдаёт это за повторный bootstrap. Политику перехода и несколько интерфейсов нужно проверить отдельно.

DoH определяет передачу бинарного DNS по HTTPS и аутентификацию сервера; POST не включает вопрос в URL. Проверенный пример провайдера поддерживает этот wire format, TLS 1.2/1.3 и HTTP/2. Это основание для реализации, а не подтверждение доступности сервиса в пользовательской сети. [RFC 8484](https://www.rfc-editor.org/rfc/rfc8484.html), [Cloudflare DoH API](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/), [wire format](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-wireformat/).

У `net/http.Transport` собственный `DialContext` и `TLSClientConfig` позволяют отделить числовой адрес соединения от проверяемого TLS-имени. Не использовать `ProxyFromEnvironment` или custom `DialTLSContext`, случайно обходящий заданные TLS-настройки. [Go HTTP Transport](https://pkg.go.dev/net/http#Transport).

## Привязка интерфейса и TLS без побочных обращений

Bootstrap-сокет должен явно привязываться к пригодному внешнему интерфейсу. `GetBestRoute2` позволяет проверить маршрут/исходный адрес, а index требуется получать заново при изменении адаптера. Для `IP_UNICAST_IF` используется network byte order, для `IPV6_UNICAST_IF` — host byte order. Ошибка привязки прекращает попытку. Фильтр WFP дополнительно ограничивает допустимый интерфейс; слабую модель host routing и multihoming проверяют в стенде. [GetBestRoute2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getbestroute2), [IPv4 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options), [IPv6 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options).

В локальном Go 1.27.2 `crypto/x509/root_windows.go` вызывает `CertGetCertificateChain` без cache-only flags. Такая проверка может получать AIA/intermediate/root через сеть. Для bootstrap необходима полноценная **офлайн** проверка имени, срока и цепочки: локальный non-system `x509.NewCertPool` с проверенными корнями либо отдельная реализация Win32 с explicit cache-only policy. `SystemCertPool` сам по себе не отключает Windows verifier. Не разрешать произвольные сетевые обращения и не ставить `InsecureSkipVerify` ради успешного bootstrap. [CertGetCertificateChain](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certgetcertificatechain).

Реализация копирует non-system root pool закреплённого Xray с `useSystemCA=false`: `golang.org/x/crypto/x509roots/fallback` версии `v0.0.0-20261005185213-c3db4df58582`, уже входящий в Go graph. TLS hostname, срок, цепочка и ограничения корней проверяются; `InsecureSkipVerify` не используется. Этот pool теперь получает и Go HTTPS healthcheck туннеля. Анализ исходников и успешный DoH smoke не заменяют packet capture для проверки отсутствия AIA/DNS-побочных запросов.

## Передача адресов Xray без потери hostname

Предпочтительный путь не требует изменения upstream:

```json
{
  "dns": {
    "hosts": {"full:server.example": ["203.0.113.10"]},
    "useSystemHosts": false
  },
  "outbounds": [{
    "tag": "proxy",
    "streamSettings": {"sockopt": {"domainStrategy": "ForceIP"}}
  }]
}
```

Это **фрагмент дополнения**, не полный рабочий конфиг. Остальные существующие DNS/outbound/routing поля сохраняются. `server.example` и documentation IP синтетические. Только служба создаёт точное `full:` отображение; hostname профиля остаётся прежним.

Подтверждено по pinned source:

- `transport/internet/dialer.go:DialSystem` применяет built-in DNS при `sockopt.domainStrategy`; `ForceIP` возвращает ошибку разрешения вместо передачи домена системному dialer.
- `app/dns/dns.go:LookupIP` сначала проверяет static hosts. Static entry с отсутствующей требуемой IP-family возвращает ошибку, а не системный DNS.
- `transport/internet/hysteria/dialer.go` также проходит `DialSystem`.
- WS/XHTTP Host и gRPC authority могут наследовать исходный hostname/TLS ServerName. Поэтому простая замена `profile.Server` на IP без сохранения этих значений неверна.

Исходники: [DialSystem](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/transport/internet/dialer.go), [DNS lookup](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/app/dns/dns.go), [Hysteria](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/transport/internet/hysteria/dialer.go), [DNS configuration](https://xtls.github.io/en/config/dns.html).

TTL самодельного bootstrap-кеша нельзя подменять внутренним условным TTL static hosts Xray. Текущий core lifetime получает неизменяемый проверенный набор. Обновление набора требует отдельной управляемой политики. Исчезновение mapping, ошибочная family или неподдерживаемый transport должны быть отрицательными тестами, а не поводом добавить `localhost` DNS.

## Проверки и границы приёмки

Локально прошли Go test/vet и сборка службы. Тесты проверяют DNS schema/question/RCODE, CNAME loop/ambiguity, несвязанные ответы, лимиты, IPv4-mapped адреса, TLS/HTTP ошибки и отмену. Lifetime-тесты проверяют, что результат не передаётся core до закрытия разрешения и отбрасывается при отмене/ошибке. Девять вариантов конфигурации компилируются точным Xray с сохранением endpoint/SNI/Host. Системные GUID сверяются с независимым Windows SDK header.

В Sandbox 2026-10-16 15:09:52–15:09:55 UTC прошёл отдельный диагностический executable под SYSTEM:

- Независимый executable выполнял numeric HTTPS до включения guard и блокировался до/во время/после bootstrap.
- Временный permit разрешил настоящий TLS/DoH POST A и AAAA для синтетического `example.com` (4 адреса). IP результатов не публикуются.
- Даже процесс bootstrap не смог соединиться с другим IP или TCP-портом.
- После закрытия динамической сессии тот же процесс потерял доступ к `1.1.1.1:443`; persistent guard сохранился.
- Explicit disarm вернул независимый HTTPS. Cleanup успешен, ранее работающая гостевая служба снова Running, TUN отсутствует.

[Обезличенный результат](evidence/windows-bootstrap-smoke.json). Это отдельная проверка WFP/DoH; она не поднимает TUN и не является UI↔SCM или полным hostname VPN-тестом. На хосте служба/адаптер ExVPN отсутствуют.

Подготовка воспроизводимого стенда: `scripts/windows/prepare-bootstrap-sandbox.ps1` только собирает tagged test/probe, проверяемый manifest и `bootstrap.wsb`; ничего не запускает. После явного запуска подготовленного гостя через `wsb start --config (Get-Content <bootstrap.wsb> -Raw) --raw` выполнить через `wsb exec --id <guest-id> --run-as System` команду:

```text
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-Bootstrap-QA\guest-bootstrap-qa.ps1 -ConfirmDisposableGuest
```

Если версия Sandbox допускает только одного гостя, использовать ранее согласованный отключённый стенд и поделиться только новым `input` read-only как `C:\ExVPN-Bootstrap-QA`, новым `output` writable как `C:\ExVPN-Bootstrap-Results`. Guest runner временно останавливает idle ExVPNService и восстанавливает прежнее состояние запуска; активный TUN или уже поставленные фильтры отклоняются. Обычные CI/unit-команды не содержат tag `exvpn_sandbox_qa`. После аварии runner проверять guard в госте и выполнять recovery только для принадлежащих ExVPN фильтров.

Полная матрица пока открыта:

- [ ] Unit: DNS schema/question/RCODE, CNAME loop, несвязанные ответы, превышение лимитов, timeout/cancel, stale generation, TTL, IPv4/IPv6 и malformed TLS/HTTP.
- [ ] Отказы создания/закрытия bootstrap permits, отмена на каждой стадии: сохраняющиеся блокировки остаются, core не получает неподтверждённые адреса.
- [ ] Компиляция точным Xray: `ForceIP`, точное static mapping, отсутствие system hosts/local DNS; сохранены SNI/Host/authority для WS, XHTTP, gRPC, REALITY и Hysteria.
- [ ] В VM холодный DNS/сертификатный кеш и packet capture: на физическом интерфейсе до TUN только разрешённый bootstrap, без DNS53/LLMNR/mDNS/AIA fallback; запросы приложений через proxy или заблокированы.
- [ ] Обрыв DoH/сервера, неверный сертификат, DNS poisoning fixture, сервис crash, смена сети и multiple interfaces: отсутствие прямого выхода защищаемого трафика.
- [ ] Исключённое приложение не получает bootstrap привилегию; неизвестный владелец и DNS сохраняют текущий безопасный маршрут.
- [ ] Последовательность restore/recovery проверена вместе с обязательной Windows матрицей E1/E5. Unit/config проверки не закрывают её.

Ожидаемая граница приватности: выбранный DoH-резолвер видит внешний IP клиента и имя VPN endpoint при установлении туннеля. DNS обычных приложений не передаётся этому bootstrap-клиенту. Это предусмотренное отдельное разрешение endpoint; обещание отсутствия вообще любых запросов вне ещё не установленного туннеля неверно.

## Версия ядра через IPC — отдельное последующее изменение

`native/windows/protocol.go:Status.CoreVersion` уже передаёт `coreVersion` из работающей службы. C++ `vpn_bridge.cpp` пока возвращает для метода `coreVersion` литерал `26.10.10` — идентичность комплектного ядра, **не подтверждённая версия установленной службы**.

Следующая редакция bridge может прочитать `status.coreVersion` через существующий аутентифицированный IPC без нового service command. Отсутствие службы, несовместимая версия протокола и bundled identity должны отображаться различимо. Поля service/app build и core commit стоит добавить отдельным типизированным version contract, если требуется диагностика несовпадений. Это не изменяет подготовленный installer и не отмечается выполненным.
