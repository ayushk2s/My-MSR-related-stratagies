// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';

import 'backtest_msr_upgraded.dart' as bt;
import 'model.dart';

// ============================================================================
// MULTI-ASSET SCAN
// Discovers all CSV pairs in the 5m / 15m folders, runs the optimised
// BacktestConfig on every asset, then prints a ranked comparison report.
// ============================================================================

const _dir5m  = '/Users/ayush/Desktop/candlestick data/5m';
const _dir15m = '/Users/ayush/Desktop/candlestick data/15m';

// ── Optimised filter settings (tuned on SOLUSDT) ─────────────────────────────
// Change these to test different parameter sets across all assets at once.
const _blockHours      = [4, 11, 13];   // UTC hours with historically poor WR
const _minVolumeRatio  = 0.8;           // entry vol >= 80% of 20-bar avg
const _volumeAvgPeriod = 20;
const _minNaturalRR    = 0.8;           // skip if TP1/stop ratio < 0.8
const _maxAtrPct       = 1.2;           // skip if ATR > 1.2% of price
const _blockMonths     = [7];           // July consistently negative across assets
const _maxConsecLosses = 3;             // circuit breaker: pause after 3 losses
const _coolingBars     = 48;            // ~4 hours cooldown on 5m bars
const _tp1AtrMult      = 1.5;           // ATR multiplier for TP1
const _riskPct         = 20.0;          // % of balance per trade
const _leverage        = 10.0;

// ============================================================================
// RESULT CONTAINER
// ============================================================================

class AssetResult {
  final String   symbol;
  final int      trades;
  final int      wins;
  final int      losses;
  final double   netPnl;
  final double   returnPct;
  final double   annReturn;
  final double   maxDdPct;
  final double   winRate;
  final double   profitFactor;
  final double   tp1HitRate;
  final double   sharpe;
  final double   calmar;
  final double   expectancy;
  final double   avgWin;
  final double   avgLoss;
  final String   period;
  final String   bestMonth;
  final String   worstMonth;
  final List<bt.BtTrade> tradeList;

  AssetResult({
    required this.symbol,
    required this.trades,
    required this.wins,
    required this.losses,
    required this.netPnl,
    required this.returnPct,
    required this.annReturn,
    required this.maxDdPct,
    required this.winRate,
    required this.profitFactor,
    required this.tp1HitRate,
    required this.sharpe,
    required this.calmar,
    required this.expectancy,
    required this.avgWin,
    required this.avgLoss,
    required this.period,
    required this.bestMonth,
    required this.worstMonth,
    required this.tradeList,
  });

  String get grade {
    if (winRate >= 45 && profitFactor >= 1.4 && returnPct > 0) return 'A  ★★★';
    if (winRate >= 38 && profitFactor >= 1.2 && returnPct > 0) return 'B  ★★ ';
    if (returnPct > 0)                                          return 'C  ★  ';
    return 'D      ';
  }
}

// ============================================================================
// COMPUTE METRICS FROM TRADE LIST
// ============================================================================

