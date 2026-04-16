// ════════════════════════════════════════════════════════════════════════════
//  CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER v8
//
//  v8 improvements over v6
//  ────────────────────────────────────────────────────────────────────────────
//  1. +DI/-DI directional filter on ChandelierMtf and TrendPullbackEma.
//     v6 used ADX level only — ADX can be high in EITHER direction.
//     Adding +DI > -DI for longs ensures ADX is trending UP, not DOWN.
//     This directly fixes ETH/SOL/XRP where ADX was high but price falling.
//
//  2. NEW strategy: DonchianPullback — fundamentally different entry mechanism.
//     4h Donchian(20) breakout signals a new trend has started.
//     Wait for 1h RSI to pull back to 40-60 (first retracement after breakout).
//     Enter on 15m EMA cross resuming in breakout direction + volume spike.
//     "Buy the first pullback after breakout" — earlier entry, better R:R
//     than ChandelierMtf (which enters after ATR-channel flip, i.e. later).
//
//  Retained from v6
//  ────────────────────────────────────────────────────────────────────────────
//  • ATR trailing stop removed from _checkExit
//  • Daily EMA20 slope gate on TrendPullbackEma
//  • IS gate: expectancy > 0 AND trades >= 10
//  • Break-even stop at +1R; Chandelier trailing stop on ChandelierMtf
//  • Dropped: KAMA-Pullback, Supertrend-Quality (consistently negative)
// ════════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

