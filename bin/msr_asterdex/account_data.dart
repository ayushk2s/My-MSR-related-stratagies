import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// ASTERDEX Futures account utilities (v1 REST API — HMAC SHA256 auth).
/// Auth is identical to Binance Futures:
///   - Header:  `X-MBX-APIKEY: apiKey`
///   - Param:   timestamp + signature = HMAC_SHA256(queryString, secretKey)
class AsterdexFutureFunctions {
  static const String _baseUrl = 'https://fapi.asterdex.com';

  // ─── HMAC-SHA256 signing ────────────────────────────────────────

  static String _sign(String query, String secretKey) {
    final keyBytes = utf8.encode(secretKey);
    final msgBytes = utf8.encode(query);
    return Hmac(sha256, keyBytes).convert(msgBytes).toString();
  }

  static Map<String, String> _headers(String apiKey) => {
        'X-MBX-APIKEY': apiKey,
        'Content-Type': 'application/json',
      };

  // ─── Signed GET ─────────────────────────────────────────────────

  static Future<dynamic> _signedGet(
    String path,
    String apiKey,
    String secretKey, [
    Map<String, String> extra = const {},
  ]) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final params = {...extra, 'timestamp': ts.toString()};

    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    final signature = _sign(query, secretKey);
    final uri = Uri.parse('$_baseUrl$path?$query&signature=$signature');

    final res = await http.get(uri, headers: _headers(apiKey));
    if (res.statusCode != 200) {
      throw Exception('Asterdex GET $path failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body);
  }

  // ─── PUBLIC: get available balance in USD terms ────────────────

  /// Returns available balance converted to USD equivalent.
  static Future<double> getAvailableBalance(String apiKey, String secretKey) async {
    final data = await _signedGet('/fapi/v1/balance', apiKey, secretKey);

    if (data is List) {
      double usdt = 0.0;
      double eth  = 0.0;

      for (final item in data) {
        final raw = item['withdrawAvailable'] ?? item['balance'];
        if (raw == null) continue;
        final val = double.tryParse(raw.toString()) ?? 0.0;
        if (item['asset'] == 'USDT') usdt = val;
        if (item['asset'] == 'ETH')  eth  = val;
      }

      // Total collateral = USDT + ETH converted to USD
      if (eth > 0) {
        final ethPrice = await _getEthPrice();
        final total = usdt + eth * ethPrice;
        print('[BALANCE] USDT=${usdt.toStringAsFixed(2)}  ETH=${eth.toStringAsFixed(4)} × ${ethPrice.toStringAsFixed(2)} = \$${total.toStringAsFixed(2)}');
        return total;
      }
      if (usdt > 0) return usdt;
      throw Exception('No positive balance found in balance list');
    }

    if (data is Map && (data.containsKey('withdrawAvailable') || data.containsKey('availableBalance'))) {
      final raw = data['withdrawAvailable'] ?? data['availableBalance'];
      return double.parse(raw.toString());
    }

    throw Exception('Unexpected balance response: $data');
  }

  /// Fetches current ETH/USDT price from Asterdex.
  static Future<double> _getEthPrice() async {
    final uri = Uri.parse('$_baseUrl/fapi/v1/ticker/price?symbol=ETHUSDT');
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      final json = jsonDecode(res.body);
      return double.parse(json['price'].toString());
    }
    // Fallback: fetch from Binance
    final binanceUri = Uri.parse('https://fapi.binance.com/fapi/v1/ticker/price?symbol=ETHUSDT');
    final binanceRes = await http.get(binanceUri);
    if (binanceRes.statusCode == 200) {
      final json = jsonDecode(binanceRes.body);
      return double.parse(json['price'].toString());
    }
    throw Exception('Could not fetch ETH price');
  }

  // ─── Set leverage ───────────────────────────────────────────────

  /// Set cross leverage for [symbol]. Call once at startup.
  static Future<void> setLeverage(
    String symbol,
    int leverage,
    String apiKey,
    String secretKey,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final body = 'symbol=$symbol&leverage=$leverage&timestamp=$ts';
    final signature = _sign(body, secretKey);
    final fullBody = '$body&signature=$signature';

    final uri = Uri.parse('$_baseUrl/fapi/v1/leverage');
    final res = await http.post(
      uri,
      headers: {
        'X-MBX-APIKEY': apiKey,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: fullBody,
    );

    if (res.statusCode != 200) {
      throw Exception('setLeverage failed (${res.statusCode}): ${res.body}');
    }
    print('[ASTERDEX] Leverage set to ${leverage}x for $symbol: ${res.body}');
  }

  // ─── Get quantity precision from exchange info ──────────────────

  /// Returns the number of decimal places allowed for [symbol] quantities.
  /// Reads the LOT_SIZE stepSize from /fapi/v1/exchangeInfo.
  /// e.g. stepSize="1" → 0,  "0.1" → 1,  "0.01" → 2
  static Future<int> getQuantityPrecision(String symbol) async {
    final uri = Uri.parse('$_baseUrl/fapi/v1/exchangeInfo');
    final res = await http.get(uri, headers: {'Content-Type': 'application/json'});
    if (res.statusCode != 200) {
      throw Exception('exchangeInfo failed (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body);
    final symbols = data['symbols'] as List<dynamic>? ?? [];
    for (final s in symbols) {
      if (s['symbol'] == symbol) {
        final filters = s['filters'] as List<dynamic>? ?? [];
        for (final f in filters) {
          if (f['filterType'] == 'LOT_SIZE') {
            return _stepSizeToPrecision(f['stepSize'].toString());
          }
        }
      }
    }
    throw Exception('LOT_SIZE filter not found for $symbol in exchangeInfo');
  }

  static int _stepSizeToPrecision(String stepSize) {
    if (!stepSize.contains('.')) return 0;
    final decimal = stepSize.split('.')[1].replaceAll(RegExp(r'0+$'), '');
    return decimal.isEmpty ? 0 : decimal.length;
  }

  // ─── Get open positions ─────────────────────────────────────────

  static Future<List<dynamic>> getOpenPositions(
    String symbol,
    String apiKey,
    String secretKey,
  ) async {
    final data = await _signedGet(
      '/fapi/v1/positionRisk',
      apiKey,
      secretKey,
      {'symbol': symbol},
    );
    return data is List ? data : [];
  }
}