AssetResult _computeResult(
  String symbol,
  List<bt.BtTrade> trades,
  List<Candle> candles,
  double initialBalance,
) {
  if (trades.isEmpty) {
    return AssetResult(
      symbol: symbol, trades: 0, wins: 0, losses: 0,
      netPnl: 0, returnPct: 0, annReturn: 0, maxDdPct: 0,
      winRate: 0, profitFactor: 0, tp1HitRate: 0, sharpe: 0, calmar: 0,
      expectancy: 0, avgWin: 0, avgLoss: 0,
      period: '', bestMonth: '', worstMonth: '',
      tradeList: [],
    );
  }

  final wins   = trades.where((t) => t.isWin).toList();
  final losses = trades.where((t) => !t.isWin).toList();
  final netPnl = trades.fold(0.0, (s, t) => s + t.totalPnl);
  final retPct = (netPnl / initialBalance) * 100.0;

  // Drawdown
  double peak = initialBalance, runBal = initialBalance, maxDd = 0.0;
  for (final t in trades) {
    runBal += t.totalPnl;
    if (runBal > peak) peak = runBal;
    final dd = peak - runBal;
    if (dd > maxDd) maxDd = dd;
  }
  final maxDdPct = peak > 0 ? (maxDd / peak) * 100.0 : 0.0;

  // Annualised return
  final dur  = candles.last.time.difference(candles.first.time);
  final yrs  = dur.inHours / (365.0 * 24.0);
  final annR = yrs > 0 ? retPct / yrs : retPct;

  // Sharpe (per-trade returns)
  final rets  = trades.map((t) => t.pnlPct).toList();
  final meanR = rets.reduce((a, b) => a + b) / rets.length;
  final stdR  = sqrt(rets.map((r) => pow(r - meanR, 2)).reduce((a, b) => a + b) / rets.length);
  final sharpe = stdR > 0 ? meanR / stdR : 0.0;

  // Calmar
  final calmar = maxDdPct > 0 ? annR / maxDdPct : 0.0;

  // Profit factor
  final winPnl  = wins.fold(0.0, (s, t) => s + t.totalPnl);
  final lossPnl = losses.fold(0.0, (s, t) => s + t.totalPnl.abs());
  final pf      = lossPnl > 0 ? winPnl / lossPnl : (winPnl > 0 ? 99.0 : 0.0);

  // TP1 hit rate
  final tp1Hit  = trades.where((t) => t.tp1Hit).length;

  // Avg win / loss
  final avgWin  = wins.isEmpty   ? 0.0 : winPnl  / wins.length;
  final avgLoss = losses.isEmpty ? 0.0 : losses.fold(0.0, (s, t) => s + t.totalPnl) / losses.length;

  // Period
  final p = '${_d(candles.first.time)} → ${_d(candles.last.time)}';

  // Monthly breakdown for best/worst
  final monthly = <String, double>{};
  for (final t in trades) {
    final key = '${t.exitTime.year}-${t.exitTime.month.toString().padLeft(2,'0')}';
    monthly[key] = (monthly[key] ?? 0) + t.totalPnl;
  }
  String bestM = '', worstM = '';
  if (monthly.isNotEmpty) {
    bestM  = monthly.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    worstM = monthly.entries.reduce((a, b) => a.value < b.value ? a : b).key;
  }

  return AssetResult(
    symbol:       symbol,
    trades:       trades.length,
    wins:         wins.length,
    losses:       losses.length,
    netPnl:       netPnl,
    returnPct:    retPct,
    annReturn:    annR,
    maxDdPct:     maxDdPct,
    winRate:      wins.length / trades.length * 100.0,
    profitFactor: pf,
    tp1HitRate:   tp1Hit / trades.length * 100.0,
    sharpe:       sharpe,
    calmar:       calmar,
    expectancy:   netPnl / trades.length,
    avgWin:       avgWin,
    avgLoss:      avgLoss,
    period:       p,
    bestMonth:    bestM,
    worstMonth:   worstM,
    tradeList:    trades,
  );
}

// ============================================================================
// REPORT PRINTER
// ============================================================================

