import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

import 'model.dart';
import 'support_resistance_2.dart';

// ============================================================================
// CONFIG  (mirrors main.dart BotConfig)
// ============================================================================

class BacktestConfig {
  final String symbol;
  final String interval;
  final int    totalCandles;   // total bars to fetch
  final int    windowSize;     // bars per indicator window (= live bot candleLimit)
  final int    warmupBars;     // skip first N bars while indicators stabilise

  final double initialCapital;
  final double leverage;
  final double positionSizePct;
  final int    quantityPrecision;

  final int    sfiPeriod;
  final double sfiMultiplier;
  final int    srDetectionLength;
  final double srMargin;

  const BacktestConfig({
    this.symbol            = 'SOLUSDT',
    this.interval          = '5m',
    this.totalCandles      = 3000,
    this.windowSize        = 1000,
    this.warmupBars        = 150,
    this.initialCapital    = 1000.0,
    this.leverage          = 10.0,
    this.positionSizePct   = 10.0,
    this.quantityPrecision = 1,
    this.sfiPeriod         = 10,
    this.sfiMultiplier     = 1.7,
    this.srDetectionLength = 15,
    this.srMargin          = 2.0,
  });
}

// ============================================================================
// TRADE STATE  (mirrors main.dart ActiveTrade)
// ============================================================================

enum TradeDirection { long, short }

class ProfitTarget {
  final double price;
  bool reached;
  ProfitTarget(this.price) : reached = false;
}

class ActiveTrade {
  final int            id;
  final TradeDirection direction;
  final DateTime       entryTime;
  final double         entryPrice;
  final double         totalQty;
  final List<ProfitTarget> targets;
  final String         zoneInfo;

  double remainingQty;
  bool   tp1Hit    = false;
  bool   tp2Hit    = false;
  double currentSl;
  double realizedPnl = 0.0;

  // Exit info
  String   exitReason = '';
  double   exitPrice  = 0.0;
  DateTime? exitTime;

  ActiveTrade({
    required this.id,
    required this.direction,
    required this.entryTime,
    required this.entryPrice,
    required this.totalQty,
    required this.targets,
    required this.zoneInfo,
    required this.currentSl,
  }) : remainingQty = totalQty;
}

// ============================================================================
// SFI INDICATOR  (exact copy from main.dart)
// ============================================================================

class SfiSignal {
  final double upLine;
  final double dnLine;
  final int    trend;
  final bool   buySignal;
  final bool   sellSignal;
  SfiSignal({required this.upLine, required this.dnLine, required this.trend,
             required this.buySignal, required this.sellSignal});
}

class SfiIndicator {
  List<double> _tr(List<Candle> c) {
    return List.generate(c.length, (i) {
      final prev = i == 0 ? c[i].close : c[i - 1].close;
      return [
        c[i].high - c[i].low,
        (c[i].high - prev).abs(),
        (c[i].low  - prev).abs(),
      ].reduce(max);
    });
  }

  List<double> _atr(List<double> tr, int period) {
    final atr = <double>[];
    double sum = 0;
    for (int i = 0; i < tr.length; i++) {
      if (i < period)       { sum += tr[i]; atr.add(sum / (i + 1)); }
      else if (i == period) { atr.add(tr.sublist(0, period).reduce((a, b) => a + b) / period); }
      else                  { atr.add(((atr[i - 1] * (period - 1)) + tr[i]) / period); }
    }
    return atr;
  }

  List<SfiSignal> calculateSfiMagic(List<Candle> candles, {int period = 10, double multiplier = 1.7}) {
    final tr  = _tr(candles);
    final atr = _atr(tr, period);
    final out = <SfiSignal>[];
    if (candles.isEmpty) return out;

    double prevUp = candles[0].ohlc4 - multiplier * (atr.isNotEmpty ? atr[0] : 0);
    double prevDn = candles[0].ohlc4 + multiplier * (atr.isNotEmpty ? atr[0] : 0);
    int    prevT  = 1;

    for (int i = 0; i < candles.length; i++) {
      final c  = candles[i];
      final a  = i < atr.length ? atr[i] : (atr.isNotEmpty ? atr.last : 0.0);
      final rU = c.ohlc4 - multiplier * a;
      final rD = c.ohlc4 + multiplier * a;
      final up = i > 0 ? (candles[i-1].close > prevUp ? max(rU, prevUp) : rU) : rU;
      final dn = i > 0 ? (candles[i-1].close < prevDn ? min(rD, prevDn) : rD) : rD;

      int t = prevT;
      if (prevT == -1 && c.close > prevDn)  t = 1;
      else if (prevT == 1 && c.close < prevUp) t = -1;

      out.add(SfiSignal(upLine: up, dnLine: dn, trend: t,
          buySignal:  prevT == -1 && t == 1,
          sellSignal: prevT == 1  && t == -1));
      prevUp = up; prevDn = dn; prevT = t;
    }
    return out;
  }

