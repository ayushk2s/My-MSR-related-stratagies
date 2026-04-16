import 'dart:async';
import 'dart:math';

import 'model.dart';
import 'support_resistance_2.dart';

import 'msr_asterdex/fetch_candle_data.dart';
import 'msr_asterdex/account_data.dart';
import 'msr_asterdex/aster_recursive_trade_function.dart';

// ============================================================================
// B07 DEPLOY-READY CONFIG
// Validated: SFI(7,1.5) / px1.0 / TP0.60 / SL0.20 / EMAno
// OOS CAGR +37.0% | MaxDD 11.6% | Calmar 3.18 | 4/4 WF folds profitable
// BNB excluded (lone loser). All other 8/9 assets positive.
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
  final double positionSizePct;   // px1.0 — 1% of balance per trade
  final int quantityPrecision;

  // ─── Timing ───
  final Duration loopInterval;

  // ─── SFI Settings — B07: period=7, multiplier=1.5 ───
  final int sfiPeriod;            // 7
  final double sfiMultiplier;     // 1.5

  // ─── B07 TP / SL ATR Multipliers ───
  final double tp1AtrMult;        // TP0.60  → TP1 at entry ± 0.60 × ATR(14)
  final double slAtrMult;         // SL0.20  → initial SL at entry ∓ 0.20 × ATR(14)

  // ─── SR Settings ───
  final int srDetectionLength;
  final double srMargin;

  /// 0 = live (normal). >0 = historical replay (no alignment wait).
  final int candleOffset;

  const BotConfig({
    required this.apiKey,
    required this.secretKey,
    this.symbol            = 'SOLUSDT',
    this.interval          = '5m',
    this.candleLimit       = 1000,
    this.leverage          = 10,
    this.positionSizePct   = 1.0,    // B07: px1.0
    this.quantityPrecision = 3,
    this.loopInterval      = const Duration(minutes: 5),
    this.sfiPeriod         = 7,      // B07: SFI period 7
    this.sfiMultiplier     = 1.5,    // B07: SFI multiplier 1.5
    this.tp1AtrMult        = 0.60,   // B07: TP0.60
    this.slAtrMult         = 0.20,   // B07: SL0.20
    this.srDetectionLength = 15,
    this.srMargin          = 2.0,
    this.candleOffset      = 0,
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

  /// targets[0] = TP1 (entry ± tp1AtrMult×ATR) — 60% closed here
  /// targets[1..4] = TP2–TP5 at ATR × [4.5, 7, 9, 11]
  final List<ProfitTarget> targets;
  final String zoneInfo;

  /// Fixed initial SL = entry ∓ slAtrMult×ATR.
  /// After TP1 switches to SFI trailing (with breakeven floor).
  final double initialSl;
  double currentSl;

  double remainingQty;
  bool tp1Hit = false;
  bool tp2Hit = false;
  double realizedPnl = 0.0;

  ActiveTrade({
    required this.id,
    required this.direction,
    required this.entryTime,
    required this.entryPrice,
    required this.totalQty,
    required this.targets,
    required this.zoneInfo,
    required this.initialSl,
  })  : currentSl    = initialSl,
        remainingQty = totalQty;

  double unrealizedPnl(double currentPrice) {
    if (remainingQty <= 0) return 0.0;
    return direction == TradeDirection.long
        ? (currentPrice - entryPrice) * remainingQty
        : (entryPrice - currentPrice) * remainingQty;
  }

  double totalPnl(double currentPrice) =>
      realizedPnl + unrealizedPnl(currentPrice);

  double totalPnlPct(double currentPrice) {
    double notional = entryPrice * totalQty;
    return notional > 0 ? (totalPnl(currentPrice) / notional) * 100.0 : 0.0;
  }

  @override
  String toString() {
    String dir    = direction == TradeDirection.long ? 'LONG' : 'SHORT';
    String tgtStr = targets
        .map((t) => '${t.price.toStringAsFixed(4)}${t.reached ? "✅" : ""}')
        .join(' | ');
    return '#$id $dir entry=${entryPrice.toStringAsFixed(4)} qty=$totalQty '
        'sl=${currentSl.toStringAsFixed(4)} tp1Hit=$tp1Hit '
        'remaining=$remainingQty realized=${realizedPnl.toStringAsFixed(4)} zone=$zoneInfo\n'
        '  targets: $tgtStr';
  }
}

// ============================================================================
// TRADING BOT  — B07
// ============================================================================

class TradingBot {
  final BotConfig config;

  final List<ActiveTrade> _openTrades  = [];
  int  _tradeCounter = 0;
  bool _running      = false;
  Timer? _timer;

  // ─── Session stats ───
  double _sessionRealizedPnl = 0.0;
  int    _sessionTotalTrades = 0;
  int    _sessionWins        = 0;
  int    _sessionLosses      = 0;
  final  List<double> _closedTradePnls = [];
  DateTime? _sessionStart;

  late int _quantityPrecision;

  TradingBot(this.config) : _quantityPrecision = config.quantityPrecision;

  // ─── START / STOP ──────────────────────────────────────────────

  void start() {
    if (_running) { print('[BOT] Already running.'); return; }
    _running       = true;
    _sessionStart  = DateTime.now();

    print('╔═══════════════════════════════════════════════════════════════╗');
    print('║         ASTERDEX B07 LIVE TRADING BOT — DEPLOY-READY         ║');
    print('╠═══════════════════════════════════════════════════════════════╣');
    print('║  Symbol   : ${config.symbol.padRight(22)}                    ║');
    print('║  Interval : ${config.interval.padRight(22)}                    ║');
    print('║  Leverage : ${config.leverage.toString().padRight(22)}                    ║');
    print('║  Risk/Trade: ${'${config.positionSizePct}%'.padRight(21)}                    ║');
    print('║  SFI      : period=${config.sfiPeriod} mult=${config.sfiMultiplier}             ║');
    print('║  TP1      : ATR × ${config.tp1AtrMult} (60% close)                   ║');
    print('║  Init SL  : ATR × ${config.slAtrMult} (fixed → trail SFI)           ║');
    print('║  EMA      : disabled                                          ║');
    print('║  OOS CAGR : +37.0% | MaxDD 11.6% | Calmar 3.18              ║');
    print('╚═══════════════════════════════════════════════════════════════╝');
    print('');

    _setupLeverageAndAlign();
  }

  Future<void> _setupLeverageAndAlign() async {
    try {
      await AsterdexFutureFunctions.setLeverage(
        config.symbol, config.leverage.toInt(),
        config.apiKey, config.secretKey,
      );
    } catch (e) { print('[BOT] WARNING: Could not set leverage — $e'); }

    try {
      final balance     = await AsterdexFutureFunctions.getAvailableBalance(
          config.apiKey, config.secretKey);
      final tradeCapital = balance * (config.positionSizePct / 100);
      final positionSize = tradeCapital * config.leverage;
      print('[BOT] Balance        : \$${balance.toStringAsFixed(2)}');
      print('[BOT] Capital/Trade  : \$${tradeCapital.toStringAsFixed(2)} (${config.positionSizePct}%)');
      print('[BOT] Position Size  : \$${positionSize.toStringAsFixed(2)} (${config.leverage}x)');
    } catch (e) { print('[BOT] WARNING: Could not fetch balance — $e'); }

    try {
      _quantityPrecision = await AsterdexFutureFunctions
          .getQuantityPrecision(config.symbol);
      print('[BOT] Qty precision  : $_quantityPrecision dp for ${config.symbol}');
    } catch (e) {
      print('[BOT] WARNING: qty precision fallback to config ($_quantityPrecision) — $e');
    }

    await _alignAndStart();
  }

  Future<void> _alignAndStart() async {
    if (config.candleOffset > 0) {
      print('[BOT] Historical mode (offset=${config.candleOffset}) — running immediately.');
      _tick();
      return;
    }

    final intervalSec     = config.loopInterval.inSeconds;
    final now             = DateTime.now();
    final secondsInto     = (now.minute * 60 + now.second) % intervalSec;
    final secondsToNext   = intervalSec - secondsInto;
    final waitSec         = secondsToNext + 2;
    final nextCandle      = now.add(Duration(seconds: waitSec));

    print('[BOT] Aligning to candle boundary — first tick at '
        '${nextCandle.hour.toString().padLeft(2, "0")}:'
        '${nextCandle.minute.toString().padLeft(2, "0")}:'
        '${nextCandle.second.toString().padLeft(2, "0")} (waiting ${waitSec}s)');

    await Future.delayed(Duration(seconds: waitSec));
    if (!_running) return;

    _tick();
    _timer = Timer.periodic(config.loopInterval, (_) => _tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    print('[BOT] ${config.symbol} stopped.');
  }

  // ─── MAIN LOOP ─────────────────────────────────────────────────

  Future<void> _tick() async {
    if (!_running) return;

    try {
      final now = DateTime.now();
      print('\n────────────────────────────────────────────────────');
      print('[BOT][${config.symbol}] Tick @ ${now.toIso8601String()}');

      // 1. Fetch candles
      final candles = await fetchBinanceCandles(
        symbol:   config.symbol,
        interval: config.interval,
        limit:    config.candleLimit,
        offset:   config.candleOffset,
      );

      if (candles.length < 50) {
        print('[BOT] Not enough candles (${candles.length}). Skipping.');
        return;
      }

      final lastC  = candles.last;
      final ct     = lastC.time.toLocal();
      final timeStr =
          '${ct.year}-${ct.month.toString().padLeft(2, '0')}-${ct.day.toString().padLeft(2, '0')} '
          '${ct.hour.toString().padLeft(2, '0')}:${ct.minute.toString().padLeft(2, '0')}:'
          '${ct.second.toString().padLeft(2, '0')} (local)';

      print('[BOT] $timeStr  O=${lastC.open.toStringAsFixed(4)}'
          ' H=${lastC.high.toStringAsFixed(4)}'
          ' L=${lastC.low.toStringAsFixed(4)}'
          ' C=${lastC.close.toStringAsFixed(4)}');

      // 2. B07 SFI — period=7, multiplier=1.5
      final sfi        = SfiIndicator();
      final sfiSignals = sfi.calculateSfiMagic(
        candles,
        period:     config.sfiPeriod,      // 7
        multiplier: config.sfiMultiplier,  // 1.5
      );
      final currentSfi = sfiSignals.last;

      // sfi.loop() returns ATR(14)-based targets + trailing SL lines
      final sfiData = sfi.loop(
        candles,
        tp1Mult: config.tp1AtrMult,  // 0.60
        slMult:  config.slAtrMult,   // 0.20
        sfiPeriod:     config.sfiPeriod,
        sfiMultiplier: config.sfiMultiplier,
      );

      // 3. SR zones (active only — broken zones excluded)
      final srIndicator = SupportResistanceIndicator(
        detectionLength: config.srDetectionLength,
        srMargin:        config.srMargin,
        avoidFBO:        true,
        checkHist:       true,
        showManip:       true,
        manipMargin:     1.3,
      );
      final srResult       = srIndicator.calculate(candles);
      final activeSupports = srResult.support.where((z) => z.isActive).toList()
        ..sort((a, b) => b.boxRight.compareTo(a.boxRight));
      final activeResistances = srResult.resistance.where((z) => z.isActive).toList()
        ..sort((a, b) => b.boxRight.compareTo(a.boxRight));

      final s0 = activeSupports.isNotEmpty
          ? 'S=${activeSupports.first.boxBottom.toStringAsFixed(4)}'
            '-${activeSupports.first.boxTop.toStringAsFixed(4)}'
            '(bar${activeSupports.first.boxRight})'
          : 'S=none';
      final r0 = activeResistances.isNotEmpty
          ? 'R=${activeResistances.first.boxBottom.toStringAsFixed(4)}'
            '-${activeResistances.first.boxTop.toStringAsFixed(4)}'
            '(bar${activeResistances.first.boxRight})'
          : 'R=none';

      print('[BOT] SFI trend=${currentSfi.trend > 0 ? "+1" : "-1"}'
          '  upLine=${currentSfi.upLine.toStringAsFixed(4)}'
          '  dnLine=${currentSfi.dnLine.toStringAsFixed(4)}'
          '  $s0  $r0'
          '${currentSfi.buySignal ? "  ▲ BUY FLIP" : ""}'
          '${currentSfi.sellSignal ? "  ▼ SELL FLIP" : ""}');

      // 4. Manage open trades
      await _manageOpenTrades(currentSfi, lastC);

      // 5. Check for new entries
      await _checkEntries(
          currentSfi, sfiData, lastC, activeSupports, activeResistances);

      // 6. Dashboard
      _printPnlDashboard(lastC.close);

    } catch (e, st) {
      print('[BOT][${config.symbol}] ERROR: $e');
      print(st);
    }
  }

  // ─── MANAGE OPEN TRADES ────────────────────────────────────────

  Future<void> _manageOpenTrades(SfiSignal sfi, Candle lastCandle) async {
    final toRemove = <ActiveTrade>[];

    for (final trade in _openTrades) {
      // ── Update SL ──
      // Before TP1: use fixed initial SL (ATR-based).
      // After TP1:  trail with SFI line, floored at breakeven.
      if (!trade.tp1Hit) {
        trade.currentSl = trade.initialSl; // hold initial SL until TP1
      } else {
        if (trade.direction == TradeDirection.long) {
          final rawSl = sfi.upLine;
          trade.currentSl = max(rawSl, trade.entryPrice); // breakeven floor
        } else {
          final rawSl = sfi.dnLine;
          trade.currentSl = min(rawSl, trade.entryPrice); // breakeven ceiling
        }
      }

      // Mark visual hits on all targets
      for (final t in trade.targets) {
        if (!t.reached) {
          if (trade.direction == TradeDirection.long  && lastCandle.high >= t.price) t.reached = true;
          if (trade.direction == TradeDirection.short && lastCandle.low  <= t.price) t.reached = true;
        }
      }

      // ── LONG management ──
      if (trade.direction == TradeDirection.long) {

        // TP1: close 60% at targets[0] (entry + tp1AtrMult × ATR)
        if (!trade.tp1Hit && trade.targets.isNotEmpty &&
            lastCandle.high >= trade.targets[0].price) {
          final closeQty  = _roundQty(trade.totalQty * 0.60);
          if (closeQty > 0) {
            final closePnl = (trade.targets[0].price - trade.entryPrice) * closeQty;
            trade.realizedPnl  += closePnl;
            trade.remainingQty  = _roundQty(trade.remainingQty - closeQty);
            trade.tp1Hit        = true;
            print('[TRADE] LONG #${trade.id} TP1 60% @ '
                '${trade.targets[0].price.toStringAsFixed(4)}'
                ' qty=$closeQty PnL +${closePnl.toStringAsFixed(4)}');
            await _exitPosition(trade: trade, closeQty: closeQty, reason: 'TP1_60pct');
          }
        }

        // TP2: close 30% at targets[1]
        if (trade.tp1Hit && !trade.tp2Hit && trade.targets.length > 1 &&
            lastCandle.high >= trade.targets[1].price) {
          final closeQty   = _roundQty(trade.totalQty * 0.30);
          final actualClose = closeQty <= trade.remainingQty ? closeQty : trade.remainingQty;
          if (actualClose > 0) {
            final closePnl  = (trade.targets[1].price - trade.entryPrice) * actualClose;
            trade.realizedPnl  += closePnl;
            trade.remainingQty  = _roundQty(trade.remainingQty - actualClose);
            trade.tp2Hit        = true;
            print('[TRADE] LONG #${trade.id} TP2 30% @ '
                '${trade.targets[1].price.toStringAsFixed(4)}'
                ' qty=$actualClose PnL +${closePnl.toStringAsFixed(4)}');
            await _exitPosition(trade: trade, closeQty: actualClose, reason: 'TP2_30pct');
          }
        }

        if (trade.remainingQty <= 0) {
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
          continue;
        }

        // SFI flip → exit all remaining
        if (sfi.sellSignal) {
          final closePnl = (lastCandle.close - trade.entryPrice) * trade.remainingQty;
          trade.realizedPnl += closePnl;
          print('[TRADE] LONG #${trade.id} EXIT (SFI FLIP) @ '
              '${lastCandle.close.toStringAsFixed(4)}'
              ' remaining=${trade.remainingQty}'
              ' PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}');
          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: 'SFI_FLIP');
          trade.remainingQty = 0;
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
          continue;
        }

        // SL hit
        if (lastCandle.low <= trade.currentSl) {
          final closePnl = (trade.currentSl - trade.entryPrice) * trade.remainingQty;
          trade.realizedPnl += closePnl;
          print('[TRADE] LONG #${trade.id} SL @ '
              '${trade.currentSl.toStringAsFixed(4)}'
              ' remaining=${trade.remainingQty}'
              ' PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}');
          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: 'SL');
          trade.remainingQty = 0;
          _recordClosedTrade(trade, trade.currentSl);
          toRemove.add(trade);
        }

      } else {
        // ── SHORT management ──

        // TP1: close 60%
        if (!trade.tp1Hit && trade.targets.isNotEmpty &&
            lastCandle.low <= trade.targets[0].price) {
          final closeQty  = _roundQty(trade.totalQty * 0.60);
          if (closeQty > 0) {
            final closePnl = (trade.entryPrice - trade.targets[0].price) * closeQty;
            trade.realizedPnl  += closePnl;
            trade.remainingQty  = _roundQty(trade.remainingQty - closeQty);
            trade.tp1Hit        = true;
            print('[TRADE] SHORT #${trade.id} TP1 60% @ '
                '${trade.targets[0].price.toStringAsFixed(4)}'
                ' qty=$closeQty PnL +${closePnl.toStringAsFixed(4)}');
            await _exitPosition(trade: trade, closeQty: closeQty, reason: 'TP1_60pct');
          }
        }

        // TP2: close 30%
        if (trade.tp1Hit && !trade.tp2Hit && trade.targets.length > 1 &&
            lastCandle.low <= trade.targets[1].price) {
          final closeQty   = _roundQty(trade.totalQty * 0.30);
          final actualClose = closeQty <= trade.remainingQty ? closeQty : trade.remainingQty;
          if (actualClose > 0) {
            final closePnl  = (trade.entryPrice - trade.targets[1].price) * actualClose;
            trade.realizedPnl  += closePnl;
            trade.remainingQty  = _roundQty(trade.remainingQty - actualClose);
            trade.tp2Hit        = true;
            print('[TRADE] SHORT #${trade.id} TP2 30% @ '
                '${trade.targets[1].price.toStringAsFixed(4)}'
                ' qty=$actualClose PnL +${closePnl.toStringAsFixed(4)}');
            await _exitPosition(trade: trade, closeQty: actualClose, reason: 'TP2_30pct');
          }
        }

        if (trade.remainingQty <= 0) {
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
          continue;
        }

        // SFI flip → exit all remaining
        if (sfi.buySignal) {
          final closePnl = (trade.entryPrice - lastCandle.close) * trade.remainingQty;
          trade.realizedPnl += closePnl;
          print('[TRADE] SHORT #${trade.id} EXIT (SFI FLIP) @ '
              '${lastCandle.close.toStringAsFixed(4)}'
              ' remaining=${trade.remainingQty}'
              ' PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}');
          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: 'SFI_FLIP');
          trade.remainingQty = 0;
          _recordClosedTrade(trade, lastCandle.close);
          toRemove.add(trade);
          continue;
        }

        // SL hit
        if (lastCandle.high >= trade.currentSl) {
          final closePnl = (trade.entryPrice - trade.currentSl) * trade.remainingQty;
          trade.realizedPnl += closePnl;
          print('[TRADE] SHORT #${trade.id} SL @ '
              '${trade.currentSl.toStringAsFixed(4)}'
              ' remaining=${trade.remainingQty}'
              ' PnL ${closePnl >= 0 ? "+" : ""}${closePnl.toStringAsFixed(4)}');
          await _exitPosition(trade: trade, closeQty: trade.remainingQty, reason: 'SL');
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

    final sfiTargets = sfiData['targets'] as List<ProfitTarget>;
    final initialSlLong  = sfiData['initialSlLong']  as double;
    final initialSlShort = sfiData['initialSlShort'] as double;
    if (sfiTargets.isEmpty) return;

    // ── LONG: SFI flips to +1 + candle wicks into top S[0] ──
    if (currentSfi.buySignal && _openTrades.isEmpty && activeSupports.isNotEmpty) {
      final zone         = activeSupports.first;
      final zoneWidthPct = (zone.boxTop - zone.boxBottom) / lastCandle.close;
      final touchesSupport = zoneWidthPct >= 0.003 &&
          lastCandle.low >= zone.boxBottom &&
          lastCandle.low <= zone.boxTop;

      print('[ENTRY CHECK] LONG: touchSupport=$touchesSupport'
          '  low=${lastCandle.low.toStringAsFixed(4)}'
          '  S[0]=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}'
          '  width=${(zoneWidthPct * 100).toStringAsFixed(2)}%'
          '  initSL=${initialSlLong.toStringAsFixed(4)}');

      if (touchesSupport) {
        final zoneInfo = 'SUP ${zone.boxBottom.toStringAsFixed(2)}-${zone.boxTop.toStringAsFixed(2)}';
        print('[SIGNAL] ▲ LONG entry! Price=${lastCandle.close.toStringAsFixed(4)}'
            ' Zone=$zoneInfo SL=${initialSlLong.toStringAsFixed(4)}'
            ' Targets=${sfiTargets.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');

        await _openPosition(
          direction:  TradeDirection.long,
          price:      lastCandle.close,
          targets:    sfiTargets,
          initialSl:  initialSlLong,
          zoneInfo:   zoneInfo,
        );
      }
    }

    // ── SHORT: SFI flips to -1 + candle wicks into bottom R[0] ──
    if (currentSfi.sellSignal && _openTrades.isEmpty && activeResistances.isNotEmpty) {
      final zone            = activeResistances.first;
      final zoneWidthPct    = (zone.boxTop - zone.boxBottom) / lastCandle.close;
      final touchesResistance = zoneWidthPct >= 0.003 &&
          lastCandle.high >= zone.boxBottom &&
          lastCandle.high <= zone.boxTop;

      print('[ENTRY CHECK] SHORT: touchResistance=$touchesResistance'
          '  high=${lastCandle.high.toStringAsFixed(4)}'
          '  R[0]=${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}'
          '  width=${(zoneWidthPct * 100).toStringAsFixed(2)}%'
          '  initSL=${initialSlShort.toStringAsFixed(4)}');

      if (touchesResistance) {
        final zoneInfo = 'RES ${zone.boxBottom.toStringAsFixed(2)}-${zone.boxTop.toStringAsFixed(2)}';
        print('[SIGNAL] ▼ SHORT entry! Price=${lastCandle.close.toStringAsFixed(4)}'
            ' Zone=$zoneInfo SL=${initialSlShort.toStringAsFixed(4)}'
            ' Targets=${sfiTargets.map((t) => t.price.toStringAsFixed(4)).join(" | ")}');

        await _openPosition(
          direction:  TradeDirection.short,
          price:      lastCandle.close,
          targets:    sfiTargets,
          initialSl:  initialSlShort,
          zoneInfo:   zoneInfo,
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
      final available  = await AsterdexFutureFunctions.getAvailableBalance(
          config.apiKey, config.secretKey);
      final riskUsdt   = available * (config.positionSizePct / 100.0);
      final notional   = riskUsdt * config.leverage;
      final rawQty     = notional / price;
      final quantity   = _roundQty(rawQty);

      if (quantity <= 0) {
        print('[TRADE] Quantity too small ($rawQty). Skipping.');
        return;
      }

      final side         = direction == TradeDirection.long ? 'BUY'  : 'SELL';
      final positionSide = direction == TradeDirection.long ? 'LONG' : 'SHORT';

      await AsterRecursiveTradeFunction.tradeLimit(
        symbol:       config.symbol,
        side:         side,
        positionSide: positionSide,
        vol:          quantity,
        leverage:     config.leverage.toInt(),
      );

      _tradeCounter++;
      final trade = ActiveTrade(
        id:         _tradeCounter,
        direction:  direction,
        entryTime:  DateTime.now(),
        entryPrice: price,
        totalQty:   quantity,
        targets:    targets,
        zoneInfo:   zoneInfo,
        initialSl:  initialSl,
      );
      _openTrades.add(trade);

      final dir = direction == TradeDirection.long ? 'LONG' : 'SHORT';
      print('[TRADE] ✅ $dir #${trade.id} opened @ $price qty=$quantity'
          ' initSL=${initialSl.toStringAsFixed(4)} zone=$zoneInfo');
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

      await AsterRecursiveTradeFunction.exitPartialTrade(
        symbol:       config.symbol,
        side:         side,
        positionSide: positionSide,
        vol:          closeQty,
      );

      print('[TRADE] ✅ Closed $closeQty of #${trade.id} ($reason)');
    } catch (e) {
      print('[TRADE] ❌ Failed to close #${trade.id}: $e');
    }
  }

  // ─── HELPERS ───────────────────────────────────────────────────

  double _roundQty(double qty) {
    final factor = pow(10, _quantityPrecision).toDouble();
    return (qty * factor).floorToDouble() / factor;
  }

  void _recordClosedTrade(ActiveTrade trade, double closePrice) {
    final finalPnl = trade.totalPnl(closePrice);
    _sessionRealizedPnl += finalPnl;
    _sessionTotalTrades++;
    finalPnl > 0 ? _sessionWins++ : _sessionLosses++;
    _closedTradePnls.add(finalPnl);
  }

  void _printPnlDashboard(double currentPrice) {
    final totalUnrealized = _openTrades.fold(
        0.0, (sum, t) => sum + t.unrealizedPnl(currentPrice));
    final totalPnl  = _sessionRealizedPnl + totalUnrealized;
    final winRate   = _sessionTotalTrades > 0
        ? (_sessionWins / _sessionTotalTrades) * 100.0
        : 0.0;

    String duration = '';
    if (_sessionStart != null) {
      final d = DateTime.now().difference(_sessionStart!);
      duration = '${d.inHours}h ${d.inMinutes % 60}m';
    }

    final bestTrade  = _closedTradePnls.isNotEmpty
        ? _closedTradePnls.reduce(max) : 0.0;
    final worstTrade = _closedTradePnls.isNotEmpty
        ? _closedTradePnls.reduce(min) : 0.0;

    print('');
    print('┌────────────────────── PnL DASHBOARD [${config.symbol}] ─────────────────────┐');
    print('│  Price: ${currentPrice.toStringAsFixed(4).padRight(16)} Session: ${duration.padRight(14)}          │');
    print('├──────────────────────────────────────────────────────────────────────────┤');
    print('│  Realized  : ${_fmtPnl(_sessionRealizedPnl).padRight(18)} Unrealized: ${_fmtPnl(totalUnrealized).padRight(14)}│');
    print('│  TOTAL PnL : ${_fmtPnl(totalPnl).padRight(57)}│');
    print('├──────────────────────────────────────────────────────────────────────────┤');
    print('│  Trades: ${_sessionTotalTrades.toString().padRight(5)}'
        ' Wins: ${_sessionWins.toString().padRight(5)}'
        ' Losses: ${_sessionLosses.toString().padRight(5)}'
        ' WR: ${winRate.toStringAsFixed(1).padRight(6)}%          │');
    print('│  Best: ${_fmtPnl(bestTrade).padRight(18)}'
        ' Worst: ${_fmtPnl(worstTrade).padRight(20)}            │');
    print('├──────────────────────────────────────────────────────────────────────────┤');

    if (_openTrades.isEmpty) {
      print('│  No open positions                                                       │');
    } else {
      for (final t in _openTrades) {
        final dir   = t.direction == TradeDirection.long ? '▲ LONG ' : '▼ SHORT';
        final uPnl  = t.unrealizedPnl(currentPrice);
        final tPnl  = t.totalPnl(currentPrice);
        final tPct  = t.totalPnlPct(currentPrice);
        final sign  = tPnl >= 0 ? '+' : '';
        final tgtStr = t.targets
            .map((tg) => '${tg.price.toStringAsFixed(2)}${tg.reached ? "✅" : ""}')
            .join(' ');
        print('│  #${t.id.toString().padRight(4)} $dir  entry=${t.entryPrice.toStringAsFixed(4)}'
            '  qty=${t.remainingQty}/${t.totalQty}'
            '  uPnL=${_fmtPnl(uPnl)}'
            '  tot=$sign${tPnl.toStringAsFixed(2)} ($sign${tPct.toStringAsFixed(2)}%)'
            '${t.tp1Hit ? " TP1✓" : ""}');
        print('│    initSL=${t.initialSl.toStringAsFixed(4)}'
            '  curSL=${t.currentSl.toStringAsFixed(4)}'
            '  zone=${t.zoneInfo}');
        print('│    Targets: $tgtStr');
      }
    }

    print('└──────────────────────────────────────────────────────────────────────────┘');
    print('');
  }

  String _fmtPnl(double val) {
    final sign = val >= 0 ? '+' : '';
    return '$sign${val.toStringAsFixed(4)}';
  }
}

// ============================================================================
// SFI INDICATOR — B07: period=7, multiplier=1.5
// ============================================================================

class SfiSignal {
  final double upLine;
  final double dnLine;
  final int    trend;
  final bool   buySignal;
  final bool   sellSignal;

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
      final prevClose = i == 0 ? candles[i].close : candles[i - 1].close;
      final tr = [
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

  List<SfiSignal> calculateSfiMagic(
    List<Candle> candles, {
    int    period     = 7,    // B07 default
    double multiplier = 1.5,  // B07 default
  }) {
    final trList    = calculateTR(candles);
    final atrWilder = calculateWilderATR(trList, period);
    List<SfiSignal> signals = [];
    if (candles.isEmpty) return signals;

    double prevUp          = candles[0].ohlc4 - multiplier * (atrWilder.isNotEmpty ? atrWilder[0] : 0.0);
    double prevDn          = candles[0].ohlc4 + multiplier * (atrWilder.isNotEmpty ? atrWilder[0] : 0.0);
    int    previousTrend   = 1;

    for (int i = 0; i < candles.length; i++) {
      final c   = candles[i];
      final atr = i < atrWilder.length ? atrWilder[i] : (atrWilder.isNotEmpty ? atrWilder.last : 0.0);
      final rawUp = c.ohlc4 - multiplier * atr;
      final rawDn = c.ohlc4 + multiplier * atr;

      double up, dn;
      if (i > 0) {
        up = candles[i - 1].close > prevUp ? max(rawUp, prevUp) : rawUp;
        dn = candles[i - 1].close < prevDn ? min(rawDn, prevDn) : rawDn;
      } else {
        up = rawUp;
        dn = rawDn;
      }

      int trend = previousTrend;
      if (previousTrend == -1 && c.close > prevDn) { trend =  1; }
      else if (previousTrend == 1 && c.close < prevUp) { trend = -1; }

      signals.add(SfiSignal(
        upLine:     up,
        dnLine:     dn,
        trend:      trend,
        buySignal:  previousTrend == -1 && trend ==  1,
        sellSignal: previousTrend ==  1 && trend == -1,
      ));

      prevUp = up;
      prevDn = dn;
      previousTrend = trend;
    }
    return signals;
  }

  
  Map<String, dynamic> loop(
    List<Candle> candles, {
    double tp1Mult      = 0.60,  // B07 TP
    double slMult       = 0.20,  // B07 SL
    int    sfiPeriod    = 7,
    double sfiMultiplier = 1.5,
  }) {
    // Target multipliers: TP1 at tp1Mult, then standard runners
    final atrMultipliers = [tp1Mult, 4.5, 7.0, 9.0, 11.0];

    final trList       = calculateTR(candles);
    final atrTargets   = calculateWilderATR(trList, 14); // ATR(14) for targets & SL
    final signals      = calculateSfiMagic(
        candles, period: sfiPeriod, multiplier: sfiMultiplier);

    List<ProfitTarget> lastTargets    = [];
    int    lastDirection = 1;
    double lastEntry     = 0.0;
    double lastAtr       = 0.0;

    for (int i = 0; i < candles.length; i++) {
      final s   = signals[i];
      final atr = i < atrTargets.length
          ? atrTargets[i]
          : (atrTargets.isNotEmpty ? atrTargets.last : 0.0);

      if (s.buySignal || s.sellSignal) {
        lastDirection = s.buySignal ? 1 : -1;
        lastEntry     = candles[i].close;
        lastAtr       = atr;
        lastTargets   = atrMultipliers
            .map((m) => ProfitTarget(
                lastDirection == 1
                    ? lastEntry + m * atr
                    : lastEntry - m * atr))
            .toList();
      }
    }

    if (lastTargets.isEmpty) return {};

    // Fixed initial SL based on last flip entry + ATR
    final initialSlLong  = lastEntry - slMult * lastAtr;
    final initialSlShort = lastEntry + slMult * lastAtr;

    return {
      'direction':      lastDirection,
      'entry':          lastEntry,
      'targets':        lastTargets,
      'initialSlLong':  initialSlLong,
      'initialSlShort': initialSlShort,
      // SFI trailing lines (used after TP1)
      'sfiUpLine':      signals.last.upLine,
      'sfiDnLine':      signals.last.dnLine,
    };
  }
}

// ============================================================================
// MAIN — B07 DEPLOY CONFIG
// Validated: SFI(7,1.5)/px1.0/TP0.60/SL0.20/EMAno
// OOS CAGR +37% | MaxDD 11.6% | Calmar 3.18 | 5/5 positive years
// BNB EXCLUDED (lone loser in 8/9 asset sweep)
// ============================================================================

Future<void> main() async {
  // ── Replace with your actual API credentials ──
  const apiKey    = '702bfa60c9818ac2b27b14d78170eade3fd72b1fce1bf49188274c6d362be7fe';
  const secretKey = 'b35258daeaa33e4554cb6bce1fe2e5b7eae6408c5496291a84b12ca42b5390ea';

  // 8 assets validated profitable — BNB omitted (lone -$61 loser)
  final symbols = [
    'SOLUSDT',  
    'ETHUSDT', 
    'BTCUSDT',  
    'XRPUSDT',   
    'AVAXUSDT', 
    'ADAUSDT',   
    'LINKUSDT', 
    'DOTUSDT',  
    // 'BNBUSDT' — EXCLUDED: lone loser (-$61) across full sweep
  ];

  final bots = symbols.map((sym) => TradingBot(BotConfig(
    apiKey:    apiKey,
    secretKey: secretKey,
    symbol:    sym,
    interval:  '5m',
    candleLimit: 1000,

    // ── B07 validated parameters ──
    leverage:          10,
    positionSizePct:   1.0,    // px1.0
    sfiPeriod:         7,      // SFI(7,...)
    sfiMultiplier:     1.5,    // SFI(...,1.5)
    tp1AtrMult:        0.60,   // TP0.60
    slAtrMult:         0.20,   // SL0.20
    // EMA: disabled (EMAno) — no field needed

    srDetectionLength: 15,
    srMargin:          2.0,
    loopInterval:      const Duration(minutes: 5),
    quantityPrecision: 3,      // auto-fetched per symbol at startup
    candleOffset:      0,      // 0 = live trading
  ))).toList();

  // Stagger starts by 2 s to avoid API rate-limit bursts
  for (final bot in bots) {
    bot.start();
    await Future.delayed(const Duration(seconds: 2));
  }

  print('\n[MAIN] All ${symbols.length} B07 bots running'
      ' (${symbols.join(", ")}). Press Ctrl+C to stop.\n');

  // Keep process alive
  await Completer<void>().future;
}