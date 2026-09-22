# Tactical Platform Protocol v1

كل رسالة هي JSON object. في النقل الخام تُفصل الرسائل بسطر جديد (`\n`)، وفي WebSocket تمثل كل رسالة frame واحدًا. الحد الأقصى للرسالة هو 1 MiB.

```json
{
  "v": 1,
  "type": "LOCATION",
  "id": "uuid",
  "sender_id": "device-1",
  "ts": 1730000000000,
  "team_id": "team-1",
  "payload": {
    "latitude": 31.95,
    "longitude": 35.91,
    "recorded_at": 1730000000000
  }
}
```

`HELLO` هو أول حدث، ويحتوي `payload.device_id` و`payload.name`، ويتطلب `team_id`. يرد الخادم بـ `ACK` مرتبط عبر `payload.acked_message_id`. بعد المصافحة تُرفض الرسائل التي لا تطابق هوية الجهاز أو الفريق في الجلسة.

الأنواع المدعومة في v1 هي `HELLO`, `ACK`, `PING`, `PONG`, `LOCATION`, `CHAT`, `POINT`, `SOS`, و`ERROR`. يتم التحقق من الإحداثيات، الحقول النصية، الحالة (`ACTIVE`/`CANCELLED`) وحدود الحجم قبل بث أي حدث.
