import 'dart:async';
import 'dart:math';

import 'model.dart';
import 'support_resistance_2.dart';

import 'msr_asterdex/fetch_candle_data.dart';
import 'msr_asterdex/account_data.dart';
import 'msr_asterdex/future_trade.dart';

// ============================================================================
// CONFIG
// ============================================================================

class BotConfig {
  // ─── ASTERDEX API Credentials ───
  final String apiKey;
  final String secretKey;

  // ─── Trading Pair ───
  final String symbol;
  final String interval;
  final int candleLimit;

  // ─── Risk Management ───
  final double leverage;
  final double positionSizePct;
  final int quantityPrecision;

  // ─── Timing ───
  final Duration loopInterval;

  // ─── SFI Settings ───
  final int sfiPeriod;
  final double sfiMultiplier;

  // ─── SR Settings ───
  final int srDetectionLength;
  final double srMargin;

  /// How many candles back from now to shift the data window.
  /// 0 = live data (normal trading). >0 = historical replay (no alignment wait).
  final int candleOffset;

  const BotConfig({
    required this.apiKey,
    required this.secretKey,
    this.symbol = 'SOLUSDT',
    this.interval = '5m',
    this.candleLimit = 1000,
    this.leverage = 10,
    this.positionSizePct = 2.0,
    this.quantityPrecision = 3,
    this.loopInterval = const Duration(minutes: 5),
    this.sfiPeriod = 10,
    this.sfiMultiplier = 1.7,
    this.srDetectionLength = 15,
    this.srMargin = 2.0,
    this.candleOffset = 0,
  });
}

// ============================================================================
// TRADE STATE
// ============================================================================

enum TradeDirection { long, short }

class ProfitTarget {
  final double price;
  bool reached;
  ProfitTarget(this.price) : reached = false;
}

class ActiveTrade {
  final int id;
  final TradeDirection direction;
  final DateTime entryTime;
  final double entryPrice;
  final double totalQty;
  final List<ProfitTarget> targets; // 5 targets: ATR × [1, 4.5, 7, 9, 11]
  final String zoneInfo;

  double remainingQty;
  bool tp1Hit = false;
  double realizedPnl = 0.0;

  /// SFI trailing stop line — updated every tick.
  /// LONG: upLine (below price, rises with price).
  /// SHORT: dnLine (above price, falls with price).
  double currentSl;

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

  double unrealizedPnl(double currentPrice) {
    if (remainingQty <= 0) return 0.0;
    return direction == TradeDirection.long
        ? (currentPrice - entryPrice) * remainingQty
        : (entryPrice - currentPrice) * remainingQty;
  }

  double totalPnl(double currentPrice) => realizedPnl + unrealizedPnl(currentPrice);

  double totalPnlPct(double currentPrice) {
    double notional = entryPrice * totalQty;
    return notional > 0 ? (totalPnl(currentPrice) / notional) * 100.0 : 0.0;
  }

  @override
  String toString() {
    String dir = direction == TradeDirection.long ? 'LONG' : 'SHORT';
    String tgtStr = targets.map((t) => '${t.price.toStringAsFixed(4)}${t.reached ? "✅" : ""}').join(' | ');
    return '#$id $dir entry=${entryPrice.toStringAsFixed(4)} qty=$totalQty '
        'sl=${currentSl.toStringAsFixed(4)} tp1Hit=$tp1Hit '
        'remaining=$remainingQty realized=${realizedPnl.toStringAsFixed(4)} zone=$zoneInfo\n'
        '  targets: $tgtStr';
  }
}

// ============================================================================
// TRADING BOT
// ============================================================================

class TradingBot {
  final BotConfig config;

  final List<ActiveTrade> _openTrades = [];
  int _tradeCounter = 0;
  bool _running = false;
  Timer? _timer;

  // ─── Session stats ───
  double _sessionRealizedPnl = 0.0;
  int _sessionTotalTrades = 0;
  int _sessionWins = 0;
  int _sessionLosses = 0;
  final List<double> _closedTradePnls = [];
  DateTime? _sessionStart;

  late int _quantityPrecision;

  TradingBot(this.config) : _quantityPrecision = config.quantityPrecision;

  // ─── START / STOP ──────────────────────────────────────────────

