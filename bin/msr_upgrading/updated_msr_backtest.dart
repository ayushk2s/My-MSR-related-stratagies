// =============================================================================
// BACKTEST STRATEGY — Multi-Timeframe SR + SFI
// =============================================================================
//
// DATA:
//   Input  : 15-minute OHLCV CSV
//   45m HTF: aggregated (3 × 15m candles)
//   5m exec : simulated (each 15m split into 3 synthetic 5m bars)
//
// STRATEGY (3-timeframe confluence):
//   ─ 45m SFI  → overall trend bias (+1 bull / -1 bear)
//   ─ 15m SFI  → intermediate confirmation
//   ─ 5m  SFI  → entry trigger (flip to +1 = long, flip to -1 = short)
//   ─ SR zones → price must be near support (LONG) or resistance (SHORT)
//
// TRADE MANAGEMENT:
//   ─ Full position at entry (100% notional × leverage)
//   ─ TP1: close 80% at nearest opposing SR zone (or ATR fallback)
//   ─ TP2: trail 20% — exit only when 5m SFI reverses
//   ─ SL : just beyond the zone that triggered the entry
//
// BIAS-FREE RULES (all applied):
//   1. SR zones: only zones confirmed at least srLN bars before current bar
//   2. SFI signal from previous closed bar drives current bar entries
//   3. Entry fills at NEXT 5m bar's open (deferred)
//   4. TP/SL same-bar → SL wins (conservative)
//   5. Funding every 8h on open position
//   6. Blended commission 0.025% + slippage 0.04% per side
//   7. Zero-volume gap candles removed before backtesting
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class BtConfig {
  final String symbol;
  final String csvPath;        // path to 15m CSV
  final double notional;       // USDT per trade
  final double leverage;
  final int    sfiPeriod;      // ATR period for SFI (default 10)
  final double sfiMult;        // ATR multiplier (default 1.7)
  final int    srLength;       // SR detection length (default 15)
  final double srMargin;       // SR margin factor (default 2.0)
  final double proximityPct;   // how close to zone to qualify (% of price)
  final double slBufferPct;    // SL buffer beyond zone edge
  final double atrFallbackTp;  // ATR multiple for TP1 fallback if no SR zone
  final int    cooldownBars;   // 5m bars to wait after SL before re-entry
  final double commission;     // % blended per side
  final double slippage;       // % per side
  final double funding;        // % per 8h

  const BtConfig({
    required this.symbol,
    required this.csvPath,
    this.notional       = 100.0,
    this.leverage       = 5.0,
    this.sfiPeriod      = 10,
    this.sfiMult        = 1.7,
    this.srLength       = 15,
    this.srMargin       = 2.0,
    this.proximityPct   = 0.8,  // 0.8% from zone edge
    this.slBufferPct    = 0.2,  // 0.2% beyond zone
    this.atrFallbackTp  = 2.0,  // 2×ATR if no opposing zone found
    this.cooldownBars   = 6,    // 6 × 5m = 30 min cooldown
    this.commission     = 0.025,
    this.slippage       = 0.04,
    this.funding        = 0.01,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE LOG
// ─────────────────────────────────────────────────────────────────────────────

class TradeLog {
  final int    id;
  final int    dir;            // +1 LONG, -1 SHORT
  final double entry;
  final double qty;            // total quantity (notional*leverage/entry)
  final double tp1;            // first TP price (80% close)
  final double sl;             // stop-loss price
  final DateTime entryTime;

  bool   tp1Hit    = false;
  double tp1ExitP  = 0;
  double tp2ExitP  = 0;
  String reason    = '';       // 'TP1+FLIP' | 'TP1+SL' | 'SL' | 'END'
  DateTime? exitTime;

  double feePaid   = 0;
  double slipPaid  = 0;
  double fundPaid  = 0;
  double pnl       = 0;        // net PnL (after all costs)

  TradeLog({
    required this.id,
    required this.dir,
    required this.entry,
    required this.qty,
    required this.tp1,
    required this.sl,
    required this.entryTime,
  });

  double get qty80 => qty * 0.80;
  double get qty20 => qty * 0.20;

  bool get open => reason.isEmpty;

  @override
  String toString() {
    final side = dir == 1 ? 'LONG ' : 'SHORT';
    final tp1s = tp1Hit ? 'TP1@${tp1ExitP.toStringAsFixed(4)} ' : '';
    final ex   = '${tp1s}Exit@${tp2ExitP.toStringAsFixed(4)}[$reason]';
    return '#$id $side  Entry:${entry.toStringAsFixed(4)}  TP1:${tp1.toStringAsFixed(4)}  SL:${sl.toStringAsFixed(4)}'
        '  ${entryTime.toIso8601String().substring(0,16)}→${exitTime?.toIso8601String().substring(0,16)??'...'}  $ex  PnL:${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(4)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI SIGNAL
// ─────────────────────────────────────────────────────────────────────────────

class _Sig {
  final double upLine;
  final double dnLine;
  final int    trend;     // +1 or -1
  final bool   buy;       // flip from -1 → +1
  final bool   sell;      // flip from +1 → -1
  const _Sig(this.upLine, this.dnLine, this.trend, this.buy, this.sell);
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
    out.add(Candle(t,
        double.parse(p[1]), double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4]),
        double.parse(p[5]), out.length));
  }
  return out;
}

/// Remove zero-volume candles and large time gaps.
List<Candle> _clean(List<Candle> raw, int intervalMin) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty && c.time.difference(out.last.time).inMinutes > intervalMin * 3) continue;
    out.add(Candle(c.time, c.open, c.high, c.low, c.close, c.volume, out.length));
  }
  return out;
}

