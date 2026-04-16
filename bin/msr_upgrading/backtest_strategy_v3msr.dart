// =============================================================================
// STRATEGY HUNT V3 — SR + SFI + Extra Indicators, Multi-Timeframe
// =============================================================================
//
// Tests 16 reversal strategies across 7 assets.
// Each strategy is a different combination of:
//   - SR timeframes     : 45m only | 45m+15m | 45m+15m+5m
//   - SFI entry trigger : 5m flip  | 15m flip
//   - Trend bias        : 45m+15m  | 45m only | none
//   - Extra filters     : Rejection candle | RSI | EMA200 | Volume | R:R
//   - TP mode           : 80/20 split | 100% at zone
//
// EXTRA INDICATORS:
//   RSI(14)   on 15m → reversal confirmation (oversold / overbought)
//   EMA(50)   on 45m → medium-term trend
//   EMA(200)  on 45m → major trend direction
//   Vol SMA   on 5m  → volume spike at entry
//   Rej candle filter → wick-to-body ratio at flip bar
//
// ALL BIAS-FREE (v5 rules throughout):
//   - Indicator uses signals[i-1] (previous bar)
//   - Fills at next bar's open
//   - SL wins same-bar TP+SL conflict
//   - Funding 0.01%/8h, commission 0.025%, slippage 0.04%
//
// OUTPUT:
//   Prints all 16 strategies per asset, then a master leaderboard
//   sorted by Calmar ratio.
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
const _dep        = _notional * _leverage; // 500 USDT
const _commission = 0.025;
const _slippage   = 0.04;
const _funding    = 0.01;
const _cooldown   = 6;      // 5m bars (= 30 min)
const _proxPct    = 0.8;    // % from zone edge to qualify as "near"
const _slBuf      = 0.2;    // % beyond zone for SL
const _atrFb      = 2.0;    // ATR fallback multiplier when no zone found

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY DEFINITION
// ─────────────────────────────────────────────────────────────────────────────

class Strat {
  final String  name;
  final int     srMask;      // bitmask: 1=5m zones, 2=15m zones, 4=45m zones
  final int     entryTfMin;  // 5 or 15 — which TF's SFI flip triggers entry
  final bool    bias45;      // filter: 45m SFI must agree
  final bool    bias15;      // filter: 15m SFI must agree
  final bool    rejCandle;   // filter: wick rejection at flip bar
  final bool    rsiFilter;   // filter: RSI oversold/overbought on 15m
  final double  rsiLevel;    // RSI threshold (e.g. 45 for long < 45, short > 100-45)
  final bool    emaFilter;   // filter: price must be above/below EMA200 on 45m
  final bool    volFilter;   // filter: volume spike > 1.3× SMA
  final double  minRR;       // min risk:reward ratio (0 = no filter)
  final double  tp1Split;    // 0.8 = 80/20, 1.0 = 100% close at TP1

  const Strat({
    required this.name,
    required this.srMask,
    this.entryTfMin = 5,
    this.bias45     = true,
    this.bias15     = true,
    this.rejCandle  = false,
    this.rsiFilter  = false,
    this.rsiLevel   = 45.0,
    this.emaFilter  = false,
    this.volFilter  = false,
    this.minRR      = 0.0,
    this.tp1Split   = 0.8,
  });
}