// ─── Realism constants ───────────────────────────────────────────────────────
const double kSlippagePerSide = 0.0005; // 5 bps per fill
const double kFeePerSide      = 0.0004; // 4 bps per fill (taker)
const int    kMaxBarsInTrade  = 96 * 5; // 5 days on 15-min bars

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

  /// IS optimisation score: expectancy × √trades.
  /// Selects parameter combos with genuine positive edge AND enough trades
  /// to be statistically meaningful.  Pure win-count combos score low.
  double get isOptScore {
    if (totalTrades < 5) return -1000.0;
    final tradeFactor =
        min(sqrt(totalTrades.toDouble()), sqrt(50.0)) / sqrt(50.0);
    return expectancy * tradeFactor;
  }

  /// Leaderboard composite (same formula as v2 for side-by-side comparability).
  double get compositeScore {
    if (totalTrades < 5) return 0;
    final wR = winRate / 100;
    final pF = min(profitFactor.isInfinite ? 5.0 : profitFactor, 5.0) / 5.0;
    final sh = (min(max(sharpeRatio, -2.0), 4.0) + 2.0) / 6.0;
    final ex = expectancy > 0 ? min(expectancy / 2.0, 1.0) : 0.0;
    return (wR * 0.20 + pF * 0.35 + sh * 0.25 + ex * 0.20) * 100;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// CSV LOADER  (identical to v2 with 5m-subfolder fix + timeframe suffix strip)
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
    // Prefer the 5m subfolder — the engine aggregates all higher TFs internally.
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
    // Strip trailing timeframe suffix so BTCUSDT5m.csv → BTCUSDT.
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

enum Timeframe { m5, m15, m30, h1, h4, d1 }

extension TimeframeExt on Timeframe {
  int    get minutes => const {Timeframe.m5:5,Timeframe.m15:15,Timeframe.m30:30,Timeframe.h1:60,Timeframe.h4:240,Timeframe.d1:1440}[this]!;
  String get label   => const {Timeframe.m5:'5m',Timeframe.m15:'15m',Timeframe.m30:'30m',Timeframe.h1:'1h',Timeframe.h4:'4h',Timeframe.d1:'1d'}[this]!;
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
    if (bMin >= 1440) return DateTime.utc(t.year, t.month, t.day);
    final total   = t.hour * 60 + t.minute;
    final floored = (total ~/ bMin) * bMin;
    return DateTime.utc(t.year, t.month, t.day, floored ~/ 60, floored % 60);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// INDICATORS
// ════════════════════════════════════════════════════════════════════════════

class Indicators {
  // ── Moving averages ────────────────────────────────────────────────────────
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

  static List<double> wma(List<double> src, int period) {
    final out   = List<double>.filled(src.length, double.nan);
    if (src.length < period) return out;
    final denom = period * (period + 1) / 2.0;
    for (int i = period - 1; i < src.length; i++) {
      double sum = 0;
      for (int j = 0; j < period; j++) sum += src[i - j] * (period - j);
      out[i] = sum / denom;
    }
    return out;
  }

  /// Kaufman Adaptive Moving Average.
  static List<double> kama(List<double> src, int period, {int fastSc = 2, int slowSc = 30}) {
    final out    = List<double>.filled(src.length, double.nan);
    if (src.length < period + 1) return out;
    final fastA  = 2.0 / (fastSc + 1);
    final slowA  = 2.0 / (slowSc + 1);
    out[period]  = src[period];
    for (int i = period + 1; i < src.length; i++) {
      final change = (src[i] - src[i - period]).abs();
      double vol = 0;
      for (int j = i - period + 1; j <= i; j++) vol += (src[j] - src[j - 1]).abs();
      final er = vol == 0 ? 0.0 : change / vol;
      final sc = pow(er * (fastA - slowA) + slowA, 2).toDouble();
      out[i] = out[i - 1] + sc * (src[i] - out[i - 1]);
    }
    return out;
  }

  // ── Volatility ─────────────────────────────────────────────────────────────
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

  static ({List<double> upper, List<double> lower, List<double> mid}) bollinger(
    List<double> src, int period, double stdMult,
  ) {
    final mid   = sma(src, period);
    final upper = List<double>.filled(src.length, double.nan);
    final lower = List<double>.filled(src.length, double.nan);
    for (int i = period - 1; i < src.length; i++) {
      double v = 0;
      for (int j = i - period + 1; j <= i; j++) v += pow(src[j] - mid[i], 2);
      final std = sqrt(v / period);
      upper[i]  = mid[i] + stdMult * std;
      lower[i]  = mid[i] - stdMult * std;
    }
    return (upper: upper, lower: lower, mid: mid);
  }

  // ── Momentum ───────────────────────────────────────────────────────────────
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

  // ── Trend strength ─────────────────────────────────────────────────────────
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

  // ── Channel indicators ─────────────────────────────────────────────────────
  static ({List<double> upper, List<double> lower, List<double> mid}) donchian(
    List<Candle> cs, int period,
  ) {
    final n     = cs.length;
    final upper = List<double>.filled(n, double.nan);
    final lower = List<double>.filled(n, double.nan);
    final mid   = List<double>.filled(n, double.nan);
    for (int i = period - 1; i < n; i++) {
      double h = cs[i - period + 1].high, l = cs[i - period + 1].low;
      for (int j = i - period + 2; j <= i; j++) {
        if (cs[j].high > h) h = cs[j].high;
        if (cs[j].low  < l) l = cs[j].low;
      }
      upper[i] = h; lower[i] = l; mid[i] = (h + l) / 2;
    }
    return (upper: upper, lower: lower, mid: mid);
  }

  // ── Supertrend ─────────────────────────────────────────────────────────────
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

  // ── Chandelier Exit ────────────────────────────────────────────────────────
  /// Returns the active stop level and trend direction.
  /// dir == 1 → price is above the long-side chandelier (bullish)
  /// dir == -1 → price is below the short-side chandelier (bearish)
  static ({List<double> stop, List<int> dir}) chandelier(
    List<Candle> cs, int period, double mult,
  ) {
    final n    = cs.length;
    final atrV = atr(cs, period);
    final stop = List<double>.filled(n, double.nan);
    final dir  = List<int>.filled(n, 1);

    // Initial direction guess
    if (n > 1) dir[0] = cs[1].close >= cs[0].close ? 1 : -1;

    for (int i = period; i < n; i++) {
      if (atrV[i].isNaN) { dir[i] = dir[i - 1]; continue; }
      // Highest high / lowest low over period (use prior bar to avoid lookahead)
      double hh = cs[i - period].high, ll = cs[i - period].low;
      for (int j = i - period + 1; j < i; j++) {
        if (cs[j].high > hh) hh = cs[j].high;
        if (cs[j].low  < ll) ll = cs[j].low;
      }
      final longStop  = hh - mult * atrV[i];
      final shortStop = ll + mult * atrV[i];

      final prevDir = dir[i - 1];
      if (prevDir == 1) {
        // In uptrend: use long stop, ratchet it up, flip if price closes below
        final prevStop = stop[i - 1].isNaN ? longStop : stop[i - 1];
        stop[i] = max(longStop, prevStop);
        dir[i]  = cs[i].close > stop[i] ? 1 : -1;
        if (dir[i] == -1) stop[i] = shortStop; // switch to short stop
      } else {
        // In downtrend: use short stop, ratchet it down, flip if price closes above
        final prevStop = stop[i - 1].isNaN ? shortStop : stop[i - 1];
        stop[i] = min(shortStop, prevStop);
        dir[i]  = cs[i].close < stop[i] ? -1 : 1;
        if (dir[i] == 1) stop[i] = longStop; // switch to long stop
      }
    }
    return (stop: stop, dir: dir);
  }

  // ── HTF index helper (last closed bar, no lookahead) ─────────────────────
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
  double get atrTargetMult; // ← new in v3: fixed profit target
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
  bool beSet = false; // break-even stop already applied?
}

double _entryFill(double px, TradeDirection d) =>
    d == TradeDirection.long ? px * (1 + kSlippagePerSide) : px * (1 - kSlippagePerSide);
double _exitFill(double px, TradeDirection d) =>
    d == TradeDirection.long ? px * (1 - kSlippagePerSide) : px * (1 + kSlippagePerSide);

/// Common exit logic shared by all v3 strategies.
/// Returns ({doExit, reason, exitIdeal}) and updates trailing stop / BE stop.
({bool doExit, String reason, double exitIdeal}) _checkExit(
  _Sim s, Candle bar, double atrNow, double atrStopMult,
) {
  bool   doExit   = false;
  String reason   = '';
  double exitIdeal = bar.close;

  if (s.dir == TradeDirection.long) {
    // Break-even: once price has moved +1R, lock stop to entry
    if (!s.beSet && bar.close >= s.entryPrice + (s.entryPrice - s.origStop)) {
      s.stopLoss = max(s.stopLoss, s.entryPrice);
      s.beSet    = true;
    }
    // 1. Target
    if (bar.high >= s.takeProfit) {
      doExit   = true; reason = 'Target'; exitIdeal = s.takeProfit;
    }
    // 2. Stop
    else if (bar.low <= s.stopLoss) {
      doExit   = true; reason = 'ATR Stop'; exitIdeal = s.stopLoss;
    }
  } else {
    if (!s.beSet && bar.close <= s.entryPrice - (s.origStop - s.entryPrice)) {
      s.stopLoss = min(s.stopLoss, s.entryPrice);
      s.beSet    = true;
    }
    if (bar.low <= s.takeProfit) {
      doExit   = true; reason = 'Target'; exitIdeal = s.takeProfit;
    } else if (bar.high >= s.stopLoss) {
      doExit   = true; reason = 'ATR Stop'; exitIdeal = s.stopLoss;
    }
  }
  return (doExit: doExit, reason: reason, exitIdeal: exitIdeal);
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 1 — TREND PULLBACK EMA
// ════════════════════════════════════════════════════════════════════════════
//
//  Concept  Buy / sell pullbacks in an established EMA trend.
//  Entry    4h EMA20 > EMA50 (trend) + ADX(14) > threshold → trend exists.
//           1h RSI(14) inside pullback zone (not overbought, not oversold).
//           15m EMA fast crosses slow → momentum resumes in trend direction.
//           15m volume of entry bar > volFactor × SMA20(volume).
//  Exit     Fixed target (atrTargetMult) first; trailing ATR stop second;
//           break-even stop once +1R in profit; time stop after 5 days.
// ════════════════════════════════════════════════════════════════════════════

class TrendPullbackParams extends StrategyParams {
  final int    fast, slow, adxMin;
  final double rsiLow, rsiHigh, volFactor;
  @override final double atrStopMult, atrTargetMult;
  TrendPullbackParams(this.fast, this.slow, this.adxMin,
      this.rsiLow, this.rsiHigh, this.volFactor,
      this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'EMA($fast/$slow) ADX>$adxMin RSI[$rsiLow,$rsiHigh] '
      'Vol>×${volFactor.toStringAsFixed(1)} '
      'SL×$atrStopMult TP×$atrTargetMult';
}

class TrendPullbackEma extends Strategy {
  @override String get name => 'TrendPullback-EMA';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final fast in [9, 13]) {
      for (final slow in [21, 34]) {
        for (final adx in [20, 25]) {
          for (final rsiZone in [(35.0, 60.0), (40.0, 65.0)]) {
            for (final rr in [2.0, 2.5]) {
              out.add(TrendPullbackParams(fast, slow, adx,
                rsiZone.$1, rsiZone.$2, 1.2, 1.5, 1.5 * rr));
            }
          }
        }
      }
    }
    return out;
  }

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  }) {
    final p   = params as TrendPullbackParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;
    final c1d = tfCandles[Timeframe.d1]!;

    final cl15     = c15.map((c) => c.close).toList();
    final vol15    = c15.map((c) => c.volume).toList();
    final eF15     = Indicators.ema(cl15, p.fast);
    final eS15     = Indicators.ema(cl15, p.slow);
    final atr15    = Indicators.atr(c15, 14);
    final volSma15 = Indicators.sma(vol15, 20);

    final cl1h  = c1h.map((c) => c.close).toList();
    final rsi1h = Indicators.rsi(cl1h, 14);

    final cl4h   = c4h.map((c) => c.close).toList();
    final e20_4h = Indicators.ema(cl4h, 20);
    final e50_4h = Indicators.ema(cl4h, 50);
    final adx4h  = Indicators.adx(c4h, 14);

    // Daily EMA20 slope gate
    final e20_1d = Indicators.ema(c1d.map((c) => c.close).toList(), 20);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = max(p.slow + 10, 60); i < c15.length - 1; i++) {
      if (eF15[i].isNaN || eS15[i].isNaN || atr15[i].isNaN) continue;
      if (volSma15[i].isNaN) continue;

      final t   = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      final i1d = Indicators.closedHtfIdx(c1d, t);
      if (i1h < 1 || i4h < 0 || i1d < 1) continue;
      if (rsi1h[i1h].isNaN || e20_4h[i4h].isNaN || e50_4h[i4h].isNaN) continue;
      if (adx4h.adx[i4h].isNaN || e20_1d[i1d].isNaN || e20_1d[i1d - 1].isNaN) continue;

      // Avoid entry on oversized candles (chasing)
      final barRange = c15[i].high - c15[i].low;
      if (barRange > 1.5 * atr15[i]) continue;

      if (!s.inTrade) {
        final volOk    = c15[i].volume > p.volFactor * volSma15[i];
        final adxOk    = adx4h.adx[i4h] > p.adxMin;
        // v8: +DI/-DI directional filter — ADX above threshold is not enough;
        // we also require the bullish DI to dominate for longs and vice versa.
        final diLong   = adx4h.plusDI[i4h] > adx4h.minusDI[i4h];
        final diShort  = adx4h.minusDI[i4h] > adx4h.plusDI[i4h];
        final rsiVal   = rsi1h[i1h];
        final crossL   = eF15[i] > eS15[i] && eF15[i - 1] <= eS15[i - 1];
        final crossS   = eF15[i] < eS15[i] && eF15[i - 1] >= eS15[i - 1];
        final trend4hL = e20_4h[i4h] > e50_4h[i4h];
        final trend4hS = e20_4h[i4h] < e50_4h[i4h];
        final rsiZoneL = rsiVal >= p.rsiLow  && rsiVal <= p.rsiHigh;
        final rsiZoneS = rsiVal <= (100 - p.rsiLow) && rsiVal >= (100 - p.rsiHigh);
        final dBull    = e20_1d[i1d] > e20_1d[i1d - 1];
        final dBear    = e20_1d[i1d] < e20_1d[i1d - 1];

        if (volOk && adxOk && diLong && trend4hL && dBull && rsiZoneL && crossL) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr15[i];
          s.inTrade    = true;
          s.entryTime  = c15[i + 1].time;
          s.entryBar   = i + 1;
          s.beSet      = false;
        } else if (volOk && adxOk && diShort && trend4hS && dBear && rsiZoneS && crossS) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr15[i];
          s.inTrade    = true;
          s.entryTime  = c15[i + 1].time;
          s.entryBar   = i + 1;
          s.beSet      = false;
        }
      } else {
        final ex = _checkExit(s, c15[i], atr15[i], p.atrStopMult);
        var doExit = ex.doExit;
        var reason = ex.reason;
        var exitIdeal = ex.exitIdeal;

        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c15[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: s.entryTime, exitTime: c15[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx,
              direction: s.dir, strategyName: name,
              symbol: symbol, exitReason: reason,
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
// STRATEGY 2 — DONCHIAN PULLBACK  (new in v8)
// ════════════════════════════════════════════════════════════════════════════
//
//  Concept  "Buy the first pullback after a breakout." Completely different
//           entry mechanism from ChandelierMtf (which enters on ATR-channel
//           flip) and TrendPullback (which uses EMA cross on 15m).
//
//  Entry    4h Donchian(donPeriod) breakout occurred within the last
//           donLookback bars — new high/low signals a fresh trend impulse.
//           4h +DI > -DI (directional confirmation) AND ADX > adxMin.
//           1h RSI(14) has pulled back into zone [40,60] — retracement.
//           15m EMA(9) just crossed above EMA(21) — momentum resuming.
//           15m volume > volFactor × SMA20(vol).
//  Exit     Fixed target (atrTargetMult × ATR). Chandelier trailing stop
//           (15m). Break-even at +1R. Time stop 5 days.
// ════════════════════════════════════════════════════════════════════════════

class DonchianPullbackParams extends StrategyParams {
  final int    donPeriod, donLookback, adxMin;
  final double rsiLow, rsiHigh, volFactor;
  @override final double atrStopMult, atrTargetMult;
  DonchianPullbackParams(this.donPeriod, this.donLookback, this.adxMin,
      this.rsiLow, this.rsiHigh, this.volFactor,
      this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'Don4h($donPeriod,lbk=$donLookback) ADX>$adxMin RSI[$rsiLow,$rsiHigh] '
      'SL×$atrStopMult TP×$atrTargetMult';
}

class DonchianPullback extends Strategy {
  @override String get name => 'Donchian-Pullback';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final don in [20, 30]) {
      for (final lbk in [4, 8]) {        // how many 4h bars to look back for breakout
        for (final adx in [18, 22]) {
          for (final tp in [3.0, 4.0]) {
            out.add(DonchianPullbackParams(don, lbk, adx, 40.0, 60.0, 1.2, 1.5, tp));
          }
        }
      }
    }
    return out; // 16 combos
  }

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  }) {
    final p   = params as DonchianPullbackParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final cl15     = c15.map((c) => c.close).toList();
    final vol15    = c15.map((c) => c.volume).toList();
    final e9_15    = Indicators.ema(cl15, 9);
    final e21_15   = Indicators.ema(cl15, 21);
    final atr15    = Indicators.atr(c15, 14);
    final volSma15 = Indicators.sma(vol15, 20);
    final ch15     = Indicators.chandelier(c15, 14, 2.5);

    final cl1h  = c1h.map((c) => c.close).toList();
    final rsi1h = Indicators.rsi(cl1h, 14);

    final don4h  = Indicators.donchian(c4h, p.donPeriod);
    final adx4h  = Indicators.adx(c4h, 14);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = max(p.donPeriod + 10, 60); i < c15.length - 1; i++) {
      if (e9_15[i].isNaN || e21_15[i].isNaN || atr15[i].isNaN || volSma15[i].isNaN) continue;
      final t   = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      if (i1h < 0 || i4h < p.donPeriod + p.donLookback) continue;
      if (don4h.upper[i4h].isNaN || adx4h.adx[i4h].isNaN) continue;
      if (rsi1h[i1h].isNaN) continue;

      final barRange = c15[i].high - c15[i].low;
      if (barRange > 1.5 * atr15[i]) continue;

      if (!s.inTrade) {
        final adxOk   = adx4h.adx[i4h] > p.adxMin;
        final diLong  = adx4h.plusDI[i4h] > adx4h.minusDI[i4h];
        final diShort = adx4h.minusDI[i4h] > adx4h.plusDI[i4h];
        final volOk   = c15[i].volume > p.volFactor * volSma15[i];
        final rsiVal  = rsi1h[i1h];
        final rsiPullL = rsiVal >= p.rsiLow && rsiVal <= p.rsiHigh;
        final rsiPullS = rsiVal >= (100 - p.rsiHigh) && rsiVal <= (100 - p.rsiLow);
        final crossL  = e9_15[i] > e21_15[i] && e9_15[i - 1] <= e21_15[i - 1];
        final crossS  = e9_15[i] < e21_15[i] && e9_15[i - 1] >= e21_15[i - 1];

        // Check if a 4h Donchian breakout occurred within the last donLookback bars
        bool brokoutUpRecently = false;
        bool brokoutDnRecently = false;
        for (int j = 1; j <= p.donLookback && i4h - j >= p.donPeriod; j++) {
          final prevUpper = don4h.upper[i4h - j];
          final prevLower = don4h.lower[i4h - j];
          if (!prevUpper.isNaN && c4h[i4h - j + 1].close > prevUpper) brokoutUpRecently = true;
          if (!prevLower.isNaN && c4h[i4h - j + 1].close < prevLower) brokoutDnRecently = true;
        }

        if (adxOk && diLong && volOk && brokoutUpRecently && rsiPullL && crossL) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr15[i];
          s.inTrade    = true; s.entryTime = c15[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        } else if (adxOk && diShort && volOk && brokoutDnRecently && rsiPullS && crossS) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr15[i];
          s.inTrade    = true; s.entryTime = c15[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        }
      } else {
        // Trail stop with 15m chandelier
        if (s.dir == TradeDirection.long && !ch15.stop[i].isNaN) {
          if (ch15.stop[i] > s.stopLoss && ch15.stop[i] < s.entryPrice * 1.5)
            s.stopLoss = ch15.stop[i];
        } else if (s.dir == TradeDirection.short && !ch15.stop[i].isNaN) {
          if (ch15.stop[i] < s.stopLoss && ch15.stop[i] > s.entryPrice * 0.5)
            s.stopLoss = ch15.stop[i];
        }
        final ex = _checkExit(s, c15[i], atr15[i], p.atrStopMult);
        var doExit = ex.doExit; var reason = ex.reason; var exitIdeal = ex.exitIdeal;
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c15[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(entryTime: s.entryTime, exitTime: c15[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx, direction: s.dir,
              strategyName: name, symbol: symbol, exitReason: reason));
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 5 — CHANDELIER MTF
// ════════════════════════════════════════════════════════════════════════════
//
//  Concept  Chandelier Exit uses highest-high / lowest-low minus/plus ATR.
//           It is extremely clean at detecting trend direction changes.
//           We stack 4h → 1h → 15m chandelier alignment and require ADX
//           confirmation before entering.
//  Entry    4h chandelier bullish + ADX(14) > adxMin.
//           1h chandelier flips bullish (the entry trigger).
//           15m EMA50 confirms direction (price above EMA50 for long).
//           15m volume > volFactor × SMA20(vol).
//  Exit     Fixed target; Chandelier trailing stop; break-even; time stop.
// ════════════════════════════════════════════════════════════════════════════

class ChandelierParams extends StrategyParams {
  final int    chPeriod, adxMin;
  final double chMult, volFactor;
  @override final double atrStopMult, atrTargetMult;
  ChandelierParams(this.chPeriod, this.chMult, this.adxMin,
      this.volFactor, this.atrStopMult, this.atrTargetMult);
  @override String get label =>
      'CH($chPeriod,${chMult.toStringAsFixed(1)}) ADX>$adxMin SL×$atrStopMult TP×$atrTargetMult';
}

class ChandelierMtf extends Strategy {
  @override String get name => 'Chandelier-MTF';

  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final per in [14, 22]) {
      for (final m in [2.5, 3.0]) {
        for (final adx in [20, 25]) {
          for (final rr in [2.0, 2.5]) {
            out.add(ChandelierParams(per, m, adx, 1.2, 2.0, 2.0 * rr));
          }
        }
      }
    }
    return out;
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
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final ch15     = Indicators.chandelier(c15, p.chPeriod, p.chMult);
    final atr15    = Indicators.atr(c15, 14);
    final cl15     = c15.map((c) => c.close).toList();
    final e50_15   = Indicators.ema(cl15, 50);
    final vol15    = c15.map((c) => c.volume).toList();
    final volSma15 = Indicators.sma(vol15, 20);

    final ch1h  = Indicators.chandelier(c1h, p.chPeriod, p.chMult);
    final adx1h = Indicators.adx(c1h, 14);

    final ch4h  = Indicators.chandelier(c4h, p.chPeriod, p.chMult);
    final adx4h = Indicators.adx(c4h, 14);

    final trades = <Trade>[];
    final s      = _Sim();

    for (int i = p.chPeriod + 10; i < c15.length - 1; i++) {
      if (atr15[i].isNaN || e50_15[i].isNaN || volSma15[i].isNaN) continue;
      final t   = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      if (i1h < 1 || i4h < 0) continue;
      if (adx4h.adx[i4h].isNaN || adx1h.adx[i1h].isNaN) continue;

      final barRange = c15[i].high - c15[i].low;
      if (barRange > 1.5 * atr15[i]) continue;

      if (!s.inTrade) {
        final adxOk   = adx4h.adx[i4h] > p.adxMin;
        final volOk   = c15[i].volume > p.volFactor * volSma15[i];
        // v8: +DI/-DI directional confirmation
        final diLong  = adx4h.plusDI[i4h] > adx4h.minusDI[i4h];
        final diShort = adx4h.minusDI[i4h] > adx4h.plusDI[i4h];
        final d4h     = ch4h.dir[i4h];
        final d1h     = ch1h.dir[i1h];
        final d1hP    = ch1h.dir[i1h - 1];
        final d15c    = ch15.dir[i];
        final flipL   = d1h == 1  && d1hP == -1;
        final flipS   = d1h == -1 && d1hP == 1;
        final conf15L = c15[i].close > e50_15[i] && d15c == 1;
        final conf15S = c15[i].close < e50_15[i] && d15c == -1;

        if (adxOk && diLong && volOk && d4h == 1 && flipL && conf15L) {
          s.dir        = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice - p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice + p.atrTargetMult * atr15[i];
          s.inTrade    = true; s.entryTime = c15[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        } else if (adxOk && diShort && volOk && d4h == -1 && flipS && conf15S) {
          s.dir        = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.origStop   = s.entryPrice + p.atrStopMult * atr15[i];
          s.stopLoss   = s.origStop;
          s.takeProfit = s.entryPrice - p.atrTargetMult * atr15[i];
          s.inTrade    = true; s.entryTime = c15[i + 1].time; s.entryBar = i + 1; s.beSet = false;
        }
      } else {
        // For Chandelier strategy, also update stop using chandelier's own stop
        if (s.dir == TradeDirection.long && !ch15.stop[i].isNaN) {
          if (ch15.stop[i] > s.stopLoss && ch15.stop[i] < s.entryPrice * 1.5)
            s.stopLoss = ch15.stop[i];
        } else if (s.dir == TradeDirection.short && !ch15.stop[i].isNaN) {
          if (ch15.stop[i] < s.stopLoss && ch15.stop[i] > s.entryPrice * 0.5)
            s.stopLoss = ch15.stop[i];
        }

        final ex = _checkExit(s, c15[i], atr15[i], p.atrStopMult);
        var doExit = ex.doExit; var reason = ex.reason; var exitIdeal = ex.exitIdeal;
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true; reason = 'Time Stop'; exitIdeal = c15[i].close;
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(Trade(entryTime: s.entryTime, exitTime: c15[i].time,
              entryPrice: s.entryPrice, exitPrice: exitPx, direction: s.dir,
              strategyName: name, symbol: symbol, exitReason: reason));
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
  /// Minimum IS trades required before applying params to OOS.
  /// Below this threshold the IS sample is too small to trust — skip the window.
  final int minIsTrades;
  WfoEngine({this.isLengthDays = 60, this.oosLengthDays = 30, this.minIsTrades = 10});

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
    final base = allTf[Timeframe.m15]!;
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
      final warmup  = _slice(allTf, win.isStart, win.oosEnd);
      final m15Len  = warmup[Timeframe.m15]?.length ?? 0;
      if (m15Len < 200) {
        print('  ⚠  ${win.label}: too few bars ($m15Len), skipping');
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
        // Proceed to OOS only when the IS period shows BOTH:
        //   (a) positive expectancy  — genuine edge present in IS
        //   (b) enough IS trades     — sample is statistically valid (not noise)
        // NOTE: no win-rate gate — high R:R strategies are profitable at 25-30%
        //       win rate and a blanket win-rate floor filters them out wrongly.
        if (bestIsExpec <= 0.0 || bestIsN < minIsTrades) {
          continue;
        }

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
║   CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER v8                         ║
║   +DI/-DI directional filter | New: DonchianPullback strategy                ║
║   IS gate: expectancy > 0 AND trades >= 10                                   ║
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
    print('\n  Longs : ${longs.length} trades, win rate ${_f(lWR)}%');
    print('  Shorts: ${shorts.length} trades, win rate ${_f(sWR)}%');
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

    final lb   = File('$outDir/leaderboard_v8.csv');
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

    final tr   = File('$outDir/all_trades_v8.csv');
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

    final wb   = File('$outDir/window_breakdown_v8.csv');
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

    print('  📄 leaderboard_v8.csv');
    print('  📄 all_trades_v8.csv');
    print('  📄 window_breakdown_v8.csv');
    print('\n  All files saved to: $outDir/');
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DEMO DATA (fallback when real data path not found)
// ════════════════════════════════════════════════════════════════════════════

Map<String, List<Candle>> _generateDemoData() {
  print('  ℹ  Generating synthetic 5m demo data (12 months)...');
  final rng    = Random(42);
  final result = <String, List<Candle>>{};
  final assets = [
    ('BTCUSDT', 42000.0, 0.0025),
    ('ETHUSDT', 2500.0,  0.0030),
    ('SOLUSDT', 100.0,   0.0045),
  ];
  for (final (sym, startPrice, vol) in assets) {
    final candles = <Candle>[];
    var time  = DateTime.utc(2024, 1, 1);
    double price = startPrice;
    for (int i = 0; i < 12 * 30 * 24 * 12; i++) {
      final trend = sin(i / (24 * 12 * 21)) * 0.0002;
      final noise = (rng.nextDouble() - 0.49) * vol;
      price = (price * (1 + trend + noise)).clamp(startPrice * 0.2, startPrice * 6);
      final range = price * (0.0008 + rng.nextDouble() * 0.003);
      final o = price;
      final h = o + range * rng.nextDouble();
      final l = o - range * rng.nextDouble();
      final c = l + (h - l) * rng.nextDouble();
      candles.add(Candle(
        time: time, open: o, high: h, low: l, close: c,
        volume: 50 + rng.nextDouble() * 500,
      ));
      time = time.add(const Duration(minutes: 5));
    }
    result[sym] = candles;
    print('  ✓ Demo $sym: ${candles.length} bars');
  }
  return result;
}

// ════════════════════════════════════════════════════════════════════════════
// MAIN
// ════════════════════════════════════════════════════════════════════════════

void main(List<String> args) {
  Reporter.banner();

  final dataDir = args.isNotEmpty ? args[0] : 'C:\\Users\\GIGA\\Desktop\\Candle Data';
  final outDir  = args.length > 1 ? args[1] : './wf_results_v8';

  const int isLengthDays  = 60;
  const int oosLengthDays = 30; // extended from 20 → more robust OOS estimate

  print('Configuration');
  print('  Data dir       : $dataDir');
  print('  Output dir     : $outDir');
  print('  IS window      : $isLengthDays days  (param optimisation)');
  print('  OOS window     : $oosLengthDays days  (reported only)');
  print('  Slippage/side  : ${kSlippagePerSide * 1e4} bps');
  print('  Fee/side       : ${kFeePerSide * 1e4} bps');
  print('  Max bars/trade : $kMaxBarsInTrade\n');

  print('Scanning for assets...');
  Map<String, List<Candle>> raw5m = CsvLoader.loadDirectory(dataDir);
  if (raw5m.isEmpty) {
    print('\n  No real data found — running DEMO mode.\n');
    raw5m = _generateDemoData();
  }

  print('\nAggregating timeframes...');
  final allTf = <String, Map<Timeframe, List<Candle>>>{};
  for (final sym in raw5m.keys) {
    allTf[sym] = {
      Timeframe.m5:  raw5m[sym]!,
      Timeframe.m15: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m15),
      Timeframe.m30: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m30),
      Timeframe.h1:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h1),
      Timeframe.h4:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h4),
      Timeframe.d1:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.d1),
    };
    final tf = allTf[sym]!;
    print(
      '  $sym → 15m:${tf[Timeframe.m15]!.length}'
      ' | 1h:${tf[Timeframe.h1]!.length}'
      ' | 4h:${tf[Timeframe.h4]!.length}'
      ' | 1d:${tf[Timeframe.d1]!.length}',
    );
  }

  // v8: KAMA-Pullback, Supertrend-Quality, Compression-Breakout all dropped.
  // DonchianPullback is new: breakout + first pullback entry with DI filter.
  final strategies = <Strategy>[
    TrendPullbackEma(),
    DonchianPullback(),
    ChandelierMtf(),
  ];

  final engine      = WfoEngine(isLengthDays: isLengthDays, oosLengthDays: oosLengthDays);
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
      final wins = byStrat[strat]!;
      allWins[sym]![strat] = wins;
      if (wins.isEmpty) continue;
      Reporter.windowTable(strat, sym, wins);
      final cons = Reporter.consolidate(strat, sym, wins);
      consolidated[sym]![strat] = cons;
      Reporter.strategyCard(cons);
    }
  }

  Reporter.leaderboard(consolidated);

  print('\nExporting CSVs...');
  Reporter.exportCsv(consolidated, allWins, outDir);
}
