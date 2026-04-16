// =============================================================================
// ZONE REVERSAL STRATEGY — Bias-Free Backtest
// =============================================================================
// Logic: Price must physically TOUCH an SR zone, show a rejection candle,
//        have a volume spike, and have the SFI flip as the trigger.
//        This is a pure mean-reversion / reversal approach — NOT trend-following.
//
// Entry (ALL required):
//   1. Candle wick enters SR zone (c.low <= zone.boxTop for long,
//                                  c.high >= zone.boxBottom for short)
//   2. Rejection candle at zone (hammer/pin bar — always required)
//   3. Volume > volSma × volThresh (climactic volume confirming rejection)
//   4. SFI flip on entry TF (trigger)
//   5. RSI confirmation: RSI[i] < rsiLong for longs, > rsiShort for shorts
//   6. EMA 200 trend alignment (optional per-strategy)
//   7. Higher-TF trend bias (optional per-strategy)
//
// Exit:
//   TP1 — nearest zone on the opposite side of trade (or 2.5× ATR fallback)
//   SL  — just outside the touched zone edge (tight, 0.15% buffer)
//   After TP1: SL moves to entry (breakeven), trail 20% until SFI reverses.
//              Trailing exit fills at NEXT bar's open (bias-free).
//
// Bias-free guarantees:
//   • Signal detected at bar i's close → queued → fill at bar i+1's open
//   • ATR at fill = atr5[i-1] (previous bar, fully closed)
//   • Trailing exit at c.open (not c.close)
//   • SR zones: checkHist:false, break bars from past closes only
//   • RSI and volume computed on fully closed bars only
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _notional   = 100.0;
const _leverage   = 5.0;
const _dep        = _notional * _leverage;
const _commission = 0.025;
const _slippage   = 0.04;
const _funding    = 0.01;
const _cooldown   = 4;       // 5m bars = 20 min
const _slBuf      = 0.15;    // % buffer beyond zone edge for SL
const _atrFb      = 2.5;     // ATR multiplier when no opposing zone found
const _volThresh  = 1.2;     // volume must be > 1.2× the 20-bar SMA
const _zoneTol    = 0.002;   // 0.2% tolerance for zone touch detection

// SR detection lengths per TF
const _srl5  = 8;
const _srl15 = 12;
const _srl30 = 11;
const _srl45 = 10;

// SR bitmask constants
const _B5  = 1;
const _B15 = 2;
const _B30 = 4;
const _B45 = 8;

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY DEFINITION
// ─────────────────────────────────────────────────────────────────────────────

class RevStrat {
  final String name;
  final int    entryTf;   // 5, 15
  final int    trendTf;   // 0=none, 15, 30, 45
  final int    srMask;    // SR zone TFs to use
  final int    sfiP;
  final double sfiM;
  final bool   ema;       // EMA 200 trend alignment filter
  final double rsiLong;   // RSI threshold for longs  (e.g. 50 → RSI < 50)
  final double rsiShort;  // RSI threshold for shorts (e.g. 50 → RSI > 50)
  const RevStrat(this.name, this.entryTf, this.trendTf, this.srMask,
                 this.sfiP, this.sfiM, this.ema, this.rsiLong, this.rsiShort);
}

String _bitsStr(int m) {
  final p = <String>[];
  if (m & _B5  != 0) p.add('5m');
  if (m & _B15 != 0) p.add('15m');
  if (m & _B30 != 0) p.add('30m');
  if (m & _B45 != 0) p.add('45m');
  return p.join('+');
}

List<RevStrat> _genStrategies() {
  final out = <RevStrat>[];

  const pairs = <(int, int)>[
    (5, 0), (5, 15), (5, 30), (5, 45),
    (15, 0), (15, 30), (15, 45),
  ];

  const sfiConfigs = <(int, double)>[
    (7, 1.5), (10, 1.7), (14, 2.0),
  ];

  // RSI configs: (rsiLong threshold, rsiShort threshold)
  // RSI < rsiLong to enter long (price was falling into support)
  // RSI > rsiShort to enter short (price was rising into resistance)
  const rsiConfigs = <(double, double)>[
    (55, 45),  // loose — only confirms prior trend direction
    (45, 55),  // medium
    (40, 60),  // strict
  ];

  const emaOptions = [false, true];

  final tfBit = {5: _B5, 15: _B15, 30: _B30, 45: _B45};

  for (final (eTf, tTf) in pairs) {
    final srOpts = <int>[];
    srOpts.add(tfBit[eTf]!);
    if (tTf > 0) {
      srOpts.add(tfBit[tTf]!);
      srOpts.add(tfBit[eTf]! | tfBit[tTf]!);
    } else {
      if (eTf < 45) srOpts.add(_B45);
      if (eTf == 5) {
        srOpts.add(_B5 | _B30);
        srOpts.add(_B5 | _B45);
      }
    }

    for (final srMask in srOpts) {
      for (final (sP, sM) in sfiConfigs) {
        for (final (rL, rS) in rsiConfigs) {
          for (final useEma in emaOptions) {
            final tStr   = tTf > 0 ? 'T${tTf}m' : 'Tno';
            final rsiStr = 'RSI${rL.toInt()}/${rS.toInt()}';
            final emaStr = useEma ? '+EMA' : '';
            final name   = 'E${eTf}m/$tStr/SR${_bitsStr(srMask)}'
                           '/SFI${sP}x${sM.toStringAsFixed(1)}/$rsiStr$emaStr';
            out.add(RevStrat(name, eTf, tTf, srMask, sP, sM, useEma, rL, rS));
          }
        }
      }
    }
  }

  return out;
}