// 16 strategies to test
final _strategies = <Strat>[
  // ── SR zone combinations ──────────────────────────────────────────────────
  Strat(name: 'S01 SR45+SFI5+Bias45+15',         srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true),
  Strat(name: 'S02 SR45+SFI5+Bias45only',         srMask: 4,  entryTfMin:  5, bias45: true,  bias15: false),
  Strat(name: 'S03 SR45+15+SFI5+Bias45+15',       srMask: 6,  entryTfMin:  5, bias45: true,  bias15: true),
  Strat(name: 'S04 SR45+SFI15+Bias45',            srMask: 4,  entryTfMin: 15, bias45: true,  bias15: false),
  Strat(name: 'S05 SR45+15+SFI15+Bias45',         srMask: 6,  entryTfMin: 15, bias45: true,  bias15: false),

  // ── Rejection candle filter ───────────────────────────────────────────────
  Strat(name: 'S06 SR45+SFI5+Rej',                srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  rejCandle: true),
  Strat(name: 'S07 SR45+15+SFI5+Rej',             srMask: 6,  entryTfMin:  5, bias45: true,  bias15: true,  rejCandle: true),
  Strat(name: 'S08 SR45+SFI15+Rej',               srMask: 4,  entryTfMin: 15, bias45: true,  bias15: false, rejCandle: true),

  // ── RSI filter ───────────────────────────────────────────────────────────
  Strat(name: 'S09 SR45+SFI5+RSI45',              srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  rsiFilter: true,  rsiLevel: 45.0),
  Strat(name: 'S10 SR45+SFI5+RSI40',              srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  rsiFilter: true,  rsiLevel: 40.0),

  // ── EMA200 filter ────────────────────────────────────────────────────────
  Strat(name: 'S11 SR45+SFI5+EMA200',             srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  emaFilter: true),
  Strat(name: 'S12 SR45+15+SFI5+EMA200',          srMask: 6,  entryTfMin:  5, bias45: true,  bias15: true,  emaFilter: true),

  // ── R:R filter ───────────────────────────────────────────────────────────
  Strat(name: 'S13 SR45+SFI5+RR1.5',              srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  minRR: 1.5),
  Strat(name: 'S14 SR45+SFI5+RR2.0',              srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,  minRR: 2.0),

  // ── Combo filters ────────────────────────────────────────────────────────
  Strat(name: 'S15 SR45+SFI5+Rej+RSI+EMA',        srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,
        rejCandle: true, rsiFilter: true, rsiLevel: 45.0, emaFilter: true),
  Strat(name: 'S16 SR45+SFI5+Rej+RR1.5+EMA',      srMask: 4,  entryTfMin:  5, bias45: true,  bias15: true,
        rejCandle: true, emaFilter: true, minRR: 1.5),
];

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String  asset, strat;
  final int     trades, wins;
  final double  netPnl, grossPnl, fees, slip, fund;
  final double  returnPct, maxDdPct, calmar;
  final String  grade;
  Res({required this.asset, required this.strat,
       required this.trades, required this.wins,
       required this.netPnl, required this.grossPnl,
       required this.fees, required this.slip, required this.fund,
       required this.returnPct, required this.maxDdPct,
       required this.calmar, required this.grade});
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

List<Candle> _agg(List<Candle> c, int m) {
  final out = <Candle>[];
  for (int i = 0; i + m - 1 < c.length; i += m) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < m; j++) { hi = max(hi, c[i+j].high); lo = min(lo, c[i+j].low); vol += c[i+j].volume; }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i+m-1].close, vol, out.length));
  }
  return out;
}

// _sim5m removed — using real 5m data instead

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS — all rolling O(n), no look-ahead
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
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low, max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i-1] * (p - 1) + tr[i]) / p); }
  }
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT = 1;
  final out = <SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m*a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m*a;
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
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low, max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i-1] * (p - 1) + tr[i]) / p); }
  }
  return atr;
}

List<double> _ema(List<Candle> cs, int p) {
  final k = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i-1] * (1 - k));
  }
  return out;
}

List<double> _rsi(List<Candle> cs, int p) {
  final out = <double>[];
  double ag = 0, al = 0;
  for (int i = 0; i < cs.length; i++) {
    final chg  = i == 0 ? 0.0 : cs[i].close - cs[i-1].close;
    final gain = chg > 0 ? chg : 0.0;
    final loss = chg < 0 ? -chg : 0.0;
    if (i == 0) { ag = gain; al = loss; out.add(50.0); continue; }
    ag = (ag * (p - 1) + gain) / p;
    al = (al * (p - 1) + loss) / p;
    out.add(al == 0 ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al));
  }
  return out;
}

// Rolling 20-bar volume SMA (from previous bars only)
List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  final buf = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(buf.length < p ? 0.0 : buf.fold(0.0, (s, v) => s + v) / buf.length);
    buf.add(cs[i].volume);
    if (buf.length > p) buf.removeAt(0);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR ZONE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<SRZone> _knSup(List<SRZone> z, int bar, int len) =>
    z.where((s) => !s.isResistance && s.boxLeft + len <= bar && !s.b).toList();
List<SRZone> _knRes(List<SRZone> z, int bar, int len) =>
    z.where((s) => s.isResistance  && s.boxLeft + len <= bar && !s.b).toList();

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

// ─────────────────────────────────────────────────────────────────────────────
// REJECTION CANDLE CHECK
// ─────────────────────────────────────────────────────────────────────────────

