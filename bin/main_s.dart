import 'dart:async';
import '../model.dart';

// ─────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────

const symbols = ['SOLUSDT', 'ETHUSDT', 'BTCUSDT', 'ASTERUSDT'];

const tp1Atr = 1.5;
const tp2Atr = 3.0;

// ─────────────────────────────────────────────
// STATE
// ─────────────────────────────────────────────

class Position {
  final String symbol;
  final int dir; // 1 long, -1 short
  final double entry;
  final double atr;
  double sl;
  bool tp1Hit = false;
  bool tp2Hit = false;

  Position(this.symbol, this.dir, this.entry, this.atr, this.sl);
}

final positions = <String, Position?>{};

// ─────────────────────────────────────────────
// STRATEGY ENGINE
// ─────────────────────────────────────────────

void runStrategy(
  String symbol,
  List<Candle> htf,
  List<double> atr,
  List<int> sfi,
  List<double> hh,
  List<double> ll,
) {
  final i = htf.length - 1;

  if (i < 2) return;

  final prev = i - 1;

  // ─────────────────────────────
  // CONDITIONS
  // ─────────────────────────────

  final sfiFlipUp   = sfi[prev] == -1 && sfi[i] == 1;
  final sfiFlipDown = sfi[prev] == 1 && sfi[i] == -1;

  final breakoutUp   = htf[i].close > hh[i];
  final breakoutDown = htf[i].close < ll[i];

  final trendUp   = sfi[i] == 1;
  final trendDown = sfi[i] == -1;

  final price = htf[i].close;
  final a     = atr[i];

  final pos = positions[symbol];

  // ─────────────────────────────
  // ENTRY
  // ─────────────────────────────

  if (pos == null) {
    if (sfiFlipUp && breakoutUp && trendUp) {
      positions[symbol] = Position(
        symbol, 1, price, a,
        price - 2 * a,
      );
      print('🟢 LONG ENTRY $symbol @ $price');
    }

    else if (sfiFlipDown && breakoutDown && trendDown) {
      positions[symbol] = Position(
        symbol, -1, price, a,
        price + 2 * a,
      );
      print('🔴 SHORT ENTRY $symbol @ $price');
    }
  }

  // ─────────────────────────────
  // EXIT MANAGEMENT
  // ─────────────────────────────

  else {
    final p = pos!;
    final tp1 = p.dir == 1
        ? p.entry + tp1Atr * p.atr
        : p.entry - tp1Atr * p.atr;

    final tp2 = p.dir == 1
        ? p.entry + tp2Atr * p.atr
        : p.entry - tp2Atr * p.atr;

    // TP1
    if (!p.tp1Hit) {
      if ((p.dir == 1 && price >= tp1) ||
          (p.dir == -1 && price <= tp1)) {
        p.tp1Hit = true;
        print('💰 TP1 HIT $symbol');
      }
    }

    // TP2
    if (!p.tp2Hit) {
      if ((p.dir == 1 && price >= tp2) ||
          (p.dir == -1 && price <= tp2)) {
        p.tp2Hit = true;
        print('💰 TP2 HIT $symbol');
      }
    }

    // TRAILING SL (SFI based)
    if (p.dir == 1) {
      p.sl = price - 2 * a;
      if (price <= p.sl) {
        print('❌ EXIT LONG $symbol @ $price');
        positions[symbol] = null;
      }
    } else {
      p.sl = price + 2 * a;
      if (price >= p.sl) {
        print('❌ EXIT SHORT $symbol @ $price');
        positions[symbol] = null;
      }
    }
  }
}

void main() async {
  for (final s in symbols) {
    positions[s] = null;
  }

  Timer.periodic(Duration(seconds: 5), (_) async {
    for (final s in symbols) {
      
      // 🔴 YOU MUST IMPLEMENT THIS
      final htf = await fetchHTFCandles(s); // 30m / 60m
      final atr = computeATR(htf, 14);
      final sfi = computeSFI(htf, atr);
      final hh  = donchianHigh(htf, 40);
      final ll  = donchianLow(htf, 40);

      runStrategy(s, htf, atr, sfi, hh, ll);
    }
  });
}