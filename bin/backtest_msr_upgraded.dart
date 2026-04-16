// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';

import 'model.dart';
import 'sf.dart';
import 'support_resistance_2.dart';

// ============================================================================
// CONFIG — mirror of BotConfig in msr_fast_loop_trial.dart
// ============================================================================

// CONFIG — exact mirror of BotConfig in main.dart
class BacktestConfig {
  final String csvPath;
  final String symbol;

  // SFI (matches main.dart defaults)
  final int    sfiPeriod;
  final double sfiMultiplier;

  // SR (matches main.dart defaults)
  final int    srDetectionLength;
  final double srMargin;

  // ATR + TP1
  final int    atrPeriod;
  final double tp1AtrMultiplier;   // ATR multiplier for TP1 price
  final double tp1ClosePct;        // fraction of position to close at TP1 (e.g. 0.9 = 90%)

  // Account / risk (matches main.dart)
  final double initialBalance;
  final double riskPctPerTrade;    // positionSizePct in main.dart
  final double leverage;

  // Fees & slippage (per side, as % of notional)
  final double takerFeePct;
  final double slippagePct;

  // Sliding candle window (matches main.dart candleLimit = 1000)
  final int candleWindow;

  // Warm-up bars before trading begins
  final int warmupBars;

  // ── Multi-timeframe (MTF) — SR zones on higher timeframe ─────────────────
  final String? htfCsvPath;      // path to 15m CSV
  final bool    htfBuild45m;     // true → aggregate 3×15m → 45m
  final int     htfCandleWindow; // rolling window of HTF bars for SR

  // ── HTF trend filter ─────────────────────────────────────────────────────
  // Uses an SMA on HTF candles to determine macro trend direction.
  // Only take LONG when HTF close > SMA, SHORT when HTF close < SMA.
  final bool htfTrendFilter;
  final int  htfTrendMaPeriod;   // SMA period on HTF candles (e.g. 50)

  // ── Session / hour filter ─────────────────────────────────────────────────
  // UTC hours to completely block from trading.
  // Evidence from backtest: 13:00 (WR 26.8%), 11:00 (WR 10.5%), 04:00 (WR 12.5%)
  final List<int> blockHours;

  // ── Volume filter ─────────────────────────────────────────────────────────
  // Skip entry if candle volume < minVolumeRatio × N-bar rolling average.
  // High-volume entries had 35.2% WR vs 27.0% for low volume.
  final double minVolumeRatio;   // e.g. 0.8 = require 80% of avg volume
  final int    volumeAvgPeriod;  // bars to compute rolling volume average

  // ── Minimum R:R gate ──────────────────────────────────────────────────────
  // Skip entry if estimated R:R (TP1 dist / stop dist) < this threshold.
  final double minNaturalRR;

  // ── Volatility gate ───────────────────────────────────────────────────────
  // Skip entry if ATR/price > maxAtrPct%.
  // High ATR% = choppy market where SR zones are less reliable.
  // e.g. 1.2 = skip if ATR > 1.2% of current price.
  final double maxAtrPct;      // 0.0 = disabled

  // ── Calendar / month filter ───────────────────────────────────────────────
  // UTC months to block from trading (1=Jan … 12=Dec).
  // Evidence: July is consistently negative across ADA, SOL, ETH, XRP, TRX.
  final List<int> blockMonths;

  // ── Consecutive loss circuit breaker ─────────────────────────────────────
  // After [maxConsecLosses] losses in a row, pause for [coolingBars] 5m bars.
  // Avoids trading into extended losing streaks / bad regimes.
  final int maxConsecLosses;   // 0 = disabled
  final int coolingBars;       // bars to wait (e.g. 48 = ~4 hours on 5m)

  const BacktestConfig({
    required this.csvPath,
    this.symbol            = 'SOLUSDT',
    this.sfiPeriod         = 10,
    this.sfiMultiplier     = 1.7,
    this.srDetectionLength = 15,
    this.srMargin          = 2.0,
    this.atrPeriod         = 14,
    this.tp1AtrMultiplier  = 1.5,
    this.tp1ClosePct       = 0.1,
    this.initialBalance    = 10000.0,
    this.riskPctPerTrade   = 50.0,
    this.leverage          = 10.0,
    this.takerFeePct       = 0.04,
    this.slippagePct       = 0.02,
    this.candleWindow      = 1000,
    this.warmupBars        = 100,
    this.htfCsvPath,
    this.htfBuild45m       = false,
    this.htfCandleWindow   = 300,
    this.htfTrendFilter    = false,
    this.htfTrendMaPeriod  = 50,
    this.blockHours        = const [],
    this.minVolumeRatio    = 0.0,
    this.volumeAvgPeriod   = 20,
    this.minNaturalRR      = 0.0,
    this.maxAtrPct         = 0.0,
    this.blockMonths       = const [],
    this.maxConsecLosses   = 0,
    this.coolingBars       = 48,
  });
}

// ============================================================================
// TRADE RECORD
// ============================================================================

enum TradeDir  { long, short }
// tp1ThenSignal = TP1 hit then 10% runner closed by signal
// signalOnly    = no TP hit, 100% closed by signal (or trend==±1 after TP1)
enum ExitReason { tp1ThenSignal, signalOnly, endOfData }

class BtTrade {
  final int      id;
  final TradeDir direction;
  final int      entryBar;
  final DateTime entryTime;
  final double   entryPrice;
  final double   quantity;       // total contracts opened
  final double   tp1Price;
  final String   zoneInfo;
  final double   atrAtEntry;
  final double   balanceAtEntry;
  final double   riskAmt;        // notional opened (riskPct × leverage × balance)

  int        exitBar    = 0;
  DateTime   exitTime   = DateTime(0);
  double     exitPrice  = 0;
  ExitReason exitReason = ExitReason.endOfData;
  bool       tp1Hit     = false;
  int        tp1Bar     = 0;
  DateTime   tp1Time    = DateTime(0);
  double     tp1NetPnl  = 0.0;   // net PnL at TP1 partial (after fee)  — 90% qty
  double     tp1Pnl     = 0.0;   // gross PnL at TP1 partial            — 90% qty
  double     remainPnl  = 0.0;   // gross PnL from 10% runner at final exit
  double     feesTotal  = 0.0;   // total fees + slippage paid
  String     s0Info     = '';    // S[0] zone string at entry time
  String     r0Info     = '';    // R[0] zone string at entry time

  // ── Entry candle analysis ────────────────────────────────────────────────
  double entryBodyPct    = 0.0;  // |close-open| / (high-low)  — how much is body vs wicks
  double entryUpperWick  = 0.0;  // upper wick / range
  double entryLowerWick  = 0.0;  // lower wick / range
  bool   entryIsBullish  = true; // close >= open
  double entryVolume     = 0.0;  // raw volume of entry candle
  double entryRangePct   = 0.0;  // (high-low)/close*100 — candle size as % of price
  double entryRangeToAtr = 0.0;  // (high-low)/ATR — is this a wide or narrow candle?
  double naturalStop     = 0.0;  // zone boundary used as natural stop (boxBottom LONG / boxTop SHORT)
  double stopDistPct     = 0.0;  // |entry - naturalStop| / entry * 100
  double naturalRR       = 0.0;  // (tp1Price - entry) / (entry - naturalStop) for LONG

  BtTrade({
    required this.id,
    required this.direction,
    required this.entryBar,
    required this.entryTime,
    required this.entryPrice,
    required this.quantity,
    required this.tp1Price,
    required this.zoneInfo,
    required this.atrAtEntry,
    required this.balanceAtEntry,
    required this.riskAmt,
  });

  double get grossPnl  => tp1Pnl + remainPnl;
  double get totalPnl  => grossPnl - feesTotal;
  int    get holdBars  => exitBar - entryBar;
  bool   get isWin     => totalPnl > 0;
  String get dirStr    => direction == TradeDir.long ? 'LONG ' : 'SHORT';

  double get pnlR   => riskAmt > 0 ? totalPnl / riskAmt : 0.0;
  double get pnlPct => balanceAtEntry > 0 ? (totalPnl / balanceAtEntry) * 100.0 : 0.0;

  String get reasonStr {
    switch (exitReason) {
      case ExitReason.tp1ThenSignal: return 'TP1    ';
      case ExitReason.signalOnly:    return 'SIGNAL ';
      case ExitReason.endOfData:     return 'END_DAT';
    }
  }
}

// ============================================================================
// BACKTESTER
// ============================================================================

class Backtester {
  final BacktestConfig config;
  final _sfi = SfiIndicator();

  Backtester(this.config);

