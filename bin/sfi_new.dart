import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

class Candle {
  final double open, high, low, close;

  Candle(this.open, this.high, this.low, this.close);
}

// ================= FETCH DATA =================
Future<List<Candle>> fetchCandles(String symbol, String interval) async {
  final url =
      'https://api.binance.com/api/v3/klines?symbol=$symbol&interval=$interval&limit=200';

  final res = await http.get(Uri.parse(url));
  final data = jsonDecode(res.body);

  return data.map<Candle>((e) {
    return Candle(
      double.parse(e[1]),
      double.parse(e[2]),
      double.parse(e[3]),
      double.parse(e[4]),
    );
  }).toList();
}

// ================= ATR =================
List<double> calculateATR(List<Candle> candles, int period) {
  List<double> trList = [];

  for (int i = 1; i < candles.length; i++) {
    double highLow = candles[i].high - candles[i].low;
    double highClose = (candles[i].high - candles[i - 1].close).abs();
    double lowClose = (candles[i].low - candles[i - 1].close).abs();

    double tr = max(highLow, max(highClose, lowClose));
    trList.add(tr);
  }

  List<double> atr = [];

  for (int i = 0; i < trList.length; i++) {
    if (i < period) {
      atr.add(trList.sublist(0, i + 1).reduce((a, b) => a + b) / (i + 1));
    } else {
      atr.add(trList.sublist(i - period, i).reduce((a, b) => a + b) / period);
    }
  }

  return atr;
}

// ================= K-MEANS (3 CLUSTERS) =================
class ClusterResult {
  double high;
  double mid;
  double low;

  ClusterResult(this.high, this.mid, this.low);
}

ClusterResult kMeansVolatility(List<double> atr) {
  double high = atr.reduce(max);
  double low = atr.reduce(min);
  double mid = (high + low) / 2;

  for (int iter = 0; iter < 10; iter++) {
    List<double> h = [], m = [], l = [];

    for (var v in atr) {
      double dH = (v - high).abs();
      double dM = (v - mid).abs();
      double dL = (v - low).abs();

      if (dH < dM && dH < dL) {
        h.add(v);
      } else if (dM < dH && dM < dL) {
        m.add(v);
      } else {
        l.add(v);
      }
    }

    if (h.isNotEmpty) high = h.reduce((a, b) => a + b) / h.length;
    if (m.isNotEmpty) mid = m.reduce((a, b) => a + b) / m.length;
    if (l.isNotEmpty) low = l.reduce((a, b) => a + b) / l.length;
  }

  return ClusterResult(high, mid, low);
}

// ================= SUPERTREND =================
class SuperTrendResult {
  double value;
  int direction;

  SuperTrendResult(this.value, this.direction);
}

SuperTrendResult superTrend(
  Candle candle,
  double prevST,
  int prevDir,
  double atr,
  double factor,
) {
  double hl2 = (candle.high + candle.low) / 2;

  double upper = hl2 + factor * atr;
  double lower = hl2 - factor * atr;

  int dir;
  double st;

  if (prevST == upper) {
    dir = candle.close > upper ? -1 : 1;
  } else {
    dir = candle.close < lower ? 1 : -1;
  }

  st = dir == -1 ? lower : upper;

  return SuperTrendResult(st, dir);
}

// ================= MAIN LOGIC =================
Future<void> runBot() async {
  List<Candle> candles = await fetchCandles("SOLUSDT", "5m");

  List<double> atr = calculateATR(candles, 10);

  // last 100 ATR values for training
  List<double> recentATR = atr.sublist(atr.length - 100);

  ClusterResult clusters = kMeansVolatility(recentATR);

  double currentATR = atr.last;

  // Determine cluster
  double dH = (currentATR - clusters.high).abs();
  double dM = (currentATR - clusters.mid).abs();
  double dL = (currentATR - clusters.low).abs();

  double assignedATR;

  if (dH < dM && dH < dL) {
    assignedATR = clusters.high;
    print("HIGH VOLATILITY");
  } else if (dM < dH && dM < dL) {
    assignedATR = clusters.mid;
    print("MEDIUM VOLATILITY");
  } else {
    assignedATR = clusters.low;
    print("LOW VOLATILITY");
  }

  double prevST = 0;
  int prevDir = 1;

  for (int i = 1; i < candles.length; i++) {
    var res = superTrend(candles[i], prevST, prevDir, assignedATR, 3);

    prevST = res.value;
    prevDir = res.direction;
  }

  if (prevDir == -1) {
    print("📈 UPTREND");
  } else {
    print("📉 DOWNTREND");
  }
}

void main() {
  runBot();
}
