// ============================================================================
// STRATEGY HUNT — v9 (realistic execution engine)
// ============================================================================
// Tests 13 strategy variants × ALL assets × 4 timeframes.
// Uses the bias-free engine from v5 (all 7 forward-bias fixes).
// Reports ONLY profitable configs (netPnl > 0).
//
// STRATEGIES TESTED:
//   S1: SFI Ride — flip entry, hold until reverse SFI signal. Emerg SL 2×ATR.
//   S2: SFI Fixed Stops — TP 3×ATR, SL 1.5×ATR (also TP2/SL1 variant).
//   S3: Donchian(20) breakout — close above 20-bar high, TP 3/4×ATR, SL 1.5/2×ATR.
//   S4: Donchian(40) breakout — same, wider lookback.
//   S5: EMA(9/21) cross — entry on cross, ride or fixed stops.
//   S6: SFI + Donchian combo — only enter when both agree.
//
// BIAS-FREE FIXES (v5 engine):
//   1. signals[bar-1]: indicator computed from CLOSED bar i → used at bar i+1
//   2. Deferred entry: signal at HTF bar close → fill at next 5m bar's open
//   3. Intrabar ambiguity resolved via FillMode (v9)
//   4. Funding 0.01%/8h
//   5. Blended commission 0.025% + slippage 0.04% per side
//   6. Volume SMA filter (≥50% of 20-bar avg)
//   7. Zero-vol + gap candle removal
//
// EXECUTION UPGRADES (v9):
//   - FillMode enum: conservative / optimistic / probabilistic / expected
//   - Realistic entry slippage (spread + latency model)
//   - SL slippage: stop-hunt / panic-fill model
//   - TP slippage: limit order slight worsening (half-rate)
//   - Close-based execution mode (optional toggle)
//   - MissedTP + SlippedSL execution quality metrics
//   - Strict 4-exit-condition priority: FillMode → SL → TP → Flip → END
//
// PERFORMANCE:
//   Pre-bucket 5m candles into HTF windows ONCE per asset×HTF.
//   Reused across all 13 strategy calls → O(n).
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PATHS & CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _root       = '/Users/ayush/Desktop/candlestick data';
const _commission = 0.025;   // % blended maker/taker
const _slippage   = 0.02;    // % per side
const _funding    = 0.01;    // % per 8h
const _notional   = 20.0;    // USDT per trade
const _leverage   = 5.0;
const _cooldown   = 3;       // bars cooldown after SL
const _minAtrPct  = 0.3;     // min ATR% to enter

// ─────────────────────────────────────────────────────────────────────────────
// FILL MODE ENUM + EXECUTION CONFIG
// ─────────────────────────────────────────────────────────────────────────────

/// Controls how ambiguous intrabar TP+SL collisions are resolved.
enum FillMode {
  conservative,  // worst case  → SL always wins
  optimistic,    // best case   → TP always wins
  probabilistic, // distance-based RNG (seeded for reproducibility)
  expected       // weighted EV — deterministic blend, no randomness
}

/// Active fill mode. Change this to explore different execution assumptions.
const FillMode fillMode = FillMode.expected;

/// If true: TP/SL trigger only when candle CLOSE crosses level (stricter).
/// Wick touches still tracked for missedTP metric.
/// If false (default): standard wick-based execution.
const bool useCloseExecution = false;

// ─────────────────────────────────────────────────────────────────────────────
// RNG  (used only by FillMode.probabilistic)
// ─────────────────────────────────────────────────────────────────────────────

/// Seed for reproducibility. Set to null for non-deterministic runs.
const int? _rngSeed = 42;

final _rng = _rngSeed != null ? Random(_rngSeed) : Random();

// ─────────────────────────────────────────────────────────────────────────────
// EXECUTION METRICS  (module-level; reset manually if running multiple passes)
// ─────────────────────────────────────────────────────────────────────────────

/// Wick touched TP but candle close didn't (only incremented in close-mode).
int _missedTP  = 0;

/// SL exit price was worse than the nominal SL level (always tracked).
int _slippedSL = 0;

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset, strategy, htf;
  final int    trades, wins;
  final double netPnl, returnPct, maxDdPct, calmar;
  final String grade;
  Res({required this.asset, required this.strategy, required this.htf,
       required this.trades, required this.wins,
       required this.netPnl, required this.returnPct,
       required this.maxDdPct, required this.calmar, required this.grade});
  double get wr => trades == 0 ? 0.0 : wins / trades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLLING INDICATORS — all O(n), zero look-ahead