bool _rejLong(Candle c) {
  final body = (c.close - c.open).abs();
  final lWick = min(c.open, c.close) - c.low;
  final total = c.high - c.low;
  if (total <= 0) return false;
  // Lower wick >= 1.5× body AND close in upper 50% of candle
  return lWick >= body * 1.5 && c.close >= c.low + total * 0.5;
}

bool _rejShort(Candle c) {
  final body = (c.close - c.open).abs();
  final uWick = c.high - max(c.open, c.close);
  final total = c.high - c.low;
  if (total <= 0) return false;
  return uWick >= body * 1.5 && c.close <= c.high - total * 0.5;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE
// ─────────────────────────────────────────────────────────────────────────────


// ─────────────────────────────────────────────────────────────────────────────
// BACKTEST ENGINE
// ─────────────────────────────────────────────────────────────────────────────

Res _run(
  String asset, Strat s,
  List<Candle> c5, List<Candle> c15, List<Candle> c45,
  List<SfiSig>  sfi5,  List<SfiSig> sfi15, List<SfiSig> sfi45,
  List<double>  atr5,
  List<double>  rsi15,
  List<double>  ema200_45,
  List<double>  volSma5,
  List<SRZone>  zones45, List<SRZone> zones15, List<SRZone> zones5,
  int srLen45, int srLen15, int srLen5,
  Map<int, int> map5to15, Map<int, int> map5to45,
) {
  double netEq = 0, grossEq = 0, totFee = 0, totSlp = 0, totFund = 0;
  double peak = 0, maxDd = 0;
  int wins = 0, tradeCount = 0, cd = 0;
  _T? active;
  bool pendL = false, pendS = false;
  DateTime lastFund = DateTime(2000);

  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i15 = map5to15[i] ?? 0;
    final i45 = map5to45[i] ?? 0;

    // ── Previous-bar signals (bias-free) ──────────────────────────────────
    final sf5p  = sfi5[i - 1];
    final sf5c  = sfi5[i];
    final sf15  = i15 > 0 ? sfi15[i15 - 1] : sfi15[0];
    final sf45  = i45 > 0 ? sfi45[i45 - 1] : sfi45[0];

    // ── SR zones known at this bar ────────────────────────────────────────
    final sup45 = (s.srMask & 4) != 0 ? _knSup(zones45, i45, srLen45) : <SRZone>[];
    final res45 = (s.srMask & 4) != 0 ? _knRes(zones45, i45, srLen45) : <SRZone>[];
    final sup15 = (s.srMask & 2) != 0 ? _knSup(zones15, i15, srLen15) : <SRZone>[];
    final res15 = (s.srMask & 2) != 0 ? _knRes(zones15, i15, srLen15) : <SRZone>[];
    final sup5c = (s.srMask & 1) != 0 ? _knSup(zones5, i, srLen5)     : <SRZone>[];
    final res5c = (s.srMask & 1) != 0 ? _knRes(zones5, i, srLen5)     : <SRZone>[];
    final allSup = [...sup45, ...sup15, ...sup5c];
    final allRes = [...res45, ...res15, ...res5c];

    // ── Fill pending at next bar's open ───────────────────────────────────
    if (active == null && cd == 0 && (pendL || pendS)) {
      final dir  = pendL ? 1 : -1;
      pendL = pendS = false;
      final fill = c.open;
      final atr  = atr5[i];

      final entSup = _nSup(allSup, fill);
      final entRes = _nRes(allRes, fill);
      double slP, tp1P;

      if (dir == 1) {
        slP  = entSup != null ? entSup.boxBottom * (1 - _slBuf / 100) : fill - _atrFb * atr;
        tp1P = entRes != null ? entRes.boxBottom : fill + _atrFb * atr;
      } else {
        slP  = entRes != null ? entRes.boxTop * (1 + _slBuf / 100) : fill + _atrFb * atr;
        tp1P = entSup != null ? entSup.boxTop  : fill - _atrFb * atr;
      }

      final validL = dir == 1  && tp1P > fill && fill > slP;
      final validS = dir == -1 && tp1P < fill && fill < slP;

      // R:R filter
      bool rrOk = true;
      if (s.minRR > 0 && (validL || validS)) {
        final reward = (tp1P - fill).abs();
        final risk   = (fill - slP).abs();
        rrOk = risk > 0 && reward / risk >= s.minRR;
      }

      if ((validL || validS) && rrOk) {
        final tObj = _T(dir: dir, entry: fill,
            qty: _dep / fill, tp1: tp1P, sl: slP);
        final ef = _dep * _commission / 100;
        final es = _dep * _slippage   / 100;
        tObj.fee += ef; tObj.slp += es; totFee += ef; totSlp += es;
        active = tObj;
        tradeCount++;
      }
    } else if (active == null) {
      pendL = pendS = false;
    }

    // ── Funding ───────────────────────────────────────────────────────────
    if (active != null && active!.open && c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final f  = _dep * _funding / 100;
      active!.fund += f; totFund += f;
    }

    // ── TP/SL ─────────────────────────────────────────────────────────────
    if (active != null && active!.open) {
      final t   = active!;
      final tpH = t.dir == 1 ? c.high >= t.tp1 : c.low  <= t.tp1;
      final slH = t.dir == 1 ? c.low  <= t.sl  : c.high >= t.sl;
      final sp  = s.tp1Split;

      if (slH) {
        // SL wins (even if TP also hit same bar)
        final gp = t.dir == 1
            ? (t.sl - t.entry) / t.entry * _dep * (t.tp1Hit ? (1 - sp) : 1.0)
            : (t.entry - t.sl) / t.entry * _dep * (t.tp1Hit ? (1 - sp) : 1.0);
        final rem = t.tp1Hit ? (1 - sp) : 1.0;
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
        // TP1 hit
        t.tp1Hit = true;
        t.tp1P   = t.tp1;
        final gp80 = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * _dep * sp
            : (t.entry - t.tp1) / t.entry * _dep * sp;
        final xf = _dep * sp * _commission / 100;
        final xs = _dep * sp * _slippage   / 100;
        t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
        grossEq += gp80; netEq += gp80 - xf - xs;

        // If tp1Split=1.0 close entire position now
        if (sp >= 1.0) {
          t.exitP  = t.tp1;
          t.reason = 'TP1';
          t.pnl    = gp80 - t.fee - t.slp - t.fund;
          netEq   -= t.fund;
          if (t.pnl > 0) wins++;
          active = null;
        }

      } else if (t.tp1Hit && sp < 1.0) {
        // Trail remaining (1-sp) until SFI reverses
        final reversed = t.dir == 1 ? sf5p.sell : sf5p.buy;
        if (reversed) {
          final rem   = 1 - sp;
          final gp20  = t.dir == 1
              ? (c.close - t.entry) / t.entry * _dep * rem
              : (t.entry - c.close) / t.entry * _dep * rem;
          final xf    = _dep * rem * _commission / 100;
          final xs    = _dep * rem * _slippage   / 100;
          t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
          grossEq += gp20;
          netEq   += gp20 - xf - xs - t.fund;
          t.exitP  = c.close;
          t.reason = 'TP1+FLIP';
          t.pnl    = (t.dir==1?(t.tp1P-t.entry)/t.entry*_dep*sp:(t.entry-t.tp1P)/t.entry*_dep*sp)
              + gp20 - t.fee - t.slp - t.fund;
          if (t.pnl > 0) wins++;
          active   = null;
        }
      }
    }

    // ── Drawdown ──────────────────────────────────────────────────────────
    if (active != null && active!.open) {
      final t   = active!;
      final rem = t.tp1Hit ? (1 - s.tp1Split) : 1.0;
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

    // ── Entry signal detection ────────────────────────────────────────────
    if (active == null && cd == 0 && !pendL && !pendS) {
      // Determine flip based on entry timeframe
      bool buyFlip, sellFlip;
      Candle flipBar;
      if (s.entryTfMin == 5) {
        buyFlip  = sf5c.buy;
        sellFlip = sf5c.sell;
        flipBar  = c5[i];
      } else {
        // 15m entry: SFI15 flip at close of 15m bar, fill at first 5m of next 15m bar
        // Detect 15m boundary: current 5m maps to different 15m than next 5m
        final isLast15 = (i + 1 < c5.length) && (map5to15[i + 1] != i15);
        buyFlip  = isLast15 && (i15 > 0 ? sfi15[i15].buy  : false);
        sellFlip = isLast15 && (i15 > 0 ? sfi15[i15].sell : false);
        flipBar  = i15 < c15.length ? c15[i15] : c;
      }

      // Trend bias filters
      if (s.bias45 && s.bias15) {
        if (!buyFlip  || sf45.trend < 0 || sf15.trend < 0) buyFlip  = false;
        if (!sellFlip || sf45.trend > 0 || sf15.trend > 0) sellFlip = false;
      } else if (s.bias45) {
        if (!buyFlip  || sf45.trend < 0) buyFlip  = false;
        if (!sellFlip || sf45.trend > 0) sellFlip = false;
      }

      // Rejection candle filter (on the flip bar itself)
      if (s.rejCandle) {
        if (buyFlip  && !_rejLong(flipBar))  buyFlip  = false;
        if (sellFlip && !_rejShort(flipBar)) sellFlip = false;
      }

      // RSI filter (on 15m, previous bar)
      if (s.rsiFilter && i15 > 0) {
        final rsi = rsi15[i15 - 1];
        if (buyFlip  && rsi > s.rsiLevel)          buyFlip  = false;
        if (sellFlip && rsi < (100 - s.rsiLevel))  sellFlip = false;
      }

      // EMA200 filter (on 45m, previous bar)
      if (s.emaFilter && i45 > 0) {
        final ema = ema200_45[i45 - 1];
        if (buyFlip  && c.close < ema) buyFlip  = false;
        if (sellFlip && c.close > ema) sellFlip = false;
      }

      // Volume filter
      if (s.volFilter) {
        final vs = volSma5[i];
        if (vs > 0 && c.volume < vs * 1.3) { buyFlip = false; sellFlip = false; }
      }

      // SR proximity check
      if (buyFlip) {
        final ns = _nSup(allSup, c.close);
        if (ns == null || !_near(ns, c.close, _proxPct)) buyFlip = false;
      }
      if (sellFlip) {
        final nr = _nRes(allRes, c.close);
        if (nr == null || !_near(nr, c.close, _proxPct)) sellFlip = false;
      }

      if (buyFlip)  pendL = true;
      if (sellFlip) pendS = true;
    }
  }

  // ── Force-close ───────────────────────────────────────────────────────────
  if (active != null && active!.open) {
    final t   = active!;
    final rem = t.tp1Hit ? (1 - s.tp1Split) : 1.0;
    final ep  = c5.last.close;
    final gp  = t.dir == 1
        ? (ep - t.entry) / t.entry * _dep * rem
        : (t.entry - ep) / t.entry * _dep * rem;
    final xf = _dep * rem * _commission / 100;
    final xs = _dep * rem * _slippage   / 100;
    t.fee += xf; t.slp += xs; totFee += xf; totSlp += xs;
    grossEq += gp; netEq += gp - xf - xs - t.fund;
    t.pnl = gp - xf - xs - t.fund;
    if (t.pnl > 0) wins++;
    tradeCount++;
    active = null;
  }

  final retPct = _dep > 0 ? netEq / _dep * 100 : 0.0;
  final ddPct  = _dep > 0 ? maxDd / _dep * 100  : 0.0;
  final calmar = ddPct.abs() > 0 ? retPct / ddPct.abs() : 0.0;
  final grade  = calmar >= 5 && retPct >= 50 ? 'A★★★'
               : calmar >= 3 && retPct >= 30 ? 'B★★'
               : calmar >= 1 && retPct >= 10 ? 'C★'
               : netEq > 0                   ? 'D'
               : 'F';
  return Res(asset: asset, strat: s.name, trades: tradeCount, wins: wins,
      netPnl: netEq, grossPnl: grossEq, fees: totFee, slip: totSlp, fund: totFund,
      returnPct: retPct, maxDdPct: ddPct.abs(), calmar: calmar, grade: grade);
}

class _T {
  final int dir;
  final double entry, qty, tp1, sl;
  bool   tp1Hit = false;
  double tp1P = 0, exitP = 0;
  String reason = '';
  double fee = 0, slp = 0, fund = 0, pnl = 0;
  bool get open => reason.isEmpty;
  _T({required this.dir, required this.entry,
      required this.qty, required this.tp1, required this.sl});
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
        const base15 = '/Users/ayush/Desktop/candlestick data/15m';
        const base5 = '/Users/ayush/Desktop/candlestick data/5m';
  const srLen45 = 10, srLen15 = 12, srLen5 = 8;

  final assets = [
    'ADAUSDT', 'APTUSDT', 'ASTERUSDT', 'BCHUSDT', 'BNBUSDT', 'BTCUSDT',
    'CFXUSDT', 'DOGEUSDT', 'ENAUSDT', 'ETHUSDT', 'HBARUSDT', 'ICPUSDT',
    'LTCUSDT', 'MYXUSDT', 'QNTUSDT', 'SOLUSDT', 'SUIUSDT', 'TRBUSDT',
    'TRXUSDT', 'XMRUSDT', 'XRPUSDT',
  ];

  final allRes = <Res>[];

  for (final sym in assets) {

    final path15 = '$base15/${sym}15m.csv';
    final path5  = '$base5/${sym}5m.csv';
    if (!File(path15).existsSync()) { print('SKIP $sym (no 15m)'); continue; }
    if (!File(path5).existsSync())  { print('SKIP $sym (no 5m)'); continue; }
    stdout.write('  $sym ... ');

    final c15 = _clean(_loadCsv(path15), 15);
    final c45 = _agg(c15, 3);                  // 45m aggregated from real 15m
    final c5  = _clean(_loadCsv(path5), 5);    // real 5m data

    // ── Build timestamp→index maps for cross-TF alignment ────────────────
    // 5m bar i maps to whichever 15m/45m bar contains its timestamp
    final map5to15 = <int, int>{};
    final map5to45 = <int, int>{};
    for (int i = 0; i < c5.length; i++) {
      final t = c5[i].time;
      // Find 15m bar: floor to 15m boundary
      int best15 = 0;
      for (int j = best15; j < c15.length; j++) {
        if (c15[j].time.isAfter(t)) break;
        best15 = j;
      }
      map5to15[i] = best15;
      // Find 45m bar
      int best45 = 0;
      for (int j = best45; j < c45.length; j++) {
        if (c45[j].time.isAfter(t)) break;
        best45 = j;
      }
      map5to45[i] = best45;
    }

    // ── Indicators (computed once per asset) ──────────────────────────────
    final sfi5    = _sfi(c5,  10, 1.7);
    final sfi15   = _sfi(c15, 10, 1.7);
    final sfi45   = _sfi(c45, 10, 1.7);
    final atr5    = _atrList(c5, 14);
    final rsi15   = _rsi(c15, 14);
    final ema200  = _ema(c45, 200);
    final vSma5   = _volSma(c5, 20);

    // ── SR zones (computed once per asset) ───────────────────────────────
    final sr45 = SupportResistanceIndicator(
        detectionLength: srLen45, srMargin: 2.0, avoidFBO: true, checkHist: true);
    final res45 = sr45.calculate(c45);
    final zones45 = [...res45.support, ...res45.resistance];

    final sr15 = SupportResistanceIndicator(
        detectionLength: srLen15, srMargin: 2.0, avoidFBO: true, checkHist: true);
    final res15 = sr15.calculate(c15);
    final zones15 = [...res15.support, ...res15.resistance];

    final sr5 = SupportResistanceIndicator(
        detectionLength: srLen5, srMargin: 2.0, avoidFBO: true, checkHist: true);
    final res5 = sr5.calculate(c5);
    final zones5 = [...res5.support, ...res5.resistance];

    stdout.write('zones(${zones45.length}+${zones15.length}+${zones5.length}) → ');

    // ── Run all strategies ────────────────────────────────────────────────
    for (final strat in _strategies) {
      final r = _run(sym, strat, c5, c15, c45,
          sfi5, sfi15, sfi45, atr5, rsi15, ema200, vSma5,
          zones45, zones15, zones5, srLen45, srLen15, srLen5,
          map5to15, map5to45);
      allRes.add(r);
    }
    print('done (${_strategies.length} strategies)');
  }

  // ── PER-ASSET TABLE ───────────────────────────────────────────────────────
  final assets2 = allRes.map((r) => r.asset).toSet().toList();
  for (final sym in assets2) {
    final assetRes = allRes.where((r) => r.asset == sym).toList()
        ..sort((a, b) => b.calmar.compareTo(a.calmar));

    print('\n');
    _hdr('PER-ASSET: $sym');
    _tblHdr();
    for (final r in assetRes) _tblRow(r);
    _tblFoot();
  }

  // ── MASTER LEADERBOARD ───────────────────────────────────────────────────
  final profitable = allRes.where((r) => r.netPnl > 0).toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));

  print('\n');
  _hdr('MASTER LEADERBOARD — ALL ASSETS × ALL STRATEGIES (profitable only, sorted by Calmar)');
  _tblHdr();
  for (int i = 0; i < profitable.length && i < 50; i++) _tblRow(profitable[i], rank: i + 1);
  _tblFoot();

  // ── STRATEGY SUMMARY ─────────────────────────────────────────────────────
  print('\n── STRATEGY SUMMARY ───────────────────────────────────────────────');
  print('${'Strategy'.padRight(35)} │ Profit% │ AvgCalmar │ BestCalmar │ A  B  C  D');
  print('─' * 80);
  for (final strat in _strategies) {
    final rs    = allRes.where((r) => r.strat == strat.name).toList();
    final prof  = rs.where((r) => r.netPnl > 0).length;
    final pct   = rs.isEmpty ? 0 : (prof / rs.length * 100).round();
    final avgC  = rs.isEmpty ? 0 : rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
    final bestC = rs.isEmpty ? 0 : rs.map((r) => r.calmar).reduce(max);
    final aG    = rs.where((r) => r.grade == 'A★★★').length;
    final bG    = rs.where((r) => r.grade == 'B★★').length;
    final cG    = rs.where((r) => r.grade == 'C★').length;
    final dG    = rs.where((r) => r.grade == 'D').length;
    print('${strat.name.padRight(35)} │  ${'$pct%'.padLeft(5)} │ ${avgC.toStringAsFixed(2).padLeft(9)} │ ${bestC.toStringAsFixed(2).padLeft(10)} │ $aG  $bG  $cG  $dG');
  }

  // ── BEST CONFIG ──────────────────────────────────────────────────────────
  if (profitable.isNotEmpty) {
    final best = profitable.first;
    print('\n── BEST OVERALL ────────────────────────────────────────────────────');
    print('  Asset     : ${best.asset}');
    print('  Strategy  : ${best.strat}');
    print('  Trades    : ${best.trades}  WR: ${best.wr.toStringAsFixed(1)}%');
    print('  Net PnL   : \$${best.netPnl.toStringAsFixed(2)}');
    print('  Return    : ${best.returnPct.toStringAsFixed(1)}%');
    print('  Max DD    : ${best.maxDdPct.toStringAsFixed(1)}%');
    print('  Calmar    : ${best.calmar.toStringAsFixed(2)}');
    print('  Grade     : ${best.grade}');
    print('  Costs     : fees \$${best.fees.toStringAsFixed(2)}  slip \$${best.slip.toStringAsFixed(2)}  fund \$${best.fund.toStringAsFixed(2)}');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  const w = 110;
  final p = ((w - t.length - 2) / 2).floor();
  print('═' * p + ' $t ' + '═' * (w - p - t.length - 2));
}

