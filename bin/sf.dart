import 'dart:async';
import 'dart:math';

import 'mexc_fetch_candle_data.dart';
import 'model.dart';



class ProfitTarget {
  final double targetPrice;
  bool reached;

  ProfitTarget(this.targetPrice) : reached = false;

  @override
  String toString() {
    return '${targetPrice.toStringAsFixed(8)}${reached ? " ✅" : ""}';
  }
}

class TradeEntry {
  final int direction; // 1=buy, -1=sell
  final double entryPrice;
  final List<ProfitTarget> targets;

  TradeEntry(this.direction, this.entryPrice, List<double> atrMultipliers, double atr)
      : targets = atrMultipliers
      .map((m) => ProfitTarget(direction == 1 ? entryPrice + m * atr : entryPrice - m * atr))
      .toList();

  @override
  String toString() {
    String type = direction == 1 ? 'BUY' : 'SELL';
    return '$type @ ${entryPrice.toStringAsFixed(2)} | Targets: ${targets.join(', ')}';
  }
}

class SfiSignal {
  final double upLine;
  final double dnLine;
  final int trend;
  final bool buySignal;
  final bool sellSignal;

  SfiSignal({
    required this.upLine,
    required this.dnLine,
    required this.trend,
    required this.buySignal,
    required this.sellSignal,
  });

  @override
  String toString() {
    return 'trend: $trend, up_line: ${upLine.toStringAsFixed(6)}, dn_line: ${dnLine.toStringAsFixed(6)}, buy_signal: $buySignal, sell_signal: $sellSignal';
  }
}

class SfiIndicator {

  // Fetch candles from Binance


  // Calculate True Range (TR)
  List<double> calculateTR(List<Candle> candles) {
    List<double> trList = [];
    for (int i = 0; i < candles.length; i++) {
      double previousClose = i == 0 ? candles[i].close : candles[i - 1].close;
      double tr = [
        candles[i].high - candles[i].low,
        (candles[i].high - previousClose).abs(),
        (candles[i].low - previousClose).abs()
      ].reduce((a, b) => a > b ? a : b);
      trList.add(tr);
    }
    return trList;
  }

  // Wilder's ATR (TradingView atr() style)
  List<double> calculateWilderATR(List<double> trList, int period) {
    List<double> atr = [];
    if (trList.isEmpty) return atr;

    double sum = 0.0;
    for (int i = 0; i < trList.length; i++) {
      if (i < period) {
        sum += trList[i];
        // until we reach period bars, use SMA of TR for initial ATR values (consistent)
        atr.add(sum / (i + 1));
      } else if (i == period) {
        // first Wilder ATR value: SMA of the first 'period' TRs
        double initial = trList.sublist(0, period).reduce((a, b) => a + b) /
            period;
        atr.add(initial);
      } else {
        // Wilder smoothing
        double prevAtr = atr[i - 1];
        double newAtr = ((prevAtr * (period - 1)) + trList[i]) / period;
        atr.add(newAtr);
      }
    }

    // Note: depending on indexing, the first true Wilder ATR full-period value appears at index == period
    // but for practical purposes we return atr list aligned with trList length.
    return atr;
  }

  // Calculate SFI Magic signals with trailing up/dn logic matching Pine Script
  List<SfiSignal> calculateSfiMagic(List<Candle> candles, {
    int period = 10,
    double multiplier = 1.7,
    bool changeAtr = true,
  }) {
    final trList = calculateTR(candles);
    // ATR used by SFI Magic (use Wilder style to match TradingView's atr())
    final atrListWilder = calculateWilderATR(trList, period);

    List<SfiSignal> signals = [];

    if (candles.isEmpty) return signals;

    // We'll keep previous up/dn (the trailed values), initialize from first raw values
    double prevUp = candles[0].ohlc4 -
        multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    double prevDn = candles[0].ohlc4 +
        multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    int previousTrend = 1;

    for (int i = 0; i < candles.length; i++) {
      Candle c = candles[i];
      // safe-guard for atr index: if atr list shorter, use last value or 0
      double atr = (i < atrListWilder.length)
          ? atrListWilder[i]
          : (atrListWilder.isNotEmpty ? atrListWilder.last : 0.0);
      double ohlc4 = c.ohlc4;

      // raw lines
      double rawUp = ohlc4 - multiplier * atr;
      double rawDn = ohlc4 + multiplier * atr;

      double up;
      double dn;

      if (i > 0) {
        // follow Pine logic: up := close[1] > up1 ? max(rawUp, up1) : rawUp
        up = candles[i - 1].close > prevUp ? max(rawUp, prevUp) : rawUp;
        // dn := close[1] < dn1 ? min(rawDn, dn1) : rawDn
        dn = candles[i - 1].close < prevDn ? min(rawDn, prevDn) : rawDn;
      } else {
        up = rawUp;
        dn = rawDn;
      }

      // Trend flip logic (same as Pine)
      int trend = previousTrend;
      if (previousTrend == -1 && c.close > prevDn)
        trend = 1;
      else if (previousTrend == 1 && c.close < prevUp) trend = -1;

      bool buySignal = previousTrend == -1 && trend == 1;
      bool sellSignal = previousTrend == 1 && trend == -1;

      signals.add(SfiSignal(upLine: up,
          dnLine: dn,
          trend: trend,
          buySignal: buySignal,
          sellSignal: sellSignal));

      // update previous variables for next iteration
      prevUp = up;
      prevDn = dn;
      previousTrend = trend;
    }

    return signals;
  }


