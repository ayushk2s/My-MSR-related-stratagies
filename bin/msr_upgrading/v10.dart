// =============================================================================
// REVERSAL STRATEGY V3 — High-Conviction Multi-Signal Confluence Engine
// =============================================================================
//
// Core Philosophy: Only trade when ≥3 independent reversal signals agree,
//   and at least ONE anchor signal (SFI flip OR SR proximity) is present.
//   A trend-follower fires on every flip. A reversal engine waits for the
//   EXHAUSTION of a move — then enters counter-trend with tight risk.
//
// WHAT CHANGED FROM V1 → V3 (all bug fixes + calibrated improvements):
//
//   [BUG FIX 1] ATR filter was inverted (<) → now correctly >= _minAtrPct
//               Effect: entries now fire in volatile markets, not choppy ones
//
//   [BUG FIX 2] Invalid SL/TP geometry used break (halted entire backtest)
//               → changed to continue. Effect: all bars in all assets now run.
//
//   [FIX A] RSI divergence quality gate: RSI must be < 45 (long) or > 55 (short)
//           Mid-range divergences are noise. Extremes confirm exhaustion.
//           (V2 used 42/58 — too tight; 45/55 is calibrated to keep more signals)
//
//   [FIX B] Soft anchor: at least ONE of {SFI flip, SR proximity} must be present.
//           V2 required BOTH — statistically near-impossible on same bar.
//           V3 uses OR: any strong reversal setup must have *some* structural anchor.
//
//   [FIX C] SR proximity widened from 0.30% to 0.50%.
//           Crypto SR zones are wider than equities. 0.30% was too tight.
//
//   [FIX D] Minimum R:R gate: TP1 must be ≥ 1.3× the SL distance.
//           Eliminates negative-expectancy entries before they happen.
//
//   [FIX E] After TP1: SL moves to entry ± 0.20× ATR buffer (not exact breakeven).
//           Exact breakeven is a liquidity magnet. Buffer prevents 1-tick wipeouts.
//
//   [FIX F] TP2 multiplier widened: 3.5× ATR (was 2.5× in v1).
//           Gives the 30% tier room to capture the full impulse move.
//
//   [FIX G] Position split changed: 50% TP1 / 30% TP2 / 20% runner (was 60/25/15).
//           More size rides to TP2+ after TP1 confirms the move is real.
//
// SIGNALS (each worth 1 point, max score 5):
//   [+1] SFI flip    — SFI reverses direction on ENTRY timeframe
//   [+1] RSI div     — price new extreme + RSI diverges + RSI at extreme level
//   [+1] Vol spike   — bar volume > 2× 20-bar SMA (capitulation / climax)
//   [+1] Pin/engulf  — rejection wick ≥ 2× body, or full engulfing candle
//   [+1] SR tight    — price within 0.5% of a known support/resistance zone
//
// ENTRY GATE:
//   score ≥ 3  AND
//   (SFI flip present  OR  SR proximity present)  AND   ← soft anchor [FIX B]
//   45m SFI trend not strongly opposed              AND
//   R:R ratio ≥ 1.3                                AND   ← [FIX D]
//   ATR% ≥ 0.25%                                         ← [BUG FIX 1]
//
// POSITION MANAGEMENT (3-tier split) [FIX G]:
//   50% at TP1 — next SR zone (or 1.5× ATR)  → SL moves to entry ± 0.2× ATR
//   30% at TP2 — 2nd SR zone (or 3.5× ATR)   → SL trails 1× ATR
//   20% trail  — rides until SFI flip on 5m   → hard SL 3× ATR from entry
//
// HARD SL: 1.5× ATR from fill price (SL wins when TP+SL hit same bar)
// COOLDOWN: 5 bars after SL hit on full position
//
// COSTS (fully bias-free, identical to v1/v2):
//   Commission: 0.025% per side (blended maker/taker)
//   Slippage:   0.04%  per side
//   Funding:    0.01%  per 8h
//   Capital:    100 USDT × 5× leverage = 500 USDT notional
//
// BIAS-FREE GUARANTEES:
//   • All indicators computed from closed bar [i-1] before entry at bar [i] open
//   • RSI divergence lookback uses only past closes
//   • SR zones: checkHist:false, break-bar computed from past closes only
//   • Volume SMA: 20-bar trailing, excludes current bar
//   • SL wins when TP and SL both triggered on the same 5m bar
//   • Funding accrued per 8h as position ages
//
// ASSETS: all 5m CSVs in the data directory
// TIMEFRAMES: Entry 5m, Trend context 45m
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _base       = '/Users/ayush/Desktop/candlestick data/5m';
const _notional   = 100.0;
const _leverage   = 5.0;
const _dep        = _notional * _leverage;   // 500 USDT notional
const _commission = 0.025;                   // % per side
const _slippage   = 0.04;                    // % per side
const _funding    = 0.01;                    // % per 8h

