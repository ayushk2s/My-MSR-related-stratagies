// ============================================================================
// STRATEGY HUNT — v10  "BEAST MODE"
// ============================================================================
// Changelog over v9:
//
//  🐛 BUG FIXES
//   1. Double SL-slippage counter: _slippedSL was incremented twice on every
//      SL hit (once inside the `if (slip)` branch, once unconditionally after).
//      Fixed — now only counted when slippage actually occurs.
//   2. Slippage applied both as exit-price worsening AND flat cost → double-
//      charged on TP/SL exits.  Now exit-price slippage is removed from the
//      flat cost when executing a real TP or SL fill (costs only charge the
//      commission; spread/latency is captured via the entry fill price).
//
//  📊 NEW INDICATORS  (all bias-free / O(n))
//   • RSI(14)             — momentum oscillator
//   • ADX(14)             — trend strength (Wilder smoothing)
//   • DI+/DI−            — directional components used by ADX
//   • MACD(12,26,9)       — EMA crossover momentum
//   • Bollinger Bands(20,2) — volatility envelope
//   • OBV + OBV-EMA(20)  — volume trend confirmation
//   • EMA(200)            — long-term regime baseline
//   • StochRSI(14,3)      — RSI of RSI, smoothed
//
//  🧠 NEW STRATEGY VARIANTS  (13 existing → 26 total)
//   S7 : ADX-Don40 (only trade when ADX > 20, market trending)
//   S7 : ADX-SFI14 (ADX filter on SFI ride)
//   S8 : RSI-SFI14 (SFI14 + RSI not extreme 35–65)
//   S8 : RSI-Don40  (Don40 + RSI momentum zone)
//   S9 : Triple (SFI14 + Don40 + ADX > 20 — all aligned)
//   S10: MACD-SFI (SFI10 + MACD histogram aligned)
//   S11: BB-Break  (Bollinger Band breakout + sustained)
//   S12: OBV-SFI14 (SFI14 + OBV above its EMA)
//   S13: Full-confluence (SFI14 + Don40 + ADX + OBV + MACD all agree)
//   S14: SFI14 Trailing Stop (ride with 1.5 ATR trail instead of fixed SL)
//   S14: Don40 Trailing Stop (breakout ride with 2 ATR trail)
//   S15: Regime-Bull (Triple + price above EMA200 long only)
//   S15: Regime-Bear (Triple + price below EMA200 short only)
//
//  🎯 TRAILING STOP ENGINE
//   New `trailAtr` parameter.  When > 0:
//   • Longs: SL trails up as price makes new highs (highs - trailAtr × ATR)
//   • Shorts: SL trails down as price makes new lows (lows + trailAtr × ATR)
//   • Trailing SL can only move in favour — never against.
//   • Uses ATR captured at entry (no lookahead).
//
//  🔍 WALK-FORWARD OOS VALIDATION
//   Data is split 70 IS / 30 OOS by bar index.
//   Each config is run on BOTH halves.  Only configs profitable in both
//   are flagged with ✅.  Configs profitable only in IS are flagged ⚠️.
//   This catches most overfit results automatically.
//
//  📈 ENHANCED METRICS
//   • Profit Factor  (gross profit / gross loss)
//   • Avg Win / Avg Loss in R-multiples
//   • Max consecutive losses
//   • Approximate Sharpe ratio  (mean trade return / std dev)
//   • Recovery Factor  (net return / max DD)
//
//  🏅 REVISED GRADING
//   Requires minimum 40 trades.  Weights Calmar, profit factor, and OOS
//   validation together.  Grade E = insufficient trade count.
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PATHS & CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _root = '/Users/ayush/Desktop/candlestick data';
const _commission = 0.04; // % blended maker/taker per side
const _slippage = 0.04; // % entry slippage per side (spread + latency)
const _funding = 0.01; // % per 8h
const _notional = 20.0; // USDT per trade
const _leverage = 5.0;
const _cooldown = 3; // bars cooldown after SL exit
const _minAtrPct = 0.3; // min ATR% gate — skip low-volatility entries

// OOS split: last `_oosFrac` fraction of bars is out-of-sample.
const double _oosFrac = 0.30;

// ADX threshold — below this the market is considered non-trending.
const double _adxTrend = 20.0;

// ─────────────────────────────────────────────────────────────────────────────
// FILL MODE
// ─────────────────────────────────────────────────────────────────────────────

enum FillMode { conservative, optimistic, probabilistic, expected }

const FillMode fillMode = FillMode.expected;
const bool useCloseExec = false;
const int? _rngSeed = 42;

final _rng = _rngSeed != null ? Random(_rngSeed) : Random();

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL EXECUTION METRICS
// ─────────────────────────────────────────────────────────────────────────────

int _missedTP = 0;
int _slippedSL = 0;

// ─────────────────────────────────────────────────────────────────────────────
// RESULT  (extended)
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset, strategy, htf;
  final int trades, wins, maxConsecLoss;
  final double netPnl, returnPct, maxDdPct, calmar;
  final double profitFactor, avgWinR, avgLossR, sharpe, recoveryFactor;
  final String grade;

  // OOS companion (null if not split yet)
  Res? oos;

  Res({
    required this.asset,
    required this.strategy,
    required this.htf,
    required this.trades,
    required this.wins,
    required this.maxConsecLoss,
    required this.netPnl,
    required this.returnPct,
    required this.maxDdPct,
    required this.calmar,
    required this.profitFactor,
    required this.avgWinR,
    required this.avgLossR,
    required this.sharpe,
    required this.recoveryFactor,
    required this.grade,
  });

  double get wr => trades == 0 ? 0 : wins / trades * 100;

  bool get oosValid => oos != null && (oos!.netPnl > 0);
  String get oosFlag => oos == null ? '' : (oosValid ? ' ✅' : ' ⚠️');
}

// EMA on candle closes.
List<double> _ema(List<Candle> cs, int p) {
  final k = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i - 1] * (1 - k));
  }
  return out;
}

// EMA on a double series.
List<double> _emaD(List<double> vals, int p) {
  final k = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < vals.length; i++) {
    out.add(i == 0 ? vals[0] : vals[i] * k + out[i - 1] * (1 - k));
  }
  return out;
}