  void start() {
    if (_running) {
      print('[BOT] Already running.');
      return;
    }
    _running = true;
    _sessionStart = DateTime.now();

    print('╔═══════════════════════════════════════════════════════════╗');
    print('║           ASTERDEX LIVE TRADING BOT STARTED              ║');
    print('╠═══════════════════════════════════════════════════════════╣');
    print('║  Symbol:    ${config.symbol.padRight(20)}                 ║');
    print('║  Interval:  ${config.interval.padRight(20)}                 ║');
    print('║  Leverage:  ${config.leverage.toString().padRight(20)}                 ║');
    print('║  Risk/Trade:${'${config.positionSizePct}%'.padRight(20)}                 ║');
    print('║  Targets:   ATR × [1, 4.5, 7, 9, 11]                     ║');
    print('╚═══════════════════════════════════════════════════════════╝');
    print('');

    _setupLeverageAndAlign();
  }

  Future<void> _setupLeverageAndAlign() async {
    try {
      await AsterdexFutureFunctions.setLeverage(
        config.symbol,
        config.leverage.toInt(),
        config.apiKey,
        config.secretKey,
      );
    } catch (e) {
      print('[BOT] WARNING: Could not set leverage — $e');
    }

    try {
      final balance = await AsterdexFutureFunctions.getAvailableBalance(config.apiKey, config.secretKey);
      final tradeCapital = balance * (config.positionSizePct / 100);
      final positionSize = tradeCapital * config.leverage;
      print('[BOT] Available Balance : \$${balance.toStringAsFixed(2)}');
      print('[BOT] Capital Per Trade : \$${tradeCapital.toStringAsFixed(2)} (${config.positionSizePct}%)');
      print('[BOT] Position Size     : \$${positionSize.toStringAsFixed(2)} (${config.leverage}x leverage)');
    } catch (e) {
      print('[BOT] WARNING: Could not fetch balance — $e');
    }

    try {
      _quantityPrecision = await AsterdexFutureFunctions.getQuantityPrecision(config.symbol);
      print('[BOT] Quantity precision for ${config.symbol}: $_quantityPrecision decimal places');
    } catch (e) {
      print('[BOT] WARNING: Could not fetch quantity precision, using config default ($_quantityPrecision) — $e');
    }

    await _alignAndStart();
  }

