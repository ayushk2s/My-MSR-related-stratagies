import 'dart:async';
import 'dart:math';

import 'model.dart';
import 'support_resistance_2.dart';

import 'msr_mexc/account_data.dart';
import 'msr_mexc/future_trade.dart';

class BotConfig {
  // ─── MEXC Account ───
  final String uid;
  final String mtoken;
  final String htoken;

  // ─── Trading Pair ───
  final String symbol;        // e.g. 'SOL_USDT'
  final String interval;      // e.g. 'Min5'
  final int candleLimit;      // how many candles to fetch
  final int candleOffset;     // offset for candle fetch

  // ─── Risk Management ───
  final double leverage;
  final double positionSizePct;   // % of available balance per trade
  final double tp1AtrMultiplier;  // ATR multiplier for TP1 (e.g. 1.0)
  final int atrPeriod;

  // ─── Timing ───
  final Duration loopInterval;    // how often to check (match candle TF)

  // ─── SFI Settings ───
  final int sfiPeriod;
  final double sfiMultiplier;

  // ─── SR Settings ───
  final int srDetectionLength;
  final double srMargin;

  // ─── Signal Window ───
  // After SFI flips, allow zone-touch entries for this many candles.
  // Fixes the problem where buySignal and zone bounce happen on different bars.
  final int signalWindowBars;

  const BotConfig({
    required this.uid,
    required this.mtoken,
    required this.htoken,
    this.symbol = 'SOL_USDT',
    this.interval = 'Min5',
    this.candleLimit = 1000,
    this.candleOffset = 26,
    this.leverage = 10,
    this.positionSizePct = 2.0,
    this.tp1AtrMultiplier = 1.0,
    this.atrPeriod = 14,
    this.loopInterval = const Duration(minutes: 5),
    this.sfiPeriod = 10,
    this.sfiMultiplier = 1.7,
    this.srDetectionLength = 15,
    this.srMargin = 2.0,
    this.signalWindowBars = 10,  // 10 bars × 5 min = 50 min look-forward
  });
}

// ============================================================================
// TRADE STATE — Tracks our active positions
// ============================================================================

enum TradeDirection { long, short }

class ActiveTrade {
  final int id;
  final TradeDirection direction;
  final DateTime entryTime;
  final double entryPrice;
  final double totalVol;        // total volume (MEXC contract vol)
  final double tp1Price;
  final String zoneInfo;

  double remainingVol;
  bool tp1Hit = false;
  double realizedPnl = 0.0;    // PnL already locked in (from partial closes)

  ActiveTrade({
    required this.id,
    required this.direction,
    required this.entryTime,
    required this.entryPrice,
    required this.totalVol,
    required this.tp1Price,
    required this.zoneInfo,
  }) : remainingVol = totalVol;

  /// Unrealized PnL on remaining open volume at current price
  double unrealizedPnl(double currentPrice) {
    if (remainingVol <= 0) return 0.0;
    if (direction == TradeDirection.long) {
      return (currentPrice - entryPrice) * remainingVol;
    } else {
      return (entryPrice - currentPrice) * remainingVol;
    }
  }

  /// Total PnL = realized + unrealized
  double totalPnl(double currentPrice) => realizedPnl + unrealizedPnl(currentPrice);

  /// PnL as percentage of entry notional
  double totalPnlPct(double currentPrice) {
    double notional = entryPrice * totalVol;
    return notional > 0 ? (totalPnl(currentPrice) / notional) * 100.0 : 0.0;
  }

  @override
  String toString() {
    String dir = direction == TradeDirection.long ? 'LONG' : 'SHORT';
    return '#$id $dir entry=${entryPrice.toStringAsFixed(4)} vol=$totalVol '
        'tp1=${tp1Price.toStringAsFixed(4)} tp1Hit=$tp1Hit remaining=$remainingVol '
        'realized=${realizedPnl.toStringAsFixed(4)} zone=$zoneInfo';
  }
}

// ============================================================================
// TRADING BOT
// ============================================================================

class TradingBot {
  final BotConfig config;

  List<ActiveTrade> _openTrades = [];
  int _tradeCounter = 0;
  bool _running = false;
  Timer? _timer;

  // ─── Replay offset (decrements each tick to walk forward through history) ───
  late int _currentOffset;