  // ─── HTF alignment ───────────────────────────────────────────────────────
  // Returns the index of the last HTF candle that has FULLY CLOSED before [time].
  // HTF candle at T opens at T and closes at T + interval.
  // A candle is closed when T + interval <= time.
  int _lastClosedHtfIdx(List<Candle> htf, DateTime time, Duration interval) {
    int lo = 0, hi = htf.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (htf[mid].time.add(interval).compareTo(time) <= 0) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  // ─── Zone touch helpers — identical to msr_fast_loop_trial.dart ──────────

  // Only check zones[0] — the most recently formed active zone.
  // SR lists use insert(0,...) so index 0 is always the newest zone.
  //
  // LONG: wick touched zone AND close bounced ABOVE zone top (confirmed bounce)
  SRZone? _bestSupport(Candle c, List<SRZone> zones) {
    if (zones.isEmpty) return null;
    final z = zones.first;
    final ok = c.low  <= z.boxTop
            && c.low  >= z.boxBottom * 0.998
            && c.close >= z.boxTop;   // close must be ABOVE zone top
    return ok ? z : null;
  }

  // SHORT: wick touched zone AND close rejected BELOW zone bottom (confirmed rejection)
  SRZone? _bestResistance(Candle c, List<SRZone> zones) {
    if (zones.isEmpty) return null;
    final z = zones.first;
    final ok = c.high >= z.boxBottom
            && c.high <= z.boxTop * 1.002
            && c.close <= z.boxBottom; // close must be BELOW zone bottom
    return ok ? z : null;
  }

  // ─── Fee helper ──────────────────────────────────────────────────────────

  /// Cost (fees + slippage) for closing [qty] contracts at [price] on one side.
  double _cost(double qty, double price) {
    final rate = (config.takerFeePct + config.slippagePct) / 100.0;
    return qty * price * rate;
  }

  // ─── Main backtest loop ───────────────────────────────────────────────────

  // [htfCandles] = higher-timeframe candles for SR detection.
  // Pass null to fall back to using 5m candles for SR (original behaviour).
  List<BtTrade> run(List<Candle> allCandles, {List<Candle>? htfCandles}) {
    final trades = <BtTrade>[];
    int    tradeId      = 0;
    double balance      = config.initialBalance;
    BtTrade? openLong;
    BtTrade? openShort;

    // Circuit breaker state
    int consecLosses = 0;
    int coolingUntil = 0; // bar index until which trading is paused

    // HTF setup — compute interval from consecutive bars
    final bool useMtf = htfCandles != null && htfCandles.length >= 2;
    final Duration htfInterval = useMtf
        ? htfCandles[1].time.difference(htfCandles[0].time)
        : Duration.zero;

    // Pre-compute HTF SMA for trend filter (causal — bar j uses bars 0..j only)
    final htfSma = <double>[];
    if (config.htfTrendFilter && useMtf) {
      double runSum = 0;
      final p = config.htfTrendMaPeriod;
      for (int j = 0; j < htfCandles.length; j++) {
        runSum += htfCandles[j].close;
        if (j >= p) runSum -= htfCandles[j - p].close;
        htfSma.add(j >= p - 1 ? runSum / p : double.nan);
      }
    }

    // Pre-compute SFI + ATR on the 5m dataset (no lookahead: SFI is causal)
    final allSfi = _sfi.calculateSfiMagic(
      allCandles, period: config.sfiPeriod, multiplier: config.sfiMultiplier,
    );
    final allTR  = _sfi.calculateTR(allCandles);
    final allATR = _sfi.calculateWilderATR(allTR, config.atrPeriod);

    int totalBars = allCandles.length;
    int progressStep = max(1, (totalBars - config.warmupBars) ~/ 20);

    for (int i = config.warmupBars; i < totalBars; i++) {
      if ((i - config.warmupBars) % progressStep == 0) {
        int pct = ((i - config.warmupBars) * 100 ~/ (totalBars - config.warmupBars));
        stdout.write('\r  Progress: $pct%  balance: \$${balance.toStringAsFixed(2)}  trades: ${trades.length}   ');
      }

      final candle = allCandles[i];
      final sfi    = allSfi[i];
      final atr    = i < allATR.length ? allATR[i] : 0.0;

      // ── Manage open LONG — mirrors main.dart _manageOpenTrades ──────────
      if (openLong != null) {
        final ol = openLong!; // pin — Dart flow analysis loses track after closure capture
        if (!ol.tp1Hit && candle.high >= ol.tp1Price) {
          final tp1Qty    = ol.quantity * config.tp1ClosePct;
          final tp1Fee    = _cost(tp1Qty, ol.tp1Price);
          ol.tp1Pnl      = (ol.tp1Price - ol.entryPrice) * tp1Qty;
          ol.tp1NetPnl   = ol.tp1Pnl - tp1Fee;
          ol.feesTotal  += tp1Fee;
          ol.tp1Hit      = true;
          ol.tp1Bar      = i;
          ol.tp1Time     = candle.time;
          balance       += ol.tp1NetPnl;
        }
        final bool sellReverse = ol.tp1Hit
            ? (sfi.sellSignal || sfi.trend == -1)
            : sfi.sellSignal;
        if (sellReverse) {
          final remQty   = ol.tp1Hit ? ol.quantity * (1 - config.tp1ClosePct) : ol.quantity;
          final exitPx   = candle.close;
          final exitFee  = _cost(remQty, exitPx);
          ol.remainPnl   = (exitPx - ol.entryPrice) * remQty;
          ol.feesTotal  += exitFee;
          balance       += ol.remainPnl - exitFee;
          ol.exitBar     = i;
          ol.exitTime    = candle.time;
          ol.exitPrice   = exitPx;
          ol.exitReason  = ol.tp1Hit ? ExitReason.tp1ThenSignal : ExitReason.signalOnly;
          trades.add(ol);
          openLong = null;
          // Circuit breaker tracking
          if (config.maxConsecLosses > 0) {
            if (ol.isWin) { consecLosses = 0; }
            else {
              consecLosses++;
              if (consecLosses >= config.maxConsecLosses) coolingUntil = i + config.coolingBars;
            }
          }
        }
      }

      // ── Manage open SHORT — mirrors main.dart _manageOpenTrades ─────────
      if (openShort != null) {
        final os = openShort!; // pin
        if (!os.tp1Hit && candle.low <= os.tp1Price) {
          final tp1Qty    = os.quantity * config.tp1ClosePct;
          final tp1Fee    = _cost(tp1Qty, os.tp1Price);
          os.tp1Pnl      = (os.entryPrice - os.tp1Price) * tp1Qty;
          os.tp1NetPnl   = os.tp1Pnl - tp1Fee;
          os.feesTotal  += tp1Fee;
          os.tp1Hit      = true;
          os.tp1Bar      = i;
          os.tp1Time     = candle.time;
          balance       += os.tp1NetPnl;
        }
        final bool buyReverse = os.tp1Hit
            ? (sfi.buySignal || sfi.trend == 1)
            : sfi.buySignal;
        if (buyReverse) {
          final remQty   = os.tp1Hit ? os.quantity * (1 - config.tp1ClosePct) : os.quantity;
          final exitPx   = candle.close;
          final exitFee  = _cost(remQty, exitPx);
          os.remainPnl   = (os.entryPrice - exitPx) * remQty;
          os.feesTotal  += exitFee;
          balance       += os.remainPnl - exitFee;
          os.exitBar     = i;
          os.exitTime    = candle.time;
          os.exitPrice   = exitPx;
          os.exitReason  = os.tp1Hit ? ExitReason.tp1ThenSignal : ExitReason.signalOnly;
          trades.add(os);
          openShort = null;
          // Circuit breaker tracking
          if (config.maxConsecLosses > 0) {
            if (os.isWin) { consecLosses = 0; }
            else {
              consecLosses++;
              if (consecLosses >= config.maxConsecLosses) coolingUntil = i + config.coolingBars;
            }
          }
        }
      }

      // ── Entry — ONLY on the exact SFI flip bar ───────────────────────────
      if (atr <= 0) continue;
      if (!sfi.buySignal && !sfi.sellSignal) continue;

      // ── Filter 1: Session / hour gate ────────────────────────────────────
      if (config.blockHours.contains(candle.time.toUtc().hour)) continue;

      // ── Filter 1b: Calendar / month gate ─────────────────────────────────
      if (config.blockMonths.contains(candle.time.toUtc().month)) continue;

      // ── Filter 1c: Circuit breaker — pause after N consecutive losses ─────
      if (config.maxConsecLosses > 0 && i < coolingUntil) continue;

      // ── Filter 1d: Volatility gate — skip high-ATR% entries ──────────────
      // ATR% = ATR / close * 100. High ATR% = choppy/trending too fast for SR.
      if (config.maxAtrPct > 0 && candle.close > 0) {
        if (atr / candle.close * 100.0 > config.maxAtrPct) continue;
      }

      // ── Filter 2: Volume gate ─────────────────────────────────────────────
      if (config.minVolumeRatio > 0 && i >= config.volumeAvgPeriod) {
        final avgVol = allCandles
            .sublist(i - config.volumeAvgPeriod, i)
            .fold(0.0, (s, c) => s + c.volume) / config.volumeAvgPeriod;
        if (avgVol > 0 && candle.volume < config.minVolumeRatio * avgVol) continue;
      }

      // ── SR zone computation + HTF trend filter ────────────────────────────
      int  htfIdx      = -1;
      bool htfUptrend   = true;  // default: allow all longs
      bool htfDowntrend = true;  // default: allow all shorts

      final List<Candle> srWindow;
      if (useMtf) {
        final htf = htfCandles; // non-null — useMtf guarantees this
        htfIdx = _lastClosedHtfIdx(htf, candle.time, htfInterval);
        if (htfIdx < config.srDetectionLength) continue;
        final htfWinStart = max(0, htfIdx + 1 - config.htfCandleWindow);
        srWindow = htf.sublist(htfWinStart, htfIdx + 1);

        // Filter 3: HTF trend — price vs SMA on HTF candles
        if (config.htfTrendFilter && htfSma.isNotEmpty && htfIdx < htfSma.length) {
          final sma = htfSma[htfIdx];
          if (!sma.isNaN) {
            htfUptrend   = htf[htfIdx].close >= sma;
            htfDowntrend = htf[htfIdx].close <= sma;
          }
        }
      } else {
        final winStart = (i + 1 >= config.candleWindow) ? (i + 1 - config.candleWindow) : 0;
        srWindow = allCandles.sublist(winStart, i + 1);
      }

      final srResult = SupportResistanceIndicator(
        detectionLength: config.srDetectionLength,
        srMargin: config.srMargin,
        avoidFBO: true, checkHist: true, showManip: true, manipMargin: 1.3,
      ).calculate(srWindow);
      final supports    = srResult.support.where((z) => z.isActive).toList();
      final resistances = srResult.resistance.where((z) => z.isActive).toList();

      // ── Helper: build and open a trade ───────────────────────────────────
      void openTrade({required bool isLong, required SRZone zone}) {
        final tp1   = isLong
            ? candle.close + config.tp1AtrMultiplier * atr
            : candle.close - config.tp1AtrMultiplier * atr;
        final cStop = isLong ? zone.boxBottom : zone.boxTop;
        final cStopDist = candle.close > 0
            ? (isLong
                ? (candle.close - cStop) / candle.close * 100
                : (cStop - candle.close) / candle.close * 100)
            : 0.0;
        final natRR = cStopDist > 0
            ? (isLong
                ? (tp1 - candle.close) / candle.close * 100 / cStopDist
                : (candle.close - tp1) / candle.close * 100 / cStopDist)
            : 0.0;

        // Filter 4: minimum R:R gate (checked before paying fees)
        if (natRR < config.minNaturalRR) return;

        final notional = balance * (config.riskPctPerTrade / 100.0) * config.leverage;
        final qty      = notional / candle.close;
        final entryFee = _cost(qty, candle.close);
        balance -= entryFee;
        tradeId++;

        final cRange = candle.high - candle.low;
        final cBody  = (candle.close - candle.open).abs();
        final s0 = supports.isNotEmpty    ? supports.first    : null;
        final r0 = resistances.isNotEmpty ? resistances.first : null;

        final t = BtTrade(
          id: tradeId,
          direction:      isLong ? TradeDir.long : TradeDir.short,
          entryBar:       i,
          entryTime:      candle.time,
          entryPrice:     candle.close,
          quantity:       qty,
          tp1Price:       tp1,
          zoneInfo:       isLong
              ? 'SUP ${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}'
              : 'RES ${zone.boxBottom.toStringAsFixed(4)}-${zone.boxTop.toStringAsFixed(4)}',
          atrAtEntry:     atr,
          balanceAtEntry: balance,
          riskAmt:        notional,
        )
          ..feesTotal        = entryFee
          ..s0Info           = s0 != null ? '${s0.boxBottom.toStringAsFixed(4)}-${s0.boxTop.toStringAsFixed(4)}' : 'none'
          ..r0Info           = r0 != null ? '${r0.boxBottom.toStringAsFixed(4)}-${r0.boxTop.toStringAsFixed(4)}' : 'none'
          ..entryBodyPct     = cRange > 0 ? cBody / cRange : 0
          ..entryUpperWick   = cRange > 0 ? (candle.high - max(candle.open, candle.close)) / cRange : 0
          ..entryLowerWick   = cRange > 0 ? (min(candle.open, candle.close) - candle.low) / cRange : 0
          ..entryIsBullish   = candle.close >= candle.open
          ..entryVolume      = candle.volume
          ..entryRangePct    = candle.close > 0 ? cRange / candle.close * 100 : 0
          ..entryRangeToAtr  = atr > 0 ? cRange / atr : 0
          ..naturalStop      = cStop
          ..stopDistPct      = cStopDist
          ..naturalRR        = natRR;

        if (isLong) openLong  = t;
        else        openShort = t;
      }

      // LONG entry — buy signal + support zone touch + trend aligned
      if (sfi.buySignal && openLong == null && htfUptrend) {
        final blockedByRes = resistances.any((r) =>
            candle.close >= r.boxBottom && candle.close <= r.boxTop);
        final zone = blockedByRes ? null : _bestSupport(candle, supports);
        if (zone != null) openTrade(isLong: true, zone: zone);
      }

      // SHORT entry — sell signal + resistance zone touch + trend aligned
      if (sfi.sellSignal && openShort == null && htfDowntrend) {
        final blockedBySup = supports.any((s) =>
            candle.close >= s.boxBottom && candle.close <= s.boxTop);
        final zone = blockedBySup ? null : _bestResistance(candle, resistances);
        if (zone != null) openTrade(isLong: false, zone: zone);
      }
    }

    stdout.writeln();

    // ── Force-close any trade still open at end of data ─────────────────────
    void forceClose(BtTrade t, bool isLong) {
      final last   = allCandles.last;
      double remQty = t.tp1Hit ? t.quantity * (1 - config.tp1ClosePct) : t.quantity;
      double pnl    = isLong
          ? (last.close - t.entryPrice) * remQty
          : (t.entryPrice - last.close) * remQty;
      double exitFee  = _cost(remQty, last.close);
      t.remainPnl     = pnl;
      t.feesTotal    += exitFee;
      balance        += pnl - exitFee;
      t.exitBar    = allCandles.length - 1;
      t.exitTime   = last.time;
      t.exitPrice  = last.close;
      t.exitReason = ExitReason.endOfData;
      trades.add(t);
    }
    if (openLong  != null) forceClose(openLong!,  true);
    if (openShort != null) forceClose(openShort!, false);

    return trades;
  }
}

// ============================================================================
// REPORTER
// ============================================================================

class Reporter {
  final BacktestConfig config;
  final List<BtTrade>  trades;
  final List<Candle>   allCandles;

