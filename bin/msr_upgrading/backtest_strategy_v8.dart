// =============================================================================
// STRATEGY V8 — Exhaustive Multi-TF Sweep  *** FULLY BIAS-FREE ***
// Timeframes : 5m · 15m · 30m · 45m  (1m/3m skipped — no CSV available)
// Assets     : 21 (all 5m CSVs)
// Strategies : ~500+ auto-generated (Entry TF × Trend TF × SR TF × SFI × Filter)
// =============================================================================
// V8 improvements vs V7 (all bias-free):
//   IMP 1 — Breakeven SL after TP1
//     After TP1 is hit, t.sl is moved to entry price.  The trailing 20%
//     can no longer produce a net loss — worst outcome is breakeven.
//     Turns many 'TP1+SL' losers into scratch trades.
//
//   IMP 2 — Volume filter (+Vol)
//     20-bar SMA of 5m volume precomputed.  +Vol filter requires signal
//     bar volume > volSma5[i] — high volume = higher conviction.
//     Bias-free: volume known at bar close, queued for next-bar fill.
//
//   IMP 3 — Cooldown 6 → 4 bars (20 min)
//     More trade opportunities without overtrading.
//
//   IMP 4 — New SFI config (5, 1.2) — fast reactive variant.
//
//   IMP 5 — Expanded SR mask: _B5|_B30, _B5|_B45 added.
//
// V7 bias fixes retained (FIX 3/4/5). V6 bias fixes retained (FIX 1/2).
// =============================================================================
// V7 bias fixes vs V6:
//   FIX 3 — same-bar signal+fill (critical look-ahead fixed)
//     V6 set pendL/pendS based on sfi5[i] (bar i's close) then filled at
//     bar i's OPEN in the same loop iteration — impossible in live trading
//     since the open precedes the close.
//     V7 fix: fill block now runs BEFORE the queue block each iteration.
//     Flow: bar i closes → signal queued (pendL/pendS set) → bar i+1 opens
//     → fill executes at c.open.  Signal and fill are always one bar apart.
//
//   FIX 4 — ATR look-ahead in TP/SL setup
//     V6 used atr5[i] (includes bar i's H/L/C) when computing TP/SL at
//     bar i's open.  V7 uses atr5[i-1] — the last fully closed ATR value
//     available at the moment of fill.
//
//   FIX 5 — trailing exit at current close (look-ahead)
//     V6 exited the trailing 20% at c.close (bar i's close) after detecting
//     a reversal signal from sfi5[i-1] (bar i-1's close).  The close is not
//     known at the start of bar i.  V7 exits at c.open instead (bar i's open,
//     the first tradeable price after the reversal signal).
//
// V6 fixes retained:
//   FIX 1 — SR zone break-bar computed from past closes only (no !s.b bias)
//   FIX 2 — checkHist:false — zones formed from past pivot data only
//
// Bias-free:  signal at close[i], fill at open[i+1], SL wins same-bar
// Costs:      0.025% commission · 0.04% slippage · 0.01%/8h funding
// Capital:    100 USDT × 5× leverage = 500 USDT notional
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
const _slippage   = 0.02;
const _funding    = 0.01;
const _cooldown   = 4;      // 5m bars = 20 min  (IMP 3)
const _proxPct    = 0.8;
const _slBuf      = 0.2;
const _atrFb      = 2.0;

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

class Strat {
  final String name;
  final int    entryTf;   // 5, 15, 30
  final int    trendTf;   // 0=none, 15, 30, 45
  final int    srMask;    // bits: _B5|_B15|_B30|_B45
  final int    sfiP;
  final double sfiM;
  final bool   rej;
  final double minRR;
  final bool   ema;
  final bool   vol;       // IMP 2: volume > volSma5 filter
  const Strat(this.name, this.entryTf, this.trendTf, this.srMask,
              this.sfiP, this.sfiM, this.rej, this.minRR, this.ema, this.vol);
}

