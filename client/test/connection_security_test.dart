import 'package:flutter_test/flutter_test.dart';
import 'package:tactical_platform_client/connection_security.dart';

void main() {
  test('allows WSS endpoints and local development WebSockets', () {
    expect(canUseWebSocketUri(Uri.parse('wss://team.example.com')), isTrue);
    expect(canUseWebSocketUri(Uri.parse('ws://localhost:8080')), isTrue);
    expect(canUseWebSocketUri(Uri.parse('ws://127.0.0.1:8080')), isTrue);
    expect(canUseWebSocketUri(Uri.parse('ws://192.168.1.25:8080')), isTrue);
    expect(canUseWebSocketUri(Uri.parse('ws://device.local:8080')), isTrue);
  });

  test('requires TLS for public hosts and rejects non-WebSocket URLs', () {
    expect(canUseWebSocketUri(Uri.parse('ws://team.example.com')), isFalse);
    expect(canUseWebSocketUri(Uri.parse('ws://8.8.8.8:8080')), isFalse);
    expect(
        canUseWebSocketUri(Uri.parse('ws://[2606:4700:4700::1111]')), isFalse);
    expect(canUseWebSocketUri(Uri.parse('https://team.example.com')), isFalse);
  });
}