final _strategies = _genStrategies();

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset, strat;
  final int    trades, wins;
  final double netPnl, returnPct, maxDdPct, calmar;
  final double fees, slip, fund;
  final String grade;
  final int    entryTf, trendTf, srMask, sfiP;
  final double sfiM;

  Res({required this.asset, required this.strat,
       required this.trades, required this.wins,
       required this.netPnl, required this.returnPct,
       required this.maxDdPct, required this.calmar,
       required this.fees, required this.slip, required this.fund,
       required this.grade, required this.entryTf, required this.trendTf,
       required this.srMask, required this.sfiP, required this.sfiM});

  double get wr => trades == 0 ? 0 : wins / trades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out   = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(',');
    if (p.length < 6) continue;
    final t = DateTime.parse(p[0].trim().replaceAll(' ', 'T') + 'Z');
    out.add(Candle(t, double.parse(p[1]), double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4]), double.parse(p[5]), out.length));
  }
  return out;
}

List<Candle> _clean(List<Candle> raw, int im) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty && c.time.difference(out.last.time).inMinutes > im * 3) continue;
    out.add(Candle(c.time, c.open, c.high, c.low, c.close, c.volume, out.length));
  }
  return out;
}

List<Candle> _agg(List<Candle> c, int n) {
  final out = <Candle>[];
  for (int i = 0; i + n - 1 < c.length; i += n) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < n; j++) {
      hi  = max(hi, c[i + j].high);
      lo  = min(lo, c[i + j].low);
      vol += c[i + j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i + n - 1].close, vol, out.length));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS
// ─────────────────────────────────────────────────────────────────────────────

class SfiSig {
  final double up, dn;
  final int    trend;
  final bool   buy, sell;
  const SfiSig(this.up, this.dn, this.trend, this.buy, this.sell);
}

List<SfiSig> _sfi(List<Candle> cs, int p, double m) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT = 1;
  final out = <SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i - 1].close > pUp ? max(cs[i].ohlc4 - m * a, pUp) : cs[i].ohlc4 - m * a)
        : cs[i].ohlc4 - m * a;
    final dn = i > 0
        ? (cs[i - 1].close < pDn ? min(cs[i].ohlc4 + m * a, pDn) : cs[i].ohlc4 + m * a)
        : cs[i].ohlc4 + m * a;
    int t = prevT;
    if (prevT == -1 && cs[i].close > pDn) t = 1;
    else if (prevT == 1 && cs[i].close < pUp) t = -1;
    out.add(SfiSig(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

List<double> _atrList(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  return atr;
}

List<double> _ema(List<Candle> cs, int p) {
  final k   = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i - 1] * (1 - k));
  }
  return out;
}

List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  double sum = 0;
  for (int i = 0; i < cs.length; i++) {
    sum += cs[i].volume;
    if (i >= p) sum -= cs[i - p].volume;
    out.add(sum / (i < p ? i + 1 : p));
  }
  return out;
}

/// Wilder-smoothed RSI.  Returns values in 0–100.
List<double> _rsi(List<Candle> cs, int p) {
  final out = <double>[];
  double ag = 0, al = 0;
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(50); continue; }
    final d = cs[i].close - cs[i - 1].close;
    final g = d > 0 ? d : 0.0;
    final l = d < 0 ? -d : 0.0;
    if (i <= p) {
      ag = (ag * (i - 1) + g) / i;
      al = (al * (i - 1) + l) / i;
    } else {
      ag = (ag * (p - 1) + g) / p;
      al = (al * (p - 1) + l) / p;
    }
    final rs = al == 0 ? 100.0 : ag / al;
    out.add(100 - 100 / (1 + rs));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR HELPERS  — BIAS-FREE
// ─────────────────────────────────────────────────────────────────────────────

List<int?> computeBreakBars(List<SRZone> zones, List<Candle> candles, int srLen) {
  final out = List<int?>.filled(zones.length, null);
  for (int zi = 0; zi < zones.length; zi++) {
    final z    = zones[zi];
    final from = z.boxLeft + srLen;
    for (int b = from; b < candles.length; b++) {
      if (z.isResistance) {
        if (candles[b].close > z.boxTop)    { out[zi] = b; break; }
      } else {
        if (candles[b].close < z.boxBottom) { out[zi] = b; break; }
      }
    }
  }
  return out;
}

