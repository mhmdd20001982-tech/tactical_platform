import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tactical_platform_client/location_models.dart';
import 'package:tactical_platform_client/protocol.dart';

void main() {
  test('creates a server-compatible HELLO message', () {
    final hello = helloMessage(
      deviceId: 'device-1',
      name: 'Test device',
      teamId: 'team-1',
    );
    final json = jsonDecode(hello.encode().trim()) as Map<String, dynamic>;
    expect(json['v'], 1);
    expect(json['type'], 'HELLO');
    expect(json['team_id'], 'team-1');
    expect(json['payload']['device_id'], 'device-1');
  });

  test('creates a validated LOCATION payload', () {
    final location = locationMessage(
      deviceId: 'device-1',
      teamId: 'team-1',
      latitude: 31.95,
      longitude: 35.91,
    );
    expect(location.type, 'LOCATION');
    expect(location.payload['latitude'], 31.95);
    expect(location.payload['longitude'], 35.91);
    expect(location.payload['recorded_at'], isA<int>());
  });

  test('parses the server ACK envelope', () {
    final ack = ProtocolMessage.fromJson({
      'v': 1,
      'type': 'ACK',
      'id': 'ack-1',
      'sender_id': 'server',
      'ts': 1,
      'team_id': 'team-1',
      'payload': {'acked_message_id': 'hello-1'},
    });
    expect(ack.payload['acked_message_id'], 'hello-1');
  });

  test('maps an inbound LOCATION message to a map location', () {
    final location = TeamLocation.fromMessage(
      ProtocolMessage.fromJson({
        'v': 1,
        'type': 'LOCATION',
        'id': 'loc-1',
        'sender_id': 'device-2',
        'ts': 1,
        'team_id': 'team-1',
        'payload': {
          'latitude': 31.95,
          'longitude': 35.91,
          'recorded_at': 1730000000000,
          'accuracy': 4.5,
        },
      }),
    );
    expect(location.deviceId, 'device-2');
    expect(location.latitude, 31.95);
    expect(location.longitude, 35.91);
    expect(location.accuracy, 4.5);
  });

  test('rejects non-location messages as map locations', () {
    expect(
      () => TeamLocation.fromMessage(
        ProtocolMessage.fromJson({
          'v': 1,
          'type': 'PING',
          'id': 'ping-1',
          'sender_id': 'device-2',
          'ts': 1,
          'payload': {},
        }),
      ),
      throwsFormatException,
    );
  });
}
