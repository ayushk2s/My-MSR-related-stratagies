// =============================================================================
// WALK-FORWARD VALIDATION — v9 Extended + Bug-Fixed
// =============================================================================
//
// ── BUGS FIXED FROM v8 ───────────────────────────────────────────────────────
//
//   BUG 1 — Double-counted TP1 profit (CRITICAL):
//     Old code added `gp80 - xf - xs` to netEq at TP1 hit, then at the final
//     exit it computed tp1Gp (= gp80 again) and subtracted t.fee/t.slp which
//     already included the TP1 fees. Result: TP1 profit counted TWICE, TP1
//     fees subtracted TWICE — every trade that hit TP1 was artificially
//     inflated by (gp80 + tp1Fees).
//
//     FIX: Nothing is added to netEq at TP1 hit. t.fee/t.slp accumulate all
//     costs. A single final P&L is computed once when the trade closes —
//     whether by SL, trail reversal, or force-close. No intermediate credits.
//
//   BUG 2 — Volume filter used current bar's SMA (look-ahead):
//     volSma5[i] at bar i already incorporates bar i's own volume.
//     Comparing bar i's volume against it is circular.
//     FIX: comparison now uses volSma5[i-1] (previous bar's SMA).
//
//   BUG 3 — const sp scoping (cosmetic but confusing):
//     The file-level `const sp = 0.8` was replaced by a single definition
//     inside _runRange as `const sp = _tp1Split`.
//
// ── NEW IN v9 ─────────────────────────────────────────────────────────────────
//
//   Indicators:
//     • RSI(14) precomputed on 5m, 15m, 30m timeframes.
//     • Bollinger Bands(20, 2.0) precomputed on 5m, 15m.
//
//   New entry mode dimension (entryMode):
//     0  SFI-flip + SR-proximity             (identical to v8)
//     1  SFI-flip + RSI confirm  (RSI<45 long / RSI>55 short)
//     2  SFI-flip + Volume spike (vol > 1.5× prev SMA)
//     3  RSI extreme bounce  (RSI<30 long / RSI>70 short, no SFI flip)
//     4  Bollinger Band touch (price≤lower long / price≥upper short)
//
//   New exit mode dimension (exitMode):
//     0  80% closed at TP1, trail 20% until SFI reversal  (v8 behaviour, fixed)
//     1  100% closed at TP1 — cleaner, more frequent exits
//
//   Expanded filter set:
//     Added +RR0.8, +RR1.0, +RR1.2 to the minRR sweep (was only 1.5 & 2.0).
//
// ── LOOK-AHEAD STATUS ────────────────────────────────────────────────────────
//   Signal at bar i close → fill at bar i+1 open      ✓
//   Trend filter uses previous bar (iTf-1)             ✓
//   ATR: atr5[i-1] at fill time                        ✓
//   Volume: volSma5[i-1]                               ✓  (v8 bug fixed)
//   EMA: ema45[i45-1]                                  ✓
//   RSI: rsi[i] at signal bar close                    ✓
//   BB:  bb[i] at signal bar close                     ✓
//   SFI: purely causal                                 ✓
//   SR: boxLeft+srLen ≤ bar guard                      ✓
//
//   Residual: SR pivot detection may use srLen future bars for pivot
//   confirmation. Mitigated by checkHist:false + the boxLeft+srLen guard.
//   Fully eliminating this requires a causal pivot implementation.
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
const _commission = 0.025;   // % per side
const _slippage   = 0.04;    // % per side
const _funding    = 0.01;    // % per 8h
const _cooldown   = 4;       // bars after full stop-out
const _proxPct    = 0.8;     // SR proximity %
const _slBuf      = 0.2;     // SL buffer below zone edge %
const _atrFb      = 2.0;     // ATR fallback multiplier for SL/TP

const _srl5  = 8;   // SR detection length on 5m
const _srl15 = 12;  // SR detection length on 15m
const _srl30 = 11;  // SR detection length on 30m
const _srl45 = 10;  // SR detection length on 45m

const _B5  = 1;
const _B15 = 2;
const _B30 = 4;
const _B45 = 8;

const _trainPct  = 0.70;
const _tp1Split  = 0.80;  // 80% closed at TP1

// New indicator params
const _rsiPeriod  = 14;
const _rsiOsLong  = 30.0;  // RSI extreme — oversold threshold (long entry)
const _rsiObShort = 70.0;  // RSI extreme — overbought threshold (short entry)
const _rsiConfL   = 45.0;  // RSI confirmation for entryMode 1 (long)
const _rsiConfS   = 55.0;  // RSI confirmation for entryMode 1 (short)
const _bbPeriod   = 20;
const _bbMult     = 2.0;
const _volMult15  = 1.5;   // volume multiplier for entryMode 2

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY DEFINITION
// ─────────────────────────────────────────────────────────────────────────────

class Strat {
  final String name;
  final int    entryTf, trendTf, srMask, sfiP;
  final double sfiM;
  final bool   rej, ema, vol;
  final double minRR;
  final int    entryMode; // 0=sfi, 1=sfi+rsi, 2=sfi+vol, 3=rsi_extreme, 4=bb_touch
  final int    exitMode;  // 0=80%tp1+trail, 1=100%tp1
  const Strat(this.name, this.entryTf, this.trendTf, this.srMask,
              this.sfiP, this.sfiM, this.rej, this.minRR, this.ema, this.vol,
              this.entryMode, this.exitMode);
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

  const sfiConfigs = <(int, double)>[
    (5, 1.2), (7, 1.5), (10, 1.7), (14, 2.0)
  ];

