import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

enum ClientConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

class AuthenticationException extends StateError {
  AuthenticationException(super.message);
}

class TacticalClient {
  TacticalClient({
    required this.serverUri,
    required this.deviceId,
    required this.deviceName,
    required this.teamId,
    this.token,
    this.reconnectInitialDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 30),
  });

  final Uri serverUri;
  final String deviceId;
  final String deviceName;
  final String teamId;
  final String? token;
  final Duration reconnectInitialDelay;
  final Duration reconnectMaxDelay;

  final _messages = StreamController<ProtocolMessage>.broadcast();
  final _connectionStates = StreamController<ClientConnectionState>.broadcast();
  final Map<String, Completer<void>> _locationAcks = {};
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  ClientConnectionState _state = ClientConnectionState.disconnected;
  bool _reconnectEnabled = false;
  bool _hasConnected = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  Stream<ProtocolMessage> get messages => _messages.stream;
  Stream<ClientConnectionState> get connectionStates =>
      _connectionStates.stream;
  ClientConnectionState get state => _state;
  bool get isConnected => _state == ClientConnectionState.connected;

  Future<void> connect({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_state != ClientConnectionState.disconnected || _disposed) return;
    _reconnectEnabled = true;
    _setState(ClientConnectionState.connecting);
    try {
      await _openConnection(timeout: timeout);
      _hasConnected = true;
      _reconnectAttempt = 0;
      _setState(ClientConnectionState.connected);
    } catch (_) {
      _reconnectEnabled = false;
      await _closeCurrentChannel();
      _setState(ClientConnectionState.disconnected);
      rethrow;
    }
  }

  Future<void> _openConnection({
    required Duration timeout,
  }) async {
    final channel = WebSocketChannel.connect(serverUri);
    _channel = channel;
    final hello = helloMessage(
      deviceId: deviceId,
      name: deviceName,
      teamId: teamId,
      token: token,
    );
    final acknowledged = Completer<void>();
    _subscription = channel.stream.listen(
      (raw) {
        try {
          final message = ProtocolMessage.fromJson(
            jsonDecode(raw as String) as Map<String, dynamic>,
          );
          if (message.type == 'ACK' &&
              message.payload['acked_message_id'] == hello.id &&
              !acknowledged.isCompleted) {
            acknowledged.complete();
          }
          if (message.type == 'ACK') {
            final acknowledgedId =
                message.payload['acked_message_id'] as String?;
            final locationAck = _locationAcks.remove(acknowledgedId);
            if (locationAck != null && !locationAck.isCompleted) {
              locationAck.complete();
            }
          }
          if (message.type == 'ERROR' && !acknowledged.isCompleted) {
            final errorMessage =
                message.payload['message'] as String? ?? 'Handshake failed';
            if (message.payload['code'] == 'unauthorized') {
              acknowledged.completeError(AuthenticationException(errorMessage));
            } else {
              acknowledged.completeError(StateError(errorMessage));
            }
          }
          _messages.add(message);
        } catch (error, stackTrace) {
          if (!acknowledged.isCompleted) {
            acknowledged.completeError(error, stackTrace);
          } else if (!_messages.isClosed) {
            _messages.addError(error, stackTrace);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!acknowledged.isCompleted) {
          acknowledged.completeError(error, stackTrace);
        }
        _handleConnectionEnded(channel);
      },
      onDone: () {
        if (!acknowledged.isCompleted) {
          acknowledged.completeError(
            StateError('Connection closed during handshake'),
          );
        }
        _handleConnectionEnded(channel);
      },
      cancelOnError: true,
    );

    try {
      // On Flutter Web, sending before the browser WebSocket reaches OPEN can
      // leave the HELLO queued without a useful error. Wait for OPEN first.
      await channel.ready.timeout(timeout);
      channel.sink.add(jsonEncode(hello.toJson()));
      await acknowledged.future.timeout(timeout);
    } catch (_) {
      if (identical(_channel, channel)) {
        await _closeCurrentChannel();
      }
      rethrow;
    }
  }

  void _handleConnectionEnded(WebSocketChannel channel) {
    if (!identical(_channel, channel)) return;
    _channel = null;
    _subscription = null;
    _failPendingLocationAcks();
    _setState(ClientConnectionState.disconnected);
    if (_reconnectEnabled && _hasConnected && !_disposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null || !_reconnectEnabled || _disposed) return;
    _setState(ClientConnectionState.reconnecting);
    final multiplier = 1 << _reconnectAttempt.clamp(0, 10).toInt();
    final delay = reconnectInitialDelay * multiplier;
    _reconnectAttempt++;
    _reconnectTimer = Timer(
      delay > reconnectMaxDelay ? reconnectMaxDelay : delay,
      () => unawaited(_attemptReconnect()),
    );
  }

  Future<void> _attemptReconnect() async {
    _reconnectTimer = null;
    if (!_reconnectEnabled || _disposed) return;
    try {
      await _openConnection(timeout: const Duration(seconds: 5));
      _reconnectAttempt = 0;
      _setState(ClientConnectionState.connected);
    } on AuthenticationException {
      _reconnectEnabled = false;
      await _closeCurrentChannel();
      _setState(ClientConnectionState.disconnected);
    } catch (_) {
      await _closeCurrentChannel();
      if (_reconnectEnabled && !_disposed) _scheduleReconnect();
    }
  }

  void _setState(ClientConnectionState state) {
    if (_state == state) return;
    _state = state;
    if (!_connectionStates.isClosed) _connectionStates.add(state);
  }

  void sendLocation({
    required double latitude,
    required double longitude,
    required String deviceName,
    double? accuracy,
  }) {
    _ensureConnected();
    final message = locationMessage(
      deviceId: deviceId,
      teamId: teamId,
      latitude: latitude,
      longitude: longitude,
      deviceName: deviceName,
      accuracy: accuracy,
    );
    _channel!.sink.add(jsonEncode(message.toJson()));
  }

  Future<void> sendLocationAcknowledged({
    required double latitude,
    required double longitude,
    required String deviceName,
    required DateTime recordedAt,
    double? accuracy,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _ensureConnected();
    final message = locationMessage(
      deviceId: deviceId,
      teamId: teamId,
      latitude: latitude,
      longitude: longitude,
      deviceName: deviceName,
      accuracy: accuracy,
      recordedAt: recordedAt,
    );
    final acknowledgement = Completer<void>();
    _locationAcks[message.id] = acknowledgement;
    try {
      _channel!.sink.add(jsonEncode(message.toJson()));
      await acknowledgement.future.timeout(timeout);
    } finally {
      _locationAcks.remove(message.id);
    }
  }

  void sendChat(String text) {
    _ensureConnected();
    _channel!.sink.add(jsonEncode(chatMessage(
      deviceId: deviceId,
      teamId: teamId,
      text: text,
    ).toJson()));
  }

  void sendPoint({
    required String name,
    required double latitude,
    required double longitude,
    String? description,
  }) {
    _ensureConnected();
    _channel!.sink.add(jsonEncode(pointMessage(
      deviceId: deviceId,
      teamId: teamId,
      pointId: newMessageId(),
      name: name,
      latitude: latitude,
      longitude: longitude,
      description: description,
    ).toJson()));
  }

  void sendSos({
    required String eventId,
    required String status,
    required double latitude,
    required double longitude,
  }) {
    _ensureConnected();
    _channel!.sink.add(jsonEncode(sosMessage(
      deviceId: deviceId,
      teamId: teamId,
      eventId: eventId,
      status: status,
      latitude: latitude,
      longitude: longitude,
    ).toJson()));
  }

  Future<void> disconnect() async {
    _reconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeCurrentChannel();
    _hasConnected = false;
    _setState(ClientConnectionState.disconnected);
  }

  Future<void> _closeCurrentChannel() async {
    _failPendingLocationAcks();
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _failPendingLocationAcks() {
    final pending = _locationAcks.values.toList();
    _locationAcks.clear();
    for (final acknowledgement in pending) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(
          StateError('Connection closed before location acknowledgement'),
        );
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _messages.close();
    await _connectionStates.close();
  }

  void _ensureConnected() {
    if (!isConnected || _channel == null) {
      throw StateError('Client is not connected');
    }
  }
}