  // ─── Session PnL tracking ───
  double _sessionRealizedPnl = 0.0;   // total realized from all closed trades
  int _sessionTotalTrades = 0;
  int _sessionWins = 0;
  int _sessionLosses = 0;
  List<double> _closedTradePnls = [];  // PnL of each closed trade for stats
  DateTime? _sessionStart;

  TradingBot(this.config) : _currentOffset = config.candleOffset;

  // ─── START / STOP ─────────────────────────────────────────────

  void start() {
    if (_running) {
      print('[BOT] Already running.');
      return;
    }
    _running = true;
    _sessionStart = DateTime.now();
    print('╔═══════════════════════════════════════════════════════════╗');
    print('║              LIVE TRADING BOT STARTED                    ║');
    print('╠═══════════════════════════════════════════════════════════╣');
    print('║  Symbol:    ${config.symbol.padRight(20)}                ║');
    print('║  Interval:  ${config.interval.padRight(20)}                ║');
    print('║  Leverage:  ${config.leverage.toString().padRight(20)}                ║');
    print('║  Risk/Trade: ${(config.positionSizePct.toString() + '%').padRight(19)}                ║');
    print('║  TP1 ATR:   ${(config.tp1AtrMultiplier.toString() + 'x').padRight(20)}                ║');
    print('╚═══════════════════════════════════════════════════════════╝');
    print('');

    // Align to next candle boundary, then run on exact interval
    _alignAndStart();
  }

  /// Waits until the next candle open boundary, then starts the periodic loop.
  /// E.g. for Min5: if now is 14:03:22, waits 1m37s so first tick is at 14:05:00.
  Future<void> _alignAndStart() async {
    final intervalSeconds = config.loopInterval.inSeconds;
    final now = DateTime.now();
    final secondsIntoInterval =
        (now.minute * 60 + now.second) % intervalSeconds;
    final secondsToNext = intervalSeconds - secondsIntoInterval;

    // Add a 2-second buffer so candle data is confirmed closed on the exchange
    // final waitSeconds = secondsToNext + 2;

    //just for trial 
        final waitSeconds =  2;

    final nextCandle = now.add(Duration(seconds: waitSeconds));
    print('[BOT] Aligning to candle boundary — next tick at '
        '${nextCandle.hour.toString().padLeft(2, "0")}:'
        '${nextCandle.minute.toString().padLeft(2, "0")}:'
        '${nextCandle.second.toString().padLeft(2, "0")} '
        '(waiting ${waitSeconds}s)');

    await Future.delayed(Duration(seconds: waitSeconds));
    if (!_running) return;

    _tick();
    // _timer = Timer.periodic(config.loopInterval, (_) => _tick());
        _timer = Timer.periodic(Duration(seconds: 3), (_) => _tick());

  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    print('[BOT] Stopped.');
  }

  // ─── MAIN LOOP (runs every candle interval) ───────────────────