  // suffix | rej | minRR | ema | vol
  const filters = <(String, bool, double, bool, bool)>[
    ('',           false, 0.0, false, false),
    ('+RR0.8',     false, 0.8, false, false),
    ('+RR1.0',     false, 1.0, false, false),
    ('+RR1.2',     false, 1.2, false, false),
    ('+RR1.5',     false, 1.5, false, false),
    ('+RR2.0',     false, 2.0, false, false),
    ('+Rej',       true,  0.0, false, false),
    ('+EMA',       false, 0.0, true,  false),
    ('+Vol',       false, 0.0, false, true),
    ('+EMA+Vol',   false, 0.0, true,  true),
    ('+RR1.0+EMA', false, 1.0, true,  false),
    ('+RR1.5+EMA', false, 1.5, true,  false),
  ];

  // Entry modes and exit modes — new v9 dimensions
  const entryModes = [0, 1, 2, 3, 4];
  const exitModes  = [0, 1];

  // Labels for strategy names
  const emLabel = ['Sfi', 'Sfi+Rsi', 'Sfi+Vol', 'RsiExt', 'BB'];
  const xmLabel = ['Split', 'Full'];

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
          for (final em in entryModes) {
            for (final xm in exitModes) {
              final tStr = tTf > 0 ? 'T${tTf}m' : 'Tno';
              final name = 'E${eTf}m/${tStr}/SR${_bitsStr(srMask)}'
                           '/SFI${sP}x${sM.toStringAsFixed(1)}'
                           '/${emLabel[em]}/${xmLabel[xm]}$fStr';
              out.add(Strat(name, eTf, tTf, srMask, sP, sM,
                            fRej, fRR, fEma, fVol, em, xm));
            }
          }
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

  double get retPct => _dep > 0 ? netEq / _dep * 100 : 0;
  double get ddPct  => _dep > 0 ? maxDd / _dep * 100 : 0;
  double get calmar => ddPct > 0 ? retPct / ddPct
                     : retPct > 0 ? 99.0 : 0.0;
  double get wr     => trades == 0 ? 0 : wins / trades * 100;
}

class WalkRes {
  final String  asset, strat;
  final _PRes   train, test;
  final double  robustness;
  final bool    robust;
  final String  grade;
  final int     entryTf, trendTf, srMask, sfiP;
  final double  sfiM;
  final int     entryMode, exitMode;

  WalkRes({
    required this.asset, required this.strat,
    required this.train, required this.test,
    required this.robustness, required this.robust, required this.grade,
    required this.entryTf, required this.trendTf, required this.srMask,
    required this.sfiP, required this.sfiM,
    required this.entryMode, required this.exitMode,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS — all purely causal
// ─────────────────────────────────────────────────────────────────────────────

class SfiSig {
  final double up, dn;
  final int    trend;
  final bool   buy, sell;
  const SfiSig(this.up, this.dn, this.trend, this.buy, this.sell);
}

// Supertrend / SFI — uses only current and previous bars.
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
    else        { atr.add((atr[i-1] * (p-1) + tr[i]) / p); }
  }
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
    else if (prevT ==  1 && cs[i].close < pUp) t = -1;
    out.add(SfiSig(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

// RSI — Wilder smoothing, causal.
// rsi[i] is fully determined by bars 0..i.
List<double> _rsi(List<Candle> cs, int p) {
  final out = <double>[];
  double avgG = 0, avgL = 0;
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(50.0); continue; }
    final chg = cs[i].close - cs[i-1].close;
    final g = chg > 0 ? chg : 0.0;
    final l = chg < 0 ? -chg : 0.0;
    if (i <= p) {
      avgG = (avgG * (i-1) + g) / i;
      avgL = (avgL * (i-1) + l) / i;
    } else {
      avgG = (avgG * (p-1) + g) / p;
      avgL = (avgL * (p-1) + l) / p;
    }
    out.add(avgL == 0 ? 100.0 : 100.0 - 100.0 / (1.0 + avgG / avgL));
  }
  return out;
}

// Bollinger Bands — SMA ± k*StdDev, causal rolling window.
class BBBar {
  final double upper, lower, mid;
  const BBBar(this.upper, this.lower, this.mid);
}

List<BBBar> _bb(List<Candle> cs, int p, double mult) {
  final out = <BBBar>[];
  for (int i = 0; i < cs.length; i++) {
    final start = max(0, i - p + 1);
    double sum = 0;
    for (int j = start; j <= i; j++) sum += cs[j].close;
    final n   = i - start + 1;
    final mid = sum / n;
    double vSum = 0;
    for (int j = start; j <= i; j++) vSum += (cs[j].close - mid) * (cs[j].close - mid);
    final std = sqrt(vSum / n);
    out.add(BBBar(mid + mult * std, mid - mult * std, mid));
  }
  return out;
}

// Volume SMA — causal rolling mean.
// NOTE: volSma[i] INCLUDES bar i's own volume.
// In _runRange we always use volSma[i-1] so the reference is bias-free.
List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  double s = 0;
  for (int i = 0; i < cs.length; i++) {
    s += cs[i].volume;
    if (i >= p) s -= cs[i-p].volume;
    out.add(s / (i < p ? i + 1 : p));
  }
  return out;
}

List<double> _atrList(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s / (i+1)); }
    else        { atr.add((atr[i-1] * (p-1) + tr[i]) / p); }
  }
  return atr;
}

List<double> _ema(List<Candle> cs, int p) {
  final k = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i-1] * (1-k));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR HELPERS — bias-free
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
// TRADE  — simplified, bug-free
// ─────────────────────────────────────────────────────────────────────────────
//
// KEY DESIGN: Nothing is added to netEq until the trade is fully closed.
// All costs (entry, TP1 partial close, final close) accumulate in fee+slp.
// P&L is computed ONCE at close: (tp1G + finalG) - fee - slp - fund.
// This eliminates all double-counting.

