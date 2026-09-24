import 'dart:convert';

const protocolVersion = 1;

class ProtocolMessage {
  const ProtocolMessage({
    required this.type,
    required this.id,
    required this.senderId,
    required this.timestamp,
    required this.payload,
    this.teamId,
  });

  final String type;
  final String id;
  final String senderId;
  final int timestamp;
  final String? teamId;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': protocolVersion,
        'type': type,
        'id': id,
        'sender_id': senderId,
        'ts': timestamp,
        if (teamId != null) 'team_id': teamId,
        'payload': payload,
      };

  factory ProtocolMessage.fromJson(Map<String, dynamic> json) {
    if (json['v'] != protocolVersion) {
      throw const FormatException('Unsupported protocol version');
    }
    final type = json['type'];
    final id = json['id'];
    final senderId = json['sender_id'];
    final timestamp = json['ts'];
    final payload = json['payload'];
    if (type is! String ||
        id is! String ||
        senderId is! String ||
        timestamp is! num ||
        payload is! Map) {
      throw const FormatException('Invalid protocol message');
    }
    return ProtocolMessage(
      type: type,
      id: id,
      senderId: senderId,
      timestamp: timestamp.toInt(),
      teamId: json['team_id'] as String?,
      payload: Map<String, dynamic>.from(payload),
    );
  }

  String encode() => '${jsonEncode(toJson())}\n';
}

String newMessageId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_messageCounter++}';
int _messageCounter = 0;

ProtocolMessage helloMessage({
  required String deviceId,
  required String name,
  required String teamId,
  String? token,
}) =>
    ProtocolMessage(
      type: 'HELLO',
      id: newMessageId(),
      senderId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      teamId: teamId,
      payload: <String, dynamic>{
        'device_id': deviceId,
        'name': name,
        if (token != null) 'token': token,
      },
    );

ProtocolMessage locationMessage({
  required String deviceId,
  required String teamId,
  required double latitude,
  required double longitude,
  required String deviceName,
  double? accuracy,
}) =>
    ProtocolMessage(
      type: 'LOCATION',
      id: newMessageId(),
      senderId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      teamId: teamId,
      payload: <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
        'device_name': deviceName,
        'recorded_at': DateTime.now().millisecondsSinceEpoch,
        if (accuracy != null) 'accuracy': accuracy,
      },
    );

ProtocolMessage chatMessage({
  required String deviceId,
  required String teamId,
  required String text,
}) =>
    ProtocolMessage(
      type: 'CHAT',
      id: newMessageId(),
      senderId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      teamId: teamId,
      payload: <String, dynamic>{'text': text},
    );

ProtocolMessage pointMessage({
  required String deviceId,
  required String teamId,
  required String pointId,
  required String name,
  required double latitude,
  required double longitude,
  String? description,
}) =>
    ProtocolMessage(
      type: 'POINT',
      id: newMessageId(),
      senderId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      teamId: teamId,
      payload: <String, dynamic>{
        'point_id': pointId,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );

ProtocolMessage sosMessage({
  required String deviceId,
  required String teamId,
  required String eventId,
  required String status,
  required double latitude,
  required double longitude,
}) =>
    ProtocolMessage(
      type: 'SOS',
      id: newMessageId(),
      senderId: deviceId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      teamId: teamId,
      payload: <String, dynamic>{
        'event_id': eventId,
        'status': status,
        'latitude': latitude,
        'longitude': longitude,
      },
    );