  Future<void> _tick() async {
    if (!_running) return;

    try {
      DateTime now = DateTime.now();
      print('\n────────────────────────────────────────────────────');
      print('[BOT] Tick @ ${now.toIso8601String()}');

      // 1. Fetch candles — use _currentOffset so each tick advances one bar forward
      print('[BOT] Replay offset: $_currentOffset');
      final candles = await fetchMexcCandles(
        symbol: config.symbol,
        interval: config.interval,
        limit: config.candleLimit,
        offset: _currentOffset,
      );
      // Advance one bar forward; once it reaches 0 the bot is on live data
      if (_currentOffset > 0) _currentOffset--;
      if (candles.length < 50) {
        print('[BOT] Not enough candles (${candles.length}). Skipping.');
        return;
      }
      final lastC = candles.last;
      final candleTime = lastC.time.toLocal();
      final timeStr =
          '${candleTime.year}-${candleTime.month.toString().padLeft(2, '0')}-${candleTime.day.toString().padLeft(2, '0')} '
          '${candleTime.hour.toString().padLeft(2, '0')}:${candleTime.minute.toString().padLeft(2, '0')}:${candleTime.second.toString().padLeft(2, '0')} (local)';
      print('[BOT] Fetched ${candles.length} candles.');
      print('[BOT] Last candle time : $timeStr');
      print('[BOT]   Open : ${lastC.open.toStringAsFixed(4)}');
      print('[BOT]   High : ${lastC.high.toStringAsFixed(4)}');
      print('[BOT]   Low  : ${lastC.low.toStringAsFixed(4)}');
      print('[BOT]   Close: ${lastC.close.toStringAsFixed(4)}');

      // 2. Compute SFI signals
      final sfiIndicator = SfiIndicator();
      final sfiSignals = sfiIndicator.calculateSfiMagic(
        candles,
        period: config.sfiPeriod,
        multiplier: config.sfiMultiplier,
      );
      final currentSfi = sfiSignals.last;

      print('[BOT] SFI trend=${currentSfi.trend} buy=${currentSfi.buySignal} sell=${currentSfi.sellSignal}');

      // ─── Entry gate: only on the exact SFI flip bar ──────────────────────
      // buySignal/sellSignal are true for exactly ONE bar (the flip).
      // If the zone condition is not met on that same bar → skip, wait for next flip.
      bool recentBuy  = currentSfi.buySignal;
      bool recentSell = currentSfi.sellSignal;

      // 3. Compute SR zones
      final srIndicator = SupportResistanceIndicator(
        detectionLength: config.srDetectionLength,
        srMargin: config.srMargin,
        avoidFBO: true,
        checkHist: true,
        showManip: true,
        manipMargin: 1.3,
      );
      final srResult = srIndicator.calculate(candles);
      final activeSupports = srResult.support.where((z) => z.isActive).toList();
      final activeResistances = srResult.resistance.where((z) => z.isActive).toList();
      print('[BOT] Active zones: ${activeSupports.length} supports, ${activeResistances.length} resistances');

      // ─── Print nearest 3 support & resistance zones to current price ─────
      double curPrice = lastC.close;
      // Sort supports by proximity of boxTop to close (ascending distance)
      final nearSupports = [...activeSupports]
        ..sort((a, b) => (curPrice - a.boxTop).abs().compareTo((curPrice - b.boxTop).abs()));
      final nearResistances = [...activeResistances]
        ..sort((a, b) => (a.boxBottom - curPrice).abs().compareTo((b.boxBottom - curPrice).abs()));

      print('[BOT] ─── Nearest Supports ──────────────────────────────────');
      for (int i = 0; i < nearSupports.length && i < 3; i++) {
        final z = nearSupports[i];
        double dist = curPrice - z.boxTop;
        String tickStr = z.t ? 'T' : '-';
        bool touched = lastC.low <= z.boxTop && (lastC.low >= z.boxBottom * 0.998 || lastC.open >= z.boxBottom || lastC.close >= z.boxBottom);
        print('[BOT]   SUP[$tickStr] ${z.boxBottom.toStringAsFixed(4)}-${z.boxTop.toStringAsFixed(4)}'
            '  dist_to_top=${dist >= 0 ? "+" : ""}${dist.toStringAsFixed(4)}'
            '  touched=$touched'
            '  (O=${lastC.open.toStringAsFixed(4)} H=${lastC.high.toStringAsFixed(4)} L=${lastC.low.toStringAsFixed(4)} C=${lastC.close.toStringAsFixed(4)})');
      }
      print('[BOT] ─── Nearest Resistances ──────────────────────────────');
      for (int i = 0; i < nearResistances.length && i < 3; i++) {
        final z = nearResistances[i];
        double dist = z.boxBottom - curPrice;
        String tickStr = z.t ? 'T' : '-';
        bool touched = lastC.high >= z.boxBottom && (lastC.high <= z.boxTop * 1.002 || lastC.open <= z.boxTop || lastC.close <= z.boxTop);
        print('[BOT]   RES[$tickStr] ${z.boxBottom.toStringAsFixed(4)}-${z.boxTop.toStringAsFixed(4)}'
            '  dist_to_bot=${dist >= 0 ? "+" : ""}${dist.toStringAsFixed(4)}'
            '  touched=$touched'
            '  (O=${lastC.open.toStringAsFixed(4)} H=${lastC.high.toStringAsFixed(4)} L=${lastC.low.toStringAsFixed(4)} C=${lastC.close.toStringAsFixed(4)})');
      }
      print('[BOT] ────────────────────────────────────────────────────────');

      // 4. Compute ATR for TP calculation
      final trList = sfiIndicator.calculateTR(candles);
      final atrList = sfiIndicator.calculateWilderATR(trList, config.atrPeriod);
      final currentAtr = atrList.isNotEmpty ? atrList.last : 0.0;
      print('[BOT] ATR(${config.atrPeriod}): ${currentAtr.toStringAsFixed(4)}');

      // 5. Manage existing trades
      await _manageOpenTrades(currentSfi, lastC, currentAtr);

      // 6. Check for new entries
      await _checkEntries(recentBuy, recentSell, lastC, activeSupports, activeResistances, currentAtr);

      // 7. Print PnL dashboard
      _printPnlDashboard(lastC.close);

    } catch (e, st) {
      print('[BOT] ERROR: $e');
      print(st);
    }
  }

