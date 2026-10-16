# Windows: защищённое разрешение имени VPN-сервера

Дата исследования: **2026-10-16**. Статус: **план следующего изменения; не реализован и не проверен сетевым испытанием**. Подготовленный Windows installer не содержит этот механизм. E1/E5 остаются открытыми. Сначала выполняется подготовленный изолированный установочный стенд; этот документ не разрешает менять маршруты, DNS или WFP рабочего хоста.

## Подтверждённое исходное состояние

- `native/windows/tunnel_config.go:BuildTunnelConfig` принимает только literal IP и возвращает `server_ip_required` для hostname.
- `native/windows/controller.go:connect` выполняет `Arm → StartTunnel → PermitTunnel → HTTPS Verify`. Постоянные WFP-блокировки появляются **до** запуска TUN. Существующие временные физические разрешения службы создаются только после успешного запуска TUN.
- `native/windows/guard_windows.go:PermitTunnel` требует AppID executable службы и LocalSystem. TUN-разрешения привязаны к локальному и next-hop/arrival интерфейсам. Обычное приложение, в том числе UI, физического разрешения службы не получает.
- Общий DNS идёт через `dns-query → proxy`; правила DNS предшествуют исключениям. `direct-excluded` использует `ForceIP`. Неизвестный/неоднозначный владелец соединения направляется в proxy. Bootstrap не должен менять эти инварианты.
- Исследован точный Xray commit `701af60772cda123492f86e383e1fdba066614a9`, версия `26.10.10`, и локальный Go `1.27.2`. Исследование исходников не доказывает отсутствие сетевых утечек на целевой ОС.

Перенос разрешения имени до `Arm()` создаёт незащищённый период. Обычный системный DNS после `Arm()` блокируется. Ни один вариант не используется как обход ограничения.

## Предлагаемый жизненный цикл

1. Проверить нормализованный профиль без сетевого обращения. Для hostname отделить проверку схемы/поддерживаемых полей от построения финальной конфигурации с уже полученными адресами. Команда `validate` не должна запускать bootstrap или менять WFP.
2. Поставить сохраняющиеся блокирующие фильтры. Определить пригодный внешний интерфейс и его текущий LUID/index без изменения таблицы маршрутизации. Не принимать ExVPN TUN или loopback как внешний интерфейс.
3. Открыть отдельную **динамическую** WFP-сессию bootstrap. Разрешить только пересечение условий: AppID службы, SYSTEM, конкретный локально заданный IP резолвера, TCP/443, выбранный интерфейс. Не создавать широкое разрешение службы на этой стадии. Не добавлять разрешение Windows DNS Client, `svchost.exe` или обычным приложениям.
4. Отдельным ограниченным HTTPS-клиентом запросить A/AAAA только для endpoint выбранного профиля. Ответ относится к текущему поколению подключения. Отмена, ошибка сертификата, отсутствие допустимых адресов или истечение срока завершают попытку без прямого fallback.
5. Закрыть HTTP body, активные/idle соединения и динамическую bootstrap-сессию. Сохраняющиеся блокировки остаются. Передать ядру проверенный внутренний набор адресов и исходный логический hostname.
6. Продолжить существующий порядок: запуск TUN, разрешения рабочего туннеля/службы, HTTPS-проверка, затем `connected`. При неудаче сохранять `blocked` и стабильный обезличенный код ошибки.

WFP поддерживает условия executable, user identity, remote IP/port, protocol и interface на нужных ALE-слоях; динамические объекты удаляются при завершении сессии. Точный набор фильтров и поведение закрытия соединений требуют интеграционной проверки, включая аварийное завершение процесса. [Условия по слоям](https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-conditions-available-at-each-filtering-layer), [идентификаторы условий](https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-condition-identifiers-), [динамические сессии](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_session0).

## Ограниченный DoH-клиент

URL, порт, TLS-имя, список числовых IP резолвера и доверенные корни задаёт локальная политика ExVPN. Подписка не может их менять. Конкретный список/сертификаты фиксируются при реализации и проходят проверку происхождения; данный план не закрепляет случайно наблюдавшийся сертификат.

