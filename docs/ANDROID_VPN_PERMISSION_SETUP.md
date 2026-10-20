# Android: запрос VPN и восстановление доступа

Кандидат 0.1.13+35, UI revision8; 2026-10-20. Рабочее дерево; commit ожидается.

Первое явное нажатие Connect сразу вызывает `VpnService.prepare()` из активной
Activity. Если Android возвращает intent, ExVPN открывает системное подтверждение.
Запуск VPN требует настоящего grant; уведомления Android13+ запрашиваются после
него отдельно. Отказ в уведомлениях не является отказом VPN.

При `vpn_permission_denied`, `vpn_permission_unavailable` или публичном запрете
`UserManager.DISALLOW_CONFIG_VPN` приложение показывает краткое восстановление
доступа с крестиком. Результат до `onResume` откладывает только показ окна.
Повтор подключения требует явного нажатия; закрытие, возврат из настроек и смена
профиля сами соединение не запускают. Системный запрет не вызывает цикл повторов.

`getVpnPermissionSetup(null)` возвращает только schema1 и закрытые enum:
vpn granted/required/restricted/unavailable, notifications granted/required,
vendor xiaomi/android. Неизвестный ответ не считается разрешением. Settings actions
фиксированы: системный раздел VPN и собственная карточка приложения. Произвольные
package/URI, сведения о другом VPN и данные подписки не принимаются.

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
Исправленный APK и физический Redmi15/Android16 ещё требуют отдельной проверки.

Источники:

- [Официальный lifecycle VPN](https://developer.android.com/develop/connectivity/vpn).
- [Android16 ConfirmDialog](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/packages/VpnDialogs/src/com/android/vpndialogs/ConfirmDialog.java).
- [Публичный запрет VPN](https://developer.android.com/reference/android/os/UserManager#DISALLOW_CONFIG_VPN).
- [Разрешение уведомлений](https://developer.android.com/develop/ui/views/notifications/notification-permission).
- [Xiaomi: дополнительные разрешения](https://www.mi.com/uk/support/faq/details/KA-497760/).
