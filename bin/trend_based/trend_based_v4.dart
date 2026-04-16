// ════════════════════════════════════════════════════════════════════════════
//  CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER v4 (1h PRECISION)
//
//  v3 → v4 upgrade rationale
//  ────────────────────────────────────────────────────────────────────────────
//  Root cause of remaining v3 losers:
//  1. 15m NOISE   Short-term bars trigger entries in intra-bar noise; stops hit
//     before the trend move actually starts. Even with ADX gate, 15m is too
//     granular for structural trend-following.
//  2. FEE DRAG    18 bps round-trip × 40–60 trades/asset = 7–11% fee drag.
//     Chandelier only has ~11% gross winners on ADAUSDT; fees ate half of it.
//  3. MISSING MACRO FILTER  4h direction is needed, but the daily slope adds
//     an extra regime confirmation that prevents trading against the weekly trend.
//
//  v4 Fixes
//  ────────────────────────────────────────────────────────────────────────────
//  • 1h PRIMARY TIMEFRAME — entry bars are 1h candles.  4h + daily confirm.
//    Fewer but higher-quality signals.  ~8 trades/asset/window vs ~20 in v3.
//  • DAILY EMA SLOPE — only long when daily EMA20 is rising; only short when
//    falling.  Blocks contra-trend entries on multi-week turns.
//  • WIDER TARGETS (4–7 × ATR)  At 1h granularity each ATR is 4× larger than
//    at 15m, so targets are further away — winners run for multiple hours.
//  • IS WINDOW 90 DAYS → more IS trades → better optimisation sample.
//  • Two strategies: Chandelier-1h (primary), TrendPullback-1h (secondary).
//    Supertrend-Quality and KAMA-Pullback dropped (consistently below fees).
// ════════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

// ─── Realism constants ───────────────────────────────────────────────────────
const double kSlippagePerSide = 0.0005; // 5 bps per fill
const double kFeePerSide      = 0.0004; // 4 bps per fill (taker)
const int    kMaxBarsInTrade  = 120;    // 5 days on 1h bars

// ════════════════════════════════════════════════════════════════════════════
// MODELS
// ════════════════════════════════════════════════════════════════════════════

class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

enum TradeDirection { long, short }

class Trade {
  final DateTime entryTime, exitTime;
  final double entryPrice, exitPrice;
  final TradeDirection direction;
  final String strategyName, symbol, exitReason;

  const Trade({
    required this.entryTime,
    required this.exitTime,
    required this.entryPrice,
    required this.exitPrice,
    required this.direction,
    required this.strategyName,
    required this.symbol,
    required this.exitReason,
  });

  double get pnlPct {
    final raw = direction == TradeDirection.long
        ? (exitPrice - entryPrice) / entryPrice * 100
        : (entryPrice - exitPrice) / entryPrice * 100;
    return raw - (2 * kSlippagePerSide + 2 * kFeePerSide) * 100;
  }

  Duration get holdingPeriod => exitTime.difference(entryTime);
}

class StrategyResult {
  final String strategyName, symbol, windowLabel;
  final List<Trade> trades;
  final String paramsLabel;

  StrategyResult({
    required this.strategyName,
    required this.symbol,
    required this.trades,
    required this.windowLabel,
    this.paramsLabel = '',
  });

  int get totalTrades   => trades.length;
  int get winningTrades => trades.where((t) => t.pnlPct > 0).length;
  int get losingTrades  => trades.where((t) => t.pnlPct <= 0).length;
  double get winRate    => totalTrades == 0 ? 0 : winningTrades / totalTrades * 100;
  double get totalReturn => trades.fold(0.0, (s, t) => s + t.pnlPct);

  double get avgWin {
    final w = trades.where((t) => t.pnlPct > 0).toList();
    return w.isEmpty ? 0 : w.fold(0.0, (s, t) => s + t.pnlPct) / w.length;
  }

  double get avgLoss {
    final l = trades.where((t) => t.pnlPct <= 0).toList();
    return l.isEmpty ? 0 : l.fold(0.0, (s, t) => s + t.pnlPct) / l.length;
  }

  double get profitFactor {
    final gp = trades.where((t) => t.pnlPct > 0).fold(0.0, (s, t) => s + t.pnlPct);
    final gl = trades.where((t) => t.pnlPct <= 0).fold(0.0, (s, t) => s + t.pnlPct.abs());
    return gl == 0 ? (gp == 0 ? 0 : double.infinity) : gp / gl;
  }

  double get sharpeRatio {
    if (trades.length < 2) return 0;
    final rets = trades.map((t) => t.pnlPct).toList();
    final mean = rets.fold(0.0, (s, r) => s + r) / rets.length;
    final variance = rets.fold(0.0, (s, r) => s + pow(r - mean, 2)) / rets.length;
    final std = sqrt(variance);
    return std == 0 ? 0 : mean / std * sqrt(trades.length.toDouble());
  }

  double get maxDrawdown {
    if (trades.isEmpty) return 0;
    double peak = 0, maxDD = 0, running = 0;
    for (final t in trades) {
      running += t.pnlPct;
      if (running > peak) peak = running;
      final dd = peak - running;
      if (dd > maxDD) maxDD = dd;
    }
    return maxDD;
  }

  double get expectancy =>
      totalTrades == 0 ? 0 : (winRate / 100 * avgWin) + ((1 - winRate / 100) * avgLoss);

  double get calmarRatio => maxDrawdown == 0 ? 0 : totalReturn / maxDrawdown;

  /// IS score: expectancy × √trades (penalises both bad edge AND tiny sample).
  double get isOptScore {
    if (totalTrades < 4) return -1000.0;
    final tradeFactor =
        min(sqrt(totalTrades.toDouble()), sqrt(40.0)) / sqrt(40.0);
    return expectancy * tradeFactor;
  }

