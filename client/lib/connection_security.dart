bool canUseWebSocketUri(Uri uri) {
  if (uri.host.isEmpty || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
    return false;
  }
  return uri.scheme == 'wss' || _isLocalNetworkHost(uri.host);
}

bool _isLocalNetworkHost(String rawHost) {
  final host = rawHost.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return true;
  }
  if (host.contains(':')) {
    return host == '::1' ||
        host.startsWith('fc') ||
        host.startsWith('fd') ||
        host.startsWith('fe80:');
  }

  final octets = host.split('.');
  if (octets.length != 4) return false;
  final address = octets.map(int.tryParse).toList();
  if (address.any((octet) => octet == null || octet < 0 || octet > 255)) {
    return false;
  }
  final first = address[0]!;
  final second = address[1]!;
  return first == 10 ||
      first == 127 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}
