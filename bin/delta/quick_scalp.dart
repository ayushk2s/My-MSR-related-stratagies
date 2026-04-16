// =============================================================================
// DELTA EXCHANGE — QUICK SCALP BACKTESTER
// =============================================================================
// Edge: Delta offers 0% closing fee within 30m (BTC) / 15m (other assets)
//       So total round-trip cost = only the OPEN fee + slippage both sides.
//
// Fee structure (after 50% referral rebate):
//   Open  maker : 0.02% × 0.5 = 0.01%
//   Open  taker : 0.05% × 0.5 = 0.025%
//   Close (within window): 0%
//   Slippage per side    : 0.015% (conservative for liquid 1m scalping)
//   → Total round-trip (maker open): 0.01% + 0.015% + 0.015% = 0.04%
//
// Strategy matrix (auto-generated, ~40 combos × 10 assets):
//   Signal  : RSI(3) extreme | RSI(5) extreme | Bollinger touch | SFI flip | Momentum
//   TP / SL : 4 combos from 0.08%/0.03% to 0.20%/0.07%
//   Filter  : no trend filter | 5m SFI trend direction required
//
// Max hold  : 29 bars/BTC (29 min), 14 bars/others (14 min) → force-close = 0% fee
// Entry     : next bar open  (conservative, assumes maker limit fills at next open)
// Cooldown  : 5 bars after any exit before re-entry
//
// Bias-free : signal from bar[i] close → entry at bar[i+1] open
//             TP/SL checked against bar high/low → SL wins same bar
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FEE CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _makerOpen  = 0.01;   // % effective after 50% rebate
const _slippage   = 0.015;  // % per side
const _openCost   = _makerOpen + _slippage;   // 0.025% per entry
const _closeCost  = _slippage;                // 0% fee + slippage = 0.015%
const _roundTrip  = _openCost + _closeCost;   // 0.04% total

const _notional   = 100.0;  // USDT capital per trade
const _leverage   = 5.0;
const _pos        = _notional * _leverage;    // 500 USDT notional position
const _cooldown   = 5;      // 1m bars between trades

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY DEFINITION
// ─────────────────────────────────────────────────────────────────────────────

enum Signal { rsi3, rsi5, bb20, sfi, momentum }

class Scalp {
  final String name;
  final Signal signal;
  final double tpPct;     // TP distance %
  final double slPct;     // SL distance %
  final bool   trendFilter; // require 5m SFI trend alignment

  const Scalp(this.name, this.signal, this.tpPct, this.slPct, this.trendFilter);
}

List<Scalp> _genStrategies() {
  final out = <Scalp>[];
  const signals = [Signal.rsi3, Signal.rsi5, Signal.bb20, Signal.sfi, Signal.momentum];
  const sigNames = ['RSI3', 'RSI5', 'BB20', 'SFI', 'Mom'];
  const tpsl = <(double, double)>[(0.08, 0.03), (0.10, 0.03), (0.15, 0.05), (0.20, 0.07)];
  const tpslNames = ['TP8/SL3', 'TP10/SL3', 'TP15/SL5', 'TP20/SL7'];

  for (int si = 0; si < signals.length; si++) {
    for (int ti = 0; ti < tpsl.length; ti++) {
      for (final tf in [false, true]) {
        final sfx = tf ? '+TF' : '';
        out.add(Scalp('${sigNames[si]}/${tpslNames[ti]}$sfx',
            signals[si], tpsl[ti].$1, tpsl[ti].$2, tf));
      }
    }
  }
  return out;
}

final _strategies = _genStrategies();

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class Res {
  final String asset, strat;
  final int    trades, wins;
  final double netPnl, returnPct, maxDdPct, calmar, profitFactor;
  final String grade;
  Res({required this.asset, required this.strat,
       required this.trades, required this.wins,
       required this.netPnl, required this.returnPct,
       required this.maxDdPct, required this.calmar,
       required this.profitFactor, required this.grade});
  double get wr => trades == 0 ? 0 : wins / trades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out   = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(',');
    if (p.length < 6) continue;
    final t = DateTime.parse(p[0].trim().replaceAll(' ', 'T') + 'Z');
    out.add(Candle(t, double.parse(p[1]), double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4]), double.parse(p[5]), out.length));
  }
  return out;
}

List<Candle> _clean(List<Candle> raw) {
  final out = <Candle>[];
  for (final c in raw) {
    if (c.volume <= 0) continue;
    if (out.isNotEmpty && c.time.difference(out.last.time).inMinutes > 5) continue;
    out.add(Candle(c.time, c.open, c.high, c.low, c.close, c.volume, out.length));
  }
  return out;
}