  /// Waits until the next candle-open boundary, then starts the periodic loop.
  /// Skipped when candleOffset > 0 (historical replay mode).
  Future<void> _alignAndStart() async {
    if (config.candleOffset > 0) {
      print('[BOT] Historical mode (offset=${config.candleOffset}) — running immediately.');
      _tick();
      return;
    }

    final intervalSeconds = config.loopInterval.inSeconds;
    final now = DateTime.now();
    final secondsIntoInterval =
        (now.minute * 60 + now.second) % intervalSeconds;
    final secondsToNext = intervalSeconds - secondsIntoInterval;

    final waitSeconds = secondsToNext + 2;
    final nextCandle = now.add(Duration(seconds: waitSeconds));

    print('[BOT] Aligning to candle boundary — first tick at '
        '${nextCandle.hour.toString().padLeft(2, "0")}:'
        '${nextCandle.minute.toString().padLeft(2, "0")}:'
        '${nextCandle.second.toString().padLeft(2, "0")} '
        '(waiting ${waitSeconds}s)');

    await Future.delayed(Duration(seconds: waitSeconds));
    if (!_running) return;

    _tick();
    _timer = Timer.periodic(config.loopInterval, (_) => _tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    print('[BOT] Stopped.');
  }

  // ─── MAIN LOOP ─────────────────────────────────────────────────

  Future<void> _tick() async {
    if (!_running) return;

    try {
      final now = DateTime.now();
      print('\n────────────────────────────────────────────────────');
      print('[BOT] Tick @ ${now.toIso8601String()}');

      // 1. Fetch candles
      final candles = await fetchBinanceCandles(
        symbol: config.symbol,
        interval: config.interval,
        limit: config.candleLimit,
        offset: config.candleOffset,
      );

      if (candles.length < 50) {
        print('[BOT] Not enough candles (${candles.length}). Skipping.');
        return;
      }

      final lastC = candles.last;
      final ct = lastC.time.toLocal();
      final timeStr =
          '${ct.year}-${ct.month.toString().padLeft(2, '0')}-${ct.day.toString().padLeft(2, '0')} '
          '${ct.hour.toString().padLeft(2, '0')}:${ct.minute.toString().padLeft(2, '0')}:'
          '${ct.second.toString().padLeft(2, '0')} (local)';

      print('[BOT] $timeStr  O=${lastC.open.toStringAsFixed(4)} H=${lastC.high.toStringAsFixed(4)} L=${lastC.low.toStringAsFixed(4)} C=${lastC.close.toStringAsFixed(4)}');

      // 2. SFI — signals (trend/flip) + targets + trailing SL lines
      final sfi = SfiIndicator();
      final sfiSignals = sfi.calculateSfiMagic(
        candles,
        period: config.sfiPeriod,
        multiplier: config.sfiMultiplier,
      );
      final currentSfi = sfiSignals.last;

      // sfi.loop() gives: direction, entry, targets (5 levels), stoploss (dnLine), nexttarget (upLine)
      final sfiData = sfi.loop(candles);

      // 3. SR zones
      final srIndicator = SupportResistanceIndicator(
        detectionLength: config.srDetectionLength,
        srMargin: config.srMargin,
        avoidFBO: true,
        checkHist: true,
        showManip: true,
        manipMargin: 1.3,
      );
      final srResult = srIndicator.calculate(candles);
      final activeSupports    = srResult.support.where((z) => z.isActive).toList();
      final activeResistances = srResult.resistance.where((z) => z.isActive).toList();

      final s0 = activeSupports.isNotEmpty
          ? 'S[0]=${activeSupports.first.boxBottom.toStringAsFixed(4)}-${activeSupports.first.boxTop.toStringAsFixed(4)}'
          : 'S[0]=none';
      final r0 = activeResistances.isNotEmpty
          ? 'R[0]=${activeResistances.first.boxBottom.toStringAsFixed(4)}-${activeResistances.first.boxTop.toStringAsFixed(4)}'
          : 'R[0]=none';

      print('[BOT] SFI trend=${currentSfi.trend > 0 ? "+1" : "-1"}'
          '  upLine=${currentSfi.upLine.toStringAsFixed(4)}'
          '  dnLine=${currentSfi.dnLine.toStringAsFixed(4)}'
          '  $s0  $r0'
          '${currentSfi.buySignal ? "  ▲ BUY FLIP" : ""}${currentSfi.sellSignal ? "  ▼ SELL FLIP" : ""}');

      // 4. Manage open trades (update trailing SL, check TP1 and SL)
      await _manageOpenTrades(currentSfi, lastC);

      // 5. Check for new entries
      await _checkEntries(currentSfi, sfiData, lastC, activeSupports, activeResistances);

      // 7. Dashboard
      _printPnlDashboard(lastC.close);

    } catch (e, st) {
      print('[BOT] ERROR: $e');
      print(st);
    }
  }

  // ─── MANAGE OPEN TRADES ────────────────────────────────────────

  Future<void> _manageOpenTrades(SfiSignal sfi, Candle lastCandle) async {
    final toRemove = <ActiveTrade>[];

    for (final trade in _openTrades) {
      // Update trailing SL from current SFI lines every tick
      if (trade.direction == TradeDirection.long) {
        trade.currentSl = sfi.upLine;   // trailing support, rises with price
      } else {
        trade.currentSl = sfi.dnLine;   // trailing resistance, falls with price
      }

      // Mark all reached targets for display
      for (final t in trade.targets) {
        if (!t.reached) {
          if (trade.direction == TradeDirection.long && lastCandle.high >= t.price) t.reached = true;
          if (trade.direction == TradeDirection.short && lastCandle.low <= t.price) t.reached = true;
        }
      }

      if (trade.direction == TradeDirection.long) {

        // ── TP1: close 90% when high reaches target[0] ──
        if (!trade.tp1Hit && lastCandle.high >= trade.targets[0].price && trade.remainingQty > 0) {
          double closeQty = _roundQty(trade.totalQty * 0.9);
          if (closeQty <= 0) closeQty = trade.remainingQty;

          double partialPnl = (trade.targets[0].price - trade.entryPrice) * closeQty;
          trade.realizedPnl += partialPnl;
          trade.targets[0].reached = true;

          print('[TRADE] LONG #${trade.id} TP1 @ ${trade.targets[0].price.toStringAsFixed(4)}'
              ' — closing $closeQty (90%) | PnL +${partialPnl.toStringAsFixed(4)}');

          await _exitPosition(trade: trade, closeQty: closeQty, reason: 'TP1');
          trade.remainingQty -= closeQty;
          trade.tp1Hit = true;

          if (trade.remainingQty <= 0) {
            _recordClosedTrade(trade, trade.targets[0].price);
            toRemove.add(trade);
            continue;
          }
        }

        // ── SL: price drops below SFI upLine ──
        // Before TP1: full exit. After TP1: trailing exit of remaining 10%.
        if (lastCandle.low <= trade.currentSl && trade.remainingQty > 0) {
          double closePnl = (trade.currentSl - trade.entryPrice) * trade.remainingQty;
          trade.realizedPnl += closePnl;

          String reason = trade.tp1Hit ? 'TRAILING_SL' : 'SL';
          print('[TRADE] LONG #${trade.id} $reason @ ${trade.currentSl.toStringAsFixed(4)}'
              ' | PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}'
              ' | Total ${trade.realizedPnl.toStringAsFixed(4)}');

          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: reason);
          trade.remainingQty = 0;
          _recordClosedTrade(trade, trade.currentSl);
          toRemove.add(trade);
        }

      } else {
        // ── SHORT ──

        // TP1: close 90% when low reaches target[0]
        if (!trade.tp1Hit && lastCandle.low <= trade.targets[0].price && trade.remainingQty > 0) {
          double closeQty = _roundQty(trade.totalQty * 0.9);
          if (closeQty <= 0) closeQty = trade.remainingQty;

          double partialPnl = (trade.entryPrice - trade.targets[0].price) * closeQty;
          trade.realizedPnl += partialPnl;
          trade.targets[0].reached = true;

          print('[TRADE] SHORT #${trade.id} TP1 @ ${trade.targets[0].price.toStringAsFixed(4)}'
              ' — closing $closeQty (90%) | PnL +${partialPnl.toStringAsFixed(4)}');

          await _exitPosition(trade: trade, closeQty: closeQty, reason: 'TP1');
          trade.remainingQty -= closeQty;
          trade.tp1Hit = true;

          if (trade.remainingQty <= 0) {
            _recordClosedTrade(trade, trade.targets[0].price);
            toRemove.add(trade);
            continue;
          }
        }

        // SL: price rises above SFI dnLine
        if (lastCandle.high >= trade.currentSl && trade.remainingQty > 0) {
          double closePnl = (trade.entryPrice - trade.currentSl) * trade.remainingQty;
          trade.realizedPnl += closePnl;

          String reason = trade.tp1Hit ? 'TRAILING_SL' : 'SL';
          print('[TRADE] SHORT #${trade.id} $reason @ ${trade.currentSl.toStringAsFixed(4)}'
              ' | PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}'
              ' | Total ${trade.realizedPnl.toStringAsFixed(4)}');

          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: reason);
          trade.remainingQty = 0;
          _recordClosedTrade(trade, trade.currentSl);
          toRemove.add(trade);
        }
      }
    }