  // ─── MANAGE OPEN TRADES ───────────────────────────────────────

  Future<void> _manageOpenTrades(SfiSignal sfi, Candle lastCandle, double atr) async {
    List<ActiveTrade> toRemove = [];

    for (var trade in _openTrades) {
      if (trade.direction == TradeDirection.long) {

        // ── TP1: close 50% if high reached tp1 ──
        if (!trade.tp1Hit && lastCandle.high >= trade.tp1Price && trade.remainingVol > 0) {
          double closeVol = (trade.totalVol * 0.5).floorToDouble();
          if (closeVol < 1) closeVol = trade.remainingVol;

          // Record realized PnL for this partial close
          double partialPnl = (trade.tp1Price - trade.entryPrice) * closeVol;
          trade.realizedPnl += partialPnl;

          print('[TRADE] LONG #${trade.id} TP1 hit @ ${trade.tp1Price.toStringAsFixed(4)} — closing $closeVol vol | PnL: +${partialPnl.toStringAsFixed(4)}');
          await _exitPosition(
            trade: trade,
            closeVol: closeVol,
            reason: 'TP1',
          );
          trade.remainingVol -= closeVol;
          trade.tp1Hit = true;

          if (trade.remainingVol <= 0) {
            _recordClosedTrade(trade, trade.tp1Price);
            toRemove.add(trade);
            continue;
          }
        }

        // ── Signal reversal (sell signal) → close remaining ──
        if (sfi.sellSignal && trade.remainingVol > 0) {
          double closePnl = (lastCandle.close - trade.entryPrice) * trade.remainingVol;
          trade.realizedPnl += closePnl;

          print('[TRADE] LONG #${trade.id} SIGNAL REVERSE (sell) — closing ${trade.remainingVol} vol @ ${lastCandle.close.toStringAsFixed(4)} | PnL: ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)} | Total: ${trade.realizedPnl.toStringAsFixed(4)}');
          await _exitPosition(
            trade: trade,
            closeVol: trade.remainingVol,
            reason: 'SIGNAL_REVERSE',
          );
          trade.remainingVol = 0;
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
        }

      } else {
        // SHORT

        // ── TP1: close 50% if low reached tp1 ──
        if (!trade.tp1Hit && lastCandle.low <= trade.tp1Price && trade.remainingVol > 0) {
          double closeVol = (trade.totalVol * 0.5).floorToDouble();
          if (closeVol < 1) closeVol = trade.remainingVol;

          double partialPnl = (trade.entryPrice - trade.tp1Price) * closeVol;
          trade.realizedPnl += partialPnl;

          print('[TRADE] SHORT #${trade.id} TP1 hit @ ${trade.tp1Price.toStringAsFixed(4)} — closing $closeVol vol | PnL: +${partialPnl.toStringAsFixed(4)}');
          await _exitPosition(
            trade: trade,
            closeVol: closeVol,
            reason: 'TP1',
          );
          trade.remainingVol -= closeVol;
          trade.tp1Hit = true;

          if (trade.remainingVol <= 0) {
            _recordClosedTrade(trade, trade.tp1Price);
            toRemove.add(trade);
            continue;
          }
        }

        // ── Signal reversal (buy signal) → close remaining ──
        if (sfi.buySignal && trade.remainingVol > 0) {
          double closePnl = (trade.entryPrice - lastCandle.close) * trade.remainingVol;
          trade.realizedPnl += closePnl;

          print('[TRADE] SHORT #${trade.id} SIGNAL REVERSE (buy) — closing ${trade.remainingVol} vol @ ${lastCandle.close.toStringAsFixed(4)} | PnL: ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)} | Total: ${trade.realizedPnl.toStringAsFixed(4)}');
          await _exitPosition(
            trade: trade,
            closeVol: trade.remainingVol,
            reason: 'SIGNAL_REVERSE',
          );
          trade.remainingVol = 0;
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
        }
      }
    }

    _openTrades.removeWhere((t) => toRemove.contains(t));
  }

