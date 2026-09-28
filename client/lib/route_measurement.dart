import 'package:latlong2/latlong.dart';

double calculateRouteDistanceMeters(List<LatLng> points) {
  if (points.length < 2) return 0;
  final distance = Distance();
  var total = 0.0;
  for (var index = 1; index < points.length; index++) {
    total += distance.as(LengthUnit.Meter, points[index - 1], points[index]);
  }
  return total;
}