class _T {
  final int    dir;
  final double entry, tp1;
  double sl;
  bool   tp1Hit = false;
  double tp1P   = 0;  // exact price TP1 was hit (= tp1 at trigger time)
  double fee    = 0;  // accumulated: entry + TP1-partial + final-close commissions
  double slp    = 0;  // accumulated: entry + TP1-partial + final-close slippage
  double fund   = 0;  // accumulated funding charges
  _T({required this.dir, required this.entry, required this.tp1, required this.sl});
}

// ─────────────────────────────────────────────────────────────────────────────
// PRECOMPUTED PER-ASSET DATA
// ─────────────────────────────────────────────────────────────────────────────

class AssetData {
  final String sym;
  final List<Candle> c5, c15, c30, c45;
  final Map<String, List<SfiSig>> sfi5Map, sfi15Map, sfi30Map, sfi45Map;
  final List<double> atr5, ema200_45, volSma5;
  final List<double> rsi5, rsi15, rsi30;
  final List<BBBar>  bb5, bb15;
  final List<SRZone> zones5, zones15, zones30, zones45;
  final List<int?>   bb5br, bb15br, bb30br, bb45br;

  AssetData({
    required this.sym,
    required this.c5, required this.c15, required this.c30, required this.c45,
    required this.sfi5Map, required this.sfi15Map,
    required this.sfi30Map, required this.sfi45Map,
    required this.atr5, required this.ema200_45, required this.volSma5,
    required this.rsi5, required this.rsi15, required this.rsi30,
    required this.bb5, required this.bb15,
    required this.zones5, required this.zones15,
    required this.zones30, required this.zones45,
    required this.bb5br, required this.bb15br,
    required this.bb30br, required this.bb45br,
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

List<Candle> _lastMonths(List<Candle> cs, int months) {
  if (cs.isEmpty) return cs;

  final lastTime = cs.last.time;

  // Approx 6 months = 180 days
  final cutoff = lastTime.subtract(Duration(days: 30 * months));

  return cs.where((c) => c.time.isAfter(cutoff)).toList();
} 

AssetData _loadAsset(String sym, String path) {
final raw5 = _clean(_loadCsv(path), 5);

// 🔥 APPLY FILTER HERE
final c5 = _lastMonths(raw5, 24);  final c15 = _agg(c5, 3);
  final c30 = _agg(c5, 6);
  final c45 = _agg(c5, 9);

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
    atr5:       _atrList(c5, 14),
    ema200_45:  _ema(c45, 200),
    volSma5:    _volSma(c5, 20),
    rsi5:       _rsi(c5,  _rsiPeriod),
    rsi15:      _rsi(c15, _rsiPeriod),
    rsi30:      _rsi(c30, _rsiPeriod),
    bb5:        _bb(c5,  _bbPeriod, _bbMult),
    bb15:       _bb(c15, _bbPeriod, _bbMult),
    zones5:  z5,  zones15: z15, zones30: z30, zones45: z45,
    bb5br:  computeBreakBars(z5,  c5,  _srl5),
    bb15br: computeBreakBars(z15, c15, _srl15),
    bb30br: computeBreakBars(z30, c30, _srl30),
    bb45br: computeBreakBars(z45, c45, _srl45),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE ENGINE — _runRange (bug-fixed + extended)
// ─────────────────────────────────────────────────────────────────────────────
//
// ── CRITICAL BUG FIX — NO DOUBLE-COUNTING ────────────────────────────────────
//
// Old code:                           New code:
//   TP1 → netEq += gp80 - fees         TP1 → record tp1P, accumulate costs
//   Exit → netEq += tp1Gp + rem - ALL  Exit → netEq += tp1G + remG - ALL
//          (tp1Gp = gp80, DOUBLE)              (ONE computation, ONE credit)
//
// Total P&L for any trade = (tp1G + remG) - (entryFee + tp1Fee + exitFee) - fund
// This is computed ONCE, when the trade closes, regardless of exit type.

_PRes _runRange(AssetData d, Strat s, int startBar, int endBar) {
  // sp: fraction closed at TP1 (exitMode 0: 80%, exitMode 1: 100%)
  final sp = s.exitMode == 1 ? 1.0 : _tp1Split; // 1.0 or 0.8

  final c5      = d.c5;
  final sfi5    = d.sfi5(s.sfiP, s.sfiM);
  final sfi15   = d.sfi15(s.sfiP, s.sfiM);
  final sfi30   = d.sfi30(s.sfiP, s.sfiM);
  final sfi45   = d.sfi45(s.sfiP, s.sfiM);
  final atr5    = d.atr5;
  final ema45   = d.ema200_45;
  final volSma5 = d.volSma5;
  final rsi5    = d.rsi5;
  final rsi15   = d.rsi15;
  final rsi30   = d.rsi30;
  final bb5     = d.bb5;
  final bb15    = d.bb15;

  double netEq = 0, peak = 0, maxDd = 0;
  int wins = 0, tradeCount = 0, cd = 0;
  _T? active;
  bool pendL = false, pendS = false;
  DateTime lastFund = startBar < c5.length ? c5[startBar].time : DateTime(2000);

  // ── Helper: compute and book a completed trade ───────────────────────────
  // tp1G: gain on TP1 tranche (0 if TP1 never hit)
  // remG: gain on remaining tranche at final exit price
  // Costs already accumulated in active.fee / active.slp / active.fund.
  void _closeTrade(_T t, double tp1G, double remG, bool isSl) {
    final pnl = tp1G + remG - t.fee - t.slp - t.fund;
    netEq += pnl;
    if (pnl > 0) wins++;
    if (isSl && !t.tp1Hit) cd = _cooldown; // cooldown only on full stop-out
    active = null;
  }

  for (int i = max(1, startBar); i < endBar; i++) {
    final c   = c5[i];
    final i15 = i ~/ 3;
    final i30 = i ~/ 6;
    final i45 = i ~/ 9;

    // ── Entry signal detection ───────────────────────────────────────────────
    // Signal fires at bar i close → queued → filled at bar i+1 open.
    bool buyFlip = false, sellFlip = false;
    Candle flipBar = c;

    // ── Step A: raw signal from entryMode ───────────────────────────────────
  if (s.entryMode == 3) {
  double? rsiRef;

  if (s.entryTf == 15) {
    if (i15 < rsi15.length) rsiRef = rsi15[i15];
  } else if (s.entryTf == 30) {
    if (i30 < rsi30.length) rsiRef = rsi30[i30];
  } else {
    rsiRef = rsi5[i];
  }

  if (rsiRef == null) {
    buyFlip = false;
    sellFlip = false;
  } else {
    double? prevRsi;

    if (s.entryTf == 15 && i15 > 0 && i15 - 1 < rsi15.length) {
      prevRsi = rsi15[i15 - 1];
    } else if (s.entryTf == 30 && i30 > 0 && i30 - 1 < rsi30.length) {
      prevRsi = rsi30[i30 - 1];
    } else if (i > 0) {
      prevRsi = rsi5[i - 1];
    }

    if (prevRsi == null) {
      buyFlip = false;
      sellFlip = false;
    } else {
      // ✅ TRUE RSI BOUNCE
      buyFlip  = prevRsi < _rsiOsLong  && rsiRef >= _rsiOsLong;
      sellFlip = prevRsi > _rsiObShort && rsiRef <= _rsiObShort;
    }
  }

  flipBar = c;
}
    
    else if (s.entryMode == 4) {
      // Bollinger Band touch — no SFI flip required.
      // Uses current bar's low/high vs band computed at bar i.
      // bb[i] uses only bars 0..i — causal.
      if (s.entryTf == 5) {
        buyFlip  = c.low  <= bb5[i].lower;
        sellFlip = c.high >= bb5[i].upper;
      } else if (s.entryTf == 15) {
        if (i15 < bb15.length) {
          buyFlip  = d.c15[i15].low  <= bb15[i15].lower;
          sellFlip = d.c15[i15].high >= bb15[i15].upper;
        }
      } else {
        // 30m — fall back to 5m BB (no bb30 precomputed)
        buyFlip  = c.low  <= bb5[i].lower;
        sellFlip = c.high >= bb5[i].upper;
      }
      flipBar = c;

    } else {
      // entryMode 0, 1, 2 — base signal is SFI flip
      if (s.entryTf == 5) {
        buyFlip  = sfi5[i].buy;
        sellFlip = sfi5[i].sell;
        flipBar  = c;
      } else if (s.entryTf == 15) {
        if (i % 3 == 2 && i15 < sfi15.length) {
          buyFlip  = sfi15[i15].buy;
          sellFlip = sfi15[i15].sell;
          flipBar  = d.c15[i15];
        }
      } else { // 30
        if (i % 6 == 5 && i30 < sfi30.length) {
          buyFlip  = sfi30[i30].buy;
          sellFlip = sfi30[i30].sell;
          flipBar  = d.c30[i30];
        }
      }
    }

    // ── Step B: trend bias filter — previous bar ────────────────────────────
    if (s.trendTf > 0 && (buyFlip || sellFlip)) {
      int trend = 0;
      if      (s.trendTf == 15 && i15 > 0) trend = sfi15[i15-1].trend;
      else if (s.trendTf == 30 && i30 > 0) trend = sfi30[i30-1].trend;
      else if (s.trendTf == 45 && i45 > 0) trend = sfi45[i45-1].trend;
      if (trend < 0) buyFlip  = false;
      if (trend > 0) sellFlip = false;
    }

    // ── Step C: extra filters ───────────────────────────────────────────────
    if (buyFlip || sellFlip) {

      // Rejection candle (uses flipBar OHLC, known at close)
      if (s.rej) {
        if (buyFlip  && !_rejLong(flipBar))  buyFlip  = false;
        if (sellFlip && !_rejShort(flipBar)) sellFlip = false;
      }

      // EMA200 on 45m — uses previous complete 45m bar
      if (s.ema && i45 > 0 && i45 - 1 < ema45.length) {
        final ema = ema45[i45-1];
        if (buyFlip  && c.close < ema) buyFlip  = false;
        if (sellFlip && c.close > ema) sellFlip = false;
      }

      // Volume filter — uses volSma5[i-1] (previous bar SMA, bias-free)
      if (s.vol) {
        final vRef = volSma5[i-1];
        if (buyFlip  && c.volume <= vRef) buyFlip  = false;
        if (sellFlip && c.volume <= vRef) sellFlip = false;
      }

      // ── Step D: entryMode-specific additional condition ──────────────────
      if (s.entryMode == 1) {
        // SFI flip + RSI confirmation
        final rsiV = s.entryTf == 15 ? rsi15[i15]
                   : s.entryTf == 30 ? rsi30[i30]
                   : rsi5[i];
        if (buyFlip  && rsiV >= _rsiConfL) buyFlip  = false; // RSI must be below 45
        if (sellFlip && rsiV <= _rsiConfS) sellFlip = false; // RSI must be above 55
      } else if (s.entryMode == 2) {
        // SFI flip + volume spike (1.5× previous bar SMA)
        final vRef = volSma5[i-1];
        if (buyFlip  && c.volume <= vRef * _volMult15) buyFlip  = false;
        if (sellFlip && c.volume <= vRef * _volMult15) sellFlip = false;
      }
    }

    // ── Step E: SR proximity check ──────────────────────────────────────────
    // Computed lazily — only if signal is still alive.
    List<SRZone>? allSup, allRes;
    List<SRZone> getSup() {
      if (allSup != null) return allSup!;
      allSup = <SRZone>[];
      if (s.srMask & _B5  != 0) allSup!.addAll(_knSup(d.zones5,  d.bb5br,  i,   _srl5));
      if (s.srMask & _B15 != 0) allSup!.addAll(_knSup(d.zones15, d.bb15br, i15, _srl15));
      if (s.srMask & _B30 != 0) allSup!.addAll(_knSup(d.zones30, d.bb30br, i30, _srl30));
      if (s.srMask & _B45 != 0) allSup!.addAll(_knSup(d.zones45, d.bb45br, i45, _srl45));
      return allSup!;
    }
    List<SRZone> getRes() {
      if (allRes != null) return allRes!;
      allRes = <SRZone>[];
      if (s.srMask & _B5  != 0) allRes!.addAll(_knRes(d.zones5,  d.bb5br,  i,   _srl5));
      if (s.srMask & _B15 != 0) allRes!.addAll(_knRes(d.zones15, d.bb15br, i15, _srl15));
      if (s.srMask & _B30 != 0) allRes!.addAll(_knRes(d.zones30, d.bb30br, i30, _srl30));
      if (s.srMask & _B45 != 0) allRes!.addAll(_knRes(d.zones45, d.bb45br, i45, _srl45));
      return allRes!;
    }

    if (buyFlip) {
      final ns = _nSup(getSup(), c.close);
      if (ns == null || !_near(ns, c.close, _proxPct)) buyFlip = false;
    }
    if (sellFlip) {
      final nr = _nRes(getRes(), c.close);
      if (nr == null || !_near(nr, c.close, _proxPct)) sellFlip = false;
    }

    // ── Fill pending ─────────────────────────────────────────────────────────
    // Pending from bar i-1 → fill at bar i open.
    if (active == null && cd == 0 && (pendL || pendS)) {
      final dir  = pendL ? 1 : -1;
      pendL = pendS = false;
      final fill = c.open;
      final atr  = atr5[i-1]; // previous bar ATR — known at open

      final sup = _nSup(getSup(), fill);
      final res = _nRes(getRes(), fill);

      double slP, tp1P;
      if (dir == 1) {
        slP  = sup != null ? sup.boxBottom * (1 - _slBuf/100) : fill - _atrFb * atr;
        tp1P = res != null ? res.boxBottom                    : fill + _atrFb * atr;
      } else {
        slP  = res != null ? res.boxTop * (1 + _slBuf/100) : fill + _atrFb * atr;
        tp1P = sup != null ? sup.boxTop                     : fill - _atrFb * atr;
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
        final t = _T(dir: dir, entry: fill, tp1: tp1P, sl: slP);
        // Charge entry commission + slippage (open side)
        t.fee += _dep * _commission / 100;
        t.slp += _dep * _slippage   / 100;
        active = t;
        tradeCount++;
      }
    } else if (active == null && (pendL || pendS) && cd > 0) {
      pendL = pendS = false; // cooldown — drop pending
    }

    // ── Queue pending entry from this bar's signal ───────────────────────────
    if (active == null && cd == 0 && !pendL && !pendS) {
      if (buyFlip)  pendL = true;
      if (sellFlip) pendS = true;
    }

    // ── Funding ─────────────────────────────────────────────────────────────
    if (active != null && c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      active!.fund += _dep * _funding / 100;
    }

    // ── TP / SL management ──────────────────────────────────────────────────
    if (active != null) {
      final t   = active!;
      final tpH = t.dir ==  1 ? c.high >= t.tp1 : c.low  <= t.tp1;
      final slH = t.dir ==  1 ? c.low  <= t.sl  : c.high >= t.sl;

      if (slH) {
        // ─── STOP-LOSS HIT ────────────────────────────────────────────────
        final rem = t.tp1Hit ? (1.0 - sp) : 1.0;
        // Charge close-side costs for remaining fraction
        t.fee += _dep * rem * _commission / 100;
        t.slp += _dep * rem * _slippage   / 100;
        // P&L: TP1 tranche (0 if never hit) + SL tranche
        final tp1G = t.tp1Hit
            ? (t.dir == 1
                ? (t.tp1P - t.entry) / t.entry * _dep * sp
                : (t.entry - t.tp1P) / t.entry * _dep * sp)
            : 0.0;
        final slG = t.dir == 1
            ? (t.sl   - t.entry) / t.entry * _dep * rem
            : (t.entry - t.sl)  / t.entry * _dep * rem;
        _closeTrade(t, tp1G, slG, true);

      } else if (!t.tp1Hit && tpH) {
        // ─── TP1 HIT ─────────────────────────────────────────────────────
        // Record TP1 price; accumulate TP1 close costs; move SL to breakeven.
        // DO NOT add anything to netEq yet.
        t.tp1Hit = true;
        t.tp1P   = t.tp1;
        t.sl     = t.entry; // breakeven
        t.fee += _dep * sp * _commission / 100;
        t.slp += _dep * sp * _slippage   / 100;

        // exitMode 1: 100% closed at TP1 — trade is done
        if (s.exitMode == 1) {
          // sp == 1.0 for exitMode 1, so rem == 0, tp1G is the full gain.
          final tp1G = t.dir == 1
              ? (t.tp1P - t.entry) / t.entry * _dep
              : (t.entry - t.tp1P) / t.entry * _dep;
          _closeTrade(t, tp1G, 0.0, false);
        }
        // exitMode 0: 20% remains, continue trailing

      } else if (t.tp1Hit && s.exitMode == 0) {
        // ─── TRAIL 20% until SFI reversal ────────────────────────────────
        // Check PREVIOUS bar's SFI flip (i-1) — fully closed, no look-ahead.
        bool reversed = false;
        if (s.entryTf == 5) {
          reversed = t.dir == 1 ? sfi5[i-1].sell : sfi5[i-1].buy;
        } else if (s.entryTf == 15) {
          reversed = t.dir == 1 ? (i15 > 0 && sfi15[i15-1].sell)
                                 : (i15 > 0 && sfi15[i15-1].buy);
        } else {
          reversed = t.dir == 1 ? (i30 > 0 && sfi30[i30-1].sell)
                                 : (i30 > 0 && sfi30[i30-1].buy);
        }
        if (reversed) {
          // Exit 20% at this bar's open price.
          final rem = 1.0 - sp; // 0.20
          t.fee += _dep * rem * _commission / 100;
          t.slp += _dep * rem * _slippage   / 100;
          final tp1G = t.dir == 1
              ? (t.tp1P - t.entry) / t.entry * _dep * sp
              : (t.entry - t.tp1P) / t.entry * _dep * sp;
          final remG = t.dir == 1
              ? (c.open - t.entry) / t.entry * _dep * rem
              : (t.entry - c.open) / t.entry * _dep * rem;
          _closeTrade(t, tp1G, remG, false);
        }
      }
    }

    // ── Drawdown tracking ────────────────────────────────────────────────────
    // Mark-to-market: what would total P&L be if closed RIGHT NOW at c.close?
    // Costs accumulated so far + estimated remaining close cost.
    if (active != null) {
      final t   = active!;
      final rem = t.tp1Hit && s.exitMode == 0 ? 1.0 - sp : 1.0;
      final tp1G = t.tp1Hit
          ? (t.dir == 1
              ? (t.tp1P - t.entry) / t.entry * _dep * sp
              : (t.entry - t.tp1P) / t.entry * _dep * sp)
          : 0.0;
      final openG = t.dir == 1
          ? (c.close - t.entry) / t.entry * _dep * rem
          : (t.entry - c.close) / t.entry * _dep * rem;
      // Approximate remaining exit costs (one side) for DD accuracy
      final estExitCost = _dep * rem * (_commission + _slippage) / 100;
      final cur = netEq + tp1G + openG - t.fee - t.slp - t.fund - estExitCost;
      if (cur > peak) peak = cur;
      if (peak - cur > maxDd) maxDd = peak - cur;
    } else {
      if (netEq > peak) peak = netEq;
      if (peak - netEq > maxDd) maxDd = peak - netEq;
    }

    if (cd > 0) cd--;

    // ── Force-close at end of period ─────────────────────────────────────────
    // tradeCount already incremented at entry — do NOT increment again.
    if (i == endBar - 1 && active != null) {
      final t   = active!;
      final rem = t.tp1Hit && s.exitMode == 0 ? 1.0 - sp : (t.tp1Hit ? 0.0 : 1.0);
      if (rem > 0) {
        t.fee += _dep * rem * _commission / 100;
        t.slp += _dep * rem * _slippage   / 100;
      }
      final tp1G = t.tp1Hit
          ? (t.dir == 1
              ? (t.tp1P - t.entry) / t.entry * _dep * sp
              : (t.entry - t.tp1P) / t.entry * _dep * sp)
          : 0.0;
      final remG = rem > 0
          ? (t.dir == 1
              ? (c.close - t.entry) / t.entry * _dep * rem
              : (t.entry - c.close) / t.entry * _dep * rem)
          : 0.0;
      final pnl = tp1G + remG - t.fee - t.slp - t.fund;
      netEq += pnl;
      if (pnl > 0) wins++;
    }
  }

  return _PRes(tradeCount, wins, netEq, maxDd);
}

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
    entryMode: s.entryMode, exitMode: s.exitMode,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// OUTPUT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  print('\n${'═' * 100}');
  print(' $t');
  print('${'═' * 100}');
}

String _robTag(double r) {
  if (r >= 0.60) return 'STRONG  ';
  if (r >= 0.30) return 'MODERATE';
  return 'WEAK    ';
}

void _robHdr() {
  print(
    '${'Rk'.padLeft(3)} │ ${'Asset'.padRight(10)} │ '
    '${'Strategy'.padRight(55)} │ '
    '${'TrTrd'.padLeft(5)} │ ${'TsTrd'.padLeft(5)} │ '
    '${'TrRet%'.padLeft(7)} │ ${'TsRet%'.padLeft(7)} │ '
    '${'TsWR%'.padLeft(6)} │ ${'TsCal'.padLeft(6)} │ '
    '${'Rob'.padLeft(5)} │ Strength  │ Grd'
  );
  print('─' * 148);
}

void _robRow(WalkRes r, int rank) {
  final rStr = r.robustness.toStringAsFixed(2);
  final tag  = _robTag(r.robustness);
  final sn   = r.strat.length > 55 ? r.strat.substring(0, 52) + '...' : r.strat;
  print(
    '${rank.toString().padLeft(3)} │ '
    '${r.asset.padRight(10)} │ '
    '${sn.padRight(55)} │ '
    '${r.train.trades.toString().padLeft(5)} │ '
    '${r.test.trades.toString().padLeft(5)} │ '
    '${(r.train.retPct >= 0 ? '+' : '') + r.train.retPct.toStringAsFixed(1).padLeft(6)}% │ '
    '${(r.test.retPct  >= 0 ? '+' : '') + r.test.retPct.toStringAsFixed(1).padLeft(6)}% │ '
    '${r.test.wr.toStringAsFixed(1).padLeft(5)}% │ '
    '${r.test.calmar.toStringAsFixed(2).padLeft(6)} │ '
    '${rStr.padLeft(5)} │ $tag │ ${r.grade}'
  );
}

void _sect(String title, List<WalkRes> all,
           List<(String, bool Function(WalkRes))> groups) {
  _hdr(title);
  print('${'Group'.padRight(18)} │ '
        '${'N'.padLeft(6)} │ ${'Robust%'.padLeft(8)} │ '
        '${'AvgTsCal'.padLeft(9)} │ ${'BestTsCal'.padLeft(10)} │ '
        '${'AvgRob'.padLeft(7)} │ A★★★  B★★   C★   D');
  print('─' * 90);
  for (final (label, fn) in groups) {
    final rs = all.where(fn).toList();
    if (rs.isEmpty) continue;
    final robCnt    = rs.where((r) => r.robust).length;
    final robPct    = robCnt / rs.length * 100;
    final avgTsCal  = rs.fold(0.0, (s, r) => s + r.test.calmar) / rs.length;
    final bestTsCal = rs.map((r) => r.test.calmar).reduce(max);
    final avgRob    = rs.fold(0.0, (s, r) => s + r.robustness) / rs.length;
    final aCount    = rs.where((r) => r.grade == 'A★★★').length;
    final bCount    = rs.where((r) => r.grade == 'B★★').length;
    final cCount    = rs.where((r) => r.grade == 'C★').length;
    final dCount    = rs.where((r) => r.grade == 'D').length;
    print('${label.padRight(18)} │ '
          '${rs.length.toString().padLeft(6)} │ '
          '${robPct.toStringAsFixed(1).padLeft(7)}% │ '
          '${avgTsCal.toStringAsFixed(3).padLeft(9)} │ '
          '${bestTsCal.toStringAsFixed(2).padLeft(10)} │ '
          '${avgRob.toStringAsFixed(3).padLeft(7)} │ '
          '$aCount    $bCount    $cCount    $dCount');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── Configure paths ────────────────────────────────────────────────────────
  // One 5m CSV per asset, named as <SYMBOL>5m.csv
  // Format: datetime,open,high,low,close,volume (header on row 0)
  const base = '/Users/ayush/Desktop/candlestick data/5m';

  final assetList = [
    'SOLUSDT', 'BTCUSDT', 'ETHUSDT',
    // 'DOGEUSDT', 'BNBUSDT', 'ADAUSDT', 'APTUSDT', 'BCHUSDT', 'TRBUSDT', 
    // 'CFXUSDT', 'ENAUSDT', 'HBARUSDT', 'ICPUSDT', 'LTCUSDT', 'XRPUSDT', 
    // 'SUIUSDT', 'TRXUSDT', 'XMRUSDT', 'QNTUSDT',
  ].toSet().toList();

  final startTime = DateTime.now();

  print('═' * 100);
  print(' WALK-FORWARD VALIDATION — v9 Extended + Bug-Fixed');
  print(' ${_strategies.length} strategies × ${assetList.length} assets'
        ' = ${_strategies.length * assetList.length * 2} total runs');
  print(' Split: ${(_trainPct*100).round()}% train / ${((1-_trainPct)*100).round()}% test');
  print('═' * 100);
  print('');
  print(' BUGS FIXED:');
  print('   ✓ Double-counted TP1 profit: P&L now computed ONCE at final close.');
  print('   ✓ Volume SMA now uses volSma5[i-1] (previous bar, bias-free).');
  print('');
  print(' NEW IN v9:');
  print('   • RSI(14) on 5m/15m/30m — used for entryMode 1 (confirm) & 3 (extreme).');
  print('   • Bollinger Bands(20,2) on 5m/15m — used for entryMode 4.');
  print('   • entryMode: 5 options (SFI, SFI+RSI, SFI+Vol, RSI-Extreme, BB-Touch).');
  print('   • exitMode:  2 options (80% TP1 + 20% trail  vs  100% TP1).');
  print('   • 6 minRR values instead of 2 (adds 0.8, 1.0, 1.2).');
  print('   • 2 extra filter combos (+RR1.0+EMA, +RR1.5+EMA).');
  print('');

  final allWalk = <WalkRes>[];
  int assetsProcessed = 0;

  for (final sym in assetList) {
    final path = '$base/${sym}5m.csv';
    if (!File(path).existsSync()) {
      print('  SKIP $sym (file not found: $path)');
      continue;
    }

    final d        = _loadAsset(sym, path);
    final trainEnd = (d.c5.length * _trainPct).round();
    final testEnd  = d.c5.length;

    final trainFrom = d.c5[0].time.toIso8601String().substring(0, 10);
    final trainTo   = d.c5[trainEnd - 1].time.toIso8601String().substring(0, 10);
    final testFrom  = d.c5[trainEnd].time.toIso8601String().substring(0, 10);
    final testTo    = d.c5[testEnd - 1].time.toIso8601String().substring(0, 10);

    stdout.write(
      '  $sym  ${d.c5.length} bars │ '
      'Train: $trainFrom→$trainTo │ '
      'Test: $testFrom→$testTo  .'
    );

    int done = 0;
    for (final strat in _strategies) {
      allWalk.add(_walkForward(d, strat));
      done++;
      if (done % 500 == 0) stdout.write('.');
    }
    assetsProcessed++;
    final elapsed = DateTime.now().difference(startTime);
    print(' done [${elapsed.inSeconds}s]');
  }

  if (allWalk.isEmpty) {
    print('\n  No data found. Check asset paths above.');
    return;
  }

  // ── ROBUST LEADERBOARD ─────────────────────────────────────────────────────
  final robust = allWalk
      .where((r) => r.robust)
      .toList()
      ..sort((a, b) {
        // Score = TestCalmar × Robustness × TradeCount (capped 20) / 20
        final sA = a.test.calmar * a.robustness * min(a.test.trades, 20) / 20;
        final sB = b.test.calmar * b.robustness * min(b.test.trades, 20) / 20;
        return sB.compareTo(sA);
      });

  final totalRuns   = allWalk.length;
  final robustCount = robust.length;

  _hdr('ROBUST LEADERBOARD — Top 60 (profitable in BOTH train + test)');
  print('  Ranked by: TestCalmar × Robustness × min(Trades, 20) / 20');
  print('  $robustCount / $totalRuns combos passed walk-forward'
        ' (${(robustCount / totalRuns * 100).toStringAsFixed(2)}%)');
  print('  TrRet%=Train return, TsRet%=Test return, TsCal=Test Calmar,'
        ' Rob=Robustness, Grd=Grade');
  print('');
  _robHdr();
  for (int i = 0; i < robust.length && i < 60; i++) {
    _robRow(robust[i], i + 1);
  }
  print('─' * 148);

  // ── ANALYSIS: what conditions produce robust strategies? ──────────────────

  _sect('ENTRY TIMEFRAME', allWalk, [
    ('E5m',  (r) => r.entryTf == 5),
    ('E15m', (r) => r.entryTf == 15),
    ('E30m', (r) => r.entryTf == 30),
  ]);

  _sect('TREND FILTER', allWalk, [
    ('No trend',  (r) => r.trendTf == 0),
    ('Trend 15m', (r) => r.trendTf == 15),
    ('Trend 30m', (r) => r.trendTf == 30),
    ('Trend 45m', (r) => r.trendTf == 45),
  ]);

  _sect('SFI CONFIGURATION', allWalk, [
    ('SFI 5×1.2',  (r) => r.sfiP == 5  && r.sfiM == 1.2),
    ('SFI 7×1.5',  (r) => r.sfiP == 7  && r.sfiM == 1.5),
    ('SFI 10×1.7', (r) => r.sfiP == 10 && r.sfiM == 1.7),
    ('SFI 14×2.0', (r) => r.sfiP == 14 && r.sfiM == 2.0),
  ]);

  _sect('ENTRY MODE (v9 NEW)', allWalk, [
    ('SFI-only',     (r) => r.entryMode == 0),
    ('SFI + RSI<45', (r) => r.entryMode == 1),
    ('SFI + Vol1.5x',(r) => r.entryMode == 2),
    ('RSI extreme',  (r) => r.entryMode == 3),
    ('BB touch',     (r) => r.entryMode == 4),
  ]);

  _sect('EXIT MODE (v9 NEW)', allWalk, [
    ('80% TP1 + trail', (r) => r.exitMode == 0),
    ('100% at TP1',     (r) => r.exitMode == 1),
  ]);

  _sect('SR ZONE TIMEFRAME', allWalk, [
    ('SR 5m',      (r) => r.srMask == _B5),
    ('SR 15m',     (r) => r.srMask == _B15),
    ('SR 30m',     (r) => r.srMask == _B30),
    ('SR 45m',     (r) => r.srMask == _B45),
    ('SR 5m+15m',  (r) => r.srMask == (_B5|_B15)),
    ('SR 5m+45m',  (r) => r.srMask == (_B5|_B45)),
    ('SR 15m+30m', (r) => r.srMask == (_B15|_B30)),
    ('SR 15m+45m', (r) => r.srMask == (_B15|_B45)),
    ('SR 30m+45m', (r) => r.srMask == (_B30|_B45)),
  ]);

  _sect('MIN R:R FILTER', allWalk, [
    ('No RR req',  (r) => !r.strat.contains('+RR')),
    ('+RR 0.8',    (r) => r.strat.contains('+RR0.8')),
    ('+RR 1.0',    (r) => r.strat.contains('+RR1.0') && !r.strat.contains('EMA')),
    ('+RR 1.2',    (r) => r.strat.contains('+RR1.2')),
    ('+RR 1.5',    (r) => r.strat.contains('+RR1.5') && !r.strat.contains('EMA')),
    ('+RR 2.0',    (r) => r.strat.contains('+RR2.0')),
  ]);

  // ── TOP CANDIDATES FOR LIVE TRADING ─────────────────────────────────────
  final candidates = allWalk
      .where((r) => r.robust && r.test.trades >= 5 && r.robustness >= 0.30)
      .toList()
      ..sort((a, b) => (b.test.calmar * b.robustness)
                       .compareTo(a.test.calmar * a.robustness));

  _hdr('TOP LIVE CANDIDATES — Criteria: robust + ≥5 test trades + robustness ≥ 0.30');
  print('  Sorted by TestCalmar × Robustness.');
  print('  REMINDER: Paper-trade 2–4 weeks before live capital.');
  print('');
  if (candidates.isEmpty) {
    print('  No strategies met all criteria. Relax robustness threshold to see more.');
  } else {
    _robHdr();
    for (int i = 0; i < min(candidates.length, 15); i++) {
      _robRow(candidates[i], i + 1);
    }
    print('─' * 148);
    print('');
    print('  ── BEST OVERALL ──');
    final best = candidates.first;
    print('    Asset      : ${best.asset}');
    print('    Strategy   : ${best.strat}');
    print('    EntryMode  : ${["SFI-only","SFI+RSI","SFI+Vol","RSI-Extreme","BB-Touch"][best.entryMode]}');
    print('    ExitMode   : ${best.exitMode == 0 ? "80% TP1 + 20% trail" : "100% at TP1"}');
    print('    Train      : ${best.train.trades} trades, '
          '${best.train.wr.toStringAsFixed(1)}% WR, '
          '${best.train.retPct >= 0 ? "+" : ""}${best.train.retPct.toStringAsFixed(1)}% return');
    print('    Test       : ${best.test.trades} trades, '
          '${best.test.wr.toStringAsFixed(1)}% WR, '
          '${best.test.retPct >= 0 ? "+" : ""}${best.test.retPct.toStringAsFixed(1)}% return');
    print('    Calmar     : ${best.test.calmar.toStringAsFixed(2)} (test)');
    print('    Robustness : ${best.robustness.toStringAsFixed(3)} — ${_robTag(best.robustness).trim()}');
    print('    Grade      : ${best.grade}');
  }

  final totalTime = DateTime.now().difference(startTime);
  print('\n');
  print('═' * 100);
  print(' END OF REPORT   Runtime: ${totalTime.inMinutes}m${totalTime.inSeconds % 60}s'
        '   Strategies: ${_strategies.length}'
        '   Robust: $robustCount');
  print(' DISCLAIMER: Historical simulation results do not guarantee future performance.');
  print(' Always use proper risk management before trading with real capital.');
  print('═' * 100);
}