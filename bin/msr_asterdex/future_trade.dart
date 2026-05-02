import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

///LONG (BUY - open; SELL - close)
///SHORT (SELL - open; BUY - close)
class AsterFunction {
  // === API Keys ===
  static const String apiKey = 'YOUR_API_KEY_HERE';
  static const String secretKey = 'YOUR_SECRET_KEY_HERE';
  ///Place Order
  static Future<void> placeOrder({
    required String symbol,
    required String side, // BUY or SELL
    required String type, // LIMIT, MARKET, etc.
    required double quantity,
    double? price, // required for LIMIT orders
    required String positionSide, // LONG or SHORT, optional
    int recvWindow = 5000,
  }) async {

    // === Build parameters map ===
    // Format quantity without floating-point noise by stripping trailing zeros
    final qtyStr = quantity
        .toStringAsFixed(8)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');

    Map<String, String> params = {
      'symbol': symbol,
      'side': side,
      'type': type,
      'quantity': qtyStr,
      'recvWindow': recvWindow.toString(),
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };

    if (type == 'LIMIT' && price != null) {
      params['price'] = price.toString();
      params['timeInForce'] = 'GTX';
    }

    // Only include positionSide if provided
    params['positionSide'] = positionSide;

    // === Create query string ===
    String queryString = params.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');

    // === Generate HMAC SHA256 signature ===
    var key = utf8.encode(secretKey);
    var bytes = utf8.encode(queryString);
    var hmacSha256 = Hmac(sha256, key);
    var digest = hmacSha256.convert(bytes);
    String signature = digest.toString();

    // === Build final URL ===
    String url =
        'https://fapi.asterdex.com/fapi/v1/order?$queryString&signature=$signature';

    // === Send POST request ===
    try {
      var response = await http.post(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );

      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
    } catch (e) {
      print('Error sending order: $e');
    }
  }

  /// Cancel all open orders for a symbol
  static Future<void> cancelAllOrders({
    required String symbol,
    int recvWindow = 5000,
  }) async {

    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

    final params = {
      'symbol': symbol,
      'recvWindow': recvWindow.toString(),
      'timestamp': timestamp,
    };

    final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');

    final signature = Hmac(
      sha256,
      utf8.encode(secretKey),
    ).convert(utf8.encode(query)).toString();

    final url =
        "https://fapi.asterdex.com/fapi/v1/allOpenOrders?$query&signature=$signature";

    try {
      final res = await http.delete(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );

      print("Cancel All Status: ${res.statusCode}");
      print("Response: ${res.body}");
    } catch (e) {
      print("Error cancelling all orders: $e");
    }
  }

  /// Query a specific order's status
  /// Get all open / pending orders using old HMAC auth
  static Future<List<dynamic>> getOpenOrders({
    String? symbol,
    int recvWindow = 5000,
  }) async {

    // Build params
    Map<String, String> params = {
      'recvWindow': recvWindow.toString(),
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };

    if (symbol != null) {
      params['symbol'] = symbol;
    }

    // Create query string
    final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');

    // HMAC SHA256 Signature
    final signature = Hmac(
      sha256,
      utf8.encode(secretKey),
    ).convert(utf8.encode(query)).toString();

    // Final URL
    final url =
        "https://fapi.asterdex.com/fapi/v1/openOrders?$query&signature=$signature";

    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );
      List<dynamic> data = jsonDecode(res.body);
      return data;
    } catch (e) {
      print("Error fetching open orders: $e");
    }
    return [];
  }

  static Future<List<dynamic>> runingOrderInfo({
    String? symbol,
    int recvWindow = 5000,
  }) async {

    // Build params
    Map<String, String> params = {
      'recvWindow': recvWindow.toString(),
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };

    if (symbol != null) {
      params['symbol'] = symbol;
    }

    // Create query string
    final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');

    // HMAC SHA256 Signature
    final signature = Hmac(
      sha256,
      utf8.encode(secretKey),
    ).convert(utf8.encode(query)).toString();

    // Final URL
    final url =
        "https://fapi.asterdex.com/fapi/v1/positionRisk?$query&signature=$signature";

    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );
      final data = jsonDecode(res.body);

      return data;
    } catch (e) {
      print("Error fetching open orders: $e");
    }
    return [];
  }

  static Future<void> changeLeverage({
    required String symbol,
    required int leverage,
  }) async {

    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

    // === Build parameters map ===
    Map<String, String> params = {
      'symbol': symbol,
      'leverage': leverage.toString(),
      'timestamp': timestamp,
    };

    // === Create query string ===
    String queryString = params.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');

    // === Generate HMAC SHA256 signature ===
    var key = utf8.encode(secretKey);
    var bytes = utf8.encode(queryString);
    var hmacSha256 = Hmac(sha256, key);
    var digest = hmacSha256.convert(bytes);
    String signature = digest.toString();

    // === Build final URL ===
    String url =
        'https://fapi.asterdex.com/fapi/v1/leverage?$queryString&signature=$signature';

    // === Send POST request ===
    try {
      var response = await http.post(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );

      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
    } catch (e) {
      print('Error sending order: $e');
    }
  }

  static Future<void> accountDetails() async {

    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

    // === Build parameters map ===
    Map<String, String> params = {
      'recvWindow': '5000',
      'timestamp': timestamp,
    };

    // === Create query string ===
    String queryString = params.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');

    // === Generate HMAC SHA256 signature ===
    var key = utf8.encode(secretKey);
    var bytes = utf8.encode(queryString);
    var hmacSha256 = Hmac(sha256, key);
    var digest = hmacSha256.convert(bytes);
    String signature = digest.toString();

    // === Build final URL ===
    String url =
        'https://fapi.asterdex.com/fapi/v2/balance?$queryString&signature=$signature';

    // === Send POST request ===
    try {
      var response = await http.get(
        Uri.parse(url),
        headers: {'X-MBX-APIKEY': apiKey},
      );

      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
    } catch (e) {
      print('Error sending order: $e');
    }
  }
}

