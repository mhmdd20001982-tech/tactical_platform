import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';

import 'location_models.dart';
import 'location_service.dart';
import 'protocol.dart';
import 'tactical_client.dart';

void main() => runApp(const TacticalPlatformApp());

class TacticalPlatformApp extends StatelessWidget {
  const TacticalPlatformApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tactical Platform',
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        home: const ClientHomePage(),
      );
}

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({super.key});

  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  late final TextEditingController _urlController =
      TextEditingController(text: _defaultWebSocketUrl());
  final _teamController = TextEditingController(text: 'demo-team');
  final _deviceController = TextEditingController(text: 'flutter-device-1');
  final _nameController = TextEditingController(text: 'Flutter Client');
  final _tokenController = TextEditingController();
  final _mapController = MapController();
  final _locationService = LocationService();
  final Map<String, TeamLocation> _locations = {};
  final Map<String, List<LatLng>> _trails = {};
  final Map<String, Map<String, dynamic>> _points = {};
  final Map<String, Map<String, dynamic>> _sosEvents = {};
  final List<Map<String, dynamic>> _chatMessages = [];
  final Set<String> _seenMessageIds = {};
  TacticalClient? _client;
  StreamSubscription<ProtocolMessage>? _messageSubscription;
  StreamSubscription<ClientConnectionState>? _connectionSubscription;
  StreamSubscription<Position>? _locationSubscription;
  String _status = 'Disconnected';
  bool _sharing = false;
  LatLng _mapCenter = const LatLng(31.95, 35.91);

  String _defaultWebSocketUrl() {
    if (!kIsWeb) return 'ws://127.0.0.1:8080';
    final base = Uri.base;
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(scheme: scheme, host: base.host, port: 8080).toString();
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    _client?.dispose();
    for (final controller in [
      _urlController,
      _teamController,
      _deviceController,
      _nameController,
      _tokenController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    await _disconnect();
    if (!mounted) return;
    setState(() {
      _locations.clear();
      _trails.clear();
      _points.clear();
      _sosEvents.clear();
      _chatMessages.clear();
      _seenMessageIds.clear();
    });
    final client = TacticalClient(
      serverUri: Uri.parse(_urlController.text.trim()),
      deviceId: _deviceController.text.trim(),
      deviceName: _nameController.text.trim(),
      teamId: _teamController.text.trim(),
      token: _tokenController.text.trim().isEmpty
          ? null
          : _tokenController.text.trim(),
    );
    _client = client;
    _messageSubscription = client.messages.listen(_receiveMessage);
    _connectionSubscription = client.connectionStates.listen((state) {
      if (!mounted) return;
      setState(() {
        _status = switch (state) {
          ClientConnectionState.disconnected => 'Disconnected',
          ClientConnectionState.connecting => 'Connecting...',
          ClientConnectionState.connected =>
            _sharing ? 'Sharing GPS location' : 'Connected',
          ClientConnectionState.reconnecting => 'Reconnecting...',
        };
      });
    });
    setState(() => _status = 'Connecting...');
    try {
      await client.connect();
      if (mounted) setState(() => _status = 'Connected');
    } catch (error) {
      if (mounted) setState(() => _status = 'Connection failed: $error');
    }
  }

  Future<void> _disconnect() async {
    await _stopSharing();
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _client?.dispose();
    _client = null;
    if (mounted) setState(() => _status = 'Disconnected');
  }

  void _receiveMessage(ProtocolMessage message) {
    if (!_seenMessageIds.add(message.id)) return;
    if (message.type == 'CHAT') {
      final text = message.payload['text'] as String? ?? '';
      if (!mounted) return;
      setState(
          () => _chatMessages.add({'sender': message.senderId, 'text': text}));
      if (message.payload['is_history'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${message.senderId}: $text')),
        );
      }
      return;
    }
    if (message.type == 'POINT') {
      final pointId = message.payload['point_id'] as String?;
      if (pointId == null) return;
      if (!mounted) return;
      setState(() => _points[pointId] = message.payload);
      return;
    }
    if (message.type == 'SOS') {
      final eventId = message.payload['event_id'] as String?;
      if (eventId == null) return;
      if (!mounted) return;
      setState(() => _sosEvents[eventId] = message.payload);
      return;
    }
    if (message.type != 'LOCATION') return;
    try {
      final location = TeamLocation.fromMessage(message);
      if (!mounted) return;
      setState(() {
        _locations[location.deviceId] = location;
        final trail = _trails.putIfAbsent(location.deviceId, () => <LatLng>[]);
        trail.add(LatLng(location.latitude, location.longitude));
        if (trail.length > 100) trail.removeAt(0);
      });
      if (location.deviceId == _deviceController.text.trim()) {
        _moveMap(location.latitude, location.longitude);
      }
    } on FormatException {
      // The protocol client has already validated the envelope; ignore an
      // invalid domain payload rather than putting a bad marker on the map.
    }
  }

  Future<void> _sendChat() async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    var draft = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Team chat'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_chatMessages.isNotEmpty)
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _chatMessages.length,
                    itemBuilder: (context, index) {
                      final message =
                          _chatMessages[_chatMessages.length - index - 1];
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '${message['sender']}: ${message['text']}',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              TextField(
                autofocus: true,
                onChanged: (value) => draft = value,
                decoration: const InputDecoration(labelText: 'Message'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, draft.trim()),
              child: const Text('Send')),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) client.sendChat(text);
  }

  Future<void> _sendPoint() async {
    final client = _client;
    final location = _locations[_deviceController.text.trim()];
    if (client == null || !client.isConnected || location == null) return;
    var draft = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add team point'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => draft = value,
          decoration: const InputDecoration(labelText: 'Point name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, draft.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      client.sendPoint(
          name: name,
          latitude: location.latitude,
          longitude: location.longitude);
    }
  }

  void _sendSos() {
    final client = _client;
    final location = _locations[_deviceController.text.trim()];
    if (client == null || !client.isConnected || location == null) return;
    final activeEvents =
        _sosEvents.values.where((event) => event['status'] == 'ACTIVE');
    final active = activeEvents.isEmpty ? null : activeEvents.first;
    client.sendSos(
      eventId: active?['event_id'] as String? ?? newMessageId(),
      status: active == null ? 'ACTIVE' : 'CANCELLED',
      latitude: location.latitude,
      longitude: location.longitude,
    );
  }

  Future<void> _toggleSharing() async {
    if (_sharing) {
      await _stopSharing();
      return;
    }
    final client = _client;
    if (client == null || !client.isConnected) {
      setState(() => _status = 'Connect before sharing location');
      return;
    }
    if (!await _locationService.ensurePermission()) {
      setState(() => _status = 'Location permission or service unavailable');
      return;
    }
    setState(() {
      _sharing = true;
      _status = 'Sharing GPS location';
    });
    _locationSubscription = _locationService.watch().listen(
      (position) {
        if (client.isConnected) {
          client.sendLocation(
            latitude: position.latitude,
            longitude: position.longitude,
            deviceName: client.deviceName,
            accuracy: position.accuracy,
          );
        }
        final location = TeamLocation(
          deviceId: client.deviceId,
          deviceName: client.deviceName,
          latitude: position.latitude,
          longitude: position.longitude,
          recordedAt: position.timestamp,
          accuracy: position.accuracy,
        );
        setState(() {
          _locations[location.deviceId] = location;
          final trail =
              _trails.putIfAbsent(location.deviceId, () => <LatLng>[]);
          trail.add(LatLng(location.latitude, location.longitude));
          if (trail.length > 100) trail.removeAt(0);
        });
        _moveMap(location.latitude, location.longitude);
      },
      onError: (Object error) {
        if (mounted) setState(() => _status = 'GPS error: $error');
      },
    );
  }

  Future<void> _stopSharing() async {
    await _locationSubscription?.cancel();
    _locationSubscription = null;
    if (mounted) {
      setState(() {
        _sharing = false;
        if (_client?.isConnected == true) _status = 'Connected';
      });
    }
  }

  void _moveMap(double latitude, double longitude) {
    final center = LatLng(latitude, longitude);
    _mapCenter = center;
    _mapController.move(center, _mapController.camera.zoom);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Tactical Platform'),
          actions: [
            IconButton(
              tooltip: 'Connection settings',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => _SettingsSheet(
                  urlController: _urlController,
                  teamController: _teamController,
                  deviceController: _deviceController,
                  nameController: _nameController,
                  tokenController: _tokenController,
                  onConnect: _connect,
                  onDisconnect: _disconnect,
                ),
              ),
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: _mapCenter, initialZoom: 13),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.tacticalplatform.client',
                ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
                PolylineLayer(
                  polylines: _trails.entries
                      .where((entry) => entry.value.length > 1)
                      .map(
                        (entry) => Polyline(
                          points: entry.value,
                          strokeWidth:
                              entry.key == _deviceController.text.trim()
                                  ? 5
                                  : 3,
                          color: entry.key == _deviceController.text.trim()
                              ? Colors.indigo
                              : Colors.orange,
                        ),
                      )
                      .toList(),
                ),
                MarkerLayer(
                  markers: [
                    ..._locations.values.map(
                      (location) => Marker(
                        point: LatLng(location.latitude, location.longitude),
                        width: 48,
                        height: 48,
                        child: Tooltip(
                          message:
                              '${location.deviceName}\n${location.deviceId}\n${location.recordedAt}',
                          child: const Icon(Icons.location_pin,
                              color: Colors.red, size: 42),
                        ),
                      ),
                    ),
                    ..._points.values.map((point) => Marker(
                          point: LatLng(point['latitude'] as double,
                              point['longitude'] as double),
                          width: 48,
                          height: 48,
                          child: Tooltip(
                            message: point['name'] as String,
                            child: const Icon(Icons.flag,
                                color: Colors.blue, size: 36),
                          ),
                        )),
                    ..._sosEvents.values
                        .where((event) => event['status'] == 'ACTIVE')
                        .map((event) => Marker(
                              point: LatLng(event['latitude'] as double,
                                  event['longitude'] as double),
                              width: 52,
                              height: 52,
                              child: const Icon(Icons.warning,
                                  color: Colors.red, size: 44),
                            )),
                  ],
                ),
              ],
            ),
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: Text(_status)),
                      FilledButton(
                        onPressed: _connectionAction(),
                        child: Text(_connectionActionLabel()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: _locations.isEmpty
                      ? const Text('No team locations received')
                      : Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: _locations.values
                              .map(
                                (location) => Chip(
                                  avatar: const Icon(Icons.person_pin_circle,
                                      size: 18),
                                  label: Text(
                                    '${location.deviceName} · ${_formatAge(location.recordedAt)}',
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 78,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'chat',
                    onPressed: _client?.isConnected == true ? _sendChat : null,
                    child: const Icon(Icons.chat),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'point',
                    onPressed: _client?.isConnected == true ? _sendPoint : null,
                    child: const Icon(Icons.flag),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'sos',
                    backgroundColor: Colors.red,
                    onPressed: _client?.isConnected == true ? _sendSos : null,
                    child: const Icon(Icons.warning),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  String _formatAge(DateTime timestamp) {
    final seconds = DateTime.now().difference(timestamp).inSeconds;
    if (seconds < 5) return 'online';
    if (seconds < 60) return '${seconds}s ago';
    return '${seconds ~/ 60}m ago';
  }

  VoidCallback? _connectionAction() {
    final client = _client;
    if (client == null || client.state == ClientConnectionState.disconnected) {
      return _connect;
    }
    if (client.state == ClientConnectionState.connecting ||
        client.state == ClientConnectionState.reconnecting) {
      return _disconnect;
    }
    return _toggleSharing;
  }

  String _connectionActionLabel() {
    final client = _client;
    if (client == null) return 'Connect';
    return switch (client.state) {
      ClientConnectionState.disconnected => 'Connect',
      ClientConnectionState.connecting => 'Cancel connection',
      ClientConnectionState.reconnecting => 'Cancel reconnect',
      ClientConnectionState.connected => _sharing ? 'Stop GPS' : 'Share GPS',
    };
  }
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.urlController,
    required this.teamController,
    required this.deviceController,
    required this.nameController,
    required this.tokenController,
    required this.onConnect,
    required this.onDisconnect,
  });

  final TextEditingController urlController;
  final TextEditingController teamController;
  final TextEditingController deviceController;
  final TextEditingController nameController;
  final TextEditingController tokenController;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Wrap(
          runSpacing: 12,
          children: [
            Text('Connection settings',
                style: Theme.of(context).textTheme.titleLarge),
            TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: 'WebSocket URL')),
            TextField(
                controller: teamController,
                decoration: const InputDecoration(labelText: 'Team ID')),
            TextField(
                controller: deviceController,
                decoration: const InputDecoration(labelText: 'Device ID')),
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Device name')),
            TextField(
              controller: tokenController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                  labelText: 'Server authentication token'),
            ),
            Row(
              children: [
                FilledButton(
                    onPressed: onConnect, child: const Text('Connect')),
                const SizedBox(width: 12),
                OutlinedButton(
                    onPressed: onDisconnect, child: const Text('Disconnect')),
              ],
            ),
          ],
        ),
      );
}
