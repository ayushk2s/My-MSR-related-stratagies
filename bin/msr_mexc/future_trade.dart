
import 'dart:convert';

import 'package:http/http.dart' as http;

class FutureTrade {
  static Future<void> sendTradeRequest({
    required String uid,
    required String mtoken,
    required String htoken,
    required String symbol,
    required String side,
    required int order_type,
    required int vol,
    required double leverage,
    double price = 0,
    double? takeProfit,
    double? stopLoss,
  }) async {
    final uri = Uri.parse('http://0.0.0.0:8000/trade');

    final payload = {
      "uid": uid,
      "mtoken": mtoken,
      "htoken": htoken,
      "symbol": symbol,
      "action": side,
      "vol": vol,
      "leverage": leverage,
      "order_type" : order_type,
      "price": price,
      "testnet": true,
    };

    // ✅ Only add if not null
    if (takeProfit != null) payload["take_profit"] = takeProfit;
    if (stopLoss != null) payload["stop_loss"] = stopLoss;

    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      print('response $response');
      if (response.statusCode == 200) {
        print('✅ Trade Success: ${response.body}');
      } else {
        print('❌ Trade Failed (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('❌ Trade Error: $e');
    }
  }

  static Future<void> sendCancelAllOrdersRequest({
    required String uid,
    required String mtoken,
    required String htoken,
    bool testnet = true,
  }) async {
    final uri = Uri.parse('http://127.0.0.1:8000/cancel');

    final payload = {
      'uid': uid,
      'mtoken': mtoken,
      'htoken': htoken,
      'testnet': testnet,
    };

    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        print("✅ Cancel Success: ${response.body}");
      } else {
        print("❌ Cancel Failed: ${response.statusCode} - ${response.body}");
      }
    } catch (e) {
      print("❌ Cancel Error: $e");
    }
  }
}