  // ─── CHECK FOR NEW ENTRIES ────────────────────────────────────

  Future<void> _checkEntries(
      bool recentBuySignal,
      bool recentSellSignal,
      Candle lastCandle,
      List<SRZone> activeSupports,
      List<SRZone> activeResistances,
      double atr,
      ) async {
    if (atr <= 0) return;

    // ─── LONG: recent buy flip (within signalWindowBars) + bounce off support ───
    if (recentBuySignal && !_hasOpenLong()) {
      print('[ENTRY] Checking LONG entries (recentBuy=true, ${activeSupports.length} supports):');
      SRZone? bestZone;
      double minDist = double.maxFinite;

      // Sort supports by proximity so logs are most relevant first
      final sortedSupports = [...activeSupports]
        ..sort((a, b) => (lastCandle.close - a.boxTop).abs().compareTo((lastCandle.close - b.boxTop).abs()));

      for (var zone in sortedSupports) {
        // Entry condition: candle touches the zone — open, close, or wick is inside/at zone.
        // Don't require close above zone; just that price entered the zone from above.
        bool touchesZone = lastCandle.low <= zone.boxTop &&
            (lastCandle.low >= zone.boxBottom * 0.998 ||
             lastCandle.open  >= zone.boxBottom ||
             lastCandle.close >= zone.boxBottom);
        String status = touchesZone ? '✅ QUALIFY' : '❌ skip';
        String reason = touchesZone ? '' : ' no_touch(low=${lastCandle.low.toStringAsFixed(4)} zone=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)})';
        print('[ENTRY]   $status  SUP ${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}$reason');

        if (touchesZone) {
          double dist = (lastCandle.close - zone.boxTop).abs();
          if (dist < minDist) {
            minDist = dist;
            bestZone = zone;
          }
        }
      }

      if (bestZone != null) {
        double tp1 = lastCandle.close + config.tp1AtrMultiplier * atr;
        String zoneInfo = 'SUP ${bestZone.boxBottom.toStringAsFixed(2)}-${bestZone.boxTop.toStringAsFixed(2)}';

        print('[SIGNAL] ▲ LONG entry! Price=${lastCandle.close.toStringAsFixed(4)} Zone=$zoneInfo TP1=${tp1.toStringAsFixed(4)}');
        await _openPosition(
          direction: TradeDirection.long,
          price: lastCandle.close,
          tp1: tp1,
          zoneInfo: zoneInfo,
        );
      }
    }

    // ─── SHORT: recent sell flip — no bar limit, stays open until SFI flips back ───
    if (recentSellSignal && !_hasOpenShort()) {
      print('[ENTRY] Checking SHORT entries (recentSell=true, ${activeResistances.length} resistances):');
      SRZone? bestZone;
      double minDist = double.maxFinite;

      final sortedResistances = [...activeResistances]
        ..sort((a, b) => (a.boxBottom - lastCandle.close).abs().compareTo((b.boxBottom - lastCandle.close).abs()));

      for (var zone in sortedResistances) {
        // Entry condition: candle touches the zone — open, close, or wick is inside/at zone.
        // Don't require close below zone; just that price entered the zone from below.
        bool touchesZone = lastCandle.high >= zone.boxBottom &&
            (lastCandle.high <= zone.boxTop * 1.002 ||
             lastCandle.open  <= zone.boxTop ||
             lastCandle.close <= zone.boxTop);
        String status = touchesZone ? '✅ QUALIFY' : '❌ skip';
        String reason = touchesZone ? '' : ' no_touch(high=${lastCandle.high.toStringAsFixed(4)} zone=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)})';
        print('[ENTRY]   $status  RES ${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}$reason');

        if (touchesZone) {
          double dist = (zone.boxBottom - lastCandle.close).abs();
          if (dist < minDist) {
            minDist = dist;
            bestZone = zone;
          }
        }
      }

      if (bestZone != null) {
        double tp1 = lastCandle.close - config.tp1AtrMultiplier * atr;
        String zoneInfo = 'RES ${bestZone.boxBottom.toStringAsFixed(2)}-${bestZone.boxTop.toStringAsFixed(2)}';

        print('[SIGNAL] ▼ SHORT entry! Price=${lastCandle.close.toStringAsFixed(4)} Zone=$zoneInfo TP1=${tp1.toStringAsFixed(4)}');
        await _openPosition(
          direction: TradeDirection.short,
          price: lastCandle.close,
          tp1: tp1,
          zoneInfo: zoneInfo,
        );
      }
    }
  }

