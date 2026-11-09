class SpaceInvite {
  const SpaceInvite({required this.baseUri, required this.token});

  final Uri baseUri;
  final String token;

  String get url =>
      '${baseUri.toString()}#token=${Uri.encodeQueryComponent(token)}';

  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{20,128}$');

  static SpaceInvite parse(String value) {
    final input = value.trim();
    if (input.isEmpty) {
      throw const FormatException('请输入空间地址。');
    }

    final Uri uri;
    try {
      uri = Uri.parse(input);
    } on FormatException {
      throw const FormatException('空间地址格式不正确。');
    }

    if (uri.scheme != 'http' || !uri.hasAuthority) {
      throw const FormatException('空间地址必须使用 http。');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('空间地址不能包含用户信息。');
    }
    final String host;
    final int port;
    try {
      host = uri.host;
      port = uri.port;
    } on FormatException {
      throw const FormatException('空间地址格式不正确。');
    }
    if (!isSupportedLanIpv4(host)) {
      throw const FormatException('空间地址必须使用局域网 IPv4 地址。');
    }
    if (!uri.hasPort || port < 1 || port > 65535) {
      throw const FormatException('空间地址必须包含有效端口。');
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const FormatException('空间地址路径不正确。');
    }
    if (uri.hasQuery) {
      throw const FormatException('空间地址不能包含查询参数。');
    }

    final token = _parseToken(uri.fragment);
    final baseUri = Uri.parse('http://$host:$port/');
    return SpaceInvite(baseUri: baseUri, token: token);
  }

  static String _parseToken(String fragment) {
    final parts = fragment.split('&');
    if (parts.length != 1) {
      throw const FormatException('空间地址缺少有效令牌，请重新扫描。');
    }

    final separator = parts.single.indexOf('=');
    if (separator <= 0) {
      throw const FormatException('空间地址缺少有效令牌，请重新扫描。');
    }

    final String key;
    final String token;
    try {
      key = Uri.decodeQueryComponent(parts.single.substring(0, separator));
      token = Uri.decodeQueryComponent(parts.single.substring(separator + 1));
    } on FormatException {
      throw const FormatException('空间地址缺少有效令牌，请重新扫描。');
    }
    if (key != 'token' || !_tokenPattern.hasMatch(token)) {
      throw const FormatException('空间地址缺少有效令牌，请重新扫描。');
    }
    return token;
  }

  static bool isSupportedLanIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;

    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
      if (part.length > 1 && part.startsWith('0')) return false;
      final octet = int.tryParse(part);
      if (octet == null || octet > 255) return false;
      octets.add(octet);
    }

    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }
}