  Map<String, dynamic> loop(List<Candle> candles) {
    const atrMultipliers = [2.0, 4.5, 7.0, 9.0, 11.0];
    final tr      = _tr(candles);
    final atr14   = _atr(tr, 14);
    final sigs    = calculateSfiMagic(candles);
    var   lastDir = 1;
    var   lastEntry = 0.0;
    var   lastTargets = <ProfitTarget>[];

    for (int i = 0; i < candles.length; i++) {
      final s = sigs[i];
      final a = i < atr14.length ? atr14[i] : (atr14.isNotEmpty ? atr14.last : 0.0);
      if (s.buySignal || s.sellSignal) {
        lastDir     = s.buySignal ? 1 : -1;
        lastEntry   = candles[i].close;
        lastTargets = atrMultipliers.map((m) => ProfitTarget(
            lastDir == 1 ? lastEntry + m * a : lastEntry - m * a)).toList();
      }
    }
    if (lastTargets.isEmpty) return {};
    final last = sigs.last;
    return {
      'targets':    lastTargets,
      'stoploss':   last.dnLine,
      'nexttarget': last.upLine,
    };
  }
}

// ============================================================================
// MULTI-PAGE CANDLE FETCH
// ============================================================================

const _intervalMs = {
  '1m': 60000, '3m': 180000, '5m': 300000, '15m': 900000,
  '30m': 1800000, '1h': 3600000, '4h': 14400000, '1d': 86400000,
};

Future<List<Candle>> fetchHistoricalCandles({
  required String symbol,
  required String interval,
  required int    totalBars,
}) async {
  final step = _intervalMs[interval] ?? 300000;
  final all  = <Candle>[];
  int?  endTimeMs;

  while (all.length < totalBars) {
    final limit = min(1000, totalBars - all.length);
    var url = 'https://fapi.binance.com/fapi/v1/klines'
              '?symbol=$symbol&interval=$interval&limit=$limit';
    if (endTimeMs != null) url += '&endTime=$endTimeMs';

    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) throw Exception('Binance fetch failed: ${res.body}');

    final data = jsonDecode(res.body) as List;
    if (data.isEmpty) break;

    final page = data.map((k) {
      final row = k as List;
      return Candle(
        DateTime.fromMillisecondsSinceEpoch(row[0] as int, isUtc: true),
        double.parse(row[1].toString()),
        double.parse(row[2].toString()),
        double.parse(row[3].toString()),
        double.parse(row[4].toString()),
        double.parse(row[5].toString()),
        0,
      );
    }).toList();

    all.insertAll(0, page);
    endTimeMs = ((data.first as List)[0] as int) - step;
    if (data.length < limit) break;
    await Future.delayed(const Duration(milliseconds: 250));
    print('[FETCH] ${all.length}/$totalBars candles...');
  }

  return all.asMap().entries
      .map((e) => Candle(e.value.time, e.value.open, e.value.high,
                         e.value.low, e.value.close, e.value.volume, e.key))
      .toList();
}

// ============================================================================
// BACKTEST ENGINE
// ============================================================================

class Backtest {
  final BacktestConfig cfg;
  final _sfi = SfiIndicator();

  ActiveTrade? _open;
  int    _tradeId = 0;
  double _capital;

  // Session stats
  int    _totalTrades = 0;
  int    _wins        = 0;
  int    _losses      = 0;
  double _totalPnl    = 0.0;
  final  List<double> _tradePnls = [];

  Backtest(this.cfg) : _capital = cfg.initialCapital;

  // ── helpers ──────────────────────────────────────────────────────

  double _roundQty(double qty) {
    final f = pow(10, cfg.quantityPrecision).toDouble();
    return (qty * f).floorToDouble() / f;
  }

  String _ts(DateTime t) {
    final lt = t.toLocal();
    return '${lt.year}-${_p(lt.month)}-${_p(lt.day)} ${_p(lt.hour)}:${_p(lt.minute)}:${_p(lt.second)}';
  }

  String _p(int v) => v.toString().padLeft(2, '0');

  // ── MANAGE OPEN TRADE  (mirrors main.dart _manageOpenTrades) ─────

