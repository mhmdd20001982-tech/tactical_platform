# تشغيل الخادم

## محليًا وضمن LAN

```powershell
npm run install:all
Copy-Item server/.env.example server/.env
npm run build
node server/dist/server.js
```

افتح `http://localhost:8080/health`. للوصول من جهاز آخر على الشبكة، اترك `HOST=0.0.0.0` وافتح المنفذ 8080 في جدار الحماية، ثم استخدم عنوان الجهاز المحلي.

يعرض الخادم في Terminal سجلات الاتصال، قبول `HELLO`، ورسائل `LOCATION`
الواردة مع الجهاز والفريق والإحداثيات. ويظل `/health` هو الفحص المختصر
لعدد الأجهزة المتصلة.

## على الإنترنت

شغّل الخادم خلف reverse proxy ينهي TLS، ووجّه WebSocket إلى نفس المنفذ. استخدم `wss://` بدل `ws://`. لا تعتبر `sender_id` مصادقة؛ إضافة token validation في handshake مطلوبة قبل الإنتاج العام.

### حماية اتصال WebSocket

قبل فتح الخادم على الإنترنت، عيّن `AUTH_TOKEN` طويلًا وعشوائيًا في
`server/.env` وأدخل القيمة نفسها في إعداد **Server authentication token**
داخل التطبيق. يرفض الخادم مصافحة HELLO إذا كان الرمز مفقودًا أو غير مطابق.
لا تشارك الرمز ولا تضعه في Git أو في سجلات الخادم. إذا لم يُضبط المتغير،
يعمل الخادم دون مصادقة لتسهيل التطوير المحلي فقط.

### نفق تطوير مؤقت من Windows

يمكن استخدام Cloudflare Quick Tunnel لتجارب مؤقتة دون فتح منافذ الراوتر أو
إنشاء VPS. يبقى الكمبيوتر والخادم والنفق قيد التشغيل، ويتغير عنوان
`trycloudflare.com` عند إعادة تشغيل النفق. لا تستخدمه لبيانات حساسة أو
كاستضافة دائمة.

1. شغّل الخادم مع `AUTH_TOKEN` مضبوط في `server/.env`.
2. ثبّت `cloudflared` من صفحة Cloudflare الرسمية.
3. نفّذ `cloudflared tunnel --url http://localhost:8080`.
4. استخدم عنوان `https://...trycloudflare.com` الظاهر في الطرفية كـ
   `wss://...trycloudflare.com` في إعدادات التطبيق.

### Docker وHTTPS تلقائيًا

يتضمن المستودع `Dockerfile` و`docker-compose.yml` مع Caddy. يوجه Caddy
طلبات HTTP وWebSocket إلى الخادم الداخلي، ويصدر شهادة HTTPS تلقائيًا من
Let's Encrypt عندما يشير DNS للنطاق إلى الخادم وتكون المنافذ 80 و443 متاحة.

على خادم Linux أو VPS:

```bash
cp .env.example .env
# عدّل DOMAIN إلى اسم DNS عام مثل tactical.example.com
docker compose up -d --build
docker compose logs -f tactical-server
```

اختبر:

```text
https://<domain>/health
```

واضبط العميل على:

```text
wss://<domain>
```

لا تستخدم هذا الإعداد قبل إضافة مصادقة token وتخزين دائم مناسبين لبيئة
الإنتاج. لا تضع أسرارًا في Git أو داخل ملف Compose.

الحالة الحالية داخل الذاكرة عمدًا لتثبيت العقد وسلوك الجلسات. التخزين الدائم، التوسع الأفقي، وpub/sub مراحل لاحقة.