  Future<Map<String, dynamic>> loop(List<Candle> candles) async {
    try {
      // Fetch candles

      // Multipliers per your Pine script
      List<double> atrMultipliers = [1, 4.5, 7, 9, 11];

      // TR & ATR lists
      List<double> trList = calculateTR(candles);
      // ATR used for targets in your Pine code was length 14; use Wilder ATR to match TradingView
      List<double> atrListTargets = calculateWilderATR(trList, 14);

      // Signals for SFI magic (period 10, multiplier 1.7)
      List<SfiSignal> signals = calculateSfiMagic(
          candles, period: 10, multiplier: 1.7);

      List<TradeEntry> activeTrades = [];

      // Track one-time target flags per trade (identity keyed)
      Map<TradeEntry, List<bool>> targetFlags = {};

      // Track entry price variables to mimic Pine label reset behavior
      double? buyEntryPrice;
      double? sellEntryPrice;
      double? upLineReturn, downLineReturn;
      List<bool> buyLabelPlotted = List.filled(atrMultipliers.length, false);
      List<bool> sellLabelPlotted = List.filled(atrMultipliers.length, false);

      for (int i = 0; i < candles.length; i++) {
        Candle c = candles[i];
        SfiSignal s = signals[i];

        // ATR for profit targets for this bar (safe fallback)
        double atrForTargets = (i < atrListTargets.length)
            ? atrListTargets[i]
            : (atrListTargets.isNotEmpty ? atrListTargets.last : 0.0);

        // When buy or sell signal appears, set/reset entry price and flags (like Pine)
        if (s.buySignal) {
          buyEntryPrice = c.close;
          // reset buy labels flags
          for (int k = 0; k < buyLabelPlotted.length; k++)
            buyLabelPlotted[k] = false;

          // create trade entry and add to activeTrades + flags
          var trade = TradeEntry(1, c.close, atrMultipliers, atrForTargets);
          activeTrades.add(trade);
          targetFlags[trade] = List.filled(trade.targets.length, false);

          // debug log entry
          // print('BUY signal @ ${c.close.toStringAsFixed(6)} (bar index $i)');
        }

        if (s.sellSignal) {
          sellEntryPrice = c.close;
          // reset sell labels flags
          for (int k = 0; k < sellLabelPlotted.length; k++)
            sellLabelPlotted[k] = false;

          var trade = TradeEntry(-1, c.close, atrMultipliers, atrForTargets);
          activeTrades.add(trade);
          targetFlags[trade] = List.filled(trade.targets.length, false);

          // debug log entry
          // print('SELL signal @ ${c.close.toStringAsFixed(6)} (bar index $i)');
        }

        // Check targets for each active trade on this bar
        for (var trade in activeTrades) {
          for (int tIdx = 0; tIdx < trade.targets.length; tIdx++) {
            if (!targetFlags[trade]![tIdx]) {
              var t = trade.targets[tIdx];
              if (trade.direction == 1 && c.close >= t.targetPrice) {
                t.reached = true;
                targetFlags[trade]![tIdx] = true;
                // print('Trade hit target ${tIdx + 1} for BUY: ${t.targetPrice
                //     .toStringAsFixed(6)} at close ${c.close.toStringAsFixed(
                //     6)} (bar $i)');
              } else if (trade.direction == -1 && c.close <= t.targetPrice) {
                t.reached = true;
                targetFlags[trade]![tIdx] = true;
                // print('Trade hit target ${tIdx + 1} for SELL: ${t.targetPrice
                //     .toStringAsFixed(6)} at close ${c.close.toStringAsFixed(
                //     6)} (bar $i)');
              }
            }
          }
        }

        // Print trailing up/dn lines for comparison with Pine (one line per bar)
        // print('Bar $i close=${c.close.toStringAsFixed(6)} trend=${s
        //     .trend} dnLine=${s.upLine.toStringAsFixed(6)} upLine=${s.dnLine
        //     .toStringAsFixed(6)} buy=${s.buySignal} sell=${s.sellSignal}');
        upLineReturn = double.tryParse(s.upLine.toStringAsPrecision(6));
        downLineReturn = double.tryParse(s.dnLine.toStringAsPrecision(6));
      }
//dn line higher then price if indication is short, upline greater and vice-versa for buy
      // Print last active trade for demo (if any)
      if (activeTrades.isNotEmpty) {
        // print('Last active trade: ${activeTrades
        //     .last} dnLine $downLineReturn upline$upLineReturn');
        return {
          'direction': activeTrades.last.direction,
          'entry': activeTrades.last.entryPrice,
          'targets': activeTrades.last.targets,
          'stoploss': downLineReturn,
          'nexttarget': upLineReturn,
        };
      } else {
        print('No active trades in this run.');
      }
    } catch (e, st) {
      print('Error in loop: $e\n$st');
    }
    return {};
  }
}

void main() async{

  final candleData = await fetchMexcCandles(
    symbol: 'SOL_USDT',
    interval: "Min5",
    limit: 300,
    offset: 5,
  );
  print(candleData.last.close);
  Map<String, dynamic> sfiData = await SfiIndicator().loop(candleData);
  print(sfiData); // downLine actual trailing up line target
  double sfiEntry = sfiData['entry'];
  int sfiDirection = sfiData['direction'];
  double sfiSl = sfiDirection == 1 ? sfiData['nexttarget'] : sfiData['stoploss'];
  double sfinextTarget = sfiDirection == 1 ? sfiData['stoploss'] : sfiData['nexttarget'];

  List<ProfitTarget> targets = sfiData['targets'];
  List d = targets.toList();

  print(d[0]);
}