List<SRZone> _knSup(List<SRZone> z, List<int?> bb, int bar, int len) {
  final out = <SRZone>[];
  for (int i = 0; i < z.length; i++) {
    if (!z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) out.add(z[i]);
  }
  return out;
}

List<SRZone> _knRes(List<SRZone> z, List<int?> bb, int bar, int len) {
  final out = <SRZone>[];
  for (int i = 0; i < z.length; i++) {
    if (z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) out.add(z[i]);
  }
  return out;
}

/// Nearest support zone AT OR BELOW price p.
SRZone? _nSup(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) {
    if (s.boxTop > p * 1.005) continue;
    final d = p - s.boxTop;
    if (d < bd) { bd = d; best = s; }
  }
  return best;
}

/// Nearest resistance zone AT OR ABOVE price p.
SRZone? _nRes(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) {
    if (s.boxBottom < p * 0.995) continue;
    final d = s.boxBottom - p;
    if (d < bd) { bd = d; best = s; }
  }
  return best;
}

/// True if candle wick ENTERED a support zone from above (reversal setup).
/// Requires: wick touched the zone AND close is inside or above zone.
bool _touchedSup(SRZone z, Candle c) {
  final inZone = c.low <= z.boxTop * (1 + _zoneTol);
  final closedOk = c.close >= z.boxBottom * (1 - _zoneTol);
  return inZone && closedOk;
}

/// True if candle wick ENTERED a resistance zone from below (reversal setup).
bool _touchedRes(SRZone z, Candle c) {
  final inZone  = c.high >= z.boxBottom * (1 - _zoneTol);
  final closedOk = c.close <= z.boxTop * (1 + _zoneTol);
  return inZone && closedOk;
}

/// Rejection candle for a long (hammer / bullish pin bar).
/// Lower wick >= 1.5× body AND close in upper half of range.
bool _rejLong(Candle c) {
  final body  = (c.close - c.open).abs();
  final lWick = min(c.open, c.close) - c.low;
  final total = c.high - c.low;
  if (total <= 0) return false;
  return lWick >= body * 1.5 && c.close >= c.low + total * 0.5;
}

