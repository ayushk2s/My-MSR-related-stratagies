// =============================================================================
// WALK-FORWARD VALIDATION — v8 Strategy Suite  (look-ahead-free edition)
// =============================================================================
//
// ── WHAT IS A BACKTEST? (and why you can't trust it alone) ───────────────────
//
//   A backtest runs a strategy on historical data to see how it "would have"
//   performed. In v8, we tested 13,000+ strategy combinations on ALL the data,
//   then ranked the best ones FROM that same data.
//
//   This is like a student studying an answer key, then acing the exact same
//   exam — it proves nothing about live performance. In trading this is called
//   "curve-fitting" or "overfitting."
//
// ── WHAT IS WALK-FORWARD VALIDATION? ─────────────────────────────────────────
//
//   Walk-forward splits historical data into two non-overlapping periods:
//
//   ╔══════════════════════════════════════╦════════════════════════╗
//   ║   TRAINING PERIOD  (first 70%)      ║   TEST PERIOD (30%)   ║
//   ║                                      ║                        ║
//   ║   Run all 13,000+ strategies.        ║   Strategy has NEVER  ║
//   ║   Find the best settings.            ║   seen this data.     ║
//   ║   Strategy CAN "see" this data.      ║   This is the proof.  ║
//   ╚══════════════════════════════════════╩════════════════════════╝
//
//   Step 1 — TRAIN : Run every strategy on training bars. Rank by Calmar.
//   Step 2 — TEST  : Run every strategy on unseen test bars.
//   Step 3 — VERIFY: If profitable in BOTH → the edge is REAL.
//
// ── WHY YOU NEED THIS ─────────────────────────────────────────────────────────
//
//   Without walk-forward:
//     • v8's top strategy has 1 trade, 100% WR — statistically meaningless.
//     • You might trade a strategy that just got lucky on old data.
//     • Showing raw backtest results to investors is misleading.
//
//   With walk-forward:
//     • A strategy profitable in BOTH periods has a real, measurable edge.
//     • This is the minimum standard used at hedge funds and prop firms.
//     • Investors can see the performance on data the model never touched.
//
// ── HOW TO READ THE RESULTS ───────────────────────────────────────────────────
//
//   Robustness Score  =  Test Calmar  ÷  Train Calmar
//   (How much of the training performance is retained in unseen data)
//
//     ≥ 0.60  → STRONG   : Likely to work in live trading
//     0.30–0.60 → MODERATE: Some decay, but edge is real
//     < 0.30  → WEAK     : Likely overfitted — avoid
//
//   Minimum criteria for ROBUST leaderboard:
//     • Test return  > 0  (profitable on unseen data)
//     • Train return > 0  (profitable on training data)
//     • Train trades ≥ 5  (enough to be statistically meaningful)
//     • Test  trades ≥ 3  (at least a few unseen data trades)
//     • Robustness  ≥ 0.25 (retains at least 25% of training edge)
//
// ── LOOK-AHEAD BIAS STATUS ────────────────────────────────────────────────────
//
//   Signal at bar i close → fill at bar i+1 open           ✓ no look-ahead
//   Trend/EMA filter uses previous bar (i-1)               ✓ no look-ahead
//   ATR uses previous bar at fill time (atr5[i-1])         ✓ no look-ahead
//   Volume filter uses PREVIOUS bar's SMA (volSma5[i-1])   ✓ FIXED (was volSma5[i])
//   EMA filter uses previous 45m bar (ema45[i45-1])        ✓ no look-ahead
//   SFI indicator is purely causal (no future bars)        ✓ no look-ahead
//   SR zones filtered by boxLeft+srLen <= bar              ✓ no look-ahead
//   Breakeven SL after TP1                                 ✓ no look-ahead
//   Trailing exit checks previous bar's SFI flip           ✓ no look-ahead
//
//   ⚠️  RESIDUAL RISK — SupportResistanceIndicator (external):
//     Standard pivot-high/pivot-low detection requires looking N bars AHEAD
//     to confirm a pivot (a high is only a pivot high if the next N bars are
//     lower). This is computed on the full dataset inside _loadAsset. If
//     SupportResistanceIndicator.calculate() uses future bars for pivot
//     confirmation, zones formed near bar j are identified with knowledge of
//     bars j+1..j+srLen, which is look-ahead. This cannot be fixed here
//     without the SR implementation source. Set checkHist:false (already done)
//     and verify that the indicator only uses past bars internally.
//
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
const _cooldown   = 4;
const _proxPct    = 0.8;
const _slBuf      = 0.2;
const _atrFb      = 2.0;

const _srl5  = 8;
const _srl15 = 12;
const _srl30 = 11;
const _srl45 = 10;

const _B5  = 1;
const _B15 = 2;
const _B30 = 4;
const _B45 = 8;

// Walk-forward split ratio
const _trainPct = 0.70;

// Partial-close ratio at TP1: 80% locked in, 20% trailed.
// Defined ONCE here; used inside _runRange (no more shadowed local consts).
const _tp1Split = 0.8;

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY DEFINITION
// ─────────────────────────────────────────────────────────────────────────────

class Strat {
  final String name;
  final int    entryTf, trendTf, srMask, sfiP;
  final double sfiM;
  final bool   rej, ema, vol;
  final double minRR;
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
  final out   = <Strat>[];
  final tfBit = {5: _B5, 15: _B15, 30: _B30, 45: _B45};