void _printReport(List<AssetResult> results, double initialBalance) {
  // Sort: profitable first (by net PnL desc), then losing (by PnL desc)
  results.sort((a, b) => b.netPnl.compareTo(a.netPnl));

  final profitable = results.where((r) => r.netPnl > 0).toList();
  final losing     = results.where((r) => r.netPnl <= 0 && r.trades > 0).toList();
  final noTrades   = results.where((r) => r.trades == 0).toList();

  // ── 1. RANKED SUMMARY TABLE ─────────────────────────────────────────────
  const w = 115;
  print('\n');
  print('╔${'═' * w}╗');
  _bx(w, '');
  _bx(w, '   MULTI-ASSET STRATEGY SCAN  ─  SFI + SR Zones  |  5m Entry · 15m SR Detection');
  _bx(w, '   Filters: blockHours=$_blockHours  |  vol≥${_minVolumeRatio}×avg  |  R:R≥$_minNaturalRR  |  ATR%≤$_maxAtrPct  |  blockMonths=$_blockMonths  |  circuit=$_maxConsecLosses L/$_coolingBars b');
  _bx(w, '   Risk: ${_riskPct.toStringAsFixed(0)}% per trade  |  Leverage: ${_leverage.toStringAsFixed(0)}×  |  InitBalance: \$${initialBalance.toStringAsFixed(0)}');
  _bx(w, '');
  print('╠${'═' * w}╣');
  _bx(w, '   RANKED RESULTS  (${results.where((r) => r.trades > 0).length} assets traded  ·  ${profitable.length} profitable  ·  ${losing.length} losing)');
  print('╠${'═' * w}╣');
  // Header
  final hdr = '  ${'Rank'.padRight(5)} ${'Symbol'.padRight(12)} ${'Trades'.padRight(7)} ${'WR%'.padRight(7)} ${'PF'.padRight(6)} '
              '${'Net PnL'.padRight(13)} ${'Return%'.padRight(9)} ${'AnnRet%'.padRight(9)} ${'MaxDD%'.padRight(8)} '
              '${'Sharpe'.padRight(8)} ${'TP1%'.padRight(6)} ${'Grade'.padRight(8)}';
  print('║${hdr.padRight(w)}║');
  print('╠${'═' * w}╣');

  int rank = 1;
  for (final r in results) {
    if (r.trades == 0) continue;
    final sign = r.netPnl >= 0 ? '+' : '';
    final row = '  ${rank.toString().padRight(5)} '
        '${r.symbol.padRight(12)} '
        '${r.trades.toString().padRight(7)} '
        '${_f1(r.winRate).padRight(7)} '
        '${_f2(r.profitFactor).padRight(6)} '
        '${'${sign}\$${_f2(r.netPnl.abs())} '.padRight(13)} '
        '${'${sign}${_f2(r.returnPct)}%'.padRight(9)} '
        '${'${r.annReturn >= 0 ? '+' : ''}${_f2(r.annReturn)}%'.padRight(9)} '
        '${'-${_f2(r.maxDdPct)}%'.padRight(8)} '
        '${_f2(r.sharpe).padRight(8)} '
        '${_f1(r.tp1HitRate).padRight(6)} '
        '${r.grade}';
    print('║${row.padRight(w)}║');
    rank++;
  }

  if (noTrades.isNotEmpty) {
    print('╠${'═' * w}╣');
    _bx(w, '   NO TRADES (filters too strict for these assets): ${noTrades.map((r) => r.symbol).join(', ')}');
  }
  print('╠${'═' * w}╣');

  // ── 2. AGGREGATE STATS ────────────────────────────────────────────────────
  final traded = results.where((r) => r.trades > 0).toList();
  if (traded.isNotEmpty) {
    final totalTrades  = traded.fold(0, (s, r) => s + r.trades);
    final totalPnl     = traded.fold(0.0, (s, r) => s + r.netPnl);
    final avgWR        = traded.fold(0.0, (s, r) => s + r.winRate) / traded.length;
    final avgPF        = traded.fold(0.0, (s, r) => s + r.profitFactor) / traded.length;
    final avgRet       = traded.fold(0.0, (s, r) => s + r.returnPct) / traded.length;
    final avgDD        = traded.fold(0.0, (s, r) => s + r.maxDdPct) / traded.length;
    final bestAsset    = traded.reduce((a, b) => a.netPnl > b.netPnl ? a : b);
    final worstAsset   = traded.reduce((a, b) => a.netPnl < b.netPnl ? a : b);

    _bx(w, '   AGGREGATE ACROSS ALL ASSETS');
    print('╠${'═' * w}╣');
    _bxkv(w, 'Total trades (all assets)',  '$totalTrades');
    _bxkv(w, 'Profitable assets',          '${profitable.length} / ${traded.length}');
    _bxkv(w, 'Combined net PnL',           '${totalPnl >= 0 ? '+' : ''}\$${_f2(totalPnl)}  (if \$${_f2(initialBalance)} deployed on each)');
    _bxkv(w, 'Avg win rate',               '${_f1(avgWR)}%');
    _bxkv(w, 'Avg profit factor',          _f2(avgPF));
    _bxkv(w, 'Avg return',                 '${avgRet >= 0 ? '+' : ''}${_f2(avgRet)}%');
    _bxkv(w, 'Avg max drawdown',           '-${_f2(avgDD)}%');
    _bxkv(w, 'Best asset',                 '${bestAsset.symbol}  ${bestAsset.netPnl >= 0 ? '+' : ''}\$${_f2(bestAsset.netPnl)}  (${_f2(bestAsset.returnPct)}%)');
    _bxkv(w, 'Worst asset',                '${worstAsset.symbol}  ${worstAsset.netPnl >= 0 ? '+' : ''}\$${_f2(worstAsset.netPnl)}  (${_f2(worstAsset.returnPct)}%)');
    print('╠${'═' * w}╣');
  }

  // ── 3. MONTHLY BREAKDOWN PER PROFITABLE ASSET ─────────────────────────────
  _bx(w, '   MONTHLY PnL HEATMAP  (profitable assets only)');
  print('╠${'═' * w}╣');

  // Collect all months across all assets
  final allMonths = <String>{};
  for (final r in profitable) {
    for (final t in r.tradeList) {
      allMonths.add('${t.exitTime.year}-${t.exitTime.month.toString().padLeft(2,'0')}');
    }
  }
  final months = allMonths.toList()..sort();

  if (profitable.isNotEmpty && months.isNotEmpty) {
    // Header row: months
    final monthCols = months.map((m) => m.substring(5)).toList(); // "01","02",...
    final hdrRow = '  ${'Symbol'.padRight(12)}' + monthCols.map((m) => m.padLeft(8)).join('') + '  ${'Total'.padLeft(10)}';
    print('║${hdrRow.padRight(w)}║');
    print('╠${'═' * w}╣');

    for (final r in profitable) {
      final monthly = <String, double>{};
      for (final t in r.tradeList) {
        final key = '${t.exitTime.year}-${t.exitTime.month.toString().padLeft(2,'0')}';
        monthly[key] = (monthly[key] ?? 0) + t.totalPnl;
      }
      final cells = months.map((m) {
        final v = monthly[m];
        if (v == null) return '       -';
        final s = '${v >= 0 ? '+' : ''}${_f0(v)}';
        return s.padLeft(8);
      }).join('');
      final total = '${r.netPnl >= 0 ? '+' : ''}${_f0(r.netPnl)}';
      final row = '  ${r.symbol.padRight(12)}$cells  ${total.padLeft(10)}';
      print('║${row.padRight(w)}║');
    }
    print('╠${'═' * w}╣');
  }

  // ── 4. WIN RATE & TRADE COUNT TABLE ──────────────────────────────────────
  _bx(w, '   ENTRY QUALITY  (per profitable asset)');
  print('╠${'═' * w}╣');
  final eHdr = '  ${'Symbol'.padRight(12)} ${'Trades'.padRight(8)} ${'Wins'.padRight(6)} ${'WR%'.padRight(7)} '
               '${'PF'.padRight(6)} ${'Exp\$/trade'.padRight(12)} ${'AvgWin\$'.padRight(10)} ${'AvgLoss\$'.padRight(10)} ${'TP1%'.padRight(6)} ${'BestMon'.padRight(8)} ${'WorstMon'}';
  print('║${eHdr.padRight(w)}║');
  print('╠${'═' * w}╣');
  for (final r in profitable) {
    final row = '  ${r.symbol.padRight(12)} '
        '${r.trades.toString().padRight(8)} '
        '${r.wins.toString().padRight(6)} '
        '${_f1(r.winRate).padRight(7)} '
        '${_f2(r.profitFactor).padRight(6)} '
        '${('${r.expectancy >= 0 ? '+' : ''}\$${_f2(r.expectancy)}').padRight(12)} '
        '${('+\$${_f2(r.avgWin)}').padRight(10)} '
        '${'${_f2(r.avgLoss)}'.padRight(10)} '
        '${_f1(r.tp1HitRate).padRight(6)} '
        '${r.bestMonth.padRight(8)} '
        '${r.worstMonth}';
    print('║${row.padRight(w)}║');
  }
  print('╠${'═' * w}╣');

  // ── 5. PRIORITY LIST ─────────────────────────────────────────────────────
  _bx(w, '   RECOMMENDATIONS');
  print('╠${'═' * w}╣');
  if (profitable.isEmpty) {
    _bx(w, '   No profitable assets found with current filter settings.');
    _bx(w, '   Try loosening: blockHours, minVolumeRatio, or minNaturalRR.');
  } else {
    // Top picks: good WR + good PF + reasonable trade count
    final topPicks = profitable
        .where((r) => r.trades >= 5 && r.profitFactor >= 1.1)
        .toList()
      ..sort((a, b) => b.profitFactor.compareTo(a.profitFactor));
    _bx(w, '   TOP PICKS (≥5 trades, PF≥1.1, sorted by Profit Factor):');
    for (int i = 0; i < min(5, topPicks.length); i++) {
      final r = topPicks[i];
      _bx(w, '   ${(i + 1).toString().padLeft(2)}.  ${r.symbol.padRight(12)}  PF=${_f2(r.profitFactor)}  WR=${_f1(r.winRate)}%  '
          'Return=${r.returnPct >= 0 ? '+' : ''}${_f2(r.returnPct)}%  DD=-${_f2(r.maxDdPct)}%  Trades=${r.trades}');
    }
    final avoid = losing.where((r) => r.trades >= 5 && r.profitFactor < 0.8).toList()
      ..sort((a, b) => a.profitFactor.compareTo(b.profitFactor));
    if (avoid.isNotEmpty) {
      print('╠${'═' * w}╣');
      _bx(w, '   AVOID (PF<0.8, worst performers):');
      for (int i = 0; i < min(3, avoid.length); i++) {
        final r = avoid[i];
        _bx(w, '   ${(i + 1).toString().padLeft(2)}.  ${r.symbol.padRight(12)}  PF=${_f2(r.profitFactor)}  WR=${_f1(r.winRate)}%  '
            'Return=${_f2(r.returnPct)}%  Trades=${r.trades}');
      }
    }
  }
  _bx(w, '');
  print('╚${'═' * w}╝');
  print('');
}

