# Tactical Platform Flutter Client

هذا عميل Flutter أولي مستقل يطابق `protocol` في جذر المستودع:

- يفتح WebSocket إلى الخادم.
- يرسل `HELLO` مع `device_id` و`name` و`team_id`.
- ينتظر `ACK` المطابق لمعرّف رسالة `HELLO`.
- يرسل أول `LOCATION` بعد نجاح المصافحة.
- يرسل ويستقبل `CHAT` و`POINT` و`SOS` ضمن الفريق.
- يبث كل الرسائل الواردة عبر `TacticalClient.messages`.
- يعرض مواقع الفريق الواردة على خريطة OpenStreetMap.
- يعرض نقاط الفريق كأعلام والتنبيهات النشطة كرموز تحذير.
- يطلب صلاحيات GPS ويشارك الموقع الحقيقي عبر `LOCATION` عند الضغط على `Share GPS`.

للتجربة المحلية شغّل الخادم على `8080` ثم:

```powershell
cd client
flutter pub get
flutter run
```

للتشغيل على الويب فعّل منصة Web أولًا إذا لزم:

```powershell
flutter create . --platforms web
flutter run -d chrome
```

العميل يملأ عنوان WebSocket تلقائيًا على الويب باستخدام نفس hostname الذي
فتحت منه صفحة Flutter، مع المنفذ `8080`. افتح أدوات الإعدادات وعدّل العنوان
إذا كان الخادم على جهاز آخر. غيّر العنوان إلى
`ws://<server-host>:8080` عند التشغيل من جهاز آخر على الشبكة. إذا كانت صفحة
الويب نفسها تعمل عبر HTTPS، استخدم
`wss://<server-host>:8080` خلف TLS؛ المتصفح يمنع `ws://` المختلط من صفحة HTTPS.
الخادم لا يحتاج CORS خاصًا لاتصال WebSocket، لكن يجب أن يكون المنفذ قابلًا
للوصول من المتصفح/الجهاز.

## GPS والمنصات

`geolocator` يطلب الصلاحية وقت التشغيل. على Android يجب إضافة
`android.permission.ACCESS_FINE_LOCATION` و`ACCESS_COARSE_LOCATION` إلى
`android/app/src/main/AndroidManifest.xml` (و`ACCESS_BACKGROUND_LOCATION` فقط
إذا أضيف تتبع بالخلفية لاحقًا). على Windows يعمل المزود عند توفر Windows
Location Service وصلاحية الموقع في إعدادات النظام؛ لا يتم طلب صلاحية Android
على Windows.

الخريطة تستخدم OpenStreetMap tiles عبر الإنترنت؛ يلزم اتصال إنترنت للوصول إلى
الخريطة، بينما يمكن أن يبقى WebSocket على عنوان LAN.