List<Candle> _agg(List<Candle> c, int n) {
  final out = <Candle>[];
  for (int i = 0; i + n - 1 < c.length; i += n) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < n; j++) {
      hi  = max(hi, c[i + j].high);
      lo  = min(lo, c[i + j].low);
      vol += c[i + j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i + n - 1].close, vol, out.length));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// INDICATORS (rolling, zero look-ahead)
// ─────────────────────────────────────────────────────────────────────────────

// RSI (Wilder smoothing)
List<double> _rsi(List<Candle> cs, int p) {
  final out = <double>[];
  double ag = 0, al = 0;
  for (int i = 0; i < cs.length; i++) {
    final chg  = i == 0 ? 0.0 : cs[i].close - cs[i - 1].close;
    final gain = max(chg, 0.0);
    final loss = max(-chg, 0.0);
    if (i == 0) { ag = gain; al = loss; out.add(50.0); continue; }
    ag = (ag * (p - 1) + gain) / p;
    al = (al * (p - 1) + loss) / p;
    out.add(al == 0 ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al));
  }
  return out;
}

// Bollinger Bands (middle, upper, lower)
({List<double> mid, List<double> upper, List<double> lower})
    _bb(List<Candle> cs, int p, double k) {
  final mid   = <double>[];
  final upper = <double>[];
  final lower = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final start = max(0, i - p + 1);
    final slice = cs.sublist(start, i + 1).map((c) => c.close).toList();
    final m     = slice.reduce((a, b) => a + b) / slice.length;
    final std   = slice.length < 2 ? 0.0
        : sqrt(slice.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b)
               / (slice.length - 1));
    mid.add(m);
    upper.add(m + k * std);
    lower.add(m - k * std);
  }
  return (mid: mid, upper: upper, lower: lower);
}

// SFI (SuperTrend-like)
class SfiSig {
  final int  trend;
  final bool buy, sell;
  const SfiSig(this.trend, this.buy, this.sell);
}

