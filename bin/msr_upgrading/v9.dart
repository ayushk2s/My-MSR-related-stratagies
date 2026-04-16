// =============================================================================
// REVERSAL STRATEGY V1 — High-Conviction Multi-Signal Confluence Engine
// =============================================================================
//
// Core Philosophy: Only trade when ≥3 independent reversal signals agree.
//   A trend-follower fires on every flip. A reversal engine waits for the
//   EXHAUSTION of a move — then enters counter-trend with tight risk.
//
// SIGNALS (each worth 1 point toward the 0-5 confluence score):
//   [+1] SFI flip   — SFI reverses direction on ENTRY timeframe
//   [+1] RSI div    — price makes new extreme but RSI doesn't (divergence)
//   [+1] Vol spike  — bar volume > 2× 20-bar SMA (capitulation / climax)
//   [+1] Pin bar    — rejection wick ≥ 2× body AND close in top/bottom 30%
//   [+1] SR tight   — price within 0.3% of a known support/resistance zone
//
// ENTRY GATE: score ≥ 3 AND 45m SFI trend is not strongly opposed
//
// POSITION MANAGEMENT (3-tier split):
//   60% at TP1 — next SR zone (or 1.5× ATR if no zone)  → SL moves to breakeven
//   25% at TP2 — 2nd SR zone (or 2.5× ATR)              → SL trails 1× ATR
//   15% trail  — rides until SFI flip on entry TF        → hard SL 3× ATR from entry
//
// HARD SL: 1.5× ATR from fill price (SL wins when TP+SL hit same bar)
// COOLDOWN: 5 bars after SL hit on full position
//
// COSTS (same as your v8 engine, fully bias-free):
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
const _minScore   = 3;       // minimum confluence score to enter
const _minAtrPct  = 0.25;    // min ATR% of price (skip choppy/thin markets)
const _cooldownBars = 5;     // bars to wait after a full stop-out

// Stop / target multipliers (ATR-based fallback when no SR zone found)
const _slAtr      = 1.5;     // hard SL distance
const _tp1Atr     = 1.5;     // TP1 fallback
const _tp2Atr     = 3.5;     // TP2 fallback
const _trailAtr   = 4.0;     // trailing hard stop for the 15% runner

// Position split fractions
const _sp1 = 0.60;           // closed at TP1
const _sp2 = 0.25;           // closed at TP2
const _sp3 = 0.15;           // runner — exits on SFI flip or trail stop

// SR zone detection params
const _srLen5  = 8;
const _srLen45 = 10;
const _srProx  = 0.30;       // % within which price is "at" a zone (tight)
const _slBuf   = 0.15;       // % buffer beyond zone bottom/top for SL placement
const _volMult = 2.0;        // volume spike threshold vs 20-bar SMA
const _rsiDiv  = 14;         // RSI period
const _rsiDivLook = 5;       // bars to look back for RSI divergence swing

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset;
  final int    trades, wins;
  final double netPnl, returnPct, maxDdPct, calmar;
  final double totFees, totSlip, totFund;
  final String grade;
  final Map<String,int> exitBreakdown;   // TP1, TP2, FLIP, TRAIL, SL, END

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

// SFI (Super Trend variant) — returns trend (+1/-1) and flip flags per bar
class SfiBar {
  final double up, dn;
  final int    trend;         // +1 uptrend, -1 downtrend
  final bool   flipUp, flipDn;
  const SfiBar(this.up, this.dn, this.trend, this.flipUp, this.flipDn);
}