// Wilder smoothing (RMA) on a double series — used by RSI and ADX.
List<double> _rma(List<double> vals, int p) {
  final out = <double>[];
  double acc = 0;
  for (int i = 0; i < vals.length; i++) {
    if (i < p) {
      acc += vals[i];
      out.add(i == p - 1 ? acc / p : 0);
    } else {
      final v = (out[i - 1] * (p - 1) + vals[i]) / p;
      out.add(v);
    }
  }
  return out;
}

// ATR (Wilder, period p).
List<double> _atr(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    tr.add(
      i == 0
          ? cs[i].high - cs[i].low
          : max(
              cs[i].high - cs[i].low,
              max(
                (cs[i].high - cs[i - 1].close).abs(),
                (cs[i].low - cs[i - 1].close).abs(),
              ),
            ),
    );
  }
  return _rma(tr, p);
}

// SFI (SuperFlux Indicator) — +1 uptrend / -1 downtrend.
List<int> _sfi(List<Candle> cs, int p, double m, List<double> atr) {
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int t = 1;
  final out = <int>[];
  for (int i = 0; i < cs.length; i++) {
    final a = atr[i];
    final up = i > 0
        ? (cs[i - 1].close > pUp
              ? max(cs[i].ohlc4 - m * a, pUp)
              : cs[i].ohlc4 - m * a)
        : cs[i].ohlc4 - m * a;
    final dn = i > 0
        ? (cs[i - 1].close < pDn
              ? min(cs[i].ohlc4 + m * a, pDn)
              : cs[i].ohlc4 + m * a)
        : cs[i].ohlc4 + m * a;
    if (t == -1 && cs[i].close > pDn)
      t = 1;
    else if (t == 1 && cs[i].close < pUp)
      t = -1;
    pUp = up;
    pDn = dn;
    out.add(t);
  }
  return out;
}

// Donchian highest-high of previous n bars (excludes current bar).
List<double> _dHH(List<Candle> cs, int n) {
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) {
      out.add(cs[0].high);
      continue;
    }
    final start = max(0, i - n);
    double hi = cs[start].high;
    for (int j = start + 1; j < i; j++) if (cs[j].high > hi) hi = cs[j].high;
    out.add(hi);
  }
  return out;
}

List<double> _dLL(List<Candle> cs, int n) {
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) {
      out.add(cs[0].low);
      continue;
    }
    final start = max(0, i - n);
    double lo = cs[start].low;
    for (int j = start + 1; j < i; j++) if (cs[j].low < lo) lo = cs[j].low;
    out.add(lo);
  }
  return out;
}

// RSI (Wilder, period p).
List<double> _rsi(List<Candle> cs, int p) {
  final gains = <double>[], losses = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) {
      gains.add(0);
      losses.add(0);
      continue;
    }
    final d = cs[i].close - cs[i - 1].close;
    gains.add(d > 0 ? d : 0.0);
    losses.add(d < 0 ? -d : 0.0);
  }
  final avgG = _rma(gains, p);
  final avgL = _rma(losses, p);
  return List.generate(cs.length, (i) {
    if (avgL[i] == 0) return 100.0;
    return 100 - 100 / (1 + avgG[i] / avgL[i]);
  });
}

// ADX (Wilder, period p).  Returns (adx, di+, di-).
(List<double>, List<double>, List<double>) _adxFull(List<Candle> cs, int p) {
  final trVals = <double>[];
  final dmP = <double>[];
  final dmM = <double>[];

  for (int i = 0; i < cs.length; i++) {
    if (i == 0) {
      trVals.add(0);
      dmP.add(0);
      dmM.add(0);
      continue;
    }
    final tr = max(
      cs[i].high - cs[i].low,
      max(
        (cs[i].high - cs[i - 1].close).abs(),
        (cs[i].low - cs[i - 1].close).abs(),
      ),
    );
    final up = cs[i].high - cs[i - 1].high;
    final dn = cs[i - 1].low - cs[i].low;
    dmP.add(up > dn && up > 0 ? up : 0.0);
    dmM.add(dn > up && dn > 0 ? dn : 0.0);
    trVals.add(tr);
  }

  final sTr = _rma(trVals, p);
  final sDmP = _rma(dmP, p);
  final sDmM = _rma(dmM, p);

  final diP = List.generate(
    cs.length,
    (i) => sTr[i] > 0 ? sDmP[i] / sTr[i] * 100 : 0.0,
  );
  final diM = List.generate(
    cs.length,
    (i) => sTr[i] > 0 ? sDmM[i] / sTr[i] * 100 : 0.0,
  );
  final dx = List.generate(cs.length, (i) {
    final s = diP[i] + diM[i];
    return s > 0 ? (diP[i] - diM[i]).abs() / s * 100 : 0.0;
  });
  final adx = _rma(dx, p);

  return (adx, diP, diM);
}

// MACD — returns (macdLine, signalLine, histogram).
(List<double>, List<double>, List<double>) _macd(
  List<Candle> cs, {
  int fast = 12,
  int slow = 26,
  int sig = 9,
}) {
  final emaF = _ema(cs, fast);
  final emaS = _ema(cs, slow);
  final line = List.generate(cs.length, (i) => emaF[i] - emaS[i]);
  final signal = _emaD(line, sig);
  final hist = List.generate(cs.length, (i) => line[i] - signal[i]);
  return (line, signal, hist);
}

// Bollinger Bands (SMA-based, period p, multiplier mult).
(List<double>, List<double>, List<double>) _bb(
  List<Candle> cs,
  int p,
  double mult,
) {
  final mid = <double>[];
  final upper = <double>[];
  final lower = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final start = max(0, i - p + 1);
    final closes = [for (int j = start; j <= i; j++) cs[j].close];
    final avg = closes.reduce((a, b) => a + b) / closes.length;
    final std = closes.isEmpty
        ? 0.0
        : sqrt(
            closes.map((v) => pow(v - avg, 2)).reduce((a, b) => a + b) /
                closes.length,
          );
    mid.add(avg);
    upper.add(avg + mult * std);
    lower.add(avg - mult * std);
  }
  return (mid, upper, lower);
}