    _openTrades.removeWhere(toRemove.contains);
  }

  // ─── CHECK FOR NEW ENTRIES ─────────────────────────────────────

  Future<void> _checkEntries(
    SfiSignal currentSfi,
    Map<String, dynamic> sfiData,
    Candle lastCandle,
    List<SRZone> activeSupports,
    List<SRZone> activeResistances,
  ) async {
    if (sfiData.isEmpty) return;

    // Targets come directly from sfi.loop() — no ATR calculation here
    final sfiTargets = sfiData['targets'] as List<ProfitTarget>;
    if (sfiTargets.isEmpty) return;

    // ── LONG: SFI flips to +1 + candle low touches s[0] ──
    if (currentSfi.buySignal && !_hasOpenLong() && activeSupports.isNotEmpty) {
      final zone = activeSupports.first;
      final touchesSupport = lastCandle.low <= zone.boxTop && lastCandle.low >= zone.boxBottom;
      // Only check R[0] for blocking (not all resistances)
      final r0zone = activeResistances.isNotEmpty ? activeResistances.first : null;
      final touchesResistance = r0zone != null &&
          lastCandle.high >= r0zone.boxBottom && lastCandle.high <= r0zone.boxTop;

      print('[ENTRY CHECK] LONG: touchSupport=$touchesSupport'
          '  low=${lastCandle.low.toStringAsFixed(4)} in S[0]=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}'
          '  touchR0=$touchesResistance'
          '${r0zone != null ? "  R[0]=${r0zone.boxBottom.toStringAsFixed(4)}-${r0zone.boxTop.toStringAsFixed(4)}" : ""}');

      if (touchesSupport && !touchesResistance) {
        // For LONG: SL = upLine (nexttarget in sfi.loop())
        final initialSl = (sfiData['nexttarget'] as double?) ?? currentSfi.upLine;

        String zoneInfo = 'SUP ${zone.boxBottom.toStringAsFixed(2)}-${zone.boxTop.toStringAsFixed(2)}';
        print('[SIGNAL] ▲ LONG entry! Price=${lastCandle.close.toStringAsFixed(4)}'
            ' Zone=$zoneInfo SL=${initialSl.toStringAsFixed(4)}'
            ' Targets=${sfiTargets.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');

        await _openPosition(
          direction: TradeDirection.long,
          price: lastCandle.close,
          targets: sfiTargets,
          initialSl: initialSl,
          zoneInfo: zoneInfo,
        );
      }
    }

    // ── SHORT: SFI flips to -1 + candle high touches r[0] ──
    if (currentSfi.sellSignal && !_hasOpenShort() && activeResistances.isNotEmpty) {
      final zone = activeResistances.first;
      final touchesResistance = lastCandle.high >= zone.boxBottom && lastCandle.high <= zone.boxTop;
      // Only check S[0] for blocking (not all supports)
      final s0zone = activeSupports.isNotEmpty ? activeSupports.first : null;
      final touchesSupport = s0zone != null &&
          lastCandle.low <= s0zone.boxTop && lastCandle.low >= s0zone.boxBottom;

      print('[ENTRY CHECK] SHORT: touchResistance=$touchesResistance'
          '  high=${lastCandle.high.toStringAsFixed(4)} in R[0]=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}'
          '  touchS0=$touchesSupport'
          '${s0zone != null ? "  S[0]=${s0zone.boxBottom.toStringAsFixed(4)}-${s0zone.boxTop.toStringAsFixed(4)}" : ""}');

      if (touchesResistance && !touchesSupport) {
        // For SHORT: SL = dnLine (stoploss in sfi.loop())
        final initialSl = (sfiData['stoploss'] as double?) ?? currentSfi.dnLine;

        String zoneInfo = 'RES ${zone.boxBottom.toStringAsFixed(2)}-${zone.boxTop.toStringAsFixed(2)}';
        print('[SIGNAL] ▼ SHORT entry! Price=${lastCandle.close.toStringAsFixed(4)}'
            ' Zone=$zoneInfo SL=${initialSl.toStringAsFixed(4)}'
            ' Targets=${sfiTargets.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');

        await _openPosition(
          direction: TradeDirection.short,
          price: lastCandle.close,
          targets: sfiTargets,
          initialSl: initialSl,
          zoneInfo: zoneInfo,
        );
      }
    }
  }

  // ─── EXECUTE: OPEN POSITION ────────────────────────────────────

  Future<void> _openPosition({
    required TradeDirection direction,
    required double price,
    required List<ProfitTarget> targets,
    required double initialSl,
    required String zoneInfo,
  }) async {
    try {
      final available = await AsterdexFutureFunctions.getAvailableBalance(
        config.apiKey, config.secretKey,
      );

      final riskUsdt = available * (config.positionSizePct / 100.0);
      final notional = riskUsdt * config.leverage;
      final rawQty   = notional / price;
      final quantity = _roundQty(rawQty);

      if (quantity <= 0) {
        print('[TRADE] Quantity too small ($rawQty). Skipping.');
        return;
      }

      final side         = direction == TradeDirection.long ? 'BUY'  : 'SELL';
      final positionSide = direction == TradeDirection.long ? 'LONG' : 'SHORT';

      await AsterFunction.placeOrder(
        symbol:       config.symbol,
        side:         side,
        positionSide: positionSide,
        quantity:     quantity,
        type:         'MARKET',
      );

      _tradeCounter++;
      final trade = ActiveTrade(
        id:          _tradeCounter,
        direction:   direction,
        entryTime:   DateTime.now(),
        entryPrice:  price,
        totalQty:    quantity,
        targets:     targets,
        zoneInfo:    zoneInfo,
        currentSl:   initialSl,
      );
      _openTrades.add(trade);

      String dir = direction == TradeDirection.long ? 'LONG' : 'SHORT';
      print('[TRADE] ✅ $dir #${trade.id} opened @ $price qty=$quantity'
          ' SL=${initialSl.toStringAsFixed(4)} zone=$zoneInfo');
      print('[TRADE]    Targets: ${targets.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');

    } catch (e) {
      print('[TRADE] ❌ Failed to open position: $e');
    }
  }

  // ─── EXECUTE: EXIT POSITION ────────────────────────────────────

  Future<void> _exitPosition({
    required ActiveTrade trade,
    required double closeQty,
    required String reason,
  }) async {
    try {
      final side         = trade.direction == TradeDirection.long ? 'SELL' : 'BUY';
      final positionSide = trade.direction == TradeDirection.long ? 'LONG' : 'SHORT';

      print('[TRADE] Closing ${trade.direction == TradeDirection.long ? "LONG" : "SHORT"}'
          ' #${trade.id}: side=$side/$positionSide qty=$closeQty reason=$reason');

      await AsterFunction.placeOrder(
        symbol:       config.symbol,
        side:         side,
        positionSide: positionSide,
        quantity:     closeQty,
        type:         'MARKET',
      );

      print('[TRADE] ✅ Closed $closeQty of #${trade.id} ($reason)');

    } catch (e) {
      print('[TRADE] ❌ Failed to close position #${trade.id}: $e');
    }
  }

  // ─── HELPERS ───────────────────────────────────────────────────

  bool _hasOpenLong()  => _openTrades.any((t) => t.direction == TradeDirection.long);
  bool _hasOpenShort() => _openTrades.any((t) => t.direction == TradeDirection.short);

  double _roundQty(double qty) {
    final factor = pow(10, _quantityPrecision).toDouble();
    return (qty * factor).floorToDouble() / factor;
  }

  void _recordClosedTrade(ActiveTrade trade, double closePrice) {
    double finalPnl = trade.totalPnl(closePrice);
    _sessionRealizedPnl += finalPnl;
    _sessionTotalTrades++;
    if (finalPnl > 0) { _sessionWins++; } else { _sessionLosses++; }
    _closedTradePnls.add(finalPnl);
  }

  void _printPnlDashboard(double currentPrice) {
    double totalUnrealized = _openTrades.fold(0.0, (sum, t) => sum + t.unrealizedPnl(currentPrice));
    double totalPnl = _sessionRealizedPnl + totalUnrealized;
    double winRate  = _sessionTotalTrades > 0
        ? (_sessionWins / _sessionTotalTrades) * 100.0
        : 0.0;

    String duration = '';
    if (_sessionStart != null) {
      final d = DateTime.now().difference(_sessionStart!);
      duration = '${d.inHours}h ${d.inMinutes % 60}m';
    }

    double bestTrade  = _closedTradePnls.isNotEmpty ? _closedTradePnls.reduce(max) : 0.0;
    double worstTrade = _closedTradePnls.isNotEmpty ? _closedTradePnls.reduce(min) : 0.0;

    print('');
    print('┌─────────────────────────── PnL DASHBOARD ───────────────────────────┐');
    print('│  Current Price: ${currentPrice.toStringAsFixed(4).padRight(14)} Session: ${duration.padRight(14)}       │');
    print('├──────────────────────────────────────────────────────────────────────┤');
    print('│  Realized PnL:    ${_fmtPnl(_sessionRealizedPnl).padRight(16)} Unrealized: ${_fmtPnl(totalUnrealized).padRight(16)}│');
    print('│  TOTAL PnL:       ${_fmtPnl(totalPnl).padRight(50)}│');
    print('├──────────────────────────────────────────────────────────────────────┤');
    print('│  Trades: ${_sessionTotalTrades.toString().padRight(5)} Wins: ${_sessionWins.toString().padRight(5)} Losses: ${_sessionLosses.toString().padRight(5)} WR: ${winRate.toStringAsFixed(1).padRight(6)}%    │');
    print('│  Best:   ${_fmtPnl(bestTrade).padRight(16)} Worst: ${_fmtPnl(worstTrade).padRight(16)}              │');
    print('├──────────────────────────────────────────────────────────────────────┤');

    if (_openTrades.isEmpty) {
      print('│  No open positions                                                   │');
    } else {
      for (final t in _openTrades) {
        String dir  = t.direction == TradeDirection.long ? '▲ LONG ' : '▼ SHORT';
        double uPnl = t.unrealizedPnl(currentPrice);
        double tPnl = t.totalPnl(currentPrice);
        double tPct = t.totalPnlPct(currentPrice);
        String sign = tPnl >= 0 ? '+' : '';
        String tgtStr = t.targets.map((tg) => '${tg.price.toStringAsFixed(2)}${tg.reached ? "✅" : ""}').join(' ');
        print('│  #${t.id.toString().padRight(4)} $dir  entry=${t.entryPrice.toStringAsFixed(4)}'
            '  qty=${t.remainingQty}/${t.totalQty}'
            '  uPnL=${_fmtPnl(uPnl)}'
            '  total=$sign${tPnl.toStringAsFixed(2)} ($sign${tPct.toStringAsFixed(2)}%)'
            '${t.tp1Hit ? " TP1✓" : ""}');
        print('│    SL=${t.currentSl.toStringAsFixed(4)}  zone=${t.zoneInfo}');
        print('│    Targets: $tgtStr');
      }
    }

    print('└──────────────────────────────────────────────────────────────────────┘');
    print('');
  }

  String _fmtPnl(double val) {
    String sign = val >= 0 ? '+' : '';
    return '$sign${val.toStringAsFixed(4)}';
  }
}

