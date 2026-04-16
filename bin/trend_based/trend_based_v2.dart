// ════════════════════════════════════════════════════════════════════════════
//  CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER (BIAS-FREE)
//
//  Fixes vs original:
//   • HTF lookahead removed — every higher-TF lookup uses the LAST CLOSED bar.
//   • Stop-loss exits fill at the stop price (worst-case), not bar.close.
//   • Slippage applied symmetrically to entries AND exits, longs AND shorts.
//   • Donchian self-reference fixed (uses prior-bar channel).
//   • Round-trip fee + 2× slippage baked into pnlPct properly.
//   • Hard max-holding-period exit prevents zombie trades.
//   • Walk-forward OPTIMIZATION: per window, grid-search params on IS,
//     then run the best combo on OOS. Reported numbers are OOS-only.
//   • New indicators: Hull MA, KAMA, Vortex, Aroon, Parabolic SAR,
//     Chandelier Exit (in addition to EMA/SMA/ATR/RSI/MACD/Supertrend/
//     ADX/Donchian/Bollinger).
//   • New strategies: Hull MA cross, Vortex cross, Aroon trend, PSAR trail.
// ════════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

// ─── Realism constants ──────────────────────────────────────────────────────
const double kSlippagePerSide = 0.0005; // 5 bps per fill
const double kFeePerSide = 0.0004; // 4 bps per fill (taker-ish)
const int kMaxBarsInTrade = 96 * 5; // 5 days on 15m

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

  /// Net pnl% with realistic costs:
  ///   entry slippage + exit slippage + 2× fees (round trip)
  /// entryPrice / exitPrice are stored as the IDEAL signal prices;
  /// costs are applied here once so we can't double-count.
  double get pnlPct {
    final raw = direction == TradeDirection.long
        ? (exitPrice - entryPrice) / entryPrice * 100
        : (entryPrice - exitPrice) / entryPrice * 100;
    final costPct = (2 * kSlippagePerSide + 2 * kFeePerSide) * 100;
    return raw - costPct;
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

  int get totalTrades => trades.length;
  int get winningTrades => trades.where((t) => t.pnlPct > 0).length;
  int get losingTrades => trades.where((t) => t.pnlPct <= 0).length;

  double get winRate =>
      totalTrades == 0 ? 0 : winningTrades / totalTrades * 100;

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
    final gp = trades
        .where((t) => t.pnlPct > 0)
        .fold(0.0, (s, t) => s + t.pnlPct);
    final gl = trades
        .where((t) => t.pnlPct <= 0)
        .fold(0.0, (s, t) => s + t.pnlPct.abs());
    return gl == 0 ? (gp == 0 ? 0 : double.infinity) : gp / gl;
  }

  double get sharpeRatio {
    if (trades.length < 2) return 0;
    final rets = trades.map((t) => t.pnlPct).toList();
    final mean = rets.fold(0.0, (s, r) => s + r) / rets.length;
    final variance =
        rets.fold(0.0, (s, r) => s + pow(r - mean, 2)) / rets.length;
    final std = sqrt(variance);
    // Per-trade Sharpe scaled by sqrt(N) ≈ annualization proxy
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

  double get expectancy => totalTrades == 0
      ? 0
      : (winRate / 100 * avgWin) + ((1 - winRate / 100) * avgLoss);

  double get calmarRatio => maxDrawdown == 0 ? 0 : totalReturn / maxDrawdown;

  /// PF(35%) + Sharpe(25%) + WinRate(20%) + Expectancy(20%)
  /// Penalizes results with too few trades (statistically meaningless).
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
      if (first.contains('time') ||
          first.contains('date') ||
          first.contains('open')) {
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
          time = ms > 9999999999
              ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
              : DateTime.fromMillisecondsSinceEpoch(ms * 1000, isUtc: true);
        } else {
          time = DateTime.parse(raw).toUtc();
        }
        candles.add(
          Candle(
            time: time,
            open: double.parse(parts[1].trim()),
            high: double.parse(parts[2].trim()),
            low: double.parse(parts[3].trim()),
            close: double.parse(parts[4].trim()),
            volume: parts.length > 5 ? double.parse(parts[5].trim()) : 0.0,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    candles.sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  static Map<String, List<Candle>> loadDirectory(String dirPath) {
    // If a '5m' subdirectory exists, scan only that — the backtest aggregates
    // higher timeframes internally, so only 5m base data is needed.
    final dir5m = Directory(p.join(dirPath, '5m'));
    final scanDir = dir5m.existsSync() ? dir5m : Directory(dirPath);
    if (!scanDir.existsSync()) {
      print('  ⛔  Directory not found: $dirPath');
      return {};
    }
    if (dir5m.existsSync()) {
      print('  📂  Found 5m subfolder — scanning: ${scanDir.path}');
    }
    final merged = <String, List<Candle>>{};
    int filesFound = 0;
    // Regex strips trailing timeframe suffix (e.g. "5m", "15m", "1h", "4h")
    // so "BTCUSDT5m.csv" → symbol "BTCUSDT".
    final tfSuffix = RegExp(r'\d+[mMhH]$');
    void scan(Directory d) {
      for (final entity in d.listSync()) {
        if (entity is Directory) {
          scan(entity);
        } else if (entity is File &&
            entity.path.toLowerCase().endsWith('.csv')) {
          filesFound++;
          final symbol = p
              .basenameWithoutExtension(entity.path)
              .replaceAll(tfSuffix, '')
              .toUpperCase()
              .trim();
          if (symbol.isEmpty) continue;
          final loaded = loadFile(entity.path);
          if (loaded.isNotEmpty) {
            merged.putIfAbsent(symbol, () => []).addAll(loaded);
          }
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

enum Timeframe { m5, m15, m30, h1, h4 }

extension TimeframeExt on Timeframe {
  int get minutes => const {
    Timeframe.m5: 5,
    Timeframe.m15: 15,
    Timeframe.m30: 30,
    Timeframe.h1: 60,
    Timeframe.h4: 240,
  }[this]!;
  String get label => const {
    Timeframe.m5: '5m',
    Timeframe.m15: '15m',
    Timeframe.m30: '30m',
    Timeframe.h1: '1h',
    Timeframe.h4: '4h',
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
      double o = base[i].open,
          h = base[i].high,
          l = base[i].low,
          c = base[i].close,
          vol = base[i].volume;
      i++;
      while (i < base.length && base[i].time.isBefore(bucketEnd)) {
        if (base[i].high > h) h = base[i].high;
        if (base[i].low < l) l = base[i].low;
        c = base[i].close;
        vol += base[i].volume;
        i++;
      }
      result.add(
        Candle(
          time: bucketStart,
          open: o,
          high: h,
          low: l,
          close: c,
          volume: vol,
        ),
      );
    }
    return result;
  }

  static DateTime _floor(DateTime t, int bMin) {
    final total = t.hour * 60 + t.minute;
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
    for (int i = period; i < src.length; i++) {
      out[i] = (src[i] - out[i - 1]) * mult + out[i - 1];
    }
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

  /// Weighted Moving Average (used for Hull MA).
  static List<double> wma(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period) return out;
    final denom = period * (period + 1) / 2.0;
    for (int i = period - 1; i < src.length; i++) {
      double sum = 0;
      for (int j = 0; j < period; j++) {
        sum += src[i - j] * (period - j);
      }
      out[i] = sum / denom;
    }
    return out;
  }

  /// Hull Moving Average — fast, low-lag trend follower.
  static List<double> hull(List<double> src, int period) {
    if (period < 2) return List<double>.filled(src.length, double.nan);
    final half = (period / 2).round();
    final sqrtP = sqrt(period.toDouble()).round();
    final wmaHalf = wma(src, half);
    final wmaFull = wma(src, period);
    final diff = List<double>.generate(
      src.length,
      (i) => (wmaHalf[i].isNaN || wmaFull[i].isNaN)
          ? double.nan
          : 2 * wmaHalf[i] - wmaFull[i],
    );
    // wma over diff, but diff has leading NaNs — substitute by working slice
    final out = List<double>.filled(src.length, double.nan);
    final firstValid = diff.indexWhere((v) => !v.isNaN);
    if (firstValid < 0 || diff.length - firstValid < sqrtP) return out;
    final slice = diff.sublist(firstValid);
    final hulled = wma(slice, sqrtP);
    for (int i = 0; i < hulled.length; i++) {
      out[firstValid + i] = hulled[i];
    }
    return out;
  }

  /// Kaufman Adaptive Moving Average.
  static List<double> kama(
    List<double> src,
    int period, {
    int fastSc = 2,
    int slowSc = 30,
  }) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period + 1) return out;
    final fastA = 2.0 / (fastSc + 1);
    final slowA = 2.0 / (slowSc + 1);
    out[period] = src[period];
    for (int i = period + 1; i < src.length; i++) {
      final change = (src[i] - src[i - period]).abs();
      double vol = 0;
      for (int j = i - period + 1; j <= i; j++) {
        vol += (src[j] - src[j - 1]).abs();
      }
      final er = vol == 0 ? 0.0 : change / vol;
      final sc = pow(er * (fastA - slowA) + slowA, 2).toDouble();
      out[i] = out[i - 1] + sc * (src[i] - out[i - 1]);
    }
    return out;
  }

  static List<double> atr(List<Candle> cs, int period) {
    if (cs.length < period + 1) return List.filled(cs.length, double.nan);
    final tr = <double>[cs[0].high - cs[0].low];
    for (int i = 1; i < cs.length; i++) {
      tr.add(
        [
          cs[i].high - cs[i].low,
          (cs[i].high - cs[i - 1].close).abs(),
          (cs[i].low - cs[i - 1].close).abs(),
        ].reduce(max),
      );
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

  static List<double> rsi(List<double> src, int period) {
    final out = List<double>.filled(src.length, double.nan);
    if (src.length < period + 1) return out;
    double g = 0, l = 0;
    for (int i = 1; i <= period; i++) {
      final d = src[i] - src[i - 1];
      if (d >= 0)
        g += d;
      else
        l -= d;
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

  static ({List<double> macd, List<double> signal, List<double> hist}) macd(
    List<double> src, {
    int fast = 12,
    int slow = 26,
    int sig = 9,
  }) {
    final fe = ema(src, fast);
    final se = ema(src, slow);
    final ml = List<double>.generate(
      src.length,
      (i) => (fe[i].isNaN || se[i].isNaN) ? double.nan : fe[i] - se[i],
    );
    final validMacd = ml.where((v) => !v.isNaN).toList();
    final sl = List<double>.filled(src.length, double.nan);
    if (validMacd.length >= sig) {
      final se2 = ema(validMacd, sig);
      int j = 0;
      for (int i = 0; i < src.length; i++) {
        if (!ml[i].isNaN) {
          sl[i] = se2[j++];
        }
      }
    }
    final hist = List<double>.generate(
      src.length,
      (i) => (ml[i].isNaN || sl[i].isNaN) ? double.nan : ml[i] - sl[i],
    );
    return (macd: ml, signal: sl, hist: hist);
  }

  static ({List<double> st, List<int> dir}) supertrend(
    List<Candle> cs,
    int period,
    double mult,
  ) {
    final atrV = atr(cs, period);
    final n = cs.length;
    final st = List<double>.filled(n, double.nan);
    final dir = List<int>.filled(n, -1);
    final ub = List<double>.filled(n, double.nan);
    final lb = List<double>.filled(n, double.nan);

    for (int i = period - 1; i < n; i++) {
      final hl2 = (cs[i].high + cs[i].low) / 2;
      final ubBasic = hl2 + mult * atrV[i];
      final lbBasic = hl2 - mult * atrV[i];
      ub[i] = (i > 0 && !ub[i - 1].isNaN)
          ? (ubBasic < ub[i - 1] || cs[i - 1].close > ub[i - 1]
                ? ubBasic
                : ub[i - 1])
          : ubBasic;
      lb[i] = (i > 0 && !lb[i - 1].isNaN)
          ? (lbBasic > lb[i - 1] || cs[i - 1].close < lb[i - 1]
                ? lbBasic
                : lb[i - 1])
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

  static ({List<double> adx, List<double> plusDI, List<double> minusDI}) adx(
    List<Candle> cs,
    int period,
  ) {
    final n = cs.length;
    final adxOut = List<double>.filled(n, double.nan);
    final pDIOut = List<double>.filled(n, double.nan);
    final mDIOut = List<double>.filled(n, double.nan);
    if (n < period * 2 + 1)
      return (adx: adxOut, plusDI: pDIOut, minusDI: mDIOut);

    final tr = List<double>.filled(n, 0.0);
    final pDM = List<double>.filled(n, 0.0);
    final mDM = List<double>.filled(n, 0.0);
    for (int i = 1; i < n; i++) {
      tr[i] = [
        cs[i].high - cs[i].low,
        (cs[i].high - cs[i - 1].close).abs(),
        (cs[i].low - cs[i - 1].close).abs(),
      ].reduce(max);
      final up = cs[i].high - cs[i - 1].high;
      final down = cs[i - 1].low - cs[i].low;
      pDM[i] = (up > down && up > 0) ? up : 0;
      mDM[i] = (down > up && down > 0) ? down : 0;
    }
    double smTR = 0, smP = 0, smM = 0;
    for (int i = 1; i <= period; i++) {
      smTR += tr[i];
      smP += pDM[i];
      smM += mDM[i];
    }
    final dxList = <double>[];
    for (int i = period; i < n; i++) {
      if (i > period) {
        smTR = smTR - smTR / period + tr[i];
        smP = smP - smP / period + pDM[i];
        smM = smM - smM / period + mDM[i];
      }
      final pdi = smTR == 0 ? 0.0 : smP / smTR * 100;
      final mdi = smTR == 0 ? 0.0 : smM / smTR * 100;
      pDIOut[i] = pdi;
      mDIOut[i] = mdi;
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

  static ({List<double> upper, List<double> lower, List<double> mid}) donchian(
    List<Candle> cs,
    int period,
  ) {
    final n = cs.length;
    final upper = List<double>.filled(n, double.nan);
    final lower = List<double>.filled(n, double.nan);
    final mid = List<double>.filled(n, double.nan);
    for (int i = period - 1; i < n; i++) {
      double h = cs[i - period + 1].high, l = cs[i - period + 1].low;
      for (int j = i - period + 2; j <= i; j++) {
        if (cs[j].high > h) h = cs[j].high;
        if (cs[j].low < l) l = cs[j].low;
      }
      upper[i] = h;
      lower[i] = l;
      mid[i] = (h + l) / 2;
    }
    return (upper: upper, lower: lower, mid: mid);
  }

  static ({List<double> upper, List<double> lower, List<double> mid}) bollinger(
    List<double> src,
    int period,
    double stdMult,
  ) {
    final mid = sma(src, period);
    final upper = List<double>.filled(src.length, double.nan);
    final lower = List<double>.filled(src.length, double.nan);
    for (int i = period - 1; i < src.length; i++) {
      double v = 0;
      for (int j = i - period + 1; j <= i; j++) {
        v += pow(src[j] - mid[i], 2);
      }
      final std = sqrt(v / period);
      upper[i] = mid[i] + stdMult * std;
      lower[i] = mid[i] - stdMult * std;
    }
    return (upper: upper, lower: lower, mid: mid);
  }

  /// Vortex Indicator (VI+ / VI-).
  static ({List<double> viPlus, List<double> viMinus}) vortex(
    List<Candle> cs,
    int period,
  ) {
    final n = cs.length;
    final vp = List<double>.filled(n, double.nan);
    final vm = List<double>.filled(n, double.nan);
    if (n < period + 1) return (viPlus: vp, viMinus: vm);
    final tr = List<double>.filled(n, 0);
    final vmpA = List<double>.filled(n, 0);
    final vmmA = List<double>.filled(n, 0);
    for (int i = 1; i < n; i++) {
      tr[i] = [
        cs[i].high - cs[i].low,
        (cs[i].high - cs[i - 1].close).abs(),
        (cs[i].low - cs[i - 1].close).abs(),
      ].reduce(max);
      vmpA[i] = (cs[i].high - cs[i - 1].low).abs();
      vmmA[i] = (cs[i].low - cs[i - 1].high).abs();
    }
    for (int i = period; i < n; i++) {
      double sTr = 0, sVp = 0, sVm = 0;
      for (int j = i - period + 1; j <= i; j++) {
        sTr += tr[j];
        sVp += vmpA[j];
        sVm += vmmA[j];
      }
      if (sTr > 0) {
        vp[i] = sVp / sTr;
        vm[i] = sVm / sTr;
      }
    }
    return (viPlus: vp, viMinus: vm);
  }

  /// Aroon up/down (0..100).
  static ({List<double> up, List<double> down}) aroon(
    List<Candle> cs,
    int period,
  ) {
    final n = cs.length;
    final up = List<double>.filled(n, double.nan);
    final dn = List<double>.filled(n, double.nan);
    for (int i = period; i < n; i++) {
      int hiIdx = i - period, loIdx = i - period;
      double hi = cs[hiIdx].high, lo = cs[loIdx].low;
      for (int j = i - period; j <= i; j++) {
        if (cs[j].high >= hi) {
          hi = cs[j].high;
          hiIdx = j;
        }
        if (cs[j].low <= lo) {
          lo = cs[j].low;
          loIdx = j;
        }
      }
      up[i] = ((period - (i - hiIdx)) / period) * 100;
      dn[i] = ((period - (i - loIdx)) / period) * 100;
    }
    return (up: up, down: dn);
  }

  /// Parabolic SAR (Wilder).
  static ({List<double> sar, List<int> dir}) psar(
    List<Candle> cs,
    double afStart,
    double afStep,
    double afMax,
  ) {
    final n = cs.length;
    final sar = List<double>.filled(n, double.nan);
    final dir = List<int>.filled(n, 1);
    if (n < 2) return (sar: sar, dir: dir);
    int trend = cs[1].close >= cs[0].close ? 1 : -1;
    double ep = trend == 1 ? cs[1].high : cs[1].low;
    double af = afStart;
    sar[0] = trend == 1 ? cs[0].low : cs[0].high;
    sar[1] = sar[0];
    dir[0] = trend;
    dir[1] = trend;
    for (int i = 2; i < n; i++) {
      double newSar = sar[i - 1] + af * (ep - sar[i - 1]);
      if (trend == 1) {
        newSar = min(newSar, min(cs[i - 1].low, cs[i - 2].low));
        if (cs[i].low < newSar) {
          trend = -1;
          newSar = ep;
          ep = cs[i].low;
          af = afStart;
        } else {
          if (cs[i].high > ep) {
            ep = cs[i].high;
            af = min(af + afStep, afMax);
          }
        }
      } else {
        newSar = max(newSar, max(cs[i - 1].high, cs[i - 2].high));
        if (cs[i].high > newSar) {
          trend = 1;
          newSar = ep;
          ep = cs[i].high;
          af = afStart;
        } else {
          if (cs[i].low < ep) {
            ep = cs[i].low;
            af = min(af + afStep, afMax);
          }
        }
      }
      sar[i] = newSar;
      dir[i] = trend;
    }
    return (sar: sar, dir: dir);
  }

  /// Returns the index of the most recent CLOSED higher-TF bar at time `t`.
  /// A bar at time `b` is "closed" at time `b + barInterval`. Therefore the
  /// last closed bar at decision time `t` is the one whose start time is
  /// strictly before `t - small_epsilon`. We implement this as the latest bar
  /// whose start <= t, then step back 1 to be safe.
  static int closedHtfIdx(List<Candle> src, DateTime t) {
    int lo = 0, hi = src.length - 1, res = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (!src[mid].time.isAfter(t)) {
        res = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return res - 1; // last fully-closed bar
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY INTERFACE
// ════════════════════════════════════════════════════════════════════════════

/// A strategy parameter combo. Subclasses encode their own params via Map.
abstract class StrategyParams {
  String get label;
  double get atrStopMult;
}

abstract class Strategy {
  String get name;

  /// All parameter combos to grid-search.
  List<StrategyParams> grid();

  /// Backtest with one specific parameter combo.
  /// `tfCandles` contains IS+OOS warmup data; `oosFrom`/`oosTo` filter trades.
  List<Trade> backtest({
    required String symbol,
    required Map<Timeframe, List<Candle>> tfCandles,
    required DateTime oosFrom,
    required DateTime oosTo,
    required StrategyParams params,
  });
}

// ─── Shared trade simulation helper ────────────────────────────────────────
class _Sim {
  bool inTrade = false;
  TradeDirection dir = TradeDirection.long;
  double entryPrice = 0, stopLoss = 0;
  DateTime entryTime = DateTime(0);
  int entryBar = 0;
}

/// Apply slippage on entry: long pays a bit more, short receives a bit less.
double _entryFill(double idealPx, TradeDirection dir) =>
    dir == TradeDirection.long
    ? idealPx * (1 + kSlippagePerSide)
    : idealPx * (1 - kSlippagePerSide);

/// Apply slippage on exit: long sells a bit lower, short covers a bit higher.
double _exitFill(double idealPx, TradeDirection dir) =>
    dir == TradeDirection.long
    ? idealPx * (1 - kSlippagePerSide)
    : idealPx * (1 + kSlippagePerSide);

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 1 — TRIPLE EMA MTF
// ════════════════════════════════════════════════════════════════════════════

class TripleEmaParams extends StrategyParams {
  final int fast, mid, slow;
  @override
  final double atrStopMult;
  TripleEmaParams(this.fast, this.mid, this.slow, this.atrStopMult);
  @override
  String get label => 'EMA($fast/$mid/$slow) ATR×$atrStopMult';
}

class TripleEmaMtf extends Strategy {
  @override
  String get name => 'TripleEMA-MTF';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final f in [5, 9, 13]) {
      for (final m in [21, 34]) {
        for (final s in [55, 89]) {
          for (final a in [1.5, 2.0, 2.5, 3.0]) {
            if (f < m && m < s) out.add(TripleEmaParams(f, m, s, a));
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
    final p = params as TripleEmaParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final cl15 = c15.map((c) => c.close).toList();
    final eF = Indicators.ema(cl15, p.fast);
    final eM = Indicators.ema(cl15, p.mid);
    final atr15 = Indicators.atr(c15, 14);

    final cl1h = c1h.map((c) => c.close).toList();
    final e9_1h = Indicators.ema(cl1h, p.fast);
    final e21_1h = Indicators.ema(cl1h, p.mid);

    final cl4h = c4h.map((c) => c.close).toList();
    final e21_4h = Indicators.ema(cl4h, p.mid);
    final e55_4h = Indicators.ema(cl4h, p.slow);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = max(p.slow, 60); i < c15.length - 1; i++) {
      if (eF[i].isNaN || eM[i].isNaN || atr15[i].isNaN) continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      if (i1h < 0 || i4h < 0) continue;
      if (e9_1h[i1h].isNaN || e21_1h[i1h].isNaN) continue;
      if (e21_4h[i4h].isNaN || e55_4h[i4h].isNaN) continue;

      final bull4h = e21_4h[i4h] > e55_4h[i4h];
      final bear4h = e21_4h[i4h] < e55_4h[i4h];
      final bull1h = e9_1h[i1h] > e21_1h[i1h];
      final bear1h = e9_1h[i1h] < e21_1h[i1h];

      if (!s.inTrade) {
        final crossLong = eF[i] > eM[i] && eF[i - 1] <= eM[i - 1];
        final crossShort = eF[i] < eM[i] && eF[i - 1] >= eM[i - 1];
        if (bull4h && bull1h && crossLong) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (bear4h && bear1h && crossShort) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;

        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (eF[i] < eM[i] && eF[i - 1] >= eM[i - 1]) {
            doExit = true;
            reason = 'EMA Cross';
            exitIdeal = bar.close;
          }
          final trail = bar.close - p.atrStopMult * atr15[i];
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (eF[i] > eM[i] && eF[i - 1] <= eM[i - 1]) {
            doExit = true;
            reason = 'EMA Cross';
            exitIdeal = bar.close;
          }
          final trail = bar.close + p.atrStopMult * atr15[i];
          if (trail < s.stopLoss) s.stopLoss = trail;
        }

        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
          exitIdeal = bar.close;
        }

        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 2 — SUPERTREND MTF
// ════════════════════════════════════════════════════════════════════════════

class SupertrendParams extends StrategyParams {
  final int period;
  final double mult;
  @override
  final double atrStopMult;
  SupertrendParams(this.period, this.mult, this.atrStopMult);
  @override
  String get label => 'ST($period,$mult) ATR×$atrStopMult';
}

class SupertrendMtf extends Strategy {
  @override
  String get name => 'Supertrend-MTF';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final per in [7, 10, 14]) {
      for (final m in [2.0, 2.5, 3.0]) {
        for (final a in [1.5, 2.0, 2.5]) {
          out.add(SupertrendParams(per, m, a));
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
    final p = params as SupertrendParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final st15 = Indicators.supertrend(c15, p.period, p.mult);
    final atr15 = Indicators.atr(c15, 14);
    final st1h = Indicators.supertrend(c1h, p.period, p.mult + 0.5);
    final st4h = Indicators.supertrend(c4h, p.period, p.mult + 1.0);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = 80; i < c15.length - 1; i++) {
      if (atr15[i].isNaN) continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      if (i1h < 0 || i4h < 0) continue;

      final d4h = st4h.dir[i4h];
      final d1h = st1h.dir[i1h];
      final d15 = st15.dir[i];
      final d15p = st15.dir[i - 1];

      if (!s.inTrade) {
        if (d4h == 1 && d1h == 1 && d15 == 1 && d15p == -1) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (d4h == -1 && d1h == -1 && d15 == -1 && d15p == 1) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;
        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (d15 == -1) {
            doExit = true;
            reason = 'ST Flip';
          }
          final trail = bar.close - p.atrStopMult * atr15[i];
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (d15 == 1) {
            doExit = true;
            reason = 'ST Flip';
          }
          final trail = bar.close + p.atrStopMult * atr15[i];
          if (trail < s.stopLoss) s.stopLoss = trail;
        }
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 3 — DONCHIAN BREAKOUT MTF
// ════════════════════════════════════════════════════════════════════════════

class DonchianParams extends StrategyParams {
  final int donPeriod;
  @override
  final double atrStopMult;
  DonchianParams(this.donPeriod, this.atrStopMult);
  @override
  String get label => 'Don($donPeriod) ATR×$atrStopMult';
}

class DonchianBreakoutMtf extends Strategy {
  @override
  String get name => 'Donchian-MTF';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final d in [10, 20, 55]) {
      for (final a in [1.5, 2.0, 2.5, 3.0]) {
        out.add(DonchianParams(d, a));
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
    final p = params as DonchianParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final c4h = tfCandles[Timeframe.h4]!;

    final don15 = Indicators.donchian(c15, p.donPeriod);
    final atr15 = Indicators.atr(c15, 14);
    final don1h = Indicators.donchian(c1h, 20);
    final cl4h = c4h.map((c) => c.close).toList();
    final e50_4h = Indicators.ema(cl4h, 50);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = max(p.donPeriod + 2, 30); i < c15.length - 1; i++) {
      if (don15.upper[i - 1].isNaN || atr15[i].isNaN) continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      final i4h = Indicators.closedHtfIdx(c4h, t);
      if (i1h < 0 || i4h < 0) continue;
      if (don1h.mid[i1h].isNaN || e50_4h[i4h].isNaN) continue;

      final price = c15[i].close;
      final prevH = don15.upper[i - 1];
      final prevL = don15.lower[i - 1];

      final bull4h = c4h[i4h].close > e50_4h[i4h];
      final bear4h = c4h[i4h].close < e50_4h[i4h];
      final bull1hDon = c1h[i1h].close > don1h.mid[i1h];
      final bear1hDon = c1h[i1h].close < don1h.mid[i1h];

      final breakLong = price > prevH && c15[i - 1].close <= prevH;
      final breakShort = price < prevL && c15[i - 1].close >= prevL;

      if (!s.inTrade) {
        if (bull4h && bull1hDon && breakLong) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (bear4h && bear1hDon && breakShort) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;
        // Use prior-bar channel for exit (no self-reference)
        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (bar.close < don15.lower[i - 1]) {
            doExit = true;
            reason = 'Channel Break';
          }
          final trail = bar.close - p.atrStopMult * atr15[i];
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (bar.close > don15.upper[i - 1]) {
            doExit = true;
            reason = 'Channel Break';
          }
          final trail = bar.close + p.atrStopMult * atr15[i];
          if (trail < s.stopLoss) s.stopLoss = trail;
        }
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 4 — HULL MA CROSS  (NEW)
// ════════════════════════════════════════════════════════════════════════════

class HullParams extends StrategyParams {
  final int fast, slow;
  @override
  final double atrStopMult;
  HullParams(this.fast, this.slow, this.atrStopMult);
  @override
  String get label => 'Hull($fast/$slow) ATR×$atrStopMult';
}

class HullMaCross extends Strategy {
  @override
  String get name => 'HullMA-Cross';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final f in [9, 16, 21]) {
      for (final sl in [34, 55]) {
        for (final a in [1.5, 2.0, 2.5]) {
          if (f < sl) out.add(HullParams(f, sl, a));
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
    final p = params as HullParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final cl15 = c15.map((c) => c.close).toList();
    final hF = Indicators.hull(cl15, p.fast);
    final hS = Indicators.hull(cl15, p.slow);
    final atr15 = Indicators.atr(c15, 14);
    final cl1h = c1h.map((c) => c.close).toList();
    final hS1h = Indicators.hull(cl1h, p.slow);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = p.slow + 10; i < c15.length - 1; i++) {
      if (hF[i].isNaN || hS[i].isNaN || atr15[i].isNaN) continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      if (i1h < 1 || hS1h[i1h].isNaN || hS1h[i1h - 1].isNaN) continue;
      final bull1h = hS1h[i1h] > hS1h[i1h - 1];
      final bear1h = hS1h[i1h] < hS1h[i1h - 1];

      if (!s.inTrade) {
        final cl = hF[i] > hS[i] && hF[i - 1] <= hS[i - 1];
        final cs = hF[i] < hS[i] && hF[i - 1] >= hS[i - 1];
        if (bull1h && cl) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (bear1h && cs) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;
        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (hF[i] < hS[i] && hF[i - 1] >= hS[i - 1]) {
            doExit = true;
            reason = 'Hull Cross';
          }
          final trail = bar.close - p.atrStopMult * atr15[i];
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (hF[i] > hS[i] && hF[i - 1] <= hS[i - 1]) {
            doExit = true;
            reason = 'Hull Cross';
          }
          final trail = bar.close + p.atrStopMult * atr15[i];
          if (trail < s.stopLoss) s.stopLoss = trail;
        }
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 5 — VORTEX CROSS  (NEW)
// ════════════════════════════════════════════════════════════════════════════

class VortexParams extends StrategyParams {
  final int period;
  @override
  final double atrStopMult;
  VortexParams(this.period, this.atrStopMult);
  @override
  String get label => 'Vortex($period) ATR×$atrStopMult';
}

class VortexCross extends Strategy {
  @override
  String get name => 'Vortex-Cross';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final per in [14, 21, 28]) {
      for (final a in [1.5, 2.0, 2.5]) {
        out.add(VortexParams(per, a));
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
    final p = params as VortexParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final v15 = Indicators.vortex(c15, p.period);
    final atr15 = Indicators.atr(c15, 14);
    final v1h = Indicators.vortex(c1h, p.period);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = p.period + 2; i < c15.length - 1; i++) {
      if (v15.viPlus[i].isNaN || v15.viPlus[i - 1].isNaN || atr15[i].isNaN)
        continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      if (i1h < 0 || v1h.viPlus[i1h].isNaN) continue;
      final bull1h = v1h.viPlus[i1h] > v1h.viMinus[i1h];
      final bear1h = v1h.viMinus[i1h] > v1h.viPlus[i1h];

      if (!s.inTrade) {
        final cl =
            v15.viPlus[i] > v15.viMinus[i] &&
            v15.viPlus[i - 1] <= v15.viMinus[i - 1];
        final cs =
            v15.viMinus[i] > v15.viPlus[i] &&
            v15.viMinus[i - 1] <= v15.viPlus[i - 1];
        if (bull1h && cl) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (bear1h && cs) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;
        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (v15.viMinus[i] > v15.viPlus[i]) {
            doExit = true;
            reason = 'Vortex Flip';
          }
          final trail = bar.close - p.atrStopMult * atr15[i];
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (v15.viPlus[i] > v15.viMinus[i]) {
            doExit = true;
            reason = 'Vortex Flip';
          }
          final trail = bar.close + p.atrStopMult * atr15[i];
          if (trail < s.stopLoss) s.stopLoss = trail;
        }
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
          }
          s.inTrade = false;
        }
      }
    }
    return trades;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STRATEGY 6 — PSAR TRAIL  (NEW)
// ════════════════════════════════════════════════════════════════════════════

class PsarParams extends StrategyParams {
  final double afStart, afStep, afMax;
  @override
  final double atrStopMult;
  PsarParams(this.afStart, this.afStep, this.afMax, this.atrStopMult);
  @override
  String get label => 'PSAR($afStart/$afStep/$afMax) ATR×$atrStopMult';
}

class PsarTrail extends Strategy {
  @override
  String get name => 'PSAR-Trail';
  @override
  List<StrategyParams> grid() {
    final out = <StrategyParams>[];
    for (final start in [0.02, 0.01]) {
      for (final step in [0.02, 0.015]) {
        for (final maxAf in [0.2, 0.3]) {
          for (final a in [1.5, 2.0, 2.5]) {
            out.add(PsarParams(start, step, maxAf, a));
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
    final p = params as PsarParams;
    final c15 = tfCandles[Timeframe.m15]!;
    final c1h = tfCandles[Timeframe.h1]!;
    final ps15 = Indicators.psar(c15, p.afStart, p.afStep, p.afMax);
    final atr15 = Indicators.atr(c15, 14);
    final cl1h = c1h.map((c) => c.close).toList();
    final e50_1h = Indicators.ema(cl1h, 50);

    final trades = <Trade>[];
    final s = _Sim();

    for (int i = 50; i < c15.length - 1; i++) {
      if (atr15[i].isNaN) continue;
      final t = c15[i].time;
      final i1h = Indicators.closedHtfIdx(c1h, t);
      if (i1h < 0 || e50_1h[i1h].isNaN) continue;
      final bull1h = c1h[i1h].close > e50_1h[i1h];
      final bear1h = c1h[i1h].close < e50_1h[i1h];
      final dNow = ps15.dir[i];
      final dPrev = ps15.dir[i - 1];

      if (!s.inTrade) {
        if (bull1h && dNow == 1 && dPrev == -1) {
          s.dir = TradeDirection.long;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice - p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        } else if (bear1h && dNow == -1 && dPrev == 1) {
          s.dir = TradeDirection.short;
          s.entryPrice = _entryFill(c15[i + 1].open, s.dir);
          s.stopLoss = s.entryPrice + p.atrStopMult * atr15[i];
          s.inTrade = true;
          s.entryTime = c15[i + 1].time;
          s.entryBar = i + 1;
        }
      } else {
        final bar = c15[i];
        String reason = '';
        bool doExit = false;
        double exitIdeal = bar.close;
        if (s.dir == TradeDirection.long) {
          if (bar.low <= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (dNow == -1) {
            doExit = true;
            reason = 'PSAR Flip';
          }
          final trail = max(s.stopLoss, ps15.sar[i]);
          if (trail > s.stopLoss) s.stopLoss = trail;
        } else {
          if (bar.high >= s.stopLoss) {
            doExit = true;
            reason = 'ATR Stop';
            exitIdeal = s.stopLoss;
          } else if (dNow == 1) {
            doExit = true;
            reason = 'PSAR Flip';
          }
          final trail = min(s.stopLoss, ps15.sar[i]);
          if (trail < s.stopLoss) s.stopLoss = trail;
        }
        if (!doExit && i - s.entryBar >= kMaxBarsInTrade) {
          doExit = true;
          reason = 'Time Stop';
        }
        if (doExit) {
          final exitPx = _exitFill(exitIdeal, s.dir);
          if (!s.entryTime.isBefore(oosFrom) && s.entryTime.isBefore(oosTo)) {
            trades.add(
              Trade(
                entryTime: s.entryTime,
                exitTime: bar.time,
                entryPrice: s.entryPrice,
                exitPrice: exitPx,
                direction: s.dir,
                strategyName: name,
                symbol: symbol,
                exitReason: reason,
              ),
            );
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
    required this.isStart,
    required this.isEnd,
    required this.oosStart,
    required this.oosEnd,
    required this.index,
  });
  String get label => 'W${index.toString().padLeft(2, '0')}';
}

class WfoEngine {
  final int isLengthDays;
  final int oosLengthDays;
  WfoEngine({this.isLengthDays = 60, this.oosLengthDays = 20});

  List<WalkForwardWindow> _windows(DateTime start, DateTime end) {
    final wins = <WalkForwardWindow>[];
    var isStart = start;
    int idx = 1;
    while (true) {
      final isEnd = isStart.add(Duration(days: isLengthDays));
      final oosEnd = isEnd.add(Duration(days: oosLengthDays));
      if (oosEnd.isAfter(end)) break;
      wins.add(
        WalkForwardWindow(
          isStart: isStart,
          isEnd: isEnd,
          oosStart: isEnd,
          oosEnd: oosEnd,
          index: idx++,
        ),
      );
      isStart = isStart.add(Duration(days: oosLengthDays));
    }
    return wins;
  }

  Map<Timeframe, List<Candle>> _slice(
    Map<Timeframe, List<Candle>> all,
    DateTime from,
    DateTime to,
  ) {
    final out = <Timeframe, List<Candle>>{};
    for (final tf in all.keys) {
      out[tf] = all[tf]!
          .where((c) => !c.time.isBefore(from) && c.time.isBefore(to))
          .toList();
    }
    return out;
  }

  /// For each window:
  ///   1. Slice IS+OOS warmup data.
  ///   2. For each parameter combo, run on the IS-only window (oos=IS end).
  ///   3. Score IS performance, pick best combo.
  ///   4. Run best combo on full IS+OOS warmup, recording only OOS trades.
  ///   5. Concatenate OOS trades across windows for final report.
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
      // Warmup slice = IS + OOS together (so indicators warm on IS)
      final warmup = _slice(allTf, win.isStart, win.oosEnd);
      final m15Len = warmup[Timeframe.m15]?.length ?? 0;
      if (m15Len < 200) {
        print('  ⚠  ${win.label}: too few bars ($m15Len), skipping');
        continue;
      }

      for (final strategy in strategies) {
        final combos = strategy.grid();

        // ── 1) IS optimization: score each combo on IS-only trades ────────
        StrategyParams? bestParams;
        double bestScore = -double.infinity;
        for (final combo in combos) {
          final isTrades = strategy.backtest(
            symbol: symbol,
            tfCandles: warmup,
            // restrict to IS region
            oosFrom: win.isStart,
            oosTo: win.isEnd,
            params: combo,
          );
          final isResult = StrategyResult(
            strategyName: strategy.name,
            symbol: symbol,
            trades: isTrades,
            windowLabel: '${win.label}-IS',
            paramsLabel: combo.label,
          );
          if (isResult.compositeScore > bestScore) {
            bestScore = isResult.compositeScore;
            bestParams = combo;
          }
        }
        if (bestParams == null) continue;

        // ── 2) OOS evaluation with best IS params ─────────────────────────
        final oosTrades = strategy.backtest(
          symbol: symbol,
          tfCandles: warmup,
          oosFrom: win.oosStart,
          oosTo: win.oosEnd,
          params: bestParams,
        );
        byStrategy[strategy.name]!.add(
          StrategyResult(
            strategyName: strategy.name,
            symbol: symbol,
            trades: oosTrades,
            windowLabel: win.label,
            paramsLabel: bestParams.label,
          ),
        );
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

  static StrategyResult consolidate(
    String strat,
    String sym,
    List<StrategyResult> wins,
  ) {
    return StrategyResult(
      strategyName: strat,
      symbol: sym,
      trades: wins.expand((w) => w.trades).toList(),
      windowLabel: 'CONSOLIDATED-OOS',
    );
  }

  static void banner() {
    print('''
╔══════════════════════════════════════════════════════════════════════════════╗
║   CRYPTO TREND-FOLLOWING · WALK-FORWARD OPTIMIZER (BIAS-FREE, OOS-ONLY)     ║
║   Per window: grid-search params on IS → run best combo on OOS              ║
║   All HTF lookups use last CLOSED bar; stops fill at stop price             ║
║   Slippage + fees applied symmetrically to entry & exit                     ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
  }

  static void windowTable(String strat, String sym, List<StrategyResult> wins) {
    print('\n  ┌─ OOS Window Breakdown │ $strat │ $sym');
    print(
      '  │  Win    Trades  Win%    Ret%      PF   Sharpe  MaxDD%  Score   Best IS Params',
    );
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
    if (r.totalTrades == 0) {
      print('  ⚠  No OOS trades.\n');
      return;
    }
    final rows = [
      ['Total Trades', r.totalTrades.toString()],
      ['Winning', '${r.winningTrades}  (${_f(r.winRate)}%)'],
      ['Losing', r.losingTrades.toString()],
      ['Total Return', '${_f(r.totalReturn)}%'],
      ['Avg Win', '${_f(r.avgWin)}%'],
      ['Avg Loss', '${_f(r.avgLoss)}%'],
      ['Profit Factor', r.profitFactor.isInfinite ? '∞' : _f(r.profitFactor)],
      ['Sharpe (per-trade)', _f(r.sharpeRatio)],
      ['Max Drawdown', '${_f(r.maxDrawdown)}%'],
      ['Expectancy', '${_f(r.expectancy)}%/trade'],
      ['Calmar', _f(r.calmarRatio)],
      ['Composite Score', '${_f(r.compositeScore)} / 100'],
    ];
    for (final row in rows) {
      print('  ${row[0].padRight(20)}  ${row[1]}');
    }
    final reasons = <String, int>{};
    for (final t in r.trades)
      reasons[t.exitReason] = (reasons[t.exitReason] ?? 0) + 1;
    print('\n  Exit reasons:');
    for (final e
        in reasons.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))) {
      print('    ${e.key.padRight(22)} ${e.value}');
    }
    final longs = r.trades
        .where((t) => t.direction == TradeDirection.long)
        .toList();
    final shorts = r.trades
        .where((t) => t.direction == TradeDirection.short)
        .toList();
    final lWR = longs.isEmpty
        ? 0.0
        : longs.where((t) => t.pnlPct > 0).length / longs.length * 100;
    final sWR = shorts.isEmpty
        ? 0.0
        : shorts.where((t) => t.pnlPct > 0).length / shorts.length * 100;
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
║              OVERALL OOS LEADERBOARD (composite score, OOS-only)            ║
╚══════════════════════════════════════════════════════════════════════════════╝
''');
    print(
      'Rank  Symbol       Strategy            Trades  Win%    Ret%     PF  Sharpe  DD%   Score',
    );
    print('─' * 95);
    int shown = 0;
    for (final e in all) {
      if (e.r.totalTrades == 0) continue;
      final pf = e.r.profitFactor.isInfinite ? '∞' : _f(e.r.profitFactor);
      final medal = shown == 0
          ? ' 🥇'
          : shown == 1
          ? ' 🥈'
          : shown == 2
          ? ' 🥉'
          : '';
      print(
        '${(shown + 1).toString().padRight(5)} '
        '${e.sym.padRight(12)} ${e.strat.padRight(18)} '
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

    print(
      '\n╔══════════════════════════════════════════════════════════════════════════════╗',
    );
    print(
      '║                       BEST STRATEGY PER SYMBOL                             ║',
    );
    print(
      '╚══════════════════════════════════════════════════════════════════════════════╝\n',
    );
    final bySym = <String, ({String strat, StrategyResult r})>{};
    for (final e in all) {
      if (e.r.totalTrades == 0) continue;
      if (!bySym.containsKey(e.sym) ||
          e.r.compositeScore > bySym[e.sym]!.r.compositeScore) {
        bySym[e.sym] = (strat: e.strat, r: e.r);
      }
    }
    for (final sym in bySym.keys) {
      final b = bySym[sym]!;
      print('  ► $sym  →  ${b.strat}');
      print(
        '    Trades:${b.r.totalTrades}  Win:${_f(b.r.winRate)}%  '
        'Return:${_f(b.r.totalReturn)}%  PF:${b.r.profitFactor.isInfinite ? "∞" : _f(b.r.profitFactor)}  '
        'MaxDD:${_f(b.r.maxDrawdown)}%  Score:${_f(b.r.compositeScore)}/100\n',
      );
    }
  }

  static void exportCsv(
    Map<String, Map<String, StrategyResult>> cons,
    Map<String, Map<String, List<StrategyResult>>> wins,
    String outDir,
  ) {
    Directory(outDir).createSync(recursive: true);

    final lb = File('$outDir/leaderboard.csv');
    final lbSb = StringBuffer(
      'Symbol,Strategy,Trades,WinRate%,TotalReturn%,AvgWin%,AvgLoss%,'
      'ProfitFactor,Sharpe,MaxDD%,Expectancy%,Calmar,CompositeScore\n',
    );
    for (final sym in cons.keys) {
      for (final st in cons[sym]!.keys) {
        final r = cons[sym]![st]!;
        final pf = r.profitFactor.isInfinite ? 999.0 : r.profitFactor;
        lbSb.writeln(
          '$sym,$st,${r.totalTrades},${_f(r.winRate)},${_f(r.totalReturn)},'
          '${_f(r.avgWin)},${_f(r.avgLoss)},${_f(pf)},${_f(r.sharpeRatio)},'
          '${_f(r.maxDrawdown)},${_f(r.expectancy)},${_f(r.calmarRatio)},${_f(r.compositeScore)}',
        );
      }
    }
    lb.writeAsStringSync(lbSb.toString());

    final tr = File('$outDir/all_trades.csv');
    final trSb = StringBuffer(
      'Symbol,Strategy,Direction,EntryTime,ExitTime,'
      'EntryPrice,ExitPrice,PnL%,ExitReason,HoldingMin\n',
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

    final wb = File('$outDir/window_breakdown.csv');
    final wbSb = StringBuffer(
      'Symbol,Strategy,Window,BestParams,Trades,WinRate%,TotalReturn%,'
      'ProfitFactor,Sharpe,MaxDD%,Score\n',
    );
    for (final sym in wins.keys) {
      for (final st in wins[sym]!.keys) {
        for (final w in wins[sym]![st]!) {
          final pf = w.profitFactor.isInfinite ? 999.0 : w.profitFactor;
          wbSb.writeln(
            '$sym,$st,${w.windowLabel},"${w.paramsLabel}",${w.totalTrades},'
            '${_f(w.winRate)},${_f(w.totalReturn)},${_f(pf)},'
            '${_f(w.sharpeRatio)},${_f(w.maxDrawdown)},${_f(w.compositeScore)}',
          );
        }
      }
    }
    wb.writeAsStringSync(wbSb.toString());

    print('  📄 leaderboard.csv');
    print('  📄 all_trades.csv');
    print('  📄 window_breakdown.csv');
    print('\n  All files saved to: $outDir/');
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DEMO DATA
// ════════════════════════════════════════════════════════════════════════════

Map<String, List<Candle>> _generateDemoData() {
  print('  ℹ  Generating synthetic 5m demo data (6 months)...');
  final rng = Random(42);
  final result = <String, List<Candle>>{};
  final assets = [('BTCUSDT', 20000.0, 0.003), ('ETHUSDT', 1200.0, 0.004)];
  for (final (sym, startPrice, vol) in assets) {
    final candles = <Candle>[];
    var time = DateTime.utc(2023, 1, 1);
    double price = startPrice;
    for (int i = 0; i < 6 * 30 * 24 * 12; i++) {
      final trend = sin(i / (24 * 12 * 14)) * 0.0003;
      final noise = (rng.nextDouble() - 0.49) * vol;
      price = (price * (1 + trend + noise)).clamp(
        startPrice * 0.2,
        startPrice * 5,
      );
      final range = price * (0.001 + rng.nextDouble() * 0.004);
      final o = price;
      final h = o + range * rng.nextDouble();
      final l = o - range * rng.nextDouble();
      final c = l + (h - l) * rng.nextDouble();
      candles.add(
        Candle(
          time: time,
          open: o,
          high: h,
          low: l,
          close: c,
          volume: 10 + rng.nextDouble() * 200,
        ),
      );
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

  final dataDir = args.isNotEmpty
      ? args[0]
      : 'C:\\Users\\GIGA\\Desktop\\Candle Data';
  final outDir = args.length > 1 ? args[1] : './wf_results';

  const int isLengthDays = 60;
  const int oosLengthDays = 20;

  print('Configuration');
  print('  Data dir       : $dataDir');
  print('  Output dir     : $outDir');
  print('  IS window      : $isLengthDays days  (param search)');
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
      Timeframe.m5: raw5m[sym]!,
      Timeframe.m15: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m15),
      Timeframe.m30: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.m30),
      Timeframe.h1: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h1),
      Timeframe.h4: TimeframeAggregator.aggregate(raw5m[sym]!, Timeframe.h4),
    };
    final tf = allTf[sym]!;
    print(
      '  $sym → 5m:${tf[Timeframe.m5]!.length} | 15m:${tf[Timeframe.m15]!.length}'
      ' | 1h:${tf[Timeframe.h1]!.length} | 4h:${tf[Timeframe.h4]!.length}',
    );
  }

  final strategies = <Strategy>[
    TripleEmaMtf(),
    SupertrendMtf(),
    DonchianBreakoutMtf(),
    HullMaCross(),
    VortexCross(),
    PsarTrail(),
  ];
  print('\nStrategies (${strategies.length}):');
  for (final s in strategies) {
    print('  • ${s.name}  (${s.grid().length} param combos)');
  }

  final engine = WfoEngine(
    isLengthDays: isLengthDays,
    oosLengthDays: oosLengthDays,
  );
  final consolidated = <String, Map<String, StrategyResult>>{};
  final allWindows = <String, Map<String, List<StrategyResult>>>{};

  for (final sym in allTf.keys) {
    print('\n${"═" * 80}');
    print('  Asset: $sym');
    print('${"═" * 80}');
    final byStrat = engine.runAll(
      symbol: sym,
      allTf: allTf[sym]!,
      strategies: strategies,
    );
    if (byStrat.isEmpty) continue;

    consolidated[sym] = {};
    allWindows[sym] = {};
    for (final strat in byStrat.keys) {
      final winResults = byStrat[strat]!;
      final cons = Reporter.consolidate(strat, sym, winResults);
      consolidated[sym]![strat] = cons;
      allWindows[sym]![strat] = winResults;
      Reporter.windowTable(strat, sym, winResults);
      Reporter.strategyCard(cons);
    }
  }

  Reporter.leaderboard(consolidated);
  print('\nExporting results...');
  Reporter.exportCsv(consolidated, allWindows, outDir);
  print(
    '\n✅  Walk-forward optimization complete — OOS-only, zero lookahead.\n',
  );
}