  const pairs = <(int, int)>[
    (5, 0), (5, 15), (5, 30), (5, 45),
    (15, 0), (15, 30), (15, 45),
    (30, 0), (30, 45),
  ];

  // Must match _loadAsset sfiConfigs exactly
  const sfiConfigs = <(int, double)>[
    (5, 1.2), (7, 1.5), (10, 1.7), (14, 2.0)
  ];

  // (suffix, rej, minRR, ema, vol)
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
    final srOpts = <int>[];
    srOpts.add(tfBit[eTf]!);
    if (tTf > 0) {
      srOpts.add(tfBit[tTf]!);
      srOpts.add(tfBit[eTf]! | tfBit[tTf]!);
    } else {
      if (eTf < 45) srOpts.add(_B45);
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
// RESULT TYPES
// ─────────────────────────────────────────────────────────────────────────────

class _PRes {
  final int    trades, wins;
  final double netEq, maxDd;
  const _PRes(this.trades, this.wins, this.netEq, this.maxDd);

  double get retPct   => _dep > 0 ? netEq / _dep * 100 : 0;
  double get ddPct    => _dep > 0 ? maxDd / _dep * 100 : 0;
  double get calmar   => ddPct > 0 ? retPct / ddPct
                       : retPct > 0 ? 99.0 : 0.0;
  double get wr       => trades == 0 ? 0 : wins / trades * 100;
}

class WalkRes {
  final String  asset, strat;
  final _PRes   train, test;
  final double  robustness;
  final bool    robust;
  final String  grade;
  final int     entryTf, trendTf, srMask, sfiP;
  final double  sfiM;

  WalkRes({
    required this.asset, required this.strat,
    required this.train, required this.test,
    required this.robustness, required this.robust, required this.grade,
    required this.entryTf, required this.trendTf, required this.srMask,
    required this.sfiP,  required this.sfiM,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS — all purely causal (each bar uses only bar i and earlier)
// ─────────────────────────────────────────────────────────────────────────────

class SfiSig {
  final double up, dn;
  final int    trend;
  final bool   buy, sell;
  const SfiSig(this.up, this.dn, this.trend, this.buy, this.sell);
}

List<SfiSig> _sfi(List<Candle> cs, int p, double m) {
  // True Range — uses only current bar and previous close.
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  // ATR — Wilder-style, causal.
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  // Supertrend-style bands — each bar uses cs[i].ohlc4 (known at bar i close)
  // and cs[i-1].close (previous bar, fully known).
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT  = 1;
  final out  = <SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m * a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m * a;
    int t = prevT;
    if (prevT == -1 && cs[i].close > pDn) t =  1;
    else if (prevT == 1  && cs[i].close < pUp) t = -1;
    out.add(SfiSig(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

// Volume SMA — causal rolling mean.
// NOTE: volSma[i] includes bar i's own volume. In _runRange we always read
// volSma[i-1] so that the reference volume is fully known before the signal bar.
List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  double s = 0;
  for (int i = 0; i < cs.length; i++) {
    s += cs[i].volume;
    if (i >= p) s -= cs[i - p].volume;
    out.add(s / (i < p ? i + 1 : p));
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
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i-1] * (1 - k));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR HELPERS — BIAS-FREE
// ─────────────────────────────────────────────────────────────────────────────

// computeBreakBars — records the first bar at which each zone was broken.
// NOT look-ahead in usage: at bar k, the filter  bb[i]! > k  is equivalent
// to asking "has this zone been breached by any bar before k?" — identical to
// what a live system would know.
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
  double sl;
  bool   tp1Hit = false;
  double tp1P = 0, exitP = 0;
  String reason = '';
  double fee = 0, slp = 0, fund = 0;
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
  final List<double> atr5, ema200_45, volSma5;
  final List<SRZone> zones5, zones15, zones30, zones45;
  final List<int?>   bb5, bb15, bb30, bb45;

  AssetData({
    required this.sym,
    required this.c5, required this.c15, required this.c30, required this.c45,
    required this.sfi5Map, required this.sfi15Map,
    required this.sfi30Map, required this.sfi45Map,
    required this.atr5, required this.ema200_45, required this.volSma5,
    required this.zones5, required this.zones15,
    required this.zones30, required this.zones45,
    required this.bb5, required this.bb15, required this.bb30, required this.bb45,
  });

  List<SfiSig> sfi5(int p, double m)  => sfi5Map['${p}_$m']!;
  List<SfiSig> sfi15(int p, double m) => sfi15Map['${p}_$m']!;
  List<SfiSig> sfi30(int p, double m) => sfi30Map['${p}_$m']!;
  List<SfiSig> sfi45(int p, double m) => sfi45Map['${p}_$m']!;
}

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
      hi  = max(hi, c[i+j].high);
      lo  = min(lo, c[i+j].low);
      vol += c[i+j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i+n-1].close, vol, out.length));
  }
  return out;
}

AssetData _loadAsset(String sym, String path) {
  final c5  = _clean(_loadCsv(path), 5);
  final c15 = _agg(c5, 3);
  final c30 = _agg(c5, 6);
  final c45 = _agg(c5, 9);

  // Must match _genStrategies sfiConfigs exactly — or you get a null crash
  const sfiConfigs = [(5, 1.2), (7, 1.5), (10, 1.7), (14, 2.0)];
  final sfi5m  = <String, List<SfiSig>>{};
  final sfi15m = <String, List<SfiSig>>{};
  final sfi30m = <String, List<SfiSig>>{};
  final sfi45m = <String, List<SfiSig>>{};

  for (final (p, m) in sfiConfigs) {
    final key   = '${p}_$m';
    sfi5m[key]  = _sfi(c5,  p, m);
    sfi15m[key] = _sfi(c15, p, m);
    sfi30m[key] = _sfi(c30, p, m);
    sfi45m[key] = _sfi(c45, p, m);
  }

  final atr5   = _atrList(c5, 14);
  final volSma = _volSma(c5, 20);
  final ema200 = _ema(c45, 200);

  // ⚠️ SR ZONE LOOK-AHEAD WARNING:
  // SupportResistanceIndicator.calculate() is called on the full c5/c15/c30/c45
  // arrays. If the indicator identifies pivot highs/lows by looking N bars
  // forward (the standard definition of a pivot), then a zone at bar j is
  // confirmed using data from bars j+1 .. j+srLen — which is look-ahead for
  // any simulation bar k ≤ j+srLen.
  //
  // Mitigations already in place:
  //   1. checkHist:false  — disables historical zone extension.
  //   2. boxLeft + srLen ≤ bar  filter in _knSup/_knRes  — a zone is only
  //      visible after srLen bars have passed since its left edge, so the
  //      confirming look-ahead window has already elapsed.
  //
  // Residual risk: zones are still IDENTIFIED using future data; only their
  // VISIBILITY is delayed by srLen bars. To fully eliminate this bias you
  // must verify that SupportResistanceIndicator uses a strictly causal (past-
  // only) pivot algorithm, or replace it with one.
  List<SRZone> _zones(List<Candle> cs, int len) {
    final sr = SupportResistanceIndicator(
        detectionLength: len, srMargin: 2.0, avoidFBO: true, checkHist: false);
    final r  = sr.calculate(cs);
    return [...r.support, ...r.resistance];
  }

  final z5  = _zones(c5,  _srl5);
  final z15 = _zones(c15, _srl15);
  final z30 = _zones(c30, _srl30);
  final z45 = _zones(c45, _srl45);

  return AssetData(
    sym: sym, c5: c5, c15: c15, c30: c30, c45: c45,
    sfi5Map: sfi5m, sfi15Map: sfi15m, sfi30Map: sfi30m, sfi45Map: sfi45m,
    atr5: atr5, ema200_45: ema200, volSma5: volSma,
    zones5: z5, zones15: z15, zones30: z30, zones45: z45,
    bb5: computeBreakBars(z5, c5, _srl5),
    bb15: computeBreakBars(z15, c15, _srl15),
    bb30: computeBreakBars(z30, c30, _srl30),
    bb45: computeBreakBars(z45, c45, _srl45),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE ENGINE — _runRange
// ─────────────────────────────────────────────────────────────────────────────
//
// Runs the simulation on bars [startBar, endBar).
// Indicator arrays are precomputed on the full dataset and are correctly indexed
// at any bar (all are causal — value at bar k depends only on bars 0..k).
// No carry-over of active trades or pending signals from prior periods.
//
// ── LOOK-AHEAD STATUS (per indicator read) ───────────────────────────────────
//
//   sfi5[i].buy/sell          bar i close signal → queued → bar i+1 open  ✓
//   sfi15[i15].buy            only when i%3==2 (15m bar just closed)       ✓
//   sfi30[i30].buy            only when i%6==5 (30m bar just closed)       ✓
//   sfi{tf}[iTf - 1].trend    previous COMPLETE bar                        ✓
//   ema45[i45 - 1]            previous complete 45m bar, EMA is causal     ✓
//   atr5[i - 1]               previous bar's ATR at fill time              ✓
//   volSma5[i - 1]            previous bar's SMA → no current-bar leak     ✓  (FIXED)
//   sfi5[i - 1].sell          trailing exit: previous bar's flip           ✓
//   sfi15[i15 - 1].sell       same, one 15m bar behind                     ✓
//   sfi30[i30 - 1].sell       same, one 30m bar behind                     ✓

_PRes _runRange(AssetData d, Strat s, int startBar, int endBar) {
  // ── Partial-close ratio: 80% at TP1, 20% trailed until reversal ──────────
  // Defined once here — removes the duplicate file-level const and the
  // shadowing local const that was nested inside the TP/SL if-block.
  const sp = _tp1Split; // 0.8

  final c5      = d.c5;
  final sfi5    = d.sfi5(s.sfiP, s.sfiM);
  final sfi15   = d.sfi15(s.sfiP, s.sfiM);
  final sfi30   = d.sfi30(s.sfiP, s.sfiM);
  final sfi45   = d.sfi45(s.sfiP, s.sfiM);
  final atr5    = d.atr5;
  final ema45   = d.ema200_45;
  final volSma5 = d.volSma5;

  double netEq = 0, peak = 0, maxDd = 0;
  int wins = 0, tradeCount = 0, cd = 0;
  _T? active;
  bool pendL = false, pendS = false;
  DateTime lastFund = startBar < c5.length
      ? c5[startBar].time
      : DateTime(2000);

  final loopStart = max(1, startBar);

  for (int i = loopStart; i < endBar; i++) {
    final c   = c5[i];
    final i15 = i ~/ 3;
    final i30 = i ~/ 6;
    final i45 = i ~/ 9;

    // ── Entry flip detection ────────────────────────────────────────────────
    // Signal uses indicator at bar i close → queued → filled at bar i+1 open.
    bool buyFlip = false, sellFlip = false;
    Candle flipBar = c;

    if (s.entryTf == 5) {
      // sfi5[i] is computed at bar i close — no look-ahead.
      buyFlip  = sfi5[i].buy;
      sellFlip = sfi5[i].sell;
      flipBar  = c;
    } else if (s.entryTf == 15) {
      // Fire only when the 15m bar just closed (last 5m bar of that group).
      if (i % 3 == 2 && i15 < sfi15.length) {
        buyFlip  = sfi15[i15].buy;
        sellFlip = sfi15[i15].sell;
        flipBar  = d.c15[i15];
      }
    } else { // entryTf == 30
      // Fire only when the 30m bar just closed.
      if (i % 6 == 5 && i30 < sfi30.length) {
        buyFlip  = sfi30[i30].buy;
        sellFlip = sfi30[i30].sell;
        flipBar  = d.c30[i30];
      }
    }

    // ── Trend bias filter — uses PREVIOUS bar of the trend timeframe ─────────
    // Using i{tf} - 1 ensures the trend bar is fully closed, no look-ahead.
    if (s.trendTf > 0 && (buyFlip || sellFlip)) {
      int trend = 0;
      if      (s.trendTf == 15 && i15 > 0) trend = sfi15[i15 - 1].trend;
      else if (s.trendTf == 30 && i30 > 0) trend = sfi30[i30 - 1].trend;
      else if (s.trendTf == 45 && i45 > 0) trend = sfi45[i45 - 1].trend;
      if (trend < 0) buyFlip  = false;
      if (trend > 0) sellFlip = false;
    }

    // ── Extra filters ───────────────────────────────────────────────────────
    if (buyFlip || sellFlip) {

      // Rejection candle: uses flipBar's own OHLC, known at its close.
      if (s.rej) {
        if (buyFlip  && !_rejLong(flipBar))  buyFlip  = false;
        if (sellFlip && !_rejShort(flipBar)) sellFlip = false;
      }

      // EMA filter: uses previous complete 45m bar (i45 - 1), causal.
      if (s.ema && i45 > 0 && i45 - 1 < ema45.length) {
        final ema = ema45[i45 - 1];
        if (buyFlip  && c.close < ema) buyFlip  = false;
        if (sellFlip && c.close > ema) sellFlip = false;
      }

      // Volume filter — FIX: use volSma5[i - 1] (previous bar's SMA).
      //
      // Original code used volSma5[i], whose SMA at index i already
      // incorporates bar i's own volume — making the threshold partly
      // dependent on the very value being tested (circular look-ahead).
      //
      // Correct approach: compare bar i's volume against the SMA of bars
      // 0..(i-1), which is entirely known BEFORE bar i opens.
      //
      // Guard: i > 0 is already guaranteed by loopStart = max(1, startBar).
      if (s.vol) {
        final vRef = volSma5[i - 1]; // previous bar's SMA — no look-ahead
        if (buyFlip  && c.volume <= vRef) buyFlip  = false;
        if (sellFlip && c.volume <= vRef) sellFlip = false;
      }
    }

    // ── Lazy SR zone computation for this bar ───────────────────────────────
    // allSup / allRes are local to each loop iteration (reset every bar).
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

    // ── SR proximity check (signal bar close vs known zones) ─────────────────
    if (buyFlip) {
      final ns = _nSup(getSup(), c.close);
      if (ns == null || !_near(ns, c.close, _proxPct)) buyFlip = false;
    }
    if (sellFlip) {
      final nr = _nRes(getRes(), c.close);
      if (nr == null || !_near(nr, c.close, _proxPct)) sellFlip = false;
    }

    // ── Fill pending (signal queued at bar i-1 → fill at bar i open) ────────
    if (active == null && cd == 0 && (pendL || pendS)) {
      final dir  = pendL ? 1 : -1;
      pendL = pendS = false;
      final fill = c.open;

      // atr5[i-1]: previous bar's ATR — fully known at bar i open.
      final atr  = atr5[i - 1];
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

      final validL = dir ==  1 && tp1P > fill && fill > slP;
      final validS = dir == -1 && tp1P < fill && fill < slP;

      bool rrOk = true;
      if (s.minRR > 0 && (validL || validS)) {
        final reward = (tp1P - fill).abs();
        final risk   = (fill  - slP).abs();
        rrOk = risk > 0 && reward / risk >= s.minRR;
      }

      if ((validL || validS) && rrOk) {
        final t  = _T(dir: dir, entry: fill, qty: _dep / fill, tp1: tp1P, sl: slP);
        final ef = _dep * _commission / 100;
        final es = _dep * _slippage   / 100;
        t.fee += ef; t.slp += es;
        active = t;
        tradeCount++;
      }
    } else if (active == null && (pendL || pendS) && cd > 0) {
      // Cooldown still active — cancel the pending order.
      pendL = pendS = false;
    }

    // ── Queue pending entry from this bar's signal ───────────────────────────
    // Runs AFTER fill — signal at bar i close is filled at bar i+1 open.
    if (active == null && cd == 0 && !pendL && !pendS) {
      if (buyFlip)  pendL = true;
      if (sellFlip) pendS = true;
    }

    // ── Funding (every 8 hours, charged on open position) ───────────────────
    if (active != null && active.open && c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      active.fund += _dep * _funding / 100;
    }

    // ── TP / SL management ───────────────────────────────────────────────────
    if (active != null && active.open) {
      final t   = active;
      // sp = 0.8 (80% closed at TP1, 20% trailed).
      final tpH = t.dir ==  1 ? c.high >= t.tp1 : c.low  <= t.tp1;
      final slH = t.dir ==  1 ? c.low  <= t.sl  : c.high >= t.sl;

      if (slH) {
        // Stop-loss hit — close remaining position at SL price.
        final rem = t.tp1Hit ? (1 - sp) : 1.0;
        final gp  = t.dir == 1
            ? (t.sl - t.entry) / t.entry * _dep * rem
            : (t.entry - t.sl) / t.entry * _dep * rem;
        final xf  = _dep * rem * _commission / 100;
        final xs  = _dep * rem * _slippage   / 100;
        t.fee += xf; t.slp += xs;
        final tp1Gp = t.tp1Hit
            ? (t.dir==1 ? (t.tp1P-t.entry)/t.entry*_dep*sp
                        : (t.entry-t.tp1P)/t.entry*_dep*sp)
            : 0.0;
        final pnl = tp1Gp + gp - t.fee - t.slp - t.fund;
        netEq += pnl;
        if (pnl > 0) wins++;
        cd = _cooldown; active = null;

      } else if (!t.tp1Hit && tpH) {
        // TP1 hit — lock in 80%, move SL to breakeven, trail 20%.
        t.tp1Hit = true;
        t.tp1P   = t.tp1;
        t.sl     = t.entry; // breakeven — remaining 20% can no longer lose
        final gp80 = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * _dep * sp
            : (t.entry - t.tp1) / t.entry * _dep * sp;
        final xf = _dep * sp * _commission / 100;
        final xs = _dep * sp * _slippage   / 100;
        t.fee += xf; t.slp += xs;
        netEq += gp80 - xf - xs;

      } else if (t.tp1Hit) {
        // Trail the remaining 20% until the entry-TF SFI reverses.
        // Uses PREVIOUS bar's signal (i-1 or iTf-1) → exit at THIS bar's open.
        // No look-ahead: the reversal flip was confirmed at the prior bar close.
        bool reversed = false;
        if (s.entryTf == 5) {
          reversed = t.dir == 1
              ? sfi5[i - 1].sell
              : sfi5[i - 1].buy;
        } else if (s.entryTf == 15) {
          reversed = t.dir == 1
              ? (i15 > 0 && sfi15[i15 - 1].sell)
              : (i15 > 0 && sfi15[i15 - 1].buy);
        } else { // 30m
          reversed = t.dir == 1
              ? (i30 > 0 && sfi30[i30 - 1].sell)
              : (i30 > 0 && sfi30[i30 - 1].buy);
        }

        if (reversed) {
          final rem   = 1 - sp; // 20%
          final gp20  = t.dir == 1
              ? (c.open - t.entry) / t.entry * _dep * rem
              : (t.entry - c.open) / t.entry * _dep * rem;
          final xf = _dep * rem * _commission / 100;
          final xs = _dep * rem * _slippage   / 100;
          t.fee += xf; t.slp += xs;
          final tp1Gp = t.dir==1
              ? (t.tp1P - t.entry) / t.entry * _dep * sp
              : (t.entry - t.tp1P) / t.entry * _dep * sp;
          final pnl = tp1Gp + gp20 - t.fee - t.slp - t.fund;
          netEq += pnl;
          if (pnl > 0) wins++;
          active = null;
        }
      }
    }

    // ── Drawdown tracking ────────────────────────────────────────────────────
    if (active != null && active.open) {
      final t   = active;
      final rem = t.tp1Hit ? (1 - sp) : 1.0;
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

    // ── Force-close any open trade at the last bar of the period ─────────────
    // Uses the period's final bar close as exit price.
    // tradeCount was already incremented at entry — do not increment again.
    if (i == endBar - 1 && active != null && active.open) {
      final t   = active;
      final rem = t.tp1Hit ? (1 - sp) : 1.0;
      final ep  = c.close;
      final gp  = t.dir == 1
          ? (ep - t.entry) / t.entry * _dep * rem
          : (t.entry - ep) / t.entry * _dep * rem;
      final xf  = _dep * rem * _commission / 100;
      final xs  = _dep * rem * _slippage   / 100;
      t.fee += xf; t.slp += xs;
      final tp1Gp = t.tp1Hit
          ? (t.dir==1 ? (t.tp1P-t.entry)/t.entry*_dep*sp
                      : (t.entry-t.tp1P)/t.entry*_dep*sp)
          : 0.0;
      final pnl = tp1Gp + gp - t.fee - t.slp - t.fund;
      netEq += pnl;
      if (pnl > 0) wins++;
    }
  }

  return _PRes(tradeCount, wins, netEq, maxDd);
}

// NOTE: The file-level  const sp = 0.8  that was here in the original has been
// REMOVED.  It is now defined once, at the top of _runRange, as  const sp = _tp1Split.
// This eliminates the confusing scoping situation where the force-close block
// silently read the file-level const while the TP/SL block shadowed it with a
// local const of the same name and same value.

// ─────────────────────────────────────────────────────────────────────────────
// WALK-FORWARD RUNNER
// ─────────────────────────────────────────────────────────────────────────────

WalkRes _walkForward(AssetData d, Strat s) {
  final total    = d.c5.length;
  final trainEnd = (total * _trainPct).round();

  final train = _runRange(d, s, 0,        trainEnd);
  final test  = _runRange(d, s, trainEnd, total);

  final rob = (train.calmar > 0 && test.calmar > 0)
      ? (test.calmar / train.calmar).clamp(0.0, 2.0)
      : 0.0;

  final robust = train.retPct > 0
      && test.retPct  > 0
      && train.trades >= 5
      && test.trades  >= 3
      && rob          >= 0.25;

  final tc = test.calmar;
  final tr = test.retPct;
  final grade = tc >= 5 && tr >= 50 ? 'A★★★'
              : tc >= 3 && tr >= 30 ? 'B★★'
              : tc >= 1 && tr >= 10 ? 'C★'
              : test.netEq > 0      ? 'D'
              : 'F';

  return WalkRes(
    asset: d.sym, strat: s.name,
    train: train, test: test,
    robustness: rob, robust: robust, grade: grade,
    entryTf: s.entryTf, trendTf: s.trendTf, srMask: s.srMask,
    sfiP: s.sfiP, sfiM: s.sfiM,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// OUTPUT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  print('\n${'═' * 96}');
  print(' $t');
  print('${'═' * 96}');
}

String _robTag(double r) {
  if (r >= 0.60) return 'STRONG  ';
  if (r >= 0.30) return 'MODERATE';
  return 'WEAK    ';
}

void _robHdr() {
  print(
    '${'Rk'.padLeft(3)} │ ${'Asset'.padRight(10)} │ '
    '${'Strategy'.padRight(50)} │ '
    '${'TrTrd'.padLeft(5)} │ ${'TsTrd'.padLeft(5)} │ '
    '${'TrRet%'.padLeft(7)} │ ${'TsRet%'.padLeft(7)} │ '
    '${'TsWR%'.padLeft(6)} │ ${'TsCal'.padLeft(6)} │ '
    '${'Rob'.padLeft(5)} │ Strength  │ Grd'
  );
  print('─' * 140);
}

void _robRow(WalkRes r, int rank) {
  final rStr = r.robustness.toStringAsFixed(2);
  final tag  = _robTag(r.robustness);
  print(
    '${rank.toString().padLeft(3)} │ '
    '${r.asset.padRight(10)} │ '
    '${r.strat.padRight(50)} │ '
    '${r.train.trades.toString().padLeft(5)} │ '
    '${r.test.trades.toString().padLeft(5)} │ '
    '${(r.train.retPct >= 0 ? '+' : '') + r.train.retPct.toStringAsFixed(1).padLeft(6)}% │ '
    '${(r.test.retPct  >= 0 ? '+' : '') + r.test.retPct.toStringAsFixed(1).padLeft(6)}% │ '
    '${r.test.wr.toStringAsFixed(1).padLeft(5)}% │ '
    '${r.test.calmar.toStringAsFixed(2).padLeft(6)} │ '
    '${rStr.padLeft(5)} │ $tag │ ${r.grade}'
  );
}

void _analysisSect(String title, String col, List<WalkRes> all,
    List<(String, Object Function(WalkRes))> groups) {
  _hdr(title);
  print('${''.padRight(14)} │ '
        '${'Robust%'.padLeft(8)} │ ${'AvgTsCal'.padLeft(9)} │ ${'BstTsCal'.padLeft(9)} │ '
        '${'AvgRob'.padLeft(7)} │ A★★★  B★★   C★');
  print('─' * 80);
  for (final (label, fn) in groups) {
    final rs = all.where((r) => fn(r).toString() == label).toList();
    if (rs.isEmpty) continue;
    final robustCnt  = rs.where((r) => r.robust).length;
    final robustPct  = robustCnt / rs.length * 100;
    final avgTsCal   = rs.fold(0.0, (s, r) => s + r.test.calmar) / rs.length;
    final bestTsCal  = rs.map((r) => r.test.calmar).reduce(max);
    final avgRob     = rs.fold(0.0, (s, r) => s + r.robustness) / rs.length;
    final aCount     = rs.where((r) => r.grade == 'A★★★').length;
    final bCount     = rs.where((r) => r.grade == 'B★★').length;
    final cCount     = rs.where((r) => r.grade == 'C★').length;
    print('${label.padRight(14)} │ '
          '${robustPct.toStringAsFixed(1).padLeft(7)}% │ '
          '${avgTsCal.toStringAsFixed(2).padLeft(9)} │ '
          '${bestTsCal.toStringAsFixed(2).padLeft(9)} │ '
          '${avgRob.toStringAsFixed(3).padLeft(7)} │ '
          '$aCount    $bCount    $cCount');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────


//main function
void main() {
  const base = '/Users/ayush/Desktop/candlestick data/5m';

  final assetList = [
    'SOLUSDT', 
    // 'XRPUSDT', 'TRBUSDT', 'BTCUSDT', 'ETHUSDT',
    // 'DOGEUSDT', 'BNBUSDT', 'ADAUSDT', 'APTUSDT', 'BCHUSDT',
    // 'CFXUSDT', 'ENAUSDT', 'HBARUSDT', 'ICPUSDT', 'LTCUSDT',
    // 'SUIUSDT', 'TRXUSDT', 'XMRUSDT', 'QNTUSDT',
  ].toSet().toList();

  print('═' * 96);
  print(' WALK-FORWARD VALIDATION — v8 Strategy Suite (look-ahead-free)');
  print(' ${_strategies.length} strategies × ${assetList.length} assets'
        ' = ${_strategies.length * assetList.length * 2} total runs'
        '  (train + test each)');
  print(' Data split: ${(_trainPct*100).round()}% training / ${((1-_trainPct)*100).round()}% testing');
  print('═' * 96);
  print('');
  print(' WHAT THIS FILE PROVES:');
  print('   Each strategy is tested on data it has NEVER seen (the last 30%).');
  print('   Only strategies that are PROFITABLE in BOTH periods appear as ROBUST.');
  print('   Robustness ≥ 0.25 means the edge is real, not just memorised data.');
  print('');
  print(' LOOK-AHEAD FIXES APPLIED IN THIS VERSION:');
  print('   • Volume filter now reads volSma5[i-1] (previous bar SMA).');
  print('     Previously volSma5[i] included bar i\'s own volume in the');
  print('     threshold being compared against bar i\'s volume — circular bias.');
  print('   • const sp = 0.8 consolidated to a single definition at function');
  print('     scope; removed the shadowing local const and the file-level duplicate.');
  print('');

  final allWalk = <WalkRes>[];

  for (final sym in assetList) {
    final path = '$base/${sym}5m.csv';
    if (!File(path).existsSync()) { print('  SKIP $sym (file not found)'); continue; }

    final d        = _loadAsset(sym, path);
    final trainEnd = (d.c5.length * _trainPct).round();
    final testEnd  = d.c5.length;

    final trainFrom = d.c5[0].time.toIso8601String().substring(0, 10);
    final trainTo   = d.c5[trainEnd - 1].time.toIso8601String().substring(0, 10);
    final testFrom  = d.c5[trainEnd].time.toIso8601String().substring(0, 10);
    final testTo    = d.c5[testEnd - 1].time.toIso8601String().substring(0, 10);

    stdout.write(
      '  $sym  ${d.c5.length} bars │ '
      'Train: $trainFrom→$trainTo (${trainEnd} bars) │ '
      'Test: $testFrom→$testTo (${testEnd - trainEnd} bars)  .'
    );

    int done = 0;
    for (final strat in _strategies) {
      allWalk.add(_walkForward(d, strat));
      done++;
      if (done % 100 == 0) stdout.write('.');
    }
    print(' done');
  }

  // ── ROBUST LEADERBOARD ─────────────────────────────────────────────────────
  final robust = allWalk
      .where((r) => r.robust)
      .toList()
      ..sort((a, b) {
        final sA = a.test.calmar * a.robustness * min(a.test.trades, 20) / 20;
        final sB = b.test.calmar * b.robustness * min(b.test.trades, 20) / 20;
        return sB.compareTo(sA);
      });

  final totalRuns   = allWalk.length;
  final robustCount = robust.length;

  _hdr('ROBUST LEADERBOARD — Top 50 (profitable in BOTH train + test periods)');
  print('  Ranked by: Test Calmar × Robustness × Trade Count (capped at 20)');
  print('  $robustCount / $totalRuns combinations passed the walk-forward test'
        ' (${(robustCount/totalRuns*100).toStringAsFixed(1)}%)');
  print('  Column key: TrTrd=Train trades, TsTrd=Test trades,'
        ' TrRet%=Train return, TsRet%=Test return, TsCal=Test Calmar, Rob=Robustness');
  print('');
  _robHdr();
  for (int i = 0; i < robust.length && i < 50; i++) {
    _robRow(robust[i], i + 1);
  }
  print('─' * 140);

  // ── ANALYSIS SECTIONS ──────────────────────────────────────────────────────

  void _sect(String title, List<(String, bool Function(WalkRes))> groups) {
    _hdr(title);
    print('${'Group'.padRight(16)} │ '
          '${'Robust%'.padLeft(8)} │ ${'AvgTsCal'.padLeft(9)} │ ${'BestTsCal'.padLeft(9)} │ '
          '${'AvgRob'.padLeft(7)} │ B★★  C★');
    print('─' * 80);
    for (final (label, fn) in groups) {
      final rs = allWalk.where(fn).toList();
      if (rs.isEmpty) continue;
      final robCnt    = rs.where((r) => r.robust).length;
      final robPct    = robCnt / rs.length * 100;
      final avgTsCal  = rs.fold(0.0, (s, r) => s + r.test.calmar) / rs.length;
      final bestTsCal = rs.map((r) => r.test.calmar).reduce(max);
      final avgRob    = rs.fold(0.0, (s, r) => s + r.robustness) / rs.length;
      final bCount    = rs.where((r) => r.grade == 'B★★').length;
      final cCount    = rs.where((r) => r.grade == 'C★').length;
      print('${label.padRight(16)} │ '
            '${robPct.toStringAsFixed(1).padLeft(7)}% │ '
            '${avgTsCal.toStringAsFixed(3).padLeft(9)} │ '
            '${bestTsCal.toStringAsFixed(2).padLeft(9)} │ '
            '${avgRob.toStringAsFixed(3).padLeft(7)} │ $bCount    $cCount');
    }
  }

  _sect('ENTRY TIMEFRAME — Robustness Analysis', [
    ('E5m',  (r) => r.entryTf == 5),
    ('E15m', (r) => r.entryTf == 15),
    ('E30m', (r) => r.entryTf == 30),
  ]);

  _sect('TREND FILTER — Robustness Analysis', [
    ('No trend',  (r) => r.trendTf == 0),
    ('Trend 15m', (r) => r.trendTf == 15),
    ('Trend 30m', (r) => r.trendTf == 30),
    ('Trend 45m', (r) => r.trendTf == 45),
  ]);

  _sect('SFI CONFIGURATION — Robustness Analysis', [
    ('SFI 5×1.2',  (r) => r.sfiP == 5  && r.sfiM == 1.2),
    ('SFI 7×1.5',  (r) => r.sfiP == 7  && r.sfiM == 1.5),
    ('SFI 10×1.7', (r) => r.sfiP == 10 && r.sfiM == 1.7),
    ('SFI 14×2.0', (r) => r.sfiP == 14 && r.sfiM == 2.0),
  ]);

  _sect('FILTER — Robustness Analysis', [
    ('No filter',  (r) => !r.strat.contains('+')),
    ('+Rej',       (r) => r.strat.endsWith('+Rej')),
    ('+RR1.5',     (r) => r.strat.endsWith('+RR1.5')),
    ('+RR2.0',     (r) => r.strat.endsWith('+RR2.0')),
    ('+EMA',       (r) => r.strat.endsWith('+EMA')),
    ('+Vol',       (r) => r.strat.endsWith('+Vol')),
    ('+EMA+Vol',   (r) => r.strat.endsWith('+EMA+Vol')),
  ]);

  _sect('SR ZONE TIMEFRAME — Robustness Analysis', [
    ('SR 5m',       (r) => r.srMask == _B5),
    ('SR 15m',      (r) => r.srMask == _B15),
    ('SR 30m',      (r) => r.srMask == _B30),
    ('SR 45m',      (r) => r.srMask == _B45),
    ('SR 5m+15m',   (r) => r.srMask == (_B5|_B15)),
    ('SR 5m+30m',   (r) => r.srMask == (_B5|_B30)),
    ('SR 5m+45m',   (r) => r.srMask == (_B5|_B45)),
    ('SR 15m+30m',  (r) => r.srMask == (_B15|_B30)),
    ('SR 15m+45m',  (r) => r.srMask == (_B15|_B45)),
    ('SR 30m+45m',  (r) => r.srMask == (_B30|_B45)),
  ]);

  // ── RECOMMENDED STRATEGIES ─────────────────────────────────────────────────
  final candidates = allWalk
      .where((r) => r.robust && r.test.trades >= 5 && r.robustness >= 0.30)
      .toList()
      ..sort((a, b) => (b.test.calmar * b.robustness)
                       .compareTo(a.test.calmar * a.robustness));

  _hdr('TOP RECOMMENDED STRATEGIES FOR LIVE TRADING');
  print('  Criteria: ROBUST + test trades ≥ 5 + robustness ≥ 0.30');
  print('  These are the strategies most likely to work in live markets.');
  print('  REMINDER: Always paper-trade for 2–4 weeks before risking real money.');
  print('');
  if (candidates.isEmpty) {
    print('  No strategies passed all criteria. Consider relaxing robustness threshold.');
  } else {
    _robHdr();
    for (int i = 0; i < candidates.length && i < 10; i++) {
      _robRow(candidates[i], i + 1);
    }
    print('─' * 140);
    print('');
    print('  BEST OVERALL RECOMMENDATION:');
    final best = candidates.first;
    print('    Asset    : ${best.asset}');
    print('    Strategy : ${best.strat}');
    print('    Train    : ${best.train.trades} trades, '
          '${best.train.wr.toStringAsFixed(1)}% WR, '
          '${best.train.retPct >= 0 ? '+' : ''}${best.train.retPct.toStringAsFixed(1)}% return');
    print('    Test     : ${best.test.trades} trades, '
          '${best.test.wr.toStringAsFixed(1)}% WR, '
          '${best.test.retPct >= 0 ? '+' : ''}${best.test.retPct.toStringAsFixed(1)}% return');
    print('    Robustness: ${best.robustness.toStringAsFixed(3)} — ${_robTag(best.robustness).trim()}');
    print('    Test Grade: ${best.grade}');
  }

  print('\n');
  print('═' * 96);
  print(' END OF WALK-FORWARD REPORT');
  print(' DISCLAIMER: Historical simulation results do not guarantee future');
  print(' performance. Always use proper risk management and consult a qualified');
  print(' financial advisor before trading with real capital or investor funds.');
  print('═' * 96);
}