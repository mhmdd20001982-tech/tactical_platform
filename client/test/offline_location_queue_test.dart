import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tactical_platform_client/offline_location_queue.dart';

void main() {
  final now = DateTime.utc(2026, 9, 28, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  QueuedLocation location(String id, DateTime recordedAt) => QueuedLocation(
        queueId: id,
        latitude: 31.9,
        longitude: 35.8,
        deviceName: 'test-device',
        recordedAt: recordedAt,
        accuracy: 4,
      );

  test('expires locations after 24 hours and drops oldest over capacity',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final queue = OfflineLocationQueue(
      preferences: preferences,
      clock: () => now,
      maxLocations: 3,
    );

    await queue.enqueue(location(
        'expired',
        now.subtract(const Duration(
          hours: 25,
        ))));
    for (var index = 1; index <= 4; index++) {
      await queue.enqueue(location(
        'location-$index',
        now.subtract(Duration(minutes: 5 - index)),
      ));
    }

    expect(
      (await queue.read()).map((item) => item.queueId),
      ['location-2', 'location-3', 'location-4'],
    );
  });

  test('persists locations and removes only the acknowledged item', () async {
    final preferences = await SharedPreferences.getInstance();
    final queue = OfflineLocationQueue(
      preferences: preferences,
      clock: () => now,
    );
    await queue.enqueue(location('first', now));
    await queue.enqueue(location('second', now));

    final restoredQueue = OfflineLocationQueue(
      preferences: preferences,
      clock: () => now,
    );
    await restoredQueue.remove('first');
    final remaining = await restoredQueue.read();
    expect(remaining.map((item) => item.queueId), ['second']);
    expect(remaining.single.accuracy, 4);
  });
}