  void _manageTrade(SfiSignal sfi, Candle c, int barIndex) {
    if (_open == null) return;
    final trade = _open!;

    // Update trailing SL — after TP1, never let SL go back through entry (breakeven floor)
    if (trade.direction == TradeDirection.long) {
      final rawSl = sfi.upLine;
      trade.currentSl = trade.tp1Hit ? max(rawSl, trade.entryPrice) : rawSl;
    } else {
      final rawSl = sfi.dnLine;
      trade.currentSl = trade.tp1Hit ? min(rawSl, trade.entryPrice) : rawSl;
    }

    // Mark targets reached
    for (final t in trade.targets) {
      if (!t.reached) {
        if (trade.direction == TradeDirection.long  && c.high >= t.price) t.reached = true;
        if (trade.direction == TradeDirection.short && c.low  <= t.price) t.reached = true;
      }
    }

    if (trade.direction == TradeDirection.long) {

      // TP1: close 60% at target[0]
      if (!trade.tp1Hit && trade.targets.isNotEmpty && c.high >= trade.targets[0].price) {
        final qty = _roundQty(trade.totalQty * 0.90);
        if (qty > 0) {
          final pnl = (trade.targets[0].price - trade.entryPrice) * qty;
          trade.realizedPnl += pnl;
          trade.remainingQty = _roundQty(trade.remainingQty - qty);
          trade.tp1Hit = true;
          print('[TP1  ] LONG  #${trade.id} 60% @ ${trade.targets[0].price.toStringAsFixed(4)}'
              '  qty=$qty  pnl=${_fmt(pnl)}');
        }
      }

      // TP2: close 30% at target[1]
      if (trade.tp1Hit && !trade.tp2Hit && trade.targets.length > 1 && c.high >= trade.targets[1].price) {
        final qty = _roundQty(trade.totalQty * 0.05);
        final act = qty <= trade.remainingQty ? qty : trade.remainingQty;
        if (act > 0) {
          final pnl = (trade.targets[1].price - trade.entryPrice) * act;
          trade.realizedPnl += pnl;
          trade.remainingQty = _roundQty(trade.remainingQty - act);
          trade.tp2Hit = true;
          print('[TP2  ] LONG  #${trade.id} 30% @ ${trade.targets[1].price.toStringAsFixed(4)}'
              '  qty=$act  pnl=${_fmt(pnl)}');
        }
      }

      if (trade.remainingQty <= 0) { _close(trade, trade.entryPrice, 'TP_DONE', c.time); return; }

      // SFI flip
      if (sfi.sellSignal) {
        final pnl = (c.close - trade.entryPrice) * trade.remainingQty;
        trade.realizedPnl += pnl;
        _close(trade, c.close, 'SFI_FLIP', c.time);
        return;
      }

      // SL
      if (c.low <= trade.currentSl) {
        final pnl = (trade.currentSl - trade.entryPrice) * trade.remainingQty;
        trade.realizedPnl += pnl;
        _close(trade, trade.currentSl, 'SL', c.time);
        return;
      }

    } else {
      // SHORT

      // TP1: close 60% at target[0]
      if (!trade.tp1Hit && trade.targets.isNotEmpty && c.low <= trade.targets[0].price) {
        final qty = _roundQty(trade.totalQty * 0.90);
        if (qty > 0) {
          final pnl = (trade.entryPrice - trade.targets[0].price) * qty;
          trade.realizedPnl += pnl;
          trade.remainingQty = _roundQty(trade.remainingQty - qty);
          trade.tp1Hit = true;
          print('[TP1  ] SHORT #${trade.id} 60% @ ${trade.targets[0].price.toStringAsFixed(4)}'
              '  qty=$qty  pnl=${_fmt(pnl)}');
        }
      }

      // TP2: close 30% at target[1]
      if (trade.tp1Hit && !trade.tp2Hit && trade.targets.length > 1 && c.low <= trade.targets[1].price) {
        final qty = _roundQty(trade.totalQty * 0.05);
        final act = qty <= trade.remainingQty ? qty : trade.remainingQty;
        if (act > 0) {
          final pnl = (trade.entryPrice - trade.targets[1].price) * act;
          trade.realizedPnl += pnl;
          trade.remainingQty = _roundQty(trade.remainingQty - act);
          trade.tp2Hit = true;
          print('[TP2  ] SHORT #${trade.id} 30% @ ${trade.targets[1].price.toStringAsFixed(4)}'
              '  qty=$act  pnl=${_fmt(pnl)}');
        }
      }

      if (trade.remainingQty <= 0) { _close(trade, trade.entryPrice, 'TP_DONE', c.time); return; }

      // SFI flip
      if (sfi.buySignal) {
        final pnl = (trade.entryPrice - c.close) * trade.remainingQty;
        trade.realizedPnl += pnl;
        _close(trade, c.close, 'SFI_FLIP', c.time);
        return;
      }

      // SL
      if (c.high >= trade.currentSl) {
        final pnl = (trade.entryPrice - trade.currentSl) * trade.remainingQty;
        trade.realizedPnl += pnl;
        _close(trade, trade.currentSl, 'SL', c.time);
        return;
      }
    }
  }

