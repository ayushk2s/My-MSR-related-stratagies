import 'dart:io';
import 'dart:math';

// =======================
// 1. DATA MODELS
// =======================

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  Candle(this.time, this.open, this.high, this.low, this.close, this.volume);
}

class SfiResult {
  final int direction; // 1 (Long) or -1 (Short)
  final double entry;
  final List<double> targets;
  final double stoploss;

  SfiResult({
    required this.direction,
    required this.entry,
    required this.targets,
    required this.stoploss,
  });
}

class TradeZone {
  final DateTime startTime;
  DateTime endTime;
  final double top;
  final double bottom;
  final bool isResistance;
  TradeZone({
    required this.startTime,
    required this.endTime,
    required this.top,
    required this.bottom,
    required this.isResistance,
  });
}

class Trade {
  final DateTime entryTime;
  final double entryPrice;
  final int direction;
  final double firstTarget;
  final double stopLoss;
  final double quantity; // Amount of SOL bought

  bool isPartialClosed = false;
  double realizedPnL = 0.0; // PnL booked in USD
  double feesPaid = 0.0;    // Fees paid in USD

  Trade({
    required this.entryTime,
    required this.entryPrice,
    required this.direction,
    required this.firstTarget,
    required this.stopLoss,
    required this.quantity,
  });
}

// =======================
// 2. CONFIGURATION
// =======================

const double INITIAL_CAPITAL = 1000.0; // Starting Balance
const double FEE_RATE = 0.0005;        // 0.05% Fee per order (Standard Crypto Exchange)
const double LEVERAGE = 1.0;           // 1x Leverage (Spot) - Change to 5.0 or 10.0 for Futures

// =======================
// 3. MAIN BACKTEST ENGINE
// =======================