// Entry gates
const _minScore     = 3;      // minimum confluence score (out of 5) to enter
const _minAtrPct    = 0.25;   // [BUG FIX 1] min ATR% — skip choppy/thin markets
const _minRR        = 1.3;    // [FIX D] minimum R:R: TP1 dist must be ≥ 1.3× SL dist
const _cooldownBars = 5;      // bars to wait after a full stop-out

// RSI extreme thresholds for divergence validity [FIX A]
// Widened vs v2 (42/58) so more genuine divergences qualify
const _rsiOversold   = 45.0;  // long divergence valid only if RSI < this
const _rsiOverbought = 55.0;  // short divergence valid only if RSI > this

// SR zone proximity [FIX C] — widened from 0.30% in v1/v2 to 0.50%
// Crypto SR zones need a wider capture radius; 0.30% was too tight
const _srProx = 0.50;         // % within which price is "at" a zone

// Stop / target multipliers (ATR fallback when no SR zone found)
const _slAtr    = 1.5;        // hard SL distance in ATR units
const _tp1Atr   = 1.5;        // TP1 fallback
const _tp2Atr   = 3.5;        // [FIX F] TP2 fallback — widened from 2.5
const _trailAtr = 3.0;        // trailing hard stop for the 20% runner
const _beBufAtr = 0.20;       // [FIX E] buffer when moving SL to breakeven

// SL zone buffer
const _slBuf = 0.15;          // % beyond zone edge for SL placement

// Position split fractions [FIX G] — was 60/25/15
const _sp1 = 0.50;            // closed at TP1
const _sp2 = 0.30;            // closed at TP2
const _sp3 = 0.20;            // runner — SFI flip or trail stop

// Indicator parameters
const _srLen5    = 8;
const _srLen45   = 10;
const _volMult   = 2.0;       // volume spike: must be 2× the 20-bar SMA
const _rsiPeriod = 14;
const _rsiLook   = 5;         // RSI divergence lookback in bars

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset;
  final int    trades, wins;
  final double netPnl, returnPct, maxDdPct, calmar;
  final double totFees, totSlip, totFund;
  final String grade;
  final Map<String, int> exitBreakdown;

  Res({
    required this.asset,
    required this.trades, required this.wins,
    required this.netPnl, required this.returnPct,
    required this.maxDdPct, required this.calmar,
    required this.totFees, required this.totSlip, required this.totFund,
    required this.grade, required this.exitBreakdown,
  });

  double get wr => trades == 0 ? 0.0 : wins / trades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS
// ─────────────────────────────────────────────────────────────────────────────

class SfiBar {
  final double up, dn;
  final int    trend;       // +1 uptrend, -1 downtrend
  final bool   flipUp, flipDn;
  const SfiBar(this.up, this.dn, this.trend, this.flipUp, this.flipDn);
}

List<SfiBar> computeSfi(List<Candle> cs, int period, double mult) {
  final tr  = <double>[];
  final atr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
    if (i == 0)         { atr.add(tr[0]); }
    else if (i < period){ atr.add((atr[i-1] * i + tr[i]) / (i + 1)); }
    else                { atr.add((atr[i-1] * (period - 1) + tr[i]) / period); }
  }
  double pUp = cs[0].ohlc4 - mult * atr[0];
  double pDn = cs[0].ohlc4 + mult * atr[0];
  int prevT  = 1;
  final out  = <SfiBar>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp
            ? max(cs[i].ohlc4 - mult * a, pUp)
            : cs[i].ohlc4 - mult * a)
        : cs[i].ohlc4 - mult * a;
    final dn = i > 0
        ? (cs[i-1].close < pDn
            ? min(cs[i].ohlc4 + mult * a, pDn)
            : cs[i].ohlc4 + mult * a)
        : cs[i].ohlc4 + mult * a;
    int t = prevT;
    if (prevT == -1 && cs[i].close > pDn) t =  1;
    else if (prevT == 1 && cs[i].close < pUp) t = -1;
    out.add(SfiBar(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

List<double> computeRsi(List<Candle> cs, int p) {
  final out  = <double>[];
  double ag  = 0, al = 0;
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(50.0); continue; }
    final ch = cs[i].close - cs[i-1].close;
    if (i <= p) {
      ag = (ag * (i - 1) + max(ch, 0.0)) / i;
      al = (al * (i - 1) + max(-ch, 0.0)) / i;
    } else {
      ag = (ag * (p - 1) + max(ch, 0.0)) / p;
      al = (al * (p - 1) + max(-ch, 0.0)) / p;
    }
    out.add(al == 0 ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al));
  }
  return out;
}

