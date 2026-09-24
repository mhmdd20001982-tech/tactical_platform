import 'package:flutter_test/flutter_test.dart';
import 'package:tactical_platform_client/main.dart';

void main() {
  testWidgets('renders the map client shell', (tester) async {
    await tester.pumpWidget(const TacticalPlatformApp());
    expect(find.text('Tactical Platform'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