List<SfiSig> _sfi(List<Candle> cs, int p, double m) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT = 1;
  final out = <SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m*a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m*a;
    int t = prevT;
    if (prevT == -1 && cs[i].close > pDn) t = 1;
    else if (prevT == 1 && cs[i].close < pUp) t = -1;
    out.add(SfiSig(t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

// Rolling 20-bar volume SMA (using only past bars)
List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  double sum = 0;
  final buf = <double>[];
  for (int i = 0; i < cs.length; i++) {
    out.add(buf.isEmpty ? 0.0 : sum / buf.length);
    buf.add(cs[i].volume);
    sum += cs[i].volume;
    if (buf.length > p) { sum -= buf.removeAt(0); }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// PRECOMPUTED PER-ASSET
// ─────────────────────────────────────────────────────────────────────────────

class AssetData {
  final String       sym;
  final bool         isBtc;
  final List<Candle> c1;        // 1m candles (entry/exit timeframe)
  final List<Candle> c5;        // 5m (trend filter)
  final List<double> rsi3, rsi5;
  final List<double> bbMid, bbUp, bbLo;
  final List<SfiSig> sfi1;      // fast SFI on 1m (signal)
  final List<SfiSig> sfi5;      // SFI on 5m (trend filter)
  final List<double> volSma1;
  final int          maxHold;   // 29 for BTC, 14 for others

  AssetData({
    required this.sym, required this.isBtc,
    required this.c1, required this.c5,
    required this.rsi3, required this.rsi5,
    required this.bbMid, required this.bbUp, required this.bbLo,
    required this.sfi1, required this.sfi5,
    required this.volSma1,
  }) : maxHold = isBtc ? 29 : 14;
}

AssetData _loadAsset(String sym, String path) {
  final c1  = _clean(_loadCsv(path));
  final c5  = _agg(c1, 5);
  final r3  = _rsi(c1, 3);
  final r5  = _rsi(c1, 5);
  final bb  = _bb(c1, 20, 2.0);
  final sf1 = _sfi(c1, 5, 1.0);
  final sf5 = _sfi(c5, 10, 1.7);
  final vs  = _volSma(c1, 20);
  return AssetData(
    sym: sym, isBtc: sym == 'BTCUSDT',
    c1: c1, c5: c5,
    rsi3: r3, rsi5: r5,
    bbMid: bb.mid, bbUp: bb.upper, bbLo: bb.lower,
    sfi1: sf1, sfi5: sf5,
    volSma1: vs,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTEST ENGINE
// ─────────────────────────────────────────────────────────────────────────────

Res _run(AssetData d, Scalp s) {
  final c    = d.c1;
  final n    = c.length;

  double netEq = 0, peak = 0, maxDd = 0;
  double grossWin = 0, grossLoss = 0;
  int wins = 0, trades = 0, cd = 0;

  int?    entryBar;   // bar index where we entered
  int?    dir;        // +1 long, -1 short
  double? entryPx;

  final tp = s.tpPct / 100;
  final sl = s.slPct / 100;

  for (int i = 1; i < n - 1; i++) {
    final i5 = i ~/ 5;

    // ── Manage open trade ────────────────────────────────────────────────────
    if (entryBar != null) {
      final held = i - entryBar!;
      final ep   = entryPx!;
      final bar  = c[i];

      // TP/SL check (SL wins same bar)
      final tpPx = dir! == 1 ? ep * (1 + tp) : ep * (1 - tp);
      final slPx = dir! == 1 ? ep * (1 - sl) : ep * (1 + sl);

      final slHit = dir! == 1 ? bar.low  <= slPx : bar.high >= slPx;
      final tpHit = dir! == 1 ? bar.high >= tpPx : bar.low  <= tpPx;
      final forceClose = held >= d.maxHold;

      double? exitPx;
      if (slHit) {
        exitPx = slPx;
      } else if (tpHit) {
        exitPx = tpPx;
      } else if (forceClose) {
        exitPx = bar.close;  // neutral close within fee window
      }

      if (exitPx != null) {
        final pct   = dir! == 1
            ? (exitPx - ep) / ep
            : (ep - exitPx) / ep;
        final gross = pct * _pos;
        final cost  = _pos * (_openCost + _closeCost) / 100;
        final net   = gross - cost;

        netEq += net;
        trades++;
        if (net > 0) { wins++; grossWin += gross; }
        else         { grossLoss += gross.abs(); }

        if (netEq > peak) peak = netEq;
        if (peak - netEq > maxDd) maxDd = peak - netEq;

        entryBar = null; dir = null; entryPx = null;
        cd = _cooldown;
      }
      continue; // don't look for new signals while in trade
    }

    if (cd > 0) { cd--; continue; }

    // ── Signal detection (from previous bar's close — bias-free) ─────────────
    final prev = c[i - 1];
    bool longSig = false, shortSig = false;

    switch (s.signal) {
      case Signal.rsi3:
        longSig  = d.rsi3[i - 1] < 20;
        shortSig = d.rsi3[i - 1] > 80;
      case Signal.rsi5:
        longSig  = d.rsi5[i - 1] < 25;
        shortSig = d.rsi5[i - 1] > 75;
      case Signal.bb20:
        longSig  = prev.close <= d.bbLo[i - 1];
        shortSig = prev.close >= d.bbUp[i - 1];
      case Signal.sfi:
        longSig  = d.sfi1[i - 1].buy;
        shortSig = d.sfi1[i - 1].sell;
      case Signal.momentum:
        // 3 consecutive candles in same direction + volume spike
        if (i >= 3) {
          final v   = d.volSma1[i - 1];
          final vol = prev.volume;
          final volOk = v <= 0 || vol > v * 1.2;
          longSig  = c[i-3].close < c[i-2].close && c[i-2].close < c[i-1].close
                     && c[i-1].close > c[i-1].open && volOk;
          shortSig = c[i-3].close > c[i-2].close && c[i-2].close > c[i-1].close
                     && c[i-1].close < c[i-1].open && volOk;
        }
    }

    // ── 5m SFI trend filter ──────────────────────────────────────────────────
    if (s.trendFilter && i5 > 0 && i5 - 1 < d.sfi5.length) {
      final trend = d.sfi5[i5 - 1].trend;
      if (trend < 0) longSig  = false;
      if (trend > 0) shortSig = false;
    }

    if (!longSig && !shortSig) continue;

    // ── Enter at next bar's open ─────────────────────────────────────────────
    final fill = c[i].open;
    entryBar   = i;
    dir        = longSig ? 1 : -1;
    entryPx    = fill;
  }

  final retPct = netEq / _notional * 100;
  final ddPct  = maxDd  / _notional * 100;
  final calmar = ddPct > 0 ? retPct / ddPct : (retPct > 0 ? 99.0 : 0.0);
  final pf     = grossLoss > 0 ? grossWin / grossLoss : (grossWin > 0 ? 99.0 : 0.0);
  final grade  = calmar >= 5 && retPct >= 50 ? 'A★★★'
               : calmar >= 3 && retPct >= 30 ? 'B★★'
               : calmar >= 1 && retPct >= 10 ? 'C★'
               : netEq > 0                   ? 'D'
               : 'F';
  return Res(asset: d.sym, strat: s.name, trades: trades, wins: wins,
      netPnl: netEq, returnPct: retPct, maxDdPct: ddPct, calmar: calmar,
      profitFactor: pf, grade: grade);
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  const base = '/Users/ayush/Desktop/candlestick data/1m';

  final assets = [
    'BTCUSDT', 'ETHUSDT', 'SOLUSDT', 'XRPUSDT',
    'DOGEUSDT', 'BNBUSDT', 'LTCUSDT', 'ADAUSDT',
    'SUIUSDT',  'TRXUSDT',
  ];

  print('═' * 100);
  print(' DELTA QUICK SCALP — ${_strategies.length} strategies × ${assets.length} assets'
        ' = ${_strategies.length * assets.length} backtests');
  print(' Fee structure: open 0.01% (maker) + 0.015% slip × 2 = 0.04% round-trip');
  print(' Close within window: 0% fee (BTC 30m, others 15m)');
  print('═' * 100);

  final allRes = <Res>[];

  for (final sym in assets) {
    final path = '$base/${sym}1m.csv';
    if (!File(path).existsSync()) { print('  SKIP $sym'); continue; }
    final d = _loadAsset(sym, path);
    stdout.write('  $sym (${d.c1.length} bars, window=${d.maxHold}m) .');
    int done = 0;
    for (final strat in _strategies) {
      allRes.add(_run(d, strat));
      done++;
      if (done % 10 == 0) stdout.write('.');
    }
    print(' done');
  }

  // ── MASTER LEADERBOARD ────────────────────────────────────────────────────
  final profitable = allRes.where((r) => r.netPnl > 0).toList()
      ..sort((a, b) => b.calmar.compareTo(a.calmar));
  final total   = allRes.length;
  final profCnt = profitable.length;

  print('\n');
  _hdr('MASTER LEADERBOARD — Top 50 (${profCnt}/$total = '
       '${(profCnt/total*100).toStringAsFixed(1)}% profitable)');
  _tblHdr();
  for (int i = 0; i < profitable.length && i < 50; i++) {
    _tblRow(profitable[i], rank: i + 1);
  }
  _tblFoot();

  // ── SIGNAL ANALYSIS ───────────────────────────────────────────────────────
  print('\n');
  _hdr('SIGNAL ANALYSIS');
  _anaHdr();
  for (final sig in Signal.values) {
    final rs = allRes.where((r) => r.strat.startsWith(sig.name.toUpperCase().replaceAll('RSI', 'RSI')
        .replaceAll('BB20', 'BB20').replaceAll('SFI', 'SFI').replaceAll('MOMENTUM', 'Mom'))).toList();
    // Match by signal name prefix
    final sigPrefix = switch(sig) {
      Signal.rsi3     => 'RSI3',
      Signal.rsi5     => 'RSI5',
      Signal.bb20     => 'BB20',
      Signal.sfi      => 'SFI',
      Signal.momentum => 'Mom',
    };
    final rs2 = allRes.where((r) => r.strat.startsWith(sigPrefix)).toList();
    if (rs2.isEmpty) continue;
    _anaRow(sigPrefix, rs2);
  }

  // ── TP/SL ANALYSIS ────────────────────────────────────────────────────────
  print('\n');
  _hdr('TP / SL ANALYSIS');
  _anaHdr();
  for (final label in ['TP8/SL3', 'TP10/SL3', 'TP15/SL5', 'TP20/SL7']) {
    final rs = allRes.where((r) => r.strat.contains(label)).toList();
    _anaRow(label, rs);
  }

  // ── TREND FILTER ANALYSIS ─────────────────────────────────────────────────
  print('\n');
  _hdr('TREND FILTER ANALYSIS');
  _anaHdr();
  final noTf = allRes.where((r) => !r.strat.endsWith('+TF')).toList();
  final withTf = allRes.where((r) => r.strat.endsWith('+TF')).toList();
  _anaRow('No filter', noTf);
  _anaRow('5m SFI +TF', withTf);

  // ── PER-ASSET BEST ────────────────────────────────────────────────────────
  print('\n');
  _hdr('BEST STRATEGY PER ASSET');
  _tblHdr();
  for (final sym in assets) {
    final rs = profitable.where((r) => r.asset == sym).toList();
    if (rs.isNotEmpty) _tblRow(rs.first);
  }
  _tblFoot();

  // ── TRADE FREQUENCY ───────────────────────────────────────────────────────
  print('\n');
  _hdr('TOP 20 BY TRADE COUNT (highest frequency)');
  final byTrades = allRes.where((r) => r.netPnl > 0).toList()
      ..sort((a, b) => b.trades.compareTo(a.trades));
  _tblHdr();
  for (int i = 0; i < byTrades.length && i < 20; i++) {
    _tblRow(byTrades[i], rank: i + 1);
  }
  _tblFoot();

  // ── BEST OVERALL ─────────────────────────────────────────────────────────
  if (profitable.isNotEmpty) {
    final best = profitable.first;
    final trPerDay = best.trades / (allRes
        .where((r) => r.asset == best.asset && r.strat == best.strat)
        .firstOrNull?.trades ?? 1);
    print('\n');
    _hdr('BEST OVERALL');
    print('  Asset         : ${best.asset}');
    print('  Strategy      : ${best.strat}');
    print('  Total trades  : ${best.trades}');
    print('  Win rate      : ${best.wr.toStringAsFixed(1)}%');
    print('  Return        : ${best.returnPct.toStringAsFixed(1)}%  on \$$_notional capital');
    print('  Max DD        : ${best.maxDdPct.toStringAsFixed(1)}%');
    print('  Calmar        : ${best.calmar.toStringAsFixed(2)}');
    print('  Profit factor : ${best.profitFactor.toStringAsFixed(2)}');
    print('  Grade         : ${best.grade}');
    print('  Round-trip cost: $_roundTrip% per trade');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRINT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

void _hdr(String t) {
  const w = 100;
  final p = max(0, (w - t.length - 2) ~/ 2);
  print('═' * p + ' $t ' + '═' * max(0, w - p - t.length - 2));
}

void _tblHdr() {
  print('  # │ Asset     │ Strategy              │  Trades │   WR% │   PF  │  Ret%  │  DD%  │ Calmar │ Grade');
  print('─' * 100);
}

void _tblRow(Res r, {int? rank}) {
  final rk = rank != null ? rank.toString().padLeft(3) : '   ';
  print('$rk │ ${r.asset.padRight(9)} │ ${r.strat.padRight(22)}'
        '│ ${r.trades.toString().padLeft(7)} │'
        ' ${r.wr.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.profitFactor.toStringAsFixed(2).padLeft(5)} │'
        ' ${(r.returnPct >= 0 ? '+' : '')}${r.returnPct.toStringAsFixed(1).padLeft(5)}% │'
        ' ${r.maxDdPct.toStringAsFixed(1).padLeft(4)}% │'
        ' ${r.calmar.toStringAsFixed(2).padLeft(6)} │ ${r.grade}');
}

void _tblFoot() => print('─' * 100);

void _anaHdr() {
  print('${'Group'.padRight(14)} │ Profitable% │ AvgCalmar │ AvgPF │ BestCalmar │ AvgTrades │ A★  B★  C★');
  print('─' * 80);
}

void _anaRow(String label, List<Res> rs) {
  if (rs.isEmpty) return;
  final prof   = rs.where((r) => r.netPnl > 0).length;
  final pct    = (prof / rs.length * 100).round();
  final avgC   = rs.fold(0.0, (s, r) => s + r.calmar) / rs.length;
  final bestC  = rs.map((r) => r.calmar).reduce(max);
  final avgPF  = rs.fold(0.0, (s, r) => s + r.profitFactor) / rs.length;
  final avgT   = (rs.fold(0, (s, r) => s + r.trades) / rs.length).round();
  final aG     = rs.where((r) => r.grade == 'A★★★').length;
  final bG     = rs.where((r) => r.grade == 'B★★').length;
  final cG     = rs.where((r) => r.grade == 'C★').length;
  print('${label.padRight(14)} │  ${'$pct%'.padLeft(8)} │'
        ' ${avgC.toStringAsFixed(2).padLeft(9)} │'
        ' ${avgPF.toStringAsFixed(2).padLeft(5)} │'
        ' ${bestC.toStringAsFixed(2).padLeft(10)} │'
        ' ${avgT.toString().padLeft(9)} │'
        ' $aG    $bG    $cG');
}
