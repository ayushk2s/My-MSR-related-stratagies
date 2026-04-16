// ============================================================================
// GRID / MARTINGALE SR ZONE BACKTEST — VERSION 4
// ============================================================================
// NEW in v4 (improvements from v3 analysis):
//  • Entry confirmation: candle must CLOSE at/below grid level (not just touch)
//  • Circuit breaker: stop new entries if open+realized loss > circuitBreakerPct%
//  • Volume filter: skip entry when exec-bar volume < volSmaMultiplier × 20-bar avg
//  • Scaled TP: first entry at tpLevelsAway, martingale entries get tpLevelsAway+1
//  • Fixed grade formula: rewards Calmar ratio — Calmar≥5 + Return≥50% = A ★★★
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class RunConfig {
  final String label;           // display name e.g. "45m+5m | GL=5 | ML=1.5"
  final String symbol;
  final String csv15m;
  final String csvExec;         // execution candles (1m or 5m)
  final String execLabel;       // '1m' or '5m'
  final int htfMultiplier;      // bars of 15m to aggregate: 2=30m, 3=45m, 4=60m, 6=90m

  // Grid
  final int gridLevels;
  final double baseNotionalUSDT;
  final double leverage;
  final bool martingale;
  final double martingaleMultiplier;
  final int maxOpenLevels;

  // Risk / cost
  final double commissionPct;   // 0.02% maker (limit orders on Asterdex)
  final double slippagePct;     // 0.03% simulated slippage per fill
  final double slBufferPct;
  final int tpLevelsAway;           // base TP distance (martingale entries get +1)
  final double minGridStepPct;      // skip entry if grid step < this % of price
  final bool requireClosedCandle;   // v4: entry only on candle CLOSE at level
  final double circuitBreakerPct;   // v4: stop new entries if loss > this % of deployedCap
  final double volSmaMultiplier;    // v4: skip entry if volume < multiplier × 20-bar avg (0=off)

  // SR + SFI
  final int srDetectionLength;
  final double srMargin;
  final int sfiPeriod;
  final double sfiMultiplier;
  final double minChannelWidthPct;

  const RunConfig({
    required this.label,
    required this.symbol,
    required this.csv15m,
    required this.csvExec,
    this.execLabel = '5m',
    this.htfMultiplier = 3,
    this.gridLevels = 5,
    this.baseNotionalUSDT = 20.0,
    this.leverage = 5.0,
    this.martingale = true,
    this.martingaleMultiplier = 1.5,
    this.maxOpenLevels = 3,
    this.commissionPct = 0.02,
    this.slippagePct = 0.03,
    this.slBufferPct = 0.3,
    this.tpLevelsAway = 2,
    this.minGridStepPct = 0.5,
    this.requireClosedCandle = true,
    this.circuitBreakerPct = 3.0,
    this.volSmaMultiplier = 0.8,
    this.srDetectionLength = 10,
    this.srMargin = 2.0,
    this.sfiPeriod = 10,
    this.sfiMultiplier = 1.7,
    this.minChannelWidthPct = 0.8,
  });

  String get htfLabel {
    final mins = 15 * htfMultiplier;
    if (mins < 60) return '${mins}m';
    return '${mins ~/ 60}h';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class RunResult {
  final RunConfig config;
  final int totalTrades;
  final int wins, losses;
  final int tpExits, slExits, breakExits;
  final double grossPnl;       // PnL before any costs
  final double totalFees;      // commissions paid
  final double totalSlippage;  // slippage paid
  final double netPnl;         // after fees + slippage
  final double maxDdPct;
  final double returnPct;      // netPnl / deployedCapital * 100
  final double calmar;
  final double pf;
  final String grade;

  RunResult({
    required this.config,
    required this.totalTrades,
    required this.wins, required this.losses,
    required this.tpExits, required this.slExits, required this.breakExits,
    required this.grossPnl, required this.totalFees,
    required this.totalSlippage, required this.netPnl,
    required this.maxDdPct, required this.returnPct,
    required this.calmar, required this.pf, required this.grade,
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
  final int id;
  final GridDir dir;
  final double entryPrice;
  final double qty;
  final double notionalUSDT;
  final double tpPrice, slPrice;
  final int levelIdx;
  final DateTime entryTime;

  bool isOpen = true;
  double exitPrice = 0;
  DateTime? exitTime;
  String exitReason = '';

  _Trade({
    required this.id, required this.dir, required this.entryPrice,
    required this.qty, required this.notionalUSDT,
    required this.tpPrice, required this.slPrice,
    required this.levelIdx, required this.entryTime,
  });

  double rawPnl(RunConfig cfg) {
    if (exitPrice == 0) return 0;
    final slipAdj = cfg.slippagePct / 100;
    // Entry fill: slippage against us
    final effEntry = dir == GridDir.long
        ? entryPrice * (1 + slipAdj)
        : entryPrice * (1 - slipAdj);
    // Exit fill: slippage against us
    final effExit = dir == GridDir.long
        ? exitPrice * (1 - slipAdj)
        : exitPrice * (1 + slipAdj);
    return dir == GridDir.long
        ? (effExit - effEntry) * qty
        : (effEntry - effExit) * qty;
  }

  double fees(RunConfig cfg) =>
      notionalUSDT * cfg.leverage * cfg.commissionPct / 100 * 2; // entry + exit

  double slippage(RunConfig cfg) =>
      notionalUSDT * cfg.leverage * cfg.slippagePct / 100 * 2;

  double grossPnl(RunConfig cfg) {
    if (exitPrice == 0) return 0;
    final raw = dir == GridDir.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
    return raw * cfg.leverage;
  }

  double netPnl(RunConfig cfg) => grossPnl(cfg) - fees(cfg) - slippage(cfg);
}

class _GridState {
  final double chanTop, chanBot;
  final List<double> levels;
  final GridDir dir;
  final Set<int> openLevels = {};
  bool isActive = true;

  _GridState({required this.chanTop, required this.chanBot,
    required this.levels, required this.dir});

  double get width => chanTop - chanBot;
  double get mid => (chanTop + chanBot) / 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI INDICATOR
// ─────────────────────────────────────────────────────────────────────────────

class _SfiInd {
  List<double> _tr(List<Candle> cs) {
    final out = <double>[];
    for (int i = 0; i < cs.length; i++) {
      final p = i == 0 ? cs[i].close : cs[i - 1].close;
      out.add([cs[i].high - cs[i].low, (cs[i].high - p).abs(), (cs[i].low - p).abs()].reduce(max));
    }
    return out;
  }

  List<double> _atr(List<double> tr, int period) {
    final out = <double>[];
    double sum = 0;
    for (int i = 0; i < tr.length; i++) {
      if (i < period) { sum += tr[i]; out.add(sum / (i + 1)); }
      else if (i == period) { out.add(tr.sublist(0, period).reduce((a, b) => a + b) / period); }
      else { out.add((out[i - 1] * (period - 1) + tr[i]) / period); }
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
      final rawUp = c.ohlc4 - mult * a;
      final rawDn = c.ohlc4 + mult * a;
      final up = i > 0 ? (cs[i-1].close > pUp ? max(rawUp, pUp) : rawUp) : rawUp;
      final dn = i > 0 ? (cs[i-1].close < pDn ? min(rawDn, pDn) : rawDn) : rawDn;
      int t = prevT;
      if (prevT == -1 && c.close > pDn) { t = 1; }
      else if (prevT == 1 && c.close < pUp) { t = -1; }
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
    out.add(Candle(c15[i].time, c15[i].open, hi, lo, c15[i + mult - 1].close, vol, idx++));
  }
  return out;
}

// Pre-compute zone state at every HTF bar (slow but done once per HTF)
List<_BarZones> _precomputeZones(List<Candle> htf, RunConfig cfg) {
  final sr  = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true, showManip: false);
  final sfi = _SfiInd();
  final minBars = cfg.srDetectionLength * 2 + 20;
  final out = <_BarZones>[];
  for (int i = 0; i < htf.length; i++) {
    if (i < minBars) { out.add(_BarZones([], [], 1)); continue; }
    final sub    = htf.sublist(0, i + 1);
    final result = sr.calculate(sub);
    final t      = sfi.trend(sub, cfg.sfiPeriod, cfg.sfiMultiplier);
    out.add(_BarZones(
      result.resistance.where((z) => z.isActive).toList(),
      result.support.where((z) => z.isActive).toList(),
      t,
    ));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

RunResult runBacktest(RunConfig cfg, List<_BarZones> barZones,
    List<Candle> htfCandles, List<Candle> execCandles) {

  final trades    = <_Trade>[];
  int   tradeId   = 0;
  double netEq    = 0.0, grossEq = 0.0;
  double totalFee = 0.0, totalSlip = 0.0;
  double peakEq   = 0.0, maxDd = 0.0;
  _GridState? grid;

  final deployedCap = cfg.baseNotionalUSDT * cfg.leverage * cfg.maxOpenLevels;

  // v4: volume SMA ring buffer (20-bar) over exec candles
  final volBuf = <double>[];
  const volPeriod = 20;

  for (int bar = 0; bar < htfCandles.length; bar++) {
    final bz = barZones[bar];
    if (bz.activeR.isEmpty || bz.activeS.isEmpty) {
      if (grid != null) grid.isActive = false;
      continue;
    }

    final chanTop = bz.activeR.first.boxBottom;
    final chanBot = bz.activeS.first.boxTop;
    if (chanTop <= chanBot) { if (grid != null) grid.isActive = false; continue; }

    final widthPct = (chanTop - chanBot) / chanBot * 100;
    if (widthPct < cfg.minChannelWidthPct) { if (grid != null) grid.isActive = false; continue; }

    final dir = bz.sfiTrend >= 0 ? GridDir.long : GridDir.short;
    final levels = List.generate(cfg.gridLevels + 1,
        (k) => chanBot + (chanTop - chanBot) * k / cfg.gridLevels);

    final needNew = grid == null || !grid.isActive || grid.dir != dir ||
        (grid.chanTop - chanTop).abs() / chanTop > 0.005 ||
        (grid.chanBot - chanBot).abs() / chanBot > 0.005;

    if (needNew) {
      // Close all at last exec price
      final lastP = execCandles.lastWhere(
          (c) => !c.time.isAfter(htfCandles[bar].time),
          orElse: () => execCandles.first).close;
      for (final t in trades.where((t) => t.isOpen)) {
        t.isOpen = false; t.exitPrice = lastP;
        t.exitTime = htfCandles[bar].time; t.exitReason = 'GRID_RESET';
        final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
        grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
      }
      grid = _GridState(chanTop: chanTop, chanBot: chanBot, levels: levels, dir: dir);
    }

    // 5m/1m execution candles for this 45m/30m/etc window
    final winStart = htfCandles[bar].time;
    final winEnd = bar + 1 < htfCandles.length
        ? htfCandles[bar + 1].time
        : winStart.add(Duration(minutes: 15 * cfg.htfMultiplier));

    final execBars = execCandles.where(
        (c) => !c.time.isBefore(winStart) && c.time.isBefore(winEnd)).toList();

    for (final c in execBars) {
      if (!grid.isActive) break;

      // Channel break check
      final broken = dir == GridDir.long
          ? c.close < chanBot * (1 - cfg.slBufferPct / 100)
          : c.close > chanTop * (1 + cfg.slBufferPct / 100);

      if (broken) {
        for (final t in trades.where((t) => t.isOpen)) {
          t.isOpen = false; t.exitPrice = t.slPrice;
          t.exitTime = c.time; t.exitReason = 'CHANNEL_BREAK';
          final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
          grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
          grid.openLevels.remove(t.levelIdx);
        }
        grid.isActive = false;
        continue;
      }

      // TP / SL management
      for (final t in trades.where((t) => t.isOpen)) {
        bool closed = false; String reason = ''; double at = 0;
        if (t.dir == GridDir.long) {
          if (c.high >= t.tpPrice) { at = t.tpPrice; reason = 'TP'; closed = true; }
          else if (c.low <= t.slPrice) { at = t.slPrice; reason = 'SL'; closed = true; }
        } else {
          if (c.low <= t.tpPrice) { at = t.tpPrice; reason = 'TP'; closed = true; }
          else if (c.high >= t.slPrice) { at = t.slPrice; reason = 'SL'; closed = true; }
        }
        if (closed) {
          t.isOpen = false; t.exitPrice = at; t.exitTime = c.time; t.exitReason = reason;
          final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
          grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
          grid.openLevels.remove(t.levelIdx);
        }
      }

      // v4: update volume SMA ring buffer
      volBuf.add(c.volume);
      if (volBuf.length > volPeriod) volBuf.removeAt(0);
      final volSma = volBuf.fold(0.0, (s, v) => s + v) / volBuf.length;

      // v4: circuit breaker — MTM session loss check
      final openMtmPnl = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
        final raw = t.dir == GridDir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        return s + raw * cfg.leverage - t.fees(cfg) - t.slippage(cfg);
      });
      final sessionNet    = netEq + openMtmPnl;
      final circuitTripped = cfg.circuitBreakerPct > 0 &&
          sessionNet < -(deployedCap * cfg.circuitBreakerPct / 100);

      // New entries
      if (!circuitTripped && grid.openLevels.length < cfg.maxOpenLevels) {
        // v4: volume filter
        final volOk = cfg.volSmaMultiplier <= 0 ||
            volBuf.length < volPeriod ||
            c.volume >= volSma * cfg.volSmaMultiplier;

        if (volOk) {
          for (int lvl = 0; lvl < levels.length - 1; lvl++) {
            if (grid.openLevels.contains(lvl)) continue;
            final lp = levels[lvl];
            bool triggered = false;

            if (dir == GridDir.long) {
              if (lp > grid.mid) continue;
              // v4: LONG confirmation — wick touched level but candle CLOSED ABOVE it
              // (zone held = bullish rejection). Without confirm: any touch triggers.
              triggered = cfg.requireClosedCandle
                  ? c.low <= lp && c.close > lp
                  : c.low <= lp && c.high >= lp;
            } else {
              if (lp < grid.mid) continue;
              // v4: SHORT confirmation — wick touched level but candle CLOSED BELOW it
              // (zone held = bearish rejection). Without confirm: any touch triggers.
              triggered = cfg.requireClosedCandle
                  ? c.high >= lp && c.close < lp
                  : c.high >= lp && c.low <= lp;
            }
            if (!triggered) continue;
            if (grid.openLevels.length >= cfg.maxOpenLevels) break;

            // skip if grid step too small vs fees
            final gridStep = grid.width / cfg.gridLevels;
            if (gridStep / lp * 100 < cfg.minGridStepPct) continue;

            final steps = (dir == GridDir.long
                ? grid.mid - lp : lp - grid.mid) / (grid.width / cfg.gridLevels);
            final mult = cfg.martingale
                ? pow(cfg.martingaleMultiplier, steps.clamp(0, cfg.gridLevels - 1)).toDouble()
                : 1.0;
            final notional = cfg.baseNotionalUSDT * mult;
            final qty      = notional / lp;

            // v4: scaled TP — martingale entries (steps≥1) get +1 extra level
            final isMartingaleEntry = steps >= 1;
            final tpDist = cfg.tpLevelsAway + (isMartingaleEntry ? 1 : 0);
            final tpIdx  = dir == GridDir.long ? lvl + tpDist : lvl - tpDist;
            final tp     = levels[tpIdx.clamp(0, levels.length - 1)];
            final sl     = dir == GridDir.long
                ? chanBot * (1 - cfg.slBufferPct / 100)
                : chanTop * (1 + cfg.slBufferPct / 100);

            final tr = _Trade(
              id: tradeId++, dir: dir, entryPrice: lp,
              qty: qty, notionalUSDT: notional,
              tpPrice: tp, slPrice: sl,
              levelIdx: lvl, entryTime: c.time,
            );
            trades.add(tr);
            grid.openLevels.add(lvl);
          }
        }
      }

      // Track drawdown (open positions MTM)
      final openPnl = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
        final raw = t.dir == GridDir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        return s + raw * cfg.leverage - t.fees(cfg) - t.slippage(cfg);
      });
      final cur = netEq + openPnl;
      if (cur > peakEq) peakEq = cur;
      final dd = peakEq - cur;
      if (dd > maxDd) maxDd = dd;
    }
  }

  // Force-close at final price
  final lastP = execCandles.last.close;
  for (final t in trades.where((t) => t.isOpen)) {
    t.isOpen = false; t.exitPrice = lastP;
    t.exitTime = execCandles.last.time; t.exitReason = 'END_OF_DATA';
    final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
    grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
  }

  final closed  = trades.where((t) => t.exitReason.isNotEmpty).toList();
  final wins    = closed.where((t) => t.grossPnl(cfg) > 0).length;
  final losses  = closed.length - wins;
  final tpEx    = closed.where((t) => t.exitReason == 'TP').length;
  final slEx    = closed.where((t) => t.exitReason == 'SL').length;
  final brkEx   = closed.where((t) => t.exitReason == 'CHANNEL_BREAK').length;

  final avgWinG  = wins > 0
      ? closed.where((t) => t.grossPnl(cfg) > 0).fold(0.0, (s, t) => s + t.grossPnl(cfg)) / wins
      : 0.0;
  final avgLossG = losses > 0
      ? closed.where((t) => t.grossPnl(cfg) <= 0).fold(0.0, (s, t) => s + t.grossPnl(cfg)).abs() / losses
      : 0.0;
  final pf = avgLossG > 0 ? (avgWinG * wins) / (avgLossG * losses) : double.infinity;

  final returnPct = deployedCap > 0 ? netEq / deployedCap * 100 : 0.0;
  final ddPct     = deployedCap > 0 ? maxDd / deployedCap * 100 : 0.0;
  final calmar    = ddPct.abs() > 0 ? returnPct / ddPct.abs() : 0.0;

  // v4: grade formula weights Calmar heavily — a Calmar≥5 is hedge-fund level
  String grade;
  if (calmar >= 5 && returnPct >= 50 && ddPct.abs() < 20)       grade = 'A ★★★';
  else if (calmar >= 3 && returnPct >= 30 && ddPct.abs() < 30)  grade = 'B ★★';
  else if (calmar >= 1 && returnPct >= 15 && ddPct.abs() < 40)  grade = 'C ★';
  else if (returnPct > 0)                                        grade = 'D';
  else                                                           grade = 'F ✗';

  return RunResult(
    config: cfg, totalTrades: closed.length,
    wins: wins, losses: losses,
    tpExits: tpEx, slExits: slEx, breakExits: brkEx,
    grossPnl: grossEq, totalFees: totalFee,
    totalSlippage: totalSlip, netPnl: netEq,
    maxDdPct: ddPct.abs(), returnPct: returnPct,
    calmar: calmar, pf: pf, grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// REPORT PRINTER
// ─────────────────────────────────────────────────────────────────────────────

void printDetailedReport(RunResult r) {
  final cfg = r.config;
  final sep = '═' * 70;
  print('\n╔$sep╗');
  print('║  ${r.config.label.padRight(68)}║');
  print('╠$sep╣');
  print('║  HTF: ${cfg.htfLabel}  |  Exec: ${cfg.execLabel}  |  GL=${cfg.gridLevels}  |  ML=${cfg.martingale ? cfg.martingaleMultiplier : 1.0}  |  MaxLvl=${cfg.maxOpenLevels}  |  TP=${cfg.tpLevelsAway}lvl  |  MinStep=${cfg.minGridStepPct}%${' ' * 3}║');
  print('╠$sep╣');

  // Cost breakdown
  print('║  COST BREAKDOWN${' ' * 54}║');
  print('║  Gross PnL  : ${_f(r.grossPnl, 10)}   (before fees & slippage)${' ' * 23}║');
  print('║  Fees paid  : ${_f(-r.totalFees, 10)}   maker commission @ ${cfg.commissionPct}% × 2 sides${' ' * 12}║');
  print('║  Slippage   : ${_f(-r.totalSlippage, 10)}   simulated @ ${cfg.slippagePct}% × 2 sides${' ' * 17}║');
  print('║  ─────────────────────────────────────────────────────────${' ' * 11}║');
  print('║  NET PnL    : ${_f(r.netPnl, 10)}   (what you actually keep)${' ' * 23}║');
  print('╠$sep╣');

  // Performance
  print('║  PERFORMANCE${' ' * 57}║');
  print('║  Trades: ${r.totalTrades.toString().padRight(6)}  Wins: ${r.wins.toString().padRight(6)}  Losses: ${r.losses.toString().padRight(6)}  WR: ${r.winRate.toStringAsFixed(1)}%${' ' * 14}║');
  print('║  TP: ${r.tpExits.toString().padRight(6)}  SL: ${r.slExits.toString().padRight(6)}  ChannelBreak: ${r.breakExits.toString().padRight(6)}${' ' * 23}║');
  print('║  PF: ${r.pf.isInfinite ? '∞   ' : r.pf.toStringAsFixed(2).padRight(8)}  Return: ${r.returnPct.toStringAsFixed(2).padRight(8)}%  MaxDD: ${r.maxDdPct.toStringAsFixed(2)}%${' ' * 14}║');
  print('║  Calmar: ${r.calmar.toStringAsFixed(2).padRight(59)}║');
  print('║  GRADE: ${r.grade.padRight(61)}║');
  print('╚$sep╝');
}

void printMasterTable(List<RunResult> results) {
  // Sort by Calmar descending
  final sorted = [...results]..sort((a, b) => b.calmar.compareTo(a.calmar));

  print('\n');
  print('╔═══════════════════════════════════════════════════════════════════════════════════════════════════════════╗');
  print('║                                    MASTER RANKING — ALL RUNS                                             ║');
  print('╠════╦══════════════════════════════════════╦══════╦═══════╦═══════╦════════╦════════╦════════╦════════════╣');
  print('║ #  ║ Config                               ║  WR% ║ Gross ║  Fees ║   Net  ║  DD%   ║ Return ║  Calmar    ║');
  print('╠════╬══════════════════════════════════════╬══════╬═══════╬═══════╬════════╬════════╬════════╬════════════╣');

  for (int i = 0; i < sorted.length; i++) {
    final r   = sorted[i];
    final lbl = r.config.label.length > 37
        ? r.config.label.substring(0, 37)
        : r.config.label.padRight(37);
    final rank = (i + 1).toString().padLeft(3);
    final wr   = r.winRate.toStringAsFixed(1).padLeft(5);
    final g    = _f2(r.grossPnl).padLeft(6);
    final fee  = _f2(-r.totalFees - r.totalSlippage).padLeft(6);
    final net  = _f2(r.netPnl).padLeft(7);
    final dd   = r.maxDdPct.toStringAsFixed(1).padLeft(6);
    final ret  = r.returnPct.toStringAsFixed(1).padLeft(7);
    final cal  = r.calmar.toStringAsFixed(1).padLeft(9);
    print('║$rank ║ $lbl║$wr%║$g ║$fee ║$net ║$dd% ║$ret% ║$cal  ║');
  }

  print('╚════╩══════════════════════════════════════╩══════╩═══════╩═══════╩════════╩════════╩════════╩════════════╝');

  final best = sorted.first;
  print('\n🏆 BEST CONFIG: ${best.config.label}');
  print('   Net PnL: ${_f(best.netPnl, 10)}  Return: ${best.returnPct.toStringAsFixed(2)}%  '
      'Calmar: ${best.calmar.toStringAsFixed(2)}  Grade: ${best.grade}');
}

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _f(double v, int w) => ((v >= 0 ? '+' : '') + v.toStringAsFixed(2)).padRight(w);
String _f2(double v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(0);

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  const base5m  = '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv';
  const base15m = '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv';
  const base1m  = '/Users/ayush/Desktop/candlestick data/1m/SOLUSDT1m.csv';

  // ── Load raw data ──────────────────────────────────────────────────────────
  print('Loading data...');
  final c15m = _loadCsv(base15m);
  final c5m  = _loadCsv(base5m);
  final c1m  = _loadCsv(base1m);
  print('  15m: ${c15m.length}  5m: ${c5m.length}  1m: ${c1m.length}\n');

  // ── Build HTF candles once per multiplier ──────────────────────────────────
  final htf30m = _aggregate(c15m, 2);  // 30m
  final htf45m = _aggregate(c15m, 3);  // 45m
  final htf60m = _aggregate(c15m, 4);  // 60m
  final htf90m = _aggregate(c15m, 6);  // 90m

  // ── Pre-compute zones per unique HTF (done once, reused across param sweeps) ─
  print('Pre-computing SR + SFI zones for each HTF...');
  final baseConfig = RunConfig(
    label: '_', symbol: 'SOLUSDT', csv15m: base15m, csvExec: base5m,
  );

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

  // ── v3 test matrix ─────────────────────────────────────────────────────────
  // Format: (label, htfMult, execLabel, execCandles, gl, ml, maxLvl, slBuf, tpAway, minStep)
  final testMatrix = [
    // ── 30m HTF ──
    ('30m+5m | GL=5 | ML=1.5 | TP=2', 2, '5m', c5m, 5, 1.5, 3, 0.3, 2, 0.5),
    ('30m+5m | GL=3 | ML=2.0 | TP=2', 2, '5m', c5m, 3, 2.0, 2, 0.3, 2, 0.5),
    ('30m+5m | GL=5 | ML=1.5 | TP=3', 2, '5m', c5m, 5, 1.5, 3, 0.3, 3, 0.5),

    // ── 45m HTF ──
    ('45m+5m | GL=5 | ML=1.5 | TP=2', 3, '5m', c5m, 5, 1.5, 3, 0.3, 2, 0.5),
    ('45m+5m | GL=3 | ML=2.0 | TP=2', 3, '5m', c5m, 3, 2.0, 2, 0.3, 2, 0.5),
    ('45m+5m | GL=5 | ML=1.5 | TP=3', 3, '5m', c5m, 5, 1.5, 3, 0.3, 3, 0.5),
    ('45m+5m | GL=5 | ML=1.0 | TP=2', 3, '5m', c5m, 5, 1.0, 3, 0.3, 2, 0.5),  // no martingale
    ('45m+5m | GL=3 | ML=2.0 | TP=3', 3, '5m', c5m, 3, 2.0, 2, 0.3, 3, 0.5),
    ('45m+1m | GL=5 | ML=1.5 | TP=2', 3, '1m', c1m, 5, 1.5, 3, 0.3, 2, 0.5),

    // ── 60m HTF ──
    ('60m+5m | GL=5 | ML=1.5 | TP=2', 4, '5m', c5m, 5, 1.5, 3, 0.3, 2, 0.5),
    ('60m+5m | GL=3 | ML=2.0 | TP=2', 4, '5m', c5m, 3, 2.0, 2, 0.3, 2, 0.5),
    ('60m+5m | GL=5 | ML=1.5 | TP=3', 4, '5m', c5m, 5, 1.5, 3, 0.3, 3, 0.5),

    // ── 90m HTF ──
    ('90m+5m | GL=5 | ML=1.5 | TP=2', 6, '5m', c5m, 5, 1.5, 3, 0.3, 2, 0.5),
    ('90m+5m | GL=3 | ML=2.0 | TP=2', 6, '5m', c5m, 3, 2.0, 2, 0.3, 2, 0.5),
    ('90m+5m | GL=5 | ML=1.5 | TP=3', 6, '5m', c5m, 5, 1.5, 3, 0.3, 3, 0.5),
  ];

  // ── Run all configs ────────────────────────────────────────────────────────
  final allResults = <RunResult>[];

  for (final (lbl, htfMult, execLbl, execC, gl, ml, maxLvl, slBuf, tpAway, minStep) in testMatrix) {
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
      commissionPct: 0.02, slippagePct: 0.03,  // v3: maker rates
      slBufferPct: slBuf,
      tpLevelsAway: tpAway,
      minGridStepPct: minStep,
      srDetectionLength: 10, srMargin: 2.0,
      sfiPeriod: 10, sfiMultiplier: 1.7,
      minChannelWidthPct: 0.8,
    );

    print('Running: $lbl...');
    final result = runBacktest(cfg, zonesByMult[htfMult]!, htfByMult[htfMult]!, execC);
    allResults.add(result);
    printDetailedReport(result);
  }

  // ── Master ranking table ───────────────────────────────────────────────────
  printMasterTable(allResults);
}