  // ─── EXECUTE: OPEN POSITION ───────────────────────────────────

  Future<void> _openPosition({
    required TradeDirection direction,
    required double price,
    required double tp1,
    required String zoneInfo,
  }) async {
    try {
      // 1. Get available balance
      final futureBalance = await MexcFutureFunctions.getAssetCurrency('USDT');
      double available = double.parse(
        futureBalance['data']['availableBalance'].toString(),
      );
      print('[TRADE] Available balance: $available USDT');

      // 2. Calculate position size
      double riskAmount = available * (config.positionSizePct / 100.0);
      // vol = (riskAmount * leverage) / price
      // This gives the contract volume for MEXC futures
      double rawVol = (riskAmount * config.leverage) / price;
      double mexcVol = rawVol.floorToDouble(); // MEXC needs integer vol for most pairs

      if (mexcVol < 1) {
        print('[TRADE] Calculated vol < 1 ($rawVol). Skipping trade.');
        return;
      }

      // 3. Determine side
      // LONG  → buy (open long)   = side 1 or 'buy'
      // SHORT → sell (open short) = side 2 or 'sell'
      String side = direction == TradeDirection.long ? 'buy' : 'sell';

      print('[TRADE] Sending ${side.toUpperCase()} order: vol=$mexcVol leverage=${config.leverage} price=$price');

      // 4. Send order via MEXC
      await FutureTrade.sendTradeRequest(
        uid: config.uid,
        mtoken: config.mtoken,
        htoken: config.htoken,
        symbol: config.symbol,
        side: side,
        order_type: 5,          // market order
        vol: mexcVol.toInt(),
        leverage: config.leverage,
      );

      // 5. Track the trade locally
      _tradeCounter++;
      final trade = ActiveTrade(
        id: _tradeCounter,
        direction: direction,
        entryTime: DateTime.now(),
        entryPrice: price,
        totalVol: mexcVol,
        tp1Price: tp1,
        zoneInfo: zoneInfo,
      );
      _openTrades.add(trade);

      print('[TRADE] ✅ ${direction == TradeDirection.long ? "LONG" : "SHORT"} #${trade.id} opened @ $price vol=$mexcVol TP1=${tp1.toStringAsFixed(4)} zone=$zoneInfo');

    } catch (e) {
      print('[TRADE] ❌ Failed to open position: $e');
    }
  }

  // ─── EXECUTE: EXIT POSITION ───────────────────────────────────

  Future<void> _exitPosition({
    required ActiveTrade trade,
    required double closeVol,
    required String reason,
  }) async {
    try {
      // To close a position:
      //   LONG  was opened with 'buy'  → close with 'sell'  (but MEXC futures uses
      //         specific close sides: for bought positions → 'broughtsell')
      //   SHORT was opened with 'sell' → close with 'buy'   (soldbuy)
      //
      // Based on your note:  buy => broughtsell,  short => soldbuy
      String closeSide = trade.direction == TradeDirection.long ? 'broughtsell' : 'soldbuy';

      print('[TRADE] Closing ${trade.direction == TradeDirection.long ? "LONG" : "SHORT"} #${trade.id}: '
          'side=$closeSide vol=$closeVol reason=$reason');

      await FutureTrade.sendTradeRequest(
        uid: config.uid,
        mtoken: config.mtoken,
        htoken: config.htoken,
        symbol: config.symbol,
        side: closeSide,
        order_type: 5,          // market order
        vol: closeVol.toInt(),
        leverage: config.leverage,
      );

      print('[TRADE] ✅ Closed $closeVol vol of #${trade.id} ($reason)');

    } catch (e) {
      print('[TRADE] ❌ Failed to close position #${trade.id}: $e');
    }
  }