/// Rejection candle for a short (shooting star / bearish pin bar).
/// Upper wick >= 1.5× body AND close in lower half of range.
bool _rejShort(Candle c) {
  final body  = (c.close - c.open).abs();
  final uWick = c.high - max(c.open, c.close);
  final total = c.high - c.low;
  if (total <= 0) return false;
  return uWick >= body * 1.5 && c.close <= c.high - total * 0.5;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE
// ─────────────────────────────────────────────────────────────────────────────

class _T {
  final int    dir;
  final double entry, qty, tp1;
  double sl;           // mutable — moved to breakeven after TP1
  bool   tp1Hit = false;
  double tp1P = 0, exitP = 0;
  String reason = '';
  double fee = 0, slp = 0, fund = 0, pnl = 0;
  bool get open => reason.isEmpty;
  _T({required this.dir, required this.entry,
      required this.qty, required this.tp1, required this.sl});
}

// ─────────────────────────────────────────────────────────────────────────────
// PRECOMPUTED PER-ASSET DATA
// ─────────────────────────────────────────────────────────────────────────────

class AssetData {
  final String sym;
  final List<Candle> c5, c15, c30, c45;
  final Map<String, List<SfiSig>> sfi5Map, sfi15Map, sfi30Map, sfi45Map;
  final Map<String, List<double>> rsi5Map, rsi15Map;
  final List<double> atr5, ema200_45, volSma5;
  final List<SRZone> zones5, zones15, zones30, zones45;
  final List<int?> bb5, bb15, bb30, bb45;

  AssetData({
    required this.sym,
    required this.c5, required this.c15, required this.c30, required this.c45,
    required this.sfi5Map, required this.sfi15Map,
    required this.sfi30Map, required this.sfi45Map,
    required this.rsi5Map, required this.rsi15Map,
    required this.atr5, required this.ema200_45, required this.volSma5,
    required this.zones5, required this.zones15,
    required this.zones30, required this.zones45,
    required this.bb5, required this.bb15,
    required this.bb30, required this.bb45,
  });

  List<SfiSig> sfi5(int p, double m)  => sfi5Map['${p}_$m']!;
  List<SfiSig> sfi15(int p, double m) => sfi15Map['${p}_$m']!;
  List<SfiSig> sfi30(int p, double m) => sfi30Map['${p}_$m']!;
  List<SfiSig> sfi45(int p, double m) => sfi45Map['${p}_$m']!;
  List<double> rsi5(int p, double m)  => rsi5Map['${p}_$m']!;
  List<double> rsi15(int p, double m) => rsi15Map['${p}_$m']!;
}

AssetData _loadAsset(String sym, String path) {
  final c5  = _clean(_loadCsv(path), 5);
  final c15 = _agg(c5, 3);
  final c30 = _agg(c5, 6);
  final c45 = _agg(c5, 9);

  const sfiConfigs = [(7, 1.5), (10, 1.7), (14, 2.0)];
  final sfi5m  = <String, List<SfiSig>>{};
  final sfi15m = <String, List<SfiSig>>{};
  final sfi30m = <String, List<SfiSig>>{};
  final sfi45m = <String, List<SfiSig>>{};
  final rsi5m  = <String, List<double>>{};
  final rsi15m = <String, List<double>>{};

  for (final (p, m) in sfiConfigs) {
    final key = '${p}_$m';
    sfi5m[key]  = _sfi(c5,  p, m);
    sfi15m[key] = _sfi(c15, p, m);
    sfi30m[key] = _sfi(c30, p, m);
    sfi45m[key] = _sfi(c45, p, m);
    rsi5m[key]  = _rsi(c5,  14);   // RSI period always 14
    rsi15m[key] = _rsi(c15, 14);
  }

  final atr5   = _atrList(c5, 14);
  final ema200 = _ema(c45, 200);
  final volSma = _volSma(c5, 20);

  List<SRZone> _zones(List<Candle> cs, int len) {
    final sr = SupportResistanceIndicator(
        detectionLength: len, srMargin: 2.0, avoidFBO: true, checkHist: false);
    final r = sr.calculate(cs);
    return [...r.support, ...r.resistance];
  }

  final z5  = _zones(c5,  _srl5);
  final z15 = _zones(c15, _srl15);
  final z30 = _zones(c30, _srl30);
  final z45 = _zones(c45, _srl45);

  final bbs5  = computeBreakBars(z5,  c5,  _srl5);
  final bbs15 = computeBreakBars(z15, c15, _srl15);
  final bbs30 = computeBreakBars(z30, c30, _srl30);
  final bbs45 = computeBreakBars(z45, c45, _srl45);

  return AssetData(
    sym: sym, c5: c5, c15: c15, c30: c30, c45: c45,
    sfi5Map: sfi5m, sfi15Map: sfi15m, sfi30Map: sfi30m, sfi45Map: sfi45m,
    rsi5Map: rsi5m, rsi15Map: rsi15m,
    atr5: atr5, ema200_45: ema200, volSma5: volSma,
    zones5: z5, zones15: z15, zones30: z30, zones45: z45,
    bb5: bbs5, bb15: bbs15, bb30: bbs30, bb45: bbs45,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTEST ENGINE
// ─────────────────────────────────────────────────────────────────────────────

Res _run(AssetData d, RevStrat s) {
  final c5    = d.c5;
  final c15   = d.c15;
  final sfi5  = d.sfi5(s.sfiP, s.sfiM);
  final sfi15 = d.sfi15(s.sfiP, s.sfiM);
  final sfi30 = d.sfi30(s.sfiP, s.sfiM);
  final sfi45 = d.sfi45(s.sfiP, s.sfiM);
  final rsi5  = d.rsi5(s.sfiP, s.sfiM);
  final rsi15 = d.rsi15(s.sfiP, s.sfiM);
  final atr5    = d.atr5;
  final ema45   = d.ema200_45;
  final volSma5 = d.volSma5;

  double netEq = 0, grossEq = 0, totFee = 0, totSlp = 0, totFund = 0;
  double peak = 0, maxDd = 0;
  int wins = 0, tradeCount = 0, cd = 0;
  _T? active;
  bool pendL = false, pendS = false;
  DateTime lastFund = DateTime(2000);

  // Store the touched zone for each pending so we can set SL precisely at fill
  SRZone? pendZone;

  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i15 = i ~/ 3;
    final i30 = i ~/ 6;
    final i45 = i ~/ 9;

    // ── Lazy zone computation ─────────────────────────────────────────────
    List<SRZone>? allSup, allRes;
    List<SRZone> getSup() {
      if (allSup != null) return allSup!;
      allSup = <SRZone>[];
      if (s.srMask & _B5  != 0) allSup!.addAll(_knSup(d.zones5,  d.bb5,  i,   _srl5));
      if (s.srMask & _B15 != 0) allSup!.addAll(_knSup(d.zones15, d.bb15, i15, _srl15));
      if (s.srMask & _B30 != 0) allSup!.addAll(_knSup(d.zones30, d.bb30, i30, _srl30));
      if (s.srMask & _B45 != 0) allSup!.addAll(_knSup(d.zones45, d.bb45, i45, _srl45));
      return allSup!;
    }
    List<SRZone> getRes() {
      if (allRes != null) return allRes!;
      allRes = <SRZone>[];
      if (s.srMask & _B5  != 0) allRes!.addAll(_knRes(d.zones5,  d.bb5,  i,   _srl5));
      if (s.srMask & _B15 != 0) allRes!.addAll(_knRes(d.zones15, d.bb15, i15, _srl15));
      if (s.srMask & _B30 != 0) allRes!.addAll(_knRes(d.zones30, d.bb30, i30, _srl30));
      if (s.srMask & _B45 != 0) allRes!.addAll(_knRes(d.zones45, d.bb45, i45, _srl45));
      return allRes!;
    }

    // ── Fill pending at this bar's open (signal queued last bar) ──────────
    if (active == null && cd == 0 && (pendL || pendS)) {
      final dir  = pendL ? 1 : -1;
      final fill = c.open;
      final atr  = atr5[i - 1];

      // SL: just outside the touched zone edge (tight)
      // TP: nearest zone on the opposite side
      double slP, tp1P;
      final pz = pendZone;
      if (dir == 1) {
        slP  = pz != null
            ? pz.boxBottom * (1 - _slBuf / 100)
            : fill - _atrFb * atr;
        final res = _nRes(getRes(), fill);
        tp1P = res != null ? res.boxBottom : fill + _atrFb * atr;
      } else {
        slP  = pz != null
            ? pz.boxTop * (1 + _slBuf / 100)
            : fill + _atrFb * atr;
        final sup = _nSup(getSup(), fill);
        tp1P = sup != null ? sup.boxTop : fill - _atrFb * atr;
      }

      pendL = pendS = false;
      pendZone = null;

      final validL = dir == 1  && tp1P > fill && fill > slP;
      final validS = dir == -1 && tp1P < fill && fill < slP;

      if (validL || validS) {
        final rr = (tp1P - fill).abs() / (fill - slP).abs();
        if (rr >= 1.0) {  // minimum 1:1 RR required
          final t  = _T(dir: dir, entry: fill, qty: _dep / fill, tp1: tp1P, sl: slP);
          final ef = _dep * _commission / 100;
          final es = _dep * _slippage   / 100;
          t.fee += ef; t.slp += es; totFee += ef; totSlp += es;
          active = t;
          tradeCount++;
        }
      }
    } else if (active == null && (pendL || pendS) && cd > 0) {
      pendL = pendS = false;
      pendZone = null;
    }

    // ── Queue signal: detect reversal setup at bar i's close ──────────────
    bool buyFlip = false, sellFlip = false;
    SRZone? touchedZone;

    if (active == null && cd == 0 && !pendL && !pendS) {
      // Step 1: SFI flip (trigger)
      if (s.entryTf == 5) {
        buyFlip  = sfi5[i].buy;
        sellFlip = sfi5[i].sell;
      } else if (s.entryTf == 15 && i % 3 == 2 && i15 < sfi15.length) {
        buyFlip  = sfi15[i15].buy;
        sellFlip = sfi15[i15].sell;
      }

      if (buyFlip || sellFlip) {
        // Step 2: Higher-TF trend bias filter (previous completed bar)
        if (s.trendTf > 0) {
          int trend = 0;
          if      (s.trendTf == 15 && i15 > 0) trend = sfi15[i15 - 1].trend;
          else if (s.trendTf == 30 && i30 > 0) trend = sfi30[i30 - 1].trend;
          else if (s.trendTf == 45 && i45 > 0) trend = sfi45[i45 - 1].trend;
          if (trend < 0) buyFlip  = false;
          if (trend > 0) sellFlip = false;
        }
      }

      if (buyFlip || sellFlip) {
        // Step 3: EMA 200 filter (previous 45m bar value)
        if (s.ema && i45 > 0 && i45 - 1 < ema45.length) {
          final ema = ema45[i45 - 1];
          if (buyFlip  && c.close < ema) buyFlip  = false;
          if (sellFlip && c.close > ema) sellFlip = false;
        }
      }

      if (buyFlip || sellFlip) {
        // Step 4: RSI confirmation — price must have been trending INTO the zone
        // Long: RSI < rsiLong (price was falling → into support)
        // Short: RSI > rsiShort (price was rising → into resistance)
        final rsi = s.entryTf == 5 ? rsi5[i] : (i15 < rsi15.length ? rsi15[i15] : 50.0);
        if (buyFlip  && rsi >= s.rsiLong)  buyFlip  = false;
        if (sellFlip && rsi <= s.rsiShort) sellFlip = false;
      }

      if (buyFlip || sellFlip) {
        // Step 5: Zone TOUCH — candle wick must have entered an SR zone
        if (buyFlip) {
          SRZone? tz;
          for (final z in getSup()) {
            if (_touchedSup(z, c)) { tz = z; break; }
          }
          if (tz == null) buyFlip = false;
          else touchedZone = tz;
        }
        if (sellFlip) {
          SRZone? tz;
          for (final z in getRes()) {
            if (_touchedRes(z, c)) { tz = z; break; }
          }
          if (tz == null) sellFlip = false;
          else touchedZone = tz;
        }
      }

      if (buyFlip || sellFlip) {
        // Step 6: Rejection candle (required — this IS a reversal strategy)
        final flipBar = s.entryTf == 5 ? c : (i15 < c15.length ? c15[i15] : c);
        if (buyFlip  && !_rejLong(flipBar))  buyFlip  = false;
        if (sellFlip && !_rejShort(flipBar)) sellFlip = false;
      }

      if (buyFlip || sellFlip) {
        // Step 7: Volume spike — climactic volume confirms the zone rejection
        if (i < volSma5.length && c.volume <= volSma5[i] * _volThresh) {
          buyFlip = sellFlip = false;
        }
      }

      // Queue if all conditions passed
      if (buyFlip)  { pendL = true;  pendZone = touchedZone; }
      if (sellFlip) { pendS = true;  pendZone = touchedZone; }
    }

    // ── Funding ───────────────────────────────────────────────────────────
    if (active != null && active!.open && c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final f  = _dep * _funding / 100;
      active!.fund += f; totFund += f;
    }

    // ── TP / SL ───────────────────────────────────────────────────────────
    if (active != null && active!.open) {
      final t   = active!;
      const sp  = 0.8;
      final tpH = t.dir == 1 ? c.high >= t.tp1 : c.low  <= t.tp1;
      final slH = t.dir == 1 ? c.low  <= t.sl  : c.high >= t.sl;

      if (slH) {
        final rem = t.tp1Hit ? (1 - sp) : 1.0;
        final gp  = t.dir == 1
            ? (t.sl - t.entry) / t.entry * _dep * rem
            : (t.entry - t.sl) / t.entry * _dep * rem;
        final xf = _dep * rem * _commission / 100;
        final xs = _dep * rem * _slippage   / 100;
        t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
        grossEq += gp;
        netEq   += gp - xf - xs - t.fund;
        t.exitP  = t.sl;
        t.reason = t.tp1Hit ? 'TP1+SL' : 'SL';
        t.pnl    = (t.tp1Hit
            ? (t.dir==1?(t.tp1P-t.entry)/t.entry*_dep*sp:(t.entry-t.tp1P)/t.entry*_dep*sp)
            : 0.0) + gp - t.fee - t.slp - t.fund;
        if (t.pnl > 0) wins++;
        cd = _cooldown; active = null;

      } else if (!t.tp1Hit && tpH) {
        t.tp1Hit = true;
        t.tp1P   = t.tp1;
        t.sl     = t.entry;  // breakeven SL — trailing 20% cannot lose
        final gp80 = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * _dep * sp
            : (t.entry - t.tp1) / t.entry * _dep * sp;
        final xf = _dep * sp * _commission / 100;
        final xs = _dep * sp * _slippage   / 100;
        t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
        grossEq += gp80; netEq += gp80 - xf - xs;

      } else if (t.tp1Hit) {
        // Trail 20% until SFI on entry TF reverses; exit at next bar's open
        bool reversed = false;
        if (s.entryTf == 5)
          reversed = t.dir == 1 ? sfi5[i > 0 ? i-1 : 0].sell : sfi5[i > 0 ? i-1 : 0].buy;
        else
          reversed = t.dir == 1 ? (i15 > 0 && sfi15[i15-1].sell) : (i15 > 0 && sfi15[i15-1].buy);

        if (reversed) {
          final rem  = 1 - sp;
          final gp20 = t.dir == 1
              ? (c.open - t.entry) / t.entry * _dep * rem
              : (t.entry - c.open) / t.entry * _dep * rem;
          final xf = _dep * rem * _commission / 100;
          final xs = _dep * rem * _slippage   / 100;
          t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
          grossEq += gp20;
          netEq   += gp20 - xf - xs - t.fund;
          t.exitP  = c.open;
          t.reason = 'TP1+FLIP';
          t.pnl    = (t.dir==1?(t.tp1P-t.entry)/t.entry*_dep*sp:(t.entry-t.tp1P)/t.entry*_dep*sp)
              + gp20 - t.fee - t.slp - t.fund;
          if (t.pnl > 0) wins++;
          active = null;
        }
      }
    }

    // ── Drawdown tracking ─────────────────────────────────────────────────
    if (active != null && active!.open) {
      final t   = active!;
      final rem = t.tp1Hit ? 0.2 : 1.0;
      final op  = t.dir == 1
          ? (c.close - t.entry) / t.entry * _dep * rem
          : (t.entry - c.close) / t.entry * _dep * rem;
      final cur = netEq + op - t.fee - t.slp - t.fund;
      if (cur > peak) peak = cur;
      if (peak - cur > maxDd) maxDd = peak - cur;
    } else {
      if (netEq > peak) peak = netEq;
      if (peak - netEq > maxDd) maxDd = peak - netEq;
    }

    if (cd > 0) cd--;
  }

  // ── Force-close at end ────────────────────────────────────────────────────
  if (active != null && active!.open) {
    final t   = active!;
    final rem = t.tp1Hit ? 0.2 : 1.0;
    final ep  = c5.last.close;
    final gp  = t.dir == 1
        ? (ep - t.entry) / t.entry * _dep * rem
        : (t.entry - ep) / t.entry * _dep * rem;
    final xf  = _dep * rem * _commission / 100;
    final xs  = _dep * rem * _slippage   / 100;
    t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
    grossEq += gp; netEq += gp - xf - xs - t.fund;
    if (gp - xf - xs - t.fund > 0) wins++;
    tradeCount++;
  }

  final retPct = _dep > 0 ? netEq / _dep * 100 : 0.0;
  final ddPct  = _dep > 0 ? maxDd  / _dep * 100 : 0.0;
  final calmar = ddPct.abs() > 0 ? retPct / ddPct.abs() : (retPct > 0 ? 99.0 : 0.0);
  final grade  = calmar >= 5 && retPct >= 50 ? 'A★★★'
               : calmar >= 3 && retPct >= 30 ? 'B★★'
               : calmar >= 1 && retPct >= 10 ? 'C★'
               : netEq > 0                   ? 'D'
               : 'F';

  return Res(
    asset: d.sym, strat: s.name, trades: tradeCount, wins: wins,
    netPnl: netEq, returnPct: retPct, maxDdPct: ddPct.abs(), calmar: calmar,
    fees: totFee, slip: totSlp, fund: totFund, grade: grade,
    entryTf: s.entryTf, trendTf: s.trendTf, srMask: s.srMask,
    sfiP: s.sfiP, sfiM: s.sfiM,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  const base = '/Users/ayush/Desktop/candlestick data/5m';

  final assetFiles = [
    'SOLUSDT', 'XRPUSDT', 'TRBUSDT', 'BTCUSDT', 'ETHUSDT',
    'DOGEUSDT', 'BNBUSDT', 'ADAUSDT', 'APTUSDT', 'BCHUSDT',
    'CFXUSDT', 'ENAUSDT', 'HBARUSDT', 'ICPUSDT', 'LTCUSDT',
    'SUIUSDT', 'TRXUSDT', 'XMRUSDT', 'QNTUSDT',
  ];
  final assetSet = assetFiles.toSet().toList();

  print('═' * 100);
  print(' ZONE REVERSAL STRATEGY — ${_strategies.length} configs × ${assetSet.length} assets'
        ' = ${_strategies.length * assetSet.length} backtests');
  print(' Logic: Zone touch + Rejection candle + Volume spike + SFI flip + RSI');
  print('═' * 100);

  final allRes = <Res>[];

  for (final sym in assetSet) {
    final path = '$base/${sym}5m.csv';
    if (!File(path).existsSync()) { print('  SKIP $sym (no file)'); continue; }
    final d = _loadAsset(sym, path);
    stdout.write('  $sym (${d.c5.length} bars) .');

    int done = 0;
    for (final strat in _strategies) {
      allRes.add(_run(d, strat));
      done++;
      if (done % 100 == 0) stdout.write('.');
    }
    print(' done');
  }

  // ── MASTER LEADERBOARD ───────────────────────────────────────────────────
  final profitable = allRes.where((r) => r.netPnl > 0 && r.trades >= 10).toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));
  final total     = allRes.length;
  final profCount = profitable.length;

  print('\n');
  _hdr('MASTER LEADERBOARD — Top 60 by Calmar  '
       '(profitable + ≥10 trades, $profCount/$total = '
       '${(profCount/total*100).toStringAsFixed(1)}% qualify)');
  _tblHdr();
  for (int i = 0; i < profitable.length && i < 60; i++) {
    _tblRow(profitable[i], rank: i + 1);
  }
  _tblFoot();

  // ── BEST STRATEGY DEEP-DIVE ───────────────────────────────────────────────
  if (profitable.isNotEmpty) {
    final best = profitable.first;
    print('\n');
    _hdr('BEST REVERSAL STRATEGY — FULL BREAKDOWN');
    print('  Asset      : ${best.asset}');
    print('  Strategy   : ${best.strat}');
    print('  Entry TF   : ${best.entryTf}m');
    print('  Trend TF   : ${best.trendTf == 0 ? 'None' : '${best.trendTf}m'}');
    print('  SR Zones   : ${_bitsStr(best.srMask)}');
    print('  SFI Config : ${best.sfiP} × ${best.sfiM}');
    print('');
    print('  Trades     : ${best.trades}');
    print('  Win Rate   : ${best.wr.toStringAsFixed(1)}%');
    print('  Net Return : ${best.returnPct >= 0 ? '+' : ''}${best.returnPct.toStringAsFixed(1)}%'
          '  (on \$${_dep.toStringAsFixed(0)} notional)');
    print('  Max DD     : ${best.maxDdPct.toStringAsFixed(1)}%');
    print('  Calmar     : ${best.calmar.toStringAsFixed(2)}');
    print('  Grade      : ${best.grade}');
    print('  Costs      : fees \$${best.fees.toStringAsFixed(2)}'
          '  slip \$${best.slip.toStringAsFixed(2)}'
          '  fund \$${best.fund.toStringAsFixed(2)}');
    print('');
    print('  ─ Setup requirements ─────────────────────────────────────────');
    print('  • Price wick must TOUCH the SR zone (not just be nearby)');
    print('  • Rejection candle (hammer/pin bar) at the zone');
    print('  • Volume > ${(_volThresh * 100).toStringAsFixed(0)}% of 20-bar average');
    print('  • SFI(${best.sfiP}, ${best.sfiM}) flip on ${best.entryTf}m chart');
    print('  • RSI 14 confirmation at entry signal bar');
    print('  • Fill at next bar\'s open (no same-bar fill)');
    print('  • SL: ${_slBuf}% beyond touched zone edge');
    print('  • After TP1: SL moves to breakeven (80% locked in)');
    print('  • Trailing 20% exits at SFI reversal (next bar open)');
  }

  // ── ENTRY TF ANALYSIS ────────────────────────────────────────────────────
  print('\n');
  _hdr('ENTRY TIMEFRAME ANALYSIS');
  print('${'Entry TF'.padRight(10)} │ Qualify% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final eTf in [5, 15]) {
    final rs = profitable.where((r) => r.entryTf == eTf).toList();
    _tfLine('E${eTf}m', rs);
  }

  // ── TREND TF ANALYSIS ────────────────────────────────────────────────────
  print('\n');
  _hdr('TREND FILTER ANALYSIS');
  print('${'Trend TF'.padRight(10)} │ Qualify% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final tTf in [0, 15, 30, 45]) {
    final rs = profitable.where((r) => r.trendTf == tTf).toList();
    _tfLine(tTf == 0 ? 'NoTrend' : 'T${tTf}m', rs);
  }

  // ── SR TF ANALYSIS ────────────────────────────────────────────────────────
  print('\n');
  _hdr('SR ZONES TF ANALYSIS');
  print('${'SR Config'.padRight(12)} │ Qualify% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final mask in [
    _B5, _B15, _B30, _B45,
    _B5|_B15, _B5|_B30, _B5|_B45,
    _B15|_B30, _B15|_B45,
  ]) {
    final rs = profitable.where((r) => r.srMask == mask).toList();
    if (rs.isEmpty) continue;
    _tfLine('SR${_bitsStr(mask)}', rs);
  }

  // ── SFI CONFIG ANALYSIS ───────────────────────────────────────────────────
  print('\n');
  _hdr('SFI CONFIGURATION ANALYSIS');
  print('${'SFI Config'.padRight(12)} │ Qualify% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final (p, m) in [(7, 1.5), (10, 1.7), (14, 2.0)]) {
    final rs = profitable.where((r) => r.sfiP == p && r.sfiM == m).toList();
    _tfLine('${p}×${m.toStringAsFixed(1)}', rs);
  }

  // ── TOP 10 PER ASSET ─────────────────────────────────────────────────────
  print('\n');
  _hdr('TOP STRATEGY PER ASSET (best Calmar)');
  _tblHdr();
  final assetBest = <String, Res>{};
  for (final r in profitable) {
    if (!assetBest.containsKey(r.asset) ||
        r.calmar > assetBest[r.asset]!.calmar) {
      assetBest[r.asset] = r;
    }
  }
  final sortedBest = assetBest.values.toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));
  for (int i = 0; i < sortedBest.length; i++) {
    _tblRow(sortedBest[i], rank: i + 1);
  }
  _tblFoot();

  // ── GRADE SUMMARY ─────────────────────────────────────────────────────────
  print('\n');
  _hdr('GRADE SUMMARY (profitable + ≥10 trades)');
  for (final g in ['A★★★', 'B★★', 'C★', 'D']) {
    final rs = profitable.where((r) => r.grade == g).toList();
    if (rs.isEmpty) continue;
    final avgC = rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
    print('  $g  ${rs.length.toString().padLeft(4)} strategies'
          '  avg Calmar ${avgC.toStringAsFixed(2)}');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  const w = 100;
  final p = max(0, (w - t.length - 2) ~/ 2);
  print('═' * p + ' $t ' + '═' * max(0, w - p - t.length - 2));
}

