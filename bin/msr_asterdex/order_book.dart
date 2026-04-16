import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class FetchBestBidAsk {
  static Future<Map<String, dynamic>> bestBidAsk(String symbol) async {
    final uri = Uri.parse(
        'https://fapi.asterdex.com/fapi/v1/depth?symbol=$symbol&limit=5');
    final response = await http.get(uri);
    if (response.statusCode == 200) {
      Map<String, dynamic> data = jsonDecode(response.body);
      List<dynamic> bids = data['bids'];
      List<dynamic> asks = data['asks'];
      return {
        'bids' : bids[0][0],
        'asks' : asks[0][0]
      };
    } else {
      print('Something went wrong!');
    }
    return {};
  }
}

void main() async{
  final data = await FetchBestBidAsk.bestBidAsk('SOLUSDT');
  print(data['bids']);
}