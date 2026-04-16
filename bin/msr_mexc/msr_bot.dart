// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';
//
// import 'account_data.dart';
// import 'future_trade.dart';
// import '../model.dart';
// import '../rsi.dart';
// import '../sf.dart';
// import 'package:web_socket_channel/io.dart';
//
// import 'fetch_candle_data.dart';
// import 'mexc_websocket_pos_data.dart';
//
// // --- Configuration ---
// String uid = '';
// String mtoken = '';
// String htoken = '';
//
//
// // 1st trade: 0.1%, 2nd: 0.09%, 3rd: 0.06%, 4th: 0.02%
//
// List<double> dcaLevels = [];
// final double fixedLeverage = 4;
// // Store the calculated DCA price levels for the current session
// ///Add a list to stores all DCA levels
// double hardStopLossLevel = 0.0; ///Calculate on every minute according to market situation
//
// // [1x, 2x, 4x, 8x, 16x] - Volume multipliers, till now 8 is good
// List<int> volumeProcess = [2, 4];
// int volumeSize = 1; ///Can be change but should be balance more then:- Written Amount (500) * 8
//
// bool isTrade = false;
// bool isUpside = false;
// bool isCoolingDown = false; // New flag for waiting for RSI reset
//
// String tradableSymbol = 'SOL_USDT';
// String symbolShortName = 'SOL';
// String candleInterval = 'Min1';
// int sfiDirectionForReset = 0;
//
// ///Contains current trade data
// double symbolLivePrice = 0.0;
// double contractAverageWeightedPrice = 0.0;
// double contractAverageVolume = 0.0;
// double contractAverageLeverage = 0.0;
//
//
// const Duration websocketReconnectDelay = Duration(seconds: 3);
//
// void main() async {
//   startWebSocketLoop();
//
//   loop();
//
//   final client = MexcWsClient(
//     apiKey: "mx0vglW1UuQdZK0RL1",
//     secretKey: "98405139d2d44c9abc51e9fc769605f5",
//   );
//
//
//   await client.connect();
//
//   client.positionStreamController.stream.listen((pos) {
//     double closePL = double.tryParse(pos['closeProfitLoss'].toString()) ?? 0;
//
//     if (closePL != 0) {
//       // 🔵 Position Closed – print important close information
//       print("------ POSITION CLOSED ------");
//       print("Symbol: ${pos['symbol']}");
//       print("Closed Volume: ${pos['closeVol']}");
//       print("Close Avg Price: ${pos['closeAvgPrice']}");
//       print("Close P/L: ${pos['closeProfitLoss']}");
//       print("Realised P/L: ${pos['realised']}");
//       print("Fee: ${pos['fee']}");
//       print("-----------------------------");
//     } else {
//       // 🟠 No close profit → Print holding/open data
//       print("------ POSITION OPEN ------");
//       print("Symbol: ${pos['symbol']}");
//       print("Hold Volume: ${pos['holdVol']}");
//       print("Open Avg Price: ${pos['openAvgPrice']}");
//       print("Hold Avg Price: ${pos['holdAvgPrice']}");
//       print("Leverage: ${pos['leverage']}");
//       print("---------------------------");
//       contractAverageVolume = double.parse(pos['holdVol'].toString());
//       contractAverageWeightedPrice = double.parse(pos['holdAvgPrice'].toString());
//       contractAverageLeverage = double.parse(pos['leverage'].toString());
//     }
//   });
// }
// ///Work on every first minute of 3rd sec
// void loop() {
//   DateTime now = DateTime.now();
//   // Sync to next minute + 3 seconds
//   DateTime nextTrigger = DateTime(
//     now.year, now.month, now.day, now.hour, now.minute + 1, 3,
//   );
//
//   Duration initialDelay = nextTrigger.difference(now);
//   print('First analyse() will run in ${initialDelay.inSeconds} seconds');
//
//   Future.delayed(initialDelay, () {
//     analyse();
//     Timer.periodic(Duration(minutes: 1), (Timer t) {
//       analyse();
//     });
//   });
// }
//
//
// ///Start Websocket to fetch MARK Price of Asset
//
// Future<IOWebSocketChannel> connectSecureWs(String url) async {
//   final client = HttpClient()
//     ..badCertificateCallback =
//         (X509Certificate cert, String host, int port) => true;
//
//   final socket = await WebSocket.connect(
//     url,
//     customClient: client,
//   );
//
//   return IOWebSocketChannel(socket);
// }
//
// Future<void> startWebSocketLoop() async {
//   while (true) {
//     try {
//       print('🔌 Connecting to MEXC websocket...');
//
//       // CHANGED HERE: using connectSecureWs instead of WebSocketChannel.connect
//       final channel = await connectSecureWs('wss://contract.mexc.com/edge');
//
//       for (final s in ['SOL_USDT']) {
//         final msg = jsonEncode({
//           "method": "sub.fair.price",
//           "param": {"symbol": s}
//         });
//
//         channel.sink.add(msg);
//         print('📡 Subscribed to $s');
//       }
//
//       await for (final raw in channel.stream) {
//         try {
//           final data = jsonDecode(raw);
//
//           if (data is! Map ||
//               data['symbol'] == null ||
//               data['data'] == null) continue;
//
//           final String sym = data['symbol'];
//           final ticker = data['data'];
//
//           if (ticker == null || ticker['price'] == null) continue;
//
//           final price = (ticker['price'] as num).toDouble();
//           final uc = sym.toUpperCase();
//
//           if (uc.contains(symbolShortName)) {
//             symbolLivePrice = price;
//           }
//
//           print('📈 $uc → $price');
//
//           if (symbolLivePrice > 0) {
//             await continueCheckPnlAndExit(assetPrice: symbolLivePrice);
//           }
//         } catch (e) {
//           print('⚠️ Websocket message processing error: $e');
//         }
//       }
//     } catch (e) {
//       print('⚠️ Websocket connection error: $e');
//     }
//
//     print('🔁 Reconnecting in ${websocketReconnectDelay.inSeconds}s...');
//     await Future.delayed(websocketReconnectDelay);
//   }
// }
//
// SfiIndicator sfiIndicator = SfiIndicator();
//
// Future<void> analyse() async {
//   List<Candle> candleData = await fetchMexcCandles(
//       symbol: tradableSymbol,
//       limit: 300,
//       interval: candleInterval
//   );
//
//   final sfiData = await sfiIndicator.loop(candleData);
//   List<double> rsi = computeRSI(candleData, 8);
//   double rsiValue = rsi[rsi.length - 2];
//   print("RSI: $rsiValue | SFI: ${sfiData['direction']} | Cooldown: $isCoolingDown");
//
//   // --- 1. COOLDOWN LOGIC ---
//   if (isCoolingDown) {
//     // If we were Long, wait for RSI to go BELOW 70 to reset
//     if (isUpside && rsiValue < 70 && sfiDirectionForReset != sfiData['direction']) {
//       print("Cooldown Complete. RSI dropped below 70.");
//       isCoolingDown = false;
//       sfiDirectionForReset = 0;
//     }
//     // If we were Short, wait for RSI to go ABOVE 30 to reset
//     else if (!isUpside && rsiValue > 30 && sfiDirectionForReset != sfiData['direction']) {
//       print("Cooldown Complete. RSI rose above 30.");
//       isCoolingDown = false;
//       sfiDirectionForReset = 0;
//     }
//     // Still cooling down, do nothing
//     return;
//   }
//
//   // --- 2. ENTRY LOGIC ---
//   // BUY: SFI == 1 AND RSI > 70
//   if (rsiValue > 70 && sfiData['direction'] == 1 && !isTrade) {
//     isTrade = true;
//     isUpside = true;
//     sfiDirectionForReset = 1;
//     // 1. Execute Market Order
//     // Ensure correct Side: Long = BUY, Short = SELL
//     await FutureTrade.sendTradeRequest(
//         uid: uid,
//         mtoken: mtoken,
//         htoken: htoken,
//         symbol: tradableSymbol,
//         side: 'buy',
//         order_type: 5,
//         vol: volumeSize,
//         leverage: fixedLeverage
//     );
//     await Future.delayed(Duration(seconds: 1));
//     await manageDCALevels(
//         currentPrice: candleData.last.close,
//         sfiStop: sfiData['stoploss']
//     );
//     print('Long Side $isUpside $isTrade');
//   }
//   // SELL: SFI == -1 AND RSI < 30
//   else if (rsiValue < 30 && sfiData['direction'] == -1 && !isTrade) {
//     isTrade = true;
//     isUpside = false;
//     sfiDirectionForReset = -1;
//
//     // 1. Execute Market Order
//     // Ensure correct Side: Long = BUY, Short = SELL
//     await FutureTrade.sendTradeRequest(
//         uid: uid,
//         mtoken: mtoken,
//         htoken: htoken,
//         symbol: tradableSymbol,
//         side: 'sell',
//         order_type: 5,
//         vol: volumeSize,
//         leverage: fixedLeverage
//     );
//     await Future.delayed(Duration(seconds: 1));
//     await manageDCALevels(
//         currentPrice: candleData.last.close,
//         sfiStop: sfiData['stoploss']
//     );
//     print('Short Side $isUpside $isTrade');
//
//   }
// }
//
//
// Future<void> manageDCALevels({required double currentPrice, required double sfiStop}) async {
//   if (!isTrade) return;
//
//   // 2. Calculate DCA Levels (The "One by One" logic plan)
//   // Gap between Entry and Trailing value
//   double gap = (currentPrice - sfiStop).abs();
//   double step = gap / 2;
//
//   dcaLevels = [];
//   // Logic: 100(Entry) -> 99(Mid) -> 98(Trail) -> 97(Extended)
//   if (isUpside == true) {
//     dcaLevels.add(currentPrice - step);
//     dcaLevels.add(sfiStop);
//     hardStopLossLevel = (sfiStop - step);
//     ///Both part removed cause in my observation I haven't seen any hit last DCA and come back so at that place stoploss would be better
//     // dcaLevels.add(sfiStop - step);
//     // hardStopLossLevel = (sfiStop - step) - step; ///StopLoss
//   } else if(isUpside == false) {
//     dcaLevels.add(currentPrice + step);
//     dcaLevels.add(sfiStop);
//     hardStopLossLevel = (sfiStop + step);
//     // dcaLevels.add(sfiStop + step);
//     // hardStopLossLevel = (sfiStop + step) + step; ///StopLoss
//   }
//
//   await FutureTrade.sendCancelAllOrdersRequest(
//     uid: uid,
//     mtoken: mtoken,
//     htoken: htoken,
//   );
//
//   print("Placing DCA Limit Order for Pos: $dcaLevels ");
//   print('Stoploss:- $hardStopLossLevel');
//   for(int i =0 ; i < dcaLevels.length; i++){
//     await FutureTrade.sendTradeRequest(
//         uid: uid,
//         mtoken: mtoken,
//         htoken: htoken,
//         symbol: tradableSymbol,
//         side: isUpside ? 'buy' :'sell',
//         order_type: 2,
//         price: double.parse(dcaLevels[i].toStringAsFixed(2)),
//         vol: volumeProcess[i] * volumeSize,
//         leverage: fixedLeverage
//     );
//     await Future.delayed(Duration(seconds: 1));
//   }
//   ///This will cancel all order pending and recreate a new order with new Limit Type
//
// }
//
//
// Future<void> continueCheckPnlAndExit({required double assetPrice}) async {
//   if (!isTrade || contractAverageWeightedPrice == 0.0) return;
//
//   double targetPercent = 0.04; // Default for 4 or more
//
//   ///Update this when mexc start charging fees
//   if(contractAverageVolume == volumeSize){
//     targetPercent = 0.1;
//   }else if(contractAverageVolume == (volumeSize * 2) + volumeSize){
//     targetPercent = 0.08;
//   }else if(contractAverageVolume == (volumeSize * 4) + (volumeSize * 2) + volumeSize){
//     targetPercent = 0.06;
//   }
//   // else if(holdVol == (volumeSize * 8) + (volumeSize * 4) + (volumeSize * 2) + volumeSize){
//   //   targetPercent = 0.04;
//   // }
//   else{
//     targetPercent = 0.04;
//   }
//
//   // 3. Calculate Current PnL Percentage based on Price Move
//   // Formula: ((Current - Entry) / Entry) * 100
//   double priceMovePercent = ((assetPrice - contractAverageWeightedPrice) / contractAverageWeightedPrice) * 100;
//
//   bool takeProfitTriggered = false;
//
//   // 4. Check Exit Conditions
//   if (isUpside) {
//     // --- LONG POSITION LOGIC ---
//     // If we are Long, price move must be positive and greater than target
//     if (priceMovePercent >= targetPercent) {
//       takeProfitTriggered = true;
//     }
//   } else {
//     // --- SHORT POSITION LOGIC ---
//     // If we are Short, price move will be negative.
//     // We check if it dropped enough (e.g. -0.1% or lower).
//     // Note: We invert logic or use absolute value for short targets.
//     // Ideally: Entry 100, Price 99.9 -> Move is -0.1%.
//     if (priceMovePercent <= -targetPercent) {
//       takeProfitTriggered = true;
//     }
//   }
//   double pnl = calculatePnl(
//       currentPrice: assetPrice,
//       openPrice: contractAverageWeightedPrice,
//       volume: contractAverageVolume,
//       leverage: contractAverageLeverage,
//       side: isUpside ? 'buy' : 'sell',
//       contractSize: 0.1
//   );
//   // 5. Execute Take Profit
//   if (takeProfitTriggered) {
//     print("✅ TAKE PROFIT TRIGGERED!");
//     print("Pnl: $pnl | Target: $targetPercent% | Actual Move: ${priceMovePercent.toStringAsFixed(4)}%");
//
//     await FutureTrade.sendTradeRequest(
//         uid: uid,
//         mtoken: mtoken,
//         htoken: htoken,
//         symbol: tradableSymbol,
//         side: isUpside ? 'broughtsell' : 'soldbuy', // Close Long or Close Short
//         order_type: 5,
//         vol: contractAverageVolume.toInt(), // Close entire volume
//         leverage: fixedLeverage
//     );
//
//     // Reset State & Start Cooldown
//     isTrade = false;
//     isUpside = true; // Resetting to default direction (optional based on your strategy)
//     isCoolingDown = true;
//     print("Exited Position. Entering Cooldown...");
//     await Future.delayed(Duration(seconds: 1));
//     await FutureTrade.sendCancelAllOrdersRequest(
//       uid: uid,
//       mtoken: mtoken,
//       htoken: htoken,
//     );
//     return; // Exit function so we don't hit Stop Loss logic below immediately
//   }
//
//   // --- STOP LOSS LOGIC ---
//   bool hitStop = false;
//   if (isUpside && assetPrice < hardStopLossLevel) hitStop = true;
//   if (!isUpside && assetPrice > hardStopLossLevel) hitStop = true;
//
//   if (hitStop) {
//     print("🛑 STOP LOSS HIT at $assetPrice (Thresh: $hardStopLossLevel)");
//
//     // Close Position
//     await FutureTrade.sendTradeRequest(
//         uid: uid,
//         mtoken: mtoken,
//         htoken: htoken,
//         symbol: tradableSymbol,
//         side: isUpside ? 'broughtsell' : 'soldbuy',
//         order_type: 5,
//         vol: contractAverageVolume.toInt(),
//         leverage: fixedLeverage
//     );
//
//     isTrade = false;
//     isCoolingDown = true;
//     await Future.delayed(Duration(seconds: 1));
//     await FutureTrade.sendCancelAllOrdersRequest(
//       uid: uid,
//       mtoken: mtoken,
//       htoken: htoken,
//     );
//   }
// }
//
//
// double calculatePnl({
//   required double currentPrice,
//   required double openPrice,
//   required double volume,
//   required double leverage,
//   required String side,
//   required double contractSize,
// }) {
//   if (volume == 0) return 0.0;
//   double diff = (side == 'buy') ? (currentPrice - openPrice) : (openPrice - currentPrice);
//   return diff * volume * contractSize;
// }
