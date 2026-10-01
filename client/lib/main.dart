import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_security.dart';
import 'location_models.dart';
import 'location_service.dart';
import 'offline_location_queue.dart';
import 'protocol.dart';
import 'route_measurement.dart';
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

class _ClientHomePageState extends State<ClientHomePage>
    with TickerProviderStateMixin {
  late final TextEditingController _urlController =
      TextEditingController(text: _defaultWebSocketUrl());
  final _teamController = TextEditingController(text: 'demo-team');
  late final TextEditingController _deviceController =
      TextEditingController(text: _defaultDeviceId());
  late final TextEditingController _nameController =
      TextEditingController(text: _defaultDeviceName());
  final _tokenController = TextEditingController();
  final _mapController = MapController();
  final _locationService = LocationService();
  final Map<String, TeamLocation> _locations = {};
  final Map<String, List<LatLng>> _trails = {};
  final Map<String, Map<String, dynamic>> _points = {};
  final Map<String, Map<String, dynamic>> _sosEvents = {};
  final ValueNotifier<List<Map<String, String>>> _chatMessages =
      ValueNotifier([]);
  final List<_ActivityEntry> _activity = [];
  final Set<String> _seenMessageIds = {};
  TacticalClient? _client;
  StreamSubscription<ProtocolMessage>? _messageSubscription;
  StreamSubscription<ClientConnectionState>? _connectionSubscription;
  StreamSubscription<Position>? _locationSubscription;
  Timer? _ageRefreshTimer;
  String _status = 'Disconnected';
  bool _sharing = false;
  bool _selectingMapPoint = false;
  bool _measuringDistance = false;
  bool _flushingLocations = false;
  OfflineLocationQueue? _offlineQueue;
  int _queuedLocationCount = 0;
  String? _queueError;
  String _activityQuery = '';
  final List<LatLng> _measurementPoints = [];
  int _queueIdCounter = 0;
  late Future<void> _queueInitialization;
  late final TabController _dashboardTabs;
  LatLng _mapCenter = const LatLng(31.95, 35.91);

  String _defaultWebSocketUrl() {
    if (!kIsWeb) return 'ws://127.0.0.1:8080';
    final base = Uri.base;
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(scheme: scheme, host: base.host, port: 8080).toString();
  }

  String _defaultDeviceId() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return 'windows-control-${DateTime.now().millisecondsSinceEpoch}';
    }
    return 'flutter-device-1';
  }

  String _defaultDeviceName() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return 'Windows Control Station';
    }
    return 'Flutter Client';
  }

  @override
  void initState() {
    super.initState();
    _queueInitialization = _initializeOfflineQueue();
    _dashboardTabs = TabController(length: 2, vsync: this);
    _ageRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initializeOfflineQueue() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final queue = OfflineLocationQueue(preferences: preferences);
      if (mounted) setState(() => _offlineQueue = queue);
      final locations = await queue.read();
      if (!mounted) return;
      setState(() {
        _offlineQueue = queue;
        _queuedLocationCount = locations.length;
        _queueError = null;
      });
      final client = _client;
      if (client?.isConnected == true) {
        unawaited(_flushLocationQueue(client!));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _queueError = 'GPS queue unavailable: $error');
      }
    }
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _ageRefreshTimer?.cancel();
    _dashboardTabs.dispose();
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
    final serverUri = Uri.tryParse(_urlController.text.trim());
    if (serverUri == null || !canUseWebSocketUri(serverUri)) {
      setState(() {
        _status =
            'Use wss:// for internet servers; ws:// is limited to local networks';
      });
      return;
    }
    setState(() {
      _locations.clear();
      _trails.clear();
      _points.clear();
      _sosEvents.clear();
      _activity.clear();
      _chatMessages.value = [];
      _seenMessageIds.clear();
    });
    final client = TacticalClient(
      serverUri: serverUri,
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
      if (state == ClientConnectionState.connected) {
        unawaited(_flushLocationQueue(client));
      }
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
      _recordActivity(
        message,
        title: 'Team message',
        details: text,
        icon: Icons.forum_rounded,
      );
      _chatMessages.value = [
        ..._chatMessages.value,
        {'sender': message.senderId, 'text': text},
      ];
      setState(() {});
      return;
    }
    if (message.type == 'POINT') {
      final pointId = message.payload['point_id'] as String?;
      if (pointId == null) return;
      if (!mounted) return;
      _recordActivity(
        message,
        title: 'Map point · ${message.payload['name'] ?? 'Unnamed'}',
        details: _coordinates(message.payload),
        icon: Icons.flag_rounded,
      );
      setState(() => _points[pointId] = message.payload);
      return;
    }
    if (message.type == 'SOS') {
      final eventId = message.payload['event_id'] as String?;
      if (eventId == null) return;
      if (!mounted) return;
      final active = message.payload['status'] == 'ACTIVE';
      _recordActivity(
        message,
        title: active ? 'SOS alert' : 'SOS cleared',
        details: _coordinates(message.payload),
        icon: active ? Icons.warning_rounded : Icons.check_circle_rounded,
      );
      setState(() => _sosEvents[eventId] = message.payload);
      return;
    }
    if (message.type != 'LOCATION') return;
    try {
      final location = TeamLocation.fromMessage(message);
      if (!mounted) return;
      _recordActivity(
        message,
        title: '${location.deviceName} location',
        details:
            '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}',
        icon: Icons.location_on_rounded,
        timestamp: location.recordedAt,
      );
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

  void _recordActivity(
    ProtocolMessage message, {
    required String title,
    required String details,
    required IconData icon,
    DateTime? timestamp,
  }) {
    _activity.insert(
      0,
      _ActivityEntry(
        senderId: message.senderId,
        title: title,
        details: details,
        icon: icon,
        timestamp:
            timestamp ?? DateTime.fromMillisecondsSinceEpoch(message.timestamp),
      ),
    );
    if (_activity.length > 200) _activity.removeRange(200, _activity.length);
  }

  String _coordinates(Map<String, dynamic> payload) {
    final latitude = payload['latitude'];
    final longitude = payload['longitude'];
    if (latitude is! num || longitude is! num) return '';
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
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
    await _promptAndSendPoint(
      LatLng(location.latitude, location.longitude),
    );
  }

  void _startMapPointSelection() {
    if (_client?.isConnected != true) return;
    setState(() {
      _measuringDistance = false;
      _selectingMapPoint = true;
    });
  }

  Future<void> _promptAndSendPoint(LatLng location) async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    var draft = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add team point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Coordinates: ${location.latitude.toStringAsFixed(6)}, '
              '${location.longitude.toStringAsFixed(6)}',
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: (value) => draft = value,
              decoration: const InputDecoration(labelText: 'Point name'),
            ),
          ],
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
    if (name != null && name.isNotEmpty && mounted && client.isConnected) {
      client.sendPoint(
          name: name,
          latitude: location.latitude,
          longitude: location.longitude);
    }
  }

  Future<void> _handleMapTap(LatLng location) async {
    if (_selectingMapPoint) {
      setState(() => _selectingMapPoint = false);
      await _promptAndSendPoint(location);
      return;
    }
    if (_measuringDistance) {
      setState(() => _measurementPoints.add(location));
    }
  }

  void _toggleDistanceMeasurement() {
    setState(() {
      _selectingMapPoint = false;
      if (_measuringDistance) {
        _measuringDistance = false;
      } else {
        _measurementPoints.clear();
        _measuringDistance = true;
      }
    });
  }

  void _clearDistanceMeasurement() {
    setState(() {
      _measuringDistance = false;
      _measurementPoints.clear();
    });
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
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
    await _queueInitialization;
    if (_offlineQueue == null) {
      if (mounted) {
        setState(() => _status = _queueError ?? 'GPS storage unavailable');
      }
      return;
    }
    setState(() {
      _sharing = true;
      _status = 'Sharing GPS location';
    });
    _locationSubscription = _locationService.watch().listen(
      (position) {
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
        unawaited(_queueAndFlushLocation(position, client));
      },
      onError: (Object error) {
        if (mounted) setState(() => _status = 'GPS error: $error');
      },
    );
  }

  Future<void> _queueAndFlushLocation(
    Position position,
    TacticalClient client,
  ) async {
    final queue = _offlineQueue;
    if (queue == null) {
      if (mounted) {
        setState(() => _queueError ??= 'Waiting for local GPS storage');
      }
      return;
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    final queued = QueuedLocation(
      queueId: '$now-${_queueIdCounter++}',
      latitude: position.latitude,
      longitude: position.longitude,
      deviceName: client.deviceName,
      recordedAt: position.timestamp,
      accuracy: position.accuracy,
    );
    try {
      await queue.enqueue(queued);
      if (mounted) {
        final current = await queue.read();
        setState(() {
          _queuedLocationCount = current.length;
          _queueError = null;
        });
      }
      await _flushLocationQueue(client);
    } catch (error) {
      if (mounted) {
        setState(() => _queueError = 'Could not store GPS location: $error');
      }
    }
  }

  Future<void> _flushLocationQueue(TacticalClient client) async {
    final queue = _offlineQueue;
    if (queue == null || _flushingLocations || !client.isConnected) return;
    _flushingLocations = true;
    String? syncError;
    try {
      while (mounted && identical(_client, client) && client.isConnected) {
        final locations = await queue.read();
        if (locations.isEmpty) break;
        final location = locations.first;
        try {
          await client.sendLocationAcknowledged(
            latitude: location.latitude,
            longitude: location.longitude,
            deviceName: location.deviceName,
            recordedAt: location.recordedAt,
            accuracy: location.accuracy,
          );
        } catch (error) {
          syncError = error.toString();
          break;
        }
        await queue.remove(location.queueId);
      }
      if (mounted) {
        final remaining = await queue.read();
        setState(() {
          _queuedLocationCount = remaining.length;
          _queueError = remaining.isEmpty
              ? null
              : syncError == null
                  ? 'Waiting to sync GPS'
                  : 'GPS sync paused: $syncError';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _queueError = 'Could not sync queued GPS: $error');
      }
    } finally {
      _flushingLocations = false;
    }
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
            if (MediaQuery.sizeOf(context).width >= 1120) ...[
              TextButton.icon(
                onPressed: _connectionAction(),
                icon: Icon(
                  _client?.isConnected == true
                      ? (_sharing
                          ? Icons.location_searching_rounded
                          : Icons.wifi_rounded)
                      : Icons.wifi_off_rounded,
                ),
                label: Text(_connectionActionLabel()),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
              IconButton(
                tooltip: 'Team chat',
                onPressed: _sendChat,
                icon: const Icon(Icons.forum_rounded),
              ),
            ],
            IconButton(
              tooltip: 'Connection settings',
              onPressed: _showConnectionSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 1120) {
              return _buildDesktopDashboard();
            }
            return Stack(
              children: [
                _buildMapCanvas(),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
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
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
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
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
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
                if (_selectingMapPoint || _measuringDistance)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 104,
                    child: Card(
                      color: Theme.of(context).colorScheme.primary,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                        child: Row(
                          children: [
                            Icon(
                              _selectingMapPoint
                                  ? Icons.touch_app_rounded
                                  : Icons.straighten_rounded,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _selectingMapPoint
                                    ? 'Tap the map to choose a team point'
                                    : _measurementPoints.length < 2
                                        ? 'Tap the map to add measurement points'
                                        : '${_measurementPoints.length} points · '
                                            '${_formatDistance(calculateRouteDistanceMeters(_measurementPoints))}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Finish map action',
                              onPressed: () => setState(() {
                                _selectingMapPoint = false;
                                _measuringDistance = false;
                              }),
                              icon:
                                  const Icon(Icons.check, color: Colors.white),
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 2,
                              children: _locations.values.map((location) {
                                final online = DateTime.now()
                                        .difference(location.recordedAt) <
                                    const Duration(seconds: 30);
                                return Chip(
                                  backgroundColor: const Color(0xFFF0F6F2),
                                  side: const BorderSide(
                                      color: Color(0xFFDCE9E1)),
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
                          if (_queuedLocationCount > 0 ||
                              _queueError != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  _queueError == null
                                      ? Icons.cloud_upload_outlined
                                      : Icons.info_outline,
                                  size: 16,
                                  color: const Color(0xFF9A5B00),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _queueError ??
                                        '$_queuedLocationCount GPS updates waiting to sync',
                                    style: const TextStyle(
                                      color: Color(0xFF805000),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
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
                        tooltip: 'Add point at my location',
                        onPressed:
                            _client?.isConnected == true ? _sendPoint : null,
                        child: const Icon(Icons.flag_rounded),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'map-point',
                        tooltip: 'Choose point on map',
                        backgroundColor: _selectingMapPoint
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        foregroundColor:
                            _selectingMapPoint ? Colors.white : null,
                        onPressed: _client?.isConnected == true
                            ? _startMapPointSelection
                            : null,
                        child: const Icon(Icons.add_location_alt_rounded),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'measure-distance',
                        tooltip: _measuringDistance
                            ? 'Finish distance measurement'
                            : 'Measure distance',
                        backgroundColor: _measuringDistance
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        foregroundColor:
                            _measuringDistance ? Colors.white : null,
                        onPressed: _toggleDistanceMeasurement,
                        child: Icon(
                          _measuringDistance
                              ? Icons.check_rounded
                              : Icons.straighten_rounded,
                        ),
                      ),
                      if (_measurementPoints.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'clear-measurement',
                          tooltip: 'Clear distance measurement',
                          onPressed: _clearDistanceMeasurement,
                          child: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'sos',
                        tooltip: 'Send or cancel SOS',
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        onPressed:
                            _client?.isConnected == true ? _sendSos : null,
                        child: const Icon(Icons.warning_amber_rounded),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );

  Future<void> _showConnectionSettings() async {
    final settings = _SettingsSheet(
      urlController: _urlController,
      teamController: _teamController,
      deviceController: _deviceController,
      nameController: _nameController,
      tokenController: _tokenController,
      onConnect: _connect,
      onDisconnect: _disconnect,
    );
    if (MediaQuery.sizeOf(context).width >= 1120) {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(width: 520, child: settings),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => settings,
    );
  }

  Widget _buildMapCanvas() => FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _mapCenter,
          initialZoom: 13,
          onTap: (_, location) => _handleMapTap(location),
        ),
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
            polylines: [
              ..._trails.entries.where((entry) => entry.value.length > 1).map(
                    (entry) => Polyline(
                      points: entry.value,
                      strokeWidth:
                          entry.key == _deviceController.text.trim() ? 5 : 3,
                      color: entry.key == _deviceController.text.trim()
                          ? Colors.indigo
                          : Colors.orange,
                    ),
                  ),
              if (_measurementPoints.length > 1)
                Polyline(
                  points: _measurementPoints,
                  strokeWidth: 4,
                  color: const Color(0xFF087F5B),
                ),
            ],
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
                    point: LatLng(
                      (point['latitude'] as num).toDouble(),
                      (point['longitude'] as num).toDouble(),
                    ),
                    width: 48,
                    height: 48,
                    child: Tooltip(
                      message: '${point['name']}\n'
                          '${(point['latitude'] as num).toDouble().toStringAsFixed(6)}, '
                          '${(point['longitude'] as num).toDouble().toStringAsFixed(6)}',
                      child:
                          const Icon(Icons.flag, color: Colors.blue, size: 36),
                    ),
                  )),
              ..._sosEvents.values
                  .where((event) => event['status'] == 'ACTIVE')
                  .map((event) => Marker(
                        point: LatLng(
                          (event['latitude'] as num).toDouble(),
                          (event['longitude'] as num).toDouble(),
                        ),
                        width: 52,
                        height: 52,
                        child: const Icon(Icons.warning,
                            color: Colors.red, size: 44),
                      )),
              ..._measurementPoints.asMap().entries.map((entry) => Marker(
                    point: entry.value,
                    width: 34,
                    height: 34,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFF087F5B),
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Colors.white, width: 2),
                        ),
                      ),
                      child: Text(
                        '${entry.key + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  )),
            ],
          ),
        ],
      );

  Widget _buildDesktopDashboard() => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            SizedBox(
              height: 92,
              child: Row(
                children: [
                  Expanded(
                    child: _DashboardMetricCard(
                      title: 'TEAM MEMBERS',
                      value: '${_locations.length}',
                      caption: 'devices reporting locations',
                      icon: Icons.groups_rounded,
                      color: const Color(0xFF176B5B),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DashboardMetricCard(
                      title: 'ACTIVE SOS',
                      value:
                          '${_sosEvents.values.where((event) => event['status'] == 'ACTIVE').length}',
                      caption: 'requires attention',
                      icon: Icons.warning_amber_rounded,
                      color: const Color(0xFFB42318),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DashboardMetricCard(
                      title: 'TEAM POINTS',
                      value: '${_points.length}',
                      caption: 'saved map markers',
                      icon: Icons.flag_rounded,
                      color: const Color(0xFF2957A4),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DashboardMetricCard(
                      title: 'CHAT MESSAGES',
                      value: '${_chatMessages.value.length}',
                      caption: 'retained team history',
                      icon: Icons.forum_rounded,
                      color: const Color(0xFF7541A6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 7,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Stack(
                        children: [
                          Positioned.fill(child: _buildMapCanvas()),
                          Positioned(
                            left: 14,
                            top: 14,
                            child: _DashboardMapToolbar(
                              selectingPoint: _selectingMapPoint,
                              measuring: _measuringDistance,
                              canSend: _client?.isConnected == true,
                              onAddPoint: _startMapPointSelection,
                              onMeasure: _toggleDistanceMeasurement,
                              onClearMeasurement: _clearDistanceMeasurement,
                              hasMeasurement: _measurementPoints.isNotEmpty,
                            ),
                          ),
                          if (_selectingMapPoint || _measuringDistance)
                            Positioned(
                              left: 14,
                              right: 14,
                              bottom: 14,
                              child: Card(
                                color: const Color(0xFF123B35),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _selectingMapPoint
                                              ? 'Click the map to place a team point'
                                              : _measurementPoints.length < 2
                                                  ? 'Click the map to add route points'
                                                  : '${_measurementPoints.length} points · '
                                                      '${_formatDistance(calculateRouteDistanceMeters(_measurementPoints))}',
                                          style: const TextStyle(
                                              color: Colors.white),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Finish map action',
                                        onPressed: () => setState(() {
                                          _selectingMapPoint = false;
                                          _measuringDistance = false;
                                        }),
                                        icon: const Icon(Icons.check_rounded,
                                            color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            right: 14,
                            bottom: 14,
                            child: FloatingActionButton.small(
                              heroTag: 'dashboard-center',
                              tooltip: 'Show team on map',
                              onPressed: _fitMapToTeam,
                              child: const Icon(Icons.center_focus_strong),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(width: 360, child: _buildDashboardSidePanel()),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildDashboardSidePanel() => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Material(
              color: Colors.white,
              child: TabBar(
                controller: _dashboardTabs,
                tabs: const [
                  Tab(icon: Icon(Icons.groups_rounded), text: 'Team'),
                  Tab(icon: Icon(Icons.history_rounded), text: 'Activity'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _dashboardTabs,
                children: [
                  _buildTeamOverview(),
                  _buildActivityFeed(),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildTeamOverview() {
    final members = _locations.values.toList()
      ..sort((first, second) => first.deviceName.toLowerCase().compareTo(
            second.deviceName.toLowerCase(),
          ));
    final activeEvents = _sosEvents.values
        .where((event) => event['status'] == 'ACTIVE')
        .toList();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _DashboardSectionHeader(
          title: 'Latest member locations',
          count: members.length,
        ),
        if (members.isEmpty)
          const _DashboardEmptyState(
            icon: Icons.location_searching_rounded,
            message: 'Connect to the team to load member locations.',
          )
        else
          ...members.map((location) {
            final isRecent = DateTime.now().difference(location.recordedAt) <
                const Duration(seconds: 30);
            return _DashboardMemberTile(
              name: location.deviceName,
              deviceId: location.deviceId,
              subtitle:
                  '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}',
              lastSeen: _formatAge(location.recordedAt),
              isRecent: isRecent,
              onTap: () => _moveMap(location.latitude, location.longitude),
            );
          }),
        const Divider(height: 28),
        _DashboardSectionHeader(
          title: 'Active SOS',
          count: activeEvents.length,
          warning: activeEvents.isNotEmpty,
        ),
        if (activeEvents.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, color: Color(0xFF16805D)),
                SizedBox(width: 8),
                Text('No active alerts'),
              ],
            ),
          )
        else
          ...activeEvents.map((event) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_rounded, color: Colors.red),
                title: Text('${event['event_id'] ?? 'SOS'}'),
                subtitle: Text(_coordinates(event)),
                onTap: () {
                  final latitude = (event['latitude'] as num?)?.toDouble();
                  final longitude = (event['longitude'] as num?)?.toDouble();
                  if (latitude != null && longitude != null) {
                    _moveMap(latitude, longitude);
                  }
                },
              )),
        const Divider(height: 28),
        _DashboardSectionHeader(title: 'Team points', count: _points.length),
        if (_points.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('No saved map points'),
          )
        else
          ..._points.entries.map((entry) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flag_rounded, color: Colors.blue),
                title: Text('${entry.value['name'] ?? entry.key}'),
                subtitle: Text(_coordinates(entry.value)),
                onTap: () {
                  final latitude =
                      (entry.value['latitude'] as num?)?.toDouble();
                  final longitude =
                      (entry.value['longitude'] as num?)?.toDouble();
                  if (latitude != null && longitude != null) {
                    _moveMap(latitude, longitude);
                  }
                },
              )),
        if (_queuedLocationCount > 0 || _queueError != null) ...[
          const Divider(height: 28),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_upload_outlined,
                color: Color(0xFF9A5B00)),
            title: Text(_queueError ?? 'GPS queue: $_queuedLocationCount'),
            subtitle: const Text('Pending updates on this computer'),
          ),
        ],
      ],
    );
  }

  Widget _buildActivityFeed() {
    final query = _activityQuery.trim().toLowerCase();
    final entries = _activity
        .where((entry) =>
            query.isEmpty ||
            entry.title.toLowerCase().contains(query) ||
            entry.details.toLowerCase().contains(query) ||
            entry.senderId.toLowerCase().contains(query))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              labelText: 'Filter recent activity',
            ),
            onChanged: (value) => setState(() => _activityQuery = value),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const _DashboardEmptyState(
                  icon: Icons.inbox_outlined,
                  message: 'No matching team activity yet.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(
                          entry.icon,
                          color: Theme.of(context).colorScheme.primary,
                          size: 19,
                        ),
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${entry.senderId}\n${entry.details}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        _formatAge(entry.timestamp),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _fitMapToTeam() {
    if (_locations.isEmpty) return;
    final points = _locations.values
        .map((location) => LatLng(location.latitude, location.longitude))
        .toList();
    if (points.length == 1) {
      _mapController.move(points.single, 14);
      return;
    }
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.all(80),
        maxZoom: 16,
      ),
    );
  }

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

class _ActivityEntry {
  const _ActivityEntry({
    required this.senderId,
    required this.title,
    required this.details,
    required this.icon,
    required this.timestamp,
  });

  final String senderId;
  final String title;
  final String details;
  final IconData icon;
  final DateTime timestamp;
}

class _DashboardMetricCard extends StatelessWidget {
  const _DashboardMetricCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                    Text(
                      value,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: color,
                                height: 1.1,
                              ),
                    ),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _DashboardMapToolbar extends StatelessWidget {
  const _DashboardMapToolbar({
    required this.selectingPoint,
    required this.measuring,
    required this.canSend,
    required this.onAddPoint,
    required this.onMeasure,
    required this.onClearMeasurement,
    required this.hasMeasurement,
  });

  final bool selectingPoint;
  final bool measuring;
  final bool canSend;
  final VoidCallback onAddPoint;
  final VoidCallback onMeasure;
  final VoidCallback onClearMeasurement;
  final bool hasMeasurement;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Wrap(
            spacing: 4,
            children: [
              IconButton(
                tooltip: 'Choose team point on map',
                onPressed: canSend ? onAddPoint : null,
                isSelected: selectingPoint,
                icon: const Icon(Icons.add_location_alt_rounded),
              ),
              IconButton(
                tooltip: measuring
                    ? 'Finish distance measurement'
                    : 'Measure distance',
                onPressed: onMeasure,
                isSelected: measuring,
                icon: Icon(
                  measuring ? Icons.check_rounded : Icons.straighten_rounded,
                ),
              ),
              if (hasMeasurement)
                IconButton(
                  tooltip: 'Clear distance measurement',
                  onPressed: onClearMeasurement,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
        ),
      );
}

class _DashboardSectionHeader extends StatelessWidget {
  const _DashboardSectionHeader({
    required this.title,
    this.count,
    this.warning = false,
  });

  final String title;
  final int? count;
  final bool warning;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (count != null)
            Badge(
              backgroundColor: warning ? Colors.red : null,
              label: Text('$count'),
            ),
        ],
      );
}

class _DashboardMemberTile extends StatelessWidget {
  const _DashboardMemberTile({
    required this.name,
    required this.deviceId,
    required this.subtitle,
    required this.lastSeen,
    required this.isRecent,
    required this.onTap,
  });

  final String name;
  final String deviceId;
  final String subtitle;
  final String lastSeen;
  final bool isRecent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor:
              isRecent ? const Color(0xFFE4F4EC) : const Color(0xFFEFF1EF),
          child: Icon(
            Icons.person_pin_circle_rounded,
            color: isRecent ? const Color(0xFF16805D) : Colors.grey,
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$deviceId\n$subtitle',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          lastSeen,
          style: TextStyle(
            color: isRecent ? const Color(0xFF16805D) : Colors.grey.shade700,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _DashboardEmptyState extends StatelessWidget {
  const _DashboardEmptyState({
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 42,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
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