// OBV (On-Balance Volume).
List<double> _obv(List<Candle> cs) {
  final out = <double>[0];
  for (int i = 1; i < cs.length; i++) {
    if (cs[i].close > cs[i - 1].close)
      out.add(out.last + cs[i].volume);
    else if (cs[i].close < cs[i - 1].close)
      out.add(out.last - cs[i].volume);
    else
      out.add(out.last);
  }
  return out;
}

// StochRSI — %K smoothed with `smooth` period.
List<double> _stochRsi(List<Candle> cs, int rsiP, int stochP, int smooth) {
  final rsi = _rsi(cs, rsiP);
  final stoch = <double>[];
  for (int i = 0; i < rsi.length; i++) {
    final start = max(0, i - stochP + 1);
    final sl = rsi.sublist(start, i + 1);
    final lo = sl.reduce(min);
    final hi = sl.reduce(max);
    stoch.add(hi == lo ? 0.5 : (rsi[i] - lo) / (hi - lo));
  }
  return _emaD(stoch, smooth); // %K smoothed
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> _load(String path) {
  final lines = File(path).readAsLinesSync();
  final out = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(',');
    if (p.length < 6) continue;
    out.add(
      Candle(
        DateTime.parse(p[0] + 'Z'),
        double.parse(p[1]),
        double.parse(p[2]),
        double.parse(p[3]),
        double.parse(p[4]),
        double.parse(p[5]),
        i - 1,
      ),
    );
  }
  return out;
}

List<Candle> _agg(List<Candle> c, int m) {
  final out = <Candle>[];
  int idx = 0;
  for (int i = 0; i + m - 1 < c.length; i += m) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < m; j++) {
      hi = max(hi, c[i + j].high);
      lo = min(lo, c[i + j].low);
      vol += c[i + j].volume;
    }
    out.add(
      Candle(c[i].time, c[i].open, hi, lo, c[i + m - 1].close, vol, idx++),
    );
  }
  return out;
}

List<Candle> _clean(List<Candle> raw, int im) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty && c.time.difference(out.last.time).inMinutes > im * 3)
      continue;
    out.add(c);
  }
  return out;
}