void _tblHdr() {
  print('  # │ Asset     │ Strategy'
        '${' ' * 47}│  Trd │   WR% │  Ret% │  DD% │ Calmar │ Grade');
  print('─' * 125);
}

void _tblRow(Res r, {int? rank}) {
  final rk = rank != null ? rank.toString().padLeft(3) : '   ';
  final sn = r.strat.length > 51 ? r.strat.substring(0, 48) + '...' : r.strat;
  print('$rk │ ${r.asset.padRight(9)} │ ${sn.padRight(51)}'
        '│ ${r.trades.toString().padLeft(4)} │'
        ' ${r.wr.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.returnPct >= 0 ? '+' : ''}${r.returnPct.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.maxDdPct.toStringAsFixed(1).padLeft(4)}% │'
        ' ${r.calmar.toStringAsFixed(2).padLeft(6)} │ ${r.grade}');
}

void _tblFoot() => print('─' * 125);

void _tfLine(String label, List<Res> rs) {
  if (rs.isEmpty) { print('${label.padRight(10)} │  (no results)'); return; }
  final avgC  = rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
  final bestC = rs.map((r) => r.calmar).reduce(max);
  final aG    = rs.where((r) => r.grade == 'A★★★').length;
  final bG    = rs.where((r) => r.grade == 'B★★').length;
  final cG    = rs.where((r) => r.grade == 'C★').length;
  print('${label.padRight(10)} │ ${rs.length.toString().padLeft(6)}   │'
        ' ${avgC.toStringAsFixed(2).padLeft(9)} │'
        ' ${bestC.toStringAsFixed(2).padLeft(10)} │ $aG    $bG    $cG');
}
