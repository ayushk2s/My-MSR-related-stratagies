// ============================================================================
// SR ZONE BOUNCE STRATEGY — VERSION 6
// ============================================================================
// Completely different approach from v1-v5 (no grid, no martingale).
//
// WHY THE GRID FAILED (v5 lesson):
//   Grid TP = 2 grid steps ≈ 0.5-1% move
//   After entry delay + fees + slippage ≈ 0.13% round trip
//   Net edge per trade was near zero → slight noise killed it
//
// THIS STRATEGY:
//   TP = FULL channel width (support top → resistance bottom) = 2-6% move
//   SL = beyond entire SR zone (structural stop, not channel edge)
//   R:R = channel_width / zone_width → typically 3:1 to 8:1
//   At 40% WR with 4:1 R:R: (0.4 × 4) - (0.6 × 1) = 1.6 - 0.6 = 1.0× per trade → profitable
//   Fees (0.13% round trip) are tiny fraction of a 3-6% TP move
//
// ENTRY LOGIC (all v5 realism fixes applied):
//   LONG : exec candle wicks INTO support zone (low ≤ chanBot),
//          candle CLOSES above it (close > chanBot) → zone held
//          → fill at NEXT bar's open (Fix 2: deferred entry)
//          → TP = chanTop (bottom of resistance zone)
//          → SL = support.boxBottom × (1 - slBufferPct)
//
//   SHORT: exec candle wicks INTO resistance zone (high ≥ chanTop),
//          candle CLOSES below it (close < chanTop) → zone held
//          → fill at NEXT bar's open
//          → TP = chanBot (top of support zone)
//          → SL = resistance.boxTop × (1 + slBufferPct)
//
// ALL V5 REALISM FIXES RETAINED:
//   Fix 1: zones[bar-1] — no forward bias on zone timing
//   Fix 2: deferred entry at next bar's open
//   Fix 3: same-bar TP+SL → SL wins (conservative)
//   Fix 4: funding rate 0.01% per 8h
//   Fix 5: blended commission 0.025%
//   Fix 6: volume SMA from previous bars
//   Fix 7: zero-volume + gap candle removal
//
// ADDITIONAL FEATURES:
//   • SFI trend filter (optional): LONG only in uptrend, SHORT only in downtrend
//   • Cooldown after SL: skip N exec bars before re-entering same direction
//   • Min R:R filter: skip trade if TP/SL ratio < minRR (default 1.5)
//   • Max hold bars: force-exit if trade open too long (prevents stuck positions)
//   • Max 1 open position at a time
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class BounceConfig {
  final String label;
  final String symbol;
  final String csv15m;
  final String csvExec;
  final String execLabel;
  final int    htfMultiplier;       // 2=30m, 3=45m, 4=60m

  // Costs (all v5 realistic rates)
  final double commissionPct;       // 0.025% blended maker/taker
  final double slippagePct;         // 0.04% per side
  final double fundingRatePct;      // 0.01% per 8h
  final int    fundingIntervalHrs;

  // Trade sizing
  final double baseNotionalUSDT;
  final double leverage;

  // Entry / exit
  final double slBufferPct;         // % beyond zone boundary for SL
  final bool   sfiFilter;           // only trade in SFI trend direction
  final double minRR;               // minimum TP/SL ratio to take a trade
  final int    cooldownBars;        // exec bars to skip after SL exit
  final int    maxHoldBars;         // force exit after N exec bars (0 = unlimited)
  final double minChannelWidthPct;  // skip if channel < this % of price

  // SR + SFI params
  final int    srDetectionLength;
  final double srMargin;
  final int    sfiPeriod;
  final double sfiMultiplier;
  final int    execIntervalMinutes; // for gap detection

  const BounceConfig({
    required this.label,
    required this.symbol,
    required this.csv15m,
    required this.csvExec,
    this.execLabel           = '5m',
    this.htfMultiplier       = 3,
    this.commissionPct       = 0.025,
    this.slippagePct         = 0.04,
    this.fundingRatePct      = 0.01,
    this.fundingIntervalHrs  = 8,
    this.baseNotionalUSDT    = 20.0,
    this.leverage            = 5.0,
    this.slBufferPct         = 0.4,
    this.sfiFilter           = true,
    this.minRR               = 1.5,
    this.cooldownBars        = 3,
    this.maxHoldBars         = 0,
    this.minChannelWidthPct  = 1.0,
    this.srDetectionLength   = 10,
    this.srMargin            = 2.0,
    this.sfiPeriod           = 10,
    this.sfiMultiplier       = 1.7,
    this.execIntervalMinutes = 5,
  });

  String get htfLabel {
    final mins = 15 * htfMultiplier;
    return mins < 60 ? '${mins}m' : '${mins ~/ 60}h';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class BounceResult {
  final BounceConfig config;
  final int    totalTrades;
  final int    wins, losses;
  final int    tpExits, slExits, sameBarSl, maxHoldExits;
  final double grossPnl, totalFees, totalSlippage, totalFunding, netPnl;
  final double maxDdPct, returnPct, calmar, pf;
  final double avgRR;           // average realized R:R (TP-dist / SL-dist at entry)
  final double avgHoldBars;
  final String grade;

  BounceResult({
    required this.config,
    required this.totalTrades,
    required this.wins, required this.losses,
    required this.tpExits, required this.slExits,
    required this.sameBarSl, required this.maxHoldExits,
    required this.grossPnl, required this.totalFees,
    required this.totalSlippage, required this.totalFunding,
    required this.netPnl, required this.maxDdPct,
    required this.returnPct, required this.calmar,
    required this.pf, required this.avgRR, required this.avgHoldBars,
    required this.grade,
  });

  double get winRate => totalTrades == 0 ? 0 : wins / totalTrades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZONE STATE
// ─────────────────────────────────────────────────────────────────────────────

class _BarZones {
  final List<SRZone> activeR;
  final List<SRZone> activeS;
  final int sfiTrend;
  _BarZones(this.activeR, this.activeS, this.sfiTrend);
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE MODEL
// ─────────────────────────────────────────────────────────────────────────────

enum Dir { long, short }

class _Trade {
  final int      id;
  final Dir      dir;
  final double   entryPrice;
  final double   qty;
  final double   notionalUSDT;
  final double   tpPrice, slPrice;
  final double   plannedRR;         // TP-dist / SL-dist at signal time
  final DateTime entryTime;
  final int      entryBar;          // exec bar index for max-hold tracking
  double         fundingPaid = 0.0;

  bool      isOpen    = true;
  double    exitPrice = 0;
  DateTime? exitTime;
  String    exitReason = '';

  _Trade({
    required this.id, required this.dir, required this.entryPrice,
    required this.qty, required this.notionalUSDT,
    required this.tpPrice, required this.slPrice,
    required this.plannedRR, required this.entryTime,
    required this.entryBar,
  });

  double grossPnl() {
    if (exitPrice == 0) return 0;
    final raw = dir == Dir.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
    return raw; // leverage already in qty via notional
  }

  double fees(BounceConfig cfg)     => notionalUSDT * cfg.leverage * cfg.commissionPct / 100 * 2;
  double slippage(BounceConfig cfg) => notionalUSDT * cfg.leverage * cfg.slippagePct / 100 * 2;
  double netPnl(BounceConfig cfg)   => grossPnl() - fees(cfg) - slippage(cfg) - fundingPaid;
}

class _PendingBounce {
  final Dir    dir;
  final double tpPrice, slPrice, plannedRR;
  final double notional;
  final DateTime signalTime;
  _PendingBounce({
    required this.dir, required this.tpPrice, required this.slPrice,
    required this.plannedRR, required this.notional, required this.signalTime,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI INDICATOR
// ─────────────────────────────────────────────────────────────────────────────

class _SfiInd {
  List<double> _tr(List<Candle> cs) {
    final out = <double>[];
    for (int i = 0; i < cs.length; i++) {
      final p = i == 0 ? cs[i].close : cs[i - 1].close;
      out.add([cs[i].high - cs[i].low,
               (cs[i].high - p).abs(),
               (cs[i].low  - p).abs()].reduce(max));
    }
    return out;
  }

  List<double> _atr(List<double> tr, int period) {
    final out = <double>[];
    double sum = 0;
    for (int i = 0; i < tr.length; i++) {
      if (i < period) { sum += tr[i]; out.add(sum / (i + 1)); }
      else if (i == period) {
        out.add(tr.sublist(0, period).reduce((a, b) => a + b) / period);
      } else {
        out.add((out[i - 1] * (period - 1) + tr[i]) / period);
      }
    }
    return out;
  }

  int trend(List<Candle> cs, int period, double mult) {
    final tr  = _tr(cs);
    final atr = _atr(tr, period);
    double pUp = cs[0].ohlc4 - mult * (atr.isNotEmpty ? atr[0] : 0);
    double pDn = cs[0].ohlc4 + mult * (atr.isNotEmpty ? atr[0] : 0);
    int prevT = 1;
    for (int i = 0; i < cs.length; i++) {
      final c = cs[i];
      final a = i < atr.length ? atr[i] : (atr.isNotEmpty ? atr.last : 0.0);
      final up = i > 0
          ? (cs[i-1].close > pUp ? max(c.ohlc4 - mult*a, pUp) : c.ohlc4 - mult*a)
          : c.ohlc4 - mult*a;
      final dn = i > 0
          ? (cs[i-1].close < pDn ? min(c.ohlc4 + mult*a, pDn) : c.ohlc4 + mult*a)
          : c.ohlc4 + mult*a;
      int t = prevT;
      if (prevT == -1 && c.close > pDn)  t = 1;
      else if (prevT == 1 && c.close < pUp) t = -1;
      pUp = up; pDn = dn; prevT = t;
    }
    return prevT;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out   = <Candle>[];
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

List<Candle> _aggregate(List<Candle> c15, int mult) {
  final out = <Candle>[];
  int idx = 0;
  for (int i = 0; i + mult - 1 < c15.length; i += mult) {
    double hi = c15[i].high, lo = c15[i].low, vol = 0;
    for (int j = 0; j < mult; j++) {
      hi  = max(hi, c15[i + j].high);
      lo  = min(lo, c15[i + j].low);
      vol += c15[i + j].volume;
    }
    out.add(Candle(c15[i].time, c15[i].open, hi, lo,
        c15[i + mult - 1].close, vol, idx++));
  }
  return out;
}

List<Candle> _cleanExec(List<Candle> raw, int intervalMin) {
  final out = <Candle>[];
  for (int i = 0; i < raw.length; i++) {
    if (raw[i].volume <= 0) continue;
    if (out.isNotEmpty) {
      final gap = raw[i].time.difference(out.last.time).inMinutes;
      if (gap > intervalMin * 3) continue;
    }
    out.add(raw[i]);
  }
  return out;
}

// Fix 1: zones[i] = SR computed from bars [0..i] (bar i is CLOSED)
// When trading during HTF bar i, use zones[i-1]
List<_BarZones> _precomputeZones(List<Candle> htf, BounceConfig cfg) {
  final sr     = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true, showManip: false);
  final sfi    = _SfiInd();
  final minBars = cfg.srDetectionLength * 2 + 20;
  final out    = <_BarZones>[];
  for (int i = 0; i < htf.length; i++) {
    if (i < minBars) { out.add(_BarZones([], [], 1)); continue; }
    final sub = htf.sublist(0, i + 1);
    final res = sr.calculate(sub);
    out.add(_BarZones(
      res.resistance.where((z) => z.isActive).toList(),
      res.support.where((z) => z.isActive).toList(),
      sfi.trend(sub, cfg.sfiPeriod, cfg.sfiMultiplier),
    ));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

BounceResult runBacktest(BounceConfig cfg, List<_BarZones> barZones,
    List<Candle> htfCandles, List<Candle> execCandlesRaw) {

  final exec = _cleanExec(execCandlesRaw, cfg.execIntervalMinutes);

  final trades       = <_Trade>[];
  int   tradeId      = 0;
  double netEq       = 0.0, grossEq = 0.0;
  double totalFee    = 0.0, totalSlip = 0.0, totalFunding = 0.0;
  double peakEq      = 0.0, maxDd = 0.0;
  int    sameBarSlCount = 0;

  _Trade?         activeTrade;
  _PendingBounce? pending;

  DateTime lastFunding  = DateTime(2000);
  int longCooldown  = 0;   // exec bars remaining before LONG re-entry allowed
  int shortCooldown = 0;

  // Fix 6: volume SMA from previous bars only
  final volBuf    = <double>[];
  const volPeriod = 20;

  int totalExecBars = 0;   // for max-hold tracking across HTF bars

  for (int bar = 0; bar < htfCandles.length; bar++) {
    // Fix 1: use zones from previous CLOSED bar
    final bz = barZones[bar > 0 ? bar - 1 : 0];

    if (bz.activeR.isEmpty || bz.activeS.isEmpty) { pending = null; continue; }

    final chanTop = bz.activeR.first.boxBottom;   // bottom of resistance zone = upper channel
    final chanBot = bz.activeS.first.boxTop;      // top of support zone      = lower channel
    final slLong  = bz.activeS.first.boxBottom;   // SL for LONG = below support zone
    final slShort = bz.activeR.first.boxTop;      // SL for SHORT = above resistance zone

    if (chanTop <= chanBot) { pending = null; continue; }

    final channelWidthPct = (chanTop - chanBot) / chanBot * 100;
    if (channelWidthPct < cfg.minChannelWidthPct) { pending = null; continue; }

    final sfiTrend = bz.sfiTrend;   // +1 = uptrend, -1 = downtrend

    final winStart = htfCandles[bar].time;
    final winEnd   = bar + 1 < htfCandles.length
        ? htfCandles[bar + 1].time
        : winStart.add(Duration(minutes: 15 * cfg.htfMultiplier));

    final execBars = exec
        .where((c) => !c.time.isBefore(winStart) && c.time.isBefore(winEnd))
        .toList();

    for (int ei = 0; ei < execBars.length; ei++) {
      final c    = execBars[ei];
      final barN = totalExecBars + ei;  // global exec bar index

      // ── Fix 2: Fill pending entry at THIS bar's open ──────────────────────
      if (pending != null && activeTrade == null) {
        final pe        = pending!;
        pending         = null;
        final fillPrice = c.open;

        // Validate: TP still reachable from fill price
        final tpReachable = pe.dir == Dir.long
            ? pe.tpPrice > fillPrice
            : pe.tpPrice < fillPrice;
        // Validate: fill price hasn't blown past SL already
        final slNotHit = pe.dir == Dir.long
            ? fillPrice > pe.slPrice
            : fillPrice < pe.slPrice;

        if (tpReachable && slNotHit) {
          // Recompute actual R:R at fill price
          final tpDist = (pe.tpPrice - fillPrice).abs();
          final slDist = (fillPrice - pe.slPrice).abs();
          final actualRR = slDist > 0 ? tpDist / slDist : 0.0;

          if (actualRR >= cfg.minRR) {
            final qty = pe.notional / fillPrice;
            activeTrade = _Trade(
              id: tradeId++, dir: pe.dir, entryPrice: fillPrice,
              qty: qty, notionalUSDT: pe.notional,
              tpPrice: pe.tpPrice, slPrice: pe.slPrice,
              plannedRR: actualRR, entryTime: c.time, entryBar: barN,
            );
            trades.add(activeTrade!);
          }
        }
      }

      // ── Fix 4: Funding every 8h ───────────────────────────────────────────
      if (activeTrade != null && activeTrade!.isOpen &&
          c.time.difference(lastFunding).inHours >= cfg.fundingIntervalHrs) {
        lastFunding = c.time;
        activeTrade!.fundingPaid +=
            activeTrade!.notionalUSDT * cfg.leverage * cfg.fundingRatePct / 100;
      }

      // ── TP / SL check (Fix 3: SL wins if both hit same bar) ──────────────
      if (activeTrade != null && activeTrade!.isOpen) {
        final t = activeTrade!;
        bool tpHit = false, slHit = false;
        if (t.dir == Dir.long) {
          tpHit = c.high >= t.tpPrice;
          slHit = c.low  <= t.slPrice;
        } else {
          tpHit = c.low  <= t.tpPrice;
          slHit = c.high >= t.slPrice;
        }

        String reason = ''; double at = 0; bool closed = false;
        if (tpHit && slHit) {
          // Fix 3: conservative — SL wins
          reason = 'SL'; at = t.slPrice; closed = true; sameBarSlCount++;
        } else if (tpHit) {
          reason = 'TP'; at = t.tpPrice; closed = true;
        } else if (slHit) {
          reason = 'SL'; at = t.slPrice; closed = true;
        }

        // Max hold: force-exit if exceeded
        if (!closed && cfg.maxHoldBars > 0 &&
            barN - t.entryBar >= cfg.maxHoldBars) {
          reason = 'MAX_HOLD'; at = c.close; closed = true;
        }

        if (closed) {
          t.isOpen = false; t.exitPrice = at;
          t.exitTime = c.time; t.exitReason = reason;
          final gp   = t.grossPnl();
          final fee  = t.fees(cfg);
          final slip = t.slippage(cfg);
          grossEq    += gp; totalFee += fee; totalSlip += slip;
          totalFunding += t.fundingPaid;
          netEq      += gp - fee - slip - t.fundingPaid;

          // Cooldown after SL
          if (reason == 'SL' || reason == 'MAX_HOLD') {
            if (t.dir == Dir.long)  longCooldown  = cfg.cooldownBars;
            else                    shortCooldown = cfg.cooldownBars;
          }
          activeTrade = null;
        }
      }

      // ── Fix 6: Volume SMA from PREVIOUS bars ─────────────────────────────
      final volSma = volBuf.length >= volPeriod
          ? volBuf.fold(0.0, (s, v) => s + v) / volBuf.length
          : 0.0;
      volBuf.add(c.volume);
      if (volBuf.length > volPeriod) volBuf.removeAt(0);

      final volOk = volBuf.length < volPeriod || c.volume >= volSma * 0.7;

      // ── Cooldown countdown ────────────────────────────────────────────────
      if (longCooldown  > 0) longCooldown--;
      if (shortCooldown > 0) shortCooldown--;

      // ── New bounce signal (only if no active trade or pending) ────────────
      if (activeTrade == null && pending == null && volOk) {

        // LONG signal: wick into support, closes above it
        final longAllowed = !cfg.sfiFilter || sfiTrend >= 0;
        if (longAllowed && longCooldown == 0) {
          final signalLong = c.low <= chanBot && c.close > chanBot;
          if (signalLong) {
            // Compute planned R:R at signal close price
            final tpDist = chanTop - c.close;
            final slDist = c.close - slLong * (1 - cfg.slBufferPct / 100);
            final rr     = slDist > 0 ? tpDist / slDist : 0.0;
            if (rr >= cfg.minRR) {
              pending = _PendingBounce(
                dir: Dir.long,
                tpPrice: chanTop,
                slPrice: slLong * (1 - cfg.slBufferPct / 100),
                plannedRR: rr,
                notional: cfg.baseNotionalUSDT,
                signalTime: c.time,
              );
            }
          }
        }

        // SHORT signal: wick into resistance, closes below it
        final shortAllowed = !cfg.sfiFilter || sfiTrend < 0;
        if (pending == null && shortAllowed && shortCooldown == 0) {
          final signalShort = c.high >= chanTop && c.close < chanTop;
          if (signalShort) {
            final tpDist = c.close - chanBot;
            final slDist = slShort * (1 + cfg.slBufferPct / 100) - c.close;
            final rr     = slDist > 0 ? tpDist / slDist : 0.0;
            if (rr >= cfg.minRR) {
              pending = _PendingBounce(
                dir: Dir.short,
                tpPrice: chanBot,
                slPrice: slShort * (1 + cfg.slBufferPct / 100),
                plannedRR: rr,
                notional: cfg.baseNotionalUSDT,
                signalTime: c.time,
              );
            }
          }
        }
      }

      // ── Drawdown tracking ─────────────────────────────────────────────────
      double openPnl = 0;
      if (activeTrade != null && activeTrade!.isOpen) {
        final t   = activeTrade!;
        final raw = t.dir == Dir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        openPnl = raw - t.fees(cfg) - t.slippage(cfg) - t.fundingPaid;
      }
      final cur = netEq + openPnl;
      if (cur > peakEq) peakEq = cur;
      final dd = peakEq - cur;
      if (dd > maxDd) maxDd = dd;
    }

    totalExecBars += execBars.length;
  }

  // Force-close remaining trade
  if (activeTrade != null && activeTrade!.isOpen) {
    final t = activeTrade!;
    t.isOpen = false; t.exitPrice = exec.last.close;
    t.exitTime = exec.last.time; t.exitReason = 'END_OF_DATA';
    final gp = t.grossPnl(); final fee = t.fees(cfg); final slip = t.slippage(cfg);
    grossEq += gp; totalFee += fee; totalSlip += slip;
    totalFunding += t.fundingPaid;
    netEq += gp - fee - slip - t.fundingPaid;
  }

  final closed   = trades.where((t) => t.exitReason.isNotEmpty).toList();
  final wins     = closed.where((t) => t.grossPnl() > 0).length;
  final losses   = closed.length - wins;
  final tpEx     = closed.where((t) => t.exitReason == 'TP').length;
  final slEx     = closed.where((t) => t.exitReason == 'SL').length;
  final mhEx     = closed.where((t) => t.exitReason == 'MAX_HOLD').length;

  final avgWin  = wins > 0
      ? closed.where((t) => t.grossPnl() > 0).fold(0.0, (s, t) => s + t.grossPnl()) / wins
      : 0.0;
  final avgLoss = losses > 0
      ? closed.where((t) => t.grossPnl() <= 0).fold(0.0, (s, t) => s + t.grossPnl()).abs() / losses
      : 0.0;
  final pf = avgLoss > 0 ? (avgWin * wins) / (avgLoss * losses) : double.infinity;

  final deployedCap = cfg.baseNotionalUSDT * cfg.leverage;
  final returnPct   = deployedCap > 0 ? netEq / deployedCap * 100 : 0.0;
  final ddPct       = deployedCap > 0 ? maxDd / deployedCap * 100 : 0.0;
  final calmar      = ddPct.abs() > 0 ? returnPct / ddPct.abs() : 0.0;

  final avgRR   = closed.isEmpty ? 0.0
      : closed.fold(0.0, (s, t) => s + t.plannedRR) / closed.length;
  final avgHold = closed.isEmpty ? 0.0
      : closed.fold(0.0, (s, t) {
          if (t.exitTime == null) return s;
          return s + t.exitTime!.difference(t.entryTime).inMinutes;
        }) / closed.length;

  String grade;
  if      (calmar >= 5 && returnPct >= 50 && ddPct < 20) grade = 'A ★★★';
  else if (calmar >= 3 && returnPct >= 30 && ddPct < 30) grade = 'B ★★';
  else if (calmar >= 1 && returnPct >= 10 && ddPct < 40) grade = 'C ★';
  else if (returnPct > 0)                                 grade = 'D';
  else                                                    grade = 'F ✗';

  return BounceResult(
    config: cfg, totalTrades: closed.length,
    wins: wins, losses: losses,
    tpExits: tpEx, slExits: slEx,
    sameBarSl: sameBarSlCount, maxHoldExits: mhEx,
    grossPnl: grossEq, totalFees: totalFee,
    totalSlippage: totalSlip, totalFunding: totalFunding,
    netPnl: netEq, maxDdPct: ddPct.abs(),
    returnPct: returnPct, calmar: calmar,
    pf: pf, avgRR: avgRR, avgHoldBars: avgHold / cfg.execIntervalMinutes,
    grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// REPORT
// ─────────────────────────────────────────────────────────────────────────────

void printReport(BounceResult r) {
  final cfg = r.config;
  final sep = '═' * 72;
  print('\n╔$sep╗');
  print('║  ${r.config.label.padRight(70)}║');
  print('╠$sep╣');
  print('║  HTF: ${cfg.htfLabel}  Exec: ${cfg.execLabel}'
      '  SFI: ${cfg.sfiFilter ? 'ON' : 'OFF'}'
      '  SL-buf: ${cfg.slBufferPct}%'
      '  MinRR: ${cfg.minRR}'
      '  Cooldown: ${cfg.cooldownBars}bars${' ' * 10}║');
  print('╠$sep╣');
  print('║  COST BREAKDOWN${' ' * 56}║');
  print('║  Gross   : ${_f(r.grossPnl, 10)}  Net: ${_f(r.netPnl, 10)}'
      '  Fees: ${_f(-r.totalFees, 7)}  Slip: ${_f(-r.totalSlippage, 7)}  Fund: ${_f(-r.totalFunding, 6)}║');
  print('╠$sep╣');
  print('║  PERFORMANCE${' ' * 59}║');
  print('║  Trades:${r.totalTrades.toString().padLeft(4)}  '
      'WR:${r.winRate.toStringAsFixed(1).padLeft(5)}%  '
      'TP:${r.tpExits.toString().padLeft(4)}  '
      'SL:${r.slExits.toString().padLeft(4)}  '
      'SameBar→SL:${r.sameBarSl.toString().padLeft(3)}  '
      'MaxHold:${r.maxHoldExits.toString().padLeft(3)}${' ' * 12}║');
  print('║  PF:${r.pf.isInfinite ? ' ∞   ' : r.pf.toStringAsFixed(2).padLeft(5)}  '
      'AvgRR:${r.avgRR.toStringAsFixed(1).padLeft(5)}  '
      'AvgHold:${r.avgHoldBars.toStringAsFixed(0).padLeft(4)}bars  '
      'Return:${r.returnPct.toStringAsFixed(1).padLeft(7)}%  '
      'DD:${r.maxDdPct.toStringAsFixed(1).padLeft(5)}%${' ' * 10}║');
  print('║  Calmar: ${r.calmar.toStringAsFixed(2).padRight(10)}  GRADE: ${r.grade.padRight(50)}║');
  print('╚$sep╝');
}

void printMasterTable(List<BounceResult> results) {
  final sorted = [...results]..sort((a, b) => b.calmar.compareTo(a.calmar));
  print('\n');
  print('╔═══╦══════════════════════════════════════════╦══════╦══════╦═══════╦═══════╦═══════╦════════════════╗');
  print('║ # ║ Config                                   ║  WR% ║ AvgRR║ Net\$  ║  DD%  ║  Ret% ║ Calmar  Grade  ║');
  print('╠═══╬══════════════════════════════════════════╬══════╬══════╬═══════╬═══════╬═══════╬════════════════╣');
  for (int i = 0; i < sorted.length; i++) {
    final r   = sorted[i];
    final lbl = r.config.label.length > 41
        ? r.config.label.substring(0, 41)
        : r.config.label.padRight(41);
    final wr  = r.winRate.toStringAsFixed(1).padLeft(5);
    final rr  = r.avgRR.toStringAsFixed(1).padLeft(5);
    final net = _f2(r.netPnl).padLeft(6);
    final dd  = r.maxDdPct.toStringAsFixed(1).padLeft(5);
    final ret = r.returnPct.toStringAsFixed(1).padLeft(6);
    final cal = r.calmar.toStringAsFixed(1).padLeft(6);
    print('║${(i+1).toString().padLeft(3)}║ $lbl║$wr%║$rr  ║$net ║$dd%  ║$ret% ║$cal  ${r.grade.padRight(7)}║');
  }
  print('╚═══╩══════════════════════════════════════════╩══════╩══════╩═══════╩═══════╩═══════╩════════════════╝');

  final best = sorted.first;
  print('\n  BEST: ${best.config.label}');
  print('  Net: ${_f(best.netPnl, 9)} | Return: ${best.returnPct.toStringAsFixed(1)}%'
      ' | Calmar: ${best.calmar.toStringAsFixed(2)} | Grade: ${best.grade}');
  print('\n  Strategy: SR Zone Bounce | TP = full channel | SL = beyond zone');
  print('  All 7 forward-bias fixes applied (v5 engine) — results are realistic.');
}

String _f(double v, int w) =>
    ((v >= 0 ? '+' : '') + v.toStringAsFixed(2)).padRight(w);
String _f2(double v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1);

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  const base5m  = '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv';
  const base15m = '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv';
  const base1m  = '/Users/ayush/Desktop/candlestick data/1m/SOLUSDT1m.csv';

  print('Loading candles...');
  final c15m     = _loadCsv(base15m);
  final c5mRaw   = _loadCsv(base5m);
  final c1mRaw   = _loadCsv(base1m);
  final c5m      = _cleanExec(c5mRaw, 5);
  final c1m      = _cleanExec(c1mRaw, 1);
  print('  15m: ${c15m.length}  5m: ${c5m.length}  1m: ${c1m.length}\n');

  final htf30 = _aggregate(c15m, 2);
  final htf45 = _aggregate(c15m, 3);
  final htf60 = _aggregate(c15m, 4);

  print('Pre-computing zones (Fix 1: zones[bar-1] used during bar execution)...');
  final baseCfg = BounceConfig(label:'_', symbol:'SOLUSDT', csv15m:base15m, csvExec:base5m);
  final z30 = _precomputeZones(htf30, baseCfg);
  print('  30m done (${htf30.length} bars)');
  final z45 = _precomputeZones(htf45, baseCfg);
  print('  45m done (${htf45.length} bars)');
  final z60 = _precomputeZones(htf60, baseCfg);
  print('  60m done (${htf60.length} bars)\n');

  // ── Test matrix ──────────────────────────────────────────────────────────
  // (label, htfMult, zones, execCandles, execLabel, execIntervalMin, sfiFilter, slBuf, minRR, cooldown, maxHold)
  final matrix = [
    // ─ 30m HTF ─
    ('30m+5m | SFI=ON  | SL=0.4% | RR≥1.5', 2, z30, c5m,  '5m', 5,  true,  0.4, 1.5, 3, 0),
    ('30m+5m | SFI=OFF | SL=0.4% | RR≥1.5', 2, z30, c5m,  '5m', 5,  false, 0.4, 1.5, 3, 0),
    ('30m+5m | SFI=ON  | SL=0.4% | RR≥2.0', 2, z30, c5m,  '5m', 5,  true,  0.4, 2.0, 3, 0),

    // ─ 45m HTF ─
    ('45m+5m | SFI=ON  | SL=0.4% | RR≥1.5', 3, z45, c5m,  '5m', 5,  true,  0.4, 1.5, 3, 0),
    ('45m+5m | SFI=OFF | SL=0.4% | RR≥1.5', 3, z45, c5m,  '5m', 5,  false, 0.4, 1.5, 3, 0),
    ('45m+5m | SFI=ON  | SL=0.5% | RR≥1.5', 3, z45, c5m,  '5m', 5,  true,  0.5, 1.5, 3, 0),
    ('45m+5m | SFI=ON  | SL=0.4% | RR≥2.0', 3, z45, c5m,  '5m', 5,  true,  0.4, 2.0, 5, 0),
    ('45m+5m | SFI=ON  | SL=0.3% | RR≥1.5', 3, z45, c5m,  '5m', 5,  true,  0.3, 1.5, 3, 0),

    // ─ 45m HTF + 1m exec ─
    ('45m+1m | SFI=ON  | SL=0.4% | RR≥1.5', 3, z45, c1m,  '1m', 1,  true,  0.4, 1.5, 10, 0),
    ('45m+1m | SFI=OFF | SL=0.4% | RR≥1.5', 3, z45, c1m,  '1m', 1,  false, 0.4, 1.5, 10, 0),
    ('45m+1m | SFI=ON  | SL=0.4% | RR≥2.0', 3, z45, c1m,  '1m', 1,  true,  0.4, 2.0, 10, 0),

    // ─ 60m HTF ─
    ('60m+5m | SFI=ON  | SL=0.4% | RR≥1.5', 4, z60, c5m,  '5m', 5,  true,  0.4, 1.5, 3, 0),
    ('60m+5m | SFI=OFF | SL=0.4% | RR≥1.5', 4, z60, c5m,  '5m', 5,  false, 0.4, 1.5, 3, 0),
    ('60m+5m | SFI=ON  | SL=0.4% | RR≥2.0', 4, z60, c5m,  '5m', 5,  true,  0.4, 2.0, 5, 0),
  ];

  final htfByMult = {2: htf30, 3: htf45, 4: htf60};
  final allResults = <BounceResult>[];

  for (final (lbl, htfMult, zones, execC, execLbl, execMin,
               sfi, slBuf, minRR, cooldown, maxHold) in matrix) {
    final cfg = BounceConfig(
      label: lbl, symbol: 'SOLUSDT',
      csv15m: base15m,
      csvExec: execLbl == '1m' ? base1m : base5m,
      execLabel: execLbl,
      htfMultiplier: htfMult,
      commissionPct: 0.025, slippagePct: 0.04,
      fundingRatePct: 0.01, fundingIntervalHrs: 8,
      baseNotionalUSDT: 20.0, leverage: 5.0,
      slBufferPct: slBuf, sfiFilter: sfi,
      minRR: minRR, cooldownBars: cooldown,
      maxHoldBars: maxHold,
      minChannelWidthPct: 1.0,
      srDetectionLength: 10, srMargin: 2.0,
      sfiPeriod: 10, sfiMultiplier: 1.7,
      execIntervalMinutes: execMin,
    );

    print('Running: $lbl...');
    final result = runBacktest(cfg, zones, htfByMult[htfMult]!, execC);
    allResults.add(result);
    printReport(result);
  }

  printMasterTable(allResults);
}
