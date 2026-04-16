import 'dart:convert';
import 'package:http/http.dart' as http;

import '../model.dart';

// Interval string → duration in milliseconds
const _intervalMs = {
  '1m':  60000,
  '3m':  180000,
  '5m':  300000,
  '15m': 900000,
  '30m': 1800000,
  '1h':  3600000,
  '2h':  7200000,
  '4h':  14400000,
  '6h':  21600000,
  '8h':  28800000,
  '12h': 43200000,
  '1d':  86400000,
};

/// Fetch OHLCV candles from Binance Futures (fapi.binance.com).
/// Used for SR analysis — same response format as Asterdex.
///
/// [symbol]   e.g. 'SOLUSDT'
/// [interval] e.g. '5m', '15m', '1h'
/// [limit]    number of candles (max 1500)
/// [offset]   how many candles back from now to end the window (0 = live data)
Future<List<Candle>> fetchBinanceCandles({
  required String symbol,
  String interval = '5m',
  int limit = 1000,
  int offset = 0,
}) async {
  if (!_intervalMs.containsKey(interval)) {
    throw Exception('Unsupported interval: $interval. '
        'Valid: ${_intervalMs.keys.join(', ')}');
  }

  final Map<String, String> params = {
    'symbol': symbol,
    'interval': interval,
    'limit': limit.toString(),
  };

  if (offset > 0) {
    final step = _intervalMs[interval]!;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final endTime = now - (offset * step);
    final startTime = endTime - (limit * step);
    params['startTime'] = startTime.toString();
    params['endTime'] = endTime.toString();
  }

  final uri = Uri.https('fapi.binance.com', '/fapi/v1/klines', params);

  final response = await http.get(uri, headers: {'Content-Type': 'application/json'});

  if (response.statusCode != 200) {
    throw Exception(
        'Binance klines failed (${response.statusCode}): ${response.body}');
  }

  final List<dynamic> body = jsonDecode(response.body);

  // Each row: [openTime, open, high, low, close, volume, closeTime, ...]
  return List.generate(body.length, (i) {
    final row = body[i] as List<dynamic>;
    return Candle(
      DateTime.fromMillisecondsSinceEpoch(row[0] as int, isUtc: true),
      double.parse(row[1].toString()),  // open
      double.parse(row[2].toString()),  // high
      double.parse(row[3].toString()),  // low
      double.parse(row[4].toString()),  // close
      double.parse(row[5].toString()),  // volume
      i,
    );
  });
}

/// Fetch OHLCV candles from ASTERDEX (fapi.asterdex.com).
///
/// [symbol]   e.g. 'SOLUSDT'
/// [interval] e.g. '5m', '15m', '1h'
/// [limit]    number of candles (max 1500)
/// [offset]   how many candles back from now to end the window (0 = live data)
Future<List<Candle>> fetchAsterdexCandles({
  required String symbol,
  String interval = '5m',
  int limit = 1000,
  int offset = 0,
}) async {
  if (!_intervalMs.containsKey(interval)) {
    throw Exception('Unsupported interval: $interval. '
        'Valid: ${_intervalMs.keys.join(', ')}');
  }

  final step = _intervalMs[interval]!;
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;

  // offset shifts the end window back in time (0 = most recent closed candle)
  final endTime = now - (offset * step);
  final startTime = endTime - (limit * step);

  final uri = Uri.https('fapi.asterdex.com', '/fapi/v3/klines', {
    'symbol': symbol,
    'interval': interval,
    'startTime': startTime.toString(),
    'endTime': endTime.toString(),
    'limit': limit.toString(),
  });

  final response = await http.get(uri, headers: {'Content-Type': 'application/json'});

  if (response.statusCode != 200) {
    throw Exception(
        'Asterdex klines failed (${response.statusCode}): ${response.body}');
  }

  final List<dynamic> body = jsonDecode(response.body);

  // Each row: [openTime, open, high, low, close, volume, closeTime, ...]
  return List.generate(body.length, (i) {
    final row = body[i] as List<dynamic>;
    return Candle(
      DateTime.fromMillisecondsSinceEpoch(row[0] as int, isUtc: true),
      double.parse(row[1].toString()),  // open
      double.parse(row[2].toString()),  // high
      double.parse(row[3].toString()),  // low
      double.parse(row[4].toString()),  // close
      double.parse(row[5].toString()),  // volume
      i,
    );
  });
}