void main() async {
  print("--- Starting Advanced Backtest ---");

  // 1. Load Data
  final File file = File('/Users/ayush/StudioProjects/msr_bot/lib/backtesting_msr/SOLUSDT5m.csv');
  if (!await file.exists()) {
    print("Error: SOLUSDT5m.csv not found.");
    return;
  }
  List<Candle> candles = await loadCsv(file);
  if (candles.isEmpty) return;

  // 2. Setup Portfolio
  double balance = INITIAL_CAPITAL;
  double maxBalance = INITIAL_CAPITAL;
  double maxDrawdownPercent = 0.0;

  List<double> equityCurve = [INITIAL_CAPITAL];
  List<Map<String, dynamic>> tradeHistory = [];

  // 3. Generate Mock Indicators (Replace with your real logic later)
  // Generating simplified zones/signals for demonstration
  List<TradeZone> zones = [
    TradeZone(startTime: candles.first.time, endTime: candles.last.time, top: 189.50, bottom: 188.00, isResistance: false),
    TradeZone(startTime: candles.first.time, endTime: candles.last.time, top: 200.00, bottom: 199.00, isResistance: true)
  ];

  List<SfiResult> sfiResults = List.generate(candles.length, (index) {
    if (candles[index].close < 190.0) {
      return SfiResult(direction: 1, entry: candles[index].close, targets: [candles[index].close + 2.0], stoploss: candles[index].close - 1.5);
    } else if (candles[index].close > 198.0) {
      return SfiResult(direction: -1, entry: candles[index].close, targets: [candles[index].close - 2.0], stoploss: candles[index].close + 1.5);
    }
    return SfiResult(direction: 0, entry: 0, targets: [], stoploss: 0);
  });

  Trade? currentTrade;
  print("Processing ${candles.length} candles...");

  for (int i = 0; i < candles.length; i++) {
    Candle c = candles[i];
    SfiResult sfi = sfiResults[i];

    // --- A. MANAGE OPEN TRADE ---
    if (currentTrade != null) {
      double currentPrice = c.close; // Approximate execution at close

      // 1. Check STOP LOSS (First Priority)
      bool slHit = false;
      if (currentTrade.direction == 1 && c.low <= currentTrade.stopLoss) slHit = true;
      if (currentTrade.direction == -1 && c.high >= currentTrade.stopLoss) slHit = true;

      if (slHit) {
        // Calculate Exit Price (Slippage simulated by using SL price directly)
        double exitPrice = currentTrade.stopLoss;
        double remainingQty = currentTrade.isPartialClosed ? currentTrade.quantity * 0.2 : currentTrade.quantity;

        // PnL Calculation
        double pnl = (exitPrice - currentTrade.entryPrice) * currentTrade.direction * remainingQty;
        double fee = (exitPrice * remainingQty) * FEE_RATE;

        balance += (pnl - fee);
        currentTrade.realizedPnL += pnl;
        currentTrade.feesPaid += fee;

        tradeHistory.add({
          "type": "SL",
          "pnl": currentTrade.realizedPnL,
          "fees": currentTrade.feesPaid,
          "reason": "Price hit Stop Loss"
        });

        currentTrade = null;
      }

      // 2. Check TARGET 1 (Partial Take Profit)
      else if (!currentTrade.isPartialClosed) {
        bool tpHit = false;
        if (currentTrade.direction == 1 && c.high >= currentTrade.firstTarget) tpHit = true;
        if (currentTrade.direction == -1 && c.low <= currentTrade.firstTarget) tpHit = true;

        if (tpHit) {
          double exitPrice = currentTrade.firstTarget;
          double sizeToClose = currentTrade.quantity * 0.80; // 80% Close

          double pnl = (exitPrice - currentTrade.entryPrice) * currentTrade.direction * sizeToClose;
          double fee = (exitPrice * sizeToClose) * FEE_RATE;

          balance += (pnl - fee); // Add realized gains to balance
          currentTrade.realizedPnL += pnl;
          currentTrade.feesPaid += fee;
          currentTrade.isPartialClosed = true;
        }
      }

      // 3. Check REVERSAL SIGNAL (Close Remaining)
      else if ((currentTrade.direction == 1 && sfi.direction == -1) ||
          (currentTrade.direction == -1 && sfi.direction == 1)) {

        double remainingQty = currentTrade.quantity * 0.20; // Remaining 20%
        double exitPrice = c.close;

        double pnl = (exitPrice - currentTrade.entryPrice) * currentTrade.direction * remainingQty;
        double fee = (exitPrice * remainingQty) * FEE_RATE;

        balance += (pnl - fee);
        currentTrade.realizedPnL += pnl;
        currentTrade.feesPaid += fee;

        tradeHistory.add({
          "type": "SIGNAL FLIP",
          "pnl": currentTrade.realizedPnL, // Total Trade PnL
          "fees": currentTrade.feesPaid,
          "reason": "Opposite Signal Received"
        });

        currentTrade = null;
      }
    }

    // --- B. OPEN NEW TRADE ---
    if (currentTrade == null && sfi.direction != 0) {
      // Zone filter logic (Simplified for space)
      bool validEntry = false;
      if (sfi.direction == 1) { // Long
        if (zones.any((z) => !z.isResistance && c.low <= z.top && c.high >= z.bottom)) validEntry = true;
      } else { // Short
        if (zones.any((z) => z.isResistance && c.high >= z.bottom && c.low <= z.top)) validEntry = true;
      }

      if (validEntry) {
        // Calculate Position Size
        // We use ALL current balance * Leverage
        double positionValue = balance * LEVERAGE;
        double qty = positionValue / c.close;
        double entryFee = positionValue * FEE_RATE;

        balance -= entryFee; // Deduct entry fee immediately

        currentTrade = Trade(
            entryTime: c.time,
            entryPrice: c.close,
            direction: sfi.direction,
            firstTarget: sfi.targets[0],
            stopLoss: sfi.stoploss,
            quantity: qty
        );

        // Track initial fee
        currentTrade.feesPaid += entryFee;
      }
    }

    // --- C. UPDATE STATS ---
    // Update Drawdown tracking
    if (balance > maxBalance) maxBalance = balance;
    double currentDD = (maxBalance - balance) / maxBalance * 100;
    if (currentDD > maxDrawdownPercent) maxDrawdownPercent = currentDD;

    equityCurve.add(balance);
  }

  // =======================
  // 4. GENERATE REPORT
  // =======================

  double totalPnL = balance - INITIAL_CAPITAL;
  int totalTrades = tradeHistory.length;
  int wins = tradeHistory.where((t) => t['pnl'] > 0).length;
  int losses = totalTrades - wins;

  // Find Best/Worst
  tradeHistory.sort((a, b) => b['pnl'].compareTo(a['pnl'])); // Sort High to Low
  double highestProfit = totalTrades > 0 ? tradeHistory.first['pnl'] : 0.0;
  double highestLoss = totalTrades > 0 ? tradeHistory.last['pnl'] : 0.0;

  print("\n========================================");
  print("      ADVANCED BACKTEST REPORT");
  print("========================================");
  print("Strategy: SFI + Dynamic Zones");
  print("Data: SOLUSDT (5m)");
  print("Initial Capital: \$${INITIAL_CAPITAL.toStringAsFixed(2)}");
  print("Final Balance:   \$${balance.toStringAsFixed(2)}");
  print("Net Profit:      \$${totalPnL.toStringAsFixed(2)} (${(totalPnL/INITIAL_CAPITAL*100).toStringAsFixed(2)}%)");
  print("----------------------------------------");
  print("Total Trades:    $totalTrades");
  print("Win Rate:        ${totalTrades > 0 ? ((wins/totalTrades)*100).toStringAsFixed(1) : 0}% ($wins W / $losses L)");
  print("Max Drawdown:    ${maxDrawdownPercent.toStringAsFixed(2)}% (Risk of Ruin)");
  print("Fees Paid:       \$${tradeHistory.fold(0.0, (sum, t) => sum + (t['fees'] as double)).toStringAsFixed(2)}");
  print("----------------------------------------");
  print("Highest Profit:  \$${highestProfit.toStringAsFixed(2)}");
  print("Highest Loss:    \$${highestLoss.toStringAsFixed(2)}");
  print("========================================");

  // Analysis
  print("\n[ANALYSIS & REASONING]");
  if (losses > 0) {
    print("Primary Cause of Loss:");
    // Simple heuristic based on the logs
    int slCount = tradeHistory.where((t) => t['type'] == 'SL').length;
    if (slCount > losses / 2) {
      print("- Stop Loss Hits: Market volatility spiked against position before TP.");
    } else {
      print("- Signal Flip Losses: Trend changed before TP1 was hit (Choppy Market).");
    }
    print("- Fees: You paid roughly \$${(tradeHistory.fold(0.0, (sum, t) => sum + (t['fees'] as double)) / totalTrades).toStringAsFixed(2)} per trade.");
  } else {
    print("No losses recorded. Warning: Check if Logic is 'Too Perfect' or Data is limited.");
  }
}

Future<List<Candle>> loadCsv(File file) async {
  List<Candle> data = [];
  List<String> lines = await file.readAsLines();
  int startRow = lines[0].startsWith("Date") ? 1 : 0;
  for (int i = startRow; i < lines.length; i++) {
    var parts = lines[i].split(',');
    if (parts.length < 6) continue;
    try {
      data.add(Candle(
          DateTime.parse(parts[0]),
          double.parse(parts[1]), double.parse(parts[2]), double.parse(parts[3]), double.parse(parts[4]), double.parse(parts[5])
      ));
    } catch (e) {}
  }
  return data;
}