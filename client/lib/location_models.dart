import 'protocol.dart';

class TeamLocation {
  const TeamLocation({
    required this.deviceId,
    required this.deviceName,
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    this.accuracy,
  });

  final String deviceId;
  final String deviceName;
  final double latitude;
  final double longitude;
  final DateTime recordedAt;
  final double? accuracy;

  factory TeamLocation.fromMessage(ProtocolMessage message) {
    if (message.type != 'LOCATION') {
      throw const FormatException('Expected a LOCATION message');
    }
    final latitude = message.payload['latitude'];
    final longitude = message.payload['longitude'];
    final recordedAt = message.payload['recorded_at'];
    if (latitude is! num || longitude is! num || recordedAt is! num) {
      throw const FormatException('Invalid LOCATION payload');
    }
    return TeamLocation(
      deviceId: message.senderId,
      deviceName: message.payload['device_name'] as String? ?? message.senderId,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      recordedAt: DateTime.fromMillisecondsSinceEpoch(recordedAt.toInt()),
      accuracy: (message.payload['accuracy'] as num?)?.toDouble(),
    );
  }
}
