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
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF176B5B),
            surface: const Color(0xFFF5F8F6),
          ),
          scaffoldBackgroundColor: const Color(0xFFF5F8F6),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF123B35),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: Color(0xFFE5F1EC),
            foregroundColor: Color(0xFF164F45),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF5F8F6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFDCE6E1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF176B5B), width: 2),
            ),
          ),
        ),
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
  final ValueNotifier<List<Map<String, String>>> _chatMessages =
      ValueNotifier([]);
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
    _chatMessages.dispose();
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
      _chatMessages.value = [];
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
      _chatMessages.value = [
        ..._chatMessages.value,
        {'sender': message.senderId, 'text': text},
      ];
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TeamChatSheet(
        messages: _chatMessages,
        canSend: _client?.isConnected == true,
        deviceId: _deviceController.text.trim(),
        connectionStates: _client?.connectionStates ??
            const Stream<ClientConnectionState>.empty(),
        onSend: (text) {
          final client = _client;
          if (client?.isConnected == true) client!.sendChat(text);
        },
      ),
    );
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Tactical Platform',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              Text(
                'إعداد م. محمد ذنيبات',
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          toolbarHeight: 68,
          actions: [
            IconButton(
              tooltip: 'Connection settings',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
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
              icon: const Icon(Icons.tune_rounded),
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
                color: Colors.white.withValues(alpha: 0.96),
                elevation: 5,
                shadowColor: const Color(0x33123B35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFE6ECE8)),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      _ConnectionIndicator(
                        connected: _client?.isConnected == true,
                        reconnecting: _client?.state ==
                            ClientConnectionState.reconnecting,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _status,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              'TEAM  ${_teamController.text.trim()}',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 11,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _connectionAction(),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
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
                color: Colors.white.withValues(alpha: 0.97),
                elevation: 5,
                shadowColor: const Color(0x33123B35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFE6ECE8)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.groups_2_rounded,
                              color: Color(0xFF176B5B), size: 19),
                          const SizedBox(width: 7),
                          const Text(
                            'TEAM MEMBERS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${_locations.length} tracked',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_locations.isEmpty)
                        Text(
                          'No team locations received',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          children: _locations.values.map((location) {
                            final online =
                                DateTime.now().difference(location.recordedAt) <
                                    const Duration(seconds: 30);
                            return Chip(
                              backgroundColor: const Color(0xFFF0F6F2),
                              side: const BorderSide(color: Color(0xFFDCE9E1)),
                              avatar: Icon(
                                Icons.person_pin_circle_rounded,
                                color: online
                                    ? const Color(0xFF16805D)
                                    : const Color(0xFF8B9690),
                                size: 19,
                              ),
                              label: Text(
                                '${location.deviceName} · ${_formatAge(location.recordedAt)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 105,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'chat',
                    tooltip: 'Team chat',
                    onPressed: _sendChat,
                    child: const Icon(Icons.forum_rounded),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'point',
                    tooltip: 'Add team point',
                    onPressed: _client?.isConnected == true ? _sendPoint : null,
                    child: const Icon(Icons.flag_rounded),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'sos',
                    tooltip: 'Send or cancel SOS',
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    onPressed: _client?.isConnected == true ? _sendSos : null,
                    child: const Icon(Icons.warning_amber_rounded),
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

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({
    required this.connected,
    required this.reconnecting,
  });

  final bool connected;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final color = connected
        ? const Color(0xFF16805D)
        : reconnecting
            ? const Color(0xFFE29B22)
            : const Color(0xFF9AA6A0);
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
        color: color,
        size: 21,
      ),
    );
  }
}

class _TeamChatSheet extends StatefulWidget {
  const _TeamChatSheet({
    required this.messages,
    required this.canSend,
    required this.deviceId,
    required this.connectionStates,
    required this.onSend,
  });

  final ValueListenable<List<Map<String, String>>> messages;
  final bool canSend;
  final String deviceId;
  final Stream<ClientConnectionState> connectionStates;
  final ValueChanged<String> onSend;

  @override
  State<_TeamChatSheet> createState() => _TeamChatSheetState();
}

class _TeamChatSheetState extends State<_TeamChatSheet> {
  final _messageController = TextEditingController();
  late bool _canSend;
  StreamSubscription<ClientConnectionState>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    _canSend = widget.canSend;
    _connectionSubscription = widget.connectionStates.listen((state) {
      if (mounted) {
        setState(() => _canSend = state == ClientConnectionState.connected);
      }
    });
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _messageController.text.trim();
    if (!_canSend || text.isEmpty) return;
    widget.onSend(text);
    _messageController.clear();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.forum_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Team chat',
                              style: Theme.of(context).textTheme.titleLarge),
                          Text(
                            'Messages are shared with your team',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    ValueListenableBuilder<List<Map<String, String>>>(
                      valueListenable: widget.messages,
                      builder: (context, messages, _) => Text(
                        '${messages.length}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, String>>>(
                    valueListenable: widget.messages,
                    builder: (context, messages, _) {
                      if (messages.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.mark_chat_unread_outlined,
                                  size: 44,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                              const SizedBox(height: 8),
                              const Text('No messages yet'),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        reverse: true,
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[messages.length - index - 1];
                          final isMine = message['sender'] == widget.deviceId;
                          final bubbleColor = isMine
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white;
                          return Align(
                            alignment: isMine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Card(
                              color: bubbleColor,
                              elevation: 1,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: isMine
                                      ? Colors.transparent
                                      : const Color(0xFFE3EAE6),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 9),
                                child: Column(
                                  crossAxisAlignment: isMine
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      message['sender'] ?? '',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: isMine
                                                ? Colors.white70
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                          ),
                                    ),
                                    Text(
                                      message['text'] ?? '',
                                      style: TextStyle(
                                        color: isMine
                                            ? Colors.white
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        enabled: _canSend,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          labelText: _canSend
                              ? 'Message'
                              : 'Connect to send a message',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Send message',
                      onPressed: _canSend ? _send : null,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
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
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.tune_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Text('Connection settings',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
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