  void _close(ActiveTrade trade, double price, String reason, DateTime time) {
    trade.exitReason = reason;
    trade.exitPrice  = price;
    trade.exitTime   = time;

    final totalPnl = trade.realizedPnl;
    _capital   += totalPnl;
    _totalPnl  += totalPnl;
    _totalTrades++;
    _tradePnls.add(totalPnl);
    if (totalPnl > 0) _wins++; else _losses++;

    final dir  = trade.direction == TradeDirection.long ? 'LONG ' : 'SHORT';
    final sign = totalPnl >= 0 ? '+' : '';
    print('[EXIT ] $dir #${trade.id}  reason=$reason  exitPx=${price.toStringAsFixed(4)}'
        '  totalPnl=$sign\$${totalPnl.toStringAsFixed(4)}'
        '  capital=\$${_capital.toStringAsFixed(2)}'
        '  ${totalPnl >= 0 ? "✓ WIN" : "✗ LOSS"}');
    print('');
    _open = null;
  }

  // ── CHECK ENTRIES  (mirrors main.dart _checkEntries) ────────────

  void _checkEntries({
    required SfiSignal        sfi,
    required Map<String, dynamic> sfiData,
    required Candle           c,
    required List<SRZone>     activeSupports,
    required List<SRZone>     activeResistances,
  }) {
    if (_open != null || sfiData.isEmpty) return;

    final targets = sfiData['targets'] as List<ProfitTarget>;
    if (targets.isEmpty) return;

    // LONG: buy signal + low touches S[0]
    if (sfi.buySignal && activeSupports.isNotEmpty) {
      final zone = activeSupports.first;
      final zoneWidthPct = (zone.boxTop - zone.boxBottom) / c.close;
      if (zoneWidthPct >= 0.003 && c.low >= zone.boxBottom && c.low <= zone.boxTop) {
        final sl = (sfiData['nexttarget'] as double?) ?? sfi.upLine;
        _openTrade(TradeDirection.long, c, zone, sl, targets);
      }
    }

    // SHORT: sell signal + high touches R[0]
    if (sfi.sellSignal && activeResistances.isNotEmpty) {
      final zone = activeResistances.first;
      final zoneWidthPct = (zone.boxTop - zone.boxBottom) / c.close;
      if (zoneWidthPct >= 0.003 && c.high >= zone.boxBottom && c.high <= zone.boxTop) {
        final sl = (sfiData['stoploss'] as double?) ?? sfi.dnLine;
        _openTrade(TradeDirection.short, c, zone, sl, targets);
      }
    }
  }

  void _openTrade(TradeDirection dir, Candle c, SRZone zone, double sl, List<ProfitTarget> targets) {
    final riskUsdt = _capital * (cfg.positionSizePct / 100.0);
    final notional = riskUsdt * cfg.leverage;
    final qty      = _roundQty(notional / c.close);
    if (qty <= 0) return;

    _tradeId++;
    final zoneInfo = '${zone.isResistance ? "RES" : "SUP"} '
                     '${zone.boxBottom.toStringAsFixed(2)}-${zone.boxTop.toStringAsFixed(2)}';

    // Fresh copies of targets for this trade
    final tradeTgts = targets.map((t) => ProfitTarget(t.price)).toList();

    _open = ActiveTrade(
      id:         _tradeId,
      direction:  dir,
      entryTime:  c.time,
      entryPrice: c.close,
      totalQty:   qty,
      targets:    tradeTgts,
      zoneInfo:   zoneInfo,
      currentSl:  sl,
    );

    final dirStr = dir == TradeDirection.long ? 'LONG ' : 'SHORT';
    print('────────────────────────────────────────────────────');
    print('[ENTRY] $dirStr #$_tradeId @ ${c.close.toStringAsFixed(4)}'
        '  qty=$qty  time=${_ts(c.time)}');
    print('        zone=$zoneInfo  SL=${sl.toStringAsFixed(4)}');
    print('        Targets: ${tradeTgts.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');
  }

  // ── MAIN RUN LOOP ─────────────────────────────────────────────────

  Future<void> run(List<Candle> allCandles) async {
    final srIndicator = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength,
      srMargin:        cfg.srMargin,
      avoidFBO:        true,
      checkHist:       true,
      showManip:       true,
      manipMargin:     1.3,
    );