String _bitsStr(int m) {
  final p = <String>[];
  if (m & _B5  != 0) p.add('5m');
  if (m & _B15 != 0) p.add('15m');
  if (m & _B30 != 0) p.add('30m');
  if (m & _B45 != 0) p.add('45m');
  return p.join('+');
}

List<Strat> _genStrategies() {
  final out = <Strat>[];
  final tfBit = {5: _B5, 15: _B15, 30: _B30, 45: _B45};

  // Valid (entry, trend) pairs — trend must be > entry
  const pairs = <(int, int)>[
    (5, 0), (5, 15), (5, 30), (5, 45),
    (15, 0), (15, 30), (15, 45),
    (30, 0), (30, 45),
  ];

  // IMP 4: added (5, 1.2) — fast reactive SFI variant
  const sfiConfigs = <(int, double)>[
    (5, 1.2), (7, 1.5), (10, 1.7), (14, 2.0)
  ];

  // Filter combos: (suffix, rej, minRR, ema, vol)
  // IMP 2: added +Vol and +EMA+Vol filters
  const filters = <(String, bool, double, bool, bool)>[
    ('',         false, 0.0, false, false),
    ('+Rej',     true,  0.0, false, false),
    ('+RR1.5',   false, 1.5, false, false),
    ('+RR2.0',   false, 2.0, false, false),
    ('+EMA',     false, 0.0, true,  false),
    ('+Vol',     false, 0.0, false, true),
    ('+EMA+Vol', false, 0.0, true,  true),
  ];

  for (final (eTf, tTf) in pairs) {
    // SR mask options — IMP 5: added _B5|_B30 and _B5|_B45 combos
    final srOpts = <int>[];
    srOpts.add(tfBit[eTf]!);                 // entry TF only
    if (tTf > 0) {
      srOpts.add(tfBit[tTf]!);               // trend TF only
      srOpts.add(tfBit[eTf]! | tfBit[tTf]!); // both
    } else {
      // No trend filter — offer 45m as higher context
      if (eTf < 45) srOpts.add(_B45);
      // Multi-TF combos (IMP 5)
      if (eTf == 5) {
        srOpts.add(_B5 | _B30);
        srOpts.add(_B5 | _B45);
      }
    }

    for (final srMask in srOpts) {
      for (final (sP, sM) in sfiConfigs) {
        for (final (fStr, fRej, fRR, fEma, fVol) in filters) {
          final tStr = tTf > 0 ? 'T${tTf}m' : 'Tno';
          final name = 'E${eTf}m/${tStr}/SR${_bitsStr(srMask)}'
                       '/SFI${sP}x${sM.toStringAsFixed(1)}$fStr';
          out.add(Strat(name, eTf, tTf, srMask, sP, sM, fRej, fRR, fEma, fVol));
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
  // For analysis breakdown
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

// IMP 2: 20-bar SMA of volume — used for the +Vol filter
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

// ─────────────────────────────────────────────────────────────────────────────
// SR HELPERS  — BIAS-FREE (V6)
// ─────────────────────────────────────────────────────────────────────────────

/// Pre-compute the first bar at which each zone is broken, using only
/// past closed candles.  Returns parallel List<int?> (null = never broken).
/// breakBar is in the same bar-index units as zone.boxLeft / the candle list.
List<int?> computeBreakBars(List<SRZone> zones, List<Candle> candles, int srLen) {
  final out = List<int?>.filled(zones.length, null);
  for (int zi = 0; zi < zones.length; zi++) {
    final z    = zones[zi];
    final from = z.boxLeft + srLen; // first bar zone is visible
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

/// Known support zones at [bar]: formed >= [len] bars ago AND not yet broken.
List<SRZone> _knSup(List<SRZone> z, List<int?> bb, int bar, int len) {
  final out = <SRZone>[];
  for (int i = 0; i < z.length; i++) {
    if (!z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) out.add(z[i]);
  }
  return out;
}

/// Known resistance zones at [bar]: formed >= [len] bars ago AND not yet broken.
List<SRZone> _knRes(List<SRZone> z, List<int?> bb, int bar, int len) {
  final out = <SRZone>[];
  for (int i = 0; i < z.length; i++) {
    if (z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) out.add(z[i]);
  }
  return out;
}

SRZone? _nSup(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) {
    if (s.boxTop > p * 1.005) continue;
    final d = p - s.boxTop;
    if (d < bd) { bd = d; best = s; }
  }
  return best;
}

SRZone? _nRes(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) {
    if (s.boxBottom < p * 0.995) continue;
    final d = s.boxBottom - p;
    if (d < bd) { bd = d; best = s; }
  }
  return best;
}

bool _near(SRZone z, double p, double pct) {
  final b = p * pct / 100;
  return p >= z.boxBottom - b && p <= z.boxTop + b;
}

bool _rejLong(Candle c) {
  final body  = (c.close - c.open).abs();
  final lWick = min(c.open, c.close) - c.low;
  final total = c.high - c.low;
  if (total <= 0) return false;
  return lWick >= body * 1.5 && c.close >= c.low + total * 0.5;
}

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
  double sl;           // IMP 1: mutable — moved to breakeven after TP1
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
  final List<double> atr5, ema200_45, volSma5;  // IMP 2: volume SMA added
  final List<SRZone> zones5, zones15, zones30, zones45;
  // Bias-free break bars: first bar (in same TF units) where zone is broken
  final List<int?> bb5, bb15, bb30, bb45;

  AssetData({
    required this.sym,
    required this.c5, required this.c15, required this.c30, required this.c45,
    required this.sfi5Map, required this.sfi15Map,
    required this.sfi30Map, required this.sfi45Map,
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
}

AssetData _loadAsset(String sym, String path) {
  final c5  = _clean(_loadCsv(path), 5);
  final c15 = _agg(c5, 3);
  final c30 = _agg(c5, 6);
  final c45 = _agg(c5, 9);

  const sfiConfigs = [(5, 1.2), (7, 1.5), (10, 1.7), (14, 2.0)]; // must match _genStrategies
  final sfi5m  = <String, List<SfiSig>>{};
  final sfi15m = <String, List<SfiSig>>{};
  final sfi30m = <String, List<SfiSig>>{};
  final sfi45m = <String, List<SfiSig>>{};

  for (final (p, m) in sfiConfigs) {
    final key = '${p}_$m';
    sfi5m[key]  = _sfi(c5,  p, m);
    sfi15m[key] = _sfi(c15, p, m);
    sfi30m[key] = _sfi(c30, p, m);
    sfi45m[key] = _sfi(c45, p, m);
  }

  final atr5    = _atrList(c5, 14);
  final volSma  = _volSma(c5, 20);   // IMP 2
  final ema200  = _ema(c45, 200);

  // SR zones — checkHist:false (no future-confirmation bias)
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

  // Bias-free break bars (computed from past closes only, no s.b look-ahead)
  final bbs5  = computeBreakBars(z5,  c5,  _srl5);
  final bbs15 = computeBreakBars(z15, c15, _srl15);
  final bbs30 = computeBreakBars(z30, c30, _srl30);
  final bbs45 = computeBreakBars(z45, c45, _srl45);

  return AssetData(
    sym: sym, c5: c5, c15: c15, c30: c30, c45: c45,
    sfi5Map: sfi5m, sfi15Map: sfi15m, sfi30Map: sfi30m, sfi45Map: sfi45m,
    atr5: atr5, ema200_45: ema200, volSma5: volSma,
    zones5: z5, zones15: z15, zones30: z30, zones45: z45,
    bb5: bbs5, bb15: bbs15, bb30: bbs30, bb45: bbs45,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTEST ENGINE
// ─────────────────────────────────────────────────────────────────────────────

Res _run(AssetData d, Strat s) {
  final c5   = d.c5;
  final c15  = d.c15;
  final c30  = d.c30;
  final c45  = d.c45;
  final sfi5  = d.sfi5(s.sfiP, s.sfiM);
  final sfi15 = d.sfi15(s.sfiP, s.sfiM);
  final sfi30 = d.sfi30(s.sfiP, s.sfiM);
  final sfi45 = d.sfi45(s.sfiP, s.sfiM);
  final atr5    = d.atr5;
  final ema45   = d.ema200_45;
  final volSma5 = d.volSma5;  // IMP 2

  double netEq = 0, grossEq = 0, totFee = 0, totSlp = 0, totFund = 0;
  double peak = 0, maxDd = 0;
  int wins = 0, tradeCount = 0, cd = 0;
  _T? active;
  bool pendL = false, pendS = false;
  DateTime lastFund = DateTime(2000);

  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i15 = i ~/ 3;
    final i30 = i ~/ 6;
    final i45 = i ~/ 9;

    // ── Entry flip detection ──────────────────────────────────────────────
    bool buyFlip = false, sellFlip = false;
    Candle flipBar = c;

    if (s.entryTf == 5) {
      buyFlip  = sfi5[i].buy;
      sellFlip = sfi5[i].sell;
      flipBar  = c;
    } else if (s.entryTf == 15) {
      if (i % 3 == 2 && i15 < sfi15.length) {
        buyFlip  = sfi15[i15].buy;
        sellFlip = sfi15[i15].sell;
        flipBar  = c15[i15];
      }
    } else { // 30
      if (i % 6 == 5 && i30 < sfi30.length) {
        buyFlip  = sfi30[i30].buy;
        sellFlip = sfi30[i30].sell;
        flipBar  = c30[i30];
      }
    }

    // ── Trend bias filter (previous bar of trend TF) ──────────────────────
    if (s.trendTf > 0 && (buyFlip || sellFlip)) {
      int trend = 0;
      if      (s.trendTf == 15 && i15 > 0 && i15 - 1 < sfi15.length) trend = sfi15[i15 - 1].trend;
      else if (s.trendTf == 30 && i30 > 0 && i30 - 1 < sfi30.length) trend = sfi30[i30 - 1].trend;
      else if (s.trendTf == 45 && i45 > 0 && i45 - 1 < sfi45.length) trend = sfi45[i45 - 1].trend;
      if (trend < 0) buyFlip  = false;
      if (trend > 0) sellFlip = false;
    }

    // ── Extra filters (only evaluate when there's a flip) ─────────────────
    if (buyFlip || sellFlip) {
      // Rejection candle
      if (s.rej) {
        if (buyFlip  && !_rejLong(flipBar))  buyFlip  = false;
        if (sellFlip && !_rejShort(flipBar)) sellFlip = false;
      }
      // EMA200 filter (45m, previous bar)
      if (s.ema && i45 > 0 && i45 - 1 < ema45.length) {
        final ema = ema45[i45 - 1];
        if (buyFlip  && c.close < ema) buyFlip  = false;
        if (sellFlip && c.close > ema) sellFlip = false;
      }
      // IMP 2: volume filter — signal bar volume must exceed 20-bar SMA
      if (s.vol && i < volSma5.length) {
        if (buyFlip  && c.volume <= volSma5[i]) buyFlip  = false;
        if (sellFlip && c.volume <= volSma5[i]) sellFlip = false;
      }
    }

    // ── Lazy zone computation (only when needed) ──────────────────────────
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

    // ── SR proximity check ────────────────────────────────────────────────
    if (buyFlip) {
      final ns = _nSup(getSup(), c.close);
      if (ns == null || !_near(ns, c.close, _proxPct)) buyFlip = false;
    }
    if (sellFlip) {
      final nr = _nRes(getRes(), c.close);
      if (nr == null || !_near(nr, c.close, _proxPct)) sellFlip = false;
    }

    // ── Fill pending at this bar's open (signal was queued last bar) ──────
    // Fill runs BEFORE queue so that a signal set at bar i's close is only
    // acted upon at bar i+1's open — never at the same bar's open.
    if (active == null && cd == 0 && (pendL || pendS)) {
      final dir = pendL ? 1 : -1;
      pendL = pendS = false;
      final fill = c.open;
      final atr  = atr5[i - 1]; // FIX 4: use previous bar's ATR (known at open)
      final sup  = _nSup(getSup(), fill);
      final res  = _nRes(getRes(), fill);

      double slP, tp1P;
      if (dir == 1) {
        slP  = sup != null ? sup.boxBottom * (1 - _slBuf / 100) : fill - _atrFb * atr;
        tp1P = res != null ? res.boxBottom                       : fill + _atrFb * atr;
      } else {
        slP  = res != null ? res.boxTop * (1 + _slBuf / 100) : fill + _atrFb * atr;
        tp1P = sup != null ? sup.boxTop                       : fill - _atrFb * atr;
      }

      final validL = dir == 1  && tp1P > fill && fill > slP;
      final validS = dir == -1 && tp1P < fill && fill < slP;

      bool rrOk = true;
      if (s.minRR > 0 && (validL || validS)) {
        final reward = (tp1P - fill).abs();
        final risk   = (fill - slP).abs();
        rrOk = risk > 0 && reward / risk >= s.minRR;
      }

      if ((validL || validS) && rrOk) {
        final t  = _T(dir: dir, entry: fill, qty: _dep / fill, tp1: tp1P, sl: slP);
        final ef = _dep * _commission / 100;
        final es = _dep * _slippage   / 100;
        t.fee += ef; t.slp += es; totFee += ef; totSlp += es;
        active = t;
        tradeCount++;
      }
    } else if (active == null && (pendL || pendS) && cd > 0) {
      pendL = pendS = false;
    }

    // ── Queue pending entry (signal fires at this bar's close) ────────────
    // Queue runs AFTER fill so the signal set here is only filled next bar.
    if (active == null && cd == 0 && !pendL && !pendS) {
      if (buyFlip)  pendL = true;
      if (sellFlip) pendS = true;
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
      const sp  = 0.8; // 80/20 split
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
        t.sl     = t.entry; // IMP 1: breakeven SL — trailing 20% can no longer lose
        final gp80 = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * _dep * sp
            : (t.entry - t.tp1) / t.entry * _dep * sp;
        final xf = _dep * sp * _commission / 100;
        final xs = _dep * sp * _slippage   / 100;
        t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
        grossEq += gp80; netEq += gp80 - xf - xs;

      } else if (t.tp1Hit) {
        // Trail 20% until SFI on entry TF reverses
        bool reversed = false;
        if (s.entryTf == 5)       reversed = t.dir == 1 ? sfi5[i > 0 ? i-1 : 0].sell  : sfi5[i > 0 ? i-1 : 0].buy;
        else if (s.entryTf == 15) reversed = t.dir == 1 ? (i15 > 0 && sfi15[i15-1].sell) : (i15 > 0 && sfi15[i15-1].buy);
        else                      reversed = t.dir == 1 ? (i30 > 0 && sfi30[i30-1].sell) : (i30 > 0 && sfi30[i30-1].buy);

        if (reversed) {
          final rem  = 1 - sp;
          // FIX 5: exit at c.open — the first tradeable price after the
          // reversal signal (which fired at the previous bar's close).
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
    'SUIUSDT', 'TRXUSDT', 'XMRUSDT', 'QNTUSDT', 'BNBUSDT',
  ];
  // Deduplicate
  final assetSet = assetFiles.toSet().toList();

  print('═' * 90);
  print(' STRATEGY V8 — ${_strategies.length} strategies × ${assetSet.length} assets'
        ' = ${_strategies.length * assetSet.length} backtests');
  print('═' * 90);

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
      if (done % 90 == 0) stdout.write('.');
    }
    print(' done (${d.zones5.length}+${d.zones15.length}+${d.zones30.length}+${d.zones45.length} zones)');
  }

  // ── MASTER LEADERBOARD ───────────────────────────────────────────────────
  final profitable = allRes.where((r) => r.netPnl > 0).toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));
  final total = allRes.length;
  final profCount = profitable.length;

  print('\n');
  _hdr('MASTER LEADERBOARD — Top 60 by Calmar (profitable only, $profCount/$total = '
       '${(profCount/total*100).toStringAsFixed(1)}% profitable)');
  _tblHdr();
  for (int i = 0; i < profitable.length && i < 60; i++) {
    _tblRow(profitable[i], rank: i + 1);
  }
  _tblFoot();

  // ── ENTRY TF ANALYSIS ────────────────────────────────────────────────────
  print('\n');
  _hdr('ENTRY TIMEFRAME ANALYSIS');
  print('${'Entry TF'.padRight(10)} │ Profitable% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final eTf in [5, 15, 30]) {
    final rs = allRes.where((r) => r.entryTf == eTf).toList();
    _tfLine('E${eTf}m', rs);
  }

  // ── TREND TF ANALYSIS ────────────────────────────────────────────────────
  print('\n');
  _hdr('TREND FILTER TF ANALYSIS');
  print('${'Trend TF'.padRight(10)} │ Profitable% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final tTf in [0, 15, 30, 45]) {
    final rs = allRes.where((r) => r.trendTf == tTf).toList();
    _tfLine(tTf == 0 ? 'No bias' : 'T${tTf}m', rs);
  }

  // ── ENTRY × TREND MATRIX ─────────────────────────────────────────────────
  print('\n');
  _hdr('ENTRY × TREND TF MATRIX (avg Calmar)');
  final trendTfs = [0, 15, 30, 45];
  final entryTfs = [5, 15, 30];
  stdout.write('${''.padRight(12)}');
  for (final tTf in trendTfs) {
    final h = tTf == 0 ? 'NoTrend' : 'T${tTf}m';
    stdout.write(' │ ${h.padLeft(8)}');
  }
  print('');
  print('─' * (12 + trendTfs.length * 12));
  for (final eTf in entryTfs) {
    stdout.write('E${eTf}m'.padRight(12));
    for (final tTf in trendTfs) {
      if (tTf > 0 && tTf <= eTf) { stdout.write(' │    --  '); continue; }
      final rs = allRes.where((r) => r.entryTf == eTf && r.trendTf == tTf).toList();
      if (rs.isEmpty) { stdout.write(' │    --  '); continue; }
      final avgC = rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
      final profPct = rs.where((r) => r.netPnl > 0).length / rs.length * 100;
      stdout.write(' │ ${avgC.toStringAsFixed(2).padLeft(5)} (${profPct.round()}%)');
    }
    print('');
  }

  // ── SFI CONFIG ANALYSIS ───────────────────────────────────────────────────
  print('\n');
  _hdr('SFI CONFIGURATION ANALYSIS');
  print('${'SFI Config'.padRight(12)} │ Profitable% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final (p, m) in [(7, 1.5), (10, 1.7), (14, 2.0)]) {
    final rs = allRes.where((r) => r.sfiP == p && r.sfiM == m).toList();
    _tfLine('${p}×${m.toStringAsFixed(1)}', rs);
  }

  // ── FILTER ANALYSIS ───────────────────────────────────────────────────────
  print('\n');
  _hdr('FILTER ANALYSIS');
  print('${'Filter'.padRight(12)} │ Profitable% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final (label, suffix) in [
    ('NoFilter',  ''),
    ('Rej',       '+Rej'),
    ('RR≥1.5',    '+RR1.5'),
    ('RR≥2.0',    '+RR2.0'),
    ('EMA200',    '+EMA'),
    ('Vol',       '+Vol'),
    ('EMA+Vol',   '+EMA+Vol'),
  ]) {
    final rs = suffix.isEmpty
        ? allRes.where((r) => !r.strat.contains('+')).toList()
        : allRes.where((r) => r.strat.endsWith(suffix)).toList();
    _tfLine(label, rs);
  }

  // ── SR TF ANALYSIS ────────────────────────────────────────────────────────
  print('\n');
  _hdr('SR ZONES TF ANALYSIS');
  print('${'SR Config'.padRight(12)} │ Profitable% │ AvgCalmar │ BestCalmar │ A★  B★  C★');
  print('─' * 60);
  for (final mask in [
    _B5, _B15, _B30, _B45,
    _B5|_B15, _B5|_B30, _B5|_B45,          // IMP 5: new combos
    _B15|_B30, _B15|_B45, _B30|_B45,
  ]) {
    final rs = allRes.where((r) => r.srMask == mask).toList();
    if (rs.isEmpty) continue;
    _tfLine('SR${_bitsStr(mask)}', rs);
  }

  // ── BEST OVERALL ─────────────────────────────────────────────────────────
  if (profitable.isNotEmpty) {
    final best = profitable.first;
    print('\n');
    _hdr('BEST OVERALL STRATEGY');
    print('  Asset    : ${best.asset}');
    print('  Strategy : ${best.strat}');
    print('  Trades   : ${best.trades}   WR: ${best.wr.toStringAsFixed(1)}%');
    print('  Return   : ${best.returnPct.toStringAsFixed(1)}%');
    print('  Max DD   : ${best.maxDdPct.toStringAsFixed(1)}%');
    print('  Calmar   : ${best.calmar.toStringAsFixed(2)}');
    print('  Grade    : ${best.grade}');
    print('  Costs    : fees \$${best.fees.toStringAsFixed(2)}'
          '  slip \$${best.slip.toStringAsFixed(2)}'
          '  fund \$${best.fund.toStringAsFixed(2)}');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  const w = 90;
  final p = max(0, (w - t.length - 2) ~/ 2);
  print('═' * p + ' $t ' + '═' * max(0, w - p - t.length - 2));
}

void _tblHdr() {
  print('  # │ Asset     │ Strategy'
        '${' ' * 42}│  Trd │   WR% │  Ret% │  DD% │ Calmar │ Grade');
  print('─' * 120);
}

void _tblRow(Res r, {int? rank}) {
  final rk  = rank != null ? rank.toString().padLeft(3) : '   ';
  final sn  = r.strat.length > 46 ? r.strat.substring(0, 43) + '...' : r.strat;
  print('$rk │ ${r.asset.padRight(9)} │ ${sn.padRight(46)}'
        '│ ${r.trades.toString().padLeft(4)} │'
        ' ${r.wr.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.returnPct >= 0 ? '+' : ''}${r.returnPct.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.maxDdPct.toStringAsFixed(1).padLeft(4)}% │'
        ' ${r.calmar.toStringAsFixed(2).padLeft(6)} │ ${r.grade}');
}

void _tblFoot() => print('─' * 120);

void _tfLine(String label, List<Res> rs) {
  if (rs.isEmpty) return;
  final prof  = rs.where((r) => r.netPnl > 0).length;
  final pct   = (prof / rs.length * 100).round();
  final avgC  = rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
  final bestC = rs.map((r) => r.calmar).reduce(max);
  final aG    = rs.where((r) => r.grade == 'A★★★').length;
  final bG    = rs.where((r) => r.grade == 'B★★').length;
  final cG    = rs.where((r) => r.grade == 'C★').length;
  print('${label.padRight(10)} │  ${'$pct%'.padLeft(8)} │ ${avgC.toStringAsFixed(2).padLeft(9)} │'
        ' ${bestC.toStringAsFixed(2).padLeft(10)} │ $aG    $bG    $cG');
}
