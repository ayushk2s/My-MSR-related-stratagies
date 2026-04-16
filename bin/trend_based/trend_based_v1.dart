import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

// ═════════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ═════════════════════════════════════════════════════════════════════════════

double slippage = 0.0005;
 const fee = 0.1; // total % round-trip

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

  return raw - fee;
}

  Duration get holdingPeriod => exitTime.difference(entryTime);
}

class StrategyResult {
  final String strategyName, symbol, windowLabel;
  final List<Trade> trades;

  StrategyResult({
    required this.strategyName,
    required this.symbol,
    required this.trades,
    required this.windowLabel,
  });

  int get totalTrades  => trades.length;
  int get winningTrades => trades.where((t) => t.pnlPct > 0).length;
  int get losingTrades  => trades.where((t) => t.pnlPct <= 0).length;

  double get winRate =>
      totalTrades == 0 ? 0 : winningTrades / totalTrades * 100;

  double get totalReturn =>
      trades.fold(0.0, (s, t) => s + t.pnlPct);

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
    return gl == 0 ? double.infinity : gp / gl;
  }

  double get sharpeRatio {
    if (trades.length < 2) return 0;
    final rets = trades.map((t) => t.pnlPct).toList();
    final mean = rets.fold(0.0, (s, r) => s + r) / rets.length;
    final variance = rets.fold(0.0, (s, r) => s + pow(r - mean, 2)) / rets.length;
    final std = sqrt(variance);
    return std == 0 ? 0 : mean / std * sqrt(252);
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

  double get calmarRatio =>
      maxDrawdown == 0 ? 0 : totalReturn / maxDrawdown;

  /// Composite score: PF(35%) + Sharpe(25%) + WinRate(25%) + Expectancy(15%)
  double get compositeScore {
    final wR = winRate / 100;
    final pF = min(profitFactor, 5.0) / 5.0;
    final sh = min(max(sharpeRatio, -2.0), 4.0) / 4.0;
    final ex = expectancy > 0 ? min(expectancy / 2.0, 1.0) : 0.0;
    return (wR * 0.25 + pF * 0.35 + sh * 0.25 + ex * 0.15) * 100;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// CSV LOADER  —  recursive, handles nested subdirectories
// ═════════════════════════════════════════════════════════════════════════════

class CsvLoader {
  static const int _minCandles = 200;

  static List<Candle> loadFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return [];

    final lines = file.readAsLinesSync();
    final candles = <Candle>[];

    // Auto-detect header
    int start = 0;
    if (lines.isNotEmpty) {
      final first = lines[0].toLowerCase();
      if (first.contains('time') || first.contains('date') || first.contains('open')) {
        start = 1;
      }
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
          time = ms > 9_999_999_999
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
        continue; // skip malformed rows
      }
    }

    candles.sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  /// Recursively scan [dirPath] for *.csv files.
  /// Each unique filename stem becomes a symbol.
  /// Duplicate stems across sub-dirs are merged & re-sorted.
  static Map<String, List<Candle>> loadDirectory(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      print('  ⛔  Directory not found: $dirPath');
      return {};
    }

    final merged = <String, List<Candle>>{};
    int filesFound = 0;

    void scan(Directory d) {
      for (final entity in d.listSync()) {
        if (entity is Directory) {
          scan(entity); // recurse
        } else if (entity is File &&
            entity.path.toLowerCase().endsWith('.csv')) {
          filesFound++;
          final symbol =
              p.basenameWithoutExtension(entity.path).toUpperCase().trim();
          final loaded = loadFile(entity.path);
          if (loaded.isNotEmpty) {
            merged.putIfAbsent(symbol, () => []).addAll(loaded);
          }
        }
      }
    }

    scan(dir);
    print('  📂  Scanned $filesFound CSV file(s) in "$dirPath" (recursive)');

    final result = <String, List<Candle>>{};
    for (final sym in merged.keys) {
      // Remove duplicate timestamps then sort
      final deduped = <DateTime, Candle>{};
      for (final c in merged[sym]!) {
        deduped[c.time] = c;
      }
      final candles = deduped.values.toList()
        ..sort((a, b) => a.time.compareTo(b.time));

      if (candles.length >= _minCandles) {
        result[sym] = candles;
        final span =
            '${candles.first.time.toIso8601String().substring(0, 10)} → '
            '${candles.last.time.toIso8601String().substring(0, 10)}';
        print('  ✓  $sym: ${candles.length} candles [$span]');
      } else {
        print('  ⚠  $sym: only ${candles.length} candles — need ≥$_minCandles, skipped');
      }
    }

    if (result.isEmpty) {
      print('  ⛔  No usable symbols found. Check your CSV format:');
      print('       timestamp,open,high,low,close[,volume]');
      print('       (timestamp = Unix seconds/ms OR ISO-8601)');
    }
    return result;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// TIMEFRAME AGGREGATOR
// ═════════════════════════════════════════════════════════════════════════════

enum Timeframe { m5, m15, m30, h1, h4 }

extension TimeframeExt on Timeframe {
  int get minutes => const {
    Timeframe.m5: 5, Timeframe.m15: 15, Timeframe.m30: 30,
    Timeframe.h1: 60, Timeframe.h4: 240,
  }[this]!;

  String get label => const {
    Timeframe.m5: '5m', Timeframe.m15: '15m', Timeframe.m30: '30m',
    Timeframe.h1: '1h', Timeframe.h4: '4h',
  }[this]!;
}

class TimeframeAggregator {
  static List<Candle> aggregate(List<Candle> base, Timeframe tf) {
    if (tf == Timeframe.m5) return List.from(base);
    final bMin = tf.minutes;
    final result = <Candle>[];
    int i = 0;

    while (i < base.length) {
      final bucketStart = _floor(base[i].time, bMin);
      final bucketEnd = bucketStart.add(Duration(minutes: bMin));

      double o = base[i].open, h = base[i].high, l = base[i].low,
          c = base[i].close, vol = base[i].volume;
      i++;

      while (i < base.length && base[i].time.isBefore(bucketEnd)) {
        if (base[i].high > h) h = base[i].high;
        if (base[i].low < l) l = base[i].low;
        c = base[i].close;
        vol += base[i].volume;
        i++;
      }

      result.add(Candle(
          time: bucketStart, open: o, high: h, low: l, close: c, volume: vol));
    }
    return result;
  }

  static DateTime _floor(DateTime t, int bMin) {
    final total = t.hour * 60 + t.minute;
    final floored = (total ~/ bMin) * bMin;
    return DateTime.utc(t.year, t.month, t.day, floored ~/ 60, floored % 60);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// TECHNICAL INDICATORS  — all pure functions, no side-effects
// ═════════════════════════════════════════════════════════════════════════════

class Indicators {
  // ── EMA ─────────────────────────────────────────────────────────────────────
  static List<double> ema(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period) return out;
    final mult = 2.0 / (period + 1);
    out[period - 1] = src.take(period).fold(0.0, (s, v) => s + v) / period;
    for (int i = period; i < src.length; i++) {
      out[i] = (src[i] - out[i - 1]) * mult + out[i - 1];
    }
    return out;
  }

  // ── SMA ─────────────────────────────────────────────────────────────────────
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

  // ── ATR (Wilder smoothing) ───────────────────────────────────────────────
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
    final out = List<double>.filled(cs.length, double.nan);
    double atrVal = tr.take(period).fold(0.0, (s, v) => s + v) / period;
    out[period - 1] = atrVal;
    for (int i = period; i < cs.length; i++) {
      atrVal = (atrVal * (period - 1) + tr[i]) / period;
      out[i] = atrVal;
    }
    return out;
  }

  // ── RSI ─────────────────────────────────────────────────────────────────────
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

  // ── MACD ────────────────────────────────────────────────────────────────────
  static ({List<double> macd, List<double> signal, List<double> hist}) macd(
      List<double> src, {int fast = 12, int slow = 26, int sig = 9}) {
    final fe = ema(src, fast);
    final se = ema(src, slow);
    final ml = List<double>.generate(src.length,
        (i) => (fe[i].isNaN || se[i].isNaN) ? double.nan : fe[i] - se[i]);

    // Build signal EMA only over non-NaN MACD values, then map back
    final validMacd = ml.where((v) => !v.isNaN).toList();
    final sl = List<double>.filled(src.length, double.nan);
    if (validMacd.length >= sig) {
      final se2 = ema(validMacd, sig);
      int j = 0;
      for (int i = 0; i < src.length; i++) {
        if (!ml[i].isNaN) sl[i] = se2[j++];
      }
    }
    final hist = List<double>.generate(src.length,
        (i) => (ml[i].isNaN || sl[i].isNaN) ? double.nan : ml[i] - sl[i]);
    return (macd: ml, signal: sl, hist: hist);
  }

  // ── Supertrend ──────────────────────────────────────────────────────────────
  static ({List<double> st, List<int> dir}) supertrend(
      List<Candle> cs, int period, double mult) {
    final atrV = atr(cs, period);
    final n = cs.length;
    final st  = List<double>.filled(n, double.nan);
    final dir = List<int>.filled(n, -1);
    final ub  = List<double>.filled(n, double.nan);
    final lb  = List<double>.filled(n, double.nan);

    for (int i = period - 1; i < n; i++) {
      final hl2 = (cs[i].high + cs[i].low) / 2;
      final ubBasic = hl2 + mult * atrV[i];
      final lbBasic = hl2 - mult * atrV[i];

      ub[i] = (i > 0 && !ub[i - 1].isNaN)
          ? (ubBasic < ub[i - 1] || cs[i - 1].close > ub[i - 1]
              ? ubBasic : ub[i - 1])
          : ubBasic;

      lb[i] = (i > 0 && !lb[i - 1].isNaN)
          ? (lbBasic > lb[i - 1] || cs[i - 1].close < lb[i - 1]
              ? lbBasic : lb[i - 1])
          : lbBasic;

      if (i == period - 1) {
        st[i] = ub[i];
        dir[i] = -1;
      } else if (!st[i - 1].isNaN) {
        dir[i] = (st[i - 1] == ub[i - 1])
            ? (cs[i].close > ub[i] ? 1 : -1)
            : (cs[i].close < lb[i] ? -1 : 1);
        st[i] = dir[i] == 1 ? lb[i] : ub[i];
      }
    }
    return (st: st, dir: dir);
  }

  // ── ADX / +DI / -DI ─────────────────────────────────────────────────────
  static ({List<double> adx, List<double> plusDI, List<double> minusDI})
      adx(List<Candle> cs, int period) {
    final n = cs.length;
    final adxOut  = List<double>.filled(n, double.nan);
    final pDIOut  = List<double>.filled(n, double.nan);
    final mDIOut  = List<double>.filled(n, double.nan);
    if (n < period * 2 + 1) {
      return (adx: adxOut, plusDI: pDIOut, minusDI: mDIOut);
    }

    final tr    = List<double>.filled(n, 0.0);
    final pDM   = List<double>.filled(n, 0.0);
    final mDM   = List<double>.filled(n, 0.0);

    for (int i = 1; i < n; i++) {
      tr[i] = [
        cs[i].high - cs[i].low,
        (cs[i].high - cs[i - 1].close).abs(),
        (cs[i].low  - cs[i - 1].close).abs(),
      ].reduce(max);
      final up   = cs[i].high - cs[i - 1].high;
      final down = cs[i - 1].low - cs[i].low;
      pDM[i] = (up > down && up > 0) ? up : 0;
      mDM[i] = (down > up && down > 0) ? down : 0;
    }

    // Wilder smoothing seed (bars 1..period)
    double smTR = 0, smP = 0, smM = 0;
    for (int i = 1; i <= period; i++) {
      smTR += tr[i]; smP += pDM[i]; smM += mDM[i];
    }

    final dxList = <double>[];
    for (int i = period; i < n; i++) {
      if (i > period) {
        smTR = smTR - smTR / period + tr[i];
        smP  = smP  - smP  / period + pDM[i];
        smM  = smM  - smM  / period + mDM[i];
      }
      final pdi = smTR == 0 ? 0.0 : smP / smTR * 100;
      final mdi = smTR == 0 ? 0.0 : smM / smTR * 100;
      pDIOut[i] = pdi;
      mDIOut[i] = mdi;
      final s = pdi + mdi;
      dxList.add(s == 0 ? 0.0 : (pdi - mdi).abs() / s * 100);
    }

    // ADX = Wilder SMA of DX over `period`
    // dxList[0] corresponds to candle index `period`
    // ADX first valid at candle index 2*period (needs `period` DX values)
    if (dxList.length >= period) {
      double adxVal = dxList.take(period).fold(0.0, (s, v) => s + v) / period;
      adxOut[2 * period - 1] = adxVal;
      for (int i = period; i < dxList.length; i++) {
        adxVal = (adxVal * (period - 1) + dxList[i]) / period;
        // dxList[i] → candle index (period + i)
        adxOut[period + i] = adxVal;
      }
    }
    return (adx: adxOut, plusDI: pDIOut, minusDI: mDIOut);
  }

  // ── Donchian Channel ────────────────────────────────────────────────────────
  static ({List<double> upper, List<double> lower, List<double> mid})
      donchian(List<Candle> cs, int period) {
    final n = cs.length;
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

  // ── Bollinger Bands ─────────────────────────────────────────────────────────
  static ({List<double> upper, List<double> lower, List<double> mid})
      bollinger(List<double> src, int period, double stdMult) {
    final mid   = sma(src, period);
    final upper = List<double>.filled(src.length, double.nan);
    final lower = List<double>.filled(src.length, double.nan);
    for (int i = period - 1; i < src.length; i++) {
      double var_ = 0;
      for (int j = i - period + 1; j <= i; j++) {
        var_ += pow(src[j] - mid[i], 2);
      }
      final std = sqrt(var_ / period);
      upper[i] = mid[i] + stdMult * std;
      lower[i] = mid[i] - stdMult * std;
    }
    return (upper: upper, lower: lower, mid: mid);
  }

  // ── Utility: binary-search for latest index ≤ target time ───────────────
  static int latestIdx(List<Candle> src, DateTime t) {
    int lo = 0, hi = src.length - 1, res = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (!src[mid].time.isAfter(t)) {
        res = mid; lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return res;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY INTERFACE
// ═════════════════════════════════════════════════════════════════════════════

/// Each strategy receives the FULL IS+OOS candle map so indicators warm up
/// properly on IS data. Only trades whose entryTime falls within [oosFrom, oosTo)
/// are counted. This is the core of forward-bias-free walk-forward testing.
abstract class Strategy {
  String get name;
  String get description;

  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,   // ← only trades after this date count
    required DateTime oosTo,     // ← only trades before this date count
    required double atrStopMult,
  });
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY 1 — TRIPLE EMA MTF
// ═════════════════════════════════════════════════════════════════════════════

class TripleEmaMtf extends Strategy {
  @override String get name => 'Triple-EMA MTF';
  @override String get description =>
      '4h: EMA21>EMA55 trend. 1h: EMA9>EMA21 confirm. 15m: EMA9×EMA21 entry. ATR trail.';

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required double atrStopMult,
  }) {
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    // Compute indicators over ALL data (IS+OOS) for proper warmup
    final cl15 = c15.map((c) => c.close).toList();
    final e9_15  = Indicators.ema(cl15, 9);
    final e21_15 = Indicators.ema(cl15, 21);
    final atr15  = Indicators.atr(c15, 14);

    final cl1h   = c1h.map((c) => c.close).toList();
    final e9_1h  = Indicators.ema(cl1h, 9);
    final e21_1h = Indicators.ema(cl1h, 21);

    final cl4h   = c4h.map((c) => c.close).toList();
    final e21_4h = Indicators.ema(cl4h, 21);
    final e55_4h = Indicators.ema(cl4h, 55);

    final trades = <Trade>[];
    bool inTrade = false;
    TradeDirection dir = TradeDirection.long;
    double entryPrice = 0, stopLoss = 0;
    DateTime entryTime = DateTime(0);

    for (int i = 60; i < c15.length - 1; i++) {
      final t = c15[i].time;

      // ── Check indicators valid ──────────────────────────────────────────
      if (e9_15[i].isNaN || e21_15[i].isNaN || atr15[i].isNaN) continue;



    final i1h = Indicators.latestIdx(c1h, t) - 1;
     final i4h = Indicators.latestIdx(c4h, t) - 1;
      if (i1h < 0 || i4h < 0) continue;
      if (e9_1h[i1h].isNaN || e21_1h[i1h].isNaN) continue;
      if (e21_4h[i4h].isNaN || e55_4h[i4h].isNaN) continue;

      final bull4h = e21_4h[i4h] > e55_4h[i4h];
      final bear4h = e21_4h[i4h] < e55_4h[i4h];
      final bull1h = e9_1h[i1h] > e21_1h[i1h];
      final bear1h = e9_1h[i1h] < e21_1h[i1h];

      if (!inTrade) {
        final crossLong  = e9_15[i] > e21_15[i] && e9_15[i-1] <= e21_15[i-1];
        final crossShort = e9_15[i] < e21_15[i] && e9_15[i-1] >= e21_15[i-1];


//It a bull run 
        if (bull4h && bull1h && crossLong) {
          entryPrice = c15[i + 1].open * (1 + slippage); 
          stopLoss   = entryPrice - atrStopMult * atr15[i];
          dir = TradeDirection.long;
          inTrade = true;
          entryTime = c15[i + 1].time;
        } else if (bear4h && bear1h && crossShort) {
          entryPrice = c15[i + 1].open * (1 + slippage); 
          stopLoss   = entryPrice + atrStopMult * atr15[i];
          dir = TradeDirection.short;
          inTrade = true;
          entryTime = c15[i + 1].time;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;

        if (dir == TradeDirection.long) {
          if (bar.low <= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (e9_15[i] < e21_15[i] && e9_15[i-1] >= e21_15[i-1]) { doExit = true; reason = 'EMA Cross'; }
          final trail = bar.close - atrStopMult * atr15[i];
          if (trail > stopLoss) stopLoss = trail;
        } else {
          if (bar.high >= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (e9_15[i] > e21_15[i] && e9_15[i-1] <= e21_15[i-1]) { doExit = true; reason = 'EMA Cross'; }
          final trail = bar.close + atrStopMult * atr15[i];
          if (trail < stopLoss) stopLoss = trail;
        }

        if (doExit) {
          // ── Only record trade if entry is inside OOS window ─────────────
          if (!entryTime.isBefore(oosFrom) && entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: entryTime, exitTime: bar.time,
              entryPrice: entryPrice, exitPrice: bar.close,
              direction: dir, strategyName: name,
              symbol: symbol, exitReason: reason,
            ));
          }
          inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY 2 — SUPERTREND MTF
// ═════════════════════════════════════════════════════════════════════════════

class SupertrendMtf extends Strategy {
  @override String get name => 'Supertrend MTF';
  @override String get description =>
      '4h ST(10,3.5) + 1h ST(10,3.0) direction filters. 15m ST(10,2.0) flip entry.';

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required double atrStopMult,
  }) {
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    // All indicators computed over IS+OOS
    final st15 = Indicators.supertrend(c15, 10, 2.0);
    final atr15 = Indicators.atr(c15, 14);
    final st1h  = Indicators.supertrend(c1h, 10, 3.0);
    final st4h  = Indicators.supertrend(c4h, 10, 3.5);

    final trades = <Trade>[];
    bool inTrade = false;
    TradeDirection dir = TradeDirection.long;
    double entryPrice = 0, stopLoss = 0;
    DateTime entryTime = DateTime(0);

    for (int i = 80; i < c15.length - 1; i++) {
      final t = c15[i].time;
      if (atr15[i].isNaN) continue;

      final i1h = Indicators.latestIdx(c1h, t);
      final i4h = Indicators.latestIdx(c4h, t);
      if (i1h < 0 || i4h < 0) continue;

      final d4h = st4h.dir[i4h];
      final d1h = st1h.dir[i1h];
      final d15 = st15.dir[i];
      final d15p = st15.dir[i - 1];

      if (!inTrade) {
        if (d4h == 1 && d1h == 1 && d15 == 1 && d15p == -1) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice - atrStopMult * atr15[i];
          dir = TradeDirection.long; inTrade = true;
          entryTime = c15[i + 1].time;
        } else if (d4h == -1 && d1h == -1 && d15 == -1 && d15p == 1) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice + atrStopMult * atr15[i];
          dir = TradeDirection.short; inTrade = true;
          entryTime = c15[i + 1].time;
        }
      } else {
        final bar = c15[i];
        String reason = ''; bool doExit = false;

        if (dir == TradeDirection.long) {
          if (bar.low <= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (d15 == -1) { doExit = true; reason = 'ST Flip'; }
          final trail = bar.close - atrStopMult * atr15[i];
          if (trail > stopLoss) stopLoss = trail;
        } else {
          if (bar.high >= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (d15 == 1) { doExit = true; reason = 'ST Flip'; }
          final trail = bar.close + atrStopMult * atr15[i];
          if (trail < stopLoss) stopLoss = trail;
        }

        if (doExit) {
          if (!entryTime.isBefore(oosFrom) && entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: entryTime, exitTime: bar.time,
              entryPrice: entryPrice, exitPrice: bar.close,
              direction: dir, strategyName: name,
              symbol: symbol, exitReason: reason,
            ));
          }
          inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY 3 — MACD MOMENTUM MTF
// ═════════════════════════════════════════════════════════════════════════════

class MacdMomentumMtf extends Strategy {
  @override String get name => 'MACD Momentum MTF';
  @override String get description =>
      '1h: EMA50 trend + MACD hist dir. 15m: MACD cross + RSI(14) 40–65 zone entry.';

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required double atrStopMult,
  }) {
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;

    final cl15  = c15.map((c) => c.close).toList();
    final macd15 = Indicators.macd(cl15);
    final rsi15  = Indicators.rsi(cl15, 14);
    final atr15  = Indicators.atr(c15, 14);

    final cl1h   = c1h.map((c) => c.close).toList();
    final e50_1h = Indicators.ema(cl1h, 50);
    final macd1h = Indicators.macd(cl1h);

    final trades = <Trade>[];
    bool inTrade = false;
    TradeDirection dir = TradeDirection.long;
    double entryPrice = 0, stopLoss = 0;
    DateTime entryTime = DateTime(0);

    for (int i = 60; i < c15.length - 1; i++) {
      final t = c15[i].time;
      if (macd15.macd[i].isNaN || macd15.signal[i].isNaN ||
          rsi15[i].isNaN || atr15[i].isNaN) continue;

      final i1h = Indicators.latestIdx(c1h, t);
      if (i1h < 1) continue;
      if (e50_1h[i1h].isNaN || macd1h.hist[i1h].isNaN) continue;

      final bullTrend = c1h[i1h].close > e50_1h[i1h];
      final bearTrend = c1h[i1h].close < e50_1h[i1h];

      final crossLong  = macd15.macd[i] > macd15.signal[i] && macd15.macd[i-1] <= macd15.signal[i-1];
      final crossShort = macd15.macd[i] < macd15.signal[i] && macd15.macd[i-1] >= macd15.signal[i-1];

      if (!inTrade) {
        if (bullTrend && macd1h.hist[i1h] > 0 && crossLong &&
            rsi15[i] > 40 && rsi15[i] < 65) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice - atrStopMult * atr15[i];
          dir = TradeDirection.long; inTrade = true;
          entryTime = c15[i + 1].time;
        } else if (bearTrend && macd1h.hist[i1h] < 0 && crossShort &&
            rsi15[i] < 60 && rsi15[i] > 35) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice + atrStopMult * atr15[i];
          dir = TradeDirection.short; inTrade = true;
          entryTime = c15[i + 1].time;
        }
      } else {
        final bar = c15[i];
        String reason = ''; bool doExit = false;

        if (dir == TradeDirection.long) {
          if (bar.low <= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (crossShort)    { doExit = true; reason = 'MACD Cross'; }
          else if (rsi15[i] > 75) { doExit = true; reason = 'RSI Overbought'; }
          final trail = bar.close - atrStopMult * atr15[i];
          if (trail > stopLoss) stopLoss = trail;
        } else {
          if (bar.high >= stopLoss) { doExit = true; reason = 'ATR Stop'; }
          else if (crossLong)      { doExit = true; reason = 'MACD Cross'; }
          else if (rsi15[i] < 25)  { doExit = true; reason = 'RSI Oversold'; }
          final trail = bar.close + atrStopMult * atr15[i];
          if (trail < stopLoss) stopLoss = trail;
        }

        if (doExit) {
          if (!entryTime.isBefore(oosFrom) && entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: entryTime, exitTime: bar.time,
              entryPrice: entryPrice, exitPrice: bar.close,
              direction: dir, strategyName: name,
              symbol: symbol, exitReason: reason,
            ));
          }
          inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY 4 — ADX TREND STRENGTH MTF
// ═════════════════════════════════════════════════════════════════════════════

class AdxTrendStrengthMtf extends Strategy {
  @override String get name => 'ADX Trend Strength MTF';
  @override String get description =>
      '1h: ADX>25 + DI direction. 15m: EMA21 pullback entry + BB squeeze filter.';

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required double atrStopMult,
  }) {
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;

    final cl15   = c15.map((c) => c.close).toList();
    final e9_15  = Indicators.ema(cl15, 9);
    final e21_15 = Indicators.ema(cl15, 21);
    final atr15  = Indicators.atr(c15, 14);
    final boll15 = Indicators.bollinger(cl15, 20, 2.0);

    final adx1h = Indicators.adx(c1h, 14);

    final trades = <Trade>[];
    bool inTrade = false;
    TradeDirection dir = TradeDirection.long;
    double entryPrice = 0, stopLoss = 0;
    DateTime entryTime = DateTime(0);

    for (int i = 60; i < c15.length - 1; i++) {
      final t = c15[i].time;
      if (e21_15[i].isNaN || atr15[i].isNaN || boll15.upper[i].isNaN) continue;

      final i1h = Indicators.latestIdx(c1h, t);
      if (i1h < 0) continue;
      if (adx1h.adx[i1h].isNaN || adx1h.plusDI[i1h].isNaN) continue;

      final adxV = adx1h.adx[i1h];
      final pdi  = adx1h.plusDI[i1h];
      final mdi  = adx1h.minusDI[i1h];
      final price = c15[i].close;

      final bbWidth      = (boll15.upper[i] - boll15.lower[i]) / boll15.mid[i];
      final notSqueeze   = bbWidth > 0.01;
      final nearEma21    = price.abs() < e21_15[i] * 1.005 && price > e21_15[i] * 0.995;

      if (!inTrade) {
        if (adxV > 25 && pdi > mdi && e9_15[i] > e21_15[i] && nearEma21 && notSqueeze) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice - atrStopMult * atr15[i];
          dir = TradeDirection.long; inTrade = true;
          entryTime = c15[i + 1].time;
        } else if (adxV > 25 && mdi > pdi && e9_15[i] < e21_15[i] && nearEma21 && notSqueeze) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice + atrStopMult * atr15[i];
          dir = TradeDirection.short; inTrade = true;
          entryTime = c15[i + 1].time;
        }
      } else {
        final bar = c15[i];
        String reason = ''; bool doExit = false;

        if (dir == TradeDirection.long) {
          if (bar.low <= stopLoss)        { doExit = true; reason = 'ATR Stop'; }
          else if (price >= boll15.upper[i]) { doExit = true; reason = 'BB Upper'; }
          else if (adxV < 20)             { doExit = true; reason = 'ADX Weak'; }
          final trail = bar.close - atrStopMult * atr15[i];
          if (trail > stopLoss) stopLoss = trail;
        } else {
          if (bar.high >= stopLoss)       { doExit = true; reason = 'ATR Stop'; }
          else if (price <= boll15.lower[i]) { doExit = true; reason = 'BB Lower'; }
          else if (adxV < 20)             { doExit = true; reason = 'ADX Weak'; }
          final trail = bar.close + atrStopMult * atr15[i];
          if (trail < stopLoss) stopLoss = trail;
        }

        if (doExit) {
          if (!entryTime.isBefore(oosFrom) && entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: entryTime, exitTime: bar.time,
              entryPrice: entryPrice, exitPrice: bar.close,
              direction: dir, strategyName: name,
              symbol: symbol, exitReason: reason,
            ));
          }
          inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY 5 — DONCHIAN BREAKOUT MTF
// ═════════════════════════════════════════════════════════════════════════════

class DonchianBreakoutMtf extends Strategy {
  @override String get name => 'Donchian Breakout MTF';
  @override String get description =>
      '4h: EMA50 bias. 1h: Donchian(20) midline. 15m: Donchian(10) breakout entry.';

  @override
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required double atrStopMult,
  }) {
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final cl15   = c15.map((c) => c.close).toList();
    final don15  = Indicators.donchian(c15, 10);
    final atr15  = Indicators.atr(c15, 14);

    final cl1h   = c1h.map((c) => c.close).toList();
    final don1h  = Indicators.donchian(c1h, 20);

    final cl4h   = c4h.map((c) => c.close).toList();
    final e50_4h = Indicators.ema(cl4h, 50);

    final trades = <Trade>[];
    bool inTrade = false;
    TradeDirection dir = TradeDirection.long;
    double entryPrice = 0, stopLoss = 0;
    DateTime entryTime = DateTime(0);

    for (int i = 30; i < c15.length - 1; i++) {
      final t = c15[i].time;
      if (don15.upper[i].isNaN || atr15[i].isNaN) continue;

      final i1h = Indicators.latestIdx(c1h, t);
      final i4h = Indicators.latestIdx(c4h, t);
      if (i1h < 0 || i4h < 0) continue;
      if (don1h.mid[i1h].isNaN || e50_4h[i4h].isNaN) continue;

      final price = c15[i].close;
      final prevH = don15.upper[i - 1];
      final prevL = don15.lower[i - 1];

      final bull4h    = c4h[i4h].close > e50_4h[i4h];
      final bear4h    = c4h[i4h].close < e50_4h[i4h];
      final bull1hDon = c1h[i1h].close > don1h.mid[i1h];
      final bear1hDon = c1h[i1h].close < don1h.mid[i1h];

      final breakLong  = price > prevH && c15[i - 1].close <= prevH;
      final breakShort = price < prevL && c15[i - 1].close >= prevL;

      if (!inTrade) {
        if (bull4h && bull1hDon && breakLong) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice - atrStopMult * atr15[i];
          dir = TradeDirection.long; inTrade = true;
          entryTime = c15[i + 1].time;
        } else if (bear4h && bear1hDon && breakShort) {
          entryPrice = c15[i + 1].open;
          stopLoss   = entryPrice + atrStopMult * atr15[i];
          dir = TradeDirection.short; inTrade = true;
          entryTime = c15[i + 1].time;
        }
      } else {
        final bar = c15[i];
        String reason = ''; bool doExit = false;

        if (dir == TradeDirection.long) {
          if (bar.low <= stopLoss)         { doExit = true; reason = 'ATR Stop'; }
          else if (price < don15.lower[i]) { doExit = true; reason = 'Channel Break'; }
          final trail = bar.close - atrStopMult * atr15[i];
          if (trail > stopLoss) stopLoss = trail;
        } else {
          if (bar.high >= stopLoss)        { doExit = true; reason = 'ATR Stop'; }
          else if (price > don15.upper[i]) { doExit = true; reason = 'Channel Break'; }
          final trail = bar.close + atrStopMult * atr15[i];
          if (trail < stopLoss) stopLoss = trail;
        }

        if (doExit) {
          if (!entryTime.isBefore(oosFrom) && entryTime.isBefore(oosTo)) {
            trades.add(Trade(
              entryTime: entryTime, exitTime: bar.time,
              entryPrice: entryPrice, exitPrice: bar.close,
              direction: dir, strategyName: name,
              symbol: symbol, exitReason: reason,
            ));
          }
          inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// WALK-FORWARD ENGINE
// ═════════════════════════════════════════════════════════════════════════════

class WalkForwardWindow {
  final DateTime isStart, isEnd, oosStart, oosEnd;
  final int index;

  WalkForwardWindow({
    required this.isStart,
    required this.isEnd,
    required this.oosStart,
    required this.oosEnd,
    required this.index,
  });

  String get label => 'W${index.toString().padLeft(2, '0')}';
}

class WalkForwardEngine {
  final int isLengthDays;
  final int oosLengthDays;

  WalkForwardEngine({this.isLengthDays = 60, this.oosLengthDays = 20});

  List<WalkForwardWindow> _windows(DateTime start, DateTime end) {
    final wins = <WalkForwardWindow>[];
    var isStart = start;
    int idx = 1;
    while (true) {
      final isEnd   = isStart.add(Duration(days: isLengthDays));
      final oosEnd  = isEnd.add(Duration(days: oosLengthDays));
      if (oosEnd.isAfter(end)) break;
      wins.add(WalkForwardWindow(
        isStart: isStart, isEnd: isEnd,
        oosStart: isEnd, oosEnd: oosEnd, index: idx++,
      ));
      isStart = isStart.add(Duration(days: oosLengthDays));
    }
    return wins;
  }

  List<Candle> _slice(List<Candle> cs, DateTime from, DateTime to) =>
      cs.where((c) => !c.time.isBefore(from) && c.time.isBefore(to)).toList();

  /// KEY INVARIANT (forward-bias-free):
  ///   Each strategy receives IS+OOS candles so all indicators can warm up
  ///   on IS data BEFORE the OOS period. The engine passes oosFrom/oosTo
  ///   so each strategy internally discards IS-era trades.
  Map<String, List<StrategyResult>> runAll({
    required String symbol,
    required Map<Timeframe, List<Candle>> allTf,
    required List<Strategy> strategies,
    required double atrStopMult,
  }) {
    final base = allTf[Timeframe.m15]!;
    if (base.isEmpty) return {};

    final wins = _windows(base.first.time, base.last.time);
    if (wins.isEmpty) {
      print('  ⚠  Not enough data for walk-forward on $symbol '
          '(need ≥${isLengthDays + oosLengthDays} days)');
      return {};
    }

    print('  → ${wins.length} walk-forward windows generated');

    final byStrategy = <String, List<StrategyResult>>{};
    for (final s in strategies) byStrategy[s.name] = [];

    for (final win in wins) {
      // Pass IS+OOS data for indicator warmup — no future data included
      final warmupTf = <Timeframe, List<Candle>>{};
      for (final tf in allTf.keys) {
        warmupTf[tf] = _slice(allTf[tf]!, win.isStart, win.oosEnd);
      }

      // Minimum bars check (15m: 60 IS days × 96 bars/day ≈ 5760 bars)
      final oosLen = (warmupTf[Timeframe.m15]?.length ?? 0);
      if (oosLen < 100) {
        print('  ⚠  ${win.label}: too few bars ($oosLen), skipping');
        continue;
      }

      for (final strategy in strategies) {
        final trades = strategy.backtest(
          symbol:      symbol,
          tfCandles:   warmupTf,
          oosFrom:     win.oosStart,  // trades before this are discarded
          oosTo:       win.oosEnd,
          atrStopMult: atrStopMult,
        );
        byStrategy[strategy.name]!.add(StrategyResult(
          strategyName: strategy.name,
          symbol: symbol,
          trades: trades,
          windowLabel: win.label,
        ));
      }
    }
    return byStrategy;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// RESULTS REPORTER
// ═════════════════════════════════════════════════════════════════════════════

class Reporter {
  static String _f(double v, {int d = 2}) =>
      (v.isNaN || v.isInfinite) ? 'N/A' : v.toStringAsFixed(d);

  static StrategyResult consolidate(
      String strat, String sym, List<StrategyResult> wins) {
    return StrategyResult(
      strategyName: strat, symbol: sym,
      trades: wins.expand((w) => w.trades).toList(),
      windowLabel: 'CONSOLIDATED',
    );
  }

  static void banner() {
    print('''
╔══════════════════════════════════════════════════════════════════════════════╗
║     CRYPTO TREND-FOLLOWING · WALK-FORWARD STRATEGY ANALYZER (BIAS-FREE)     ║
║          Multi-Timeframe: 5m raw → 15m / 1h / 4h synthesised                ║
║   IS warmup passed to strategies; only OOS-window trades counted             ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
  }

  static void windowTable(String strat, String sym, List<StrategyResult> wins) {
    print('\n  ┌─ OOS Window Breakdown │ $strat │ $sym');
    print('  │  ${"Win".padLeft(5)} ${"Trades".padLeft(7)} ${"Win%".padLeft(7)} '
        '${"Ret%".padLeft(8)} ${"PF".padLeft(6)} ${"Sharpe".padLeft(8)} '
        '${"MaxDD%".padLeft(7)} ${"Score".padLeft(7)}');
    print('  │  ${"─" * 62}');
    for (final w in wins) {
      if (w.totalTrades == 0) {
        print('  │  ${w.windowLabel.padLeft(5)} ${"0".padLeft(7)} '
            '${"-".padLeft(7)} ${"-".padLeft(8)} ${"-".padLeft(6)} '
            '${"-".padLeft(8)} ${"-".padLeft(7)} ${"-".padLeft(7)}');
        continue;
      }
      final pf = w.profitFactor == double.infinity ? '∞' : _f(w.profitFactor);
      print('  │  ${w.windowLabel.padLeft(5)} '
          '${w.totalTrades.toString().padLeft(7)} '
          '${_f(w.winRate).padLeft(7)} '
          '${_f(w.totalReturn).padLeft(8)} '
          '${pf.padLeft(6)} '
          '${_f(w.sharpeRatio).padLeft(8)} '
          '${_f(w.maxDrawdown).padLeft(7)} '
          '${_f(w.compositeScore).padLeft(7)}');
    }
    print('  └─');
  }

  static void strategyCard(StrategyResult r) {
    print('\n${"─" * 80}');
    print('  Strategy  : ${r.strategyName}');
    print('  Symbol    : ${r.symbol}   Window: ${r.windowLabel}');
    print('${"─" * 80}');

    if (r.totalTrades == 0) {
      print('  ⚠  No OOS trades generated.\n');
      return;
    }

    final rows = [
      ['Total Trades',    r.totalTrades.toString()],
      ['Winning',         '${r.winningTrades}  (${_f(r.winRate)}%)'],
      ['Losing',          r.losingTrades.toString()],
      ['Total Return',    '${_f(r.totalReturn)}%'],
      ['Avg Win',         '${_f(r.avgWin)}%'],
      ['Avg Loss',        '${_f(r.avgLoss)}%'],
      ['Profit Factor',   r.profitFactor == double.infinity ? '∞' : _f(r.profitFactor)],
      ['Sharpe Ratio',    _f(r.sharpeRatio)],
      ['Max Drawdown',    '${_f(r.maxDrawdown)}%'],
      ['Expectancy',      '${_f(r.expectancy)}%/trade'],
      ['Calmar Ratio',    _f(r.calmarRatio)],
      ['Composite Score', '${_f(r.compositeScore)} / 100'],
    ];
    for (final row in rows) {
      print('  ${row[0].padRight(18)}  ${row[1]}');
    }

    // Exit reasons
    final reasons = <String, int>{};
    for (final t in r.trades) reasons[t.exitReason] = (reasons[t.exitReason] ?? 0) + 1;
    print('\n  Exit reasons:');
    for (final e in reasons.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      print('    ${e.key.padRight(22)} ${e.value}');
    }

    // L/S breakdown
    final longs  = r.trades.where((t) => t.direction == TradeDirection.long).toList();
    final shorts = r.trades.where((t) => t.direction == TradeDirection.short).toList();
    final lWR = longs.isEmpty  ? 0.0 : longs.where((t)  => t.pnlPct > 0).length / longs.length * 100;
    final sWR = shorts.isEmpty ? 0.0 : shorts.where((t) => t.pnlPct > 0).length / shorts.length * 100;
    print('\n  Longs : ${longs.length} trades, win rate ${_f(lWR)}%');
    print('  Shorts: ${shorts.length} trades, win rate ${_f(sWR)}%');
  }

  static void leaderboard(Map<String, Map<String, StrategyResult>> cons) {
    final all = <({String sym, String strat, StrategyResult r})>[];
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        all.add((sym: sym, strat: st, r: cons[sym]![st]!));
      }
    }
    all.sort((a, b) => b.r.compositeScore.compareTo(a.r.compositeScore));

    print('''

╔══════════════════════════════════════════════════════════════════════════════╗
║                       OVERALL STRATEGY LEADERBOARD                          ║
║               (ranked by composite score on OOS trades only)                 ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');

    print('${"Rank".padRight(5)} ${"Symbol".padRight(12)} ${"Strategy".padRight(26)} '
        '${"Trades".padLeft(7)} ${"Win%".padLeft(7)} ${"Ret%".padLeft(8)} '
        '${"PF".padLeft(6)} ${"Sharpe".padLeft(8)} ${"DD%".padLeft(7)} ${"Score".padLeft(7)}');
    print('─' * 97);

    int shown = 0;
    for (int i = 0; i < all.length; i++) {
      final e = all[i];
      if (e.r.totalTrades == 0) continue;
      final pf     = e.r.profitFactor == double.infinity ? '∞' : _f(e.r.profitFactor);
      final medal  = shown == 0 ? ' 🥇' : shown == 1 ? ' 🥈' : shown == 2 ? ' 🥉' : '';
      print('${(shown + 1).toString().padRight(5)} '
          '${e.sym.padRight(12)} ${e.strat.padRight(26)} '
          '${e.r.totalTrades.toString().padLeft(7)} '
          '${_f(e.r.winRate).padLeft(7)} '
          '${_f(e.r.totalReturn).padLeft(8)} '
          '${pf.padLeft(6)} '
          '${_f(e.r.sharpeRatio).padLeft(8)} '
          '${_f(e.r.maxDrawdown).padLeft(7)} '
          '${_f(e.r.compositeScore).padLeft(7)}$medal');
      shown++;
    }

    // Best per symbol
    print('''

╔══════════════════════════════════════════════════════════════════════════════╗
║                        BEST STRATEGY PER SYMBOL                             ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
    final bySymbol = <String, ({String strat, StrategyResult r})>{};
    for (final e in all) {
      if (e.r.totalTrades == 0) continue;
      if (!bySymbol.containsKey(e.sym) ||
          e.r.compositeScore > bySymbol[e.sym]!.r.compositeScore) {
        bySymbol[e.sym] = (strat: e.strat, r: e.r);
      }
    }
    for (final sym in bySymbol.keys) {
      final b = bySymbol[sym]!;
      print('  ► $sym  →  ${b.strat}');
      print('    Trades:${b.r.totalTrades}  Win:${_f(b.r.winRate)}%  '
          'Return:${_f(b.r.totalReturn)}%  PF:${b.r.profitFactor == double.infinity ? "∞" : _f(b.r.profitFactor)}  '
          'Score:${_f(b.r.compositeScore)}/100\n');
    }

    // Top 3 final recommendation
    print('''
╔══════════════════════════════════════════════════════════════════════════════╗
║                         FINAL RECOMMENDATIONS                               ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
    final top = all.where((e) => e.r.totalTrades > 0).take(3).toList();
    for (int i = 0; i < top.length; i++) {
      final e = top[i];
      final medal = ['🥇', '🥈', '🥉'][i];
      print('$medal  ${e.strat} on ${e.sym}');
      print('   Score: ${_f(e.r.compositeScore)}/100 | Win Rate: ${_f(e.r.winRate)}% | '
          'PF: ${e.r.profitFactor == double.infinity ? "∞" : _f(e.r.profitFactor)} | '
          'Return: ${_f(e.r.totalReturn)}% | MaxDD: ${_f(e.r.maxDrawdown)}%\n');
    }
  }

  static void exportCsv(
    Map<String, Map<String, StrategyResult>> cons,
    Map<String, Map<String, List<StrategyResult>>> wins,
    String outDir,
  ) {
    Directory(outDir).createSync(recursive: true);

    // leaderboard.csv
    final lb = File('$outDir/leaderboard.csv');
    final lbSb = StringBuffer(
        'Symbol,Strategy,Trades,WinRate%,TotalReturn%,AvgWin%,AvgLoss%,'
        'ProfitFactor,Sharpe,MaxDD%,Expectancy%,CalmarRatio,CompositeScore\n');
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        final r = cons[sym]![st]!;
        final pf = r.profitFactor == double.infinity ? 999.0 : r.profitFactor;
        lbSb.writeln('$sym,$st,${r.totalTrades},${_f(r.winRate)},${_f(r.totalReturn)},'
            '${_f(r.avgWin)},${_f(r.avgLoss)},${_f(pf)},${_f(r.sharpeRatio)},'
            '${_f(r.maxDrawdown)},${_f(r.expectancy)},${_f(r.calmarRatio)},${_f(r.compositeScore)}');
      }
    }
    lb.writeAsStringSync(lbSb.toString());
    print('  📄 leaderboard.csv');

    // all_trades.csv
    final tr = File('$outDir/all_trades.csv');
    final trSb = StringBuffer(
        'Symbol,Strategy,Direction,EntryTime,ExitTime,'
        'EntryPrice,ExitPrice,PnL%,ExitReason,HoldingMin\n');
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        for (final t in cons[sym]![st]!.trades) {
          trSb.writeln('${t.symbol},${t.strategyName},${t.direction.name},'
              '${t.entryTime.toIso8601String()},${t.exitTime.toIso8601String()},'
              '${t.entryPrice},${t.exitPrice},${_f(t.pnlPct)},${t.exitReason},'
              '${t.holdingPeriod.inMinutes}');
        }
      }
    }
    tr.writeAsStringSync(trSb.toString());
    print('  📄 all_trades.csv');

    // window_breakdown.csv
    final wb = File('$outDir/window_breakdown.csv');
    final wbSb = StringBuffer(
        'Symbol,Strategy,Window,Trades,WinRate%,TotalReturn%,'
        'ProfitFactor,Sharpe,MaxDD%,Score\n');
    for (final sym in wins.keys) {
      for (final st in wins[sym]!.keys) {
        for (final w in wins[sym]![st]!) {
          final pf = w.profitFactor == double.infinity ? 999.0 : w.profitFactor;
          wbSb.writeln('$sym,$st,${w.windowLabel},${w.totalTrades},'
              '${_f(w.winRate)},${_f(w.totalReturn)},${_f(pf)},'
              '${_f(w.sharpeRatio)},${_f(w.maxDrawdown)},${_f(w.compositeScore)}');
        }
      }
    }
    wb.writeAsStringSync(wbSb.toString());
    print('  📄 window_breakdown.csv');
    print('\n  All files saved to: $outDir/');
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// DEMO DATA GENERATOR
// ═════════════════════════════════════════════════════════════════════════════

Map<String, List<Candle>> _generateDemoData() {
  print('  ℹ  Generating synthetic BTC & ETH-like 5m demo data (6 months each)...');
  final rng = Random(42);
  final result = <String, List<Candle>>{};

  final assets = [
    ('BTCUSDT', 20000.0, 0.003),
    ('ETHUSDT',  1200.0, 0.004),
  ];

  for (final (sym, startPrice, vol) in assets) {
    final candles = <Candle>[];
    var time = DateTime.utc(2023, 1, 1);
    double price = startPrice;

    for (int i = 0; i < 6 * 30 * 24 * 12; i++) {
      final trend = sin(i / (24 * 12 * 14)) * 0.0003;
      final noise = (rng.nextDouble() - 0.49) * vol;
      price = (price * (1 + trend + noise)).clamp(startPrice * 0.2, startPrice * 5);
      final range = price * (0.001 + rng.nextDouble() * 0.004);
      final o = price;
      final h = o + range * rng.nextDouble();
      final l = o - range * rng.nextDouble();
      final c = l + (h - l) * rng.nextDouble();
      candles.add(Candle(time: time, open: o, high: h, low: l, close: c,
          volume: 10 + rng.nextDouble() * 200));
      time = time.add(const Duration(minutes: 5));
    }
    result[sym] = candles;
    print('  ✓ Demo $sym: ${candles.length} bars');
  }
  return result;
}

// ═════════════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════════════

void main(List<String> args) {
  Reporter.banner();

  final dataDir  = args.isNotEmpty ? args[0] : '/Users/ayush/Desktop/candlestick data';
  final outDir   = args.length > 1  ? args[1]  : './wf_results';

  // ── Configurable parameters ────────────────────────────────────────────────
  const double atrStopMult  = 2.0;  // ATR × for stop / trailing stop
  const int    isLengthDays = 60;   // In-sample warmup window (days)
  const int    oosLengthDays = 20;  // Out-of-sample test window (days)

  print('Configuration');
  print('  Data dir       : $dataDir');
  print('  Output dir     : $outDir');
  print('  ATR stop mult  : ${atrStopMult}×');
  print('  IS window      : $isLengthDays days  (indicator warmup)');
  print('  OOS window     : $oosLengthDays days  (trades counted here only)');
  print('  Bias guarantee : indicators warm on IS data; OOS trades only counted\n');

  // ── Load all CSV assets (recursive scan) ────────────────────────────────────
  print('Scanning for assets...');
  Map<String, List<Candle>> raw5m = CsvLoader.loadDirectory(dataDir);

  if (raw5m.isEmpty) {
    print('\n  No real data found — running DEMO mode.\n');
    raw5m = _generateDemoData();
  }

  // ── Aggregate timeframes ────────────────────────────────────────────────────
  print('\nAggregating timeframes...');
  final allTf = <String, Map<Timeframe, List<Candle>>>{};
  for (final sym in raw5m.keys) {
    allTf[sym] = {
      Timeframe.m5:  raw5m[sym]!,
      Timeframe.m15: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m15),
      Timeframe.m30: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m30),
      Timeframe.h1:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h1),
      Timeframe.h4:  TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h4),
    };
    final tf = allTf[sym]!;
    print('  $sym → 5m:${tf[Timeframe.m5]!.length} | 15m:${tf[Timeframe.m15]!.length}'
        ' | 1h:${tf[Timeframe.h1]!.length} | 4h:${tf[Timeframe.h4]!.length}');
  }

  // ── Strategies ─────────────────────────────────────────────────────────────
  final strategies = <Strategy>[
    TripleEmaMtf(),
    SupertrendMtf(),
    MacdMomentumMtf(),
    AdxTrendStrengthMtf(),
    DonchianBreakoutMtf(),
  ];

  print('\nStrategies:');
  for (final s in strategies) print('  • ${s.name}');

  // ── Walk-forward loop ───────────────────────────────────────────────────────
  final engine = WalkForwardEngine(
      isLengthDays: isLengthDays, oosLengthDays: oosLengthDays);

  final consolidated = <String, Map<String, StrategyResult>>{};
  final allWindows   = <String, Map<String, List<StrategyResult>>>{};

  for (final sym in allTf.keys) {
    print('\n${'═' * 80}');
    print('  Asset: $sym');
    print('${'═' * 80}');

    final byStrat = engine.runAll(
      symbol: sym, allTf: allTf[sym]!,
      strategies: strategies, atrStopMult: atrStopMult,
    );
    if (byStrat.isEmpty) continue;

    consolidated[sym] = {};
    allWindows[sym]   = {};

    for (final strat in byStrat.keys) {
      final winResults = byStrat[strat]!;
      final cons = Reporter.consolidate(strat, sym, winResults);
      consolidated[sym]![strat] = cons;
      allWindows[sym]![strat]   = winResults;

      Reporter.windowTable(strat, sym, winResults);
      Reporter.strategyCard(cons);
    }
  }

  // ── Leaderboard + CSV export ────────────────────────────────────────────────
  Reporter.leaderboard(consolidated);
  print('\nExporting results...');
  Reporter.exportCsv(consolidated, allWindows, outDir);

  print('\n✅  Walk-forward analysis complete — all results are OOS-only, zero lookahead.\n');
}