- `POST` с DNS wire format, `Content-Type` и `Accept: application/dns-message`; запрос содержит один вопрос A либо AAAA для выбранного hostname. Не использовать generic HTTP/DNS proxy API в IPC.
- `DialContext` соединяется только с разрешённым числовым IP. `Proxy=nil`, редиректы запрещены, cookies отсутствуют. Отдельный transport не переиспользует чужие соединения и после попытки полностью закрывается.
- Общий deadline, ограниченные connect/TLS/header timeouts и предел ответа 64 KiB. Проверять HTTP status/media type, DNS response/question/class/type, RCODE, число записей и связанность CNAME-цепочки. Ограничить CNAME глубиной 8 и числом адресов; игнорировать несвязанные additional records.
- Нормализовать IPv4-mapped адреса; отклонять unspecified, multicast, loopback и собственные адреса TUN. Политику private-unicast согласовать с поддержкой частных VPN endpoint, не заменять её неявным публичным-only фильтром. Невозможность разрешить имя частной зоны публичным DoH — явная несовместимость; системный DNS не становится fallback.
- Не делать SRV/TXT/HTTPS/SVCB discovery, search-suffix expansion, mDNS или LLMNR. Не передавать EDNS Client Subnet.
- Кеш только в памяти, с TTL и текущим поколением сети/подключения. Не продлевать TTL минимальным clamp; учитывать ограничения кеширования ответа. Не использовать просроченную запись как скрытый fallback и не писать результат в системный DNS-кеш.
- При смене сети выполнять новую ограниченную попытку/управляемое переподключение под guard. При TTL expiry не перезаписывать профиль в пользовательском хранилище и не разрывать успешный транспорт без определённой политики перехода.

DoH определяет передачу бинарного DNS по HTTPS и аутентификацию сервера; POST не включает вопрос в URL. Проверенный пример провайдера поддерживает этот wire format, TLS 1.2/1.3 и HTTP/2. Это основание для реализации, а не подтверждение доступности сервиса в пользовательской сети. [RFC 8484](https://www.rfc-editor.org/rfc/rfc8484.html), [Cloudflare DoH API](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/), [wire format](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-wireformat/).

У `net/http.Transport` собственный `DialContext` и `TLSClientConfig` позволяют отделить числовой адрес соединения от проверяемого TLS-имени. Не использовать `ProxyFromEnvironment` или custom `DialTLSContext`, случайно обходящий заданные TLS-настройки. [Go HTTP Transport](https://pkg.go.dev/net/http#Transport).

## Привязка интерфейса и TLS без побочных обращений

Bootstrap-сокет должен явно привязываться к пригодному внешнему интерфейсу. `GetBestRoute2` позволяет проверить маршрут/исходный адрес, а index требуется получать заново при изменении адаптера. Для `IP_UNICAST_IF` используется network byte order, для `IPV6_UNICAST_IF` — host byte order. Ошибка привязки прекращает попытку. Фильтр WFP дополнительно ограничивает допустимый интерфейс; слабую модель host routing и multihoming проверяют в стенде. [GetBestRoute2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getbestroute2), [IPv4 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options), [IPv6 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options).

В локальном Go 1.27.2 `crypto/x509/root_windows.go` вызывает `CertGetCertificateChain` без cache-only flags. Такая проверка может получать AIA/intermediate/root через сеть. Для bootstrap необходима полноценная **офлайн** проверка имени, срока и цепочки: локальный non-system `x509.NewCertPool` с проверенными корнями либо отдельная реализация Win32 с explicit cache-only policy. `SystemCertPool` сам по себе не отключает Windows verifier. Не разрешать произвольные сетевые обращения и не ставить `InsecureSkipVerify` ради успешного bootstrap. [CertGetCertificateChain](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certgetcertificatechain).

В закреплённом Xray при текущем `useSystemCA=false` используется встроенный root bundle. Новый Go transport и существующий Go HTTPS healthcheck должны отдельно проверяться на побочные certificate-chain обращения. Возможность такого обращения по исходникам не объявляется доказанной утечкой текущего клиента.

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

## Приёмка будущего изменения

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
