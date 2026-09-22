# تشغيل الخادم

## محليًا وضمن LAN

```powershell
npm run install:all
Copy-Item server/.env.example server/.env
npm run build
node server/dist/server.js
```

افتح `http://localhost:8080/health`. للوصول من جهاز آخر على الشبكة، اترك `HOST=0.0.0.0` وافتح المنفذ 8080 في جدار الحماية، ثم استخدم عنوان الجهاز المحلي.

## على الإنترنت

شغّل الخادم خلف reverse proxy ينهي TLS، ووجّه WebSocket إلى نفس المنفذ. استخدم `wss://` بدل `ws://`. لا تعتبر `sender_id` مصادقة؛ إضافة token validation في handshake مطلوبة قبل الإنتاج العام.

الحالة الحالية داخل الذاكرة عمدًا لتثبيت العقد وسلوك الجلسات. التخزين الدائم، التوسع الأفقي، وpub/sub مراحل لاحقة.
