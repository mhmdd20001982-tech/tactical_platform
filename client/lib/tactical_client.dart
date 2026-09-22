import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

enum ClientConnectionState { disconnected, connecting, connected }

class TacticalClient {
  TacticalClient({
    required this.serverUri,
    required this.deviceId,
    required this.deviceName,
    required this.teamId,
    this.token,
  });

  final Uri serverUri;
  final String deviceId;
  final String deviceName;
  final String teamId;
  final String? token;

  final _messages = StreamController<ProtocolMessage>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  String? _helloId;
  ClientConnectionState _state = ClientConnectionState.disconnected;

  Stream<ProtocolMessage> get messages => _messages.stream;
  ClientConnectionState get state => _state;
  bool get isConnected => _state == ClientConnectionState.connected;

  Future<void> connect({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_state != ClientConnectionState.disconnected) return;
    _state = ClientConnectionState.connecting;
    final channel = WebSocketChannel.connect(serverUri);
    _channel = channel;
    final hello = helloMessage(
      deviceId: deviceId,
      name: deviceName,
      teamId: teamId,
      token: token,
    );
    _helloId = hello.id;
    final acknowledged = Completer<void>();
    _subscription = channel.stream.listen(
      (raw) {
        final message = ProtocolMessage.fromJson(
          jsonDecode(raw as String) as Map<String, dynamic>,
        );
        if (message.type == 'ACK' &&
            message.payload['acked_message_id'] == _helloId &&
            !acknowledged.isCompleted) {
          acknowledged.complete();
          _state = ClientConnectionState.connected;
        }
        if (message.type == 'ERROR' && !acknowledged.isCompleted) {
          acknowledged.completeError(
            StateError(message.payload['message'] as String? ?? 'Handshake failed'),
          );
        }
        _messages.add(message);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!acknowledged.isCompleted) acknowledged.completeError(error, stackTrace);
        _state = ClientConnectionState.disconnected;
      },
      onDone: () {
        if (!acknowledged.isCompleted) {
          acknowledged.completeError(StateError('Connection closed during handshake'));
        }
        _state = ClientConnectionState.disconnected;
      },
    );
    try {
      // On Flutter Web, sending before the browser WebSocket reaches OPEN can
      // leave the HELLO queued without a useful error. Wait for the channel
      // handshake explicitly before writing the first protocol frame.
      await channel.ready.timeout(timeout);
      channel.sink.add(jsonEncode(hello.toJson()));
      await acknowledged.future.timeout(timeout);
    } on TimeoutException {
      await disconnect();
      throw StateError('WebSocket connection timed out: $serverUri');
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  void sendLocation({
    required double latitude,
    required double longitude,
    double? accuracy,
  }) {
    _ensureConnected();
    final message = locationMessage(
      deviceId: deviceId,
      teamId: teamId,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
    );
    _channel!.sink.add(jsonEncode(message.toJson()));
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _state = ClientConnectionState.disconnected;
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
  }

  void _ensureConnected() {
    if (!isConnected || _channel == null) {
      throw StateError('Client is not connected');
    }
  }
}
