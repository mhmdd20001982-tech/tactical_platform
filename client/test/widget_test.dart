import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tactical_platform_client/main.dart';

void main() {
  testWidgets('renders the map client shell', (tester) async {
    await tester.pumpWidget(const TacticalPlatformApp());
    expect(find.text('Tactical Platform'), findsOneWidget);
    expect(find.text('إعداد م. محمد ذنيبات'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('opens chat history while disconnected', (tester) async {
    await tester.pumpWidget(const TacticalPlatformApp());
    await tester.tap(find.byTooltip('Team chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Team chat'), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('Connect to send a message'), findsOneWidget);
  });

  testWidgets('shows arbitrary map point action but disables it offline',
      (tester) async {
    await tester.pumpWidget(const TacticalPlatformApp());
    final mapPointButton = tester.widget<FloatingActionButton>(
      find.ancestor(
        of: find.byTooltip('Choose point on map'),
        matching: find.byType(FloatingActionButton),
      ),
    );

    expect(mapPointButton.onPressed, isNull);
  });
}
