// TODO Implement this library.import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

///Spots

Future<void> main() async {
  ///Trial Account Keys
  const String apiKey = 'YOUR_MEXC_API_KEY';
  const String secretKey = 'YOUR_MEXC_SECRET_KEY';
  const baseUrl = 'https://api.mexc.com';

  final spotAccount = await MexcSpotFunctions.getSpotAccount();
  print(spotAccount);


  // Generate timestamp in milliseconds
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final recvWindow = 5000;

  // Prepare query string
  final queryString = 'timestamp=$timestamp&recvWindow=$recvWindow';

  // Generate HMAC SHA256 signature
  final signature = Hmac(sha256, utf8.encode(secretKey))
      .convert(utf8.encode(queryString))
      .toString();

  // Final URL with signature
  final url = '$baseUrl/api/v3/account?$queryString&signature=$signature';

  // Send GET request
  final response = await http.get(
    Uri.parse(url),
    headers: {
      'X-MEXC-APIKEY': apiKey,
      'Content-Type': 'application/json',
    },
  );

  final futureBalance = await MexcFutureFunctions.getAssetCurrency('USDT');
  double futuresAvailable = double.parse(
      futureBalance['data']['availableBalance'].toString()
  );
  print("Futures Available Balance: $futuresAvailable");
  final positions = await MexcFutureFunctions.getOpenPositions();
  double totalUsedMargin = 0;

  for (var pos in positions['data']) {
    totalUsedMargin += double.parse(pos['im'].toString()); // Initial Margin
  }

  print("Total Futures Margin (Invested): $totalUsedMargin");

  double total =
          futuresAvailable +
          totalUsedMargin;

  print("--------------------------------------------------");
  print("TOTAL PORTFOLIO BALANCE SUMMARY");
  print("--------------------------------------------------");
  print("Futures Available Balance : $futuresAvailable");
  print("Futures Used Margin       : $totalUsedMargin");
  print("--------------------------------------------------");
  print("TOTAL VALUE (USDT)        : $total");
  print("--------------------------------------------------");


}

///Futures
class MexcFutureFunctions {
  static const String baseUrl = 'https://contract.mexc.com';
  //Tussie

  static String apiKey = 'YOUR_MEXC_API_KEY';
  static String secretKey = 'YOUR_MEXC_SECRET_KEY';

  static int _getTimestamp() => DateTime.now().millisecondsSinceEpoch;

  static String _sign(String input) {
    final key = utf8.encode(secretKey);
    final bytes = utf8.encode(input);
    final hmacSha256 = Hmac(sha256, key);
    final digest = hmacSha256.convert(bytes);
    return digest.toString();
  }

  static Future<Map<String, String>> _getHeaders({String params = ''}) async {
    final timestamp = _getTimestamp();
    final base = params.isEmpty
        ? '$apiKey$timestamp'
        : '$apiKey$timestamp$params';
    final signature = _sign(base);

    return {
      'ApiKey': apiKey,
      'Request-Time': timestamp.toString(),
      'Signature': signature,
      'Content-Type': 'application/json',
    };
  }

  static Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    String paramString = '';
    if (query != null && query.isNotEmpty) {
      paramString = query.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      path += '?$paramString';
    }

    final headers = await _getHeaders(params: paramString);
    final uri = Uri.parse('$baseUrl$path');
    final res = await http.get(uri, headers: headers);
    return jsonDecode(res.body);
  }

  // 📦 1. Get Account Balance
  static Future<dynamic> getAccountAssets() async {
    return await _get('/api/v1/private/account/assets');
  }

  // 📦 2. Get Balance of Specific Currency
  static Future<dynamic> getAssetCurrency(String currency) async {
    return await _get('/api/v1/private/account/asset/$currency');
  }

  // 📜 3. Get Open Positions
  static Future<dynamic> getOpenPositions([String? symbol]) async {
    final query = <String, String>{};
    if (symbol != null) query['symbol'] = symbol;
    return await _get('/api/v1/private/position/open_positions', query);
  }

  // 📜 4. Get History Positions
  static Future<dynamic> getHistoryPositions({
    required String pageNum,
    String? pageSize,
    String? symbol,
  }) async {
    final query = <String, String>{
      'page_num': pageNum,
    };
    if (pageSize != null) query['page_size'] = pageSize;
    if (symbol != null) query['symbol'] = symbol;
    return await _get('/api/v1/private/position/list/history_positions', query);
  }

  // 📜 5. Get Open Orders (Pending Trades)
  static Future<dynamic> getOpenOrders({
    String? pageNum,
    String? pageSize,
    String? symbol,
  }) async {
    final query = <String, String>{};
    if (pageNum != null) query['page_num'] = pageNum;
    if (pageSize != null) query['page_size'] = pageSize;
    if (symbol != null) query['symbol'] = symbol;
    return await _get('/api/v1/private/order/list/open_orders', query);
  }

  // 📜 6. Get History Orders
  static Future<dynamic> getHistoryOrders({
    String? pageNum,
    String? pageSize,
    String? symbol,
    String? states,
    String? category,
    String? startTime,
    String? endTime,
    String? side,
  }) async {
    final query = <String, String>{};
    if (pageNum != null) query['page_num'] = pageNum;
    if (pageSize != null) query['page_size'] = pageSize;
    if (symbol != null) query['symbol'] = symbol;
    if (states != null) query['states'] = states;
    if (category != null) query['category'] = category;
    if (startTime != null) query['start_time'] = startTime;
    if (endTime != null) query['end_time'] = endTime;
    if (side != null) query['side'] = side;
    return await _get('/api/v1/private/order/list/history_orders', query);
  }
}



class MexcSpotFunctions {
  static const String baseUrl = 'https://api.mexc.com';
  static String apiKey = 'YOUR_MEXC_API_KEY';
  static String secretKey = 'YOUR_MEXC_SECRET_KEY';

  /// Generate signature for MEXC SPOT
  static String _sign(String query) {
    final key = utf8.encode(secretKey);
    final bytes = utf8.encode(query);
    final hmacSha256 = Hmac(sha256, key);
    return hmacSha256.convert(bytes).toString();
  }

  /// GET request
  static Future<dynamic> _get(String path, Map<String, dynamic>? params) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final recvWindow = 5000;

    // Build query string
    String query = 'timestamp=$timestamp&recvWindow=$recvWindow';

    if (params != null && params.isNotEmpty) {
      query += '&' + params.entries
          .map((e) => '${e.key}=${e.value}')
          .join('&');
    }

    // Sign the query
    final signature = _sign(query);

    // Final full URL
    final url = '$baseUrl$path?$query&signature=$signature';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'X-MEXC-APIKEY': apiKey,
        'Content-Type': 'application/json',
      },
    );

    return jsonDecode(response.body);
  }

  /// 📦 **Get SPOT Account Information**
  static Future<dynamic> getSpotAccount() async {
    return await _get('/api/v3/account', {});
  }

  /// 📦 **Get the balance of a specific SPOT asset**
  static Future<dynamic> getSpotAsset(String asset) async {
    final account = await getSpotAccount();

    return account['balances']
        .firstWhere((b) => b['asset'] == asset, orElse: () => null);
  }
}