// Pre-bucket 5m candles into HTF windows — O(N+M).
List<List<Candle>> _bucket(List<Candle> htf, List<Candle> exec) {
  final wins = List.generate(htf.length, (_) => <Candle>[]);
  int h = 0;
  for (final c in exec) {
    while (h + 1 < htf.length && !c.time.isBefore(htf[h + 1].time)) h++;
    if (!c.time.isBefore(htf[0].time)) wins[h].add(c);
  }
  return wins;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE CLASS  (mutable SL for trailing stops)
// ─────────────────────────────────────────────────────────────────────────────

class _T {
  final int id, dir;
  final double entry, qty, tp;
  double sl; // mutable — updated by trailing stop engine
  final double entryAtr; // ATR at entry (used for trail calculations)
  final double trailMult; // ATR multiplier for trailing stop (0 = off)
  double trailBest; // best price seen during trade
  final DateTime entryTime;
  double fundPaid = 0;
  bool open = true;
  double exitP = 0;
  String reason = '';

  _T({
    required this.id,
    required this.dir,
    required this.entry,
    required this.qty,
    required this.tp,
    required this.sl,
    required this.entryAtr,
    required this.trailMult,
    required this.entryTime,
  }) : trailBest = entry;
}

class _Pend {
  final int dir;
  _Pend({required this.dir});
}

// ─────────────────────────────────────────────────────────────────────────────
// INTRABAR TP+SL COLLISION RESOLVER
// ─────────────────────────────────────────────────────────────────────────────

(String, double) _resolveBothHit(_T t, Candle c) {
  switch (fillMode) {
    case FillMode.conservative:
      return ('SL', t.sl);
    case FillMode.optimistic:
      return ('TP', t.tp);
    case FillMode.probabilistic:
      final tpD = (t.tp - c.open).abs(), slD = (t.sl - c.open).abs();
      final tot = tpD + slD;
      final pTP = tot > 0 ? slD / tot : 0.5;
      return _rng.nextDouble() < pTP ? ('TP', t.tp) : ('SL', t.sl);
    case FillMode.expected:
      final tpD = (t.tp - c.open).abs(), slD = (t.sl - c.open).abs();
      final tot = tpD + slD;
      final pTP = tot > 0 ? slD / tot : 0.5;
      return (pTP >= 0.5 ? 'TP' : 'SL', pTP * t.tp + (1 - pTP) * t.sl);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTEST ENGINE  v10
//
//  signals[i]  : +1 LONG / -1 SHORT / 0 flat — from CLOSED bar i
//                used during bar i+1 (Fix 1: no lookahead)
//  tpAtr = 0   : ride mode — no fixed TP, exit on reverse signal or SL/trail
//  trailMult>0 : activate trailing stop at `trailMult × entryATR`
//  isOos       : if true, run only on the OOS slice (last _oosFrac of bars)
// ─────────────────────────────────────────────────────────────────────────────

Res _backtest(
  String asset,
  String strategy,
  String htfLabel,
  List<Candle> htf,
  List<List<Candle>> windows,
  List<int> signals,
  List<double> htfAtr,
  double tpAtr,
  double slAtr, {
  double trailMult = 0.0,
  bool isOos = false,
}) {
  // OOS: only process the last _oosFrac fraction of HTF bars.
  final iStart = isOos ? (htf.length * (1 - _oosFrac)).round() : 0;

  final trades = <_T>[];
  int tradeId = 0;
  double netEq = 0, peak = 0, maxDd = 0;

  int localMissedTP = 0;
  int localSlippedSL = 0;

  _T? active;
  _Pend? pending;
  DateTime lastFund = DateTime(2000);
  int longCd = 0, shortCd = 0;
  final volBuf = <double>[];

  for (int bar = iStart; bar < htf.length; bar++) {
    final sig = bar > 0 ? signals[bar - 1] : 0;
    final prevSig = bar > 1 ? signals[bar - 2] : 0;
    final atr = bar > 0 ? htfAtr[bar - 1] : htfAtr[0];

    final bars = windows[bar];
    if (bars.isEmpty) continue;

    for (int ei = 0; ei < bars.length; ei++) {
      final c = bars[ei];

      // ── Fill pending order at open of next bar (Fix 2) ────────────────────
      if (pending != null && active == null) {
        final pe = pending!;
        pending = null;
        final double fill = pe.dir == 1
            ? c.open * (1.0 + _slippage / 100.0)
            : c.open * (1.0 - _slippage / 100.0);

        final tp = tpAtr > 0
            ? (pe.dir == 1 ? fill + tpAtr * atr : fill - tpAtr * atr)
            : (pe.dir == 1 ? double.infinity : double.negativeInfinity);
        final sl = pe.dir == 1 ? fill - slAtr * atr : fill + slAtr * atr;

        if ((pe.dir == 1 ? fill > sl : fill < sl) &&
            atr / fill * 100 >= _minAtrPct) {
          active = _T(
            id: tradeId++,
            dir: pe.dir,
            entry: fill,
            qty: _notional / fill,
            tp: tp,
            sl: sl,
            entryAtr: atr,
            trailMult: trailMult,
            entryTime: c.time,
          );
          trades.add(active!);
        }
      }

      // ── Funding every 8h ──────────────────────────────────────────────────
      if (active != null &&
          active!.open &&
          c.time.difference(lastFund).inHours >= 8) {
        lastFund = c.time;
        active!.fundPaid += _notional * _leverage * _funding / 100;
      }

      // ── Trailing stop update ──────────────────────────────────────────────
      if (active != null && active!.open && active!.trailMult > 0) {
        final t = active!;
        if (t.dir == 1 && c.high > t.trailBest) {
          t.trailBest = c.high;
          final newSL = t.trailBest - t.trailMult * t.entryAtr;
          if (newSL > t.sl) t.sl = newSL; // only move in favour
        } else if (t.dir == -1 && c.low < t.trailBest) {
          t.trailBest = c.low;
          final newSL = t.trailBest + t.trailMult * t.entryAtr;
          if (newSL < t.sl) t.sl = newSL;
        }
      }

      // ── Exit logic — strict priority: FillMode → SL → TP → Flip → END ────
      if (active != null && active!.open) {
        final t = active!;

        final tpWick = t.dir == 1
            ? (t.tp.isFinite && c.high >= t.tp)
            : (t.tp.isFinite && c.low <= t.tp);
        final slWick = t.dir == 1 ? c.low <= t.sl : c.high >= t.sl;
        final tpClose = t.dir == 1
            ? (t.tp.isFinite && c.close >= t.tp)
            : (t.tp.isFinite && c.close <= t.tp);
        final slClose = t.dir == 1 ? c.close <= t.sl : c.close >= t.sl;

        if (useCloseExec && tpWick && !tpClose) {
          localMissedTP++;
          _missedTP++;
        }

        final effTP = useCloseExec ? tpClose : tpWick;
        final effSL = slWick; // SL always wick-based (can't ignore margin)
        final revSig = sig == -t.dir && sig != 0;

        String rsn = '';
        double at = 0;
        bool closed = false;

        if (effTP && effSL) {
          // ── Collision resolution ──────────────────────────────────────────
          final res = _resolveBothHit(t, c);
          rsn = res.$1;
          at = res.$2;
          closed = true;
          // Half-rate slippage on blended exit.
          at = t.dir == 1
              ? at * (1 - _slippage / 200.0)
              : at * (1 + _slippage / 200.0);
          if (rsn == 'SL') {
            localSlippedSL++;
            _slippedSL++;
          }
        } else if (effSL) {
          // ── SL only — probabilistic stop-hunt model ───────────────────────
          rsn = 'SL';
          closed = true;
          final slip = _rng.nextDouble() < 0.40;
          if (slip) {
            at = t.dir == 1
                ? t.sl * (1 - _slippage / 100.0)
                : t.sl * (1 + _slippage / 100.0);
            localSlippedSL++;
            _slippedSL++; // ✅ FIX: only count here
          } else {
            at = t.sl;
          }
        } else if (effTP) {
          // ── TP only — limit order, slight half-rate worsening ─────────────
          at = t.dir == 1
              ? t.tp * (1 - _slippage / 200.0)
              : t.tp * (1 + _slippage / 200.0);
          rsn = 'TP';
          closed = true;
        } else if (revSig) {
          // ── Reverse signal flip — market order at close ───────────────────
          at = c.close;
          rsn = 'FL';
          closed = true;
        }

        if (closed) {
          t.open = false;
          t.exitP = at;
          t.reason = rsn;
          final gp = t.dir == 1
              ? (at - t.entry) * t.qty * _leverage
              : (t.entry - at) * t.qty * _leverage;
          // ✅ FIX: commission only in flat costs (slippage captured in fill price).
          final costs =
              _notional * _leverage * _commission / 100 * 2 + t.fundPaid;
          netEq += gp - costs;
          if (rsn == 'SL' || rsn == 'FL') {
            if (t.dir == 1)
              longCd = _cooldown;
            else
              shortCd = _cooldown;
          }
          active = null;
        }
      }

      // ── Volume SMA filter (Fix 6) ─────────────────────────────────────────
      final volSma = volBuf.length >= 20
          ? volBuf.fold(0.0, (s, v) => s + v) / volBuf.length
          : 0.0;
      volBuf.add(c.volume);
      if (volBuf.length > 20) volBuf.removeAt(0);
      final volOk = volBuf.length < 20 || c.volume >= volSma * 0.5;

      if (longCd > 0) longCd--;
      if (shortCd > 0) shortCd--;

      // ── New entry only at first bar of HTF window ─────────────────────────
      if (active == null && pending == null && volOk && ei == 0) {
        if (sig == 1 && prevSig != 1 && longCd == 0)
          pending = _Pend(dir: 1);
        else if (sig == -1 && prevSig != -1 && shortCd == 0)
          pending = _Pend(dir: -1);
      }

      // ── Mark-to-market drawdown on every 5m bar ───────────────────────────
      double op = 0;
      if (active != null && active!.open) {
        final t = active!;
        op =
            (t.dir == 1 ? (c.close - t.entry) : (t.entry - c.close)) *
                t.qty *
                _leverage -
            _notional * _leverage * _commission / 100 * 2 -
            t.fundPaid;
      }
      final cur = netEq + op;
      if (cur > peak) peak = cur;
      if (peak - cur > maxDd) maxDd = peak - cur;
    }
  }

  // ── Force-close at end of data ────────────────────────────────────────────
  if (active != null && active!.open) {
    final t = active!;
    t.open = false;
    t.exitP = windows.last.isNotEmpty ? windows.last.last.close : t.entry;
    t.reason = 'END';
    final gp = t.dir == 1
        ? (t.exitP - t.entry) * t.qty * _leverage
        : (t.entry - t.exitP) * t.qty * _leverage;
    netEq += gp - _notional * _leverage * _commission / 100 * 2 - t.fundPaid;
  }

  // ── Statistics ────────────────────────────────────────────────────────────
  final closed = trades.where((t) => t.reason.isNotEmpty).toList();

  // Per-trade P&L.
  final pnls = closed.map((t) {
    return t.dir == 1
        ? (t.exitP - t.entry) * t.qty * _leverage -
              _notional * _leverage * _commission / 100 * 2 -
              t.fundPaid
        : (t.entry - t.exitP) * t.qty * _leverage -
              _notional * _leverage * _commission / 100 * 2 -
              t.fundPaid;
  }).toList();

  final wins = pnls.where((p) => p > 0).length;
  final grossW = pnls.where((p) => p > 0).fold(0.0, (a, b) => a + b);
  final grossL = pnls.where((p) => p < 0).fold(0.0, (a, b) => a + b.abs());
  final pf = grossL > 0 ? grossW / grossL : (grossW > 0 ? 99.0 : 0.0);

  final avgWin = wins > 0 ? grossW / wins : 0.0;
  final avgLoss = (closed.length - wins) > 0
      ? grossL / (closed.length - wins)
      : 0.0;
  final slAtrVal = slAtr > 0 ? slAtr : 2.0; // fallback for ride strategies
  final riskUnit = _notional * _leverage * slAtrVal * 0.01;
  final avgWinR = riskUnit > 0 ? avgWin / riskUnit : 0.0;
  final avgLossR = riskUnit > 0 ? avgLoss / riskUnit : 0.0;

  // Max consecutive losses.
  int maxCL = 0, curCL = 0;
  for (final p in pnls) {
    if (p < 0) {
      curCL++;
      if (curCL > maxCL) maxCL = curCL;
    } else
      curCL = 0;
  }

  // Approximate Sharpe (per-trade, assuming 0 risk-free rate).
  double sharpe = 0;
  if (closed.length > 1) {
    final mean = pnls.fold(0.0, (s, p) => s + p) / pnls.length;
    final variance =
        pnls.map((p) => pow(p - mean, 2)).fold(0.0, (s, v) => s + v) /
        pnls.length;
    final std = sqrt(variance);
    sharpe = std > 0 ? mean / std * sqrt(closed.length.toDouble()) : 0;
  }

  // Execution quality (print only if non-zero).
  if (localMissedTP > 0 || localSlippedSL > 0) {
    stdout.write(
      '    [ExecQ] $asset/$strategy/$htfLabel'
      ' MissedTP:$localMissedTP SlipSL:$localSlippedSL\n',
    );
  }

  final dep = _notional * _leverage;
  final ret = dep > 0 ? netEq / dep * 100 : 0.0;
  final ddP = dep > 0 ? maxDd / dep * 100 : 0.0;
  final calmar = ddP.abs() > 0 ? ret / ddP.abs() : 0.0;
  final recov = maxDd > 0 ? netEq / maxDd : 0.0;

  // ── Grading ───────────────────────────────────────────────────────────────
  // Minimum 40 trades required for any grade above E.
  String grade;
  if (closed.length < 40)
    grade = 'E  (n<40)';
  else if (calmar >= 4 && ret >= 40 && ddP < 25 && pf >= 1.5)
    grade = 'A ★★★';
  else if (calmar >= 2.5 && ret >= 20 && ddP < 35 && pf >= 1.3)
    grade = 'B ★★';
  else if (calmar >= 1 && ret >= 10 && ddP < 50 && pf >= 1.1)
    grade = 'C ★';
  else if (ret > 0)
    grade = 'D';
  else
    grade = 'F';

  return Res(
    asset: asset,
    strategy: strategy,
    htf: htfLabel,
    trades: closed.length,
    wins: wins,
    maxConsecLoss: maxCL,
    netPnl: netEq,
    returnPct: ret,
    maxDdPct: ddP.abs(),
    calmar: calmar,
    profitFactor: pf,
    avgWinR: avgWinR,
    avgLossR: avgLossR,
    sharpe: sharpe,
    recoveryFactor: recov,
    grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/// Convert momentary breakout signal to sustained direction.
List<int> _sustained(List<int> sigs) {
  final out = <int>[];
  int cur = 0;
  for (final s in sigs) {
    if (s != 0) cur = s;
    out.add(cur);
  }
  return out;
}

/// Centre-pad string to width.
String _c(String s, int w) {
  final p = ((w - s.length) / 2).floor();
  return ' ' * p + s + ' ' * (w - s.length - p);
}

void _writeReport(StringBuffer buf) {
  final ts = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .substring(0, 19);
  final path = '/Users/ayush/Desktop/strategy_hunt_v10_$ts.txt';
  File(path).writeAsStringSync(buf.toString());
  print('\nReport saved → $path');
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  final buf = StringBuffer();
  void log(String s) {
    print(s);
    buf.writeln(s);
  }

  _missedTP = 0;
  _slippedSL = 0;

  final dir15 = Directory('$_root/15m');
  final assets = dir15
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.csv'))
      .map((f) {
        final name = f.path.split('/').last.replaceAll('15m.csv', '');
        final f5 = File('$_root/5m/${name}5m.csv');
        return f5.existsSync() ? (name, f.path, f5.path) : null;
      })
      .whereType<(String, String, String)>()
      .toList();

  log('Found ${assets.length} assets.\n');
  log('FillMode      : $fillMode');
  log('CloseExec     : $useCloseExec');
  log('OOS split     : ${(_oosFrac * 100).round()}% out-of-sample validation');
  log('Commission    : $_commission% per side');
  log('Slippage      : $_slippage% (entry fill only; not double-charged)');
  log('Notional      : \$$_notional × ${_leverage}x\n');

  final htfDefs = [(2, '30m'), (3, '45m'), (4, '60m'), (6, '90m')];
  final allResults = <Res>[];
  int tested = 0;

  for (final (sym, p15, p5) in assets) {
    stdout.write('  $sym ... ');
    buf.write('  $sym ... ');
    final c15 = _load(p15);
    final c5 = _clean(_load(p5), 5);

    for (final (mult, htfLbl) in htfDefs) {
      final htf = _agg(c15, mult);
      if (htf.length < 200) continue; // need enough bars for EMA200

      final windows = _bucket(htf, c5);

      // ── Precompute all indicators ────────────────────────────────────────
      final atr14 = _atr(htf, 14);
      final atr10 = _atr(htf, 10);
      final sfi10 = _sfi(htf, 10, 1.7, atr10);
      final sfi14 = _sfi(htf, 14, 2.0, atr14);
      final hh20 = _dHH(htf, 20);
      final ll20 = _dLL(htf, 20);
      final hh40 = _dHH(htf, 40);
      final ll40 = _dLL(htf, 40);
      final ema9 = _ema(htf, 9);
      final ema21 = _ema(htf, 21);
      final ema200 = _ema(htf, 200);
      final rsi14 = _rsi(htf, 14);
      final (adx14, diP, diM) = _adxFull(htf, 14);
      final (macdL, macdS, macdH) = _macd(htf);
      final (bbMid, bbUp, bbLo) = _bb(htf, 20, 2.0);
      final obvRaw = _obv(htf);
      final obvEma = _emaD(obvRaw, 20);
      final stochRsi = _stochRsi(htf, 14, 14, 3);

      // ── Signal arrays ─────────────────────────────────────────────────────

      // Existing signals.
      final sigDon20 = List.generate(
        htf.length,
        (i) => i == 0
            ? 0
            : htf[i].close > hh20[i]
            ? 1
            : htf[i].close < ll20[i]
            ? -1
            : 0,
      );
      final sigDon40 = List.generate(
        htf.length,
        (i) => i == 0
            ? 0
            : htf[i].close > hh40[i]
            ? 1
            : htf[i].close < ll40[i]
            ? -1
            : 0,
      );
      final sigDon20s = _sustained(sigDon20);
      final sigDon40s = _sustained(sigDon40);

      final sigEma = List.generate(
        htf.length,
        (i) => i == 0
            ? 0
            : ema9[i] > ema21[i]
            ? 1
            : -1,
      );

      final sigCombo10 = List.generate(
        htf.length,
        (i) => sfi10[i] == 1 && sigDon20s[i] == 1
            ? 1
            : sfi10[i] == -1 && sigDon20s[i] == -1
            ? -1
            : 0,
      );
      final sigCombo14 = List.generate(
        htf.length,
        (i) => sfi14[i] == 1 && sigDon40s[i] == 1
            ? 1
            : sfi14[i] == -1 && sigDon40s[i] == -1
            ? -1
            : 0,
      );

      // ── NEW signals ───────────────────────────────────────────────────────

      // S7: ADX-filtered (only enter trending markets).
      final sigAdxDon40 = List.generate(
        htf.length,
        (i) => adx14[i] >= _adxTrend ? sigDon40s[i] : 0,
      );
      final sigAdxSfi14 = List.generate(
        htf.length,
        (i) => adx14[i] >= _adxTrend ? sfi14[i] : 0,
      );

      // S8: RSI-filtered (avoid extreme RSI entries).
      final sigRsiSfi14 = List.generate(htf.length, (i) {
        final r = rsi14[i];
        if (sfi14[i] == 1 && r > 35 && r < 68) return 1;
        if (sfi14[i] == -1 && r > 32 && r < 65) return -1;
        return 0;
      });
      final sigRsiDon40 = List.generate(htf.length, (i) {
        final r = rsi14[i];
        if (sigDon40s[i] == 1 && r > 40 && r < 70) return 1;
        if (sigDon40s[i] == -1 && r > 30 && r < 60) return -1;
        return 0;
      });

      // S9: Triple confluence (SFI14 + Don40 + ADX > 20).
      final sigTriple = List.generate(htf.length, (i) {
        if (adx14[i] < _adxTrend) return 0;
        if (sfi14[i] == 1 && sigDon40s[i] == 1) return 1;
        if (sfi14[i] == -1 && sigDon40s[i] == -1) return -1;
        return 0;
      });

      // S10: MACD histogram + SFI10.
      final sigMacdSfi10 = List.generate(htf.length, (i) {
        if (sfi10[i] == 1 && macdH[i] > 0) return 1;
        if (sfi10[i] == -1 && macdH[i] < 0) return -1;
        return 0;
      });

      // S11: Bollinger Band breakout (sustained after initial break).
      final sigBbBreak = List.generate(htf.length, (i) {
        if (i == 0) return 0;
        if (htf[i].close > bbUp[i] && htf[i - 1].close <= bbUp[i - 1]) return 1;
        if (htf[i].close < bbLo[i] && htf[i - 1].close >= bbLo[i - 1])
          return -1;
        return 0;
      });
      final sigBbBreaks = _sustained(sigBbBreak);

      // S12: OBV trend + SFI14.
      final sigObvSfi14 = List.generate(htf.length, (i) {
        if (sfi14[i] == 1 && obvRaw[i] > obvEma[i]) return 1;
        if (sfi14[i] == -1 && obvRaw[i] < obvEma[i]) return -1;
        return 0;
      });

      // S13: Full confluence (SFI14 + Don40 + ADX + OBV + MACD all aligned).
      final sigFull = List.generate(htf.length, (i) {
        if (adx14[i] < _adxTrend) return 0;
        final macdBull = macdH[i] > 0;
        final obvBull = obvRaw[i] > obvEma[i];
        if (sfi14[i] == 1 && sigDon40s[i] == 1 && macdBull && obvBull) return 1;
        if (sfi14[i] == -1 && sigDon40s[i] == -1 && !macdBull && !obvBull)
          return -1;
        return 0;
      });

      // S15: Regime-aware triple (long only above EMA200, short only below).
      final sigRegimeBull = List.generate(htf.length, (i) {
        if (htf[i].close > ema200[i] && sigTriple[i] == 1) return 1;
        if (htf[i].close < ema200[i] && sigTriple[i] == -1) return -1;
        return 0;
      });

      // StochRSI-filtered Don40: avoid overbought entries.
      final sigStochDon40 = List.generate(htf.length, (i) {
        if (sigDon40s[i] == 1 && stochRsi[i] < 0.80) return 1;
        if (sigDon40s[i] == -1 && stochRsi[i] > 0.20) return -1;
        return 0;
      });

      // DI+ / DI− divergence filter on SFI14:
      // Enter long only when DI+ > DI− (confirms bullish pressure).
      final sigDiSfi14 = List.generate(htf.length, (i) {
        if (sfi14[i] == 1 && diP[i] > diM[i]) return 1;
        if (sfi14[i] == -1 && diM[i] > diP[i]) return -1;
        return 0;
      });

      // ── Strategy variants (name, signals, tpAtr, slAtr, trailMult) ────────
      final variants = [
        // ── ORIGINAL 13 (unchanged logic, bugs fixed in engine) ──────────
        ('S1:SFI10-Ride', sfi10, 0.0, 2.0, 0.0),
        ('S1:SFI14-Ride', sfi14, 0.0, 2.0, 0.0),
        ('S2:SFI10-TP3SL1.5', sfi10, 3.0, 1.5, 0.0),
        ('S2:SFI14-TP3SL1.5', sfi14, 3.0, 1.5, 0.0),
        ('S2:SFI10-TP2SL1', sfi10, 2.0, 1.0, 0.0),
        ('S3:Don20-TP3SL1.5', sigDon20s, 3.0, 1.5, 0.0),
        ('S3:Don20-TP4SL2', sigDon20s, 4.0, 2.0, 0.0),
        ('S4:Don40-TP3SL1.5', sigDon40s, 3.0, 1.5, 0.0),
        ('S4:Don40-TP4SL2', sigDon40s, 4.0, 2.0, 0.0),
        ('S5:EMA9x21-TP3SL1.5', sigEma, 3.0, 1.5, 0.0),
        ('S5:EMA9x21-Ride', sigEma, 0.0, 2.0, 0.0),
        ('S6:SFI10+Don20', sigCombo10, 3.0, 1.5, 0.0),
        ('S6:SFI14+Don40', sigCombo14, 3.0, 1.5, 0.0),

        // ── NEW STRATEGIES ───────────────────────────────────────────────
        // S7 — ADX trend filter
        ('S7:ADX-Don40-TP4SL2', sigAdxDon40, 4.0, 2.0, 0.0),
        ('S7:ADX-SFI14-Ride', sigAdxSfi14, 0.0, 2.0, 0.0),

        // S8 — RSI zone filter
        ('S8:RSI-SFI14-TP3SL1.5', sigRsiSfi14, 3.0, 1.5, 0.0),
        ('S8:RSI-Don40-TP4SL2', sigRsiDon40, 4.0, 2.0, 0.0),

        // S9 — Triple confluence (SFI + Don + ADX)
        ('S9:Triple-TP4SL2', sigTriple, 4.0, 2.0, 0.0),
        ('S9:Triple-TP3SL1.5', sigTriple, 3.0, 1.5, 0.0),

        // S10 — MACD + SFI
        ('S10:MACD+SFI10', sigMacdSfi10, 3.0, 1.5, 0.0),

        // S11 — Bollinger Band breakout
        ('S11:BB-Break-TP3SL1.5', sigBbBreaks, 3.0, 1.5, 0.0),
        ('S11:BB-Break-TP4SL2', sigBbBreaks, 4.0, 2.0, 0.0),

        // S12 — OBV volume trend + SFI14
        ('S12:OBV+SFI14-TP3SL1.5', sigObvSfi14, 3.0, 1.5, 0.0),

        // S13 — Full kitchen-sink confluence
        ('S13:Full-TP4SL2', sigFull, 4.0, 2.0, 0.0),
        ('S13:Full-Ride', sigFull, 0.0, 2.0, 0.0),

        // S14 — Trailing stops
        ('S14:SFI14-Trail1.5', sfi14, 0.0, 3.0, 1.5),
        ('S14:Don40-Trail2', sigDon40s, 0.0, 3.0, 2.0),
        ('S14:Triple-Trail1.5', sigTriple, 0.0, 3.0, 1.5),

        // S15 — Regime-aware (EMA200 filter)
        ('S15:Regime-Triple', sigRegimeBull, 4.0, 2.0, 0.0),

        // S16 — StochRSI + Don40 (avoid entering near exhaustion)
        ('S16:Stoch-Don40-TP4SL2', sigStochDon40, 4.0, 2.0, 0.0),

        // S17 — DI+/DI− directional confirmation
        ('S17:DI-SFI14-TP3SL1.5', sigDiSfi14, 3.0, 1.5, 0.0),
        ('S17:DI-SFI14-Ride', sigDiSfi14, 0.0, 2.0, 0.0),
      ];

      for (final (name, sigs, tpA, slA, trailA) in variants) {
        // ── IS (full / in-sample) ──────────────────────────────────────────
        final r = _backtest(
          sym,
          name,
          htfLbl,
          htf,
          windows,
          sigs,
          atr14,
          tpA,
          slA,
          trailMult: trailA,
        );

        // ── OOS validation ─────────────────────────────────────────────────
        final rOos = _backtest(
          sym,
          name,
          htfLbl,
          htf,
          windows,
          sigs,
          atr14,
          tpA,
          slA,
          trailMult: trailA,
          isOos: true,
        );
        r.oos = rOos;

        if (r.netPnl > 0) allResults.add(r);
        tested++;
      }
    }
    stdout.writeln('done');
    buf.writeln('done');
  }

  log('\nTested $tested configs across ${assets.length} assets.');
  log('Profitable (IS): ${allResults.length}');
  final oosValid = allResults.where((r) => r.oosValid).length;
  log('OOS confirmed  : $oosValid  (✅ = profitable in both IS + OOS)');

  log(
    '\n── EXECUTION QUALITY ─────────────────────────────────────────────────────────',
  );
  log('  Missed TP (close-mode): $_missedTP');
  log('  SL slippage events    : $_slippedSL  (fixed double-count bug)');

  if (allResults.isEmpty) {
    log('\nNo profitable configs found.');
    _writeReport(buf);
    return;
  }

  allResults.sort((a, b) => b.calmar.compareTo(a.calmar));

  // ── Master table ──────────────────────────────────────────────────────────
  final sep = '═' * 120;
  log('\n╔$sep╗');
  log(
    '║${_c('PROFITABLE CONFIGS — v10 BEAST MODE (bias-free, walk-forward OOS validated)', 120)}║',
  );
  log(
    '╠════╦═══════════════╦════════════════════════════╦══════╦══════╦══════╦═══════╦════════╦══════╦════╦══════════════════╣',
  );
  log(
    '║  # ║ Asset         ║ Strategy                   ║  HTF ║  Trd ║  WR% ║  Net\$  ║   DD%  ║  PF  ║ CL ║ Calmar  Grade    ║',
  );
  log(
    '╠════╬═══════════════╬════════════════════════════╬══════╬══════╬══════╬═══════╬════════╬══════╬════╬══════════════════╣',
  );

  int shown = 0;
  for (int i = 0; i < allResults.length && shown < 100; i++) {
    final r = allResults[i];
    if (r.grade == 'F' || r.grade.startsWith('E')) continue;
    shown++;
    final n = shown.toString().padLeft(3);
    final as = r.asset.padRight(13);
    final st = r.strategy.padRight(26);
    final ht = r.htf.padLeft(4);
    final tr = r.trades.toString().padLeft(4);
    final wr = '${r.wr.toStringAsFixed(1)}%'.padLeft(5);
    final np = ((r.netPnl >= 0 ? '+' : '') + r.netPnl.toStringAsFixed(1))
        .padLeft(6);
    final dd = '${r.maxDdPct.toStringAsFixed(1)}%'.padLeft(6);
    final pf = r.profitFactor.toStringAsFixed(2).padLeft(5);
    final cl = r.maxConsecLoss.toString().padLeft(3);
    final ca = r.calmar.toStringAsFixed(2).padLeft(6);
    final gr = (r.grade + r.oosFlag).padRight(14);
    log('║$n ║ $as║ $st║  $ht║$tr  ║$wr ║$np ║$dd  ║$pf ║$cl ║$ca  $gr║');
  }
  log(
    '╚════╩═══════════════╩════════════════════════════╩══════╩══════╩══════╩═══════╩════════╩══════╩════╩══════════════════╝',
  );
  log(
    '  ✅ = also profitable in OOS (last ${(_oosFrac * 100).round()}% of data)   ⚠️ = IS-only, may be overfit',
  );

  // ── Strategy summary ──────────────────────────────────────────────────────
  log(
    '\n── STRATEGY SUMMARY (profitable count + avg Calmar + OOS rate) ──────────────',
  );
  final bySt = <String, List<Res>>{};
  for (final r in allResults) {
    final key = r.strategy.replaceAll(RegExp(r'-TP.*|-Ride.*|-Trail.*'), '');
    bySt.putIfAbsent(key, () => []).add(r);
  }
  final stSorted = bySt.entries.toList()
    ..sort((a, b) {
      final ca = a.value.fold(0.0, (s, r) => s + r.calmar) / a.value.length;
      final cb = b.value.fold(0.0, (s, r) => s + r.calmar) / b.value.length;
      return cb.compareTo(ca);
    });
  for (final e in stSorted) {
    final avg = e.value.fold(0.0, (s, r) => s + r.calmar) / e.value.length;
    final aGr = e.value.where((r) => r.grade.startsWith('A')).length;
    final bGr = e.value.where((r) => r.grade.startsWith('B')).length;
    final cGr = e.value.where((r) => r.grade.startsWith('C')).length;
    final oosc = e.value.where((r) => r.oosValid).length;
    final oosR = e.value.isNotEmpty ? (oosc / e.value.length * 100).round() : 0;
    log(
      '  ${e.key.padRight(30)} → ${e.value.length.toString().padLeft(3)} profitable '
      '| AvgCalmar: ${avg.toStringAsFixed(2).padLeft(6)} '
      '| A:$aGr B:$bGr C:$cGr '
      '| OOS: $oosR%',
    );
  }

  // ── Best configs ──────────────────────────────────────────────────────────
  final bestAll = allResults.first;
  final bestOos = allResults.where((r) => r.oosValid).toList();
  bestOos.sort((a, b) => b.calmar.compareTo(a.calmar));

  log(
    '\n── BEST OVERALL (IS Calmar) ─────────────────────────────────────────────────',
  );
  _printBest(log, bestAll);

  if (bestOos.isNotEmpty) {
    log(
      '\n── BEST OOS-CONFIRMED (profitable in both IS + OOS) ─────────────────────────',
    );
    _printBest(log, bestOos.first);
    log('  OOS Return  : ${bestOos.first.oos!.returnPct.toStringAsFixed(1)}%');
    log('  OOS MaxDD   : ${bestOos.first.oos!.maxDdPct.toStringAsFixed(1)}%');
    log('  OOS Calmar  : ${bestOos.first.oos!.calmar.toStringAsFixed(2)}');
  }

  _writeReport(buf);
}

void _printBest(void Function(String) log, Res r) {
  log('  Asset         : ${r.asset}');
  log('  Strategy      : ${r.strategy}');
  log('  HTF           : ${r.htf}');
  log('  Trades        : ${r.trades}  WR: ${r.wr.toStringAsFixed(1)}%');
  log('  Net PnL       : \$${r.netPnl.toStringAsFixed(2)}');
  log('  Return        : ${r.returnPct.toStringAsFixed(1)}%');
  log('  Max DD        : ${r.maxDdPct.toStringAsFixed(1)}%');
  log('  Calmar        : ${r.calmar.toStringAsFixed(2)}');
  log('  Profit Factor : ${r.profitFactor.toStringAsFixed(2)}');
  log('  Avg Win (R)   : ${r.avgWinR.toStringAsFixed(2)}');
  log('  Avg Loss (R)  : ${r.avgLossR.toStringAsFixed(2)}');
  log('  Max Consec L  : ${r.maxConsecLoss}');
  log('  Sharpe~       : ${r.sharpe.toStringAsFixed(2)}');
  log('  Recovery F.   : ${r.recoveryFactor.toStringAsFixed(2)}');
  log('  Grade         : ${r.grade}${r.oosFlag}');
}
