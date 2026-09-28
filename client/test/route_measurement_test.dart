import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tactical_platform_client/route_measurement.dart';

void main() {
  test('returns zero until the route has two points', () {
    expect(calculateRouteDistanceMeters([]), 0);
    expect(calculateRouteDistanceMeters([const LatLng(0, 0)]), 0);
  });

  test('sums straight-line segments between all selected points', () {
    final route = [
      const LatLng(0, 0),
      const LatLng(0, 0.001),
      const LatLng(0, 0.002),
    ];

    expect(calculateRouteDistanceMeters(route), closeTo(222.4, 1));
  });
}