  // ─── HELPERS ──────────────────────────────────────────────────

  bool _hasOpenLong() => _openTrades.any((t) => t.direction == TradeDirection.long);
  bool _hasOpenShort() => _openTrades.any((t) => t.direction == TradeDirection.short);

  /// Call this whenever a trade is fully closed to record session stats
  void _recordClosedTrade(ActiveTrade trade, double closePrice) {
    double finalPnl = trade.totalPnl(closePrice);
    _sessionRealizedPnl += finalPnl;
    _sessionTotalTrades++;
    if (finalPnl > 0) {
      _sessionWins++;
    } else {
      _sessionLosses++;
    }
    _closedTradePnls.add(finalPnl);
  }

  /// Print a live PnL dashboard every tick
  void _printPnlDashboard(double currentPrice) {
    // Calculate unrealized PnL across all open trades
    double totalUnrealized = 0.0;
    for (var t in _openTrades) {
      totalUnrealized += t.unrealizedPnl(currentPrice);
    }

    double totalPnl = _sessionRealizedPnl + totalUnrealized;
    double winRate = _sessionTotalTrades > 0
        ? (_sessionWins / _sessionTotalTrades) * 100.0
        : 0.0;

    // Session duration
    String duration = '';
    if (_sessionStart != null) {
      Duration d = DateTime.now().difference(_sessionStart!);
      duration = '${d.inHours}h ${d.inMinutes % 60}m';
    }

    // Best / worst trade
    double bestTrade = _closedTradePnls.isNotEmpty
        ? _closedTradePnls.reduce((a, b) => a > b ? a : b)
        : 0.0;
    double worstTrade = _closedTradePnls.isNotEmpty
        ? _closedTradePnls.reduce((a, b) => a < b ? a : b)
        : 0.0;

    print('');
    print('┌─────────────────────────── PnL DASHBOARD ───────────────────────────┐');
    print('│  Current Price: ${currentPrice.toStringAsFixed(4).padRight(14)} Session: ${duration.padRight(14)}       │');
    print('├────────────────────────────────────────────────────────────────────  ┤');
    print('│  Realized PnL:    ${_fmtPnl(_sessionRealizedPnl).padRight(16)} Unrealized PnL: ${_fmtPnl(totalUnrealized).padRight(14)}│');
    print('│  TOTAL PnL:       ${_fmtPnl(totalPnl).padRight(50)}│');
    print('├─────────────────────────────────────────────────────────────────── ─ ┤');
    print('│  Trades: ${_sessionTotalTrades.toString().padRight(5)} Wins: ${_sessionWins.toString().padRight(5)} Losses: ${_sessionLosses.toString().padRight(5)} WR: ${winRate.toStringAsFixed(1).padRight(6)}%    │');
    print('│  Best:   ${_fmtPnl(bestTrade).padRight(16)} Worst: ${_fmtPnl(worstTrade).padRight(16)}              │');
    print('├──────────────────────────────────────────────────────────────────── ─┤');

    if (_openTrades.isEmpty) {
      print('│  No open positions                                                  │');
    } else {
      for (var t in _openTrades) {
        String dir = t.direction == TradeDirection.long ? '▲ LONG ' : '▼ SHORT';
        double uPnl = t.unrealizedPnl(currentPrice);
        double tPnl = t.totalPnl(currentPrice);
        double tPct = t.totalPnlPct(currentPrice);
        String pnlColor = tPnl >= 0 ? '+' : '';

        print('│  #${t.id.toString().padRight(4)} $dir  entry=${t.entryPrice.toStringAsFixed(4)}'
            '  vol=${t.remainingVol.toStringAsFixed(0)}/${t.totalVol.toStringAsFixed(0)}'
            '  uPnL=${_fmtPnl(uPnl)}'
            '  total=$pnlColor${tPnl.toStringAsFixed(2)} (${pnlColor}${tPct.toStringAsFixed(2)}%)'
            '${t.tp1Hit ? " TP1✓" : ""}');
        print('│         zone=${t.zoneInfo}  tp1=${t.tp1Price.toStringAsFixed(4)}');
      }
    }

    print('└─────────────────────────────────────────────────────────────────────┘');
    print('');
  }

