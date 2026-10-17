# Подпись Windows: варианты для ExVPN

Проверено 2026-10-17. Уточнённые условия пользователя: Казахстан, частный
разработчик, сертификата Authenticode нет. Покупки, заявки и обращения
провайдерам не выполнялись. Цены ориентировочные; доступность оплаты и выдачи
нужно подтвердить до заказа.

Решение пользователя 2026-10-17: **выбор платной подписи отложен**.
Покупки и заявки не выполняются. До получения подходящей подписи Windows
пакеты сохраняют маркировку development; это отдельное ограничение выпуска.

| Вариант | Стоимость по официальной странице | Применимость |
|---|---|---|
| Certum Open Source в облаке | От €49, срок OSS-продукта — один год | Первый бюджетный кандидат для бесплатного открытого ExVPN. Выдаётся физлицам; нужны подтверждение личности/адреса и публичная связь с проектом. Коммерческое распространение подписанного ПО запрещено условиями этого продукта. Выдача конкретному заявителю из Казахстана ещё не подтверждена |
| Certum Standard в облаке | От €209 | Альтернатива без ограничения OSS-продукта на коммерческое распространение. У Certum описана выдача Standard физлицам; совместимость документов из Казахстана и итоговую цену нужно подтвердить |
| SSL.com Individual Validation + eSigner | IV: $129/год; облачная подпись отдельно, на странице Tier 1 показано $15/месяц при выбранном годовом варианте, 240 подписей | Кандидат для индивидуального издателя и облачной подписи. Казахстан присутствует в общем списке стран CSR; это **не подтверждение выдачи конкретному заявителю**. Нужен ответ по IV/eSigner, документам и итоговому тарифу |
| SignPath Foundation | Бесплатная программа для подходящих OSS-проектов | Возможная альтернатива после рассмотрения проекта. Подпись от SignPath Foundation, требования к репутации проекта, CI, ревью, подтверждению каждого выпуска и составу зависимостей. Приём ExVPN не подтверждён |
| Microsoft Artifact Signing | Basic $9,99/месяц, до 5000 подписей | Для физлиц Public Trust доступен только в США/Канаде. Казахстан не входит в опубликованный список |

Источники цен и условий: [SSL.com IV](https://www.ssl.com/products/software-integrity/code-signing/iv/),
[eSigner](https://www.ssl.com/products/software-integrity/signing-service/),
[страны SSL.com](https://www.ssl.com/country-codes/),
[SignPath и условия](https://signpath.org/terms.html),
[Certum цены](https://shop.certum.eu/buy-a-code-signing-certyficate),
[Certum OSS](https://support.certum.eu/en/code-signing-required-documents/),
[Microsoft eligibility](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart),
[Microsoft цена](https://azure.microsoft.com/en-us/products/artifact-signing).

После возобновления выбора подписи следующий шаг — подтвердить Certum OSS/SimplySign для заявителя
из Казахстана и бесплатного ExVPN. Если планируется коммерческое распространение,
сравнить Certum Standard и SSL.com IV/eSigner. Лицензию Apache-2.0 менять не нужно;
ограничение OSS-сертификата относится к использованию именно этого продукта
подписи. SignPath оставляем
кандидатом без обещания одобрения: в ExVPN есть отдельно лицензируемые
Wintun/MSVC binaries и собственный Xray patch, совместимость с правилами
программы требует рассмотрения. Присутствие KZ в общей таблице SSL.com не
заменяет индивидуальную проверку. Посредник не отменяет условия издателя.

Текст запроса для самостоятельной отправки провайдеру:

> I am an individual developer residing in Kazakhstan. I maintain the free,
> open-source ExVPN Windows VPN client under Apache-2.0. Can you issue an
> Authenticode certificate to me with cloud signing? Please compare your
> individual and open-source options, where available, and confirm
> identity/address requirements, supported payment methods, country restrictions,
> and the full one-year price including cloud signing and signature quota.
> The package contains a Windows UI, a user-mode service, an NSIS installer and
> an uninstaller; it does not ship a newly developed kernel driver.

## Что должно быть подписано и проверено

- Собственные UI EXE, служебный EXE и необходимые собственные DLL/scripts
  подписываются до вычисления окончательного manifest пакета.
- NSIS uninstaller и внешний installer также получают Authenticode и timestamp;
  последующее изменение файла требует новой подписи и нового hash.
- Сторонние подписанные DLL не переподписываются от имени ExVPN.
- После упаковки независимый audit проверяет подпись, доверенную цепочку,
  ожидаемого издателя, timestamp и фактическое содержимое installer.
- Повторяется установка/обновление/удаление именно подписанного кандидата
  на чистом стенде. Новый сертификат сам по себе не подтверждает E1/E7.

Самоподписанные сертификаты, найденные на ПК, не относятся к ExVPN и не
используются. Даже действительная OV/EV-подпись не гарантирует исчезновения
SmartScreen для нового файла: Microsoft отдельно описывает накопление репутации.
[Пояснение Microsoft](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).