  Reporter(this.config, this.trades, this.allCandles);

  void printAll() {
    _printTradeLog();
    _printSummary();
    _printEquityCurve();
    _printMonthlyBreakdown();
    _printInvestorReport();
    _printFeeImpact();
    _printLossAnalysis();
    _printCandleAnalysis();
    _printWhatWouldHelp();
  }

  // ─── 1. Per-trade log ─────────────────────────────────────────────────────

  void _printTradeLog() {
    final w = 158;
    print('\n');
    print('═' * w);
    print('  TRADE LOG  ·  ${config.symbol}  ·  ${config.csvPath}');
    print('═' * w);
    print(
      '  #    Dir    Entry Time          EntryPx    Exit Time           ExitPx    '
      'Hold   Zone                                TP1?  Exit     R-mult  PnL\$           PnL%',
    );
    print('─' * w);

    for (var t in trades) {
      String pnlSign  = t.totalPnl >= 0 ? '+' : '';
      String pnlPctS  = t.pnlPct  >= 0 ? '+' : '';
      String rSign    = t.pnlR    >= 0 ? '+' : '';
      String winMark  = t.isWin ? '✅' : '❌';

      // ── Main trade row (entry → final exit) ──
      print(
        '  ${t.id.toString().padLeft(3)}  '
        '${t.dirStr}  '
        '${_fmtTime(t.entryTime).padRight(20)}'
        '${t.entryPrice.toStringAsFixed(5).padRight(11)}'
        '${_fmtTime(t.exitTime).padRight(20)}'
        '${t.exitPrice.toStringAsFixed(5).padRight(10)}'
        '  ${t.holdBars.toString().padLeft(4)}b  '
        '${t.zoneInfo.padRight(36)}'
        '${t.tp1Hit ? "YES" : "NO "}   '
        '${t.reasonStr}  '
        '$winMark ${(rSign + t.pnlR.toStringAsFixed(2) + "R").padLeft(7)}  '
        '${(pnlSign + "\$" + t.totalPnl.toStringAsFixed(4)).padLeft(13)}  '
        '${(pnlPctS + t.pnlPct.toStringAsFixed(3) + "%").padLeft(8)}',
      );

      // ── SR zone sub-row ──
      print(
        '         SR  '
        '${" ".padRight(20)}'
        '${" ".padRight(11)}'
        '${" ".padRight(20)}'
        '${" ".padRight(10)}'
        '${" ".padRight(8)}'
        'S[0]: ${t.s0Info.padRight(26)}  R[0]: ${t.r0Info}',
      );

      // ── TP1 sub-row (only when TP1 was hit) ──
      if (t.tp1Hit) {
        final tp1Sign = t.tp1NetPnl >= 0 ? '+' : '';
        final tp1Bars = t.tp1Bar - t.entryBar;
        print(
          '       ├─TP1  '
          '${_fmtTime(t.tp1Time).padRight(20)}'
          '${t.tp1Price.toStringAsFixed(5).padRight(11)}'
          '${" ".padRight(20)}'
          '${" ".padRight(10)}'
          '  ${tp1Bars.toString().padLeft(4)}b  '
          '${"${(config.tp1ClosePct * 100).toStringAsFixed(0)}% closed  qty=${(t.quantity * config.tp1ClosePct).toStringAsFixed(3)}".padRight(36)}'
          '${" ".padRight(9)}'
          '${" ".padRight(10)}'
          '   ${(tp1Sign + "\$" + t.tp1NetPnl.toStringAsFixed(4)).padLeft(13)}',
        );
      }
    }
    print('─' * w);
  }

  // ─── 2. Summary stats ─────────────────────────────────────────────────────

  void _printSummary() {
    if (trades.isEmpty) { print('\nNo trades found.\n'); return; }

    final wins   = trades.where((t) => t.isWin).toList();
    final losses = trades.where((t) => !t.isWin).toList();
    final longs  = trades.where((t) => t.direction == TradeDir.long).toList();
    final shorts = trades.where((t) => t.direction == TradeDir.short).toList();

    double totalPnl   = trades.fold(0.0, (s, t) => s + t.totalPnl);
    double winPnl     = wins.fold(0.0,   (s, t) => s + t.totalPnl);
    double lossPnl    = losses.fold(0.0, (s, t) => s + t.totalPnl);
    double finalBal   = config.initialBalance + totalPnl;
    double totalRet   = (totalPnl / config.initialBalance) * 100.0;

    double winRate    = wins.length   / trades.length * 100.0;
    double avgWin     = wins.isNotEmpty   ? winPnl  / wins.length   : 0.0;
    double avgLoss    = losses.isNotEmpty ? lossPnl / losses.length : 0.0;
    double pf         = lossPnl.abs() > 0 ? winPnl / lossPnl.abs() : double.infinity;
    double expectancy = (wins.length / trades.length) * avgWin +
                        (losses.length / trades.length) * avgLoss;

    double avgHold    = trades.fold(0.0, (s, t) => s + t.holdBars) / trades.length;
    int    maxHold    = trades.map((t) => t.holdBars).reduce(max);
    int    minHold    = trades.map((t) => t.holdBars).reduce(min);
    int    tp1Count   = trades.where((t) => t.tp1Hit).length;
    double tp1Rate    = tp1Count / trades.length * 100.0;

    // Max drawdown
    double peak = config.initialBalance, runBal = config.initialBalance, maxDD = 0.0;
    for (var t in trades) {
      runBal += t.totalPnl;
      if (runBal > peak) peak = runBal;
      double dd = peak - runBal;
      if (dd > maxDD) maxDD = dd;
    }
    double maxDDPct = peak > 0 ? (maxDD / peak) * 100.0 : 0.0;

    // Sharpe (on trade-level PnL%)
    List<double> rets = trades.map((t) => t.pnlPct).toList();
    double meanR = rets.reduce((a, b) => a + b) / rets.length;
    double stdR  = sqrt(rets.map((r) => pow(r - meanR, 2)).reduce((a, b) => a + b) / rets.length);
    double sharpe = stdR > 0 ? meanR / stdR : 0.0;

    // Avg R per trade
    double avgR = trades.fold(0.0, (s, t) => s + t.pnlR) / trades.length;

    print('\n');
    print('═' * 70);
    print('  BACKTEST SUMMARY');
    print('═' * 70);
    _row('Symbol',            config.symbol);
    _row('Data Period',       '${_fmtDate(allCandles.first.time)} → ${_fmtDate(allCandles.last.time)}');
    _row('Candles',           '${allCandles.length} (5-min TF)');
    print('─' * 70);
    _row('Initial Balance',   '\$${_f2(config.initialBalance)}');
    _row('Final Balance',     '\$${_f2(finalBal)}');
    _row('Net PnL',           '${totalPnl >= 0 ? "+" : ""}\$${_f4(totalPnl)}');
    _row('Total Return',      '${totalRet >= 0 ? "+" : ""}${_f2(totalRet)}%');
    _row('Max Drawdown',      '-\$${_f2(maxDD)}  (-${_f2(maxDDPct)}%)');
    print('─' * 70);
    _row('Total Trades',      '${trades.length}');
    _row('  → Longs',         '${longs.length}  (${_f1(longs.length / trades.length * 100)}%)');
    _row('  → Shorts',        '${shorts.length}  (${_f1(shorts.length / trades.length * 100)}%)');
    _row('Win Rate',          '${_f2(winRate)}%   (${wins.length}W / ${losses.length}L)');
    _row('TP1 Hit Rate',      '${_f2(tp1Rate)}%   ($tp1Count trades hit TP1)');
    print('─' * 70);
    _row('Avg Win',           '+\$${_f4(avgWin)}');
    _row('Avg Loss',          '\$${_f4(avgLoss)}');
    _row('Profit Factor',     pf.isInfinite ? '∞' : _f2(pf));
    _row('Expectancy/Trade',  '${expectancy >= 0 ? "+" : ""}\$${_f4(expectancy)}');
    _row('Avg R/Trade',       '${avgR >= 0 ? "+" : ""}${_f3(avgR)}R');
    _row('Sharpe (trades)',   _f3(sharpe));
    print('─' * 70);
    _row('Avg Hold',          '${_f1(avgHold)} bars  (~${_f1(avgHold * 5 / 60)}h)');
    _row('Min Hold',          '$minHold bars');
    _row('Max Hold',          '$maxHold bars');
    _row('Max Consec Wins',   '${_maxConsec(true)}');
    _row('Max Consec Losses', '${_maxConsec(false)}');
    print('─' * 70);
    final best  = trades.reduce((a, b) => a.totalPnl > b.totalPnl ? a : b);
    final worst = trades.reduce((a, b) => a.totalPnl < b.totalPnl ? a : b);
    _row('Best Trade',  '#${best.id}  ${best.dirStr}  +\$${_f4(best.totalPnl)}  (${_f2(best.pnlPct)}%)  ${_fmtDate(best.entryTime)}');
    _row('Worst Trade', '#${worst.id}  ${worst.dirStr}  \$${_f4(worst.totalPnl)}  (${_f2(worst.pnlPct)}%)  ${_fmtDate(worst.entryTime)}');
    print('═' * 70);
  }

