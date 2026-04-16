// =============================================================================
// BACKTEST STRATEGY V2 — SR on 45m + 15m + 5m, SFI flip on 5m
// =============================================================================
//
// WHAT'S NEW vs V1:
//   SR zones computed on ALL 3 timeframes (45m, 15m, 5m).
//   Nearest zone from any timeframe is used for:
//     - Proximity check (is price near support/resistance?)
//     - TP1 placement (next opposing zone)
//     - SL placement (just beyond entry zone)
//   5m SFI flip is the sole entry trigger.
//   45m + 15m SFI used only as trend bias filter (not reversed = allowed).
//   All execution (fill, TP, SL, trail exit) happens on 5m bars.
//
// DATA:
//   Input  : 15-minute OHLCV CSV
//   45m    : aggregated (3 × 15m)
//   15m    : direct
//   5m     : simulated (each 15m → 3 synthetic 5m bars)
//
// BIAS-FREE:
//   1. Zone delay: zone visible only after boxLeft + srLen bars (per timeframe)
//   2. SFI signal from previous closed 5m bar triggers pending entry
//   3. Entry fills at NEXT 5m bar's open
//   4. TP/SL same bar → SL wins
//   5. Funding 0.01%/8h, commission 0.025% blended, slippage 0.04%
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class BtConfigV2 {
  final String symbol;
  final String csvPath;
  final double notional;
  final double leverage;
  final int    sfiPeriod;
  final double sfiMult;
  final int    srLen45;      // SR detection length for 45m
  final int    srLen15;      // SR detection length for 15m
  final int    srLen5;       // SR detection length for 5m (simulated)
  final double srMargin;
  final double proximityPct; // % from zone edge to qualify as "near"
  final double slBufferPct;  // % beyond zone edge for SL
  final double atrFallbackTp;
  final int    cooldownBars;
  final double commission;
  final double slippage;
  final double funding;

  const BtConfigV2({
    required this.symbol,
    required this.csvPath,
    this.notional       = 100.0,
    this.leverage       = 5.0,
    this.sfiPeriod      = 10,
    this.sfiMult        = 1.7,
    this.srLen45        = 10,
    this.srLen15        = 12,
    this.srLen5         = 8,
    this.srMargin       = 2.0,
    this.proximityPct   = 0.8,
    this.slBufferPct    = 0.2,
    this.atrFallbackTp  = 2.0,
    this.cooldownBars   = 6,
    this.commission     = 0.025,
    this.slippage       = 0.04,
    this.funding        = 0.01,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE LOG
// ─────────────────────────────────────────────────────────────────────────────

class TradeV2 {
  final int      id, dir;
  final double   entry, qty, tp1, sl;
  final DateTime entryTime;
  bool   tp1Hit   = false;
  double tp1ExitP = 0, tp2ExitP = 0;
  String reason   = '';
  DateTime? exitTime;
  double feePaid = 0, slipPaid = 0, fundPaid = 0, pnl = 0;

  TradeV2({required this.id, required this.dir, required this.entry,
           required this.qty, required this.tp1, required this.sl,
           required this.entryTime});

  bool get open => reason.isEmpty;

  @override
  String toString() {
    final side = dir == 1 ? 'LONG ' : 'SHORT';
    final t1s  = tp1Hit ? 'TP1@${tp1ExitP.toStringAsFixed(4)} ' : '';
    return '#$id $side  En:${entry.toStringAsFixed(4)}  TP1:${tp1.toStringAsFixed(4)}'
        '  SL:${sl.toStringAsFixed(4)}'
        '  ${entryTime.toIso8601String().substring(0,16)}'
        '→${exitTime?.toIso8601String().substring(0,16) ?? '...'}  '
        '${t1s}Ex@${tp2ExitP.toStringAsFixed(4)}[$reason]'
        '  PnL:${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(4)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI SIGNAL
// ─────────────────────────────────────────────────────────────────────────────

class _Sig {
  final double upLine, dnLine;
  final int    trend;
  final bool   buy, sell;
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

List<Candle> _agg(List<Candle> c, int mult) {
  final out = <Candle>[];
  for (int i = 0; i + mult - 1 < c.length; i += mult) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < mult; j++) {
      hi = max(hi, c[i+j].high); lo = min(lo, c[i+j].low); vol += c[i+j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i+mult-1].close, vol, out.length));
  }
  return out;
}

/// Simulate 3 synthetic 5m bars per 15m bar (linear close interpolation).
List<Candle> _sim5m(List<Candle> c15) {
  final out = <Candle>[];
  for (final c in c15) {
    final dp      = (c.close - c.open) / 3.0;
    final bullish = c.close >= c.open;
    final rng     = c.high - c.low;
    final mid     = rng / 6.0;
    for (int i = 0; i < 3; i++) {
      final o5 = i == 0 ? c.open : c.open + dp * i;
      final c5 = c.open + dp * (i + 1);
      double h5, l5;
      if (bullish) {
        h5 = i == 2 ? c.high : max(o5, c5) + mid * (i == 0 ? 0.2 : 0.5);
        l5 = i == 0 ? c.low  : min(o5, c5) - mid * 0.2;
      } else {
        h5 = i == 0 ? c.high : max(o5, c5) + mid * 0.2;
        l5 = i == 2 ? c.low  : min(o5, c5) - mid * (i == 0 ? 0.2 : 0.5);
      }
      h5 = max(h5.clamp(c.low, c.high), max(o5, c5));
      l5 = min(l5.clamp(c.low, c.high), min(o5, c5));
      out.add(Candle(c.time.add(Duration(minutes: 5 * i)),
          o5, h5, l5, c5, c.volume / 3.0, out.length));
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI (rolling SuperTrend, no look-ahead)
// ─────────────────────────────────────────────────────────────────────────────

List<_Sig> _sfi(List<Candle> cs, int p, double m) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
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
  int prevT = 1;
  final out = <_Sig>[];
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

List<double> _atrList(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high - cs[i].low,
           max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i-1] * (p-1) + tr[i]) / p); }
  }
  return atr;
}

// ─────────────────────────────────────────────────────────────────────────────
// SR ZONE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<SRZone> _knownSup(List<SRZone> zones, int barIdx, int srLen) =>
    zones.where((z) => !z.isResistance && z.boxLeft + srLen <= barIdx && !z.b).toList();

List<SRZone> _knownRes(List<SRZone> zones, int barIdx, int srLen) =>
    zones.where((z) => z.isResistance  && z.boxLeft + srLen <= barIdx && !z.b).toList();

SRZone? _nearestSup(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxTop > price * 1.005) continue;
    final d = price - z.boxTop;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

SRZone? _nearestRes(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxBottom < price * 0.995) continue;
    final d = z.boxBottom - price;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

bool _near(SRZone z, double price, double pct) {
  final buf = price * pct / 100;
  return price >= z.boxBottom - buf && price <= z.boxTop + buf;
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class BtResultV2 {
  final List<TradeV2> trades;
  final double netPnl, grossPnl, totalFees, totalSlip, totalFund;
  final double maxDd, returnPct, calmar;
  final int wins;
  BtResultV2({required this.trades, required this.netPnl, required this.grossPnl,
               required this.totalFees, required this.totalSlip, required this.totalFund,
               required this.maxDd, required this.returnPct, required this.calmar,
               required this.wins});
  int get total => trades.length;
  double get wr  => total == 0 ? 0 : wins / total * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

BtResultV2 backtestV2(BtConfigV2 cfg) {
  // ── Load & prepare candles ────────────────────────────────────────────────
  final c15 = _clean(_loadCsv(cfg.csvPath), 15);
  if (c15.length < 100) throw Exception('Need ≥100 candles, got ${c15.length}');
  final c45 = _agg(c15, 3);
  final c5  = _sim5m(c15);

  // ── SFI on all 3 timeframes ───────────────────────────────────────────────
  final sfi45 = _sfi(c45, cfg.sfiPeriod, cfg.sfiMult);
  final sfi15 = _sfi(c15, cfg.sfiPeriod, cfg.sfiMult);
  final sfi5  = _sfi(c5,  cfg.sfiPeriod, cfg.sfiMult);
  final atr5  = _atrList(c5, 14);

  // ── SR zones on 45m, 15m, 5m ─────────────────────────────────────────────
  final sr = SupportResistanceIndicator(srMargin: cfg.srMargin, avoidFBO: true, checkHist: true);

  final res45 = sr.calculate(c45);
  final zones45 = [...res45.support, ...res45.resistance];

  sr.calculate(c15); // reset internal state before reuse
  final res15 = SupportResistanceIndicator(
      detectionLength: cfg.srLen15, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true).calculate(c15);
  final zones15 = [...res15.support, ...res15.resistance];

  final res5 = SupportResistanceIndicator(
      detectionLength: cfg.srLen5, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true).calculate(c5);
  final zones5 = [...res5.support, ...res5.resistance];

  print('  SR zones → 45m:${zones45.length}  15m:${zones15.length}  5m:${zones5.length}');

  // ── Index helpers ─────────────────────────────────────────────────────────
  // Each 15m bar → 3 synthetic 5m bars
  // Each 45m bar → 3 15m bars → 9 5m bars
  int i15For(int i5) => i5 ~/ 3;
  int i45For(int i5) => i5 ~/ 9;

  // ── Backtest state ────────────────────────────────────────────────────────
  final trades    = <TradeV2>[];
  int   tradeId   = 0;
  double netEq    = 0, grossEq = 0, totFee = 0, totSlip = 0, totFund = 0;
  double peak     = 0, maxDd  = 0;
  int    cooldown = 0;
  TradeV2? active;
  bool pendingLong = false, pendingShort = false;
  DateTime lastFund = DateTime(2000);
  final dep = cfg.notional * cfg.leverage;

  // ── Main loop on 5m bars ──────────────────────────────────────────────────
  for (int i = 1; i < c5.length; i++) {
    final c   = c5[i];
    final i15 = i15For(i);
    final i45 = i45For(i);

    // Bias-free: previous bar's signals
    final sig5prev  = sfi5[i - 1];   // used for 20% trail exit trigger
    final sig5cur   = sfi5[i];       // used for new entry signal detection
    final sig15     = i15 > 0 ? sfi15[i15 - 1] : sfi15[0];
    final sig45     = i45 > 0 ? sfi45[i45 - 1] : sfi45[0];

    // Known SR zones at current bar (bias-free delay per timeframe)
    final sup45 = _knownSup(zones45, i45, cfg.srLen45);
    final sup15 = _knownSup(zones15, i15, cfg.srLen15);
    final sup5  = _knownSup(zones5,  i,   cfg.srLen5);
    final res45 = _knownRes(zones45, i45, cfg.srLen45);
    final res15 = _knownRes(zones15, i15, cfg.srLen15);
    final res5  = _knownRes(zones5,  i,   cfg.srLen5);

    // Combined zone pools
    final allSup = [...sup45, ...sup15, ...sup5];
    final allRes = [...res45, ...res15, ...res5];

    // ── Fill pending entry at this bar's open ─────────────────────────────
    if (active == null && cooldown == 0 && (pendingLong || pendingShort)) {
      final dir = pendingLong ? 1 : -1;
      pendingLong = pendingShort = false;

      final fill = c.open;
      final atr  = atr5[i];

      SRZone? entryZone, tpZone;
      double slPrice, tp1Price;

      if (dir == 1) {
        entryZone = _nearestSup(allSup, fill);
        tpZone    = _nearestRes(allRes, fill);
        slPrice   = entryZone != null
            ? entryZone.boxBottom * (1 - cfg.slBufferPct / 100)
            : fill - cfg.atrFallbackTp * atr;
        tp1Price  = tpZone != null
            ? tpZone.boxBottom
            : fill + cfg.atrFallbackTp * atr;
      } else {
        entryZone = _nearestRes(allRes, fill);
        tpZone    = _nearestSup(allSup, fill);
        slPrice   = entryZone != null
            ? entryZone.boxTop * (1 + cfg.slBufferPct / 100)
            : fill + cfg.atrFallbackTp * atr;
        tp1Price  = tpZone != null
            ? tpZone.boxTop
            : fill - cfg.atrFallbackTp * atr;
      }

      final validL = dir == 1  && tp1Price > fill && fill > slPrice;
      final validS = dir == -1 && tp1Price < fill && fill < slPrice;

      if (validL || validS) {
        final qty   = dep / fill;
        final t     = TradeV2(id: tradeId++, dir: dir, entry: fill,
            qty: qty, tp1: tp1Price, sl: slPrice, entryTime: c.time);
        final eFee  = dep * cfg.commission / 100;
        final eSlip = dep * cfg.slippage   / 100;
        t.feePaid  += eFee;  t.slipPaid += eSlip;
        totFee     += eFee;  totSlip    += eSlip;
        active = t;
        trades.add(t);
      }
    } else if (active == null) {
      pendingLong = pendingShort = false;
    }

    // ── Funding ───────────────────────────────────────────────────────────
    if (active != null && active!.open && c.time.difference(lastFund).inHours >= 8) {
      lastFund = c.time;
      final f  = dep * cfg.funding / 100;
      active!.fundPaid += f;
      totFund          += f;
    }

    // ── TP1 / SL / Trail exit ─────────────────────────────────────────────
    if (active != null && active!.open) {
      final t   = active!;
      final tpH = t.dir == 1 ? c.high >= t.tp1  : c.low  <= t.tp1;
      final slH = t.dir == 1 ? c.low  <= t.sl   : c.high >= t.sl;

      if (slH) {
        // SL — close full position (SL wins even if TP also hit same bar)
        final pnlG  = t.dir == 1
            ? (t.sl - t.entry) / t.entry * dep
            : (t.entry - t.sl) / t.entry * dep;
        final xFee  = dep * (t.tp1Hit ? 0.20 : 1.0) * cfg.commission / 100;
        final xSlip = dep * (t.tp1Hit ? 0.20 : 1.0) * cfg.slippage   / 100;
        t.feePaid += xFee; t.slipPaid += xSlip;
        totFee += xFee; totSlip += xSlip;
        grossEq += pnlG;
        t.tp2ExitP = t.sl;
        t.reason   = t.tp1Hit ? 'TP1+SL' : 'SL';
        t.exitTime = c.time;
        t.pnl      = (t.tp1Hit
            ? (t.dir==1 ? (t.tp1ExitP-t.entry)/t.entry*dep*0.80 : (t.entry-t.tp1ExitP)/t.entry*dep*0.80)
            : 0.0) + pnlG - t.feePaid - t.slipPaid - t.fundPaid;
        netEq += t.pnl - (t.tp1Hit
            ? (t.dir==1 ? (t.tp1ExitP-t.entry)/t.entry*dep*0.80 : (t.entry-t.tp1ExitP)/t.entry*dep*0.80) - (dep*0.80*cfg.commission/100) - (dep*0.80*cfg.slippage/100)
            : 0.0); // incremental: only the 20% (or 100%) SL portion not yet in netEq
        netEq += pnlG - xFee - xSlip - (t.tp1Hit ? t.fundPaid : 0.0);
        if (!t.tp1Hit) netEq -= t.fundPaid; // fund not yet counted
        cooldown = cfg.cooldownBars;
        active   = null;

      } else if (!t.tp1Hit && tpH) {
        // TP1 — close 80%
        t.tp1Hit   = true;
        t.tp1ExitP = t.tp1;
        final pnl80 = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * dep * 0.80
            : (t.entry - t.tp1) / t.entry * dep * 0.80;
        final f80   = dep * 0.80 * cfg.commission / 100;
        final s80   = dep * 0.80 * cfg.slippage   / 100;
        t.feePaid += f80; t.slipPaid += s80;
        totFee += f80; totSlip += s80;
        grossEq += pnl80;
        netEq   += pnl80 - f80 - s80;

      } else if (t.tp1Hit) {
        // Trail 20% — exit when 5m SFI reverses (use previous bar's signal)
        final reversed = t.dir == 1 ? sig5prev.sell : sig5prev.buy;
        if (reversed) {
          final exitP = c.close;
          t.tp2ExitP  = exitP;
          t.reason    = 'TP1+FLIP';
          t.exitTime  = c.time;
          final pnl20 = t.dir == 1
              ? (exitP - t.entry) / t.entry * dep * 0.20
              : (t.entry - exitP) / t.entry * dep * 0.20;
          final f20   = dep * 0.20 * cfg.commission / 100;
          final s20   = dep * 0.20 * cfg.slippage   / 100;
          t.feePaid += f20; t.slipPaid += s20;
          totFee += f20; totSlip += s20;
          grossEq += pnl20;
          netEq   += pnl20 - f20 - s20 - t.fundPaid;
          t.pnl    = (t.dir==1 ? (t.tp1ExitP-t.entry)/t.entry*dep*0.80 : (t.entry-t.tp1ExitP)/t.entry*dep*0.80)
              + pnl20 - t.feePaid - t.slipPaid - t.fundPaid;
          active   = null;
        }
      }
    }

    // ── Drawdown ──────────────────────────────────────────────────────────
    double openPnl = 0;
    if (active != null && active!.open) {
      final t   = active!;
      final rem = t.tp1Hit ? 0.20 : 1.0;
      openPnl = t.dir == 1
          ? (c.close - t.entry) / t.entry * dep * rem
          : (t.entry - c.close) / t.entry * dep * rem;
      openPnl -= t.feePaid + t.slipPaid + t.fundPaid;
    }
    final cur = netEq + openPnl;
    if (cur > peak) peak = cur;
    if (peak - cur > maxDd) maxDd = peak - cur;

    if (cooldown > 0) cooldown--;

    // ── New entry signal — 5m SFI flip + SR proximity ────────────────────
    if (active == null && cooldown == 0 && !pendingLong && !pendingShort) {
      // 45m + 15m trend filter: both must not be opposite direction
      final b45 = sig45.trend;
      final b15 = sig15.trend;

      if (sig5cur.buy && b45 >= 0 && b15 >= 0) {
        // LONG: price near support from any timeframe
        final ns = _nearestSup(allSup, c.close);
        if (ns != null && _near(ns, c.close, cfg.proximityPct)) pendingLong = true;

      } else if (sig5cur.sell && b45 <= 0 && b15 <= 0) {
        // SHORT: price near resistance from any timeframe
        final nr = _nearestRes(allRes, c.close);
        if (nr != null && _near(nr, c.close, cfg.proximityPct)) pendingShort = true;
      }
    }
  }

  // ── Force-close at end ────────────────────────────────────────────────────
  if (active != null && active!.open) {
    final t     = active!;
    final exitP = c5.last.close;
    final rem   = t.tp1Hit ? 0.20 : 1.0;
    t.tp2ExitP  = exitP;
    t.exitTime  = c5.last.time;
    t.reason    = t.tp1Hit ? 'END(TP1+)' : 'END';
    final pnlR  = t.dir == 1
        ? (exitP - t.entry) / t.entry * dep * rem
        : (t.entry - exitP) / t.entry * dep * rem;
    final xFee  = dep * rem * cfg.commission / 100;
    final xSlip = dep * rem * cfg.slippage   / 100;
    t.feePaid += xFee; t.slipPaid += xSlip;
    totFee += xFee; totSlip += xSlip;
    grossEq += pnlR;
    netEq   += pnlR - xFee - xSlip - t.fundPaid;
    t.pnl    = (t.tp1Hit
        ? (t.dir==1 ? (t.tp1ExitP-t.entry)/t.entry*dep*0.80 : (t.entry-t.tp1ExitP)/t.entry*dep*0.80) - dep*0.80*(cfg.commission+cfg.slippage)/100
        : 0.0) + pnlR - xFee - xSlip - t.fundPaid;
    active = null;
  }

  final closed = trades.where((t) => t.reason.isNotEmpty).toList();
  final wins   = closed.where((t) => t.pnl > 0).length;
  final retPct = dep > 0 ? netEq / dep * 100 : 0.0;
  final ddPct  = dep > 0 ? maxDd / dep * 100  : 0.0;
  final calmar = ddPct.abs() > 0 ? retPct / ddPct.abs() : 0.0;

  return BtResultV2(trades: closed, netPnl: netEq, grossPnl: grossEq,
      totalFees: totFee, totalSlip: totSlip, totalFund: totFund,
      maxDd: maxDd, returnPct: retPct, calmar: calmar, wins: wins);
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT
// ─────────────────────────────────────────────────────────────────────────────

void _sep(String t) {
  const w = 88;
  final p = ((w - t.length - 2) / 2).floor();
  print('─' * p + ' $t ' + '─' * (w - p - t.length - 2));
}

void printV2(BtConfigV2 cfg, BtResultV2 r) {
  print('');
  _sep('BACKTEST V2 — ${cfg.symbol}  (SR: 45m+15m+5m | SFI flip: 5m)');
  print('  Period      : ${r.trades.isNotEmpty ? r.trades.first.entryTime.toIso8601String().substring(0,10) : "-"}'
        ' → ${r.trades.isNotEmpty ? r.trades.last.exitTime?.toIso8601String().substring(0,10) ?? "-" : "-"}');
  print('  Notional    : \$${cfg.notional}  Leverage: ${cfg.leverage}×  = \$${cfg.notional*cfg.leverage}/trade');
  print('');
  _sep('PERFORMANCE');
  print('  Total Trades: ${r.total}');
  print('  Wins        : ${r.wins}  (${r.wr.toStringAsFixed(1)}%)');
  print('  Net PnL     : ${r.netPnl  >= 0 ? "+" : ""}\$${r.netPnl.toStringAsFixed(4)}');
  print('  Gross PnL   : ${r.grossPnl >= 0 ? "+" : ""}\$${r.grossPnl.toStringAsFixed(4)}');
  print('  Return      : ${r.returnPct >= 0 ? "+" : ""}${r.returnPct.toStringAsFixed(2)}%');
  print('  Max Drawdown: \$${r.maxDd.toStringAsFixed(4)} (${(r.maxDd/(cfg.notional*cfg.leverage)*100).toStringAsFixed(1)}%)');
  print('  Calmar      : ${r.calmar.toStringAsFixed(2)}');
  print('  Avg/Trade   : ${r.netPnl/r.total >= 0 ? "+" : ""}\$${(r.total > 0 ? r.netPnl/r.total : 0).toStringAsFixed(4)}');
  print('');
  _sep('COSTS');
  print('  Fees        : -\$${r.totalFees.toStringAsFixed(4)}   (${cfg.commission}% blended × 2)');
  print('  Slippage    : -\$${r.totalSlip.toStringAsFixed(4)}   (${cfg.slippage}% × 2)');
  print('  Funding     : -\$${r.totalFund.toStringAsFixed(4)}   (${cfg.funding}%/8h)');
  print('  Total Costs : -\$${(r.totalFees+r.totalSlip+r.totalFund).toStringAsFixed(4)}');

  if (r.trades.isNotEmpty) {
    print('');
    _sep('BY EXIT TYPE');
    final byR = <String, List<TradeV2>>{};
    for (final t in r.trades) byR.putIfAbsent(t.reason, () => []).add(t);
    for (final e in byR.entries) {
      final wn  = e.value.where((t) => t.pnl > 0).length;
      final sum = e.value.fold(0.0, (s, t) => s + t.pnl);
      print('  ${e.key.padRight(14)}: ${e.value.length.toString().padLeft(4)} trades'
            '  WR:${(wn/e.value.length*100).toStringAsFixed(0).padLeft(3)}%'
            '  Net:${sum >= 0 ? "+" : ""}\$${sum.toStringAsFixed(2)}');
    }
    print('');
    _sep('LAST 20 TRADES');
    final show = r.trades.length > 20 ? r.trades.sublist(r.trades.length - 20) : r.trades;
    for (final t in show) print('  $t');
  }

  final grade = r.calmar >= 5 && r.returnPct >= 50 ? 'A ★★★'
              : r.calmar >= 3 && r.returnPct >= 30 ? 'B ★★'
              : r.calmar >= 1 && r.returnPct >= 10 ? 'C ★'
              : r.netPnl > 0                        ? 'D'
              : 'F';
  print('');
  print('  Grade: $grade  (Calmar ${r.calmar.toStringAsFixed(2)}, Return ${r.returnPct.toStringAsFixed(1)}%)');
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  const base = '/Users/ayush/Desktop/candlestick data/15m';

  final configs = [
    BtConfigV2(symbol: 'SOLUSDT',  csvPath: '$base/SOLUSDT15m.csv'),
    BtConfigV2(symbol: 'XRPUSDT',  csvPath: '$base/XRPUSDT15m.csv'),
    BtConfigV2(symbol: 'TRBUSDT',  csvPath: '$base/TRBUSDT15m.csv'),
    BtConfigV2(symbol: 'BTCUSDT',  csvPath: '$base/BTCUSDT15m.csv'),
    BtConfigV2(symbol: 'ETHUSDT',  csvPath: '$base/ETHUSDT15m.csv'),
    BtConfigV2(symbol: 'DOGEUSDT', csvPath: '$base/DOGEUSDT15m.csv'),
    BtConfigV2(symbol: 'BNBUSDT',  csvPath: '$base/BNBUSDT15m.csv'),
  ];

  for (final cfg in configs) {
    if (!File(cfg.csvPath).existsSync()) {
      print('  [SKIP] ${cfg.symbol}');
      continue;
    }
    stdout.write('Running ${cfg.symbol} ... ');
    try {
      final r = backtestV2(cfg);
      printV2(cfg, r);
    } catch (e, st) {
      print('ERROR: $e\n$st');
    }
  }
}