/// Aggregate N×15m candles → HTF candles.
List<Candle> _agg(List<Candle> c15, int mult) {
  final out = <Candle>[];
  for (int i = 0; i + mult - 1 < c15.length; i += mult) {
    double hi = c15[i].high, lo = c15[i].low, vol = 0;
    for (int j = 0; j < mult; j++) {
      hi  = max(hi, c15[i+j].high);
      lo  = min(lo, c15[i+j].low);
      vol += c15[i+j].volume;
    }
    out.add(Candle(c15[i].time, c15[i].open, hi, lo, c15[i+mult-1].close, vol, out.length));
  }
  return out;
}

/// Simulate 3 synthetic 5m bars from each 15m OHLCV bar.
/// Closes are linearly interpolated (O → C in 3 steps).
/// H/L are split based on direction: bullish=low early+high late, bearish=high early+low late.
/// All synthetic H/L clamped within 15m bar's H/L range.
List<Candle> _sim5m(List<Candle> c15) {
  final out = <Candle>[];
  for (final c in c15) {
    final dp       = (c.close - c.open) / 3.0;
    final bullish  = c.close >= c.open;
    final range    = c.high - c.low;
    final midRange = range / 6.0; // half-range per sub-bar wick

    for (int i = 0; i < 3; i++) {
      final o5  = i == 0 ? c.open : c.open + dp * i;
      final c5  = c.open + dp * (i + 1);
      final t5  = c.time.add(Duration(minutes: 5 * i));

      double h5, l5;
      if (bullish) {
        // Bullish: high concentrates in later sub-bars, low in earlier
        h5 = i == 2 ? c.high : max(o5, c5) + midRange * (i == 0 ? 0.2 : 0.5);
        l5 = i == 0 ? c.low  : min(o5, c5) - midRange * 0.2;
      } else {
        // Bearish: high concentrates in earlier sub-bars, low in later
        h5 = i == 0 ? c.high : max(o5, c5) + midRange * 0.2;
        l5 = i == 2 ? c.low  : min(o5, c5) - midRange * (i == 0 ? 0.2 : 0.5);
      }
      h5 = h5.clamp(c.low, c.high);
      l5 = l5.clamp(c.low, c.high);
      h5 = max(h5, max(o5, c5));
      l5 = min(l5, min(o5, c5));

      out.add(Candle(t5, o5, h5, l5, c5, c.volume / 3.0, out.length));
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI — rolling SuperTrend-like indicator (no look-ahead)
// ─────────────────────────────────────────────────────────────────────────────

List<_Sig> _sfi(List<Candle> cs, int p, double m) {
  final tr  = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low,
           max((cs[i].high - prev).abs(),
               (cs[i].low  - prev).abs())));
  }

  // Wilder ATR
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i+1)); }
    else        { atr.add((atr[i-1] * (p-1) + tr[i]) / p); }
  }

  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int    prevT = 1;
  final  out = <_Sig>[];

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

    out.add(_Sig(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

// Rolling ATR (Wilder) — separate utility for TP fallback
List<double> _atrList(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low,
           max((cs[i].high - prev).abs(),
               (cs[i].low  - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i+1)); }
    else        { atr.add((atr[i-1] * (p-1) + tr[i]) / p); }
  }
  return atr;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR ZONE UTILITIES
// ─────────────────────────────────────────────────────────────────────────────

/// Returns active support zones known at bar [barIdx] (zone confirmed after srLN bars).
List<SRZone> _knownSupports(List<SRZone> allZones, int barIdx, int srLN) =>
    allZones.where((z) =>
        !z.isResistance &&
        z.boxLeft + srLN <= barIdx &&
        !z.b).toList();

List<SRZone> _knownResistances(List<SRZone> allZones, int barIdx, int srLN) =>
    allZones.where((z) =>
        z.isResistance &&
        z.boxLeft + srLN <= barIdx &&
        !z.b).toList();

/// Nearest support zone below or touching [price].
SRZone? _nearestSupport(List<SRZone> zones, double price) {
  SRZone? best;
  double bestDist = double.infinity;
  for (final z in zones) {
    if (z.boxTop > price * 1.005) continue; // zone far above price
    final dist = price - z.boxTop;
    if (dist < bestDist) { bestDist = dist; best = z; }
  }
  return best;
}

/// Nearest resistance zone above or touching [price].
SRZone? _nearestResistance(List<SRZone> zones, double price) {
  SRZone? best;
  double bestDist = double.infinity;
  for (final z in zones) {
    if (z.boxBottom < price * 0.995) continue; // zone far below price
    final dist = z.boxBottom - price;
    if (dist < bestDist) { bestDist = dist; best = z; }
  }
  return best;
}

bool _nearZone(SRZone z, double price, double proximityPct) {
  final buf = price * proximityPct / 100;
  return price >= z.boxBottom - buf && price <= z.boxTop + buf;
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class BacktestResult {
  final List<TradeLog> trades;
  final double netPnl;
  final double grossPnl;
  final double totalFees;
  final double totalSlippage;
  final double totalFunding;
  final double maxDd;
  final double returnPct;
  final double calmar;
  final int    wins;

  BacktestResult({
    required this.trades,
    required this.netPnl,
    required this.grossPnl,
    required this.totalFees,
    required this.totalSlippage,
    required this.totalFunding,
    required this.maxDd,
    required this.returnPct,
    required this.calmar,
    required this.wins,
  });

  int get total   => trades.length;
  double get wr   => total == 0 ? 0 : wins / total * 100;
  double get avgR => total == 0 ? 0 : netPnl / total;
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

BacktestResult backtest(BtConfig cfg) {
  // ── 1. Load & clean 15m candles ──────────────────────────────────────────
  final raw15 = _loadCsv(cfg.csvPath);
  final c15   = _clean(raw15, 15);
  if (c15.length < 100) throw Exception('Not enough 15m candles: ${c15.length}');

  // ── 2. Aggregate to 45m ───────────────────────────────────────────────────
  final c45 = _agg(c15, 3);
  if (c45.length < 60) throw Exception('Not enough 45m candles: ${c45.length}');

  // ── 3. Simulate 5m from 15m ───────────────────────────────────────────────
  final c5 = _sim5m(c15);

  // ── 4. Compute SFI on all 3 timeframes ───────────────────────────────────
  final sfi45 = _sfi(c45, cfg.sfiPeriod, cfg.sfiMult);
  final sfi15 = _sfi(c15, cfg.sfiPeriod, cfg.sfiMult);
  final sfi5  = _sfi(c5,  cfg.sfiPeriod, cfg.sfiMult);
  final atr5  = _atrList(c5, 14);  // for TP fallback

  // ── 5. Compute SR zones on 45m (bias-free: use boxLeft + srLN delay) ─────
  final srIndicator = SupportResistanceIndicator(
    detectionLength: cfg.srLength,
    srMargin:        cfg.srMargin,
    avoidFBO:        true,
    checkHist:       true,
  );
  final srResult = srIndicator.calculate(c45);
  final allZones = [...srResult.support, ...srResult.resistance];

  // ── 6. Build a time→index map for 45m and 15m (fast lookup) ──────────────
  final c45TimeIdx = <DateTime, int>{};
  for (int i = 0; i < c45.length; i++) c45TimeIdx[c45[i].time] = i;

  final c15TimeIdx = <DateTime, int>{};
  for (int i = 0; i < c15.length; i++) c15TimeIdx[c15[i].time] = i;

  // Map each 5m bar → its parent 45m bar index and parent 15m bar index
  // 5m bar belongs to 15m bar whose time == first 5m of that 15m group
  // = 5m index ~/ 3 → 15m index; 15m index ~/ 3 → 45m index
  int idx15For5m(int i5) => i5 ~/ 3;
  int idx45For5m(int i5) => i5 ~/ 9;  // 3 sub-bars × 3 = 9 5m bars per 45m

  // ── 7. Backtest loop ──────────────────────────────────────────────────────
  final trades   = <TradeLog>[];
  int   tradeId  = 0;
  double netEq   = 0, grossEq = 0;
  double totFee  = 0, totSlip = 0, totFund = 0;
  double peak    = 0, maxDd  = 0;
  int    cooldown = 0;
  TradeLog? active;
  bool   pendingLong  = false;
  bool   pendingShort = false;
  DateTime lastFund   = DateTime(2000);

  final dep = cfg.notional * cfg.leverage;

  for (int i = 1; i < c5.length; i++) {
    final c = c5[i];

    // ── Indices into parent timeframes ──
    final i15 = idx15For5m(i);
    final i45 = idx45For5m(i);

    // ── Bias-free: use PREVIOUS bar's signal ──
    // sfi5[i-1] = signal computed after 5m bar i-1 closed
    final sig5prev  = sfi5[i - 1];
    final sig5cur   = sfi5[i];    // current bar's signal (for ride exit)

    // 15m and 45m: use previous completed bar's trend
    final sig15 = i15 > 0 ? sfi15[i15 - 1] : sfi15[0];
    final sig45 = i45 > 0 ? sfi45[i45 - 1] : sfi45[0];

    // SR zones known at current 45m bar
    final knownSup = _knownSupports(allZones,   i45, cfg.srLength);
    final knownRes = _knownResistances(allZones, i45, cfg.srLength);

    // ── Fill pending entry at this bar's open ──
    if (active == null && cooldown == 0) {
      if (pendingLong || pendingShort) {
        final dir = pendingLong ? 1 : -1;
        pendingLong = pendingShort = false;

        final fill = c.open;
        final atr  = atr5[i];

        // Find nearest support (for LONG SL/TP) or resistance (for SHORT)
        SRZone? entryZone, tpZone;
        double slPrice, tp1Price;

        if (dir == 1) {
          entryZone = _nearestSupport(knownSup, fill);
          tpZone    = _nearestResistance(knownRes, fill);
          slPrice   = entryZone != null
              ? entryZone.boxBottom * (1 - cfg.slBufferPct / 100)
              : fill - cfg.atrFallbackTp * atr;
          tp1Price  = tpZone != null
              ? tpZone.boxBottom                        // bottom of resistance zone
              : fill + cfg.atrFallbackTp * atr;
        } else {
          entryZone = _nearestResistance(knownRes, fill);
          tpZone    = _nearestSupport(knownSup, fill);
          slPrice   = entryZone != null
              ? entryZone.boxTop * (1 + cfg.slBufferPct / 100)
              : fill + cfg.atrFallbackTp * atr;
          tp1Price  = tpZone != null
              ? tpZone.boxTop                           // top of support zone
              : fill - cfg.atrFallbackTp * atr;
        }

        // Validate: TP and SL must be on correct sides + TP > SL distance
        final validLong  = dir == 1  && tp1Price > fill && fill > slPrice;
        final validShort = dir == -1 && tp1Price < fill && fill < slPrice;

        if (validLong || validShort) {
          final qty = (cfg.notional * cfg.leverage) / fill;
          final t   = TradeLog(
            id: tradeId++, dir: dir,
            entry: fill, qty: qty,
            tp1: tp1Price, sl: slPrice,
            entryTime: c.time,
          );
          // Entry fee + slippage (both sides of 80% + 20% are charged at entry)
          final entryFee  = cfg.notional * cfg.leverage * cfg.commission / 100;
          final entrySlip = cfg.notional * cfg.leverage * cfg.slippage   / 100;
          t.feePaid  += entryFee;
          t.slipPaid += entrySlip;
          totFee     += entryFee;
          totSlip    += entrySlip;
          active = t;
          trades.add(t);
        }
      }
    } else {
      pendingLong = pendingShort = false;
    }

    // ── Funding ──
    if (active != null && active!.open &&
        c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final f  = cfg.notional * cfg.leverage * cfg.funding / 100;
      active!.fundPaid += f;
      totFund          += f;
    }

    // ── TP1 / SL / Flip check ──
    if (active != null && active!.open) {
      final t = active!;

      final tpH = t.dir == 1 ? c.high >= t.tp1   : c.low  <= t.tp1;
      final slH = t.dir == 1 ? c.low  <= t.sl     : c.high >= t.sl;

      // Fix 4: same bar → SL wins
      if (slH || (tpH && slH)) {
        // Full SL — close entire position
        final exitP    = t.sl;
        final pnlGross = t.dir == 1
            ? (exitP - t.entry) / t.entry * cfg.notional * cfg.leverage
            : (t.entry - exitP) / t.entry * cfg.notional * cfg.leverage;
        final exitFee  = cfg.notional * cfg.leverage * cfg.commission / 100;
        final exitSlip = cfg.notional * cfg.leverage * cfg.slippage   / 100;
        t.feePaid  += exitFee;
        t.slipPaid += exitSlip;
        totFee     += exitFee;
        totSlip    += exitSlip;
        t.tp2ExitP = exitP;
        t.reason   = 'SL';
        t.exitTime = c.time;
        t.pnl      = pnlGross - t.feePaid - t.slipPaid - t.fundPaid;
        grossEq    += pnlGross;
        netEq      += t.pnl;
        if (t.pnl > 0) {}  // win counted later
        cooldown = cfg.cooldownBars;
        active   = null;

      } else if (!t.tp1Hit && tpH) {
        // TP1 hit — close 80%
        final exitP    = t.tp1;
        t.tp1Hit       = true;
        t.tp1ExitP     = exitP;
        final pnl80    = t.dir == 1
            ? (exitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.80
            : (t.entry - exitP) / t.entry * cfg.notional * cfg.leverage * 0.80;
        final fee80    = cfg.notional * cfg.leverage * 0.80 * cfg.commission / 100;
        final slip80   = cfg.notional * cfg.leverage * 0.80 * cfg.slippage   / 100;
        t.feePaid  += fee80;
        t.slipPaid += slip80;
        totFee     += fee80;
        totSlip    += slip80;
        grossEq    += pnl80;
        netEq      += pnl80 - fee80 - slip80;

      } else if (t.tp1Hit) {
        // 20% position: wait for SFI 5m reversal
        // sig5cur reflects end-of-current-bar — exit at close if SFI reversed
        // Use PREVIOUS bar's SFI to decide reversal trigger (bias-free)
        final reversed = t.dir == 1 ? sig5prev.sell : sig5prev.buy;
        if (reversed) {
          final exitP  = c.close;  // exit at close of reversal bar
          t.tp2ExitP   = exitP;
          t.reason     = 'TP1+FLIP';
          t.exitTime   = c.time;
          final pnl20  = t.dir == 1
              ? (exitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.20
              : (t.entry - exitP) / t.entry * cfg.notional * cfg.leverage * 0.20;
          final fee20  = cfg.notional * cfg.leverage * 0.20 * cfg.commission / 100;
          final slip20 = cfg.notional * cfg.leverage * 0.20 * cfg.slippage   / 100;
          t.feePaid  += fee20;
          t.slipPaid += slip20;
          totFee     += fee20;
          totSlip    += slip20;
          grossEq    += pnl20;
          t.pnl       = (t.dir == 1
              ? (t.tp1ExitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.80
              : (t.entry - t.tp1ExitP) / t.entry * cfg.notional * cfg.leverage * 0.80)
              + pnl20 - t.feePaid - t.slipPaid - t.fundPaid;
          netEq      += pnl20 - fee20 - slip20 - t.fundPaid;
          active      = null;
        }

        // SL check on 20% (only if TP1 already hit)
        if (active != null && active!.open && slH) {
          final exitP  = t.sl;
          t.tp2ExitP   = exitP;
          t.reason     = 'TP1+SL';
          t.exitTime   = c.time;
          final pnl20  = t.dir == 1
              ? (exitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.20
              : (t.entry - exitP) / t.entry * cfg.notional * cfg.leverage * 0.20;
          final fee20  = cfg.notional * cfg.leverage * 0.20 * cfg.commission / 100;
          final slip20 = cfg.notional * cfg.leverage * 0.20 * cfg.slippage   / 100;
          t.feePaid  += fee20;
          t.slipPaid += slip20;
          totFee     += fee20;
          totSlip    += slip20;
          grossEq    += pnl20;
          t.pnl       = (t.dir == 1
              ? (t.tp1ExitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.80
              : (t.entry - t.tp1ExitP) / t.entry * cfg.notional * cfg.leverage * 0.80)
              + pnl20 - t.feePaid - t.slipPaid - t.fundPaid;
          netEq      += pnl20 - fee20 - slip20 - t.fundPaid;
          active      = null;
        }
      }
    }

    // ── Drawdown ──
    double openPnl = 0;
    if (active != null && active!.open) {
      final t = active!;
      openPnl = t.dir == 1
          ? (c.close - t.entry) / t.entry * cfg.notional * cfg.leverage * (t.tp1Hit ? 0.20 : 1.0)
          : (t.entry - c.close) / t.entry * cfg.notional * cfg.leverage * (t.tp1Hit ? 0.20 : 1.0);
      openPnl -= t.feePaid + t.slipPaid + t.fundPaid;
    }
    final cur = netEq + openPnl;
    if (cur > peak) peak = cur;
    if (peak - cur > maxDd) maxDd = peak - cur;

    // ── Cooldown tick ──
    if (cooldown > 0) cooldown--;

    // ── New entry signal detection ──
    // Signal: 5m SFI flip (detected at close of current bar → pending fill next open)
    if (active == null && cooldown == 0 && !pendingLong && !pendingShort) {
      final buy5m  = sig5cur.buy;   // 5m SFI just flipped to +1
      final sell5m = sig5cur.sell;  // 5m SFI just flipped to -1

      // 45m and 15m trend: not contradicting means they should not be on the opposite side
      final bias45  = sig45.trend;
      final bias15  = sig15.trend;

      if (buy5m && bias45 >= 0 && bias15 >= 0) {
        // Check price near support
        final knownSupNow = _knownSupports(allZones, i45, cfg.srLength);
        final nearSup     = _nearestSupport(knownSupNow, c.close);
        if (nearSup != null && _nearZone(nearSup, c.close, cfg.proximityPct)) {
          pendingLong = true;
        }
      } else if (sell5m && bias45 <= 0 && bias15 <= 0) {
        // Check price near resistance
        final knownResNow = _knownResistances(allZones, i45, cfg.srLength);
        final nearRes     = _nearestResistance(knownResNow, c.close);
        if (nearRes != null && _nearZone(nearRes, c.close, cfg.proximityPct)) {
          pendingShort = true;
        }
      }
    }
  }

  // ── Force-close open trade at end ──
  if (active != null && active!.open) {
    final t     = active!;
    final exitP = c5.last.close;
    t.exitTime  = c5.last.time;
    final remainPct = t.tp1Hit ? 0.20 : 1.0;
    final exitFee   = cfg.notional * cfg.leverage * remainPct * cfg.commission / 100;
    final exitSlip  = cfg.notional * cfg.leverage * remainPct * cfg.slippage   / 100;
    totFee  += exitFee;
    totSlip += exitSlip;
    t.feePaid  += exitFee;
    t.slipPaid += exitSlip;
    final rem = t.dir == 1
        ? (exitP - t.entry) / t.entry * cfg.notional * cfg.leverage * remainPct
        : (t.entry - exitP) / t.entry * cfg.notional * cfg.leverage * remainPct;
    grossEq += rem;
    if (t.tp1Hit) {
      t.tp2ExitP = exitP;
      t.reason   = 'END(TP1+)';
      final prev80pnl = t.dir == 1
          ? (t.tp1ExitP - t.entry) / t.entry * cfg.notional * cfg.leverage * 0.80
          : (t.entry - t.tp1ExitP) / t.entry * cfg.notional * cfg.leverage * 0.80;
      t.pnl = prev80pnl + rem - t.feePaid - t.slipPaid - t.fundPaid;
    } else {
      t.tp2ExitP = exitP;
      t.reason   = 'END';
      t.pnl      = rem - t.feePaid - t.slipPaid - t.fundPaid;
    }
    netEq += t.pnl - (t.tp1Hit
        ? 0   // 80% already in netEq above
        : 0); // re-add correctly
    // Adjust netEq: the incremental pnl from 20% wasn't added to netEq yet for END case
    netEq += rem - exitFee - exitSlip - (t.tp1Hit ? t.fundPaid : 0);
    active = null;
  }

  final closed = trades.where((t) => t.reason.isNotEmpty).toList();
  final wins   = closed.where((t) => t.pnl > 0).length;
  final retPct = dep > 0 ? netEq / dep * 100 : 0.0;
  final ddPct  = dep > 0 ? maxDd / dep * 100  : 0.0;
  final calmar = ddPct.abs() > 0 ? retPct / ddPct.abs() : 0.0;

  return BacktestResult(
    trades:       closed,
    netPnl:       netEq,
    grossPnl:     grossEq,
    totalFees:    totFee,
    totalSlippage: totSlip,
    totalFunding:  totFund,
    maxDd:        maxDd,
    returnPct:    retPct,
    calmar:       calmar,
    wins:         wins,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _printSep(String title) {
  const w = 90;
  final pad = ((w - title.length - 2) / 2).floor();
  print('─' * pad + ' $title ' + '─' * (w - pad - title.length - 2));
}

void printResult(BtConfig cfg, BacktestResult r) {
  print('');
  _printSep('BACKTEST RESULT — ${cfg.symbol}');
  print('  Period    : ${r.trades.isNotEmpty ? r.trades.first.entryTime.toIso8601String().substring(0,10) : "-"}'
        ' → ${r.trades.isNotEmpty ? r.trades.last.exitTime?.toIso8601String().substring(0,10) ?? "-" : "-"}');
  print('  Notional  : \$${cfg.notional}  Leverage: ${cfg.leverage}×  → \$${cfg.notional * cfg.leverage} per trade');
  print('');
  _printSep('PERFORMANCE');
  print('  Total Trades  : ${r.total}');
  print('  Wins          : ${r.wins}  (${r.wr.toStringAsFixed(1)}%)');
  print('  Net PnL       : ${r.netPnl >= 0 ? "+" : ""}\$${r.netPnl.toStringAsFixed(4)}');
  print('  Gross PnL     : ${r.grossPnl >= 0 ? "+" : ""}\$${r.grossPnl.toStringAsFixed(4)}');
  print('  Return        : ${r.returnPct >= 0 ? "+" : ""}${r.returnPct.toStringAsFixed(2)}%');
  print('  Max Drawdown  : ${r.maxDd.toStringAsFixed(4)} (${r.maxDd / (cfg.notional * cfg.leverage) * 100 < 0 ? "" : ""}${(r.maxDd / (cfg.notional * cfg.leverage) * 100).toStringAsFixed(1)}%)');
  print('  Calmar Ratio  : ${r.calmar.toStringAsFixed(2)}');
  print('  Avg PnL/Trade : ${r.avgR >= 0 ? "+" : ""}\$${r.avgR.toStringAsFixed(4)}');
  print('');
  _printSep('COSTS BREAKDOWN');
  print('  Total Fees    : -\$${r.totalFees.toStringAsFixed(4)}   (commission ${cfg.commission}% blended × 2 sides)');
  print('  Total Slippage: -\$${r.totalSlippage.toStringAsFixed(4)}   (${cfg.slippage}% × 2 sides)');
  print('  Total Funding : -\$${r.totalFunding.toStringAsFixed(4)}   (${cfg.funding}%/8h)');
  print('  Total Costs   : -\$${(r.totalFees + r.totalSlippage + r.totalFunding).toStringAsFixed(4)}');
  print('');

  if (r.trades.isNotEmpty) {
    _printSep('TRADE LOG (last 30)');
    final show = r.trades.length > 30 ? r.trades.sublist(r.trades.length - 30) : r.trades;
    for (final t in show) print('  ${t.toString()}');
    print('');

    _printSep('BREAKDOWN BY EXIT TYPE');
    final byReason = <String, List<TradeLog>>{};
    for (final t in r.trades) byReason.putIfAbsent(t.reason, () => []).add(t);
    for (final e in byReason.entries) {
      final cnt  = e.value.length;
      final wpct = e.value.where((t) => t.pnl > 0).length / cnt * 100;
      final sum  = e.value.fold(0.0, (s, t) => s + t.pnl);
      print('  ${e.key.padRight(14)}: ${cnt.toString().padLeft(4)} trades  '
            'WR: ${wpct.toStringAsFixed(0).padLeft(3)}%  Net: ${sum >= 0 ? "+" : ""}\$${sum.toStringAsFixed(2)}');
    }
    print('');
  }

  final grade = r.calmar >= 5 && r.returnPct >= 50 ? 'A ★★★'
              : r.calmar >= 3 && r.returnPct >= 30 ? 'B ★★'
              : r.calmar >= 1 && r.returnPct >= 10 ? 'C ★'
              : r.netPnl > 0                        ? 'D'
              : 'F';
  print('  Overall Grade : $grade  (Calmar ${r.calmar.toStringAsFixed(2)}, Return ${r.returnPct.toStringAsFixed(1)}%)');
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN — configure and run
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── Try multiple assets ──
  final configs = [
    BtConfig(
      symbol:  'SOLUSDT',
      csvPath: '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv',
      notional: 100, leverage: 5,
    ),
    BtConfig(
      symbol:  'XRPUSDT',
      csvPath: '/Users/ayush/Desktop/candlestick data/15m/XRPUSDT15m.csv',
      notional: 100, leverage: 5,
    ),
    BtConfig(
      symbol:  'TRBUSDT',
      csvPath: '/Users/ayush/Desktop/candlestick data/15m/TRBUSDT15m.csv',
      notional: 100, leverage: 5,
    ),
    BtConfig(
      symbol:  'BTCUSDT',
      csvPath: '/Users/ayush/Desktop/candlestick data/15m/BTCUSDT15m.csv',
      notional: 100, leverage: 5,
    ),
    BtConfig(
      symbol:  'ETHUSDT',
      csvPath: '/Users/ayush/Desktop/candlestick data/15m/ETHUSDT15m.csv',
      notional: 100, leverage: 5,
    ),
  ];

  for (final cfg in configs) {
    if (!File(cfg.csvPath).existsSync()) {
      print('  [SKIP] ${cfg.symbol} — file not found: ${cfg.csvPath}');
      continue;
    }
    try {
      final result = backtest(cfg);
      printResult(cfg, result);
    } catch (e) {
      print('  [ERROR] ${cfg.symbol}: $e');
    }
  }
}