  // ─── 3. Equity Curve ──────────────────────────────────────────────────────

  void _printEquityCurve() {
    if (trades.isEmpty) return;

    print('\n');
    print('═' * 72);
    print('  EQUITY CURVE  (cumulative PnL after each trade)');
    print('═' * 72);

    // Build cumulative equity
    double cum = 0.0;
    final equity = <double>[0.0];
    for (var t in trades) { cum += t.totalPnl; equity.add(cum); }

    double minE = equity.reduce(min);
    double maxE = equity.reduce(max);
    double range = (maxE - minE).abs();
    if (range < 0.001) range = 1.0;

    const int H = 16;   // chart height in rows
    const int W = 64;   // chart width in columns

    // Downsample equity to W points
    List<double> pts = [];
    if (equity.length <= W) {
      pts = List.from(equity);
    } else {
      double step = (equity.length - 1) / (W - 1);
      for (int j = 0; j < W; j++) {
        pts.add(equity[(j * step).round().clamp(0, equity.length - 1)]);
      }
    }

    // Build char grid
    List<List<String>> grid = List.generate(H, (_) => List.filled(pts.length, ' '));
    for (int x = 0; x < pts.length; x++) {
      int row = H - 1 - ((pts[x] - minE) / range * (H - 1)).round().clamp(0, H - 1);
      grid[row][x] = pts[x] >= 0 ? '▲' : '▼';
    }
    // Zero line
    int zeroRow = H - 1 - ((-minE) / range * (H - 1)).round().clamp(0, H - 1);
    for (int x = 0; x < pts.length; x++) {
      if (grid[zeroRow][x] == ' ') grid[zeroRow][x] = '─';
    }

    for (int r = 0; r < H; r++) {
      double val   = maxE - (r / (H - 1)) * range;
      String label = (val >= 0 ? '+' : '') + val.toStringAsFixed(0);
      print('  ${label.padLeft(9)} │ ${grid[r].join()}');
    }
    print('           ╰${'─' * (pts.length + 1)}');
    print('              Trades  1 → ${trades.length}');
    print('');
    print('  ▲ = profit point   ▼ = loss point   ─ = break-even line');
    print('═' * 72);
  }

  // ─── 4. Monthly breakdown ─────────────────────────────────────────────────

  void _printMonthlyBreakdown() {
    if (trades.isEmpty) return;

    // Group by YYYY-MM (using exitTime)
    final Map<String, List<BtTrade>> months = {};
    for (var t in trades) {
      String key = '${t.exitTime.year}-${t.exitTime.month.toString().padLeft(2, "0")}';
      months.putIfAbsent(key, () => []).add(t);
    }

    print('\n');
    print('═' * 76);
    print('  MONTHLY BREAKDOWN');
    print('═' * 76);
    print('  Month     Trades  Wins  Loss  WinRate%   Net PnL\$       PnL%     Grade');
    print('─' * 76);

    double cumTotal = 0.0;
    final sortedKeys = months.keys.toList()..sort();
    for (var key in sortedKeys) {
      final mt    = months[key]!;
      double mPnl = mt.fold(0.0, (s, t) => s + t.totalPnl);
      int mWins   = mt.where((t) => t.isWin).length;
      double mWr  = mt.isEmpty ? 0.0 : mWins / mt.length * 100.0;
      double mBal = mt.first.balanceAtEntry;
      double mPct = mBal > 0 ? (mPnl / mBal) * 100.0 : 0.0;
      cumTotal   += mPnl;

      String grade = mPnl > 0 ? (mWr >= 60 ? '★★★' : '★★ ') : (mPnl > -200 ? '★  ' : '   ');
      String pnlS  = (mPnl >= 0 ? '+' : '') + '\$${_f2(mPnl)}';
      String pctS  = (mPct >= 0 ? '+' : '') + '${_f2(mPct)}%';

      print(
        '  $key   '
        '${mt.length.toString().padRight(8)}'
        '${mWins.toString().padRight(6)}'
        '${(mt.length - mWins).toString().padRight(6)}'
        '${_f1(mWr).padLeft(8)}   '
        '${pnlS.padRight(15)}'
        '${pctS.padRight(9)}'
        '$grade',
      );
    }
    print('─' * 76);
    double totRet = (cumTotal / config.initialBalance) * 100.0;
    int totW = trades.where((t) => t.isWin).length;
    double totWr = trades.isEmpty ? 0.0 : totW / trades.length * 100.0;
    print(
      '  TOTAL     '
      '${trades.length.toString().padRight(8)}'
      '${totW.toString().padRight(6)}'
      '${(trades.length - totW).toString().padRight(6)}'
      '${_f1(totWr).padLeft(8)}   '
      '${((cumTotal >= 0 ? "+" : "") + "\$${_f2(cumTotal)}").padRight(15)}'
      '${((totRet >= 0 ? "+" : "") + "${_f2(totRet)}%").padRight(9)}',
    );
    print('═' * 76);
  }

  // ─── 5. Investor Report ───────────────────────────────────────────────────

