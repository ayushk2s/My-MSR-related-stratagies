import 'dart:async';
import 'aster_function.dart';
import 'order_book.dart';

class AsterRecursiveTradeFunction {

  // ── Helper: get position amount (abs) for a specific positionSide ──
  static Future<double> _getPositionAmt(String symbol, String positionSide) async {
    final pos = await AsterFunction.runingOrderInfo(symbol: symbol);
    for (final p in pos) {
      if (p['positionSide']?.toString() == positionSide) {
        return double.parse(p['positionAmt'].toString()).abs();
      }
    }
    return 0.0;
  }

  // =============== ENTRY LOGIC ===============
  static Future<void> tradeLimit({
    required String symbol,
    required String side,          // BUY or SELL
    required String positionSide,  // LONG or SHORT
    required double vol,
    required int leverage,
  }) async {

    print("🚀 Starting ENTRY for $symbol");

    // Set leverage
    await AsterFunction.changeLeverage(symbol: symbol, leverage: leverage);
    await Future.delayed(Duration(milliseconds: 300));

    while (true) {
      // Check if already executed
      var pos = await AsterFunction.runingOrderInfo(symbol: symbol);
      final d = pos.where((e) => double.parse(e['positionAmt'].toString()) != 0);
      if (d.isNotEmpty) {
        print("✅ Entry filled for $symbol");
        break;
      }


      // Fetch open orders
      List<dynamic> openOrders = await AsterFunction.getOpenOrders(symbol: symbol);
      double existingPrice = openOrders.isNotEmpty
          ? double.parse(openOrders[0]['price'])
          : 0.0;

      // Order book logic
      final md = await FetchBestBidAsk.bestBidAsk(symbol);
      double bestPrice = (positionSide == "LONG")
          ? double.parse(md['bids']) // Buy at bid
          : double.parse(md['asks']); // Sell at ask

      // If price is same, do nothing
      if (existingPrice == bestPrice) {
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      print("🔄 Updating ENTRY order: $existingPrice → $bestPrice");

      // Cancel old
      await AsterFunction.cancelAllOrders(symbol: symbol);

      // Place new
      await AsterFunction.placeOrder(
        symbol: symbol,
        side: side,
        type: 'LIMIT',
        quantity: vol,
        price: bestPrice,
        positionSide: positionSide,
      );

      await Future.delayed(Duration(milliseconds: 600));
    }
  }

  // =============== EXIT LOGIC ===============
  static Future<void> exitTrade({
    required String symbol,
    required String side,          // opposite of entry
    required String positionSide,  // LONG or SHORT
    required double vol,
  }) async {

    print("🚪 Starting EXIT for $symbol");

    while (true) {
      // Check if position is closed
      var pos = await AsterFunction.runingOrderInfo(symbol: symbol);
      final d = pos.where((e) => double.parse(e['positionAmt'].toString()) != 0);
      if (d.isEmpty) {
        await AsterFunction.cancelAllOrders(symbol: symbol);
        print("🎉 Exit filled for $symbol");
        break;
      }

      // Check open orders
      List<dynamic> orders = await AsterFunction.getOpenOrders(symbol: symbol);
      double existingPrice =
      orders.isNotEmpty ? double.parse(orders[0]['price']) : 0.0;

      // Order book logic
      final md = await FetchBestBidAsk.bestBidAsk(symbol);
      double bestPrice = (positionSide == "LONG")
          ? double.parse(md['asks']) // Exit LONG = sell at ask
          : double.parse(md['bids']); // Exit SHORT = buy at bid

      if (existingPrice == bestPrice) {
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      print("🔄 Updating EXIT order: $existingPrice → $bestPrice");

      // Cancel old
      await AsterFunction.cancelAllOrders(symbol: symbol);

      // Place updated exit
      await AsterFunction.placeOrder(
        symbol: symbol,
        side: side,
        type: 'LIMIT',
        quantity: vol,
        price: bestPrice,
        positionSide: positionSide,
      );

      await Future.delayed(Duration(milliseconds: 600));
    }
  }

  // =============== PARTIAL EXIT LOGIC ===============
  // Closes exactly [vol] qty via limit orders at best ask/bid.
  // Works for both partial closes (TP1, TP2) and full closes (SFI flip, SL).
  static Future<void> exitPartialTrade({
    required String symbol,
    required String side,         // SELL for LONG, BUY for SHORT
    required String positionSide, // LONG or SHORT
    required double vol,          // qty to close
  }) async {
    print("🚪 Partial exit: closing $vol $symbol ($positionSide)");

    final initialAmt = await _getPositionAmt(symbol, positionSide);

    while (true) {
      // Check if position already decreased by vol
      final currentAmt = await _getPositionAmt(symbol, positionSide);
      if (currentAmt <= initialAmt - vol + 0.0001) {
        await AsterFunction.cancelAllOrders(symbol: symbol);
        print("✅ Partial exit done for $symbol: $vol closed");
        break;
      }

      // Fetch open orders and best price
      final openOrders = await AsterFunction.getOpenOrders(symbol: symbol);
      final existingPrice = openOrders.isNotEmpty
          ? double.parse(openOrders[0]['price'].toString())
          : 0.0;

      final md = await FetchBestBidAsk.bestBidAsk(symbol);
      final bestPrice = (positionSide == 'LONG')
          ? double.parse(md['asks'].toString()) // exit LONG: sell at ask
          : double.parse(md['bids'].toString()); // exit SHORT: buy at bid

      if (existingPrice == bestPrice) {
        await Future.delayed(Duration(milliseconds: 500));
        continue;
      }

      print("🔄 Updating exit order: $existingPrice → $bestPrice");
      await AsterFunction.cancelAllOrders(symbol: symbol);
      await AsterFunction.placeOrder(
        symbol: symbol,
        side: side,
        type: 'LIMIT',
        quantity: vol,
        price: bestPrice,
        positionSide: positionSide,
      );

      await Future.delayed(Duration(milliseconds: 600));
    }
  }
}
