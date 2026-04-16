// ============================================================================
// GRID / MARTINGALE SR ZONE — MULTI-ASSET INVESTOR REPORT
// ============================================================================
// Runs the best v4 config on ALL 21 assets automatically.
// Produces per-asset breakdown + full portfolio summary for investors.
//
// Best config (from v4 analysis):
//   HTF: 30m (from 15m)  |  Exec: 5m
//   Grid levels: 3  |  Martingale: 2.0x  |  TP: 2 levels  |  MaxOpen: 2
//   Entry: candle-close confirmation  |  Circuit breaker: 3%  |  Vol filter: 0.8x
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PATHS
// ─────────────────────────────────────────────────────────────────────────────

const _dataRoot = '/Users/ayush/Desktop/candlestick data';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class RunConfig {
  final String symbol;
  final String csv15m;
  final String csv5m;
  final int htfMultiplier;
  final int gridLevels;
  final double baseNotionalUSDT;
  final double leverage;
  final bool martingale;
  final double martingaleMultiplier;
  final int maxOpenLevels;
  final double commissionPct;
  final double slippagePct;
  final double slBufferPct;
  final int tpLevelsAway;
  final double minGridStepPct;
  final bool requireClosedCandle;
  final double circuitBreakerPct;
  final double volSmaMultiplier;
  final int srDetectionLength;
  final double srMargin;
  final int sfiPeriod;
  final double sfiMultiplier;
  final double minChannelWidthPct;

  const RunConfig({
    required this.symbol,
    required this.csv15m,
    required this.csv5m,
    this.htfMultiplier      = 2,    // 30m
    this.gridLevels         = 3,
    this.baseNotionalUSDT   = 20.0,
    this.leverage           = 5.0,
    this.martingale         = true,
    this.martingaleMultiplier = 2.0,
    this.maxOpenLevels      = 2,
    this.commissionPct      = 0.02,
    this.slippagePct        = 0.03,
    this.slBufferPct        = 0.3,
    this.tpLevelsAway       = 2,
    this.minGridStepPct     = 0.5,
    this.requireClosedCandle = true,
    this.circuitBreakerPct  = 3.0,
    this.volSmaMultiplier   = 0.8,
    this.srDetectionLength  = 10,
    this.srMargin           = 2.0,
    this.sfiPeriod          = 10,
    this.sfiMultiplier      = 1.7,
    this.minChannelWidthPct = 0.8,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class AssetResult {
  final String symbol;
  final int totalTrades;
  final int wins, losses;
  final int tpExits, slExits, breakExits;
  final double grossPnl;
  final double totalFees;
  final double totalSlippage;
  final double netPnl;
  final double maxDdPct;
  final double returnPct;
  final double calmar;
  final double pf;
  final String grade;
  final int totalBars;

  AssetResult({
    required this.symbol,
    required this.totalTrades,
    required this.wins, required this.losses,
    required this.tpExits, required this.slExits, required this.breakExits,
    required this.grossPnl, required this.totalFees,
    required this.totalSlippage, required this.netPnl,
    required this.maxDdPct, required this.returnPct,
    required this.calmar, required this.pf, required this.grade,
    required this.totalBars,
  });

  double get winRate => totalTrades == 0 ? 0 : wins / totalTrades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZONE STATE (per HTF bar)
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

  double grossPnl(RunConfig cfg) {
    if (exitPrice == 0) return 0;
    final raw = dir == GridDir.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
    return raw * cfg.leverage;
  }

  double fees(RunConfig cfg)     => notionalUSDT * cfg.leverage * cfg.commissionPct / 100 * 2;
  double slippage(RunConfig cfg) => notionalUSDT * cfg.leverage * cfg.slippagePct / 100 * 2;
  double netPnl(RunConfig cfg)   => grossPnl(cfg) - fees(cfg) - slippage(cfg);
}

class _Grid {
  final double chanTop, chanBot;
  final List<double> levels;
  final GridDir dir;
  final Set<int> openLevels = {};
  bool isActive = true;
  _Grid({required this.chanTop, required this.chanBot,
    required this.levels, required this.dir});
  double get width => chanTop - chanBot;
  double get mid   => (chanTop + chanBot) / 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI INDICATOR
// ─────────────────────────────────────────────────────────────────────────────

class _Sfi {
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
      if (i < period)       { sum += tr[i]; out.add(sum / (i + 1)); }
      else if (i == period) { out.add(tr.sublist(0, period).reduce((a, b) => a + b) / period); }
      else                  { out.add((out[i - 1] * (period - 1) + tr[i]) / period); }
    }
    return out;
  }

  int trend(List<Candle> cs, int period, double mult) {
    final atr = _atr(_tr(cs), period);
    double pUp = cs[0].ohlc4 - mult * (atr.isNotEmpty ? atr[0] : 0);
    double pDn = cs[0].ohlc4 + mult * (atr.isNotEmpty ? atr[0] : 0);
    int prevT = 1;
    for (int i = 0; i < cs.length; i++) {
      final c = cs[i];
      final a = i < atr.length ? atr[i] : (atr.isNotEmpty ? atr.last : 0.0);
      final up = i > 0 ? (cs[i-1].close > pUp ? max(c.ohlc4 - mult*a, pUp) : c.ohlc4 - mult*a) : c.ohlc4 - mult*a;
      final dn = i > 0 ? (cs[i-1].close < pDn ? min(c.ohlc4 + mult*a, pDn) : c.ohlc4 + mult*a) : c.ohlc4 + mult*a;
      int t = prevT;
      if (prevT == -1 && c.close > pDn) t = 1;
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
      hi  = max(hi, c15[i+j].high);
      lo  = min(lo, c15[i+j].low);
      vol += c15[i+j].volume;
    }
    out.add(Candle(c15[i].time, c15[i].open, hi, lo, c15[i+mult-1].close, vol, idx++));
  }
  return out;
}

List<_BarZones> _precompute(List<Candle> htf, RunConfig cfg) {
  final sr  = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true, showManip: false);
  final sfi = _Sfi();
  final min = cfg.srDetectionLength * 2 + 20;
  final out = <_BarZones>[];
  for (int i = 0; i < htf.length; i++) {
    if (i < min) { out.add(_BarZones([], [], 1)); continue; }
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

AssetResult _runBacktest(RunConfig cfg, List<_BarZones> zones,
    List<Candle> htf, List<Candle> exec) {

  final trades    = <_Trade>[];
  int   tradeId   = 0;
  double netEq    = 0.0, grossEq = 0.0;
  double totalFee = 0.0, totalSlip = 0.0;
  double peakEq   = 0.0, maxDd = 0.0;
  _Grid? grid;

  final deployedCap = cfg.baseNotionalUSDT * cfg.leverage * cfg.maxOpenLevels;
  final volBuf = <double>[];
  const volPeriod = 20;

  for (int bar = 0; bar < htf.length; bar++) {
    final bz = zones[bar];
    if (bz.activeR.isEmpty || bz.activeS.isEmpty) { if (grid != null) grid.isActive = false; continue; }

    final chanTop = bz.activeR.first.boxBottom;
    final chanBot = bz.activeS.first.boxTop;
    if (chanTop <= chanBot) { if (grid != null) grid.isActive = false; continue; }

    final widthPct = (chanTop - chanBot) / chanBot * 100;
    if (widthPct < cfg.minChannelWidthPct) { if (grid != null) grid.isActive = false; continue; }

    final dir    = bz.sfiTrend >= 0 ? GridDir.long : GridDir.short;
    final levels = List.generate(cfg.gridLevels + 1,
        (k) => chanBot + (chanTop - chanBot) * k / cfg.gridLevels);

    final needNew = grid == null || !grid.isActive || grid.dir != dir ||
        (grid.chanTop - chanTop).abs() / chanTop > 0.005 ||
        (grid.chanBot - chanBot).abs() / chanBot > 0.005;

    if (needNew) {
      final lastP = exec.lastWhere((c) => !c.time.isAfter(htf[bar].time),
          orElse: () => exec.first).close;
      for (final t in trades.where((t) => t.isOpen)) {
        t.isOpen = false; t.exitPrice = lastP;
        t.exitTime = htf[bar].time; t.exitReason = 'GRID_RESET';
        final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
        grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
      }
      grid = _Grid(chanTop: chanTop, chanBot: chanBot, levels: levels, dir: dir);
    }

    final winStart = htf[bar].time;
    final winEnd   = bar + 1 < htf.length
        ? htf[bar + 1].time
        : winStart.add(Duration(minutes: 15 * cfg.htfMultiplier));

    final execBars = exec.where((c) => !c.time.isBefore(winStart) && c.time.isBefore(winEnd)).toList();

    for (final c in execBars) {
      if (!grid.isActive) break;

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
        grid.isActive = false; continue;
      }

      for (final t in trades.where((t) => t.isOpen)) {
        bool closed = false; String reason = ''; double at = 0;
        if (t.dir == GridDir.long) {
          if (c.high >= t.tpPrice)  { at = t.tpPrice; reason = 'TP'; closed = true; }
          else if (c.low <= t.slPrice) { at = t.slPrice; reason = 'SL'; closed = true; }
        } else {
          if (c.low <= t.tpPrice)   { at = t.tpPrice; reason = 'TP'; closed = true; }
          else if (c.high >= t.slPrice) { at = t.slPrice; reason = 'SL'; closed = true; }
        }
        if (closed) {
          t.isOpen = false; t.exitPrice = at; t.exitTime = c.time; t.exitReason = reason;
          final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
          grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
          grid.openLevels.remove(t.levelIdx);
        }
      }

      volBuf.add(c.volume);
      if (volBuf.length > volPeriod) volBuf.removeAt(0);
      final volSma = volBuf.fold(0.0, (s, v) => s + v) / volBuf.length;

      final openMtm = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
        final raw = t.dir == GridDir.long
            ? (c.close - t.entryPrice) * t.qty
            : (t.entryPrice - c.close) * t.qty;
        return s + raw * cfg.leverage - t.fees(cfg) - t.slippage(cfg);
      });
      final circuitTripped = cfg.circuitBreakerPct > 0 &&
          (netEq + openMtm) < -(deployedCap * cfg.circuitBreakerPct / 100);
      final volOk = cfg.volSmaMultiplier <= 0 || volBuf.length < volPeriod ||
          c.volume >= volSma * cfg.volSmaMultiplier;

      if (!circuitTripped && volOk && grid.openLevels.length < cfg.maxOpenLevels) {
        for (int lvl = 0; lvl < levels.length - 1; lvl++) {
          if (grid.openLevels.contains(lvl)) continue;
          final lp = levels[lvl];
          bool triggered = false;
          if (dir == GridDir.long) {
            if (lp > grid.mid) continue;
            triggered = cfg.requireClosedCandle
                ? c.low <= lp && c.close > lp
                : c.low <= lp && c.high >= lp;
          } else {
            if (lp < grid.mid) continue;
            triggered = cfg.requireClosedCandle
                ? c.high >= lp && c.close < lp
                : c.high >= lp && c.low <= lp;
          }
          if (!triggered) continue;
          if (grid.openLevels.length >= cfg.maxOpenLevels) break;

          final gridStep = grid.width / cfg.gridLevels;
          if (gridStep / lp * 100 < cfg.minGridStepPct) continue;

          final steps = (dir == GridDir.long
              ? grid.mid - lp : lp - grid.mid) / (grid.width / cfg.gridLevels);
          final mult    = cfg.martingale
              ? pow(cfg.martingaleMultiplier, steps.clamp(0, cfg.gridLevels - 1)).toDouble()
              : 1.0;
          final notional = cfg.baseNotionalUSDT * mult;
          final qty      = notional / lp;

          final tpDist = cfg.tpLevelsAway + (steps >= 1 ? 1 : 0);
          final tpIdx  = dir == GridDir.long ? lvl + tpDist : lvl - tpDist;
          final tp     = levels[tpIdx.clamp(0, levels.length - 1)];
          final sl     = dir == GridDir.long
              ? chanBot * (1 - cfg.slBufferPct / 100)
              : chanTop * (1 + cfg.slBufferPct / 100);

          trades.add(_Trade(
            id: tradeId++, dir: dir, entryPrice: lp,
            qty: qty, notionalUSDT: notional,
            tpPrice: tp, slPrice: sl,
            levelIdx: lvl, entryTime: c.time,
          ));
          grid.openLevels.add(lvl);
        }
      }

      final curEq = netEq + openMtm;
      if (curEq > peakEq) peakEq = curEq;
      final dd = peakEq - curEq;
      if (dd > maxDd) maxDd = dd;
    }
  }

  final lastP = exec.last.close;
  for (final t in trades.where((t) => t.isOpen)) {
    t.isOpen = false; t.exitPrice = lastP;
    t.exitTime = exec.last.time; t.exitReason = 'END_OF_DATA';
    final gp = t.grossPnl(cfg); final fee = t.fees(cfg); final slip = t.slippage(cfg);
    grossEq += gp; totalFee += fee; totalSlip += slip; netEq += gp - fee - slip;
  }

  final closed = trades.where((t) => t.exitReason.isNotEmpty).toList();
  final wins   = closed.where((t) => t.grossPnl(cfg) > 0).length;
  final losses = closed.length - wins;
  final tpEx   = closed.where((t) => t.exitReason == 'TP').length;
  final slEx   = closed.where((t) => t.exitReason == 'SL').length;
  final brkEx  = closed.where((t) => t.exitReason == 'CHANNEL_BREAK').length;

  final avgW = wins > 0
      ? closed.where((t) => t.grossPnl(cfg) > 0).fold(0.0, (s, t) => s + t.grossPnl(cfg)) / wins
      : 0.0;
  final avgL = losses > 0
      ? closed.where((t) => t.grossPnl(cfg) <= 0).fold(0.0, (s, t) => s + t.grossPnl(cfg)).abs() / losses
      : 0.0;
  final pf  = avgL > 0 ? (avgW * wins) / (avgL * losses) : double.infinity;

  final returnPct = deployedCap > 0 ? netEq / deployedCap * 100 : 0.0;
  final ddPct     = deployedCap > 0 ? maxDd / deployedCap * 100 : 0.0;
  final calmar    = ddPct > 0 ? returnPct / ddPct : 0.0;

  String grade;
  if      (calmar >= 5 && returnPct >= 50 && ddPct < 20) grade = 'A ★★★';
  else if (calmar >= 3 && returnPct >= 30 && ddPct < 30) grade = 'B ★★';
  else if (calmar >= 1 && returnPct >= 15 && ddPct < 40) grade = 'C ★';
  else if (returnPct > 0)                                grade = 'D';
  else                                                   grade = 'F ✗';

  return AssetResult(
    symbol: cfg.symbol, totalTrades: closed.length,
    wins: wins, losses: losses,
    tpExits: tpEx, slExits: slEx, breakExits: brkEx,
    grossPnl: grossEq, totalFees: totalFee,
    totalSlippage: totalSlip, netPnl: netEq,
    maxDdPct: ddPct, returnPct: returnPct,
    calmar: calmar, pf: pf, grade: grade,
    totalBars: htf.length,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// INVESTOR REPORT
// ─────────────────────────────────────────────────────────────────────────────

void _printInvestorReport(List<AssetResult> results, RunConfig sampleCfg,
    DateTime periodStart, DateTime periodEnd) {
  final sorted = [...results]..sort((a, b) => b.netPnl.compareTo(a.netPnl));

  final totalNet    = results.fold(0.0, (s, r) => s + r.netPnl);
  final totalGross  = results.fold(0.0, (s, r) => s + r.grossPnl);
  final totalFees   = results.fold(0.0, (s, r) => s + r.totalFees);
  final totalSlip   = results.fold(0.0, (s, r) => s + r.totalSlippage);
  final totalTrades = results.fold(0, (s, r) => s + r.totalTrades);
  final totalWins   = results.fold(0, (s, r) => s + r.wins);
  final profitableAssets = results.where((r) => r.netPnl > 0).length;
  final avgWR       = results.isEmpty ? 0.0 : results.fold(0.0, (s, r) => s + r.winRate) / results.length;
  final avgCalmar   = results.isEmpty ? 0.0 : results.fold(0.0, (s, r) => s + r.calmar) / results.length;
  final avgReturn   = results.isEmpty ? 0.0 : results.fold(0.0, (s, r) => s + r.returnPct) / results.length;
  final worstDd     = results.isEmpty ? 0.0 : results.map((r) => r.maxDdPct).reduce(max);
  final portfolioPf = totalFees + totalSlip > 0
      ? totalGross / (totalFees + totalSlip + (totalNet < 0 ? totalNet.abs() : 0))
      : 0.0;

  // Grade distribution
  final gradeA = results.where((r) => r.grade.startsWith('A')).length;
  final gradeB = results.where((r) => r.grade.startsWith('B')).length;
  final gradeC = results.where((r) => r.grade.startsWith('C')).length;
  final gradeD = results.where((r) => r.grade.startsWith('D')).length;
  final gradeF = results.where((r) => r.grade.startsWith('F')).length;

  final sep  = '═' * 78;
  final sep2 = '─' * 78;

  print('\n');
  print('╔$sep╗');
  print('║${_c('ASTERDEX GRID TRADING STRATEGY — INVESTOR PERFORMANCE REPORT', 78)}║');
  print('╠$sep╣');
  print('║${_c('Backtest Period: ${_fd(periodStart)} → ${_fd(periodEnd)}', 78)}║');
  print('║${_c('Assets Tested: ${results.length}  |  Strategy: Zone Grid / Martingale  |  Exec TF: 5m', 78)}║');
  print('╠$sep╣');

  // Strategy summary
  print('║  STRATEGY PARAMETERS${' ' * 57}║');
  print('║  HTF: 30m (3×15m)  |  Entry: Candle-close confirmation at SR zones          ║');
  print('║  Grid: ${sampleCfg.gridLevels} levels  |  Martingale: ${sampleCfg.martingaleMultiplier}x  |  TP: ${sampleCfg.tpLevelsAway} levels away  |  Max positions: ${sampleCfg.maxOpenLevels}    ║');
  print('║  Commission: ${sampleCfg.commissionPct}% (maker)  |  Slippage: ${sampleCfg.slippagePct}%  |  Circuit breaker: ${sampleCfg.circuitBreakerPct}%  |  Vol filter: ON  ║');
  print('║  Capital per asset: \$${sampleCfg.baseNotionalUSDT.toStringAsFixed(0)}  |  Leverage: ${sampleCfg.leverage}x  |  Max deployed: \$${(sampleCfg.baseNotionalUSDT * sampleCfg.leverage * sampleCfg.maxOpenLevels).toStringAsFixed(0)}           ║');
  print('╠$sep╣');

  // Portfolio P&L
  print('║  PORTFOLIO P&L BREAKDOWN${' ' * 53}║');
  print('║  Gross PnL    : ${_fp(totalGross, 12)}  (sum across all ${results.length} assets)${' ' * 26}║');
  print('║  Total Fees   : ${_fp(-totalFees, 12)}  (maker commission @ ${sampleCfg.commissionPct}%)${' ' * 29}║');
  print('║  Total Slippage: ${_fp(-totalSlip, 11)}  (simulated @ ${sampleCfg.slippagePct}%)${' ' * 33}║');
  print('║  $sep2  ║');
  print('║  NET PnL      : ${_fp(totalNet, 12)}  ← what you actually keep${' ' * 27}║');
  print('╠$sep╣');

  // Portfolio stats
  print('║  PORTFOLIO STATISTICS${' ' * 56}║');
  print('║  Total Trades     : ${totalTrades.toString().padRight(10)} Profitable Assets: $profitableAssets / ${results.length}${' ' * 22}║');
  print('║  Total Wins       : ${totalWins.toString().padRight(10)} Avg Win Rate     : ${avgWR.toStringAsFixed(1)}%${' ' * 25}║');
  print('║  Avg Return/Asset : ${('${avgReturn.toStringAsFixed(1)}%').padRight(10)} Avg Calmar Ratio : ${avgCalmar.toStringAsFixed(2)}${' ' * 25}║');
  print('║  Worst Asset DD   : ${('${worstDd.toStringAsFixed(1)}%').padRight(10)} Grade Dist: A=${gradeA} B=${gradeB} C=${gradeC} D=${gradeD} F=${gradeF}${' ' * 19}║');
  print('║  Portfolio PF     : ${portfolioPf.toStringAsFixed(2).padRight(10)}${' ' * 46}║');
  print('╠$sep╣');

  // Per-asset table
  print('║  PER-ASSET BREAKDOWN${' ' * 57}║');
  print('╠════════════╦═══════╦══════╦════════╦═══════╦═════════╦═════════╦═══════════╣');
  print('║ Symbol     ║Trades ║  WR% ║Net PnL ║Ret%   ║ Max DD% ║  Calmar ║ Grade     ║');
  print('╠════════════╬═══════╬══════╬════════╬═══════╬═════════╬═════════╬═══════════╣');

  for (final r in sorted) {
    final sym    = r.symbol.padRight(10);
    final trades = r.totalTrades.toString().padLeft(5);
    final wr     = r.winRate.toStringAsFixed(1).padLeft(5);
    final net    = _fp(r.netPnl, 7);
    final ret    = ('${r.returnPct.toStringAsFixed(1)}%').padLeft(6);
    final dd     = ('${r.maxDdPct.toStringAsFixed(1)}%').padLeft(7);
    final cal    = r.calmar.toStringAsFixed(1).padLeft(7);
    final gr     = r.grade.padRight(9);
    print('║ $sym ║$trades ║$wr% ║$net ║$ret ║$dd  ║$cal  ║ $gr ║');
  }

  print('╠════════════╬═══════╬══════╬════════╬═══════╬═════════╬═════════╬═══════════╣');
  final allSym  = 'PORTFOLIO'.padRight(10);
  final allT    = totalTrades.toString().padLeft(5);
  final allWR   = avgWR.toStringAsFixed(1).padLeft(5);
  final allNet  = _fp(totalNet, 7);
  final allRet  = ('${avgReturn.toStringAsFixed(1)}%').padLeft(6);
  final allDD   = ('${worstDd.toStringAsFixed(1)}%').padLeft(7);
  final allCal  = avgCalmar.toStringAsFixed(1).padLeft(7);
  print('║ $allSym ║$allT ║$allWR% ║$allNet ║$allRet ║$allDD  ║$allCal  ║ COMBINED  ║');
  print('╚════════════╩═══════╩══════╩════════╩═══════╩═════════╩═════════╩═══════════╝');

  // Top 5 / Bottom 5
  print('\n  ── TOP 5 PERFORMERS ─────────────────────────────────────────────────');
  for (int i = 0; i < min(5, sorted.length); i++) {
    final r = sorted[i];
    print('  ${(i+1)}. ${r.symbol.padRight(12)} Net: ${_fp(r.netPnl, 10)} Return: ${r.returnPct.toStringAsFixed(1).padLeft(7)}%  Calmar: ${r.calmar.toStringAsFixed(2).padLeft(6)}  ${r.grade}');
  }
  print('\n  ── BOTTOM 5 PERFORMERS ───────────────────────────────────────────────');
  final bottom = sorted.reversed.take(5).toList();
  for (int i = 0; i < bottom.length; i++) {
    final r = bottom[i];
    print('  ${(sorted.length - bottom.length + i + 1)}. ${r.symbol.padRight(12)} Net: ${_fp(r.netPnl, 10)} Return: ${r.returnPct.toStringAsFixed(1).padLeft(7)}%  Calmar: ${r.calmar.toStringAsFixed(2).padLeft(6)}  ${r.grade}');
  }

  // Investment summary
  final totalCapDeployed = sampleCfg.baseNotionalUSDT * sampleCfg.leverage * sampleCfg.maxOpenLevels * results.length;
  print('\n  ── INVESTMENT SUMMARY ────────────────────────────────────────────────');
  print('  Total capital deployed: \$${totalCapDeployed.toStringAsFixed(0)} (${results.length} assets × \$${(sampleCfg.baseNotionalUSDT * sampleCfg.leverage * sampleCfg.maxOpenLevels).toStringAsFixed(0)}/asset)');
  print('  Portfolio net return  : ${(totalNet / totalCapDeployed * 100).toStringAsFixed(2)}%');
  print('  Net PnL (all assets)  : ${totalNet >= 0 ? '+' : ''}\$${totalNet.toStringAsFixed(2)}');
  print('  Profitable assets     : $profitableAssets / ${results.length} (${(profitableAssets / results.length * 100).toStringAsFixed(0)}%)');
  print('  Average Calmar ratio  : ${avgCalmar.toStringAsFixed(2)}  (>3 = institutional grade)');
  print('');
}

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _c(String s, int w) {
  final pad = w - s.length; final l = pad ~/ 2; final r = pad - l;
  return ' ' * l + s + ' ' * r;
}

String _fp(double v, int w) => ((v >= 0 ? '+' : '') + v.toStringAsFixed(2)).padRight(w);
String _fd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  final allSymbols = [
    'ADAUSDT','APTUSDT','ASTERUSDT','BCHUSDT','BNBUSDT',
    'BTCUSDT','CFXUSDT','DOGEUSDT','ENAUSDT','ETHUSDT',
    'HBARUSDT','ICPUSDT','LTCUSDT','MYXUSDT','QNTUSDT',
    'SOLUSDT','SUIUSDT','TRBUSDT','TRXUSDT','XMRUSDT','XRPUSDT',
  ];

  print('╔══════════════════════════════════════════════════════════════════════════════╗');
  print('║         GRID STRATEGY — MULTI-ASSET BACKTEST (${allSymbols.length} assets)              ║');
  print('╚══════════════════════════════════════════════════════════════════════════════╝\n');

  final results   = <AssetResult>[];
  DateTime? start, end;
  RunConfig? sampleCfg;

  for (final sym in allSymbols) {
    final csv15m = '$_dataRoot/15m/${sym}15m.csv';
    final csv5m  = '$_dataRoot/5m/${sym}5m.csv';

    if (!File(csv15m).existsSync() || !File(csv5m).existsSync()) {
      print('  [SKIP] $sym — CSV not found');
      continue;
    }

    final cfg = RunConfig(symbol: sym, csv15m: csv15m, csv5m: csv5m);
    sampleCfg ??= cfg;

    stdout.write('  Running $sym ... ');

    try {
      final c15m = _loadCsv(csv15m);
      final c5m  = _loadCsv(csv5m);
      final htf  = _aggregate(c15m, cfg.htfMultiplier);
      final zones = _precompute(htf, cfg);
      final result = _runBacktest(cfg, zones, htf, c5m);
      results.add(result);

      start ??= c5m.first.time;
      end    = c5m.last.time;

      final flag = result.netPnl >= 0 ? '✅' : '❌';
      print('$flag  Net: ${_fp(result.netPnl, 9)}  WR: ${result.winRate.toStringAsFixed(1).padLeft(5)}%  '
          'Calmar: ${result.calmar.toStringAsFixed(2).padLeft(6)}  ${result.grade}');
    } catch (e) {
      print('❌  ERROR: $e');
    }
  }

  print('');
  _printInvestorReport(results, sampleCfg!, start!, end!);
}