List<SfiBar> computeSfi(List<Candle> cs, int period, double mult) {
  // True Range → ATR (Wilder's EMA)
  final tr  = <double>[];
  final atr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
    if (i == 0) { atr.add(tr[0]); }
    else if (i < period) { atr.add((atr[i-1] * i + tr[i]) / (i + 1)); }
    else { atr.add((atr[i-1] * (period - 1) + tr[i]) / period); }
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
    else if (prevT ==  1 && cs[i].close < pUp) t = -1;
    out.add(SfiBar(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

// RSI (standard 14-period Wilder's)
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

// 20-bar volume SMA (trailing, excludes current bar)
List<double> computeVolSma(List<Candle> cs, int p) {
  final out = <double>[];
  double sum = 0;
  for (int i = 0; i < cs.length; i++) {
    // Use i bars BEFORE current → [0..i-1]
    if (i == 0) { out.add(0.0); continue; }
    final start = max(0, i - p);
    sum = 0;
    for (int j = start; j < i; j++) sum += cs[j].volume;
    out.add(sum / (i - start));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SIGNAL SCORING
// ─────────────────────────────────────────────────────────────────────────────

/// Checks for RSI bullish divergence: price made a lower low in last [look]
/// bars but RSI made a higher low. (And bearish = higher high + lower RSI high)
bool rsiDivLong(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  // Find swing low in price over [i-look .. i-1]
  int    priceSwingBar = i - 1;
  double priceSwingLow = cs[i-1].low;
  for (int j = i - look; j < i - 1; j++) {
    if (cs[j].low < priceSwingLow) { priceSwingLow = cs[j].low; priceSwingBar = j; }
  }
  // Current bar must be making a new low vs that swing
  if (cs[i].low > priceSwingLow) return false;
  // RSI at current bar must be HIGHER than RSI at the previous swing low
  return rsi[i] > rsi[priceSwingBar];
}

bool rsiDivShort(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  int    priceSwingBar = i - 1;
  double priceSwingHigh = cs[i-1].high;
  for (int j = i - look; j < i - 1; j++) {
    if (cs[j].high > priceSwingHigh) { priceSwingHigh = cs[j].high; priceSwingBar = j; }
  }
  if (cs[i].high < priceSwingHigh) return false;
  return rsi[i] < rsi[priceSwingBar];
}

/// Bullish pin bar: lower wick ≥ 2× body, close in upper 30% of range
bool pinBarLong(Candle c) {
  final body  = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  final lWick = min(c.open, c.close) - c.low;
  return lWick >= body * 2.0 && (c.close - c.low) / range >= 0.70;
}

/// Bearish pin bar: upper wick ≥ 2× body, close in lower 30% of range
bool pinBarShort(Candle c) {
  final body  = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  final uWick = c.high - max(c.open, c.close);
  return uWick >= body * 2.0 && (c.high - c.close) / range >= 0.70;
}

/// Additionally check for bullish/bearish engulfing (strong reversal pattern)
bool engulfLong(List<Candle> cs, int i) {
  if (i == 0) return false;
  final prev = cs[i-1]; final curr = cs[i];
  return prev.close < prev.open             // previous bar bearish
      && curr.close > curr.open             // current bar bullish
      && curr.open  < prev.close            // gaps into prior body
      && curr.close > prev.open;            // engulfs prior body
}

bool engulfShort(List<Candle> cs, int i) {
  if (i == 0) return false;
  final prev = cs[i-1]; final curr = cs[i];
  return prev.close > prev.open
      && curr.close < curr.open
      && curr.open  > prev.close
      && curr.close < prev.open;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR HELPERS (identical bias-free approach to your v8)
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

List<SRZone> _knownSup(List<SRZone> z, List<int?> bb, int bar, int len) {
  return [for (int i = 0; i < z.length; i++)
    if (!z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) z[i]];
}

List<SRZone> _knownRes(List<SRZone> z, List<int?> bb, int bar, int len) {
  return [for (int i = 0; i < z.length; i++)
    if ( z[i].isResistance && z[i].boxLeft + len <= bar
        && (bb[i] == null || bb[i]! > bar)) z[i]];
}

/// Nearest support zone BELOW price
SRZone? _nearestSup(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxTop >= price * 1.001) continue;   // zone must be below
    final d = price - z.boxTop;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

/// Nearest resistance zone ABOVE price
SRZone? _nearestRes(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxBottom <= price * 0.999) continue; // zone must be above
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

// Cost helper — returns net P&L for closing [fraction] of position
double _pnl(int dir, double entry, double exitP, double fraction) {
  return dir == 1
      ? (exitP - entry) / entry * _dep * fraction
      : (entry - exitP) / entry * _dep * fraction;
}

double _cost(double fraction) =>
    _dep * fraction * (_commission + _slippage) / 100.0 * 2.0;

// ─────────────────────────────────────────────────────────────────────────────
// ACTIVE TRADE STATE
// ─────────────────────────────────────────────────────────────────────────────

class _Trade {
  final int    dir;
  final double entry, qty;
  final double hardSl;     // never changes — emergency exit
  double sl;               // dynamic: starts = hardSl, moves to breakeven after TP1
  final double tp1, tp2;   // target levels for the first two tiers
  double trailStop;        // trailing stop for the runner (tier 3)

  bool tp1Hit = false;
  bool tp2Hit = false;
  bool open   = true;

  double fundPaid = 0.0;
  double realizedPnl = 0.0;  // cumulative net after partial closes
  String reason = '';         // set when fully closed

  _Trade({
    required this.dir, required this.entry, required this.qty,
    required this.hardSl, required this.sl,
    required this.tp1, required this.tp2, required this.trailStop,
  });

  /// Fraction of original position still open
  double get openFraction =>
      tp1Hit && tp2Hit ? _sp3
      : tp1Hit         ? _sp2 + _sp3
      :                  1.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE BACKTEST
// ─────────────────────────────────────────────────────────────────────────────

Res _backtest(String sym, List<Candle> c5) {
  // Aggregate to 45m (9 × 5m bars)
  final c45 = _agg(c5, 9);

  // ── Indicator arrays ────────────────────────────────────────────────────
  // SFI on both timeframes (10-period, 1.7× multiplier for 5m; 14-period, 2.0× for 45m)
  final sfi5  = computeSfi(c5,  10, 1.7);
  final sfi45 = computeSfi(c45, 14, 2.0);

  // RSI on 5m
  final rsi5  = computeRsi(c5, _rsiDiv);

  // Volume SMA on 5m (trailing — excludes current bar)
  final volSma5 = computeVolSma(c5, 20);

  // ATR14 on 5m (Wilder's — same as SFI internal)
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

  // ── SR zones (bias-free) ─────────────────────────────────────────────────
  List<SRZone> _zones(List<Candle> cs, int len) {
    final sr = SupportResistanceIndicator(
        detectionLength: len, srMargin: 2.0, avoidFBO: true, checkHist: false);
    final r  = sr.calculate(cs);
    return [...r.support, ...r.resistance];
  }

  final zones5  = _zones(c5,  _srLen5);
  final zones45 = _zones(c45, _srLen45);
  final bb5     = computeBreakBars(zones5,  c5,  _srLen5);
  final bb45    = computeBreakBars(zones45, c45, _srLen45);

  // ── State ────────────────────────────────────────────────────────────────
  double netEq = 0, peak = 0, maxDd = 0;
  double totFee = 0, totSlp = 0, totFund = 0;
  int tradeCount = 0, wins = 0;
  int cooldown = 0;
  final exitBreakdown = <String,int>{};
  _Trade?  active;
  int?     pendDir;          // queued entry direction (+1/-1)
  int?     pendSignalBar;    // bar index when signal fired (for SL calc)
  DateTime lastFund = DateTime(2000);

  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i45 = i ~/ 9;
    if (cooldown > 0) cooldown--;

    // ── ATR from previous CLOSED bar (bias-free) ─────────────────────────
    final atr  = atr5[i - 1];

    // ── Funding every 8h ──────────────────────────────────────────────────
    if (active != null && active!.open &&
        c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final fCharge = _dep * active!.openFraction * _funding / 100.0;
      active!.fundPaid += fCharge;
      totFund += fCharge;
    }

    // ── Fill pending entry at THIS bar's OPEN ─────────────────────────────
    // Signal was set at previous bar's close; we fill at this bar's open.
    if (active == null && pendDir != null && cooldown == 0) {
      final dir  = pendDir!;
      pendDir    = null;
      final fill = c.open;

      // Minimum ATR filter
      if (atr / fill * 100 > _minAtrPct)
      {
        // SR zones at this moment (i = current 5m bar, i45 for 45m)
        final sup5  = _knownSup(zones5,  bb5,  i,   _srLen5);
        final res5  = _knownRes(zones5,  bb5,  i,   _srLen5);
        final sup45 = _knownSup(zones45, bb45, i45, _srLen45);
        final res45 = _knownRes(zones45, bb45, i45, _srLen45);

        // ── Hard SL placement ────────────────────────────────────────────
        double slPrice;
        if (dir == 1) {
          final ns = _nearestSup([...sup5, ...sup45], fill);
          slPrice = ns != null
              ? ns.boxBottom * (1.0 - _slBuf / 100.0)
              : fill - _slAtr * atr;
          if (slPrice >= fill) slPrice = fill - _slAtr * atr; // sanity check
        } else {
          final nr = _nearestRes([...res5, ...res45], fill);
          slPrice = nr != null
              ? nr.boxTop * (1.0 + _slBuf / 100.0)
              : fill + _slAtr * atr;
          if (slPrice <= fill) slPrice = fill + _slAtr * atr;
        }

        // ── TP1: next SR zone or ATR fallback ────────────────────────────
        double tp1Price;
        if (dir == 1) {
          final nr = _nearestRes([...res5, ...res45], fill);
          tp1Price = nr != null ? nr.boxBottom : fill + _tp1Atr * atr;
        } else {
          final ns = _nearestSup([...sup5, ...sup45], fill);
          tp1Price = ns != null ? ns.boxTop    : fill - _tp1Atr * atr;
        }

        // ── TP2: second SR zone or wider ATR fallback ────────────────────
        double tp2Price;
        if (dir == 1) {
          final res_sorted = ([...res5, ...res45]
              ..sort((a, b) => a.boxBottom.compareTo(b.boxBottom)));
          final above = res_sorted.where((z) => z.boxBottom > tp1Price).toList();
          tp2Price = above.isNotEmpty ? above.first.boxBottom : fill + _tp2Atr * atr;
        } else {
          final sup_sorted = ([...sup5, ...sup45]
              ..sort((a, b) => b.boxTop.compareTo(a.boxTop)));
          final below = sup_sorted.where((z) => z.boxTop < tp1Price).toList();
          tp2Price = below.isNotEmpty ? below.first.boxTop : fill - _tp2Atr * atr;
        }

        // Validate targets
        final validL = dir ==  1 && tp1Price > fill && fill > slPrice && tp2Price > tp1Price;
        final validS = dir == -1 && tp1Price < fill && fill < slPrice && tp2Price < tp1Price;
        if (!validL && !validS) continue;

        // Initial trailing stop = hard SL (will move after TP2 hit)
        final trailStop = dir == 1 ? fill - _trailAtr * atr : fill + _trailAtr * atr;

        // Entry commission + slippage
        final entryFee  = _dep * _commission / 100.0;
        final entrySlip = _dep * _slippage   / 100.0;
        totFee  += entryFee;
        totSlp  += entrySlip;

        active = _Trade(
          dir: dir, entry: fill, qty: _dep / fill,
          hardSl: slPrice, sl: slPrice,
          tp1: tp1Price, tp2: tp2Price, trailStop: trailStop,
        );
        tradeCount++;
      }
    }

    // ── Exit logic (SL wins same bar when both TP and SL triggered) ───────
    if (active != null && active!.open) {
      final t = active!;

      // Update trailing stop for runner (tightens as price moves in our favour)
      if (t.tp1Hit && t.tp2Hit) {
        final newTrail = t.dir == 1
            ? max(t.trailStop, c.close - _trailAtr * atr)
            : min(t.trailStop, c.close + _trailAtr * atr);
        t.trailStop = newTrail;
      }

      final slHit  = t.dir ==  1 ? c.low  <= t.sl : c.high >= t.sl;
      final tp1Hit = !t.tp1Hit && (t.dir ==  1 ? c.high >= t.tp1 : c.low  <= t.tp1);
      final tp2Hit = t.tp1Hit && !t.tp2Hit &&
                     (t.dir == 1 ? c.high >= t.tp2 : c.low <= t.tp2);
      final trailHit = t.tp1Hit && t.tp2Hit &&
                       (t.dir == 1 ? c.low <= t.trailStop : c.high >= t.trailStop);

      // SFI reversal on 5m (use [i-1] signal — fired at last closed bar)
      final sfiFlip = t.tp1Hit && t.tp2Hit &&
          (t.dir == 1 ? sfi5[i-1].flipDn : sfi5[i-1].flipUp);

      // Priority: SL wins over TP if both hit same bar
      if (slHit) {
        // ── Full stop-out ─────────────────────────────────────────────────
        final frac = t.openFraction;
        final gp   = _pnl(t.dir, t.entry, t.sl, frac);
        final cost = _cost(frac);
        final exFund = t.fundPaid;   // all remaining fund charged
        final net  = gp - cost - exFund;
        netEq += t.realizedPnl + net;
        totFee  += cost / 2.0;
        totSlp  += cost / 2.0;
        if (t.realizedPnl + net > 0) wins++;
        t.open   = true; // prevent double-close in force-close
        t.open   = false;
        t.reason = t.tp1Hit ? (t.tp2Hit ? 'TP2+SL' : 'TP1+SL') : 'SL';
        exitBreakdown[t.reason] = (exitBreakdown[t.reason] ?? 0) + 1;
        cooldown = _cooldownBars;
        active   = null;

      } else if (tp1Hit) {
        // ── Partial close: tier 1 (60%) ───────────────────────────────────
        final gp   = _pnl(t.dir, t.entry, t.tp1, _sp1);
        final cost = _cost(_sp1);
        final net  = gp - cost;
        netEq += net;
        t.realizedPnl += net;
        totFee += cost / 2.0;
        totSlp += cost / 2.0;
        t.tp1Hit = true;
        t.sl     = t.entry;   // breakeven: runner can no longer make a net loss
        exitBreakdown['TP1'] = (exitBreakdown['TP1'] ?? 0) + 1;

      } else if (tp2Hit) {
        // ── Partial close: tier 2 (25%) ───────────────────────────────────
        final gp   = _pnl(t.dir, t.entry, t.tp2, _sp2);
        final cost = _cost(_sp2);
        final net  = gp - cost;
        netEq += net;
        t.realizedPnl += net;
        totFee += cost / 2.0;
        totSlp += cost / 2.0;
        t.tp2Hit = true;
        // From here: trailing stop on the 15% runner
        t.trailStop = t.dir == 1
            ? t.tp2 - _trailAtr * atr
            : t.tp2 + _trailAtr * atr;
        exitBreakdown['TP2'] = (exitBreakdown['TP2'] ?? 0) + 1;

      } else if (trailHit || sfiFlip) {
        // ── Close runner (15%) ────────────────────────────────────────────
        final exitP = trailHit ? t.trailStop : c.open; // open = first price after flip
        final gp    = _pnl(t.dir, t.entry, exitP, _sp3);
        final cost  = _cost(_sp3);
        final exFund = t.fundPaid;
        final net   = gp - cost - exFund;
        netEq += t.realizedPnl + net;
        totFee  += cost / 2.0;
        totSlp  += cost / 2.0;
        if (t.realizedPnl + net > 0) wins++;
        t.open   = false;
        t.reason = trailHit ? 'TRAIL' : 'FLIP';
        exitBreakdown[t.reason] = (exitBreakdown[t.reason] ?? 0) + 1;
        active   = null;
      }
    }

    // ── Generate entry signal (uses bar i — but only QUEUED, filled next bar) ─
    if (active == null && pendDir == null && cooldown == 0) {
      final i45safe = i45.clamp(0, sfi45.length - 1);

      // ── Compute confluence score for LONG ────────────────────────────────
      int longScore = 0;

      // [1] SFI flip up on 5m (current bar close — available for next-bar fill)
      if (sfi5[i].flipUp) longScore++;

      // [2] RSI bullish divergence (uses closed data through bar i)
      if (rsiDivLong(c5, rsi5, i, _rsiDivLook) && rsi5[i] < 42) longScore++;

      // [3] Volume spike
      if (volSma5[i] > 0 && c5[i].volume >= volSma5[i] * _volMult) longScore++;

      // [4] Candlestick pattern (pin bar OR engulfing on signal bar)
      if (pinBarLong(c5[i]) || engulfLong(c5, i)) longScore++;

      // [5] SR proximity — within tight range of a known support zone
      if (i45 < zones45.length) {
        final sup5  = _knownSup(zones5,  bb5,  i,       _srLen5);
        final sup45 = _knownSup(zones45, bb45, i45safe, _srLen45);
        final ns    = _nearestSup([...sup5, ...sup45], c5[i].close);
        if (ns != null && _withinPct(ns, c5[i].close, _srProx)) longScore++;
      }

      // ── Compute confluence score for SHORT ──────────────────────────────
      int shortScore = 0;

      if (sfi5[i].flipDn) shortScore++;
      if (rsiDivShort(c5, rsi5, i, _rsiDivLook) && rsi5[i] > 58) shortScore++;
      if (volSma5[i] > 0 && c5[i].volume >= volSma5[i] * _volMult) shortScore++;
      if (pinBarShort(c5[i]) || engulfShort(c5, i)) shortScore++;

      if (i45 < zones45.length) {
        final res5  = _knownRes(zones5,  bb5,  i,       _srLen5);
        final res45 = _knownRes(zones45, bb45, i45safe, _srLen45);
        final nr    = _nearestRes([...res5, ...res45], c5[i].close);
        if (nr != null && _withinPct(nr, c5[i].close, _srProx)) shortScore++;
      }

      // ── 45m trend context gate ────────────────────────────────────────
      // Only block entries when 45m SFI is STRONGLY opposed (not neutral)
      final trend45 = i45safe > 0 ? sfi45[i45safe - 1].trend : 0;

      // Queue entry if score threshold met and trend not opposed
      if (longScore >= _minScore && trend45 >= 0) {
        pendDir = 1;
      } else if (shortScore >= _minScore && trend45 <= 0) {
        pendDir = -1;
      }
    }

    // ── Drawdown tracking ─────────────────────────────────────────────────
    double openPnl = 0;
    if (active != null && active!.open) {
      final t   = active!;
      final frac = t.openFraction;
      final raw  = _pnl(t.dir, t.entry, c.close, frac);
      openPnl = raw - _cost(frac) - t.fundPaid;
    }
    final cur = netEq + openPnl;
    if (cur > peak) peak = cur;
    if (peak - cur > maxDd) maxDd = peak - cur;
  }

  // ── Force-close any open position at end of data ──────────────────────────
  if (active != null && active!.open) {
    final t    = active!;
    final ep   = c5.last.close;
    final frac = t.openFraction;
    final gp   = _pnl(t.dir, t.entry, ep, frac);
    final cost = _cost(frac);
    final net  = gp - cost - t.fundPaid;
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

  log('═' * 110);
  log('  REVERSAL STRATEGY V1 — Multi-Signal Confluence Engine');
  log('  Signals: SFI flip · RSI divergence · Vol spike · Pin bar · SR proximity');
  log('  Entry gate: score ≥ $_minScore/5 AND 45m trend not opposing');
  log('  Positions: 60% TP1 → breakeven SL | 25% TP2 → trail | 15% SFI-flip runner');
  log('═' * 110);

  final results = <Res>[];

  for (final sym in assetSymbols) {
    final path = '$_base/${sym}5m.csv';
    if (!File(path).existsSync()) {
      log('  SKIP $sym — file not found');
      continue;
    }
    stdout.write('  $sym ... ');
    final c5 = _clean(_loadCsv(path), 5);
    if (c5.length < 200) { log('  SKIP $sym — too few bars'); continue; }

    final r = _backtest(sym, c5);
    results.add(r);

    final mark = r.grade.startsWith('A') ? ' ◀ A-GRADE' :
                 r.grade.startsWith('B') ? ' ◀ B-GRADE' : '';
    log('done  |  ${r.trades.toString().padLeft(4)} trades  '
        'WR ${r.wr.toStringAsFixed(1).padLeft(5)}%  '
        'Net \$${r.netPnl.toStringAsFixed(2).padLeft(8)}  '
        'DD ${r.maxDdPct.toStringAsFixed(1).padLeft(5)}%  '
        'Calmar ${r.calmar.toStringAsFixed(2).padLeft(6)}  '
        '${r.grade}$mark');
  }

  // ── Master leaderboard ────────────────────────────────────────────────────
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
    final a  = r.asset.padRight(8);
    final tr = r.trades.toString().padLeft(5);
    final wr = '${r.wr.toStringAsFixed(1)}%'.padLeft(6);
    final np = ((r.netPnl >= 0 ? '+' : '') + r.netPnl.toStringAsFixed(2)).padLeft(10);
    final dd = '${r.maxDdPct.toStringAsFixed(1)}%'.padLeft(5);
    final ca = r.calmar.toStringAsFixed(2).padLeft(6);
    log('║ $a ║$tr  ║ $wr ║ $np ║ $dd ║$ca  ║ ${r.grade.padRight(12)} ║');
  }
  log('╚══════════╩═══════╩════════╩════════════╩═══════╩════════╩══════════════╝');

  // ── Aggregate stats ───────────────────────────────────────────────────────
  log('\n── AGGREGATE (profitable assets only) ──────────────────────────────────────');
  if (profitable.isNotEmpty) {
    final avgCalmar = profitable.fold(0.0, (s, r) => s + r.calmar) / profitable.length;
    final avgWr     = profitable.fold(0.0, (s, r) => s + r.wr)     / profitable.length;
    final totalNet  = profitable.fold(0.0, (s, r) => s + r.netPnl);
    final aGrade    = profitable.where((r) => r.grade.startsWith('A')).length;
    final bGrade    = profitable.where((r) => r.grade.startsWith('B')).length;
    log('  Profitable assets : ${profitable.length} / ${results.length}');
    log('  Avg Calmar        : ${avgCalmar.toStringAsFixed(2)}');
    log('  Avg Win Rate      : ${avgWr.toStringAsFixed(1)}%');
    log('  Total Net PnL     : \$${totalNet.toStringAsFixed(2)}');
    log('  A-grades          : $aGrade   B-grades: $bGrade');
  }

  // ── Exit breakdown across all profitable results ──────────────────────────
  log('\n── EXIT BREAKDOWN (profitable assets) ─────────────────────────────────────');
  final combined = <String, int>{};
  for (final r in profitable) {
    r.exitBreakdown.forEach((k, v) => combined[k] = (combined[k] ?? 0) + v);
  }
  final totalExits = combined.values.fold(0, (s, v) => s + v);
  for (final e in (combined.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))) {
    final pct = totalExits > 0 ? e.value / totalExits * 100 : 0.0;
    log('  ${e.key.padRight(12)} : ${e.value.toString().padLeft(5)}  '
        '(${pct.toStringAsFixed(1)}%)');
  }

  // ── Best single asset ──────────────────────────────────────────────────────
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
  }

  // ── Save report ────────────────────────────────────────────────────────────
  final ts   = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
  final path = '/Users/ayush/Desktop/reversal_v1_$ts.txt';
  File(path).writeAsStringSync(buf.toString());
  print('\nReport saved → $path');
}

String _centre(String s, int w) {
  final pad = ((w - s.length) / 2).floor();
  return ' ' * pad + s + ' ' * (w - s.length - pad);
}