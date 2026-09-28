import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class QueuedLocation {
  const QueuedLocation({
    required this.queueId,
    required this.latitude,
    required this.longitude,
    required this.deviceName,
    required this.recordedAt,
    this.accuracy,
  });

  final String queueId;
  final double latitude;
  final double longitude;
  final String deviceName;
  final DateTime recordedAt;
  final double? accuracy;

  Map<String, dynamic> toJson() => {
        'queue_id': queueId,
        'latitude': latitude,
        'longitude': longitude,
        'device_name': deviceName,
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        if (accuracy != null) 'accuracy': accuracy,
      };

  factory QueuedLocation.fromJson(Map<String, dynamic> json) {
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final queueId = json['queue_id'];
    final deviceName = json['device_name'];
    final recordedAt = json['recorded_at'];
    final accuracy = json['accuracy'];
    if (latitude is! num ||
        longitude is! num ||
        queueId is! String ||
        deviceName is! String ||
        recordedAt is! num ||
        (accuracy != null && accuracy is! num)) {
      throw const FormatException('Invalid queued GPS location');
    }
    return QueuedLocation(
      queueId: queueId,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      deviceName: deviceName,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(recordedAt.toInt()),
      accuracy: (accuracy as num?)?.toDouble(),
    );
  }
}

class OfflineLocationQueue {
  OfflineLocationQueue({
    required SharedPreferences preferences,
    DateTime Function()? clock,
    this.maxLocations = 1000,
    this.maxAge = const Duration(hours: 24),
  })  : _preferences = preferences,
        _clock = clock ?? DateTime.now {
    if (maxLocations <= 0 || maxAge <= Duration.zero) {
      throw ArgumentError('Queue limits must be positive');
    }
  }

  static const _storageKey = 'offline_gps_queue_v1';
  final SharedPreferences _preferences;
  final DateTime Function() _clock;
  final int maxLocations;
  final Duration maxAge;
  Future<void> _serial = Future<void>.value();

  Future<List<QueuedLocation>> read() => _run(() async => _read());

  Future<List<QueuedLocation>> _read() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Queued locations must be a list');
      }
      final locations = decoded.map((value) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid queued GPS location');
        }
        return QueuedLocation.fromJson(value);
      }).toList(growable: true);
      final originalIds =
          locations.map((location) => location.queueId).toList();
      final originalLength = locations.length;
      final retained = _removeExpiredAndExcess(locations);
      final orderChanged = originalIds.length != retained.length ||
          List.generate(
            retained.length,
            (index) => originalIds[index] != retained[index].queueId,
          ).any((changed) => changed);
      if (originalLength != retained.length || orderChanged) {
        await _save(retained);
      }
      return retained;
    } on FormatException {
      await _preferences.remove(_storageKey);
      rethrow;
    }
  }

  Future<void> enqueue(QueuedLocation location) => _run(() async {
        final locations = await _read();
        locations.add(location);
        _removeExpiredAndExcess(locations);
        await _save(locations);
      });

  Future<void> remove(String queueId) => _run(() async {
        final locations = await _read();
        locations.removeWhere((location) => location.queueId == queueId);
        await _save(locations);
      });

  Future<void> clear() => _run(() => _preferences.remove(_storageKey));

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  List<QueuedLocation> _removeExpiredAndExcess(
    List<QueuedLocation> locations,
  ) {
    final cutoff = _clock().subtract(maxAge);
    locations.removeWhere((location) => location.recordedAt.isBefore(cutoff));
    locations.sort((first, second) {
      final timeOrder = first.recordedAt.compareTo(second.recordedAt);
      return timeOrder != 0
          ? timeOrder
          : first.queueId.compareTo(second.queueId);
    });
    if (locations.length > maxLocations) {
      locations.removeRange(0, locations.length - maxLocations);
    }
    return locations;
  }

  Future<void> _save(List<QueuedLocation> locations) async {
    if (locations.isEmpty) {
      await _preferences.remove(_storageKey);
      return;
    }
    await _preferences.setString(
      _storageKey,
      jsonEncode(locations.map((location) => location.toJson()).toList()),
    );
  }
}
