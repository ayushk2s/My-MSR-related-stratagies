// ============================================================================
// GRID / MARTINGALE SR ZONE BACKTEST
// ============================================================================
// Strategy:
//   • SR zones detected on 45m candles (built by aggregating 3 × 15m candles)
//   • SFI indicator determines trend direction (long grid vs short grid)
//   • A grid of N evenly-spaced levels is placed inside the S-R channel
//   • Entries execute when 5m candle price touches a grid level
//   • Martingale sizing: deeper levels get progressively larger positions
//   • TP  = next grid level (toward opposite zone)
//   • SL  = channel boundary break + buffer
//   • Grid invalidated when price closes outside the channel
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class GridConfig {
  final String symbol;
  final String csv15m;              // 45m is aggregated from this
  final String csv5m;               // execution timeframe

  // Grid parameters
  final int gridLevels;             // total grid lines (e.g. 5)
  final double baseNotionalUSDT;    // base position notional per unit, before leverage
  final double leverage;
  final bool martingale;            // if true, deeper levels get more size
  final double martingaleMultiplier; // 1.5 → each level 50% larger than previous
  final int maxOpenLevels;          // max concurrent open trades

  // Risk
  final double commissionPct;       // 0.05 = 0.05%
  final double slBufferPct;         // extra % beyond channel edge for SL

  // SR + SFI settings
  final int srDetectionLength;
  final double srMargin;
  final int sfiPeriod;
  final double sfiMultiplier;

  // Filters
  final double minChannelWidthPct;  // skip channels narrower than this %

  const GridConfig({
    required this.symbol,
    required this.csv15m,
    required this.csv5m,
    this.gridLevels = 5,
    this.baseNotionalUSDT = 20.0,
    this.leverage = 5.0,
    this.martingale = true,
    this.martingaleMultiplier = 1.5,
    this.maxOpenLevels = 3,
    this.commissionPct = 0.05,
    this.slBufferPct = 0.3,
    this.srDetectionLength = 10,
    this.srMargin = 2.0,
    this.sfiPeriod = 10,
    this.sfiMultiplier = 1.7,
    this.minChannelWidthPct = 0.8,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

enum GridDirection { long, short }

class GridTrade {
  final int id;
  final GridDirection direction;
  final double entryPrice;
  final double qty;
  final double notionalUSDT;    // qty * entryPrice (base, before leverage)
  final double tpPrice;
  final double slPrice;
  final int levelIndex;
  final DateTime entryTime;

  bool isOpen = true;
  double exitPrice = 0.0;
  DateTime? exitTime;
  String exitReason = '';

  GridTrade({
    required this.id,
    required this.direction,
    required this.entryPrice,
    required this.qty,
    required this.notionalUSDT,
    required this.tpPrice,
    required this.slPrice,
    required this.levelIndex,
    required this.entryTime,
  });

  // PnL in USDT (before leverage — multiply by leverage when recording to equity)
  double get rawPnl {
    if (exitPrice == 0) return 0;
    return direction == GridDirection.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
  }
}

class GridState {
  final double channelTop;      // R[0].boxBottom (bottom of resistance zone)
  final double channelBottom;   // S[0].boxTop    (top of support zone)
  final List<double> levels;    // evenly spaced grid lines
  final GridDirection direction;
  final Set<int> openLevelIndices = {};
  bool isActive = true;

  GridState({
    required this.channelTop,
    required this.channelBottom,
    required this.levels,
    required this.direction,
  });

  double get width      => channelTop - channelBottom;
  double get midpoint   => (channelTop + channelBottom) / 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI INDICATOR  (SuperTrend-style, copied from main.dart)
// ─────────────────────────────────────────────────────────────────────────────

class SfiSignal {
  final double upLine;
  final double dnLine;
  final int trend;
  final bool buySignal;
  final bool sellSignal;
  SfiSignal({
    required this.upLine, required this.dnLine,
    required this.trend,  required this.buySignal, required this.sellSignal,
  });
}

class SfiIndicator {
  List<double> _calcTR(List<Candle> candles) {
    final tr = <double>[];
    for (int i = 0; i < candles.length; i++) {
      final prev = i == 0 ? candles[i].close : candles[i - 1].close;
      tr.add([
        candles[i].high - candles[i].low,
        (candles[i].high - prev).abs(),
        (candles[i].low  - prev).abs(),
      ].reduce(max));
    }
    return tr;
  }

  List<double> _wilderATR(List<double> tr, int period) {
    final atr = <double>[];
    double sum = 0;
    for (int i = 0; i < tr.length; i++) {
      if (i < period) {
        sum += tr[i];
        atr.add(sum / (i + 1));
      } else if (i == period) {
        atr.add(tr.sublist(0, period).reduce((a, b) => a + b) / period);
      } else {
        atr.add((atr[i - 1] * (period - 1) + tr[i]) / period);
      }
    }
    return atr;
  }

  List<SfiSignal> calculate(List<Candle> candles, {int period = 10, double multiplier = 1.7}) {
    final tr  = _calcTR(candles);
    final atr = _wilderATR(tr, period);
    final out = <SfiSignal>[];
    if (candles.isEmpty) return out;

    double prevUp = candles[0].ohlc4 - multiplier * (atr.isNotEmpty ? atr[0] : 0);
    double prevDn = candles[0].ohlc4 + multiplier * (atr.isNotEmpty ? atr[0] : 0);
    int prevTrend = 1;

    for (int i = 0; i < candles.length; i++) {
      final c   = candles[i];
      final a   = i < atr.length ? atr[i] : (atr.isNotEmpty ? atr.last : 0.0);
      final raw_up = c.ohlc4 - multiplier * a;
      final raw_dn = c.ohlc4 + multiplier * a;

      final up = i > 0
          ? (candles[i - 1].close > prevUp ? max(raw_up, prevUp) : raw_up)
          : raw_up;
      final dn = i > 0
          ? (candles[i - 1].close < prevDn ? min(raw_dn, prevDn) : raw_dn)
          : raw_dn;

      int trend = prevTrend;
      if (prevTrend == -1 && c.close > prevDn) trend = 1;
      else if (prevTrend == 1 && c.close < prevUp) trend = -1;

      out.add(SfiSignal(
        upLine: up, dnLine: dn, trend: trend,
        buySignal:  prevTrend == -1 && trend == 1,
        sellSignal: prevTrend ==  1 && trend == -1,
      ));
      prevUp = up; prevDn = dn; prevTrend = trend;
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out   = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(',');
    if (p.length < 6) continue;
    out.add(Candle(
      DateTime.parse(p[0] + 'Z'),
      double.parse(p[1]),
      double.parse(p[2]),
      double.parse(p[3]),
      double.parse(p[4]),
      double.parse(p[5]),
      i - 1,
    ));
  }
  return out;
}

/// Aggregate 15m candles into 45m by taking groups of 3.
List<Candle> to45m(List<Candle> c15) {
  final out = <Candle>[];
  int idx = 0;
  for (int i = 0; i + 2 < c15.length; i += 3) {
    out.add(Candle(
      c15[i].time,
      c15[i].open,
      max(c15[i].high, max(c15[i + 1].high, c15[i + 2].high)),
      min(c15[i].low,  min(c15[i + 1].low,  c15[i + 2].low)),
      c15[i + 2].close,
      c15[i].volume + c15[i + 1].volume + c15[i + 2].volume,
      idx++,
    ));
  }
  return out;
}

/// Build a list of [start, end) time-boundary pairs for each 45m bar
/// so we can quickly pull matching 5m candles.
List<(DateTime, DateTime)> buildBarWindows(List<Candle> c45) {
  final wins = <(DateTime, DateTime)>[];
  for (int i = 0; i < c45.length; i++) {
    final end = i + 1 < c45.length
        ? c45[i + 1].time
        : c45[i].time.add(const Duration(minutes: 45));
    wins.add((c45[i].time, end));
  }
  return wins;
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

class GridBacktester {
  final GridConfig cfg;

  GridBacktester(this.cfg);

  double _comm(double notional) => notional * cfg.commissionPct / 100;

  void run() {
    // ── 1. Load and build candles ─────────────────────────────────────────────
    print('Loading candle data...');
    final c15m = loadCsv(cfg.csv15m);
    final c5m  = loadCsv(cfg.csv5m);
    final c45m = to45m(c15m);

    print('  15m: ${c15m.length} candles  (${c15m.first.time.toUtc()} → ${c15m.last.time.toUtc()})');
    print('  5m : ${c5m.length} candles');
    print('  45m: ${c45m.length} candles (aggregated)\n');

    final windows = buildBarWindows(c45m);
    final srInd   = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength,
      srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true, showManip: false,
    );
    final sfiInd = SfiIndicator();

    // ── 2. Bookkeeping ────────────────────────────────────────────────────────
    final allTrades   = <GridTrade>[];
    int   tradeId     = 0;
    double equity     = 0.0;       // cumulative realized PnL in USDT (with leverage)
    double peakEq     = 0.0;
    double maxDd      = 0.0;
    GridState? grid;

    final int minBars = cfg.srDetectionLength * 2 + 20;

    // ── 3. Main loop: one 45m bar at a time ───────────────────────────────────
    for (int bar45 = minBars; bar45 < c45m.length; bar45++) {

      // ── 3a. SR + SFI analysis on 45m data up to this bar (no lookahead) ────
      final srResult = srInd.calculate(c45m.sublist(0, bar45 + 1));
      final sfiSigs  = sfiInd.calculate(c45m.sublist(0, bar45 + 1),
          period: cfg.sfiPeriod, multiplier: cfg.sfiMultiplier);
      final sfi = sfiSigs.last;

      final activeR = srResult.resistance.where((z) => z.isActive).toList();
      final activeS = srResult.support.where((z) => z.isActive).toList();

      // Need at least one of each to form a channel
      if (activeR.isEmpty || activeS.isEmpty) {
        if (grid != null) grid.isActive = false;
        continue;
      }

      final topZone    = activeR.first;   // nearest active resistance
      final botZone    = activeS.first;   // nearest active support
      final chanTop    = topZone.boxBottom;
      final chanBot    = botZone.boxTop;

      // Sanity check
      if (chanTop <= chanBot) {
        if (grid != null) grid.isActive = false;
        continue;
      }

      final widthPct = (chanTop - chanBot) / chanBot * 100;
      if (widthPct < cfg.minChannelWidthPct) {
        if (grid != null) grid.isActive = false;
        continue;
      }

      // Direction from SFI
      final dir = sfi.trend >= 0 ? GridDirection.long : GridDirection.short;

      // Build evenly-spaced grid levels
      final levels = List.generate(cfg.gridLevels + 1,
          (k) => chanBot + (chanTop - chanBot) * k / cfg.gridLevels);

      // Rebuild grid if channel shifted significantly (>0.5%) or direction changed
      final bool needNewGrid = grid == null ||
          !grid.isActive ||
          grid.direction != dir ||
          (grid.channelTop - chanTop).abs() / chanTop > 0.005 ||
          (grid.channelBottom - chanBot).abs() / chanBot > 0.005;

      if (needNewGrid) {
        // Force-close all existing open trades at the current last 5m close
        // (approximate close when channel resets)
        final lastClose = _last5mClose(c5m, c45m[bar45].time);
        _closeAll(allTrades, lastClose, c45m[bar45].time, 'GRID_RESET', equity);
        grid = GridState(
          channelTop: chanTop, channelBottom: chanBot,
          levels: levels, direction: dir,
        );
      }

      // ── 3b. Execution on every 5m candle in this 45m bar's window ──────────
      final (winStart, winEnd) = windows[bar45];
      final bar5mList = c5m.where(
          (c) => !c.time.isBefore(winStart) && c.time.isBefore(winEnd)).toList();

      for (final c5 in bar5mList) {
        if (!grid.isActive) break;

        // ── Check channel invalidation ──────────────────────────────────────
        final slBreak = dir == GridDirection.long
            ? c5.close < chanBot * (1 - cfg.slBufferPct / 100)
            : c5.close > chanTop * (1 + cfg.slBufferPct / 100);

        if (slBreak) {
          for (final t in allTrades.where((t) => t.isOpen)) {
            t.isOpen     = false;
            t.exitPrice  = t.slPrice;
            t.exitTime   = c5.time;
            t.exitReason = 'CHANNEL_BREAK';
            final leveragedPnl = t.rawPnl * cfg.leverage;
            equity += leveragedPnl - _comm(t.notionalUSDT * cfg.leverage) * 2;
            grid.openLevelIndices.remove(t.levelIndex);
          }
          grid.isActive = false;
          _trackDD(equity, allTrades, c5.close, peakEq, (p, d) { peakEq = p; maxDd = d; });
          break;
        }

        // ── Check TP / SL on open trades ────────────────────────────────────
        for (final t in allTrades.where((t) => t.isOpen)) {
          bool closed = false;
          String reason = '';
          double closeAt = 0;

          if (t.direction == GridDirection.long) {
            if (c5.high >= t.tpPrice) { closeAt = t.tpPrice; reason = 'TP'; closed = true; }
            else if (c5.low <= t.slPrice) { closeAt = t.slPrice; reason = 'SL'; closed = true; }
          } else {
            if (c5.low <= t.tpPrice) { closeAt = t.tpPrice; reason = 'TP'; closed = true; }
            else if (c5.high >= t.slPrice) { closeAt = t.slPrice; reason = 'SL'; closed = true; }
          }

          if (closed) {
            t.isOpen     = false;
            t.exitPrice  = closeAt;
            t.exitTime   = c5.time;
            t.exitReason = reason;
            final lev = t.rawPnl * cfg.leverage;
            equity += lev - _comm(t.notionalUSDT * cfg.leverage) * 2;
            grid.openLevelIndices.remove(t.levelIndex);
          }
        }

        // ── Check for new grid entries ───────────────────────────────────────
        if (grid.openLevelIndices.length < cfg.maxOpenLevels) {
          for (int lvl = 0; lvl < levels.length - 1; lvl++) {
            if (grid.openLevelIndices.contains(lvl)) continue;

            final lvlPrice = levels[lvl];
            bool touched   = false;

            if (dir == GridDirection.long) {
              // Only enter in LOWER half (buy dips toward support)
              if (lvlPrice > grid.midpoint) continue;
              touched = c5.low <= lvlPrice && c5.high >= lvlPrice;
            } else {
              // Only enter in UPPER half (sell rallies toward resistance)
              if (lvlPrice < grid.midpoint) continue;
              touched = c5.high >= lvlPrice && c5.low <= lvlPrice;
            }

            if (!touched) continue;
            if (grid.openLevelIndices.length >= cfg.maxOpenLevels) break;

            // Martingale sizing: deeper levels (away from midpoint) get more size
            final stepsFromMid = (dir == GridDirection.long
                ? grid.midpoint - lvlPrice
                : lvlPrice - grid.midpoint) / (grid.width / cfg.gridLevels);
            final mult = cfg.martingale
                ? pow(cfg.martingaleMultiplier, stepsFromMid.clamp(0, cfg.gridLevels - 1)).toDouble()
                : 1.0;
            final notional = cfg.baseNotionalUSDT * mult;
            final qty      = notional / lvlPrice;

            // TP = next level toward opposite zone; SL = beyond channel
            final tpIdx  = dir == GridDirection.long ? lvl + 1 : lvl - 1;
            final tpPrice = levels[tpIdx.clamp(0, levels.length - 1)];
            final slPrice = dir == GridDirection.long
                ? chanBot * (1 - cfg.slBufferPct / 100)
                : chanTop * (1 + cfg.slBufferPct / 100);

            final trade = GridTrade(
              id: tradeId++, direction: dir,
              entryPrice: lvlPrice, qty: qty,
              notionalUSDT: notional,
              tpPrice: tpPrice, slPrice: slPrice,
              levelIndex: lvl, entryTime: c5.time,
            );
            allTrades.add(trade);
            grid.openLevelIndices.add(lvl);
          }
        }

        // ── Update drawdown ─────────────────────────────────────────────────
        _trackDD(equity, allTrades, c5.close, peakEq, (p, d) { peakEq = p; maxDd = d; });
      } // end 5m loop
    } // end 45m loop

    // ── 4. Force-close remaining open trades at final price ──────────────────
    final lastClose = c5m.last.close;
    for (final t in allTrades.where((t) => t.isOpen)) {
      t.isOpen     = false;
      t.exitPrice  = lastClose;
      t.exitTime   = c5m.last.time;
      t.exitReason = 'END_OF_DATA';
      equity += t.rawPnl * cfg.leverage - _comm(t.notionalUSDT * cfg.leverage) * 2;
    }

    // ── 5. Print report ───────────────────────────────────────────────────────
    _printReport(allTrades, equity, maxDd, c5m.first.time, c5m.last.time);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  double _last5mClose(List<Candle> c5m, DateTime around) {
    for (int i = c5m.length - 1; i >= 0; i--) {
      if (!c5m[i].time.isAfter(around)) return c5m[i].close;
    }
    return c5m.first.close;
  }

  void _closeAll(List<GridTrade> trades, double price, DateTime t, String reason, double equity) {
    for (final tr in trades.where((t) => t.isOpen)) {
      tr.isOpen = false; tr.exitPrice = price; tr.exitTime = t; tr.exitReason = reason;
    }
  }

  void _trackDD(double realizedEq, List<GridTrade> trades, double curPrice,
      double peakEq, void Function(double, double) update) {
    final openPnl = trades.where((t) => t.isOpen).fold(0.0, (s, t) {
      final raw = t.direction == GridDirection.long
          ? (curPrice - t.entryPrice) * t.qty
          : (t.entryPrice - curPrice) * t.qty;
      return s + raw * cfg.leverage;
    });
    final cur = realizedEq + openPnl;
    final peak = max(peakEq, cur);
    final dd   = peak - cur;
    update(peak, dd);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REPORT
  // ─────────────────────────────────────────────────────────────────────────

  void _printReport(
    List<GridTrade> trades, double finalEquity, double maxDd,
    DateTime start, DateTime end,
  ) {
    final closed   = trades.where((t) => t.exitReason != '').toList();
    final wins     = closed.where((t) => t.rawPnl > 0).length;
    final losses   = closed.where((t) => t.rawPnl <= 0).length;
    final tpTrades = closed.where((t) => t.exitReason == 'TP').length;
    final slTrades = closed.where((t) => t.exitReason == 'SL').length;
    final cbTrades = closed.where((t) => t.exitReason == 'CHANNEL_BREAK').length;
    final grTrades = closed.where((t) => t.exitReason == 'GRID_RESET').length;
    final edTrades = closed.where((t) => t.exitReason == 'END_OF_DATA').length;

    final winRate  = closed.isEmpty ? 0.0 : wins / closed.length * 100;
    final avgWin   = wins > 0 ? closed.where((t) => t.rawPnl > 0).fold(0.0, (s, t) => s + t.rawPnl * cfg.leverage) / wins : 0.0;
    final avgLoss  = losses > 0 ? closed.where((t) => t.rawPnl <= 0).fold(0.0, (s, t) => s + t.rawPnl * cfg.leverage).abs() / losses : 0.0;
    final pf       = avgLoss > 0 ? (avgWin * wins) / (avgLoss * losses) : double.infinity;

    // Capital deployed = max concurrent notional (approximate as sum of base notionals)
    final totalDeployed = closed.fold(0.0, (s, t) => s + t.notionalUSDT);
    final avgDeployed   = closed.isEmpty ? cfg.baseNotionalUSDT : totalDeployed / closed.length;
    final returnPct     = avgDeployed > 0 ? finalEquity / (avgDeployed * cfg.leverage) * 100 : 0.0;
    final ddPct         = avgDeployed > 0 ? maxDd / (avgDeployed * cfg.leverage) * 100 : 0.0;
    final calmar        = ddPct.abs() > 0 ? returnPct / ddPct.abs() : 0.0;

    // Grade
    String grade;
    if (returnPct >= 30 && ddPct.abs() < 10 && winRate >= 55) grade = 'A ★★★';
    else if (returnPct >= 20 && ddPct.abs() < 15 && winRate >= 50) grade = 'B ★★';
    else if (returnPct >= 10 && ddPct.abs() < 25) grade = 'C ★';
    else if (returnPct > 0) grade = 'D';
    else grade = 'F ✗';

    final sep = '═' * 68;
    print('\n╔$sep╗');
    print('║${_c('GRID / MARTINGALE SR ZONE BACKTEST — ${cfg.symbol}', 68)}║');
    print('╠$sep╣');
    print('║${_c('Period: ${_fmtDate(start)} → ${_fmtDate(end)}', 68)}║');
    print('╠$sep╣');

    // Settings
    print('║  SETTINGS${' ' * 58}║');
    print('║  45m HTF (from 15m) + 5m execution · Grid levels: ${cfg.gridLevels}${' ' * (15 - cfg.gridLevels.toString().length)}║');
    print('║  Base notional: \$${cfg.baseNotionalUSDT.toStringAsFixed(0)}  Leverage: ${cfg.leverage}x  Martingale: ${cfg.martingale ? 'ON (×${cfg.martingaleMultiplier})' : 'OFF'}${' ' * 12}║');
    print('║  Max open levels: ${cfg.maxOpenLevels}  SL buffer: ${cfg.slBufferPct}%  Min channel: ${cfg.minChannelWidthPct}%${' ' * 10}║');
    print('╠$sep╣');

    // Stats
    print('║  PERFORMANCE${' ' * 55}║');
    print('║  Total Trades : ${closed.length.toString().padRight(10)} Open at End : $edTrades${' ' * 30}║');
    print('║  Wins         : ${wins.toString().padRight(10)} Losses      : $losses${' ' * 30}║');
    print('║  Win Rate     : ${winRate.toStringAsFixed(1).padRight(8)}%${' ' * 38}║');
    print('║  TP exits     : ${tpTrades.toString().padRight(10)} SL exits    : $slTrades${' ' * 30}║');
    print('║  Channel break: ${cbTrades.toString().padRight(10)} Grid resets : $grTrades${' ' * 29}║');
    print('╠$sep╣');
    print('║  PnL METRICS${' ' * 55}║');
    print('║  Net PnL (USDT)   : ${_fmtF(finalEquity, 12)} Return %   : ${returnPct.toStringAsFixed(2).padRight(10)}%║');
    print('║  Avg Win  (USDT)  : ${_fmtF(avgWin, 12)} Avg Loss   : ${_fmtF(-avgLoss, 12)}║');
    print('║  Profit Factor    : ${pf.isInfinite ? '∞   ' : pf.toStringAsFixed(2).padRight(12)} Max DD %   : ${ddPct.abs().toStringAsFixed(2).padRight(10)}%║');
    print('║  Calmar Ratio     : ${calmar.toStringAsFixed(2).padRight(51)}║');
    print('╠$sep╣');
    print('║  GRADE: $grade${' ' * (59 - grade.length)}║');
    print('╚$sep╝\n');

    // Trade log (last 30)
    print('── TRADE LOG (last 30) ──────────────────────────────────────────');
    print('${'ID'.padLeft(4)}  ${'Dir'.padRight(5)}  ${'Entry'.padRight(9)}  ${'Exit'.padRight(9)}'
        '  ${'PnL\$'.padRight(8)}  ${'Reason'.padRight(13)}  Time');
    print('─' * 80);
    final start30 = closed.length > 30 ? closed.length - 30 : 0;
    for (final t in closed.sublist(start30)) {
      final pnl     = t.rawPnl * cfg.leverage;
      final sign    = pnl >= 0 ? '+' : '';
      final dirStr  = t.direction == GridDirection.long ? 'LONG ' : 'SHORT';
      final timeStr = t.exitTime != null ? _fmtDate(t.exitTime!) : '-';
      print('${t.id.toString().padLeft(4)}  $dirStr  '
          '${t.entryPrice.toStringAsFixed(3).padRight(9)}  '
          '${t.exitPrice.toStringAsFixed(3).padRight(9)}  '
          '${('$sign${pnl.toStringAsFixed(2)}').padRight(8)}  '
          '${t.exitReason.padRight(13)}  $timeStr');
    }
    print('');
  }

  String _c(String s, int w) {
    final pad = w - s.length;
    final l = pad ~/ 2; final r = pad - l;
    return ' ' * l + s + ' ' * r;
  }

  String _fmtF(double v, int w) {
    final s = (v >= 0 ? '+' : '') + v.toStringAsFixed(2);
    return s.padRight(w);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  final backtester = GridBacktester(GridConfig(
    symbol:               'SOLUSDT',
    csv15m:               '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv',
    csv5m:                '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv',
    gridLevels:           5,
    baseNotionalUSDT:     20.0,     // $20 base per unit (before leverage)
    leverage:             5.0,
    martingale:           true,
    martingaleMultiplier: 1.5,      // each deeper level 50% larger
    maxOpenLevels:        3,         // max 3 concurrent positions
    commissionPct:        0.05,
    slBufferPct:          0.3,       // SL 0.3% beyond channel edge
    srDetectionLength:    10,
    srMargin:             2.0,
    sfiPeriod:            10,
    sfiMultiplier:        1.7,
    minChannelWidthPct:   0.8,       // ignore narrow channels < 0.8%
  ));

  backtester.run();
}