  double get compositeScore {
    if (totalTrades < 4) return 0;
    final wR = winRate / 100;
    final pF = min(profitFactor.isInfinite ? 5.0 : profitFactor, 5.0) / 5.0;
    final sh = (min(max(sharpeRatio, -2.0), 4.0) + 2.0) / 6.0;
    final ex = expectancy > 0 ? min(expectancy / 2.0, 1.0) : 0.0;
    return (wR * 0.20 + pF * 0.35 + sh * 0.25 + ex * 0.20) * 100;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// CSV LOADER
// ════════════════════════════════════════════════════════════════════════════

class CsvLoader {
  static const int _minCandles = 200;

  static List<Candle> loadFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return [];
    final lines = file.readAsLinesSync();
    final candles = <Candle>[];
    int start = 0;
    if (lines.isNotEmpty) {
      final first = lines[0].toLowerCase();
      if (first.contains('time') || first.contains('date') || first.contains('open'))
        start = 1;
    }
    for (int i = start; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 5) continue;
      try {
        final raw = parts[0].trim();
        DateTime time;
        if (RegExp(r'^\d{10,13}$').hasMatch(raw)) {
          final ms = int.parse(raw);
          time = ms > 9999999999
              ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
              : DateTime.fromMillisecondsSinceEpoch(ms * 1000, isUtc: true);
        } else {
          time = DateTime.parse(raw).toUtc();
        }
        candles.add(Candle(
          time:   time,
          open:   double.parse(parts[1].trim()),
          high:   double.parse(parts[2].trim()),
          low:    double.parse(parts[3].trim()),
          close:  double.parse(parts[4].trim()),
          volume: parts.length > 5 ? double.parse(parts[5].trim()) : 0.0,
        ));
      } catch (_) {
        continue;
      }
    }
    candles.sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  static Map<String, List<Candle>> loadDirectory(String dirPath) {
    final dir5m   = Directory(p.join(dirPath, '5m'));
    final scanDir = dir5m.existsSync() ? dir5m : Directory(dirPath);
    if (!scanDir.existsSync()) {
      print('  ⛔  Directory not found: $dirPath');
      return {};
    }
    if (dir5m.existsSync())
      print('  📂  Found 5m subfolder — scanning: ${scanDir.path}');

    final merged  = <String, List<Candle>>{};
    int filesFound = 0;
    final tfSuffix = RegExp(r'\d+[mMhH]$');

    void scan(Directory d) {
      for (final entity in d.listSync()) {
        if (entity is Directory) {
          scan(entity);
        } else if (entity is File && entity.path.toLowerCase().endsWith('.csv')) {
          filesFound++;
          final symbol = p
              .basenameWithoutExtension(entity.path)
              .replaceAll(tfSuffix, '')
              .toUpperCase()
              .trim();
          if (symbol.isEmpty) continue;
          final loaded = loadFile(entity.path);
          if (loaded.isNotEmpty)
            merged.putIfAbsent(symbol, () => []).addAll(loaded);
        }
      }
    }

    scan(scanDir);
    print('  📂  Scanned $filesFound CSV file(s) in "${scanDir.path}"');

    final result = <String, List<Candle>>{};
    for (final sym in merged.keys) {
      final deduped = <DateTime, Candle>{};
      for (final c in merged[sym]!) deduped[c.time] = c;
      final candles = deduped.values.toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      if (candles.length >= _minCandles) {
        result[sym] = candles;
        final span =
            '${candles.first.time.toIso8601String().substring(0, 10)} → '
            '${candles.last.time.toIso8601String().substring(0, 10)}';
        print('  ✓  $sym: ${candles.length} candles [$span]');
      } else {
        print('  ⚠  $sym: only ${candles.length} candles — skipped');
      }
    }
    return result;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TIMEFRAME AGGREGATOR
// ════════════════════════════════════════════════════════════════════════════

enum Timeframe { m5, m15, h1, h4, d1 }

extension TimeframeExt on Timeframe {
  int    get minutes => const {Timeframe.m5:5,Timeframe.m15:15,Timeframe.h1:60,Timeframe.h4:240,Timeframe.d1:1440}[this]!;
  String get label   => const {Timeframe.m5:'5m',Timeframe.m15:'15m',Timeframe.h1:'1h',Timeframe.h4:'4h',Timeframe.d1:'1d'}[this]!;
}

class TimeframeAggregator {
  static List<Candle> aggregate(List<Candle> base, Timeframe tf) {
    if (tf == Timeframe.m5) return List.from(base);
    final bMin = tf.minutes;
    final result = <Candle>[];
    int i = 0;
    while (i < base.length) {
      final bucketStart = _floor(base[i].time, bMin);
      final bucketEnd   = bucketStart.add(Duration(minutes: bMin));
      double o = base[i].open, h = base[i].high, l = base[i].low,
             c = base[i].close, vol = base[i].volume;
      i++;
      while (i < base.length && base[i].time.isBefore(bucketEnd)) {
        if (base[i].high > h) h = base[i].high;
        if (base[i].low  < l) l = base[i].low;
        c   = base[i].close;
        vol += base[i].volume;
        i++;
      }
      result.add(Candle(time: bucketStart, open: o, high: h, low: l, close: c, volume: vol));
    }
    return result;
  }

  static DateTime _floor(DateTime t, int bMin) {
    if (bMin >= 1440) {
      // Daily: floor to midnight UTC of the same calendar day
      return DateTime.utc(t.year, t.month, t.day);
    }
    final total   = t.hour * 60 + t.minute;
    final floored = (total ~/ bMin) * bMin;
    return DateTime.utc(t.year, t.month, t.day, floored ~/ 60, floored % 60);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// INDICATORS
// ════════════════════════════════════════════════════════════════════════════

class Indicators {
  static List<double> ema(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period) return out;
    final mult = 2.0 / (period + 1);
    out[period - 1] = src.take(period).fold(0.0, (s, v) => s + v) / period;
    for (int i = period; i < src.length; i++)
      out[i] = (src[i] - out[i - 1]) * mult + out[i - 1];
    return out;
  }

  static List<double> sma(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period) return out;
    double sum = src.take(period).fold(0.0, (s, v) => s + v);
    out[period - 1] = sum / period;
    for (int i = period; i < src.length; i++) {
      sum += src[i] - src[i - period];
      out[i] = sum / period;
    }
    return out;
  }

  static List<double> atr(List<Candle> cs, int period) {
    if (cs.length < period + 1) return List.filled(cs.length, double.nan);
    final tr = <double>[cs[0].high - cs[0].low];
    for (int i = 1; i < cs.length; i++) {
      tr.add([
        cs[i].high - cs[i].low,
        (cs[i].high - cs[i - 1].close).abs(),
        (cs[i].low  - cs[i - 1].close).abs(),
      ].reduce(max));
    }
    final out   = List<double>.filled(cs.length, double.nan);
    double atrV = tr.take(period).fold(0.0, (s, v) => s + v) / period;
    out[period - 1] = atrV;
    for (int i = period; i < cs.length; i++) {
      atrV    = (atrV * (period - 1) + tr[i]) / period;
      out[i]  = atrV;
    }
    return out;
  }

  static List<double> rsi(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period + 1) return out;
    double g = 0, l = 0;
    for (int i = 1; i <= period; i++) {
      final d = src[i] - src[i - 1];
      if (d >= 0) g += d; else l -= d;
    }
    double ag = g / period, al = l / period;
    out[period] = 100 - 100 / (1 + (al == 0 ? double.infinity : ag / al));
    for (int i = period + 1; i < src.length; i++) {
      final d = src[i] - src[i - 1];
      ag = (ag * (period - 1) + (d > 0 ? d : 0)) / period;
      al = (al * (period - 1) + (d < 0 ? -d : 0)) / period;
      out[i] = 100 - 100 / (1 + (al == 0 ? double.infinity : ag / al));
    }
    return out;
  }

  static ({List<double> adx, List<double> plusDI, List<double> minusDI}) adx(
    List<Candle> cs, int period,
  ) {
    final n      = cs.length;
    final adxOut = List<double>.filled(n, double.nan);
    final pDIOut = List<double>.filled(n, double.nan);
    final mDIOut = List<double>.filled(n, double.nan);
    if (n < period * 2 + 1) return (adx: adxOut, plusDI: pDIOut, minusDI: mDIOut);

    final tr  = List<double>.filled(n, 0.0);
    final pDM = List<double>.filled(n, 0.0);
    final mDM = List<double>.filled(n, 0.0);
    for (int i = 1; i < n; i++) {
      tr[i] = [cs[i].high - cs[i].low,
               (cs[i].high - cs[i - 1].close).abs(),
               (cs[i].low  - cs[i - 1].close).abs()].reduce(max);
      final up   = cs[i].high - cs[i - 1].high;
      final down = cs[i - 1].low - cs[i].low;
      pDM[i] = (up > down && up > 0) ? up : 0;
      mDM[i] = (down > up && down > 0) ? down : 0;
    }
    double smTR = 0, smP = 0, smM = 0;
    for (int i = 1; i <= period; i++) { smTR += tr[i]; smP += pDM[i]; smM += mDM[i]; }
    final dxList = <double>[];
    for (int i = period; i < n; i++) {
      if (i > period) {
        smTR = smTR - smTR / period + tr[i];
        smP  = smP  - smP  / period + pDM[i];
        smM  = smM  - smM  / period + mDM[i];
      }
      final pdi = smTR == 0 ? 0.0 : smP / smTR * 100;
      final mdi = smTR == 0 ? 0.0 : smM / smTR * 100;
      pDIOut[i]  = pdi;
      mDIOut[i]  = mdi;
      final s = pdi + mdi;
      dxList.add(s == 0 ? 0.0 : (pdi - mdi).abs() / s * 100);
    }
    if (dxList.length >= period) {
      double adxVal = dxList.take(period).fold(0.0, (s, v) => s + v) / period;
      adxOut[2 * period - 1] = adxVal;
      for (int i = period; i < dxList.length; i++) {
        adxVal = (adxVal * (period - 1) + dxList[i]) / period;
        adxOut[period + i] = adxVal;
      }
    }
    return (adx: adxOut, plusDI: pDIOut, minusDI: mDIOut);
  }

  /// Chandelier Exit.
  /// dir == 1 → bullish (price above long-side stop)
  /// dir == -1 → bearish (price below short-side stop)
  static ({List<double> stop, List<int> dir}) chandelier(
    List<Candle> cs, int period, double mult,
  ) {
    final n    = cs.length;
    final atrV = atr(cs, period);
    final stop = List<double>.filled(n, double.nan);
    final dir  = List<int>.filled(n, 1);

    if (n > 1) dir[0] = cs[1].close >= cs[0].close ? 1 : -1;

    for (int i = period; i < n; i++) {
      if (atrV[i].isNaN) { dir[i] = dir[i - 1]; continue; }
      double hh = cs[i - period].high, ll = cs[i - period].low;
      for (int j = i - period + 1; j < i; j++) {
        if (cs[j].high > hh) hh = cs[j].high;
        if (cs[j].low  < ll) ll = cs[j].low;
      }
      final longStop  = hh - mult * atrV[i];
      final shortStop = ll + mult * atrV[i];

      final prevDir = dir[i - 1];
      if (prevDir == 1) {
        final prevStop = stop[i - 1].isNaN ? longStop : stop[i - 1];
        stop[i] = max(longStop, prevStop);
        dir[i]  = cs[i].close > stop[i] ? 1 : -1;
        if (dir[i] == -1) stop[i] = shortStop;
      } else {
        final prevStop = stop[i - 1].isNaN ? shortStop : stop[i - 1];
        stop[i] = min(shortStop, prevStop);
        dir[i]  = cs[i].close < stop[i] ? -1 : 1;
        if (dir[i] == 1) stop[i] = longStop;
      }
    }
    return (stop: stop, dir: dir);
  }

  /// Supertrend indicator.
  static ({List<double> st, List<int> dir}) supertrend(
    List<Candle> cs, int period, double mult,
  ) {
    final atrV = atr(cs, period);
    final n    = cs.length;
    final st   = List<double>.filled(n, double.nan);
    final dir  = List<int>.filled(n, -1);
    final ub   = List<double>.filled(n, double.nan);
    final lb   = List<double>.filled(n, double.nan);
    for (int i = period - 1; i < n; i++) {
      final hl2     = (cs[i].high + cs[i].low) / 2;
      final ubBasic = hl2 + mult * atrV[i];
      final lbBasic = hl2 - mult * atrV[i];
      ub[i] = (i > 0 && !ub[i-1].isNaN)
          ? (ubBasic < ub[i-1] || cs[i-1].close > ub[i-1] ? ubBasic : ub[i-1])
          : ubBasic;
      lb[i] = (i > 0 && !lb[i-1].isNaN)
          ? (lbBasic > lb[i-1] || cs[i-1].close < lb[i-1] ? lbBasic : lb[i-1])
          : lbBasic;
      if (i == period - 1) { st[i] = ub[i]; dir[i] = -1; }
      else if (!st[i-1].isNaN) {
        dir[i] = (st[i-1] == ub[i-1])
            ? (cs[i].close > ub[i] ? 1 : -1)
            : (cs[i].close < lb[i] ? -1 : 1);
        st[i] = dir[i] == 1 ? lb[i] : ub[i];
      }
    }
    return (st: st, dir: dir);
  }

  /// Binary-search for the last fully-closed HTF bar at time t.
  static int closedHtfIdx(List<Candle> src, DateTime t) {
    int lo = 0, hi = src.length - 1, res = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (!src[mid].time.isAfter(t)) { res = mid; lo = mid + 1; }
      else hi = mid - 1;
    }
    return res - 1; // last fully-closed bar
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY INTERFACE
// ════════════════════════════════════════════════════════════════════════════

abstract class StrategyParams {
  String get label;
  double get atrStopMult;
  double get atrTargetMult;
}

abstract class Strategy {
  String get name;
  List<StrategyParams> grid();
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  });
}

// ─── Simulation state ────────────────────────────────────────────────────────
class _Sim {
  bool inTrade = false;
  TradeDirection dir = TradeDirection.long;
  double entryPrice = 0, stopLoss = 0, takeProfit = 0, origStop = 0;
  DateTime entryTime = DateTime(0);
  int entryBar = 0;
  bool beSet = false;
}

double _entryFill(double px, TradeDirection d) =>
    d == TradeDirection.long ? px * (1 + kSlippagePerSide) : px * (1 - kSlippagePerSide);
double _exitFill(double px, TradeDirection d) =>
    d == TradeDirection.long ? px * (1 - kSlippagePerSide) : px * (1 + kSlippagePerSide);

({bool doExit, String reason, double exitIdeal}) _checkExit(
  _Sim s, Candle bar, double atrNow, double atrStopMult,
) {
  bool   doExit    = false;
  String reason    = '';
  double exitIdeal = bar.close;

  if (s.dir == TradeDirection.long) {
    if (!s.beSet && bar.close >= s.entryPrice + (s.entryPrice - s.origStop)) {
      s.stopLoss = max(s.stopLoss, s.entryPrice);
      s.beSet    = true;
    }
    if (bar.high >= s.takeProfit) {
      doExit = true; reason = 'Target'; exitIdeal = s.takeProfit;
    } else if (bar.low <= s.stopLoss) {
      doExit = true; reason = 'ATR Stop'; exitIdeal = s.stopLoss;
    }
    if (!doExit) {
      final trail = bar.close - atrStopMult * atrNow;
      if (trail > s.stopLoss) s.stopLoss = trail;
    }
  } else {
    if (!s.beSet && bar.close <= s.entryPrice - (s.origStop - s.entryPrice)) {
      s.stopLoss = min(s.stopLoss, s.entryPrice);
      s.beSet    = true;
    }
    if (bar.low <= s.takeProfit) {
      doExit = true; reason = 'Target'; exitIdeal = s.takeProfit;
    } else if (bar.high >= s.stopLoss) {
      doExit = true; reason = 'ATR Stop'; exitIdeal = s.stopLoss;
    }
    if (!doExit) {
      final trail = bar.close + atrStopMult * atrNow;
      if (trail < s.stopLoss) s.stopLoss = trail;
    }
  }
  return (doExit: doExit, reason: reason, exitIdeal: exitIdeal);
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 1 — CHANDELIER-1h
// ════════════════════════════════════════════════════════════════════════════
//
//  Entry timeframe: 1h  (vs 15m in v3 → 4× less noise, 4× less fee drag)
//  Confirmation   : 4h chandelier direction + daily EMA20 slope
//  Trigger        : 1h chandelier flips bullish (long) / bearish (short)
//  Confirm entry  : 1h price above EMA50 (long) / below EMA50 (short)
//  Regime gate    : ADX(14,4h) > adxMin  +  daily EMA20 slope aligns
//  Volume gate    : 1h bar volume > volFactor × SMA20(1h vol)
//  Stops          : ATR × atrStopMult (wider at 1h → less noise stop-out)
//  Target         : ATR × atrTargetMult (4–7×) — let winners run for hours
//  Trailing       : chandelier stop ratcheted on 1h bars
//  Break-even     : once +1R profit, stop moved to entry
// ════════════════════════════════════════════════════════════════════════════

class ChandelierParams extends StrategyParams {
  final int    chPeriod, adxMin;
  final double chMult, volFactor;
  @override final double atrStopMult, atrTargetMult;
  ChandelierParams(this.chPeriod, this.adxMin, this.chMult,
      this.volFactor, this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'CH($chPeriod,${chMult.toStringAsFixed(1)}) ADX>$adxMin '
      'Vol>×${volFactor.toStringAsFixed(1)} SL×$atrStopMult TP×$atrTargetMult';
}

class ChandelierMtf1h extends Strategy {
  @override String get name => 'Chandelier-1h';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final chPeriod in [14, 22]) {
      for (final chMult in [2.0, 2.5, 3.0]) {
        for (final adxMin in [20, 25]) {
          for (final atrStop in [2.0, 2.5, 3.0]) {
            for (final atrTarget in [4.0, 5.5, 7.0]) {
              for (final volFactor in [1.2, 1.5]) {
                out.add(ChandelierParams(chPeriod, adxMin, chMult,
                    volFactor, atrStop, atrTarget));
              }
            }
          }
        }
      }
    }
    return out; // 2×3×2×3×3×2 = 216 combos
  }

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  }) {
    final p   = params as ChandelierParams;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;
    final c1d = tfCandles[Timeframe.d1]!;

    if (c1h.length < p.chPeriod + 60 || c4h.length < p.chPeriod + 10 || c1d.length < 25)
      return [];

    final cl1h     = c1h.map((c) => c.close).toList();
    final vol1h    = c1h.map((c) => c.volume).toList();
    final e50_1h   = Indicators.ema(cl1h, 50);
    final atr1h    = Indicators.atr(c1h, 14);
    final volSma1h = Indicators.sma(vol1h, 20);

    final ch1h  = Indicators.chandelier(c1h, p.chPeriod, p.chMult);
    final adx4h = Indicators.adx(c4h, 14);
    final ch4h  = Indicators.chandelier(c4h, p.chPeriod, p.chMult);

    // Daily EMA20 for macro slope filter
    final cl1d    = c1d.map((c) => c.close).toList();
    final e20_1d  = Indicators.ema(cl1d, 20);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = max(p.chPeriod + 10, 50); i < c1h.length - 1; i++) {
      if (atr1h[i].isNaN || e50_1h[i].isNaN || volSma1h[i].isNaN) continue;

      final t   = c1h[i].time;
      final i4h = Indicators.closedHtfIdx(c4h, t);
      final i1d = Indicators.closedHtfIdx(c1d, t);
      if (i4h < 1 || i1d < 1) continue;
      if (adx4h.adx[i4h].isNaN) continue;
      if (e20_1d[i1d].isNaN || e20_1d[i1d - 1].isNaN) continue;

      // Reject spike bars (extreme range = false signal)
      final barRange = c1h[i].high - c1h[i].low;
      if (barRange > 2.0 * atr1h[i]) continue;

      if (!s.inTrade) {
        final adxOk   = adx4h.adx[i4h] > p.adxMin;
        final volOk   = c1h[i].volume > p.volFactor * volSma1h[i];
        final d4h = ch4h.dir[i4h];
        final d1h = ch1h.dir[i];
        final d1hPrev = ch1h.dir[i > 0 ? i - 1 : 0];

        // 1h chandelier flip triggers
        final flipL = d1h == 1  && d1hPrev == -1;
        final flipS = d1h == -1 && d1hPrev == 1;

        // Daily EMA slope
        final dBull = e20_1d[i1d] > e20_1d[i1d - 1];
        final dBear = e20_1d[i1d] < e20_1d[i1d - 1];

        // 1h price-side confirmation
        final above1h = c1h[i].close > e50_1h[i];
        final below1h = c1h[i].close < e50_1h[i];

        if (adxOk && volOk && d4h == 1 && dBull && flipL && above1h) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        } else if (adxOk && volOk && d4h == -1 && dBear && flipS && below1h) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        }
      } else {
        // Ratchet chandelier stop
        if (s.dir == TradeDirection.long && !ch1h.stop[i].isNaN) {
          if (ch1h.stop[i] > s.stopLoss && ch1h.stop[i] < s.entryPrice * 1.5)
            s.stopLoss = ch1h.stop[i];
        } else if (s.dir == TradeDirection.short && !ch1h.stop[i].isNaN) {
          if (ch1h.stop[i] < s.stopLoss && ch1h.stop[i] > s.entryPrice * 0.5)
            s.stopLoss = ch1h.stop[i];
        }

        final ex = _checkExit(s, c1h[i], atr1h[i], p.atrStopMult);
        var doExit = ex.doExit; var reason = ex.reason; var exitIdeal = ex.exitIdeal;
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c1h[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: s.entryTime, exitTime: c1h[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx, direction: s.dir,
              strategyName: name, symbol: symbol, exitReason: reason,
            ));
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 2 — TRENDPULLBACK-1h
// ════════════════════════════════════════════════════════════════════════════
//
//  Entry timeframe: 1h
//  Trend filter   : 4h EMA(fast) > EMA(slow)  (long) / reverse (short)
//                   Daily EMA20 slope aligned with trade direction
//  Momentum gate  : ADX(14,4h) > adxMin
//  Pullback zone  : 4h RSI(14) in [rsiLow, rsiHigh] — not over-extended
//  Trigger        : 1h EMA fast crosses slow in trend direction
//  Volume gate    : 1h bar volume > volFactor × SMA20(1h vol)
//  Exit           : fixed target (atrTargetMult) | trailing stop | break-even
// ════════════════════════════════════════════════════════════════════════════

class TrendPullback1hParams extends StrategyParams {
  final int    fast, slow, adxMin;
  final double rsiLow, rsiHigh, volFactor;
  @override final double atrStopMult, atrTargetMult;
  TrendPullback1hParams(this.fast, this.slow, this.adxMin,
      this.rsiLow, this.rsiHigh, this.volFactor,
      this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'EMA($fast/$slow) ADX>$adxMin RSI[$rsiLow,$rsiHigh] '
      'Vol>×${volFactor.toStringAsFixed(1)} SL×$atrStopMult TP×$atrTargetMult';
}

class TrendPullback1h extends Strategy {
  @override String get name => 'TrendPullback-1h';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final fast in [9, 13]) {
      for (final slow in [21, 34]) {
        for (final adx in [20, 25]) {
          for (final rsiZone in [(35.0, 60.0), (40.0, 65.0)]) {
            for (final atrStop in [2.0, 2.5]) {
              for (final atrTarget in [4.0, 6.0]) {
                out.add(TrendPullback1hParams(fast, slow, adx,
                    rsiZone.$1, rsiZone.$2, 1.2, atrStop, atrTarget));
              }
            }
          }
        }
      }
    }
    return out; // 2×2×2×2×2×2 = 64 combos
  }

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  }) {
    final p   = params as TrendPullback1hParams;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;
    final c1d = tfCandles[Timeframe.d1]!;

    if (c1h.length < p.slow + 30 || c4h.length < p.slow + 14 || c1d.length < 25) return [];

    final cl1h     = c1h.map((c) => c.close).toList();
    final vol1h    = c1h.map((c) => c.volume).toList();
    final eF1h     = Indicators.ema(cl1h, p.fast);
    final eS1h     = Indicators.ema(cl1h, p.slow);
    final atr1h    = Indicators.atr(c1h, 14);
    final volSma1h = Indicators.sma(vol1h, 20);

    final cl4h  = c4h.map((c) => c.close).toList();
    final eF4h  = Indicators.ema(cl4h, p.fast);
    final eS4h  = Indicators.ema(cl4h, p.slow);
    final rsi4h = Indicators.rsi(cl4h, 14);
    final adx4h = Indicators.adx(c4h, 14);

    final cl1d   = c1d.map((c) => c.close).toList();
    final e20_1d = Indicators.ema(cl1d, 20);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = p.slow + 10; i < c1h.length - 1; i++) {
      if (atr1h[i].isNaN || eF1h[i].isNaN || eS1h[i].isNaN || volSma1h[i].isNaN) continue;

      final t   = c1h[i].time;
      final i4h = Indicators.closedHtfIdx(c4h, t);
      final i1d = Indicators.closedHtfIdx(c1d, t);
      if (i4h < 1 || i1d < 1) continue;
      if (adx4h.adx[i4h].isNaN || rsi4h[i4h].isNaN) continue;
      if (e20_1d[i1d].isNaN || e20_1d[i1d - 1].isNaN) continue;

      final barRange = c1h[i].high - c1h[i].low;
      if (barRange > 2.0 * atr1h[i]) continue;

      if (!s.inTrade) {
        final adxOk = adx4h.adx[i4h] > p.adxMin;
        final volOk = c1h[i].volume > p.volFactor * volSma1h[i];
        final rsi   = rsi4h[i4h];
        final dBull = e20_1d[i1d] > e20_1d[i1d - 1];
        final dBear = e20_1d[i1d] < e20_1d[i1d - 1];

        // 4h trend
        final trendBull = eF4h[i4h] > eS4h[i4h];
        final trendBear = eF4h[i4h] < eS4h[i4h];

        // 1h cross triggers
        final crossUp   = eF1h[i] > eS1h[i] && eF1h[i - 1] <= eS1h[i - 1];
        final crossDown = eF1h[i] < eS1h[i] && eF1h[i - 1] >= eS1h[i - 1];

        // RSI pullback (not over-extended in direction)
        final rsiOkL = rsi >= p.rsiLow  && rsi <= p.rsiHigh;
        final rsiOkS = rsi >= (100 - p.rsiHigh) && rsi <= (100 - p.rsiLow);

        if (adxOk && volOk && trendBull && dBull && crossUp && rsiOkL) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        } else if (adxOk && volOk && trendBear && dBear && crossDown && rsiOkS) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        }
      } else {
        final ex = _checkExit(s, c1h[i], atr1h[i], p.atrStopMult);
        var doExit = ex.doExit; var reason = ex.reason; var exitIdeal = ex.exitIdeal;
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c1h[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: s.entryTime, exitTime: c1h[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx, direction: s.dir,
              strategyName: name, symbol: symbol, exitReason: reason,
            ));
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 3 — SUPERTREND-1h (Dual TF confirmation)
// ════════════════════════════════════════════════════════════════════════════
//
//  Entry timeframe: 1h
//  Confirmation   : 4h supertrend must agree
//  Daily EMA slope must align
//  ADX gate on 4h
//  Volume gate on 1h
// ════════════════════════════════════════════════════════════════════════════

class Supertrend1hParams extends StrategyParams {
  final int    stPeriod, adxMin;
  final double stMult, volFactor;
  @override final double atrStopMult, atrTargetMult;
  Supertrend1hParams(this.stPeriod, this.adxMin, this.stMult,
      this.volFactor, this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'ST($stPeriod,${stMult.toStringAsFixed(1)}) ADX>$adxMin '
      'Vol>×${volFactor.toStringAsFixed(1)} SL×$atrStopMult TP×$atrTargetMult';
}

class Supertrend1h extends Strategy {
  @override String get name => 'Supertrend-1h';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final stPeriod in [10, 14]) {
      for (final stMult in [2.0, 3.0]) {
        for (final adxMin in [20, 25]) {
          for (final atrStop in [2.0, 2.5]) {
            for (final atrTarget in [4.0, 5.5]) {
              for (final volFactor in [1.2, 1.5]) {
                out.add(Supertrend1hParams(stPeriod, adxMin, stMult,
                    volFactor, atrStop, atrTarget));
              }
            }
          }
        }
      }
    }
    return out; // 2×2×2×2×2×2 = 64 combos
  }

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  }) {
    final p   = params as Supertrend1hParams;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;
    final c1d = tfCandles[Timeframe.d1]!;

    if (c1h.length < p.stPeriod + 30 || c4h.length < p.stPeriod + 10 || c1d.length < 25)
      return [];

    final vol1h    = c1h.map((c) => c.volume).toList();
    final cl1h     = c1h.map((c) => c.close).toList();
    final atr1h    = Indicators.atr(c1h, 14);
    final volSma1h = Indicators.sma(vol1h, 20);
    final e50_1h   = Indicators.ema(cl1h, 50);

    final st1h  = Indicators.supertrend(c1h, p.stPeriod, p.stMult);
    final adx4h = Indicators.adx(c4h, 14);
    final st4h  = Indicators.supertrend(c4h, p.stPeriod, p.stMult);

    final cl1d   = c1d.map((c) => c.close).toList();
    final e20_1d = Indicators.ema(cl1d, 20);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = max(p.stPeriod + 5, 50); i < c1h.length - 1; i++) {
      if (atr1h[i].isNaN || st1h.dir[i] == 0 || volSma1h[i].isNaN || e50_1h[i].isNaN) continue;

      final t   = c1h[i].time;
      final i4h = Indicators.closedHtfIdx(c4h, t);
      final i1d = Indicators.closedHtfIdx(c1d, t);
      if (i4h < 1 || i1d < 1) continue;
      if (adx4h.adx[i4h].isNaN) continue;
      if (e20_1d[i1d].isNaN || e20_1d[i1d - 1].isNaN) continue;

      final barRange = c1h[i].high - c1h[i].low;
      if (barRange > 2.0 * atr1h[i]) continue;

      if (!s.inTrade) {
        final adxOk = adx4h.adx[i4h] > p.adxMin;
        final volOk = c1h[i].volume > p.volFactor * volSma1h[i];
        final dBull = e20_1d[i1d] > e20_1d[i1d - 1];
        final dBear = e20_1d[i1d] < e20_1d[i1d - 1];

        final d1h     = st1h.dir[i];
        final d1hPrev = st1h.dir[i > 0 ? i - 1 : 0];
        final d4h     = st4h.dir[i4h];

        final flipL = d1h == 1  && d1hPrev == -1;
        final flipS = d1h == -1 && d1hPrev == 1;

        if (adxOk && volOk && d4h == 1 && dBull && flipL && c1h[i].close > e50_1h[i]) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        } else if (adxOk && volOk && d4h == -1 && dBear && flipS && c1h[i].close < e50_1h[i]) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c1h[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr1h[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr1h[i];
          s.inTrade    = true; s.entryTime = c1h[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        }
      } else {
        final ex = _checkExit(s, c1h[i], atr1h[i], p.atrStopMult);
        var doExit = ex.doExit; var reason = ex.reason; var exitIdeal = ex.exitIdeal;
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c1h[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: s.entryTime, exitTime: c1h[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx, direction: s.dir,
              strategyName: name, symbol: symbol, exitReason: reason,
            ));
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// WALK-FORWARD OPTIMIZATION ENGINE
// ════════════════════════════════════════════════════════════════════════════

class WalkForwardWindow {
  final DateTime isStart, isEnd, oosStart, oosEnd;
  final int index;
  WalkForwardWindow({
    required this.isStart, required this.isEnd,
    required this.oosStart, required this.oosEnd, required this.index,
  });
  String get label => 'W${index.toString().padLeft(2, '0')}';
}

class WfoEngine {
  final int isLengthDays;
  final int oosLengthDays;
  final int minIsTrades;
  WfoEngine({this.isLengthDays = 90, this.oosLengthDays = 30, this.minIsTrades = 8});

  List<WalkForwardWindow> _windows(DateTime start, DateTime end) {
    final wins = <WalkForwardWindow>[];
    var isStart = start;
    int idx = 1;
    while (true) {
      final isEnd  = isStart.add(Duration(days: isLengthDays));
      final oosEnd = isEnd.add(Duration(days: oosLengthDays));
      if (oosEnd.isAfter(end)) break;
      wins.add(WalkForwardWindow(
        isStart: isStart, isEnd: isEnd,
        oosStart: isEnd, oosEnd: oosEnd, index: idx++,
      ));
      isStart = isStart.add(Duration(days: oosLengthDays));
    }
    return wins;
  }

  Map<Timeframe, List<Candle>> _slice(
    Map<Timeframe, List<Candle>> all, DateTime from, DateTime to,
  ) {
    final out = <Timeframe, List<Candle>>{};
    for (final tf in all.keys)
      out[tf] = all[tf]!.where((c) => !c.time.isBefore(from) && c.time.isBefore(to)).toList();
    return out;
  }

  Map<String, List<StrategyResult>> runAll({
    required String symbol,
    required Map<Timeframe, List<Candle>> allTf,
    required List<Strategy> strategies,
  }) {
    // v4 uses 1h bars as base for window generation
    final base = allTf[Timeframe.h1]!;
    if (base.isEmpty) return {};
    final wins = _windows(base.first.time, base.last.time);
    if (wins.isEmpty) {
      print('  ⚠  Not enough data for walk-forward on $symbol');
      return {};
    }
    print('  → ${wins.length} walk-forward windows');

    final byStrategy = <String, List<StrategyResult>>{};
    for (final s in strategies) byStrategy[s.name] = [];

    for (final win in wins) {
      final warmup = _slice(allTf, win.isStart, win.oosEnd);
      final h1Len  = warmup[Timeframe.h1]?.length ?? 0;
      if (h1Len < 100) {
        print('  ⚠  ${win.label}: too few 1h bars ($h1Len), skipping');
        continue;
      }

      for (final strategy in strategies) {
        final combos = strategy.grid();

        // IS optimisation — pick by expectancy × √trades
        StrategyParams? bestParams;
        double bestScore   = -double.infinity;
        int    bestIsN     = 0;
        double bestIsExpec = 0;
        for (final combo in combos) {
          final isTrades = strategy.backtest(
            symbol: symbol, tfCandles: warmup,
            oosFrom: win.isStart, oosTo: win.isEnd, params: combo,
          );
          final isResult = StrategyResult(
            strategyName: strategy.name, symbol: symbol,
            trades: isTrades, windowLabel: '${win.label}-IS', paramsLabel: combo.label,
          );
          if (isResult.isOptScore > bestScore) {
            bestScore   = isResult.isOptScore;
            bestParams  = combo;
            bestIsN     = isResult.totalTrades;
            bestIsExpec = isResult.expectancy;
          }
        }
        if (bestParams == null) continue;

        // ── IS PASS GATE ─────────────────────────────────────────────────────
        // Skip OOS if IS period does not show positive expectancy AND
        // sufficient sample size.  High R:R strategies are legitimately
        // profitable at 25-30% win rate — no win-rate gate applied.
        if (bestIsExpec <= 0.0 || bestIsN < minIsTrades) continue;

        // OOS evaluation with best IS params
        final oosTrades = strategy.backtest(
          symbol: symbol, tfCandles: warmup,
          oosFrom: win.oosStart, oosTo: win.oosEnd, params: bestParams,
        );
        byStrategy[strategy.name]!.add(StrategyResult(
          strategyName: strategy.name, symbol: symbol,
          trades: oosTrades, windowLabel: win.label, paramsLabel: bestParams.label,
        ));
      }
    }
    return byStrategy;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// REPORTER
// ════════════════════════════════════════════════════════════════════════════

class Reporter {
  static String _f(double v, {int d = 2}) =>
      (v.isNaN || v.isInfinite) ? 'N/A' : v.toStringAsFixed(d);

  static StrategyResult consolidate(String strat, String sym, List<StrategyResult> wins) =>
      StrategyResult(
        strategyName: strat, symbol: sym,
        trades: wins.expand((w) => w.trades).toList(),
        windowLabel: 'CONSOLIDATED-OOS',
      );

  static void banner() {
    print('''
╔══════════════════════════════════════════════════════════════════════════════╗
║   CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER v4 (1h PRECISION)         ║
║   1h entry · 4h+Daily confirm · Daily EMA slope gate · IS PASS GATE         ║
║   IS window: 90d  |  OOS: 30d  |  min IS trades: 8                          ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
  }

  static void windowTable(String strat, String sym, List<StrategyResult> wins) {
    print('\n  ┌─ OOS Window Breakdown │ $strat │ $sym');
    print('  │  Win    Trades  Win%    Ret%      PF   Sharpe  MaxDD%  Score   Best IS Params');
    print('  │  ${"─" * 95}');
    for (final w in wins) {
      final pf = w.profitFactor.isInfinite ? '∞' : _f(w.profitFactor);
      print(
        '  │  ${w.windowLabel.padRight(5)} '
        '${w.totalTrades.toString().padLeft(6)} '
        '${_f(w.winRate).padLeft(6)} '
        '${_f(w.totalReturn).padLeft(8)} '
        '${pf.padLeft(6)} '
        '${_f(w.sharpeRatio).padLeft(7)} '
        '${_f(w.maxDrawdown).padLeft(7)} '
        '${_f(w.compositeScore).padLeft(6)}   ${w.paramsLabel}',
      );
    }
    print('  └─');
  }

  static void strategyCard(StrategyResult r) {
    print('\n${"─" * 80}');
    print('  Strategy  : ${r.strategyName}');
    print('  Symbol    : ${r.symbol}   ${r.windowLabel}');
    print('${"─" * 80}');
    if (r.totalTrades == 0) { print('  ⚠  No OOS trades.\n'); return; }
    final rows = [
      ['Total Trades',     r.totalTrades.toString()],
      ['Winning',          '${r.winningTrades}  (${_f(r.winRate)}%)'],
      ['Losing',           r.losingTrades.toString()],
      ['Total Return',     '${_f(r.totalReturn)}%'],
      ['Avg Win',          '${_f(r.avgWin)}%'],
      ['Avg Loss',         '${_f(r.avgLoss)}%'],
      ['Profit Factor',    r.profitFactor.isInfinite ? '∞' : _f(r.profitFactor)],
      ['Sharpe',           _f(r.sharpeRatio)],
      ['Max Drawdown',     '${_f(r.maxDrawdown)}%'],
      ['Expectancy',       '${_f(r.expectancy)}%/trade'],
      ['Calmar',           _f(r.calmarRatio)],
      ['Composite Score',  '${_f(r.compositeScore)} / 100'],
    ];
    for (final row in rows) print('  ${row[0].padRight(20)}  ${row[1]}');

    final reasons = <String, int>{};
    for (final t in r.trades) reasons[t.exitReason] = (reasons[t.exitReason] ?? 0) + 1;
    print('\n  Exit reasons:');
    for (final e in reasons.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
      print('    ${e.key.padRight(22)} ${e.value}');

    final longs  = r.trades.where((t) => t.direction == TradeDirection.long).toList();
    final shorts = r.trades.where((t) => t.direction == TradeDirection.short).toList();
    final lWR = longs.isEmpty  ? 0.0 : longs.where((t) => t.pnlPct > 0).length / longs.length * 100;
    final sWR = shorts.isEmpty ? 0.0 : shorts.where((t) => t.pnlPct > 0).length / shorts.length * 100;
    print('\n  Longs : ${longs.length} trades  win rate ${_f(lWR)}%');
    print('  Shorts: ${shorts.length} trades  win rate ${_f(sWR)}%');
  }

  static void leaderboard(Map<String, Map<String, StrategyResult>> cons) {
    final all = <({String sym, String strat, StrategyResult r})>[];
    for (final sym in cons.keys)
      for (final st in cons[sym]!.keys)
        all.add((sym: sym, strat: st, r: cons[sym]![st]!));
    all.sort((a, b) => b.r.compositeScore.compareTo(a.r.compositeScore));

    print('''

╔══════════════════════════════════════════════════════════════════════════════╗
║              OVERALL OOS LEADERBOARD (composite score, OOS-only)            ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
    print('Rank  Symbol       Strategy              Trades  Win%    Ret%     PF  Sharpe  DD%   Score');
    print('─' * 97);
    int shown = 0;
    for (final e in all) {
      if (e.r.totalTrades == 0) continue;
      final pf    = e.r.profitFactor.isInfinite ? '∞' : _f(e.r.profitFactor);
      final medal = shown == 0 ? ' 🥇' : shown == 1 ? ' 🥈' : shown == 2 ? ' 🥉' : '';
      print(
        '${(shown + 1).toString().padRight(5)} '
        '${e.sym.padRight(12)} ${e.strat.padRight(20)} '
        '${e.r.totalTrades.toString().padLeft(6)} '
        '${_f(e.r.winRate).padLeft(6)} '
        '${_f(e.r.totalReturn).padLeft(7)} '
        '${pf.padLeft(6)} '
        '${_f(e.r.sharpeRatio).padLeft(7)} '
        '${_f(e.r.maxDrawdown).padLeft(6)} '
        '${_f(e.r.compositeScore).padLeft(6)}$medal',
      );
      shown++;
    }

    print('\n╔══════════════════════════════════════════════════════════════════════════════╗');
    print('║                       BEST STRATEGY PER SYMBOL                             ║');
    print('╚══════════════════════════════════════════════════════════════════════════════╝\n');

    final bySym = <String, ({String strat, StrategyResult r})>{};
    for (final e in all) {
      if (e.r.totalTrades == 0) continue;
      if (!bySym.containsKey(e.sym) || e.r.compositeScore > bySym[e.sym]!.r.compositeScore)
        bySym[e.sym] = (strat: e.strat, r: e.r);
    }
    for (final sym in bySym.keys.toList()..sort()) {
      final b = bySym[sym]!;
      print('  ► $sym  →  ${b.strat}');
      print(
        '    Trades:${b.r.totalTrades}  Win:${_f(b.r.winRate)}%  '
        'Return:${_f(b.r.totalReturn)}%  PF:${b.r.profitFactor.isInfinite ? "∞" : _f(b.r.profitFactor)}  '
        'Expectancy:${_f(b.r.expectancy)}%  MaxDD:${_f(b.r.maxDrawdown)}%  '
        'Score:${_f(b.r.compositeScore)}/100\n',
      );
    }
  }

  static void exportCsv(
    Map<String, Map<String, StrategyResult>> cons,
    Map<String, Map<String, List<StrategyResult>>> wins,
    String outDir,
  ) {
    Directory(outDir).createSync(recursive: true);

    final lb   = File('$outDir/leaderboard_v4.csv');
    final lbSb = StringBuffer(
      'Symbol,Strategy,Trades,WinRate%,TotalReturn%,AvgWin%,AvgLoss%,'
      'ProfitFactor,Sharpe,MaxDD%,Expectancy%,Calmar,CompositeScore\n',
    );
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        final r  = cons[sym]![st]!;
        final pf = r.profitFactor.isInfinite ? 999.0 : r.profitFactor;
        lbSb.writeln(
          '$sym,$st,${r.totalTrades},${_f(r.winRate)},${_f(r.totalReturn)},'
          '${_f(r.avgWin)},${_f(r.avgLoss)},${_f(pf)},${_f(r.sharpeRatio)},'
          '${_f(r.maxDrawdown)},${_f(r.expectancy)},${_f(r.calmarRatio)},${_f(r.compositeScore)}',
        );
      }
    }
    lb.writeAsStringSync(lbSb.toString());

    final tr   = File('$outDir/all_trades_v4.csv');
    final trSb = StringBuffer(
      'Symbol,Strategy,Direction,EntryTime,ExitTime,EntryPrice,ExitPrice,PnL%,ExitReason,HoldingMin\n',
    );
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        for (final t in cons[sym]![st]!.trades) {
          trSb.writeln(
            '${t.symbol},${t.strategyName},${t.direction.name},'
            '${t.entryTime.toIso8601String()},${t.exitTime.toIso8601String()},'
            '${t.entryPrice},${t.exitPrice},${_f(t.pnlPct)},${t.exitReason},'
            '${t.holdingPeriod.inMinutes}',
          );
        }
      }
    }
    tr.writeAsStringSync(trSb.toString());

    final wb   = File('$outDir/window_breakdown_v4.csv');
    final wbSb = StringBuffer(
      'Symbol,Strategy,Window,BestParams,Trades,WinRate%,TotalReturn%,'
      'ProfitFactor,Sharpe,MaxDD%,Expectancy%,Score\n',
    );
    for (final sym in wins.keys) {
      for (final st in wins[sym]!.keys) {
        for (final w in wins[sym]![st]!) {
          final pf = w.profitFactor.isInfinite ? 999.0 : w.profitFactor;
          wbSb.writeln(
            '$sym,$st,${w.windowLabel},"${w.paramsLabel}",${w.totalTrades},'
            '${_f(w.winRate)},${_f(w.totalReturn)},${_f(pf)},'
            '${_f(w.sharpeRatio)},${_f(w.maxDrawdown)},${_f(w.expectancy)},${_f(w.compositeScore)}',
          );
        }
      }
    }
    wb.writeAsStringSync(wbSb.toString());

    print('  📄 leaderboard_v4.csv');
    print('  📄 all_trades_v4.csv');
    print('  📄 window_breakdown_v4.csv');
    print('\n  All files saved to: $outDir/');
  }
}

// ════════════════════════════════════════════════════════════════════════════
// MAIN
// ════════════════════════════════════════════════════════════════════════════

void main(List<String> args) {
  Reporter.banner();

  final dataDir = args.isNotEmpty ? args[0] : 'C:\\Users\\GIGA\\Desktop\\Candle Data';
  final outDir  = args.length > 1 ? args[1] : './wf_results_v4';

  const int isLengthDays  = 90;  // longer IS → better stats on fewer 1h trades
  const int oosLengthDays = 30;

  print('Configuration');
  print('  Data dir       : $dataDir');
  print('  Output dir     : $outDir');
  print('  IS window      : $isLengthDays days  (param optimisation)');
  print('  OOS window     : $oosLengthDays days  (reported only)');
  print('  Entry TF       : 1h (primary)');
  print('  Confirm TF     : 4h + daily');
  print('  Slippage/side  : ${kSlippagePerSide * 1e4} bps');
  print('  Fee/side       : ${kFeePerSide * 1e4} bps');
  print('  Max bars/trade : $kMaxBarsInTrade (= ${kMaxBarsInTrade ~/ 24} days on 1h)\n');

  print('Scanning for assets...');
  final raw5m = CsvLoader.loadDirectory(dataDir);
  if (raw5m.isEmpty) {
    print('\n  ⛔  No data found. Check path: $dataDir');
    return;
  }

  print('\nAggregating timeframes...');
  final allTf = <String, Map<Timeframe, List<Candle>>>{};
  for (final sym in raw5m.keys) {
    allTf[sym] = {
      Timeframe.m5:  raw5m[sym]!,
      Timeframe.m15: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m15),
      Timeframe.h1:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h1),
      Timeframe.h4:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h4),
      Timeframe.d1:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.d1),
    };
    final tf = allTf[sym]!;
    print(
      '  $sym → 5m:${tf[Timeframe.m5]!.length}'
      ' | 15m:${tf[Timeframe.m15]!.length}'
      ' | 1h:${tf[Timeframe.h1]!.length}'
      ' | 4h:${tf[Timeframe.h4]!.length}'
      ' | 1d:${tf[Timeframe.d1]!.length}',
    );
  }

  final strategies = <Strategy>[
    ChandelierMtf1h(),
    TrendPullback1h(),
    Supertrend1h(),
  ];

  final engine       = WfoEngine(isLengthDays: isLengthDays, oosLengthDays: oosLengthDays);
  final consolidated = <String, Map<String, StrategyResult>>{};
  final allWins      = <String, Map<String, List<StrategyResult>>>{};

  for (final sym in allTf.keys) {
    print('\n══ $sym ══');
    final byStrat = engine.runAll(
      symbol: sym, allTf: allTf[sym]!, strategies: strategies,
    );
    consolidated[sym] = {};
    allWins[sym]      = {};
    for (final strat in byStrat.keys) {
      final winList = byStrat[strat]!;
      allWins[sym]![strat] = winList;
      if (winList.isEmpty) continue;
      Reporter.windowTable(strat, sym, winList);
      final cons = Reporter.consolidate(strat, sym, winList);
      consolidated[sym]![strat] = cons;
      Reporter.strategyCard(cons);
    }
  }

  Reporter.leaderboard(consolidated);

  print('\nExporting CSVs...');
  Reporter.exportCsv(consolidated, allWins, outDir);
}
