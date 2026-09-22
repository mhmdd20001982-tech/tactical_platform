import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

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
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        home: const ClientHomePage(),
      );
}

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({super.key});

  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  final _urlController = TextEditingController(text: 'ws://127.0.0.1:8080');
  final _teamController = TextEditingController(text: 'demo-team');
  final _deviceController = TextEditingController(text: 'flutter-device-1');
  final _nameController = TextEditingController(text: 'Flutter Client');
  final _mapController = MapController();
  final _locationService = LocationService();
  final Map<String, TeamLocation> _locations = {};
  TacticalClient? _client;
  StreamSubscription<ProtocolMessage>? _messageSubscription;
  StreamSubscription<Position>? _locationSubscription;
  String _status = 'Disconnected';
  bool _sharing = false;
  LatLng _mapCenter = const LatLng(31.95, 35.91);

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _messageSubscription?.cancel();
    _client?.dispose();
    for (final controller in [
      _urlController,
      _teamController,
      _deviceController,
      _nameController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    await _disconnect();
    final client = TacticalClient(
      serverUri: Uri.parse(_urlController.text.trim()),
      deviceId: _deviceController.text.trim(),
      deviceName: _nameController.text.trim(),
      teamId: _teamController.text.trim(),
    );
    _client = client;
    _messageSubscription = client.messages.listen(_receiveMessage);
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
    await _client?.dispose();
    _client = null;
    if (mounted) setState(() => _status = 'Disconnected');
  }

  void _receiveMessage(ProtocolMessage message) {
    if (message.type != 'LOCATION') return;
    try {
      final location = TeamLocation.fromMessage(message);
      if (!mounted) return;
      setState(() => _locations[location.deviceId] = location);
      if (location.deviceId == _deviceController.text.trim()) {
        _moveMap(location.latitude, location.longitude);
      }
    } on FormatException {
      // The protocol client has already validated the envelope; ignore an
      // invalid domain payload rather than putting a bad marker on the map.
    }
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
        client.sendLocation(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
        );
        final location = TeamLocation(
          deviceId: client.deviceId,
          latitude: position.latitude,
          longitude: position.longitude,
          recordedAt: position.timestamp,
          accuracy: position.accuracy,
        );
        setState(() => _locations[location.deviceId] = location);
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
                MarkerLayer(
                  markers: _locations.values
                      .map(
                        (location) => Marker(
                          point: LatLng(location.latitude, location.longitude),
                          width: 48,
                          height: 48,
                          child: Tooltip(
                            message: '${location.deviceId}\n${location.recordedAt}',
                            child: const Icon(Icons.location_pin, color: Colors.red, size: 42),
                          ),
                        ),
                      )
                      .toList(),
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
                        onPressed: _client?.isConnected == true ? _toggleSharing : _connect,
                        child: Text(_client?.isConnected == true
                            ? (_sharing ? 'Stop GPS' : 'Share GPS')
                            : 'Connect'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.urlController,
    required this.teamController,
    required this.deviceController,
    required this.nameController,
    required this.onConnect,
    required this.onDisconnect,
  });

  final TextEditingController urlController;
  final TextEditingController teamController;
  final TextEditingController deviceController;
  final TextEditingController nameController;
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
            Text('Connection settings', style: Theme.of(context).textTheme.titleLarge),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: 'WebSocket URL')),
            TextField(controller: teamController, decoration: const InputDecoration(labelText: 'Team ID')),
            TextField(controller: deviceController, decoration: const InputDecoration(labelText: 'Device ID')),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Device name')),
            Row(
              children: [
                FilledButton(onPressed: onConnect, child: const Text('Connect')),
                const SizedBox(width: 12),
                OutlinedButton(onPressed: onDisconnect, child: const Text('Disconnect')),
              ],
            ),
          ],
        ),
      );
}