/*
> QPhysiq:
60de7921719e28c2f7532b2b4dfc4828f62d83ed9c7c8b622e2970cbcf52f9dc

> QPhysiq:
86cfda671891b0de56cb71153c07d949dccc4a35fcc6a70bddd8ede20b793dbc
 */
void main() async {
  await AsterFunction.accountDetails();
  // List<dynamic> data = await AsterFunction.getOpenOrders(symbol: 'SUIUSDT');
  // print(data);
  // double openOrderPrice = data.isNotEmpty ? double.parse(data[0]['price'].toString()) : 0.0;
  // print(openOrderPrice);
  // var positions = await AsterFunction.runingOrderInfo(symbol: 'SUIUSDT');
  // final d = positions.where((e) => double.parse(e['positionAmt'].toString()) != 0);
  // print(d);
  // await AsterFunction.changeLeverage(
  //   symbol: "SUIUSDT",
  //   leverage: 5,
  // );
  // await Future.delayed(Duration(milliseconds: 1000));
  // await AsterRecursiveTradeFunction.tradeLimit(
  //     symbol: 'SUIUSDT',
  //     side: 'SELL',
  //     positionSide: 'SHORT',
  //     vol: 5,
  //   leverage: 10
  // );
  // await AsterFunction.placeOrder(
  //   symbol: 'SOLUSDT',
  //   side: 'BUY',
  //   type: 'LIMIT',
  //   quantity: 0.05,
  //   price: 130,
  //   positionSide: 'LONG',
  // );
  // await AsterFunction.cancelAllOrders(symbol: 'SOLUSDT');
  // await AsterFunction.placeOrder(
  //   symbol: 'SUIUSDT',
  //   side: 'BUY',
  //   type: 'LIMIT',
  //   quantity: 10,
  //   price: 1.45,
  //   positionSide: 'LONG',
  // );
  //
  // await AsterFunction.placeOrder(
  //   symbol: 'SUIUSDT',
  //   side: 'BUY',
  //   type: 'LIMIT',
  //   quantity: 15,
  //   price: 1.4,
  //   positionSide: 'LONG',
  // );

  // await Future.delayed(Duration(milliseconds: 500));
  // await AsterFunction.changeLeverage(
  //   symbol: "SUIUSDT",
  //   leverage: 8,
  // );
  // await Future.delayed(Duration(milliseconds: 1000));
  // final bki = await FetchBestBidAsk.bestBidAsk('SUIUSDT');
  // print(bki['bids']);
  // await AsterFunction.placeOrder(
  //   symbol: 'SUIUSDT',
  //   side: 'BUY',
  //   type: 'LIMIT',
  //   quantity: 1,
  //   price: double.parse((double.parse(bki['bids']) - 0.01).toStringAsFixed(2)),
  //   positionSide: 'LONG',
  // );
  // List<dynamic> data1 = await AsterFunction.getOpenOrders(symbol: 'SUIUSDT');
  // print(data1);
  // //
  // var positions1 = await AsterFunction.runingOrderInfo(symbol: 'SUIUSDT');
  // print(positions1);
  // final d1 = positions1.where((e) => double.parse(e['positionAmt'].toString()) > 0);
  // print(d1);
  // if(d1.isNotEmpty){
  //   print('There is something');
  // }
  // await Future.delayed(Duration(seconds: 5));
  //
  // final running = positions.where((p) {
  //   final amt = double.tryParse(p['positionAmt'].toString()) ?? 0;
  //   return amt != 0;
  // }).toList();
  //
  // print("Running Positions: $running");
  // var positions2 = await AsterFunction.runingOrderInfo(symbol: 'SUIUSDT');
  // final running2= positions2.where((p) {
  //   final amt = double.tryParse(p['positionAmt'].toString()) ?? 0;
  //   return amt != 0;
  // }).toList();
  //
  // print("Running Positions: $running2");
  //
  //
  //
  // // Query all pending order
  // List<dynamic> data = await AsterFunction.getOpenOrders(symbol: "SUIUSDT");
  // print(data);
  // if(data.isEmpty){
  //   print('perfect');
  // }else{
  //   print("Still pending");
  // }
  // // Cancel everything for a symbol
  // await AsterFunction.cancelAllOrders(symbol: "SUIUSDT");
}