// ─────────────────────────────────────────────────────────────────────────────

List<double> _atr(List<Candle> cs, int p) {
  final out = <double>[];
  double prev = cs[0].high - cs[0].low;
  for (int i = 0; i < cs.length; i++) {
    final tr = i == 0
        ? cs[i].high - cs[i].low
        : max(cs[i].high - cs[i].low,
            max((cs[i].high - cs[i-1].close).abs(),
                (cs[i].low  - cs[i-1].close).abs()));
    prev = i == 0 ? tr : (prev * (p - 1) + tr) / p;
    out.add(prev);
  }
  return out;
}

// Returns +1 (uptrend) or -1 (downtrend) at each bar.
List<int> _sfi(List<Candle> cs, int p, double m, List<double> atr) {
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int t = 1;
  final out = <int>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m*a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m*a;
    if (t == -1 && cs[i].close > pDn) t = 1;
    else if (t == 1 && cs[i].close < pUp) t = -1;
    pUp = up; pDn = dn;
    out.add(t);
  }
  return out;
}

// Donchian: highest-high of PREVIOUS n bars (no current bar) — O(n·window).
List<double> _dHH(List<Candle> cs, int n) {
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(cs[0].high); continue; }
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
    if (i == 0) { out.add(cs[0].low); continue; }
    final start = max(0, i - n);
    double lo = cs[start].low;
    for (int j = start + 1; j < i; j++) if (cs[j].low < lo) lo = cs[j].low;
    out.add(lo);
  }
  return out;
}

List<double> _ema(List<Candle> cs, int p) {
  final k = 2.0 / (p + 1);
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(i == 0 ? cs[0].close : cs[i].close * k + out[i-1] * (1 - k));
  }
  return out;
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
    out.add(Candle(DateTime.parse(p[0] + 'Z'),
        double.parse(p[1]), double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4]),
        double.parse(p[5]), i - 1));
  }
  return out;
}

List<Candle> _agg(List<Candle> c, int m) {
  final out = <Candle>[];
  int idx = 0;
  for (int i = 0; i + m - 1 < c.length; i += m) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < m; j++) {
      hi = max(hi, c[i+j].high);
      lo = min(lo, c[i+j].low);
      vol += c[i+j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i+m-1].close, vol, idx++));
  }
  return out;
}

List<Candle> _clean(List<Candle> raw, int im) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty && c.time.difference(out.last.time).inMinutes > im * 3) continue;
    out.add(c);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// PRE-BUCKET: assign each 5m candle to its HTF window index — O(N+M)
// Returns List<List<Candle>> of length htf.length.
// ─────────────────────────────────────────────────────────────────────────────

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
// TRADE CLASSES
// ─────────────────────────────────────────────────────────────────────────────

class _T {
  final int id, dir;
  final double entry, qty, tp, sl;
  final DateTime entryTime;
  double fundPaid = 0;
  bool open = true;
  double exitP = 0;
  String reason = '';
  _T({required this.id, required this.dir, required this.entry,
      required this.qty, required this.tp, required this.sl,
      required this.entryTime});
}

class _Pend {
  final int dir;
  _Pend({required this.dir});
}

// ─────────────────────────────────────────────────────────────────────────────
// INTRABAR AMBIGUITY RESOLVER  (both TP + SL hit same candle)
//
// Returns (reason, exitPrice).
// NOTE: Slippage is NOT applied inside this function — the caller applies it
// after, preventing double-application in FillMode.expected where the blended
// price already represents a realistic weighted outcome.
// ─────────────────────────────────────────────────────────────────────────────

