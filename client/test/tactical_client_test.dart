import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tactical_platform_client/tactical_client.dart';

void main() {
  test('reconnects after a dropped socket and stops retrying on disconnect',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var acceptedConnections = 0;
    final sockets = <WebSocket>[];
    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      acceptedConnections++;
      final connectionNumber = acceptedConnections;
      sockets.add(socket);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] != 'HELLO') return;
        socket.add(jsonEncode({
          'v': 1,
          'type': 'ACK',
          'id': 'ack-$connectionNumber',
          'sender_id': 'server',
          'ts': DateTime.now().millisecondsSinceEpoch,
          'team_id': 'test-team',
          'payload': {'acked_message_id': message['id']},
        }));
        if (connectionNumber == 1) {
          Timer(const Duration(milliseconds: 50), socket.close);
        }
      });
    });

    final client = TacticalClient(
      serverUri: Uri.parse('ws://127.0.0.1:${server.port}'),
      deviceId: 'device-test',
      deviceName: 'Test device',
      teamId: 'test-team',
      reconnectInitialDelay: const Duration(milliseconds: 50),
      reconnectMaxDelay: const Duration(milliseconds: 100),
    );
    final secondConnection = Completer<void>();
    var connectedEvents = 0;
    final stateSubscription = client.connectionStates.listen((state) {
      if (state == ClientConnectionState.connected) {
        connectedEvents++;
        if (connectedEvents == 2 && !secondConnection.isCompleted) {
          secondConnection.complete();
        }
      }
    });

    try {
      await client.connect();
      await secondConnection.future.timeout(const Duration(seconds: 3));
      expect(acceptedConnections, greaterThanOrEqualTo(2));
      expect(client.isConnected, isTrue);

      final reconnecting = client.connectionStates
          .firstWhere((state) => state == ClientConnectionState.reconnecting)
          .timeout(const Duration(seconds: 2));
      await sockets.last.close();
      await reconnecting;
      await client.disconnect();
      final connectionsAfterDisconnect = acceptedConnections;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(acceptedConnections, connectionsAfterDisconnect);
      expect(client.state, ClientConnectionState.disconnected);
    } finally {
      await client.dispose();
      await stateSubscription.cancel();
      for (final socket in sockets) {
        await socket.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}