// ============================================================================
// SFI INDICATOR
// ============================================================================

class SfiSignal {
  final double upLine;   // trailing support (below price when trend=+1)
  final double dnLine;   // trailing resistance (above price when trend=-1)
  final int trend;
  final bool buySignal;
  final bool sellSignal;

  SfiSignal({
    required this.upLine,
    required this.dnLine,
    required this.trend,
    required this.buySignal,
    required this.sellSignal,
  });
}

class SfiIndicator {
  List<double> calculateTR(List<Candle> candles) {
    List<double> trList = [];
    for (int i = 0; i < candles.length; i++) {
      double prevClose = i == 0 ? candles[i].close : candles[i - 1].close;
      double tr = [
        candles[i].high - candles[i].low,
        (candles[i].high - prevClose).abs(),
        (candles[i].low  - prevClose).abs(),
      ].reduce(max);
      trList.add(tr);
    }
    return trList;
  }

  List<double> calculateWilderATR(List<double> trList, int period) {
    List<double> atr = [];
    if (trList.isEmpty) return atr;
    double sum = 0.0;
    for (int i = 0; i < trList.length; i++) {
      if (i < period) {
        sum += trList[i];
        atr.add(sum / (i + 1));
      } else if (i == period) {
        atr.add(trList.sublist(0, period).reduce((a, b) => a + b) / period);
      } else {
        atr.add(((atr[i - 1] * (period - 1)) + trList[i]) / period);
      }
    }
    return atr;
  }

