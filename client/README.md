# Tactical Platform Flutter Client

هذا عميل Flutter أولي مستقل يطابق `protocol` في جذر المستودع:

- يفتح WebSocket إلى الخادم.
- يرسل `HELLO` مع `device_id` و`name` و`team_id`.
- ينتظر `ACK` المطابق لمعرّف رسالة `HELLO`.
- يرسل أول `LOCATION` بعد نجاح المصافحة.
- يبث كل الرسائل الواردة عبر `TacticalClient.messages`.
- يعرض مواقع الفريق الواردة على خريطة OpenStreetMap.
- يطلب صلاحيات GPS ويشارك الموقع الحقيقي عبر `LOCATION` عند الضغط على `Share GPS`.

للتجربة المحلية شغّل الخادم على `8080` ثم:

```powershell
cd client
flutter pub get
flutter run
```

غيّر `ws://127.0.0.1:8080` في `lib/main.dart` إلى عنوان الجهاز المضيف عند التشغيل من جهاز آخر على الشبكة. في الإنتاج استخدم `wss://` خلف TLS.

## GPS والمنصات

`geolocator` يطلب الصلاحية وقت التشغيل. على Android يجب إضافة
`android.permission.ACCESS_FINE_LOCATION` و`ACCESS_COARSE_LOCATION` إلى
`android/app/src/main/AndroidManifest.xml` (و`ACCESS_BACKGROUND_LOCATION` فقط
إذا أضيف تتبع بالخلفية لاحقًا). على Windows يعمل المزود عند توفر Windows
Location Service وصلاحية الموقع في إعدادات النظام؛ لا يتم طلب صلاحية Android
على Windows.

الخريطة تستخدم OpenStreetMap tiles عبر الإنترنت؛ يلزم اتصال إنترنت للوصول إلى
الخريطة، بينما يمكن أن يبقى WebSocket على عنوان LAN.