  String _fmtPnl(double val) {
    String sign = val >= 0 ? '+' : '';
    return '$sign${val.toStringAsFixed(4)}';
  }
}

// ============================================================================
// SFI INDICATOR (same as backtest — included here for completeness)
// ============================================================================

class SfiSignal {
  final double upLine;
  final double dnLine;
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
      double previousClose = i == 0 ? candles[i].close : candles[i - 1].close;
      double tr = [
        candles[i].high - candles[i].low,
        (candles[i].high - previousClose).abs(),
        (candles[i].low - previousClose).abs()
      ].reduce((a, b) => a > b ? a : b);
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
        double initial = trList.sublist(0, period).reduce((a, b) => a + b) / period;
        atr.add(initial);
      } else {
        double prevAtr = atr[i - 1];
        double newAtr = ((prevAtr * (period - 1)) + trList[i]) / period;
        atr.add(newAtr);
      }
    }
    return atr;
  }

  List<SfiSignal> calculateSfiMagic(List<Candle> candles, {
    int period = 10,
    double multiplier = 1.7,
  }) {
    final trList = calculateTR(candles);
    final atrListWilder = calculateWilderATR(trList, period);
    List<SfiSignal> signals = [];
    if (candles.isEmpty) return signals;

    double prevUp = candles[0].ohlc4 - multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    double prevDn = candles[0].ohlc4 + multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    int previousTrend = 1;

    for (int i = 0; i < candles.length; i++) {
      Candle c = candles[i];
      double atr = (i < atrListWilder.length) ? atrListWilder[i] : (atrListWilder.isNotEmpty ? atrListWilder.last : 0.0);
      double ohlc4 = c.ohlc4;
      double rawUp = ohlc4 - multiplier * atr;
      double rawDn = ohlc4 + multiplier * atr;

      double up;
      double dn;
      if (i > 0) {
        up = candles[i - 1].close > prevUp ? max(rawUp, prevUp) : rawUp;
        dn = candles[i - 1].close < prevDn ? min(rawDn, prevDn) : rawDn;
      } else {
        up = rawUp;
        dn = rawDn;
      }

      int trend = previousTrend;
      if (previousTrend == -1 && c.close > prevDn) {
        trend = 1;
      } else if (previousTrend == 1 && c.close < prevUp) {
        trend = -1;
      }

      bool buySignal = previousTrend == -1 && trend == 1;
      bool sellSignal = previousTrend == 1 && trend == -1;

      signals.add(SfiSignal(upLine: up, dnLine: dn, trend: trend, buySignal: buySignal, sellSignal: sellSignal));

      prevUp = up;
      prevDn = dn;
      previousTrend = trend;
    }
    return signals;
  }
}

// ============================================================================
// MAIN — Configure and start
// ============================================================================

Future<void> main() async {
  // ─── Fill in YOUR credentials ───
  final config = BotConfig(
    uid: 'YOUR_UID',
    mtoken: 'YOUR_MTOKEN',
    htoken: 'YOUR_HTOKEN',

    // Trading pair
    symbol: 'SOL_USDT',
    interval: 'Min5',
    candleLimit: 1000,
    candleOffset: 26,    // 0 = fetch up to the most recently closed candle

    // Risk
    leverage: 10,
    positionSizePct: 2.0,      // 2% of available balance per trade
    tp1AtrMultiplier: 1.0,     // TP1 at 1x ATR
    atrPeriod: 14,

    // Loop every 5 minutes (matching candle TF)
    loopInterval: Duration(minutes: 5),

    // Indicators
    sfiPeriod: 10,
    sfiMultiplier: 1.7,
    srDetectionLength: 15,
    srMargin: 2.0,
  );

  final bot = TradingBot(config);
  bot.start();

  // Keep alive — the bot runs on a timer.
  // Press Ctrl+C to stop, or call bot.stop() programmatically.
  print('[MAIN] Bot is running. Press Ctrl+C to stop.\n');

  // Keep the process alive
  await Completer<void>().future;
}