// 20-bar volume SMA — trailing, excludes current bar (bias-free)
List<double> computeVolSma(List<Candle> cs, int p) {
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(0.0); continue; }
    final start = max(0, i - p);
    double sum  = 0;
    for (int j = start; j < i; j++) sum += cs[j].volume;
    out.add(sum / (i - start));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SIGNAL HELPERS
// ─────────────────────────────────────────────────────────────────────────────

// RSI bullish divergence: price lower low in past [look] bars, RSI higher low.
// [FIX A] Caller must also check rsi[i] < _rsiOversold.
bool rsiDivLong(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  int    bar  = i - 1;
  double low  = cs[i-1].low;
  for (int j = i - look; j < i - 1; j++) {
    if (cs[j].low < low) { low = cs[j].low; bar = j; }
  }
  if (cs[i].low > low) return false;
  return rsi[i] > rsi[bar];
}

// RSI bearish divergence: price higher high in past [look] bars, RSI lower high.
// [FIX A] Caller must also check rsi[i] > _rsiOverbought.
bool rsiDivShort(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  int    bar  = i - 1;
  double high = cs[i-1].high;
  for (int j = i - look; j < i - 1; j++) {
    if (cs[j].high > high) { high = cs[j].high; bar = j; }
  }
  if (cs[i].high < high) return false;
  return rsi[i] < rsi[bar];
}

// Bullish pin bar: lower wick ≥ 2× body, close in upper 30% of range
bool pinBarLong(Candle c) {
  final body  = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  final lWick = min(c.open, c.close) - c.low;
  return lWick >= body * 2.0 && (c.close - c.low) / range >= 0.70;
}

// Bearish pin bar: upper wick ≥ 2× body, close in lower 30% of range
bool pinBarShort(Candle c) {
  final body  = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  final uWick = c.high - max(c.open, c.close);
  return uWick >= body * 2.0 && (c.high - c.close) / range >= 0.70;
}

// Bullish engulfing: prev bearish, curr bullish, curr body engulfs prev body
bool engulfLong(List<Candle> cs, int i) {
  if (i == 0) return false;
  final prev = cs[i-1]; final curr = cs[i];
  return prev.close < prev.open
      && curr.close > curr.open
      && curr.open  < prev.close
      && curr.close > prev.open;
}