void _tblHdr() {
  print('${'#'.padLeft(3)} │ ${'Asset'.padRight(9)} │ ${'Strategy'.padRight(34)} │ ${'Trd'.padLeft(4)} │ ${'WR%'.padLeft(5)} │ ${'Net\$'.padLeft(8)} │ ${'Ret%'.padLeft(6)} │ ${'DD%'.padLeft(5)} │ ${'Calmar'.padLeft(7)} │ ${'Costs\$'.padLeft(7)} │ Grade');
  print('─' * 115);
}

void _tblRow(Res r, {int? rank}) {
  final n   = rank != null ? rank.toString().padLeft(3) : '   ';
  final tr  = r.trades.toString().padLeft(4);
  final wr  = '${r.wr.toStringAsFixed(1)}%'.padLeft(5);
  final np  = '${r.netPnl >= 0 ? "+" : ""}\$${r.netPnl.toStringAsFixed(1)}'.padLeft(8);
  final rp  = '${r.returnPct >= 0 ? "+" : ""}${r.returnPct.toStringAsFixed(1)}%'.padLeft(6);
  final dd  = '${r.maxDdPct.toStringAsFixed(1)}%'.padLeft(5);
  final cal = r.calmar.toStringAsFixed(2).padLeft(7);
  final cost = '\$${(r.fees + r.slip + r.fund).toStringAsFixed(1)}'.padLeft(7);
  print('$n │ ${r.asset.padRight(9)} │ ${r.strat.padRight(34)} │$tr  │$wr  │$np  │$rp  │$dd  │$cal  │$cost  │ ${r.grade}');
}

void _tblFoot() => print('─' * 115);