    print('[BT] Running ${allCandles.length} bars  warmup=${cfg.warmupBars}  window=${cfg.windowSize}\n');

    for (int i = cfg.warmupBars; i < allCandles.length; i++) {
      final wStart = i >= cfg.windowSize - 1 ? i - cfg.windowSize + 1 : 0;
      final window = allCandles.sublist(wStart, i + 1);
      final c      = window.last;

      final sigs    = _sfi.calculateSfiMagic(window, period: cfg.sfiPeriod, multiplier: cfg.sfiMultiplier);
      final curSfi  = sigs.last;
      final sfiData = _sfi.loop(window);
      final srResult = srIndicator.calculate(window);

      final activeSupports = srResult.support.where((z) => z.isActive).toList()
          ..sort((a, b) => b.boxRight.compareTo(a.boxRight));
      final activeResistances = srResult.resistance.where((z) => z.isActive).toList()
          ..sort((a, b) => b.boxRight.compareTo(a.boxRight));

      _manageTrade(curSfi, c, i);
      _checkEntries(
        sfi: curSfi, sfiData: sfiData, c: c,
        activeSupports: activeSupports, activeResistances: activeResistances,
      );
    }

    // Force-close any open trade at end of data
    if (_open != null) {
      final last = allCandles.last;
      print('[BT] Force-closing open trade #${_open!.id} at end of data');
      final pnl = _open!.direction == TradeDirection.long
          ? (last.close - _open!.entryPrice) * _open!.remainingQty
          : (_open!.entryPrice - last.close) * _open!.remainingQty;
      _open!.realizedPnl += pnl;
      _close(_open!, last.close, 'END_OF_DATA', last.time);
    }
  }

  // ── OVERALL RESULT ────────────────────────────────────────────────

  void printResult() {
    final sep  = '═' * 60;
    final dash = '─' * 60;
    final wr   = _totalTrades > 0 ? _wins / _totalTrades * 100 : 0.0;
    final best  = _tradePnls.isNotEmpty ? _tradePnls.reduce(max) : 0.0;
    final worst = _tradePnls.isNotEmpty ? _tradePnls.reduce(min) : 0.0;
    final avgPnl = _totalTrades > 0 ? _totalPnl / _totalTrades : 0.0;
    final retPct = ((_capital - cfg.initialCapital) / cfg.initialCapital) * 100;

    print('\n$sep');
    print('  BACKTEST RESULT  ─  ${cfg.symbol}  (${cfg.interval})');
    print(dash);
    print('  Initial Capital : \$${cfg.initialCapital.toStringAsFixed(2)}');
    print('  Final Capital   : \$${_capital.toStringAsFixed(2)}');
    print('  Total Return    : ${retPct >= 0 ? "+" : ""}${retPct.toStringAsFixed(2)}%');
    print('  Total PnL       : ${_fmt(_totalPnl)}');
    print(dash);
    print('  Total Trades    : $_totalTrades');
    print('  Wins            : $_wins   Losses: $_losses   Win Rate: ${wr.toStringAsFixed(1)}%');
    print('  Avg PnL/Trade   : ${_fmt(avgPnl)}');
    print('  Best Trade      : ${_fmt(best)}');
    print('  Worst Trade     : ${_fmt(worst)}');
    print(sep);
  }

  String _fmt(double v) => '${v >= 0 ? "+" : ""}\$${v.toStringAsFixed(4)}';
}

// ============================================================================
// MAIN
// ============================================================================

Future<void> main() async {
  final cfg = BacktestConfig(
    symbol:            'SOLUSDT',
    interval:          '5m',
    totalCandles:      3000,   // ~10 days of 5m bars
    windowSize:        1000,   // must match live bot candleLimit
    warmupBars:        150,
    initialCapital:    1000.0,
    leverage:          10.0,
    positionSizePct:   10.0,
    quantityPrecision: 1,
    sfiPeriod:         10,
    sfiMultiplier:     1.7,
    srDetectionLength: 15,
    srMargin:          2.0,
  );

  print('[BT] Fetching ${cfg.totalCandles} ${cfg.interval} candles for ${cfg.symbol}...');
  final candles = await fetchHistoricalCandles(
    symbol:    cfg.symbol,
    interval:  cfg.interval,
    totalBars: cfg.totalCandles,
  );
  print('[BT] ${candles.length} candles: ${candles.first.time.toLocal()} → ${candles.last.time.toLocal()}\n');

  final bt = Backtest(cfg);
  await bt.run(candles);
  bt.printResult();
}
