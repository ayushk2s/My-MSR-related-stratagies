import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model.dart';

Future<List<Candle>> fetchMexcCandles({
  required String symbol,
  String interval = "Min5",
  int limit = 800,
  int offset = 0,
}) async {
  final intervalSeconds = {
    "Min1": 60,
    "Min5": 300,
    "Min15": 900,
    "Min30": 1800,
    "Min60": 3600,
  };

  if (!intervalSeconds.containsKey(interval)) {
    throw Exception("Unsupported interval: $interval");
  }

  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final step = intervalSeconds[interval]!;

  final end = now - (offset * step);
  final start = end - (limit * step);

  final url =
      'https://contract.mexc.com/api/v1/contract/kline/$symbol?interval=$interval&start=$start&end=$end';

  print(url);
  final response = await http.get(Uri.parse(url));

  if (response.statusCode == 200) {
    final body = jsonDecode(response.body);

    if (body["success"] == true && body["data"] != null) {
      final data = body["data"];
      final times = List<int>.from(data["time"]);
      final opens = List<double>.from(data["open"].map((e) => e.toDouble()));
      final highs = List<double>.from(data["high"].map((e) => e.toDouble()));
      final lows = List<double>.from(data["low"].map((e) => e.toDouble()));
      final closes = List<double>.from(data["close"].map((e) => e.toDouble()));
      final vols = List<double>.from(data["vol"].map((e) => e.toDouble()));

      return List.generate(times.length, (i) {
        return Candle(
          DateTime.fromMillisecondsSinceEpoch(times[i] * 1000, isUtc: true),
          opens[i],
          highs[i],
          lows[i],
          closes[i],
          vols[i],
          i
        );
      });
    } else {
      throw Exception("Invalid response data: ${body}");
    }
  } else {
    throw Exception(
        'Failed to fetch MEXC data: ${response.statusCode} ${response.body}');
  }
}

void main() async {
  List<String> cryptos = [
    "BTC_USDT",
    "ETH_USDT",
    "XRP_USDT",
    "LTC_USDT",
    "BNB_USDT",
    "ADA_USDT",
    "SOL_USDT",
    "AVAX_USDT",
    "BCH_USDT"
  ];
  for(int i =0; i<cryptos.length; i++) {
    final data = await fetchMexcCandles(symbol: cryptos[i], offset: 0);
    print(data.last);
    await Future.delayed(Duration(seconds: 1));
  }
}
