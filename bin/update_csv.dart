// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

// ── Config ───────────────────────────────────────────────────────────────────

const csvPath  = '/Users/ayush/Desktop/msr/SOLUSDT5m.csv';
const symbol   = 'SOLUSDT';
const interval = '5m';
const intervalMs = 5 * 60 * 1000; // 5 minutes in ms

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Returns the open-time (ms) of the last candle already in the CSV.
int lastCsvTimestampMs(String path) {
  final lines = File(path).readAsLinesSync();
  for (int i = lines.length - 1; i >= 1; i--) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.isEmpty) continue;
    try {
      return DateTime.parse(parts[0]).millisecondsSinceEpoch;
    } catch (_) {}
  }
  throw Exception('Could not read last timestamp from CSV');
}

/// Fetch up to 1500 candles from Binance starting at [startMs] (inclusive).
Future<List<List<dynamic>>> fetchKlines(int startMs, int endMs) async {
  final uri = Uri.https('fapi.binance.com', '/fapi/v1/klines', {
    'symbol':    symbol,
    'interval':  interval,
    'startTime': startMs.toString(),
    'endTime':   endMs.toString(),
    'limit':     '1500',
  });

  final resp = await http.get(uri, headers: {'Content-Type': 'application/json'});
  if (resp.statusCode != 200) {
    throw Exception('Binance error (${resp.statusCode}): ${resp.body}');
  }
  return (jsonDecode(resp.body) as List).cast<List<dynamic>>();
}

String fmtTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String p(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}:${p(dt.second)}';
}

// ── Main ─────────────────────────────────────────────────────────────────────

Future<void> main() async {
  final file = File(csvPath);
  if (!file.existsSync()) {
    print('ERROR: CSV not found at $csvPath');
    return;
  }

  final lastMs  = lastCsvTimestampMs(csvPath);
  final startMs = lastMs + intervalMs; // first candle we DON'T have yet
  final nowMs   = DateTime.now().toUtc().millisecondsSinceEpoch;
  // Don't include the currently-forming (unclosed) candle
  final endMs   = nowMs - (nowMs % intervalMs) - intervalMs;

  print('CSV last candle : ${fmtTime(lastMs)}');
  print('Fetching from   : ${fmtTime(startMs)}');
  print('Fetching up to  : ${fmtTime(endMs)}');

  if (startMs > endMs) {
    print('CSV is already up to date.');
    return;
  }

  final sink    = file.openWrite(mode: FileMode.append);
  int   fetched = 0;
  int   cursor  = startMs;

  while (cursor <= endMs) {
    final batch = await fetchKlines(cursor, endMs);
    if (batch.isEmpty) break;

    for (final row in batch) {
      final openMs = row[0] as int;
      if (openMs > endMs) break;
      final time   = fmtTime(openMs);
      final open   = row[1];
      final high   = row[2];
      final low    = row[3];
      final close  = row[4];
      final volume = row[5];
      sink.writeln('$time,$open,$high,$low,$close,$volume');
      fetched++;
    }

    // Advance cursor past this batch
    final lastBatchMs = batch.last[0] as int;
    cursor = lastBatchMs + intervalMs;

    stdout.write('\r  Fetched $fetched candles (up to ${fmtTime(lastBatchMs)})   ');
    if (batch.length < 1500) break; // got everything
  }

  await sink.flush();
  await sink.close();
  stdout.writeln();

  if (fetched == 0) {
    print('Nothing new to append.');
  } else {
    print('Done — appended $fetched candles to $csvPath');
    print('CSV now ends at: ${fmtTime(endMs)}');
  }
}