  void _printInvestorReport() {
    if (trades.isEmpty) return;

    double totalPnl   = trades.fold(0.0, (s, t) => s + t.totalPnl);
    double finalBal   = config.initialBalance + totalPnl;
    double totalRet   = (totalPnl / config.initialBalance) * 100.0;
    int    wins       = trades.where((t) => t.isWin).length;
    double winRate    = wins / trades.length * 100.0;
    double winPnl     = trades.where((t) => t.isWin).fold(0.0, (s, t) => s + t.totalPnl);
    double lossPnl    = trades.where((t) => !t.isWin).fold(0.0, (s, t) => s + t.totalPnl);
    double pf         = lossPnl.abs() > 0 ? winPnl / lossPnl.abs() : double.infinity;
    double expectancy = totalPnl / trades.length;

    // Drawdown
    double peak = config.initialBalance, runBal = config.initialBalance, maxDD = 0.0;
    for (var t in trades) {
      runBal += t.totalPnl;
      if (runBal > peak) peak = runBal;
      double dd = peak - runBal;
      if (dd > maxDD) maxDD = dd;
    }
    double maxDDPct = peak > 0 ? (maxDD / peak) * 100.0 : 0.0;

    // Sharpe
    List<double> rets = trades.map((t) => t.pnlPct).toList();
    double meanR = rets.reduce((a, b) => a + b) / rets.length;
    double stdR  = sqrt(rets.map((r) => pow(r - meanR, 2)).reduce((a, b) => a + b) / rets.length);
    double sharpe = stdR > 0 ? meanR / stdR : 0.0;

    // Calmar ratio
    Duration period   = allCandles.last.time.difference(allCandles.first.time);
    double yrs        = period.inHours / (365.0 * 24.0);
    double annRet     = yrs > 0 ? totalRet / yrs : totalRet;
    double calmar     = maxDDPct > 0 ? annRet / maxDDPct : 0.0;

    // R stats
    double avgR = trades.fold(0.0, (s, t) => s + t.pnlR) / trades.length;
    double avgWinR  = wins > 0 ? trades.where((t) => t.isWin).fold(0.0, (s, t) => s + t.pnlR) / wins : 0.0;
    int    lossCount = trades.length - wins;
    double avgLossR = lossCount > 0 ? trades.where((t) => !t.isWin).fold(0.0, (s, t) => s + t.pnlR) / lossCount : 0.0;

    // Exit breakdown
    int tp1SigCount  = trades.where((t) => t.exitReason == ExitReason.tp1ThenSignal).length;
    int sigOnlyCount = trades.where((t) => t.exitReason == ExitReason.signalOnly).length;
    int endCount     = trades.where((t) => t.exitReason == ExitReason.endOfData).length;

    // Overall grade
    String grade;
    if (winRate >= 55 && pf >= 1.5 && totalRet > 0) {
      grade = 'A  ★★★  Excellent';
    } else if (winRate >= 45 && pf >= 1.2 && totalRet > 0) {
      grade = 'B  ★★   Good';
    } else if (totalRet > 0) {
      grade = 'C  ★    Marginal — needs tuning';
    } else {
      grade = 'D       Losing — strategy needs rework';
    }

    const int bw = 66;
    print('\n');
    print('╔${'═' * bw}╗');
    _bx(bw, '');
    _bx(bw, '   INVESTOR PERFORMANCE REPORT');
    _bx(bw, '   Strategy: SFI Flip + SR Zone Touch  |  ${config.symbol}  |  5-Min TF');
    _bx(bw, '');
    print('╠${'═' * bw}╣');
    _bx(bw, '   PERIOD & INSTRUMENT');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'Instrument',       config.symbol);
    _bxkv(bw, 'Data Range',       '${_fmtDate(allCandles.first.time)} → ${_fmtDate(allCandles.last.time)}');
    _bxkv(bw, 'Timeframe',        '5-Minute candles');
    _bxkv(bw, 'Total Candles',    '${allCandles.length}');
    print('╠${'═' * bw}╣');
    _bx(bw, '   CAPITAL PERFORMANCE');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'Starting Capital', '\$${_f2(config.initialBalance)}');
    _bxkv(bw, 'Ending Capital',   '\$${_f2(finalBal)}');
    _bxkv(bw, 'Net Profit',       '${totalPnl >= 0 ? "+" : ""}\$${_f2(totalPnl)}  (${totalRet >= 0 ? "+" : ""}${_f2(totalRet)}%)');
    _bxkv(bw, 'Annualized Return','${annRet >= 0 ? "+" : ""}${_f2(annRet)}%');
    _bxkv(bw, 'Max Drawdown',     '-\$${_f2(maxDD)}  (-${_f2(maxDDPct)}%)');
    _bxkv(bw, 'Calmar Ratio',     _f2(calmar));
    print('╠${'═' * bw}╣');
    _bx(bw, '   TRADE STATISTICS');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'Total Trades',     '${trades.length}  (${trades.where((t) => t.direction == TradeDir.long).length}L / ${trades.where((t) => t.direction == TradeDir.short).length}S)');
    _bxkv(bw, 'Win Rate',         '${_f2(winRate)}%  ($wins wins / ${trades.length - wins} losses)');
    _bxkv(bw, 'Profit Factor',    pf.isInfinite ? '∞ (no losing trades)' : _f2(pf));
    _bxkv(bw, 'Expectancy',       '${expectancy >= 0 ? "+" : ""}\$${_f4(expectancy)} per trade');
    _bxkv(bw, 'Avg R / Trade',    '${avgR >= 0 ? "+" : ""}${_f3(avgR)}R');
    _bxkv(bw, 'Avg Win R',        '+${_f3(avgWinR)}R');
    _bxkv(bw, 'Avg Loss R',       '${_f3(avgLossR)}R');
    _bxkv(bw, 'Sharpe Ratio',     _f2(sharpe));
    print('╠${'═' * bw}╣');
    _bx(bw, '   EXIT ANALYSIS');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'TP1 Hit Rate',     '${_f1(trades.where((t) => t.tp1Hit).length / trades.length * 100)}%  (${trades.where((t) => t.tp1Hit).length} trades)');
    _bxkv(bw, 'TP1 → Signal',    '$tp1SigCount  (TP1 taken, 10% runner closed by signal)');
    _bxkv(bw, 'Signal Only',      '$sigOnlyCount  (no TP hit, closed 100% by signal reverse)');
    _bxkv(bw, 'End-of-Data',      '$endCount  (still open at data end)');
    _bxkv(bw, 'Max Consec Wins',  '${_maxConsec(true)}');
    _bxkv(bw, 'Max Consec Loss',  '${_maxConsec(false)}');
    print('╠${'═' * bw}╣');
    _bx(bw, '   STRATEGY SETTINGS');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'Leverage',         '${config.leverage.toStringAsFixed(0)}x');
    _bxkv(bw, 'Risk / Trade',     '${_f2(config.riskPctPerTrade)}% of balance');
    _bxkv(bw, 'TP1',              '${config.tp1AtrMultiplier}× ATR  (closes 90%; 10% runner on signal)');
    _bxkv(bw, 'Exit',             'SFI opposite signal  (closes 100% if no TP hit, 10% after TP1)');
    _bxkv(bw, 'SFI Period',       '${config.sfiPeriod}  mult=${config.sfiMultiplier}');
    _bxkv(bw, 'SR Detection',     'len=${config.srDetectionLength}  margin=${config.srMargin}');
    _bxkv(bw, 'Candle Window',    '${config.candleWindow} bars (matches live bot)');
    print('╠${'═' * bw}╣');
    _bx(bw, '   OVERALL ASSESSMENT');
    print('╠${'═' * bw}╣');
    _bxkv(bw, 'Grade', grade);
    _bx(bw, '');
    _bx(bw, '   Notes:');
    _bx(bw, '   · Entry: exact SFI flip bar only (no look-forward window)');
    _bx(bw, '   · SR computed on sliding ${config.candleWindow}-bar window — no look-ahead bias');
    _bx(bw, '   · Fees + slippage modelled at ${config.takerFeePct + config.slippagePct}% per side per leg');
    _bx(bw, '');
    print('╚${'═' * bw}╝');
    print('');
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  int _maxConsec(bool isWin) {
    int mx = 0, cur = 0;
    for (var t in trades) {
      if (t.isWin == isWin) { cur++; if (cur > mx) { mx = cur; } }
      else { cur = 0; }
    }
    return mx;
  }

  void _row(String label, String val) {
    print('  ${label.padRight(24)} $val');
  }

  void _bx(int w, String content) {
    print('║${content.padRight(w)}║');
  }

  void _bxkv(int w, String key, String val) {
    String line = '   ${key.padRight(22)}  $val';
    print('║${line.padRight(w)}║');
  }

  String _fmtTime(DateTime dt) =>
      '${dt.year}-${_p2(dt.month)}-${_p2(dt.day)} ${_p2(dt.hour)}:${_p2(dt.minute)}';
  String _fmtDate(DateTime dt) =>
      '${dt.year}-${_p2(dt.month)}-${_p2(dt.day)}';
  String _p2(int n) => n.toString().padLeft(2, '0');
  String _f1(double v) => v.toStringAsFixed(1);
  String _f2(double v) => v.toStringAsFixed(2);
  String _f3(double v) => v.toStringAsFixed(3);
  String _f4(double v) => v.toStringAsFixed(4);

  // ─── 6. Fee Impact ────────────────────────────────────────────────────────

  void _printFeeImpact() {
    if (trades.isEmpty) return;

    double totalFees  = trades.fold(0.0, (s, t) => s + t.feesTotal);
    double grossPnl   = trades.fold(0.0, (s, t) => s + t.grossPnl);
    double netPnl     = trades.fold(0.0, (s, t) => s + t.totalPnl);
    double avgFee     = totalFees / trades.length;

    // Trades that are winners gross but losers net (fee-flipped)
    int feeFlipped    = trades.where((t) => t.grossPnl > 0 && t.totalPnl <= 0).length;
    // Trades where fees > |gross loss| (fees made small losses bigger)
    int feeWorsened   = trades.where((t) => t.grossPnl < 0 && t.feesTotal > 0).length;

    int winsNoFee     = trades.where((t) => t.grossPnl > 0).length;
    int winsWithFee   = trades.where((t) => t.totalPnl > 0).length;
    double wrNoFee    = winsNoFee  / trades.length * 100.0;
    double wrWithFee  = winsWithFee / trades.length * 100.0;

    const w = 68;
    print('\n');
    print('╔${'═' * w}╗');
    print('║${'  FEE & SLIPPAGE IMPACT'.padRight(w)}║');
    print('╠${'═' * w}╣');
    print('║${'  Rate: Taker fee ${config.takerFeePct}% + Slippage ${config.slippagePct}% = ${config.takerFeePct + config.slippagePct}% per side (both sides on each leg)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Gross PnL (before fees)',  '${grossPnl >= 0 ? "+" : ""}\$${_f2(grossPnl)}');
    _frow(w, 'Total Fees Paid',          '-\$${_f2(totalFees)}');
    _frow(w, 'Net PnL (after fees)',     '${netPnl >= 0 ? "+" : ""}\$${_f2(netPnl)}');
    _frow(w, 'Avg Fee Per Trade',        '\$${_f2(avgFee)}');
    print('╠${'═' * w}╣');
    _frow(w, 'Win Rate WITHOUT fees',    '${_f1(wrNoFee)}%  ($winsNoFee wins)');
    _frow(w, 'Win Rate WITH fees',       '${_f1(wrWithFee)}%  ($winsWithFee wins)');
    _frow(w, 'Fee-flipped trades',       '$feeFlipped  (gross profit → net loss after fees)');
    _frow(w, 'Losses worsened by fees',  '$feeWorsened  (losing trades made worse)');
    print('╠${'═' * w}╣');
    String verdict = totalFees > grossPnl
        ? '  ⚠  FEES EXCEED GROSS PROFIT — strategy is fee-negative'
        : totalFees > grossPnl * 0.5
        ? '  ⚠  Fees consuming ${_f1(totalFees / grossPnl.abs() * 100)}% of gross profit — significant drag'
        : '  ✓  Fees are ${_f1(totalFees / grossPnl.abs() * 100)}% of gross profit — manageable';
    print('║${verdict.padRight(w)}║');
    print('╚${'═' * w}╝');
  }

  void _frow(int w, String key, String val) {
    String line = '  ${key.padRight(30)}  $val';
    print('║${line.padRight(w)}║');
  }

  // ─── 7. Loss Analysis ─────────────────────────────────────────────────────

  void _printLossAnalysis() {
    if (trades.isEmpty) return;

    final losses  = trades.where((t) => !t.isWin).toList();
    final wins    = trades.where((t) =>  t.isWin).toList();
    if (losses.isEmpty) { print('\nNo losing trades — nothing to analyse.\n'); return; }

    // By direction
    int longLoss  = losses.where((t) => t.direction == TradeDir.long).length;
    int shortLoss = losses.where((t) => t.direction == TradeDir.short).length;
    int longWin   = wins.where((t) => t.direction == TradeDir.long).length;
    int shortWin  = wins.where((t) => t.direction == TradeDir.short).length;
    int totalLong  = longLoss + longWin;
    int totalShort = shortLoss + shortWin;
    double longWR  = totalLong  > 0 ? longWin  / totalLong  * 100 : 0;
    double shortWR = totalShort > 0 ? shortWin / totalShort * 100 : 0;

    // By exit reason
    int signalOnlyLoss  = losses.where((t) => t.exitReason == ExitReason.signalOnly).length;
    int tp1SigLoss      = losses.where((t) => t.exitReason == ExitReason.tp1ThenSignal).length;

    // By time of day (UTC hour of entry)
    final Map<int, List<BtTrade>> byHour = {};
    for (var t in trades) {
      int h = t.entryTime.hour;
      byHour.putIfAbsent(h, () => []).add(t);
    }
    // Find worst and best hours
    final hourStats = byHour.entries.map((e) {
      double pnl = e.value.fold(0.0, (s, t) => s + t.totalPnl);
      int w2 = e.value.where((t) => t.isWin).length;
      double wr = w2 / e.value.length * 100;
      return (hour: e.key, trades: e.value.length, pnl: pnl, wr: wr);
    }).toList()..sort((a, b) => a.pnl.compareTo(b.pnl));

    final worstHours = hourStats.take(3).toList();
    final bestHours  = hourStats.reversed.take(3).toList();

    // Hold time
    double avgWinHold  = wins.isEmpty   ? 0 : wins.fold(0.0,   (s, t) => s + t.holdBars) / wins.length;
    double avgLossHold = losses.isEmpty ? 0 : losses.fold(0.0, (s, t) => s + t.holdBars) / losses.length;

    // Avg loss size
    double avgLossPnl = losses.fold(0.0, (s, t) => s + t.totalPnl) / losses.length;
    double avgWinPnl  = wins.isNotEmpty ? wins.fold(0.0, (s, t) => s + t.totalPnl) / wins.length : 0;

    // Consecutive losses
    int maxConsecLoss = _maxConsec(false);

    // Losses by hour table
    final Map<int, ({int total, int lossCount, double pnl})> hourLoss = {};
    for (var t in losses) {
      int h = t.entryTime.hour;
      final prev = hourLoss[h];
      if (prev == null) {
        hourLoss[h] = (total: byHour[h]!.length, lossCount: 1, pnl: t.totalPnl);
      } else {
        hourLoss[h] = (total: prev.total, lossCount: prev.lossCount + 1, pnl: prev.pnl + t.totalPnl);
      }
    }

    const w = 72;
    print('\n');
    print('╔${'═' * w}╗');
    print('║${'  WHERE ARE YOU LOSING'.padRight(w)}║');
    print('╠${'═' * w}╣');

    // Direction breakdown
    print('║${'  DIRECTION BREAKDOWN'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'LONG  trades', '$totalLong total   ${longWin}W / ${longLoss}L   WR: ${_f1(longWR)}%   PnL: ${_f2(wins.where((t) => t.direction == TradeDir.long).fold(0.0,(s,t)=>s+t.totalPnl) + losses.where((t) => t.direction == TradeDir.long).fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'SHORT trades', '$totalShort total   ${shortWin}W / ${shortLoss}L   WR: ${_f1(shortWR)}%   PnL: ${_f2(wins.where((t) => t.direction == TradeDir.short).fold(0.0,(s,t)=>s+t.totalPnl) + losses.where((t) => t.direction == TradeDir.short).fold(0.0,(s,t)=>s+t.totalPnl))}');
    String weakDir = longWR < shortWR ? 'LONG  is weaker — LONGs win ${_f1(longWR)}% vs SHORTs ${_f1(shortWR)}%'
                                      : 'SHORT is weaker — SHORTs win ${_f1(shortWR)}% vs LONGs ${_f1(longWR)}%';
    print('║${'  → $weakDir'.padRight(w)}║');
    print('╠${'═' * w}╣');

    // Exit reason breakdown
    print('║${'  LOSS BY EXIT REASON'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Signal-only losses (no TP)', '$signalOnlyLoss  — price reversed before hitting TP1');
    _frow(w, 'TP hit then loss on runner', '$tp1SigLoss  — TP1/TP2 taken but runner closed at loss');
    if (signalOnlyLoss > tp1SigLoss) {
      print('║${'  → Most losses happen BEFORE TP1. Price is not reaching your TP1 target.'.padRight(w)}║');
      print('║${'    Try: reduce TP1 multiplier to be closer to price, or widen SR zone filter.'.padRight(w)}║');
    } else {
      print('║${'  → Most losses are on the runner. The runner adds little value.'.padRight(w)}║');
      print('║${'    Try: close 100% at TP1 — skip the runner entirely.'.padRight(w)}║');
    }
    print('╠${'═' * w}╣');

    // Hold time
    print('║${'  HOLD TIME ANALYSIS'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Avg hold — winners', '${_f1(avgWinHold)} bars  (~${_f1(avgWinHold * 5 / 60)}h)');
    _frow(w, 'Avg hold — losers',  '${_f1(avgLossHold)} bars  (~${_f1(avgLossHold * 5 / 60)}h)');
    _frow(w, 'Avg win PnL',        '+\$${_f2(avgWinPnl)}');
    _frow(w, 'Avg loss PnL',       '\$${_f2(avgLossPnl)}');
    _frow(w, 'Max consecutive losses', '$maxConsecLoss');
    print('╠${'═' * w}╣');

    // Worst hours
    print('║${'  WORST HOURS (UTC entry time)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    for (var h in worstHours) {
      String label = 'Hour ${h.hour.toString().padLeft(2, "0")}:00 UTC';
      String val   = '${h.trades} trades   WR: ${_f1(h.wr)}%   PnL: ${h.pnl >= 0 ? "+" : ""}\$${_f2(h.pnl)}';
      _frow(w, label, val);
    }
    print('╠${'═' * w}╣');
    print('║${'  BEST HOURS (UTC entry time)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    for (var h in bestHours) {
      String label = 'Hour ${h.hour.toString().padLeft(2, "0")}:00 UTC';
      String val   = '${h.trades} trades   WR: ${_f1(h.wr)}%   PnL: ${h.pnl >= 0 ? "+" : ""}\$${_f2(h.pnl)}';
      _frow(w, label, val);
    }
    print('╚${'═' * w}╝');
  }

  // ─── 8. Entry Candle Analysis ─────────────────────────────────────────────

  void _printCandleAnalysis() {
    if (trades.isEmpty) return;

    final wins   = trades.where((t) =>  t.isWin).toList();
    final losses = trades.where((t) => !t.isWin).toList();

    // ── helpers ──────────────────────────────────────────────────────────────
    double avg(List<BtTrade> list, double Function(BtTrade) fn) =>
        list.isEmpty ? 0 : list.fold(0.0, (s, t) => s + fn(t)) / list.length;

    // ── win vs loss candle stats ──────────────────────────────────────────────
    double wBody    = avg(wins,   (t) => t.entryBodyPct   * 100);
    double lBody    = avg(losses, (t) => t.entryBodyPct   * 100);
    double wUWick   = avg(wins,   (t) => t.entryUpperWick * 100);
    double lUWick   = avg(losses, (t) => t.entryUpperWick * 100);
    double wLWick   = avg(wins,   (t) => t.entryLowerWick * 100);
    double lLWick   = avg(losses, (t) => t.entryLowerWick * 100);
    double wRange   = avg(wins,   (t) => t.entryRangePct);
    double lRange   = avg(losses, (t) => t.entryRangePct);
    double wRangeAtr= avg(wins,   (t) => t.entryRangeToAtr);
    double lRangeAtr= avg(losses, (t) => t.entryRangeToAtr);
    double wStop    = avg(wins,   (t) => t.stopDistPct);
    double lStop    = avg(losses, (t) => t.stopDistPct);
    double wRR      = avg(wins,   (t) => t.naturalRR);
    double lRR      = avg(losses, (t) => t.naturalRR);

    // ── bullish vs bearish entry candle win rates ─────────────────────────────
    final bullEntries = trades.where((t) => t.entryIsBullish).toList();
    final bearEntries = trades.where((t) => !t.entryIsBullish).toList();
    double bullWR = bullEntries.isEmpty ? 0 : bullEntries.where((t) => t.isWin).length / bullEntries.length * 100;
    double bearWR = bearEntries.isEmpty ? 0 : bearEntries.where((t) => t.isWin).length / bearEntries.length * 100;

    // ── wide vs narrow candle win rate (split by median rangeToAtr) ───────────
    final sortedByRange = [...trades]..sort((a, b) => a.entryRangeToAtr.compareTo(b.entryRangeToAtr));
    final medianRange   = sortedByRange[sortedByRange.length ~/ 2].entryRangeToAtr;
    final narrowCandles = trades.where((t) => t.entryRangeToAtr <= medianRange).toList();
    final wideCandles   = trades.where((t) => t.entryRangeToAtr >  medianRange).toList();
    double narrowWR = narrowCandles.isEmpty ? 0 : narrowCandles.where((t) => t.isWin).length / narrowCandles.length * 100;
    double wideWR   = wideCandles.isEmpty   ? 0 : wideCandles.where((t)   => t.isWin).length / wideCandles.length   * 100;

    // ── stop distance bucket win rates ────────────────────────────────────────
    // Group into tight (<0.3%), medium (0.3-0.7%), wide (>0.7%)
    final tightStop  = trades.where((t) => t.stopDistPct < 0.3).toList();
    final medStop    = trades.where((t) => t.stopDistPct >= 0.3 && t.stopDistPct < 0.7).toList();
    final wideStop   = trades.where((t) => t.stopDistPct >= 0.7).toList();
    double tightWR   = tightStop.isEmpty ? 0 : tightStop.where((t) => t.isWin).length / tightStop.length * 100;
    double medWR     = medStop.isEmpty   ? 0 : medStop.where((t)   => t.isWin).length / medStop.length   * 100;
    double wideStWR  = wideStop.isEmpty  ? 0 : wideStop.where((t)  => t.isWin).length / wideStop.length  * 100;

    // ── R:R bucket win rates ──────────────────────────────────────────────────
    final poorRR  = trades.where((t) => t.naturalRR < 1.0).toList();
    final okRR    = trades.where((t) => t.naturalRR >= 1.0 && t.naturalRR < 2.0).toList();
    final goodRR  = trades.where((t) => t.naturalRR >= 2.0).toList();
    double poorRRWR = poorRR.isEmpty  ? 0 : poorRR.where((t)  => t.isWin).length / poorRR.length  * 100;
    double okRRWR   = okRR.isEmpty    ? 0 : okRR.where((t)    => t.isWin).length / okRR.length    * 100;
    double goodRRWR = goodRR.isEmpty  ? 0 : goodRR.where((t)  => t.isWin).length / goodRR.length  * 100;

    // ── volume percentile ─────────────────────────────────────────────────────
    final sortedVol = trades.map((t) => t.entryVolume).toList()..sort();
    double p25Vol = sortedVol[(sortedVol.length * 0.25).floor()];
    double p75Vol = sortedVol[(sortedVol.length * 0.75).floor()];
    final lowVol  = trades.where((t) => t.entryVolume <= p25Vol).toList();
    final highVol = trades.where((t) => t.entryVolume >= p75Vol).toList();
    double lowVolWR  = lowVol.isEmpty  ? 0 : lowVol.where((t)  => t.isWin).length / lowVol.length  * 100;
    double highVolWR = highVol.isEmpty ? 0 : highVol.where((t) => t.isWin).length / highVol.length * 100;

    // ── losing trade detail table — show entry candle data for each loser ─────
    const w = 76;
    print('\n');
    print('╔${'═' * w}╗');
    print('║${'  ENTRY CANDLE ANALYSIS'.padRight(w)}║');
    print('╠${'═' * w}╣');

    // Win vs loss candle characteristics
    print('║${'  AVG ENTRY CANDLE: WINNERS vs LOSERS'.padRight(w)}║');
    print('╠${'═' * w}╣');
    print('║  ${'Metric'.padRight(28)} ${'Winners'.padLeft(10)} ${'Losers'.padLeft(10)} ${'Diff'.padLeft(10)}  ║');
    print('╠${'═' * w}╣');
    void cmpRow(String label, double wVal, double lVal, {String unit = '%', bool higherIsBetter = true}) {
      String diff = wVal - lVal >= 0 ? '+${_f1(wVal - lVal)}$unit' : '${_f1(wVal - lVal)}$unit';
      bool wIsBetter = higherIsBetter ? wVal >= lVal : wVal <= lVal;
      String tag = wIsBetter ? '▲' : '▼';
      print('║  ${label.padRight(28)} ${('${_f1(wVal)}$unit').padLeft(10)} ${('${_f1(lVal)}$unit').padLeft(10)} ${('$tag $diff').padLeft(10)}  ║');
    }
    cmpRow('Body size (body/range)',    wBody,     lBody);
    cmpRow('Upper wick',                wUWick,    lUWick,    higherIsBetter: false);
    cmpRow('Lower wick (LONG bounce)', wLWick,    lLWick);
    cmpRow('Candle range (% of price)',wRange,    lRange,    higherIsBetter: false);
    cmpRow('Range / ATR ratio',        wRangeAtr, lRangeAtr, higherIsBetter: false);
    cmpRow('Stop dist (% from entry)', wStop,     lStop);
    cmpRow('Natural R:R (TP1/stop)',   wRR,       lRR,       unit: 'x');
    print('╠${'═' * w}╣');

    // Candle direction
    print('║${'  CANDLE DIRECTION AT ENTRY'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Bullish candle entries', '${bullEntries.length} trades   WR: ${_f1(bullWR)}%   PnL: \$${_f2(bullEntries.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'Bearish candle entries', '${bearEntries.length} trades   WR: ${_f1(bearWR)}%   PnL: \$${_f2(bearEntries.fold(0.0,(s,t)=>s+t.totalPnl))}');
    String candleDir = bullWR > bearWR ? '→ Bullish entry candles perform better' : '→ Bearish entry candles perform better';
    print('║  ${candleDir.padRight(w - 2)}║');
    print('╠${'═' * w}╣');

    // Candle size
    print('║${'  CANDLE SIZE vs WIN RATE (split at median Range/ATR = ${_f2(medianRange)}×)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Narrow candles (≤median ATR)', '${narrowCandles.length} trades   WR: ${_f1(narrowWR)}%   PnL: \$${_f2(narrowCandles.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'Wide candles   (>median ATR)', '${wideCandles.length} trades   WR: ${_f1(wideWR)}%   PnL: \$${_f2(wideCandles.fold(0.0,(s,t)=>s+t.totalPnl))}');
    print('╠${'═' * w}╣');

    // Stop distance
    print('║${'  STOP DISTANCE (entry → zone boundary)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Tight (<0.3% from entry)', '${tightStop.length} trades   WR: ${_f1(tightWR)}%   PnL: \$${_f2(tightStop.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'Medium (0.3–0.7%)',        '${medStop.length} trades   WR: ${_f1(medWR)}%   PnL: \$${_f2(medStop.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'Wide (>0.7%)',             '${wideStop.length} trades   WR: ${_f1(wideStWR)}%   PnL: \$${_f2(wideStop.fold(0.0,(s,t)=>s+t.totalPnl))}');
    print('║  → Tighter stop = entry is closer to zone core = stronger zone touch${' ' * (w - 71)}║');
    print('╠${'═' * w}╣');

    // R:R analysis
    print('║${'  NATURAL R:R AT ENTRY (TP1 distance / stop distance)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Poor R:R  (<1.0×)',  '${poorRR.length} trades   WR: ${_f1(poorRRWR)}%   PnL: \$${_f2(poorRR.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'OK R:R    (1–2×)',   '${okRR.length} trades   WR: ${_f1(okRRWR)}%   PnL: \$${_f2(okRR.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'Good R:R  (≥2.0×)', '${goodRR.length} trades   WR: ${_f1(goodRRWR)}%   PnL: \$${_f2(goodRR.fold(0.0,(s,t)=>s+t.totalPnl))}');
    print('╠${'═' * w}╣');

    // Volume
    print('║${'  ENTRY CANDLE VOLUME (P25/P75 split)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Low volume  (≤P25)',  '${lowVol.length} trades   WR: ${_f1(lowVolWR)}%   PnL: \$${_f2(lowVol.fold(0.0,(s,t)=>s+t.totalPnl))}');
    _frow(w, 'High volume (≥P75)', '${highVol.length} trades   WR: ${_f1(highVolWR)}%   PnL: \$${_f2(highVol.fold(0.0,(s,t)=>s+t.totalPnl))}');
    String volMsg = highVolWR > lowVolWR
        ? '→ High-volume entries win more — volume confirms the reversal zone'
        : '→ Low-volume entries win more — high vol at zone may indicate breakout, not bounce';
    print('║  ${volMsg.padRight(w - 2)}║');
    print('╠${'═' * w}╣');

    // Losing trade detail table
    print('║${'  LOSING TRADES — ENTRY CANDLE DETAIL'.padRight(w)}║');
    print('╠${'═' * w}╣');
    print('║  ${'#'.padLeft(3)}  ${'Dir'.padRight(5)} ${'Body%'.padLeft(6)} ${'UWick%'.padLeft(7)} ${'LWick%'.padLeft(7)} ${'Rng%'.padLeft(5)} ${'Rng/ATR'.padLeft(8)} ${'Stop%'.padLeft(6)} ${'R:R'.padLeft(5)} ${'Vol'.padLeft(10)} ${'NetPnL'.padLeft(10)}  ║');
    print('╠${'═' * w}╣');
    for (var t in losses) {
      final row =
        '  ${t.id.toString().padLeft(3)}  '
        '${t.dirStr.padRight(5)} '
        '${_f1(t.entryBodyPct * 100).padLeft(6)} '
        '${_f1(t.entryUpperWick * 100).padLeft(7)} '
        '${_f1(t.entryLowerWick * 100).padLeft(7)} '
        '${_f2(t.entryRangePct).padLeft(5)} '
        '${_f2(t.entryRangeToAtr).padLeft(8)} '
        '${_f2(t.stopDistPct).padLeft(6)} '
        '${_f2(t.naturalRR).padLeft(5)} '
        '${t.entryVolume.toStringAsFixed(0).padLeft(10)} '
        '${('\$${_f2(t.totalPnl)}').padLeft(10)} ';
      print('║${row.padRight(w)}║');
    }
    print('╚${'═' * w}╝');
  }

  // ─── 9. What Would Help ───────────────────────────────────────────────────

  void _printWhatWouldHelp() {
    if (trades.isEmpty) return;

    final losses = trades.where((t) => !t.isWin).toList();
    final wins   = trades.where((t) =>  t.isWin).toList();

    double totalFees  = trades.fold(0.0, (s, t) => s + t.feesTotal);
    double netPnl     = trades.fold(0.0, (s, t) => s + t.totalPnl);
    double avgWinPnl  = wins.isEmpty ? 0 : wins.fold(0.0, (s,t)=>s+t.totalPnl)/wins.length;
    double avgLossPnl = losses.isEmpty ? 0 : losses.fold(0.0,(s,t)=>s+t.totalPnl)/losses.length;

    int signalOnlyLoss = losses.where((t) => t.exitReason == ExitReason.signalOnly).length;

    // How much PnL if we close 100% at TP1 (ignore TP2 and runner)
    double pnlAllTp1 = trades.fold(0.0, (s, t) {
      if (t.tp1Hit) {
        // full position closed at TP1, only entry fee + full tp1 exit fee
        double fullTp1Qty = t.quantity;
        double grossFull  = (t.direction == TradeDir.long
            ? t.tp1Price - t.entryPrice
            : t.entryPrice - t.tp1Price) * fullTp1Qty;
        double fees = (config.takerFeePct + config.slippagePct) / 100.0 * fullTp1Qty * t.entryPrice
                    + (config.takerFeePct + config.slippagePct) / 100.0 * fullTp1Qty * t.tp1Price;
        return s + grossFull - fees;
      } else {
        return s + t.totalPnl;
      }
    });

    // How much PnL if we skip trades that don't hit TP1 (signalOnly exits)
    double pnlSkipNoTp1 = trades.where((t) => t.tp1Hit).fold(0.0, (s, t) => s + t.totalPnl);

    // PnL if we only trade specific direction
    double longOnlyPnl  = trades.where((t) => t.direction == TradeDir.long).fold(0.0, (s,t)=>s+t.totalPnl);
    double shortOnlyPnl = trades.where((t) => t.direction == TradeDir.short).fold(0.0,(s,t)=>s+t.totalPnl);

    // PnL if we halve risk (fees scale down proportionally)
    double halfRiskPnl = netPnl * 0.1;  // linear — fees scale with position size

    // Win/loss ratio
    double wlRatio = avgLossPnl != 0 ? avgWinPnl / avgLossPnl.abs() : 0;

    const w = 72;
    print('\n');
    print('╔${'═' * w}╗');
    print('║${'  WHAT WOULD MAKE IT PROFITABLE'.padRight(w)}║');
    print('╠${'═' * w}╣');

    // Current state
    print('║${'  CURRENT STATE'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Net PnL',       '${netPnl >= 0 ? "+" : ""}\$${_f2(netPnl)}');
    _frow(w, 'Win/Loss ratio','${_f2(wlRatio)}  (avg win \$${_f2(avgWinPnl)} vs avg loss \$${_f2(avgLossPnl.abs())})');
    _frow(w, 'Problem',       wlRatio < 1.0
        ? 'Avg loss is larger than avg win — need bigger winners or smaller losers'
        : 'Win rate or trade frequency insufficient');
    print('╠${'═' * w}╣');

    // Option 1: Close 100% at TP1
    String tp1Tag = pnlAllTp1 > netPnl ? '✅ BETTER' : '❌ worse';
    print('║${'  OPTION 1: Close 100% at TP1 (remove TP2 + runner)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Simulated Net PnL', '${pnlAllTp1 >= 0 ? "+" : ""}\$${_f2(pnlAllTp1)}   $tp1Tag vs current \$${_f2(netPnl)}');
    _frow(w, 'Why',               'TP2 + runner add little — removing them reduces variance');
    print('╠${'═' * w}╣');

    // Option 2: Skip signal-only exits (only trade when TP1 is eventually hit)
    String skipTag = pnlSkipNoTp1 > netPnl ? '✅ BETTER' : '❌ worse';
    print('║${'  OPTION 2: Only count trades that hit TP1 (skip signal-only)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Simulated Net PnL', '${pnlSkipNoTp1 >= 0 ? "+" : ""}\$${_f2(pnlSkipNoTp1)}   $skipTag');
    _frow(w, 'Trades remaining',  '${trades.where((t)=>t.tp1Hit).length} (removed $signalOnlyLoss signal-only trades)');
    _frow(w, 'Why',               'Signal-only losses are the entries that immediately reversed against you');
    print('╠${'═' * w}╣');

    // Option 3: Trade only LONG or only SHORT
    String longTag  = longOnlyPnl  > netPnl ? '✅ BETTER' : '↔';
    String shortTag = shortOnlyPnl > netPnl ? '✅ BETTER' : '↔';
    print('║${'  OPTION 3: Trade only one direction'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'LONG only PnL',  '${longOnlyPnl  >= 0 ? "+" : ""}\$${_f2(longOnlyPnl)}   $longTag');
    _frow(w, 'SHORT only PnL', '${shortOnlyPnl >= 0 ? "+" : ""}\$${_f2(shortOnlyPnl)}   $shortTag');
    _frow(w, 'Why',            'One direction may align better with prevailing trend');
    print('╠${'═' * w}╣');

    // Option 4: Reduce position size to cut fees
    print('║${'  OPTION 4: Lower risk per trade (e.g. 10% instead of 20%)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Estimated Net PnL at 10% risk', '${halfRiskPnl >= 0 ? "+" : ""}\$${_f2(halfRiskPnl)}  (fees scale with size)');
    _frow(w, 'Fees saved',                    '\$${_f2(totalFees * 0.5)}');
    _frow(w, 'Why',                           'Lower size = lower fee drag per trade');
    print('╠${'═' * w}╣');

    // Option 5: Increase TP1 multiplier
    print('║${'  OPTION 5: Increase TP1 ATR multiplier (e.g. 1.5× or 2×)'.padRight(w)}║');
    print('╠${'═' * w}╣');
    _frow(w, 'Current TP1 multiplier', '${config.tp1AtrMultiplier}× ATR');
    _frow(w, 'Why bigger TP1 helps',   'Bigger TP1 = more gross profit per winning trade if hit');
    _frow(w, 'Trade-off',              'Fewer trades will hit TP1 — TP1 hit rate will drop');
    _frow(w, 'Recommendation',         'Test 1.5× and 2× in the config and re-run backtest');
    print('╠${'═' * w}╣');

    // Option 6: Reduce fees — use limit orders
    print('║${'  OPTION 6: Use LIMIT orders (maker fee) to cut costs'.padRight(w)}║');
    print('╠${'═' * w}╣');
    double makerFee = 0.01; // typical maker fee
    double totalNotional = trades.fold(0.0, (s,t) => s + t.quantity * t.entryPrice);
    // saving = difference in rate × total notional (entry side only — simplified)
    double savedFees = (config.takerFeePct - makerFee) / 100.0 * totalNotional;
    _frow(w, 'Taker fee (current)',  '${config.takerFeePct}% per side');
    _frow(w, 'Maker fee (limit)',    '0.01% per side (Asterdex typical)');
    _frow(w, 'Estimated fee saving', '~\$${_f2(savedFees)} over ${trades.length} trades');
    _frow(w, 'Trade-off',            'Limit orders may not fill during fast moves');
    print('╠${'═' * w}╣');

    // Final verdict
    print('║${'  PRIORITY ACTIONS'.padRight(w)}║');
    print('╠${'═' * w}╣');
    final actions = <String>[];
    if (pnlAllTp1 > netPnl)     actions.add('1. Close 100% at TP1 — removes low-value runner');
    if (pnlSkipNoTp1 > netPnl)  actions.add('2. Tighten SR zone filter to reduce signal-only losses');
    if (longOnlyPnl > netPnl || shortOnlyPnl > netPnl) {
      String dir = longOnlyPnl > shortOnlyPnl ? 'LONG' : 'SHORT';
      actions.add('3. Focus on $dir direction only or add trend filter');
    }
    actions.add('4. Test TP1 multiplier 1.5× and 2× — re-run backtest to compare');
    actions.add('5. Reduce position size to 10% to lower fee drag while improving strategy');
    for (var a in actions) {
      print('║${'  $a'.padRight(w)}║');
    }
    print('╚${'═' * w}╝\n');
  }
}

// ============================================================================
// CSV LOADER
// ============================================================================

List<Candle> loadCsv(String path) {
  final lines   = File(path).readAsLinesSync();
  final candles = <Candle>[];
  for (int i = 1; i < lines.length; i++) {   // skip header row
    final line  = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.length < 5) continue;
    try {
      final time   = DateTime.parse(parts[0]);
      final open   = double.parse(parts[1]);
      final high   = double.parse(parts[2]);
      final low    = double.parse(parts[3]);
      final close  = double.parse(parts[4]);
      final volume = parts.length > 5 ? double.parse(parts[5]) : 0.0;
      candles.add(Candle(time, open, high, low, close, volume, i - 1));
    } catch (_) { /* skip malformed row */ }
  }
  return candles;
}

/// Aggregate [candles] (15-minute) into N-minute bars.
/// [factor] = number of input bars per output bar (e.g. 3 for 45m from 15m).
List<Candle> buildAggregatedCandles(List<Candle> candles, int factor) {
  final out = <Candle>[];
  for (int i = 0; i + factor - 1 < candles.length; i += factor) {
    final group = candles.sublist(i, i + factor);
    final open   = group.first.open;
    final close  = group.last.close;
    final high   = group.map((c) => c.high).reduce(max);
    final low    = group.map((c) => c.low).reduce(min);
    final volume = group.fold(0.0, (s, c) => s + c.volume);
    out.add(Candle(group.first.time, open, high, low, close, volume, out.length));
  }
  return out;
}

String _fmtDate(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';

// ============================================================================
// MAIN
// ============================================================================

void main() {
  final config = BacktestConfig(
    csvPath:           '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv',
    symbol:            'SOLUSDT',
    sfiPeriod:         10,
    sfiMultiplier:     1.7,
    srDetectionLength: 15,
    srMargin:          2.0,
    atrPeriod:         14,
    tp1AtrMultiplier:  1.5,
    initialBalance:    10000.0,
    riskPctPerTrade:   20.0,
    leverage:          10.0,
    candleWindow:      1000,
    warmupBars:        100,

    // ── Multi-timeframe SR ──────────────────────────────────────────────────
    htfCsvPath:      '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv',
    htfBuild45m:     false,  // 15m SR — 45m zones are too coarse for 5m candle touches
    htfCandleWindow: 300,

    // ── HTF trend filter ────────────────────────────────────────────────────
    // Uses 50-bar SMA on 15m candles: only LONG above SMA, SHORT below.
    htfTrendFilter:   false,  // 15m trend is typically opposite 5m signal — not useful
    htfTrendMaPeriod: 50,

    // ── Session hour filter (UTC) ───────────────────────────────────────────
    // Evidence: 04 WR 12.5%, 11 WR 10.5%, 13 WR 26.8% — combined -$5,573 loss
    blockHours: const [4, 11, 13],

    // ── Volume filter ───────────────────────────────────────────────────────
    // High-vol P75 WR 35.2% vs low-vol P25 WR 27.0%
    minVolumeRatio:  0.8,
    volumeAvgPeriod: 20,

    // ── Minimum R:R gate ────────────────────────────────────────────────────
    // Best result: 0.8 → 41 trades, +7%, PF 1.19
    minNaturalRR: 0.8,

    // ── Volatility gate ─────────────────────────────────────────────────────
    // Skip entry if ATR > 1.2% of price (choppy / runaway regime)
    maxAtrPct: 1.2,

    // ── Calendar / month filter ─────────────────────────────────────────────
    // July consistently negative: SOL -609, ETH -655, ADA -221, XRP -341
    blockMonths: const [7],

    // ── Consecutive loss circuit breaker ────────────────────────────────────
    // After 3 losses in a row, pause ~4 hours (48 × 5m bars)
    maxConsecLosses: 3,
    coolingBars: 48,
  );

  // ── Load 5m candles ───────────────────────────────────────────────────────
  print('Loading 5m candles from ${config.csvPath}...');
  final candles = loadCsv(config.csvPath);
  if (candles.isEmpty) {
    print('ERROR: No candles loaded. Check path: ${config.csvPath}');
    return;
  }
  print('Loaded ${candles.length} 5m candles  '
      '(${_fmtDate(candles.first.time)} → ${_fmtDate(candles.last.time)})');

  // ── Load / build HTF candles for SR ──────────────────────────────────────
  List<Candle>? htfCandles;
  if (config.htfCsvPath != null) {
    print('Loading 15m candles from ${config.htfCsvPath}...');
    final raw15m = loadCsv(config.htfCsvPath!);
    if (raw15m.isEmpty) {
      print('ERROR: No 15m candles loaded. Check path: ${config.htfCsvPath}');
      return;
    }
    if (config.htfBuild45m) {
      htfCandles = buildAggregatedCandles(raw15m, 3);
      print('Built ${htfCandles.length} 45m candles from ${raw15m.length} 15m candles.');
    } else {
      htfCandles = raw15m;
      print('Using ${htfCandles.length} 15m candles for SR detection.');
    }
  }

  final htfLabel = htfCandles == null ? '5m' : (config.htfBuild45m ? '45m' : '15m');
  print('Running backtest — SFI on 5m | SR zones on $htfLabel...');

  final trades = Backtester(config).run(candles, htfCandles: htfCandles);

  print('\nBacktest complete — ${trades.length} trades found.\n');

  Reporter(config, trades, candles).printAll();
}