// ── Helpers ─────────────────────────────────────────────────────────────────

void _bx(int w, String s)             => print('║${s.padRight(w)}║');
void _bxkv(int w, String k, String v) => _bx(w, '   ${k.padRight(30)} $v');
String _d(DateTime dt)  => '${dt.year}-${_p2(dt.month)}-${_p2(dt.day)}';
String _p2(int n)       => n.toString().padLeft(2, '0');
String _f0(double v)    => v.toStringAsFixed(0);
String _f1(double v)    => v.toStringAsFixed(1);
String _f2(double v)    => v.toStringAsFixed(2);

// ============================================================================
// MAIN
// ============================================================================

void main() {
  const initialBalance = 10000.0;
  const dir5m  = _dir5m;
  const dir15m = _dir15m;

  // ── Discover assets ───────────────────────────────────────────────────────
  final files5m = Directory(dir5m)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('5m.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('\n  Discovered ${files5m.length} assets in $dir5m');
  print('  Running backtest on each...\n');

  final results = <AssetResult>[];

  for (final file5m in files5m) {
    final fname  = file5m.uri.pathSegments.last;            // e.g. ADAUSDT5m.csv
    final symbol = fname.replaceAll('5m.csv', '');          // ADAUSDT
    final path15m = '$dir15m/${symbol}15m.csv';

    stdout.write('  [$symbol]  loading...');

    if (!File(path15m).existsSync()) {
      print('  ⚠ no 15m file — skipping');
      results.add(AssetResult(
        symbol: symbol, trades: 0, wins: 0, losses: 0,
        netPnl: 0, returnPct: 0, annReturn: 0, maxDdPct: 0,
        winRate: 0, profitFactor: 0, tp1HitRate: 0, sharpe: 0, calmar: 0,
        expectancy: 0, avgWin: 0, avgLoss: 0,
        period: '', bestMonth: '', worstMonth: '',
        tradeList: [],
      ));
      continue;
    }

    // Load candles
    final candles5m = bt.loadCsv(file5m.path);
    final raw15m    = bt.loadCsv(path15m);

    if (candles5m.isEmpty || raw15m.isEmpty) {
      print(' empty data — skipping');
      continue;
    }

    final htfCandles = raw15m; // use 15m directly (45m zones too coarse for 5m touches)

    stdout.write(' ${candles5m.length} 5m · ${htfCandles.length} 15m candles  ');

    // Build config for this asset
    final config = bt.BacktestConfig(
      csvPath:          file5m.path,
      symbol:           symbol,
      sfiPeriod:        10,
      sfiMultiplier:    1.7,
      srDetectionLength: 15,
      srMargin:         2.0,
      atrPeriod:        14,
      tp1AtrMultiplier: _tp1AtrMult,
      tp1ClosePct:      0.1,
      initialBalance:   initialBalance,
      riskPctPerTrade:  _riskPct,
      leverage:         _leverage,
      takerFeePct:      0.04,
      slippagePct:      0.02,
      candleWindow:     1000,
      warmupBars:       100,
      htfCsvPath:       path15m,
      htfBuild45m:      false,
      htfCandleWindow:  300,
      htfTrendFilter:   false,
      htfTrendMaPeriod: 50,
      blockHours:       _blockHours,
      minVolumeRatio:   _minVolumeRatio,
      volumeAvgPeriod:  _volumeAvgPeriod,
      minNaturalRR:     _minNaturalRR,
      maxAtrPct:        _maxAtrPct,
      blockMonths:      _blockMonths,
      maxConsecLosses:  _maxConsecLosses,
      coolingBars:      _coolingBars,
    );

    final trades = bt.Backtester(config).run(candles5m, htfCandles: htfCandles);
    print('→ ${trades.length} trades');

    results.add(_computeResult(symbol, trades, candles5m, initialBalance));
  }

  print('\n  All assets done. Generating report...\n');
  _printReport(results, initialBalance);
}