  List<SfiSignal> calculateSfiMagic(List<Candle> candles, {
    int period = 10,
    double multiplier = 1.7,
  }) {
    final trList    = calculateTR(candles);
    final atrWilder = calculateWilderATR(trList, period);
    List<SfiSignal> signals = [];
    if (candles.isEmpty) return signals;

    double prevUp = candles[0].ohlc4 - multiplier * (atrWilder.isNotEmpty ? atrWilder[0] : 0.0);
    double prevDn = candles[0].ohlc4 + multiplier * (atrWilder.isNotEmpty ? atrWilder[0] : 0.0);
    int previousTrend = 1;

    for (int i = 0; i < candles.length; i++) {
      final c   = candles[i];
      final atr = i < atrWilder.length ? atrWilder[i] : (atrWilder.isNotEmpty ? atrWilder.last : 0.0);
      double rawUp = c.ohlc4 - multiplier * atr;
      double rawDn = c.ohlc4 + multiplier * atr;

      double up, dn;
      if (i > 0) {
        up = candles[i - 1].close > prevUp ? max(rawUp, prevUp) : rawUp;
        dn = candles[i - 1].close < prevDn ? min(rawDn, prevDn) : rawDn;
      } else {
        up = rawUp;
        dn = rawDn;
      }

      int trend = previousTrend;
      if (previousTrend == -1 && c.close > prevDn) { trend = 1; }
      else if (previousTrend == 1 && c.close < prevUp) { trend = -1; }

      signals.add(SfiSignal(
        upLine:     up,
        dnLine:     dn,
        trend:      trend,
        buySignal:  previousTrend == -1 && trend == 1,
        sellSignal: previousTrend == 1  && trend == -1,
      ));

      prevUp = up;
      prevDn = dn;
      previousTrend = trend;
    }
    return signals;
  }