(String, double) _resolveBothHit(_T t, Candle c) {
  switch (fillMode) {

    case FillMode.conservative:
      // Worst case: SL always wins.
      return ('SL', t.sl);

    case FillMode.optimistic:
      // Best case: TP always wins.
      return ('TP', t.tp);

    case FillMode.probabilistic:
      // The level closer to the candle open is statistically more likely
      // to have been reached first.
      final tpDist = (t.tp - c.open).abs();
      final slDist = (t.sl - c.open).abs();
      final total  = tpDist + slDist;
      final probTP = total > 0 ? slDist / total : 0.5;
      return _rng.nextDouble() < probTP
          ? ('TP', t.tp)
          : ('SL', t.sl);

    case FillMode.expected:
      // Deterministic weighted EV — no randomness, maximum realism.
      // probTP = slDist / (tpDist + slDist): TP more likely when SL is further.
      final tpDist = (t.tp - c.open).abs();
      final slDist = (t.sl - c.open).abs();
      final total  = tpDist + slDist;
      final probTP = total > 0 ? slDist / total : 0.5;
      // Weighted blended exit price.
      final expectedExit = probTP * t.tp + (1.0 - probTP) * t.sl;
      final rsn          = probTP >= 0.5 ? 'TP' : 'SL';
      return (rsn, expectedExit);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GENERIC BACKTESTER  (v9 — realistic execution engine)
//
// signals[i]: +1 LONG, -1 SHORT, 0 flat — computed after htf[i] CLOSES
//             → used during htf[i+1]'s execution window (Fix 1, no lookahead)
// tpAtr=0  : ride mode — no fixed TP, exit only on reverse signal or SL
// ─────────────────────────────────────────────────────────────────────────────

Res _backtest(
  String asset, String strategy, String htfLabel,
  List<Candle> htf,
  List<List<Candle>> windows,   // pre-bucketed 5m candles per HTF bar
  List<int>    signals,
  List<double> htfAtr,
  double tpAtr, double slAtr,
) {
  final trades = <_T>[];
  int tradeId  = 0;
  double netEq = 0, peak = 0, maxDd = 0;

  // ── Per-call execution quality counters ───────────────────────────────────
  int localMissedTP  = 0;
  int localSlippedSL = 0;

  _T?    active;
  _Pend? pending;
  DateTime lastFund = DateTime(2000);
  int longCd = 0, shortCd = 0;

  final volBuf = <double>[];

  for (int bar = 0; bar < htf.length; bar++) {
    // Fix 1: use signal from previous CLOSED bar — strictly no lookahead.
    final sig     = bar > 0 ? signals[bar - 1] : 0;
    final prevSig = bar > 1 ? signals[bar - 2] : 0;
    final atr     = bar > 0 ? htfAtr[bar - 1]  : htfAtr[0];

    final bars = windows[bar];
    if (bars.isEmpty) continue;

    for (int ei = 0; ei < bars.length; ei++) {
      final c = bars[ei];

      // ── Fix 2 + §4: fill pending at this bar's open with entry slippage ───
      // Simulates spread + latency: longs pay ask, shorts hit bid.
      if (pending != null && active == null) {
        final pe  = pending!;
        pending   = null;

        final double fill = pe.dir == 1
            ? c.open * (1.0 + _slippage / 100.0)   // long  → buy at ask
            : c.open * (1.0 - _slippage / 100.0);   // short → sell at bid

        final tp = tpAtr > 0
            ? (pe.dir == 1 ? fill + tpAtr * atr : fill - tpAtr * atr)
            : (pe.dir == 1 ? double.infinity : double.negativeInfinity);
        final sl = pe.dir == 1
            ? fill - slAtr * atr
            : fill + slAtr * atr;

        final slOk = pe.dir == 1 ? fill > sl : fill < sl;
        if (slOk && atr / fill * 100 >= _minAtrPct) {
          active = _T(
            id: tradeId++, dir: pe.dir,
            entry: fill, qty: _notional / fill,
            tp: tp, sl: sl, entryTime: c.time,
          );
          trades.add(active!);
        }
      }

      // ── Fix 4: funding charge every 8h ───────────────────────────────────
      if (active != null && active!.open &&
          c.time.difference(lastFund).inHours >= 8) {
        lastFund = c.time;
        active!.fundPaid += _notional * _leverage * _funding / 100;
      }

      // ── §7 EXIT LOGIC — strict priority order ─────────────────────────────
      // Priority: (TP∧SL → FillMode) → SL → TP → Flip → END
      if (active != null && active!.open) {
        final t = active!;

        // ── Hit detection ─────────────────────────────────────────────────
        // Wick-based detection (always computed; used for missedTP tracking
        // in close-mode and as primary trigger in standard mode).
        final bool tpWickHit = t.dir == 1
            ? (t.tp.isFinite && c.high  >= t.tp)
            : (t.tp.isFinite && c.low   <= t.tp);
        final bool slWickHit = t.dir == 1
            ? c.low  <= t.sl
            : c.high >= t.sl;

        // Close-based detection (only meaningful when useCloseExecution=true).
        final bool tpCloseHit = t.dir == 1
            ? (t.tp.isFinite && c.close >= t.tp)
            : (t.tp.isFinite && c.close <= t.tp);
        final bool slCloseHit = t.dir == 1
            ? c.close <= t.sl
            : c.close >= t.sl;

        // §3 — Missed TP metric: wick touched TP but close didn't.
        // Only tracked in close-execution mode to be meaningful.
        if (useCloseExecution && tpWickHit && !tpCloseHit) {
          localMissedTP++;
          _missedTP++;
        }

        // Effective triggers: either wick-based or close-based per config.
        // SL always uses wick (you can't ignore a hard margin breach).
        final bool effectiveTpHit = useCloseExecution ? tpCloseHit : tpWickHit;
        final bool effectiveSlHit = useCloseExecution ? slWickHit  : slWickHit;

        final bool reverseSignal = sig == -t.dir && sig != 0;

        String rsn = ''; double at = 0; bool closed = false;

        if (effectiveTpHit && effectiveSlHit) {
          // ── Both TP and SL hit same candle → resolve via FillMode ─────────
          final result = _resolveBothHit(t, c);
          rsn = result.$1;
          at  = result.$2;
          closed = true;

          // Apply slippage post-resolution.
          // FillMode.expected: expectedExit already blends levels realistically,
          // so we apply only half-slippage to avoid over-penalising.
          if (fillMode == FillMode.expected) {
            // Blend: partial TP + partial SL → apply averaged slippage.
            at = t.dir == 1
                ? at * (1.0 - _slippage / 200.0)
                : at * (1.0 + _slippage / 200.0);
          } else if (rsn == 'SL') {
            // §5 — SL slippage: stop-hunt / panic-fill model.
            at = t.dir == 1
                ? at * (1.0 - _slippage / 100.0)
                : at * (1.0 + _slippage / 100.0);
            localSlippedSL++; _slippedSL++;
          } else {
            // §6 — TP slippage: limit order, slightly worse fill.
            at = t.dir == 1
                ? at * (1.0 - _slippage / 200.0)
                : at * (1.0 + _slippage / 200.0);
          }

        } else if (effectiveSlHit) {
          // ── SL only ───────────────────────────────────────────────────────
          // §5 — SL slippage: stop-hunt / panic-fill model.
          // probabilistic SL slippage model
bool slip = _rng.nextDouble() < 0.4; // 40% chance of slippage

if (slip) {
  at = t.dir == 1
      ? t.sl * (1.0 - _slippage / 100.0)
      : t.sl * (1.0 + _slippage / 100.0);
  localSlippedSL++; 
  _slippedSL++;
} else {
  at = t.sl; // clean fill
}
          rsn = 'SL'; closed = true;
          localSlippedSL++; _slippedSL++;

        } else if (effectiveTpHit) {
          // ── TP only ───────────────────────────────────────────────────────
          // §6 — TP slippage: limit order slightly worse (half-rate vs SL).
          at = t.dir == 1
              ? t.tp * (1.0 - _slippage / 200.0)
              : t.tp * (1.0 + _slippage / 200.0);
          rsn = 'TP'; closed = true;

        } else if (reverseSignal) {
          // ── Reverse signal (FLIP) — market order at close ─────────────────
          at = c.close; rsn = 'FL'; closed = true;
        }

        if (closed) {
          t.open = false; t.exitP = at; t.reason = rsn;
          final gp = t.dir == 1
              ? (at - t.entry) * t.qty * _leverage
              : (t.entry - at) * t.qty * _leverage;
          final costs = _notional * _leverage * (_commission + _slippage) / 100 * 2
                      + t.fundPaid;
          netEq += gp - costs;
          if (rsn == 'SL' || rsn == 'FL') {
            if (t.dir == 1) longCd = _cooldown; else shortCd = _cooldown;
          }
          active = null;
        }
      }

      // ── Fix 6: volume SMA filter — built from previous bars only ──────────
      final volSma = volBuf.length >= 20
          ? volBuf.fold(0.0, (s, v) => s + v) / volBuf.length
          : 0.0;
      volBuf.add(c.volume);
      if (volBuf.length > 20) volBuf.removeAt(0);
      final volOk = volBuf.length < 20 || c.volume >= volSma * 0.5;

      if (longCd  > 0) longCd--;
      if (shortCd > 0) shortCd--;

      // ── New entry: only at first exec bar of HTF window (ei == 0) ─────────
      if (active == null && pending == null && volOk && ei == 0) {
        if (sig == 1  && prevSig != 1  && longCd  == 0) {
          pending = _Pend(dir:  1);
        } else if (sig == -1 && prevSig != -1 && shortCd == 0) {
          pending = _Pend(dir: -1);
        }
      }

      // ── Drawdown tracking (mark-to-market on every 5m bar) ───────────────
      double op = 0;
      if (active != null && active!.open) {
        final t = active!;
        final raw = t.dir == 1
            ? (c.close - t.entry) * t.qty * _leverage
            : (t.entry - c.close) * t.qty * _leverage;
        op = raw
           - _notional * _leverage * (_commission + _slippage) / 100 * 2
           - t.fundPaid;
      }
      final cur = netEq + op;
      if (cur > peak) peak = cur;
      if (peak - cur > maxDd) maxDd = peak - cur;
    }
  }

  // ── §7 Exit condition 4: force-close open trade at end of data ───────────
  if (active != null && active!.open) {
    final t  = active!;
    t.open   = false;
    t.exitP  = windows.last.isNotEmpty ? windows.last.last.close : t.entry;
    t.reason = 'END';
    final gp = t.dir == 1
        ? (t.exitP - t.entry) * t.qty * _leverage
        : (t.entry - t.exitP) * t.qty * _leverage;
    netEq += gp
           - _notional * _leverage * (_commission + _slippage) / 100 * 2
           - t.fundPaid;
  }

  // ── Trade statistics ──────────────────────────────────────────────────────
  final closed = trades.where((t) => t.reason.isNotEmpty).toList();
  final wins   = closed.where((t) {
    final gp = t.dir == 1
        ? (t.exitP - t.entry) * t.qty * _leverage
        : (t.entry - t.exitP) * t.qty * _leverage;
    return gp > 0;
  }).length;

  // §8 — Print execution quality metrics per config (non-zero only).
  if (localMissedTP > 0 || localSlippedSL > 0) {
    stdout.write(
      '    [ExecQ] $asset/$strategy/$htfLabel'
      ' | MissedTP: $localMissedTP'
      ' | SL-Slippage events: $localSlippedSL\n',
    );
  }

  final dep    = _notional * _leverage;
  final ret    = dep > 0 ? netEq / dep * 100  : 0.0;
  final ddP    = dep > 0 ? maxDd  / dep * 100  : 0.0;
  final calmar = ddP.abs() > 0 ? ret / ddP.abs() : 0.0;

  String grade;
  if      (calmar >= 5 && ret >= 50 && ddP < 20) grade = 'A ★★★';
  else if (calmar >= 3 && ret >= 30 && ddP < 30) grade = 'B ★★';
  else if (calmar >= 1 && ret >= 10 && ddP < 40) grade = 'C ★';
  else if (ret > 0)                               grade = 'D';
  else                                            grade = 'F';

  return Res(
    asset: asset, strategy: strategy, htf: htfLabel,
    trades: closed.length, wins: wins,
    netPnl: netEq, returnPct: ret,
    maxDdPct: ddP.abs(), calmar: calmar, grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  final buf = StringBuffer();
  void log(String s) { print(s); buf.writeln(s); }

  // Reset global execution metrics for this run.
  _missedTP  = 0;
  _slippedSL = 0;

  // Discover assets with both 15m and 5m CSVs.
  final dir15  = Directory('$_root/15m');
  final assets = dir15.listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.csv'))
      .map((f) {
        final name = f.path.split('/').last.replaceAll('15m.csv', '');
        final f5   = File('$_root/5m/${name}5m.csv');
        return f5.existsSync() ? (name, f.path, f5.path) : null;
      })
      .whereType<(String, String, String)>()
      .toList();

  log('Found ${assets.length} assets with 15m+5m data.\n');
  log('FillMode        : $fillMode');
  log('CloseExecution  : $useCloseExecution');
  log('Slippage/side   : $_slippage%');
  log('Commission      : $_commission%');
  log('Notional        : \$$_notional × ${_leverage}x leverage\n');

  final htfDefs = [
    (2, '30m'), (3, '45m'), (4, '60m'), (6, '90m'),
  ];

  final allResults = <Res>[];
  int tested = 0;

  for (final (sym, p15, p5) in assets) {
    stdout.write('  $sym ... '); buf.write('  $sym ... ');
    final c15 = _load(p15);
    final c5  = _clean(_load(p5), 5);

    for (final (mult, htfLbl) in htfDefs) {
      final htf = _agg(c15, mult);
      if (htf.length < 60) continue;

      // Pre-bucket 5m candles into HTF windows ONCE per asset×HTF.
      final windows = _bucket(htf, c5);

      // Precompute indicators O(n).
      final atr14 = _atr(htf, 14);
      final atr10 = _atr(htf, 10);
      final sfi10 = _sfi(htf, 10, 1.7, atr10);
      final sfi14 = _sfi(htf, 14, 2.0, atr14);
      final hh20  = _dHH(htf, 20);
      final ll20  = _dLL(htf, 20);
      final hh40  = _dHH(htf, 40);
      final ll40  = _dLL(htf, 40);
      final ema9  = _ema(htf, 9);
      final ema21 = _ema(htf, 21);

      // ── Build signal arrays ───────────────────────────────────────────────

      // S3: Donchian(20) — momentary breakout signal.
      final sigDon20 = List.generate(htf.length, (i) {
        if (i == 0) return 0;
        if (htf[i].close > hh20[i]) return 1;
        if (htf[i].close < ll20[i]) return -1;
        return 0;
      });

      // S4: Donchian(40) — momentary breakout signal.
      final sigDon40 = List.generate(htf.length, (i) {
        if (i == 0) return 0;
        if (htf[i].close > hh40[i]) return 1;
        if (htf[i].close < ll40[i]) return -1;
        return 0;
      });

      // Sustained Donchian: once triggered, stay in direction until opposite.
      final sigDon20s = _sustained(sigDon20);
      final sigDon40s = _sustained(sigDon40);

      // S5: EMA cross (sustained — once crossed, stay).
      final sigEma = List.generate(htf.length, (i) {
        if (i == 0) return 0;
        if (ema9[i] > ema21[i]) return 1;
        if (ema9[i] < ema21[i]) return -1;
        return 0;
      });

      // S6: SFI + Donchian combo — both must agree.
      final sigCombo10 = List.generate(htf.length, (i) {
        if (sfi10[i] == 1  && sigDon20s[i] == 1)  return  1;
        if (sfi10[i] == -1 && sigDon20s[i] == -1) return -1;
        return 0;
      });
      final sigCombo14 = List.generate(htf.length, (i) {
        if (sfi14[i] == 1  && sigDon40s[i] == 1)  return  1;
        if (sfi14[i] == -1 && sigDon40s[i] == -1) return -1;
        return 0;
      });

      // ── Strategy variants ─────────────────────────────────────────────────
      final variants = [
        // S1: SFI ride until flip
        ('S1:SFI10-Ride',       sfi10,      0.0, 2.0),
        ('S1:SFI14-Ride',       sfi14,      0.0, 2.0),
        // S2: SFI fixed stops
        ('S2:SFI10-TP3SL1.5',  sfi10,      3.0, 1.5),
        ('S2:SFI14-TP3SL1.5',  sfi14,      3.0, 1.5),
        ('S2:SFI10-TP2SL1',    sfi10,      2.0, 1.0),
        // S3: Donchian(20)
        ('S3:Don20-TP3SL1.5',  sigDon20s,  3.0, 1.5),
        ('S3:Don20-TP4SL2',    sigDon20s,  4.0, 2.0),
        // S4: Donchian(40)
        ('S4:Don40-TP3SL1.5',  sigDon40s,  3.0, 1.5),
        ('S4:Don40-TP4SL2',    sigDon40s,  4.0, 2.0),
        // S5: EMA cross
        ('S5:EMA9x21-TP3SL1.5',sigEma,     3.0, 1.5),
        ('S5:EMA9x21-Ride',    sigEma,     0.0, 2.0),
        // S6: Combo
        ('S6:SFI10+Don20',     sigCombo10, 3.0, 1.5),
        ('S6:SFI14+Don40',     sigCombo14, 3.0, 1.5),
      ];

      for (final (name, sigs, tpA, slA) in variants) {
        final r = _backtest(sym, name, htfLbl, htf, windows, sigs, atr14, tpA, slA);
        if (r.netPnl > 0) allResults.add(r);
        tested++;
      }
    }
    stdout.writeln('done'); buf.writeln('done');
  }

  log('\nTested $tested configs across ${assets.length} assets.');
  log('Profitable configs: ${allResults.length}');

  // §8 — Global execution quality summary.
  log('\n── EXECUTION QUALITY (global) ───────────────────────────────────────────────────');
  log('  FillMode            : $fillMode');
  log('  Close-exec mode     : $useCloseExecution');
  log('  Missed TP (total)   : $_missedTP');
  log('  SL slippage events  : $_slippedSL');

  if (allResults.isEmpty) {
    log('\nNo profitable configs. Strategy hunt exhausted.');
    _writeReport(buf);
    return;
  }

  allResults.sort((a, b) => b.calmar.compareTo(a.calmar));

  // ── Master table ──────────────────────────────────────────────────────────
  final sep = '═' * 100;
  log('\n╔$sep╗');
  log('║${_c('PROFITABLE CONFIGS — ALL ASSETS × HTF × STRATEGIES (bias-free, v9 execution)', 100)}║');
  log('╠════╦═══════════════╦══════════════════════════╦══════╦══════╦═════════╦═══════╦════════╦══════════════╣');
  log('║  # ║ Asset         ║ Strategy                 ║  HTF ║  Trd ║   WR%   ║  Net\$ ║   DD%  ║ Calmar Grade ║');
  log('╠════╬═══════════════╬══════════════════════════╬══════╬══════╬═════════╬═══════╬════════╬══════════════╣');

  for (int i = 0; i < allResults.length && i < 80; i++) {
    final r  = allResults[i];
    final n  = (i + 1).toString().padLeft(3);
    final as = r.asset.padRight(13);
    final st = r.strategy.padRight(24);
    final ht = r.htf.padLeft(4);
    final tr = r.trades.toString().padLeft(4);
    final wr = '${r.wr.toStringAsFixed(1)}%'.padLeft(6);
    final np = ((r.netPnl >= 0 ? '+' : '') + r.netPnl.toStringAsFixed(1)).padLeft(6);
    final dd = '${r.maxDdPct.toStringAsFixed(1)}%'.padLeft(6);
    final ca = r.calmar.toStringAsFixed(2).padLeft(6);
    log('║$n ║ $as║ $st║  $ht║$tr  ║ $wr ║$np ║$dd  ║$ca ${r.grade.padRight(5)}║');
  }
  log('╚════╩═══════════════╩══════════════════════════╩══════╩══════╩═════════╩═══════╩════════╩══════════════╝');

  // ── By-strategy summary ───────────────────────────────────────────────────
  log('\n── STRATEGY SUMMARY (profitable count + avg Calmar) ─────────────────────────────');
  final bySt = <String, List<Res>>{};
  for (final r in allResults) {
    final key = r.strategy.split('-')[0];
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
    final aG  = e.value.where((r) => r.grade.startsWith('A')).length;
    final bG  = e.value.where((r) => r.grade.startsWith('B')).length;
    log('  ${e.key.padRight(22)} → ${e.value.length.toString().padLeft(3)} profitable | '
        'AvgCalmar: ${avg.toStringAsFixed(2).padLeft(6)} | A:$aG B:$bG');
  }

  // ── Best single config ────────────────────────────────────────────────────
  final best = allResults.first;
  log('\n── BEST SINGLE CONFIG ───────────────────────────────────────────────────────────');
  log('  Asset    : ${best.asset}');
  log('  Strategy : ${best.strategy}');
  log('  HTF      : ${best.htf}');
  log('  Trades   : ${best.trades}  WR: ${best.wr.toStringAsFixed(1)}%');
  log('  Net PnL  : \$${best.netPnl.toStringAsFixed(2)}');
  log('  Return   : ${best.returnPct.toStringAsFixed(1)}%');
  log('  Max DD   : ${best.maxDdPct.toStringAsFixed(1)}%');
  log('  Calmar   : ${best.calmar.toStringAsFixed(2)}');
  log('  Grade    : ${best.grade}');

  _writeReport(buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _writeReport(StringBuffer buf) {
  final ts   = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
  final path = '/Users/ayush/Desktop/strategy_hunt_$ts.txt';
  File(path).writeAsStringSync(buf.toString());
  print('\nReport saved → $path');
}

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

/// Centre-pad [s] to width [w].
String _c(String s, int w) {
  final p = ((w - s.length) / 2).floor();
  return ' ' * p + s + ' ' * (w - s.length - p);
}


///Updated version of strategy hunt through claude 