// Bearish engulfing: prev bullish, curr bearish, curr body engulfs prev body
bool engulfShort(List<Candle> cs, int i) {
  if (i == 0) return false;
  final prev = cs[i-1]; final curr = cs[i];
  return prev.close > prev.open
      && curr.close < curr.open
      && curr.open  > prev.close
      && curr.close < prev.open;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR ZONE HELPERS (bias-free — identical to v1/v2)
// ─────────────────────────────────────────────────────────────────────────────

List<int?> computeBreakBars(List<SRZone> zones, List<Candle> cs, int len) {
  final out = List<int?>.filled(zones.length, null);
  for (int zi = 0; zi < zones.length; zi++) {
    final z    = zones[zi];
    final from = z.boxLeft + len;
    for (int b = from; b < cs.length; b++) {
      if (z.isResistance) {
        if (cs[b].close > z.boxTop)    { out[zi] = b; break; }
      } else {
        if (cs[b].close < z.boxBottom) { out[zi] = b; break; }
      }
    }
  }
  return out;
}

List<SRZone> _knownSup(List<SRZone> z, List<int?> bb, int bar, int len) =>
    [for (int i = 0; i < z.length; i++)
      if (!z[i].isResistance && z[i].boxLeft + len <= bar
          && (bb[i] == null || bb[i]! > bar)) z[i]];

List<SRZone> _knownRes(List<SRZone> z, List<int?> bb, int bar, int len) =>
    [for (int i = 0; i < z.length; i++)
      if ( z[i].isResistance && z[i].boxLeft + len <= bar
          && (bb[i] == null || bb[i]! > bar)) z[i]];

SRZone? _nearestSup(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxTop >= price * 1.001) continue;
    final d = price - z.boxTop;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

SRZone? _nearestRes(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxBottom <= price * 0.999) continue;
    final d = z.boxBottom - price;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

bool _withinPct(SRZone z, double price, double pct) {
  final buf = price * pct / 100.0;
  return price >= z.boxBottom - buf && price <= z.boxTop + buf;
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

List<Candle> _clean(List<Candle> raw, int intervalMin) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty &&
        c.time.difference(out.last.time).inMinutes > intervalMin * 3) continue;
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

double _pnl(int dir, double entry, double exitP, double frac) =>
    dir == 1
        ? (exitP - entry) / entry * _dep * frac
        : (entry - exitP) / entry * _dep * frac;

double _cost(double frac) =>
    _dep * frac * (_commission + _slippage) / 100.0 * 2.0;

// ─────────────────────────────────────────────────────────────────────────────
// ACTIVE TRADE STATE
// ─────────────────────────────────────────────────────────────────────────────

class _Trade {
  final int    dir;
  final double entry, qty;
  final double hardSl;
  double sl;               // dynamic: tightens after TP1 and TP2
  final double tp1, tp2;
  double trailStop;        // runner trailing stop (tightens after TP2 hit)

  bool tp1Hit = false;
  bool tp2Hit = false;
  bool open   = true;

  double fundPaid     = 0.0;
  double realizedPnl  = 0.0;   // cumulative net after partial closes
  String reason       = '';

  _Trade({
    required this.dir, required this.entry, required this.qty,
    required this.hardSl, required this.sl,
    required this.tp1, required this.tp2, required this.trailStop,
  });

  double get openFraction =>
      tp1Hit && tp2Hit ? _sp3
      : tp1Hit         ? _sp2 + _sp3
      :                  1.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE BACKTEST
// ─────────────────────────────────────────────────────────────────────────────

Res _backtest(String sym, List<Candle> c5) {
  // Aggregate 5m → 45m (9 bars per 45m bar)
  final c45 = _agg(c5, 9);

  // ── Indicator arrays ───────────────────────────────────────────────────
  final sfi5    = computeSfi(c5,  10, 1.7);
  final sfi45   = computeSfi(c45, 14, 2.0);
  final rsi5    = computeRsi(c5, _rsiPeriod);
  final volSma5 = computeVolSma(c5, 20);

  // ATR14 Wilder's on 5m
  final atr5 = <double>[];
  {
    double prev = c5[0].high - c5[0].low;
    for (int i = 0; i < c5.length; i++) {
      final p  = i == 0 ? c5[0].close : c5[i-1].close;
      final tr = max(c5[i].high - c5[i].low,
                     max((c5[i].high - p).abs(), (c5[i].low - p).abs()));
      prev = i == 0 ? tr : (prev * 13.0 + tr) / 14.0;
      atr5.add(prev);
    }
  }

  // ── SR zones (bias-free) ───────────────────────────────────────────────
  List<SRZone> _zones(List<Candle> cs, int len) {
    final sr = SupportResistanceIndicator(
        detectionLength: len, srMargin: 2.0, avoidFBO: true, checkHist: false);
    return [...sr.calculate(cs).support, ...sr.calculate(cs).resistance];
  }

  final zones5  = _zones(c5,  _srLen5);
  final zones45 = _zones(c45, _srLen45);
  final bb5     = computeBreakBars(zones5,  c5,  _srLen5);
  final bb45    = computeBreakBars(zones45, c45, _srLen45);

  // ── State ──────────────────────────────────────────────────────────────
  double netEq = 0, peak = 0, maxDd = 0;
  double totFee = 0, totSlp = 0, totFund = 0;
  int tradeCount = 0, wins = 0;
  int cooldown   = 0;
  final exitBreakdown = <String, int>{};
  _Trade?  active;
  int?     pendDir;
  DateTime lastFund = DateTime(2000);

  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i45 = i ~/ 9;
    if (cooldown > 0) cooldown--;

    // ATR from previous CLOSED bar — bias-free
    final atr = atr5[i - 1];

    // ── Funding every 8h ──────────────────────────────────────────────
    if (active != null && active!.open &&
        c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final charge = _dep * active!.openFraction * _funding / 100.0;
      active!.fundPaid += charge;
      totFund         += charge;
    }

    // ── Fill pending entry at THIS bar's OPEN ────────────────────────
    // Signal fired at previous bar's close; we fill at this bar's open.
    if (active == null && pendDir != null && cooldown == 0) {
      final dir  = pendDir!;
      pendDir    = null;
      final fill = c.open;

      // [BUG FIX 1] was < (inverted). Now correctly skips thin/choppy bars.
      if (atr / fill * 100 >= _minAtrPct) {
        final i45s  = i45.clamp(0, sfi45.length - 1);
        final sup5  = _knownSup(zones5,  bb5,  i,    _srLen5);
        final res5  = _knownRes(zones5,  bb5,  i,    _srLen5);
        final sup45 = _knownSup(zones45, bb45, i45s, _srLen45);
        final res45 = _knownRes(zones45, bb45, i45s, _srLen45);
        final allSup = [...sup5, ...sup45];
        final allRes = [...res5, ...res45];

        // ── Hard SL: nearest SR zone or ATR fallback ────────────────
        double slPrice;
        if (dir == 1) {
          final ns = _nearestSup(allSup, fill);
          slPrice  = ns != null
              ? ns.boxBottom * (1.0 - _slBuf / 100.0)
              : fill - _slAtr * atr;
          if (slPrice >= fill) slPrice = fill - _slAtr * atr;
        } else {
          final nr = _nearestRes(allRes, fill);
          slPrice  = nr != null
              ? nr.boxTop * (1.0 + _slBuf / 100.0)
              : fill + _slAtr * atr;
          if (slPrice <= fill) slPrice = fill + _slAtr * atr;
        }

        // ── TP1: next SR zone or ATR fallback ───────────────────────
        double tp1Price;
        if (dir == 1) {
          final nr = _nearestRes(allRes, fill);
          tp1Price = nr != null ? nr.boxBottom : fill + _tp1Atr * atr;
        } else {
          final ns = _nearestSup(allSup, fill);
          tp1Price = ns != null ? ns.boxTop    : fill - _tp1Atr * atr;
        }

        // ── TP2: second SR zone or widened ATR fallback [FIX F] ────
        double tp2Price;
        if (dir == 1) {
          final sorted = ([...allRes]
              ..sort((a, b) => a.boxBottom.compareTo(b.boxBottom)));
          final above = sorted.where((z) => z.boxBottom > tp1Price).toList();
          tp2Price = above.isNotEmpty ? above.first.boxBottom : fill + _tp2Atr * atr;
        } else {
          final sorted = ([...allSup]
              ..sort((a, b) => b.boxTop.compareTo(a.boxTop)));
          final below = sorted.where((z) => z.boxTop < tp1Price).toList();
          tp2Price = below.isNotEmpty ? below.first.boxTop : fill - _tp2Atr * atr;
        }

        // Geometry sanity check
        final validL = dir ==  1 && tp1Price > fill && fill > slPrice && tp2Price > tp1Price;
        final validS = dir == -1 && tp1Price < fill && fill < slPrice && tp2Price < tp1Price;

        // [BUG FIX 2] was break — halted entire backtest. Now continue.
        if (!validL && !validS) continue;

        // [FIX D] Minimum R:R gate — skip entry if TP1 < 1.3× SL distance
        final rrRatio = (tp1Price - fill).abs() / (fill - slPrice).abs();
        if (rrRatio < _minRR) continue;

        final trailStop = dir == 1 ? fill - _trailAtr * atr : fill + _trailAtr * atr;

        totFee += _dep * _commission / 100.0;
        totSlp += _dep * _slippage   / 100.0;

        active = _Trade(
          dir: dir, entry: fill, qty: _dep / fill,
          hardSl: slPrice, sl: slPrice,
          tp1: tp1Price, tp2: tp2Price, trailStop: trailStop,
        );
        tradeCount++;
      }
    }

    // ── Exit logic (SL wins same bar when TP and SL both triggered) ──
    if (active != null && active!.open) {
      final t = active!;

      // Tighten trailing stop for runner after TP2 is hit
      if (t.tp1Hit && t.tp2Hit) {
        final newTrail = t.dir == 1
            ? max(t.trailStop, c.close - _trailAtr * atr)
            : min(t.trailStop, c.close + _trailAtr * atr);
        t.trailStop = newTrail;
      }

      final slHit    = t.dir ==  1 ? c.low  <= t.sl      : c.high >= t.sl;
      final tp1Hit   = !t.tp1Hit && (t.dir ==  1 ? c.high >= t.tp1 : c.low  <= t.tp1);
      final tp2Hit   = t.tp1Hit && !t.tp2Hit &&
                       (t.dir == 1 ? c.high >= t.tp2 : c.low <= t.tp2);
      final trailHit = t.tp1Hit && t.tp2Hit &&
                       (t.dir == 1 ? c.low <= t.trailStop : c.high >= t.trailStop);
      // SFI flip signal uses [i-1] (last closed bar) — bias-free
      final sfiFlip  = t.tp1Hit && t.tp2Hit &&
                       (t.dir == 1 ? sfi5[i-1].flipDn : sfi5[i-1].flipUp);

      if (slHit) {
        // ── Full stop-out ─────────────────────────────────────────
        final frac   = t.openFraction;
        final gp     = _pnl(t.dir, t.entry, t.sl, frac);
        final cost   = _cost(frac);
        final net    = gp - cost - t.fundPaid;
        netEq       += t.realizedPnl + net;
        totFee      += cost / 2.0;
        totSlp      += cost / 2.0;
        if (t.realizedPnl + net > 0) wins++;
        t.open   = false;
        t.reason = t.tp1Hit ? (t.tp2Hit ? 'TP2+SL' : 'TP1+SL') : 'SL';
        exitBreakdown[t.reason] = (exitBreakdown[t.reason] ?? 0) + 1;
        cooldown = _cooldownBars;
        active   = null;

      } else if (tp1Hit) {
        // ── Partial close: tier 1 (50%) ───────────────────────────
        final gp   = _pnl(t.dir, t.entry, t.tp1, _sp1);
        final cost = _cost(_sp1);
        final net  = gp - cost;
        netEq         += net;
        t.realizedPnl += net;
        totFee += cost / 2.0;
        totSlp += cost / 2.0;
        t.tp1Hit = true;
        // [FIX E] SL → entry ± 0.2× ATR buffer (not exact BE)
        t.sl = t.dir == 1
            ? t.entry - _beBufAtr * atr
            : t.entry + _beBufAtr * atr;
        exitBreakdown['TP1'] = (exitBreakdown['TP1'] ?? 0) + 1;

      } else if (tp2Hit) {
        // ── Partial close: tier 2 (30%) ───────────────────────────
        final gp   = _pnl(t.dir, t.entry, t.tp2, _sp2);
        final cost = _cost(_sp2);
        final net  = gp - cost;
        netEq         += net;
        t.realizedPnl += net;
        totFee += cost / 2.0;
        totSlp += cost / 2.0;
        t.tp2Hit = true;
        // Set initial trailing stop for the 20% runner from TP2 level
        t.trailStop = t.dir == 1
            ? t.tp2 - _trailAtr * atr
            : t.tp2 + _trailAtr * atr;
        exitBreakdown['TP2'] = (exitBreakdown['TP2'] ?? 0) + 1;

      } else if (trailHit || sfiFlip) {
        // ── Close runner (20%) ────────────────────────────────────
        final exitP  = trailHit ? t.trailStop : c.open;
        final gp     = _pnl(t.dir, t.entry, exitP, _sp3);
        final cost   = _cost(_sp3);
        final net    = gp - cost - t.fundPaid;
        netEq       += t.realizedPnl + net;
        totFee      += cost / 2.0;
        totSlp      += cost / 2.0;
        if (t.realizedPnl + net > 0) wins++;
        t.open   = false;
        t.reason = trailHit ? 'TRAIL' : 'FLIP';
        exitBreakdown[t.reason] = (exitBreakdown[t.reason] ?? 0) + 1;
        active   = null;
      }
    }

    // ── Generate entry signal ─────────────────────────────────────────
    // Signal fires at bar [i] close; filled at bar [i+1] open.
    if (active == null && pendDir == null && cooldown == 0) {
      final i45s = i45.clamp(0, sfi45.length - 1);

      // Pre-fetch SR zones once for both long and short scoring
      final sup5_s  = _knownSup(zones5,  bb5,  i,    _srLen5);
      final res5_s  = _knownRes(zones5,  bb5,  i,    _srLen5);
      final sup45_s = _knownSup(zones45, bb45, i45s, _srLen45);
      final res45_s = _knownRes(zones45, bb45, i45s, _srLen45);
      final allSup  = [...sup5_s, ...sup45_s];
      final allRes  = [...res5_s, ...res45_s];

      // ── LONG scoring ────────────────────────────────────────────
      int  longScore   = 0;
      bool longSfiFl   = false;  // SFI flip present
      bool longSrProx  = false;  // SR proximity present

      // [1] SFI flip up on 5m
      if (sfi5[i].flipUp) {
        longScore++;
        longSfiFl = true;
      }

      // [2] RSI bullish divergence at oversold extreme [FIX A]
      if (rsiDivLong(c5, rsi5, i, _rsiLook) && rsi5[i] < _rsiOversold) longScore++;

      // [3] Volume spike (capitulation)
      if (volSma5[i] > 0 && c5[i].volume >= volSma5[i] * _volMult) longScore++;

      // [4] Pin bar or bullish engulfing
      if (pinBarLong(c5[i]) || engulfLong(c5, i)) longScore++;

      // [5] SR proximity — within _srProx% of a known support zone [FIX C]
      {
        final ns = _nearestSup(allSup, c5[i].close);
        if (ns != null && _withinPct(ns, c5[i].close, _srProx)) {
          longScore++;
          longSrProx = true;
        }
      }

      // ── SHORT scoring ───────────────────────────────────────────
      int  shortScore  = 0;
      bool shortSfiFl  = false;
      bool shortSrProx = false;

      // [1] SFI flip down on 5m
      if (sfi5[i].flipDn) {
        shortScore++;
        shortSfiFl = true;
      }

      // [2] RSI bearish divergence at overbought extreme [FIX A]
      if (rsiDivShort(c5, rsi5, i, _rsiLook) && rsi5[i] > _rsiOverbought) shortScore++;

      // [3] Volume spike
      if (volSma5[i] > 0 && c5[i].volume >= volSma5[i] * _volMult) shortScore++;

      // [4] Pin bar or bearish engulfing
      if (pinBarShort(c5[i]) || engulfShort(c5, i)) shortScore++;

      // [5] SR proximity — within _srProx% of a known resistance zone [FIX C]
      {
        final nr = _nearestRes(allRes, c5[i].close);
        if (nr != null && _withinPct(nr, c5[i].close, _srProx)) {
          shortScore++;
          shortSrProx = true;
        }
      }

      // ── 45m trend context gate ──────────────────────────────────
      // Block entries only when 45m SFI is STRONGLY opposed.
      final trend45 = i45s > 0 ? sfi45[i45s - 1].trend : 0;

      // ── Entry gate [FIX B] — soft anchor: SFI flip OR SR proximity ──
      // Score ≥ 3 AND at least one anchor present AND 45m not opposed
      if (longScore >= _minScore && (longSfiFl || longSrProx) && trend45 >= 0) {
        pendDir = 1;
      } else if (shortScore >= _minScore && (shortSfiFl || shortSrProx) && trend45 <= 0) {
        pendDir = -1;
      }
    }

    // ── Drawdown tracking ────────────────────────────────────────────
    double openPnl = 0;
    if (active != null && active!.open) {
      final t = active!;
      openPnl = _pnl(t.dir, t.entry, c.close, t.openFraction)
              - _cost(t.openFraction) - t.fundPaid;
    }
    final cur = netEq + openPnl;
    if (cur > peak) peak = cur;
    if (peak - cur > maxDd) maxDd = peak - cur;
  }

  // ── Force-close open position at end of data ─────────────────────────
  if (active != null && active!.open) {
    final t    = active!;
    final ep   = c5.last.close;
    final frac = t.openFraction;
    final net  = _pnl(t.dir, t.entry, ep, frac) - _cost(frac) - t.fundPaid;
    netEq += t.realizedPnl + net;
    if (t.realizedPnl + net > 0) wins++;
    tradeCount++;
    exitBreakdown['END'] = (exitBreakdown['END'] ?? 0) + 1;
  }

  final retPct = _dep > 0 ? netEq / _dep * 100 : 0.0;
  final ddPct  = _dep > 0 ? maxDd  / _dep * 100 : 0.0;
  final calmar = ddPct > 0 ? retPct / ddPct
               : retPct > 0 ? 99.0 : 0.0;

  final grade = calmar >= 5 && retPct >= 50 && ddPct < 20 ? 'A ★★★'
              : calmar >= 3 && retPct >= 30 && ddPct < 30 ? 'B ★★'
              : calmar >= 1 && retPct >= 10 && ddPct < 40 ? 'C ★'
              : netEq > 0                                  ? 'D'
              : 'F';

  return Res(
    asset: sym, trades: tradeCount, wins: wins,
    netPnl: netEq, returnPct: retPct, maxDdPct: ddPct, calmar: calmar,
    totFees: totFee, totSlip: totSlp, totFund: totFund,
    grade: grade, exitBreakdown: exitBreakdown,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  final buf = StringBuffer();
  void log(String s) { print(s); buf.writeln(s); }

  const assetSymbols = [
    'SOLUSDT', 'XRPUSDT', 'TRBUSDT', 'BTCUSDT', 'ETHUSDT',
    'DOGEUSDT', 'BNBUSDT', 'ADAUSDT', 'APTUSDT', 'BCHUSDT',
    'CFXUSDT', 'ENAUSDT', 'HBARUSDT', 'ICPUSDT', 'LTCUSDT',
    'SUIUSDT', 'TRXUSDT', 'XMRUSDT', 'QNTUSDT',
  ];

  log('═' * 112);
  log('  REVERSAL STRATEGY V3 — Multi-Signal Confluence Engine');
  log('  Signals: SFI flip · RSI div (extreme only) · Vol spike · Pin/engulf · SR proximity');
  log('  Entry gate: score ≥ $_minScore/5  AND  (SFI flip OR SR proximity)  AND  R:R ≥ ${_minRR}×  AND  45m not opposed');
  log('  Positions: 50% TP1 → BE±buf | 30% TP2 (3.5× ATR) → trail | 20% SFI-flip runner');
  log('  v3 changes: soft anchor (OR) · SR 0.5% · RSI 45/55 · R:R gate · BE buffer · TP2 3.5× · 50/30/20 split');
  log('═' * 112);

  final results = <Res>[];

  for (final sym in assetSymbols) {
    final path = '$_base/${sym}5m.csv';
    if (!File(path).existsSync()) { log('  SKIP $sym — file not found'); continue; }
    stdout.write('  $sym ... ');
    final c5 = _clean(_loadCsv(path), 5);
    if (c5.length < 200) { log('  SKIP $sym — too few bars'); continue; }

    final r = _backtest(sym, c5);
    results.add(r);

    final mark = r.grade.startsWith('A') ? ' ◀ A-GRADE' :
                 r.grade.startsWith('B') ? ' ◀ B-GRADE' :
                 r.grade.startsWith('C') ? ' ◀ C-GRADE' : '';
    log('done  |  ${r.trades.toString().padLeft(4)} trades  '
        'WR ${r.wr.toStringAsFixed(1).padLeft(5)}%  '
        'Net \$${r.netPnl.toStringAsFixed(2).padLeft(8)}  '
        'DD ${r.maxDdPct.toStringAsFixed(1).padLeft(5)}%  '
        'Calmar ${r.calmar.toStringAsFixed(2).padLeft(6)}  '
        '${r.grade}$mark');
  }

  // ── Leaderboard ──────────────────────────────────────────────────────
  final profitable = results.where((r) => r.netPnl > 0).toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));

  log('\n');
  final sep = '═' * 100;
  log('╔$sep╗');
  log('║${_centre('LEADERBOARD — profitable assets ranked by Calmar', 100)}║');
  log('╠══════════╦═══════╦════════╦════════════╦═══════╦════════╦══════════════╣');
  log('║ Asset    ║  Trd  ║   WR%  ║    Net \$   ║   DD% ║ Calmar ║ Grade        ║');
  log('╠══════════╬═══════╬════════╬════════════╬═══════╬════════╬══════════════╣');
  for (final r in profitable) {
    log('║ ${r.asset.padRight(8)} ║${r.trades.toString().padLeft(5)}  ║ '
        '${('${r.wr.toStringAsFixed(1)}%').padLeft(6)} ║ '
        '${((r.netPnl >= 0 ? '+' : '') + r.netPnl.toStringAsFixed(2)).padLeft(10)} ║ '
        '${('${r.maxDdPct.toStringAsFixed(1)}%').padLeft(5)} ║'
        '${r.calmar.toStringAsFixed(2).padLeft(6)}  ║ ${r.grade.padRight(12)} ║');
  }
  log('╚══════════╩═══════╩════════╩════════════╩═══════╩════════╩══════════════╝');

  // ── Aggregate stats ──────────────────────────────────────────────────
  log('\n── AGGREGATE (profitable assets only) ──────────────────────────────────────');
  if (profitable.isNotEmpty) {
    final avgCalmar = profitable.fold(0.0, (s, r) => s + r.calmar) / profitable.length;
    final avgWr     = profitable.fold(0.0, (s, r) => s + r.wr)     / profitable.length;
    final totalNet  = profitable.fold(0.0, (s, r) => s + r.netPnl);
    log('  Profitable assets : ${profitable.length} / ${results.length}');
    log('  Avg Calmar        : ${avgCalmar.toStringAsFixed(2)}');
    log('  Avg Win Rate      : ${avgWr.toStringAsFixed(1)}%');
    log('  Total Net PnL     : \$${totalNet.toStringAsFixed(2)}');
    log('  A-grades          : ${profitable.where((r) => r.grade.startsWith("A")).length}'
        '   B-grades: ${profitable.where((r) => r.grade.startsWith("B")).length}'
        '   C-grades: ${profitable.where((r) => r.grade.startsWith("C")).length}');
  }

  // ── Exit breakdown ───────────────────────────────────────────────────
  log('\n── EXIT BREAKDOWN (profitable assets) ─────────────────────────────────────');
  final combined    = <String, int>{};
  for (final r in profitable) {
    r.exitBreakdown.forEach((k, v) => combined[k] = (combined[k] ?? 0) + v);
  }
  final totalExits = combined.values.fold(0, (s, v) => s + v);
  for (final e in (combined.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)))) {
    final pct = totalExits > 0 ? e.value / totalExits * 100 : 0.0;
    log('  ${e.key.padRight(12)} : ${e.value.toString().padLeft(5)}  (${pct.toStringAsFixed(1)}%)');
  }

  // ── Best single asset ────────────────────────────────────────────────
  if (profitable.isNotEmpty) {
    final best = profitable.first;
    log('\n── BEST SINGLE ASSET ───────────────────────────────────────────────────────');
    log('  Asset    : ${best.asset}');
    log('  Trades   : ${best.trades}   Win Rate: ${best.wr.toStringAsFixed(1)}%');
    log('  Net PnL  : \$${best.netPnl.toStringAsFixed(2)}');
    log('  Return   : ${best.returnPct.toStringAsFixed(1)}%  (on 500 USDT notional)');
    log('  Max DD   : ${best.maxDdPct.toStringAsFixed(1)}%');
    log('  Calmar   : ${best.calmar.toStringAsFixed(2)}');
    log('  Grade    : ${best.grade}');
    log('  Costs    : fees \$${best.totFees.toStringAsFixed(2)}'
        '  slip \$${best.totSlip.toStringAsFixed(2)}'
        '  fund \$${best.totFund.toStringAsFixed(2)}');
    log('  Exits    : ${best.exitBreakdown}');
  }

  // ── Save report ──────────────────────────────────────────────────────
  final ts   = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
  final path = '/Users/ayush/Desktop/reversal_v3_$ts.txt';
  File(path).writeAsStringSync(buf.toString());
  print('\nReport saved → $path');
}

String _centre(String s, int w) {
  final pad = ((w - s.length) / 2).floor();
  return ' ' * pad + s + ' ' * (w - s.length - pad);
}