  /// Returns the last signal's targets + current SFI trailing lines as SL.
  /// Mirrors sf.dart's loop() — targets use ATR(14) × [1, 4.5, 7, 9, 11].
  /// Returns: { direction, entry, targets, stoploss (dnLine), nexttarget (upLine) }
  Map<String, dynamic> loop(List<Candle> candles) {
    const atrMultipliers = [1.0, 4.5, 7.0, 9.0, 11.0];

    final trList       = calculateTR(candles);
    final atrTargets   = calculateWilderATR(trList, 14); // period 14 for targets
    final signals      = calculateSfiMagic(candles, period: 10, multiplier: 1.7);

    List<ProfitTarget> lastTargets = [];
    int lastDirection = 1;
    double lastEntry  = 0.0;

    for (int i = 0; i < candles.length; i++) {
      final s   = signals[i];
      final atr = i < atrTargets.length ? atrTargets[i] : (atrTargets.isNotEmpty ? atrTargets.last : 0.0);

      if (s.buySignal || s.sellSignal) {
        lastDirection = s.buySignal ? 1 : -1;
        lastEntry     = candles[i].close;
        lastTargets   = atrMultipliers
            .map((m) => ProfitTarget(lastDirection == 1
                ? lastEntry + m * atr
                : lastEntry - m * atr))
            .toList();
      }
    }

    if (lastTargets.isEmpty) return {};

    final lastSfi = signals.last;
    // upLine = trailing support (SL for LONG / nexttarget label in sf.dart)
    // dnLine = trailing resistance (SL for SHORT / stoploss label in sf.dart)
    return {
      'direction':  lastDirection,
      'entry':      lastEntry,
      'targets':    lastTargets,
      'stoploss':   lastSfi.dnLine,
      'nexttarget': lastSfi.upLine,
    };
  }
}

// ============================================================================
// MAIN — configure and run
// ============================================================================

Future<void> main() async {
  final config = BotConfig(
    apiKey:    '702bfa60c9818ac2b27b14d78170eade3fd72b1fce1bf49188274c6d362be7fe',
    secretKey: 'b35258daeaa33e4554cb6bce1fe2e5b7eae6408c5496291a84b12ca42b5390ea',

    symbol:   'SOLUSDT',
    interval: '5m',
    candleLimit: 1000,

    leverage:         10,
    positionSizePct:  10.0,
    quantityPrecision: 1,

    loopInterval: Duration(minutes: 5),

    sfiPeriod:       10,
    sfiMultiplier:   1.7,
    srDetectionLength: 15,
    srMargin:        2.0,

    // Historical replay: set >0 to inspect past data (skips candle-boundary wait)
    // Set to 0 for live trading
    candleOffset: 0,
  );

  final bot = TradingBot(config);
  bot.start();

  print('[MAIN] ASTERDEX bot is running. Press Ctrl+C to stop.\n');

  await Completer<void>().future;
}
