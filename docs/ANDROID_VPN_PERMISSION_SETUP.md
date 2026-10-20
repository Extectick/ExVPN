# Android: запрос VPN и восстановление доступа

Кандидат 0.1.13+35, UI revision9; 2026-10-20. Рабочее дерево; commit ожидается.

Первое явное нажатие Connect сразу вызывает `VpnService.prepare()` из активной
Activity. Если Android возвращает intent, ExVPN открывает системное подтверждение.
Запуск VPN требует настоящего grant; уведомления Android13+ запрашиваются после
него отдельно. Отказ в уведомлениях не является отказом VPN.

При `vpn_permission_denied`, `vpn_permission_unavailable` или публичном запрете
`UserManager.DISALLOW_CONFIG_VPN` приложение показывает краткое восстановление
доступа с крестиком. Результат до `onResume` откладывает только показ окна.
Повтор подключения требует явного нажатия; закрытие, возврат из настроек и смена
профиля сами соединение не запускают. Системный запрет не вызывает цикл повторов.

Recovery `getVpnPermissionSetup(null)` вызывается после явной попытки подключения
и возвращает только schema1 и закрытые enum:
vpn granted/required/restricted/unavailable, notifications granted/required,
vendor xiaomi/android. Неизвестный ответ не считается разрешением. Settings actions
фиксированы: системный раздел VPN и собственная карточка приложения. Произвольные
package/URI, сведения о другом VPN и данные подписки не принимаются. Наблюдение
уведомлений использует отдельный `getNotificationPermission(null)` с закрытым
granted|required и не вызывает `VpnService.prepare()`: простое открытие настроек
не должно менять prepared VPN. Проверяются POST, app toggle и собственный канал.
`openNotificationSettings(null)` ведёт только в уведомления ExVPN с fallback на
собственную карточку приложения; действие всегда явное.

Обычная отмена позволяет повторить запрос сразу. Ссылка «Запрос не появляется?»
раскрывает три конкретных шага: открыть VPN settings, у другого VPN нажать ⚙/ⓘ
и выключить постоянный VPN, вернуться и повторить запрос. Помощь не утверждает,
что приложение обнаружило чужой пакет. После открытия настроек главной становится
кнопка повтора, но возврат не начинает соединение. Xiaomi-подсказки вторичны.

После connected/foreground/idle при недоступном уведомлении показывается одно
краткое предложение включить его. Оно не повторяется на каждом status tick.
Постоянный путь «Уведомление VPN» находится в Android-настройках ExVPN и обновляет
статус после возврата. Неизвестный ответ не выдаётся за отказ пользователя.

На Xiaomi/Redmi/Poco после ошибки доступна карточка ExVPN и условная подсказка
о дополнительных настройках производителя. Overlay, доступ ко всем файлам,
исключение батареи и автозапуск не объявляются обязательными для первого VPN.
Маршрутизация, DNS, TUN, исключения и защита не меняются; ограничения другого VPN
и lockdown приложение самостоятельно не отключает.

В Android16 системный `ConfirmDialog` может вернуть RESULT_CANCELED без окна,
если другой пакет выбран постоянным VPN или действует запрет администратора.
Поэтому отмена не доказывает, что пользователь отказался. ExVPN не утверждает,
что обнаружил чужой постоянный VPN: публичного разрешённого способа узнать его
пакет у обычного приложения нет. Подсказка сформулирована условно.

На принадлежащем QA эмуляторе API36 в опубликованной 0.1.12+34 подтверждены:
на чистых настройках появляется настоящий запрос, после OK проходит HTTPS
из отдельного UID через VPN transport. При другом постоянном VPN без lockdown
окно ОС не появляется, а старый клиент пишет «VPN permission was not granted».
Контрольный пакет не имеет INTERNET и никогда не создаёт TUN. Его Always-on
меняется только через настоящий экран системных настроек на этом эмуляторе.
Промежуточный APK f39b681/UI8 прошёл тот же сценарий recovery → Settings → return
без auto-connect → явный retry → реальная отмена → retry/grant; отдельный UID
получил HTTPS200 и DNS через единственный ExVPN TUN с другим внешним IP.
Этот APK не публиковался; последующие пожелания пользователя входят в UI9.

На физическом Redmi15/Android16 установлена 0.1.12+34. В её основном пространстве
другой VPN был выбран постоянным. Пользователь отключил его самостоятельно;
настоящее системное окно ExVPN появилось, пользователь разрешил VPN. Наблюдены
foreground service, VPN-сеть с UID ExVPN, предоставленное notification permission
и собственное уведомление7001 с действием «Отключить». Пользователь смахнул только
ExVPN из недавних: служба/TUN остались, package не stopped, exit-info не изменился.
Физический HTTPS/DNS/IPv6 и финальный APK35 этим не приняты.

## Закрытие UI и ограничения Android

Служба уже использовала START_STICKY, защищённое восстановление профиля и прямой
PendingIntent STOP; Activity/Flutter dispose не вызывают native stop. Теперь
stopWithTask=false указан явно, уведомление CATEGORY_SERVICE показывается сразу,
без повторного звука/времени. Это уточняет существующее поведение, а не доказывает
устранение всех OEM-остановок. Трафик и DNS не переводятся напрямую при сбое.

История телефона содержит системные SwipeUpClean/OneKeyClean. Свежий тест смахивания
после разрешения уведомлений их не воспроизвёл. Android Task Manager Stop и Force
stop завершают приложение; обхода нет. Android14+ может позволять пользователю
смахнуть ongoing-уведомление. Xiaomi-настройки батареи/автозапуска не объявляются
обязательными VPN-разрешениями. Redmi15 по официальному FAQ не поддерживает
Background App lock: этот пункт пользователю не навязывается.

UI9 принят исходниками:15 focused tests, scoped analyze, затем общий Full12/12
за104,54с, app482 tests и неизменные исходники во время прогона.
[Отчёт](evidence/fast-validation-android-guidance35-ui9.json).
Финальный APK и runtime остаются отдельным следующим гейтом.66 JVM tests
прошли при промежуточной сборке f39b681; это не новый JVM-прогон UI9.

Источники:

- [Официальный lifecycle VPN](https://developer.android.com/develop/connectivity/vpn).
- [Android16 ConfirmDialog](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/packages/VpnDialogs/src/com/android/vpndialogs/ConfirmDialog.java).
- [Публичный запрет VPN](https://developer.android.com/reference/android/os/UserManager#DISALLOW_CONFIG_VPN).
- [Разрешение уведомлений](https://developer.android.com/develop/ui/views/notifications/notification-permission).
- [Xiaomi: дополнительные разрешения](https://www.mi.com/uk/support/faq/details/KA-497760/).
- [Остановка foreground service пользователем](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping).
- [Redmi15: FAQ модели](https://www.mi.com/uk/support/faq/details/KA-592870/).
