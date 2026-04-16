// ============================================================================
// GRID / MARTINGALE SR ZONE BACKTEST — VERSION 5
// ============================================================================
// REALISM FIXES vs v4 (every fix = lower reported returns, closer to live):
//
//  FIX 1 — Zone off-by-one (was FORWARD BIAS):
//      v4: zones[bar]  — included current HTF bar's own close/high/low
//      v5: zones[bar-1] — only uses CLOSED previous bars (what you'd know live)
//
//  FIX 2 — Deferred entry after candle-close confirmation (was FORWARD BIAS):
//      v4: entry price = grid level at close-confirm candle (knew close already)
//      v5: signal on bar c → fill at NEXT bar's OPEN price (real execution)
//
//  FIX 3 — TP/SL same-bar ambiguity (was OPTIMISTIC):
//      v4: TP checked first — if both hit in same bar, TP always wins
//      v5: conservative — if both hit in same bar, SL wins (unknown fill order)
//
//  FIX 4 — Funding rate cost (was MISSING):
//      v5: 0.01% of notional×leverage every 8h per open position
//          (real perpetual futures cost on Binance/Asterdex)
//
//  FIX 5 — Blended commission rate (was OPTIMISTIC):
//      v4: 0.02% maker flat (assumes all limits fill as maker)
//      v5: 0.025% blended (75% maker × 0.02% + 25% taker × 0.05%)
//          Real: not all limit orders fill at maker rate on fast moves
//
//  FIX 6 — Volume SMA uses PREVIOUS bars only (was MINOR BIAS):
//      v4: volSma computed AFTER adding current bar → slight look-ahead
//      v5: volSma computed from previous 20 bars BEFORE adding current bar
//
//  FIX 7 — Data gap / zero-volume candle skip (was MISSING):
//      v5: skip exec candles where volume == 0 (bad data)
//          skip exec candles with time gap > 3× expected interval (exchange downtime)
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class RunConfig {
  final String label;
  final String symbol;
  final String csv15m;
  final String csvExec;
  final String execLabel;
  final int    htfMultiplier;      // 2=30m, 3=45m, 4=60m, 6=90m

  // Grid
  final int    gridLevels;
  final double baseNotionalUSDT;
  final double leverage;
  final bool   martingale;
  final double martingaleMultiplier;
  final int    maxOpenLevels;

  // Risk / cost
  final double commissionPct;      // FIX 5: blended maker/taker (default 0.025%)
  final double slippagePct;        // market impact per side (default 0.04%)
  final double fundingRatePct;     // FIX 4: per 8h funding cost (default 0.01%)
  final int    fundingIntervalHrs; // FIX 4: funding interval (default 8)
  final double slBufferPct;
  final int    tpLevelsAway;
  final double minGridStepPct;
  final bool   requireClosedCandle;
  final double circuitBreakerPct;
  final double volSmaMultiplier;
  final int    execIntervalMinutes; // FIX 7: for gap detection

  // SR + SFI
  final int    srDetectionLength;
  final double srMargin;
  final int    sfiPeriod;
  final double sfiMultiplier;
  final double minChannelWidthPct;

  const RunConfig({
    required this.label,
    required this.symbol,
    required this.csv15m,
    required this.csvExec,
    this.execLabel            = '5m',
    this.htfMultiplier        = 3,
    this.gridLevels           = 5,
    this.baseNotionalUSDT     = 20.0,
    this.leverage             = 5.0,
    this.martingale           = true,
    this.martingaleMultiplier = 1.5,
    this.maxOpenLevels        = 3,
    this.commissionPct        = 0.025,   // FIX 5: blended rate
    this.slippagePct          = 0.04,    // FIX 5: slightly higher than v4
    this.fundingRatePct       = 0.01,    // FIX 4: 0.01% per 8h
    this.fundingIntervalHrs   = 8,       // FIX 4
    this.slBufferPct          = 0.3,
    this.tpLevelsAway         = 2,
    this.minGridStepPct       = 0.5,
    this.requireClosedCandle  = true,
    this.circuitBreakerPct    = 3.0,
    this.volSmaMultiplier     = 0.8,
    this.execIntervalMinutes  = 5,       // FIX 7: gap detection
    this.srDetectionLength    = 10,
    this.srMargin             = 2.0,
    this.sfiPeriod            = 10,
    this.sfiMultiplier        = 1.7,
    this.minChannelWidthPct   = 0.8,
  });

  String get htfLabel {
    final mins = 15 * htfMultiplier;
    return mins < 60 ? '${mins}m' : '${mins ~/ 60}h';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class RunResult {
  final RunConfig config;
  final int    totalTrades;
  final int    wins, losses;
  final int    tpExits, slExits, sameBarSl, breakExits;
  final double grossPnl;
  final double totalFees;
  final double totalSlippage;
  final double totalFunding;    // FIX 4
  final double netPnl;
  final double maxDdPct;
  final double returnPct;
  final double calmar;
  final double pf;
  final String grade;

  RunResult({
    required this.config,
    required this.totalTrades,
    required this.wins, required this.losses,
    required this.tpExits, required this.slExits,
    required this.sameBarSl, required this.breakExits,
    required this.grossPnl, required this.totalFees,
    required this.totalSlippage, required this.totalFunding,
    required this.netPnl, required this.maxDdPct,
    required this.returnPct, required this.calmar,
    required this.pf, required this.grade,
  });

  double get winRate => totalTrades == 0 ? 0 : wins / totalTrades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZONE STATE (pre-computed per HTF bar)
// ─────────────────────────────────────────────────────────────────────────────

class _BarZones {
  final List<SRZone> activeR;
  final List<SRZone> activeS;
  final int sfiTrend;
  _BarZones(this.activeR, this.activeS, this.sfiTrend);
}

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

enum GridDir { long, short }

class _Trade {
  final int      id;
  final GridDir  dir;
  final double   entryPrice;   // FIX 2: next bar's open (not grid level)
  final double   qty;
  final double   notionalUSDT;
  final double   tpPrice, slPrice;
  final int      levelIdx;
  final DateTime entryTime;
  double         fundingPaid = 0.0;  // FIX 4: accumulated funding cost

  bool      isOpen     = true;
  double    exitPrice  = 0;
  DateTime? exitTime;
  String    exitReason = '';

  _Trade({
    required this.id, required this.dir, required this.entryPrice,
    required this.qty, required this.notionalUSDT,
    required this.tpPrice, required this.slPrice,
    required this.levelIdx, required this.entryTime,
  });

  double grossPnl(RunConfig cfg) {
    if (exitPrice == 0) return 0;
    final raw = dir == GridDir.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
    return raw * cfg.leverage;
  }

  double fees(RunConfig cfg) =>
      notionalUSDT * cfg.leverage * cfg.commissionPct / 100 * 2;

  double slippage(RunConfig cfg) =>
      notionalUSDT * cfg.leverage * cfg.slippagePct / 100 * 2;

  double netPnl(RunConfig cfg) =>
      grossPnl(cfg) - fees(cfg) - slippage(cfg) - fundingPaid;
}

// FIX 2: Deferred entry — pending signal waiting for next bar's open
class _PendingEntry {
  final int      levelIdx;
  final double   notional;
  final double   tpPrice, slPrice;
  final GridDir  dir;
  final DateTime signalTime;
  _PendingEntry({
    required this.levelIdx, required this.notional,
    required this.tpPrice, required this.slPrice,
    required this.dir, required this.signalTime,
  });
}

class _GridState {
  final double      chanTop, chanBot;
  final List<double> levels;
  final GridDir     dir;
  final Set<int>    openLevels     = {};
  final Set<int>    pendingLevels  = {};  // FIX 2: reserved by signal, not yet filled
  bool              isActive       = true;

  _GridState({required this.chanTop, required this.chanBot,
    required this.levels, required this.dir});

  double get width => chanTop - chanBot;
  double get mid   => (chanTop + chanBot) / 2;

  int get allActiveCount => openLevels.length + pendingLevels.length;
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
      final c    = cs[i];
      final a    = i < atr.length ? atr[i] : (atr.isNotEmpty ? atr.last : 0.0);
      final rawUp = c.ohlc4 - mult * a;
      final rawDn = c.ohlc4 + mult * a;
      final up = i > 0
          ? (cs[i-1].close > pUp ? max(rawUp, pUp) : rawUp)
          : rawUp;
      final dn = i > 0
          ? (cs[i-1].close < pDn ? min(rawDn, pDn) : rawDn)
          : rawDn;
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

// FIX 7: Filter exec candles — remove zero-volume and gap candles
List<Candle> _cleanExecCandles(List<Candle> raw, int expectedIntervalMin) {
  final out = <Candle>[];
  for (int i = 0; i < raw.length; i++) {
    // Skip zero-volume candles (bad data / exchange downtime)
    if (raw[i].volume <= 0) continue;
    // Skip candles with gap > 3× expected interval
    if (i > 0 && out.isNotEmpty) {
      final gap = raw[i].time.difference(out.last.time).inMinutes;
      if (gap > expectedIntervalMin * 3) continue; // discard candle after big gap
    }
    out.add(raw[i]);
  }
  return out;
}

// FIX 1: Pre-compute zones — result at index i = zones computed from bars [0..i]
// When trading during HTF bar i, we use zones[i-1] (previous closed bar)
List<_BarZones> _precomputeZones(List<Candle> htf, RunConfig cfg) {
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

RunResult runBacktest(RunConfig cfg, List<_BarZones> barZones,
    List<Candle> htfCandles, List<Candle> execCandlesRaw) {

  // FIX 7: Clean exec candles first
  final execCandles = _cleanExecCandles(execCandlesRaw, cfg.execIntervalMinutes);

  final trades       = <_Trade>[];
  final pending      = <_PendingEntry>[];  // FIX 2
  int   tradeId      = 0;
  double netEq       = 0.0, grossEq = 0.0;
  double totalFee    = 0.0, totalSlip = 0.0, totalFunding = 0.0;
  double peakEq      = 0.0, maxDd = 0.0;
  int    sameBarSlCount = 0;
  _GridState? grid;

  final deployedCap = cfg.baseNotionalUSDT * cfg.leverage * cfg.maxOpenLevels;

  // FIX 4: Funding tracking
  DateTime lastFunding = DateTime(2000);

  // FIX 6: Volume SMA ring buffer — filled with PREVIOUS bars before checking
  final volBuf    = <double>[];
  const volPeriod = 20;

  for (int bar = 0; bar < htfCandles.length; bar++) {
    // FIX 1: Use zones from previous closed bar (not current bar's zones)
    final bz = barZones[bar > 0 ? bar - 1 : 0];

    if (bz.activeR.isEmpty || bz.activeS.isEmpty) {
      if (grid != null) { grid.isActive = false; pending.clear(); }
      continue;
    }

    final chanTop  = bz.activeR.first.boxBottom;
    final chanBot  = bz.activeS.first.boxTop;
    if (chanTop <= chanBot) {
      if (grid != null) { grid.isActive = false; pending.clear(); }
      continue;
    }

    final widthPct = (chanTop - chanBot) / chanBot * 100;
    if (widthPct < cfg.minChannelWidthPct) {
      if (grid != null) { grid.isActive = false; pending.clear(); }
      continue;
    }

    final dir    = bz.sfiTrend >= 0 ? GridDir.long : GridDir.short;
    final levels = List.generate(cfg.gridLevels + 1,
        (k) => chanBot + (chanTop - chanBot) * k / cfg.gridLevels);

    final needNew = grid == null || !grid.isActive || grid.dir != dir ||
        (grid.chanTop - chanTop).abs() / chanTop > 0.005 ||
        (grid.chanBot - chanBot).abs() / chanBot > 0.005;

    if (needNew) {
      pending.clear(); // FIX 2: cancel all pending entries on grid reset
      final lastP = execCandles.lastWhere(
          (c) => !c.time.isAfter(htfCandles[bar].time),
          orElse: () => execCandles.first).close;
      for (final t in trades.where((t) => t.isOpen)) {
        t.isOpen = false; t.exitPrice = lastP;
        t.exitTime = htfCandles[bar].time; t.exitReason = 'GRID_RESET';
        final gp = t.grossPnl(cfg); final fee = t.fees(cfg);
        final slip = t.slippage(cfg);
        grossEq += gp; totalFee += fee; totalSlip += slip;
        totalFunding += t.fundingPaid;
        netEq += gp - fee - slip - t.fundingPaid;
      }
      grid = _GridState(chanTop: chanTop, chanBot: chanBot,
          levels: levels, dir: dir);
    }

    final winStart = htfCandles[bar].time;
    final winEnd   = bar + 1 < htfCandles.length
        ? htfCandles[bar + 1].time
        : winStart.add(Duration(minutes: 15 * cfg.htfMultiplier));

    final execBars = execCandles
        .where((c) => !c.time.isBefore(winStart) && c.time.isBefore(winEnd))
        .toList();

    for (int ei = 0; ei < execBars.length; ei++) {
      final c = execBars[ei];
      if (!grid.isActive) break;

      // ── FIX 2: Fill pending entries at this bar's OPEN price ─────────────
      final toFill = List<_PendingEntry>.from(pending);
      pending.clear();
      for (final pe in toFill) {
        if (!grid.isActive) { grid.pendingLevels.remove(pe.levelIdx); continue; }
        if (!grid.pendingLevels.contains(pe.levelIdx)) continue; // grid reset cancelled it
        final fillPrice = c.open; // real execution: enter at next bar's open
        final actualQty = pe.notional / fillPrice;
        trades.add(_Trade(
          id: tradeId++, dir: pe.dir, entryPrice: fillPrice,
          qty: actualQty, notionalUSDT: pe.notional,
          tpPrice: pe.tpPrice, slPrice: pe.slPrice,
          levelIdx: pe.levelIdx, entryTime: c.time,
        ));
        grid.pendingLevels.remove(pe.levelIdx);
        grid.openLevels.add(pe.levelIdx);
      }

      // ── Channel break check ───────────────────────────────────────────────
      final broken = dir == GridDir.long
          ? c.close < chanBot * (1 - cfg.slBufferPct / 100)
          : c.close > chanTop * (1 + cfg.slBufferPct / 100);

      if (broken) {
        pending.clear(); // cancel pending entries
        for (final t in trades.where((t) => t.isOpen)) {
          t.isOpen = false; t.exitPrice = t.slPrice;
          t.exitTime = c.time; t.exitReason = 'CHANNEL_BREAK';
          final gp = t.grossPnl(cfg); final fee = t.fees(cfg);
          final slip = t.slippage(cfg);
          grossEq += gp; totalFee += fee; totalSlip += slip;
          totalFunding += t.fundingPaid;
          netEq += gp - fee - slip - t.fundingPaid;
          grid.openLevels.remove(t.levelIdx);
        }
        grid.isActive = false;
        continue;
      }

      // ── FIX 4: Funding rate every 8h ─────────────────────────────────────
      if (c.time.difference(lastFunding).inHours >= cfg.fundingIntervalHrs) {
        lastFunding = c.time;
        for (final t in trades.where((t) => t.isOpen)) {
          final fundingCost =
              t.notionalUSDT * cfg.leverage * cfg.fundingRatePct / 100;
          t.fundingPaid += fundingCost;
        }
      }

      // ── FIX 3 + TP/SL management ─────────────────────────────────────────
      for (final t in trades.where((t) => t.isOpen)) {
        bool tpHit = false, slHit = false;
        if (t.dir == GridDir.long) {
          tpHit = c.high >= t.tpPrice;
          slHit = c.low  <= t.slPrice;
        } else {
          tpHit = c.low  <= t.tpPrice;
          slHit = c.high >= t.slPrice;
        }

        String reason = ''; double at = 0; bool closed = false;
        if (tpHit && slHit) {
          // FIX 3: Both hit in same bar — conservative: SL wins
          reason = 'SL'; at = t.slPrice; closed = true; sameBarSlCount++;
        } else if (tpHit) {
          reason = 'TP'; at = t.tpPrice; closed = true;
        } else if (slHit) {
          reason = 'SL'; at = t.slPrice; closed = true;
        }

        if (closed) {
          t.isOpen = false; t.exitPrice = at;
          t.exitTime = c.time; t.exitReason = reason;
          final gp = t.grossPnl(cfg); final fee = t.fees(cfg);
          final slip = t.slippage(cfg);
          grossEq += gp; totalFee += fee; totalSlip += slip;
          totalFunding += t.fundingPaid;
          netEq += gp - fee - slip - t.fundingPaid;
          grid.openLevels.remove(t.levelIdx);
        }
      }

      // ── FIX 6: Volume SMA — compute from PREVIOUS bars before adding current
      final volSma = volBuf.length >= volPeriod
          ? volBuf.fold(0.0, (s, v) => s + v) / volBuf.length
          : 0.0;
      volBuf.add(c.volume);
      if (volBuf.length > volPeriod) volBuf.removeAt(0);

      // ── Circuit breaker ───────────────────────────────────────────────────
      final openMtm = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
        final raw = t.dir == GridDir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        return s + raw * cfg.leverage - t.fees(cfg) - t.slippage(cfg)
            - t.fundingPaid;
      });
      final circuitTripped = cfg.circuitBreakerPct > 0 &&
          (netEq + openMtm) < -(deployedCap * cfg.circuitBreakerPct / 100);

      // ── New entry signals ─────────────────────────────────────────────────
      final volOk = cfg.volSmaMultiplier <= 0 ||
          volBuf.length < volPeriod ||
          c.volume >= volSma * cfg.volSmaMultiplier;

      if (!circuitTripped && volOk &&
          grid.allActiveCount < cfg.maxOpenLevels) {
        for (int lvl = 0; lvl < levels.length - 1; lvl++) {
          if (grid.openLevels.contains(lvl)) continue;
          if (grid.pendingLevels.contains(lvl)) continue; // already signalled
          final lp = levels[lvl];
          bool triggered = false;

          if (dir == GridDir.long) {
            if (lp > grid.mid) continue;
            triggered = cfg.requireClosedCandle
                ? c.low <= lp && c.close > lp   // wick down, closed above = zone held
                : c.low <= lp;
          } else {
            if (lp < grid.mid) continue;
            triggered = cfg.requireClosedCandle
                ? c.high >= lp && c.close < lp   // wick up, closed below = zone held
                : c.high >= lp;
          }
          if (!triggered) continue;
          if (grid.allActiveCount >= cfg.maxOpenLevels) break;

          final gridStep = grid.width / cfg.gridLevels;
          if (gridStep / lp * 100 < cfg.minGridStepPct) continue;

          final steps = (dir == GridDir.long
              ? grid.mid - lp : lp - grid.mid) / (grid.width / cfg.gridLevels);
          final mult = cfg.martingale
              ? pow(cfg.martingaleMultiplier,
                    steps.clamp(0, cfg.gridLevels - 1)).toDouble()
              : 1.0;
          final notional = cfg.baseNotionalUSDT * mult;

          final isMartingaleEntry = steps >= 1;
          final tpDist = cfg.tpLevelsAway + (isMartingaleEntry ? 1 : 0);
          final tpIdx  = dir == GridDir.long ? lvl + tpDist : lvl - tpDist;
          final tp     = levels[tpIdx.clamp(0, levels.length - 1)];
          final sl     = dir == GridDir.long
              ? chanBot * (1 - cfg.slBufferPct / 100)
              : chanTop * (1 + cfg.slBufferPct / 100);

          // FIX 2: Reserve slot and add to pending — fill at NEXT bar's open
          grid.pendingLevels.add(lvl);
          pending.add(_PendingEntry(
            levelIdx: lvl, notional: notional,
            tpPrice: tp, slPrice: sl,
            dir: dir, signalTime: c.time,
          ));
        }
      }

      // ── Track drawdown ────────────────────────────────────────────────────
      final openPnl = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
        final raw = t.dir == GridDir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        return s + raw * cfg.leverage - t.fees(cfg) - t.slippage(cfg)
            - t.fundingPaid;
      });
      final cur = netEq + openPnl;
      if (cur > peakEq) peakEq = cur;
      final dd = peakEq - cur;
      if (dd > maxDd) maxDd = dd;
    }
  }

  // Force-close remaining open positions at final price
  final lastP = execCandles.last.close;
  for (final t in trades.where((t) => t.isOpen)) {
    t.isOpen = false; t.exitPrice = lastP;
    t.exitTime = execCandles.last.time; t.exitReason = 'END_OF_DATA';
    final gp = t.grossPnl(cfg); final fee = t.fees(cfg);
    final slip = t.slippage(cfg);
    grossEq += gp; totalFee += fee; totalSlip += slip;
    totalFunding += t.fundingPaid;
    netEq += gp - fee - slip - t.fundingPaid;
  }

  final closed  = trades.where((t) => t.exitReason.isNotEmpty).toList();
  final wins    = closed.where((t) => t.grossPnl(cfg) > 0).length;
  final losses  = closed.length - wins;
  final tpEx    = closed.where((t) => t.exitReason == 'TP').length;
  final slEx    = closed.where((t) => t.exitReason == 'SL').length;
  final brkEx   = closed.where((t) => t.exitReason == 'CHANNEL_BREAK').length;

  final avgWinG  = wins > 0
      ? closed.where((t) => t.grossPnl(cfg) > 0)
          .fold(0.0, (s, t) => s + t.grossPnl(cfg)) / wins
      : 0.0;
  final avgLossG = losses > 0
      ? closed.where((t) => t.grossPnl(cfg) <= 0)
          .fold(0.0, (s, t) => s + t.grossPnl(cfg)).abs() / losses
      : 0.0;
  final pf = avgLossG > 0 ? (avgWinG * wins) / (avgLossG * losses) : double.infinity;

  final returnPct = deployedCap > 0 ? netEq / deployedCap * 100 : 0.0;
  final ddPct     = deployedCap > 0 ? maxDd / deployedCap * 100 : 0.0;
  final calmar    = ddPct.abs() > 0 ? returnPct / ddPct.abs() : 0.0;

  String grade;
  if      (calmar >= 5 && returnPct >= 50 && ddPct.abs() < 20) grade = 'A ★★★';
  else if (calmar >= 3 && returnPct >= 30 && ddPct.abs() < 30) grade = 'B ★★';
  else if (calmar >= 1 && returnPct >= 15 && ddPct.abs() < 40) grade = 'C ★';
  else if (returnPct > 0)                                       grade = 'D';
  else                                                          grade = 'F ✗';

  return RunResult(
    config: cfg, totalTrades: closed.length,
    wins: wins, losses: losses,
    tpExits: tpEx, slExits: slEx,
    sameBarSl: sameBarSlCount, breakExits: brkEx,
    grossPnl: grossEq, totalFees: totalFee,
    totalSlippage: totalSlip, totalFunding: totalFunding,
    netPnl: netEq,
    maxDdPct: ddPct.abs(), returnPct: returnPct,
    calmar: calmar, pf: pf, grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// REPORT PRINTER
// ─────────────────────────────────────────────────────────────────────────────

void printDetailedReport(RunResult r) {
  final cfg = r.config;
  final sep = '═' * 72;
  print('\n╔$sep╗');
  print('║  ${r.config.label.padRight(70)}║');
  print('╠$sep╣');
  print('║  HTF: ${cfg.htfLabel}  |  Exec: ${cfg.execLabel}  |  GL=${cfg.gridLevels}'
      '  |  ML=${cfg.martingale ? cfg.martingaleMultiplier : 1.0}'
      '  |  MaxLvl=${cfg.maxOpenLevels}  |  TP=${cfg.tpLevelsAway}lvl'
      '  |  MinStep=${cfg.minGridStepPct}%${' ' * 3}║');
  print('╠$sep╣');

  print('║  REALISTIC COST BREAKDOWN${' ' * 46}║');
  print('║  Gross PnL  : ${_f(r.grossPnl, 12)}  (before all costs)${' ' * 27}║');
  print('║  Fees paid  : ${_f(-r.totalFees, 12)}  blended commission @ ${cfg.commissionPct}% × 2 sides${' ' * 9}║');
  print('║  Slippage   : ${_f(-r.totalSlippage, 12)}  market impact @ ${cfg.slippagePct}% × 2 sides${' ' * 14}║');
  print('║  Funding    : ${_f(-r.totalFunding, 12)}  ${cfg.fundingRatePct}% per ${cfg.fundingIntervalHrs}h per open position${' ' * 18}║');
  print('║  ─────────────────────────────────────────────────────────────────${' ' * 3}║');
  print('║  NET PnL    : ${_f(r.netPnl, 12)}  ← what you actually keep${' ' * 23}║');
  print('╠$sep╣');

  print('║  PERFORMANCE${' ' * 59}║');
  print('║  Trades: ${r.totalTrades.toString().padRight(6)}  '
      'Wins: ${r.wins.toString().padRight(6)}  '
      'Losses: ${r.losses.toString().padRight(6)}  '
      'WR: ${r.winRate.toStringAsFixed(1)}%${' ' * 14}║');
  print('║  TP: ${r.tpExits.toString().padRight(6)}  '
      'SL: ${r.slExits.toString().padRight(6)}  '
      'SameBar→SL: ${r.sameBarSl.toString().padRight(6)}  '
      'BreakExit: ${r.breakExits}${' ' * 10}║');
  print('║  PF: ${r.pf.isInfinite ? '∞   ' : r.pf.toStringAsFixed(2).padRight(8)}  '
      'Return: ${r.returnPct.toStringAsFixed(2).padRight(8)}%  '
      'MaxDD: ${r.maxDdPct.toStringAsFixed(2)}%${' ' * 14}║');
  print('║  Calmar: ${r.calmar.toStringAsFixed(2).padRight(62)}║');
  print('║  GRADE: ${r.grade.padRight(63)}║');
  print('╚$sep╝');
}

void printMasterTable(List<RunResult> results) {
  final sorted = [...results]..sort((a, b) => b.calmar.compareTo(a.calmar));

  print('\n');
  print('╔═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗');
  print('║                              MASTER RANKING — ALL RUNS (v5 — REALISTIC)                                         ║');
  print('╠════╦══════════════════════════════════════╦══════╦════════╦════════╦════════╦════════╦════════╦════════════════╣');
  print('║ #  ║ Config                               ║  WR% ║  Gross ║  Costs ║   Net  ║  DD%   ║ Return ║  Calmar  Grade ║');
  print('╠════╬══════════════════════════════════════╬══════╬════════╬════════╬════════╬════════╬════════╬════════════════╣');

  for (int i = 0; i < sorted.length; i++) {
    final r   = sorted[i];
    final lbl = r.config.label.length > 37
        ? r.config.label.substring(0, 37)
        : r.config.label.padRight(37);
    final rank  = (i + 1).toString().padLeft(3);
    final wr    = r.winRate.toStringAsFixed(1).padLeft(5);
    final g     = _f2(r.grossPnl).padLeft(7);
    final costs = _f2(-(r.totalFees + r.totalSlippage + r.totalFunding)).padLeft(7);
    final net   = _f2(r.netPnl).padLeft(7);
    final dd    = r.maxDdPct.toStringAsFixed(1).padLeft(6);
    final ret   = r.returnPct.toStringAsFixed(1).padLeft(7);
    final cal   = r.calmar.toStringAsFixed(1).padLeft(7);
    final grade = r.grade.padRight(6);
    print('║$rank ║ $lbl║$wr%║$g ║$costs ║$net ║$dd% ║$ret% ║$cal  $grade║');
  }

  print('╚════╩══════════════════════════════════════╩══════╩════════╩════════╩════════╩════════╩════════╩════════════════╝');

  final best = sorted.first;
  print('\n  BEST CONFIG: ${best.config.label}');
  print('  Net PnL: ${_f(best.netPnl, 10)}  Return: ${best.returnPct.toStringAsFixed(2)}%'
      '  Calmar: ${best.calmar.toStringAsFixed(2)}  Grade: ${best.grade}');

  // Compare v4 vs v5 impact summary
  print('\n  ── V4→V5 REALISM ADJUSTMENT SUMMARY ──────────────────────────────────────────');
  print('  Zone delay (Fix 1)  : uses previous closed HTF bar zones only');
  print('  Entry delay (Fix 2) : entries fill at next bar open (not at touch level)');
  print('  SL-first (Fix 3)    : TP/SL same-bar → SL wins (${sorted.fold(0, (s, r) => s + r.sameBarSl)} instances forced to SL)');
  print('  Funding (Fix 4)     : ${best.config.fundingRatePct}% per ${best.config.fundingIntervalHrs}h per open position');
  print('  Blended fee (Fix 5) : ${best.config.commissionPct}% (was 0.02% maker-only in v4)');
  print('  Vol SMA (Fix 6)     : previous bars only (no current-bar look-ahead)');
  print('  Gap filter (Fix 7)  : zero-volume + time-gap candles removed from execution');
  print('  ────────────────────────────────────────────────────────────────────────────────');
}

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _f(double v, int w) =>
    ((v >= 0 ? '+' : '') + v.toStringAsFixed(2)).padRight(w);
String _f2(double v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(0);

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  const base5m  = '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv';
  const base15m = '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv';
  const base1m  = '/Users/ayush/Desktop/candlestick data/1m/SOLUSDT1m.csv';

  print('Loading data...');
  final c15m = _loadCsv(base15m);
  final c5m  = _loadCsv(base5m);
  final c1m  = _loadCsv(base1m);
  print('  Raw — 15m: ${c15m.length}  5m: ${c5m.length}  1m: ${c1m.length}');

  // FIX 7: Clean exec data
  final c5mClean = _cleanExecCandles(c5m, 5);
  final c1mClean = _cleanExecCandles(c1m, 1);
  print('  Cleaned — 5m: ${c5mClean.length} (removed ${c5m.length - c5mClean.length})'
      '  1m: ${c1mClean.length} (removed ${c1m.length - c1mClean.length})\n');

  final htf30m = _aggregate(c15m, 2);
  final htf45m = _aggregate(c15m, 3);
  final htf60m = _aggregate(c15m, 4);
  final htf90m = _aggregate(c15m, 6);

  print('Pre-computing SR + SFI zones (FIX 1: zones[i] = info from closed bars 0..i)...');
  final baseConfig = RunConfig(label: '_', symbol: 'SOLUSDT', csv15m: base15m, csvExec: base5m);
  final zones30 = _precomputeZones(htf30m, baseConfig);
  print('  30m zones done (${htf30m.length} bars)');
  final zones45 = _precomputeZones(htf45m, baseConfig);
  print('  45m zones done (${htf45m.length} bars)');
  final zones60 = _precomputeZones(htf60m, baseConfig);
  print('  60m zones done (${htf60m.length} bars)');
  final zones90 = _precomputeZones(htf90m, baseConfig);
  print('  90m zones done (${htf90m.length} bars)\n');

  final zonesByMult = {2: zones30, 3: zones45, 4: zones60, 6: zones90};
  final htfByMult   = {2: htf30m,  3: htf45m,  4: htf60m,  6: htf90m};

  // Same test matrix as v4
  final testMatrix = [
    // ── 30m HTF ──
    ('30m+5m | GL=5 | ML=1.5 | TP=2', 2, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 2, 0.5),
    ('30m+5m | GL=3 | ML=2.0 | TP=2', 2, '5m', c5mClean, 5, 3, 2.0, 2, 0.3, 2, 0.5),
    ('30m+5m | GL=5 | ML=1.5 | TP=3', 2, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 3, 0.5),

    // ── 45m HTF ──
    ('45m+5m | GL=5 | ML=1.5 | TP=2', 3, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 2, 0.5),
    ('45m+5m | GL=3 | ML=2.0 | TP=2', 3, '5m', c5mClean, 5, 3, 2.0, 2, 0.3, 2, 0.5),
    ('45m+5m | GL=5 | ML=1.5 | TP=3', 3, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 3, 0.5),
    ('45m+5m | GL=5 | ML=1.0 | TP=2', 3, '5m', c5mClean, 5, 5, 1.0, 3, 0.3, 2, 0.5),
    ('45m+5m | GL=3 | ML=2.0 | TP=3', 3, '5m', c5mClean, 5, 3, 2.0, 2, 0.3, 3, 0.5),
    ('45m+1m | GL=5 | ML=1.5 | TP=2', 3, '1m', c1mClean, 1, 5, 1.5, 3, 0.3, 2, 0.5),

    // ── 60m HTF ──
    ('60m+5m | GL=5 | ML=1.5 | TP=2', 4, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 2, 0.5),
    ('60m+5m | GL=3 | ML=2.0 | TP=2', 4, '5m', c5mClean, 5, 3, 2.0, 2, 0.3, 2, 0.5),
    ('60m+5m | GL=5 | ML=1.5 | TP=3', 4, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 3, 0.5),

    // ── 90m HTF ──
    ('90m+5m | GL=5 | ML=1.5 | TP=2', 6, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 2, 0.5),
    ('90m+5m | GL=3 | ML=2.0 | TP=2', 6, '5m', c5mClean, 5, 3, 2.0, 2, 0.3, 2, 0.5),
    ('90m+5m | GL=5 | ML=1.5 | TP=3', 6, '5m', c5mClean, 5, 5, 1.5, 3, 0.3, 3, 0.5),
  ];

  final allResults = <RunResult>[];

  for (final (lbl, htfMult, execLbl, execC, execIntervalMins,
                gl, ml, maxLvl, slBuf, tpAway, minStep) in testMatrix) {
    final cfg = RunConfig(
      label: lbl, symbol: 'SOLUSDT',
      csv15m: base15m,
      csvExec: execLbl == '1m' ? base1m : base5m,
      execLabel: execLbl,
      htfMultiplier: htfMult,
      gridLevels: gl,
      baseNotionalUSDT: 20.0, leverage: 5.0,
      martingale: ml > 1.0, martingaleMultiplier: ml,
      maxOpenLevels: maxLvl,
      commissionPct:  0.025,  // FIX 5: blended rate
      slippagePct:    0.04,   // FIX 5: slightly higher
      fundingRatePct: 0.01,   // FIX 4: 0.01% per 8h
      fundingIntervalHrs: 8,
      slBufferPct: slBuf,
      tpLevelsAway: tpAway,
      minGridStepPct: minStep,
      execIntervalMinutes: execIntervalMins,
      srDetectionLength: 10, srMargin: 2.0,
      sfiPeriod: 10, sfiMultiplier: 1.7,
      minChannelWidthPct: 0.8,
    );

    print('Running: $lbl...');
    final result = runBacktest(cfg, zonesByMult[htfMult]!, htfByMult[htfMult]!, execC);
    allResults.add(result);
    printDetailedReport(result);
  }

  printMasterTable(allResults);
}
