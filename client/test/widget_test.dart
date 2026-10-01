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

  testWidgets('opens distance measurement mode over the map', (tester) async {
    await tester.pumpWidget(const TacticalPlatformApp());
    await tester.tap(find.byTooltip('Measure distance'));
    await tester.pump();

    expect(find.text('Tap the map to add measurement points'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the Windows operations dashboard on wide screens',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TacticalPlatformApp());
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('TEAM MEMBERS'), findsOneWidget);
    expect(find.text('ACTIVE SOS'), findsOneWidget);
    expect(find.text('TEAM POINTS'), findsOneWidget);
    expect(find.text('CHAT MESSAGES'), findsOneWidget);
    expect(find.text('Latest member locations'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
