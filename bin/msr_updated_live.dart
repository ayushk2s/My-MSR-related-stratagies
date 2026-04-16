

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'model.dart';
import 'support_resistance_2.dart';

// ─── CREDENTIALS ─────────────────────────────────────────────────────────────

const _API_KEY    = 'YOUR_API_KEY';     // ← fill in
const _SECRET_KEY = 'YOUR_SECRET_KEY';  // ← fill in

// ─── EXCHANGE ENDPOINTS ───────────────────────────────────────────────────────
// Asterdex is Binance-compatible. Adjust WS_BASE if their WS domain differs.

const _REST_BASE = 'https://fapi.asterdex.com';
const _WS_BASE   = 'wss://fstream.asterdex.com';

// ─── ASSETS ──────────────────────────────────────────────────────────────────

const _ASSETS = [
  'BCHUSDT', 'BNBUSDT', 'BTCUSDT', 'DOGEUSDT', 'ETCUSDT',
  'ETHUSDT', 'LINKUSDT', 'SOLUSDT', 'XRPUSDT',
];

// ─── FROZEN CONFIG ───────────────────────────────────────────────────────────

// Indicators
const int    _SFI5_P   = 5;    const double _SFI5_M   = 1.2;
const int    _SFI45_P  = 7;    const double _SFI45_M  = 1.5;
const int    _RSI_P    = 14;
const int    _RSI_LOOK = 5;
const double _RSI_OS   = 45.0;  // RSI < 45 required for long divergence
const double _RSI_OB   = 55.0;  // RSI > 55 required for short divergence
const int    _VOL_LEN  = 20;
const double _VOL_MULT = 2.0;
const int    _ATR_P    = 14;
const int    _SR_LEN15 = 12;    // SR detectionLength on 15m bars
const int    _SR_LEN45 = 10;    // SR detectionLength on 45m bars

// Entry filters
const int    _MIN_SCORE  = 2;
const double _MIN_RR     = 1.0;
const double _SR_PROX    = 1.0;   // proximity %: price within 1% of zone
const double _MIN_ATR_PC = 0.25;  // skip if ATR% < 0.25% (choppy bar)
const int    _COOLDOWN   = 5;     // bars to skip after full stop-out

// Exit tiers (70% at TP1, 20% at TP2, 10% runner)
const double _SP1 = 0.70;
const double _SP2 = 0.20;
const double _SP3 = 0.10;

// ATR multipliers
const double _TP1_ATR   = 1.5;
const double _TP2_ATR   = 2.5;
const double _TRAIL_ATR = 3.0;
const double _BE_BUF    = 0.20;  // breakeven buffer after TP1
const double _SL_ATR    = 2.0;
const double _SL_BUF    = 0.15;  // zone-edge buffer %

// ─── POSITION SIZING ─────────────────────────────────────────────────────────
// Effective notional per trade = TRADE_NOTIONAL_USDT × LEVERAGE
// Example: 50 USDT × 5x = 250 USDT notional. Adjust to your account size.

const int    _LEVERAGE            = 5;
const double _TRADE_NOTIONAL_USDT = 50.0;

// Candle history to keep in memory (1000 × 5m ≈ 83 hours)
const int _HIST_BARS = 1000;

// ─── MODELS ──────────────────────────────────────────────────────────────────

class SfiBar {
  final double up, dn;
  final int trend;          // 1 = bullish, -1 = bearish
  final bool flipUp, flipDn;
  const SfiBar(this.up, this.dn, this.trend, this.flipUp, this.flipDn);
}

/// Quantities for the 3-tier exit, calculated once at entry to avoid rounding drift.
class TierQty {
  final double tp1Qty;      // 70% of position
  final double tp2Qty;      // 20% of position
  final double runnerQty;   // 10% of position (= total - tp1 - tp2)
  const TierQty(this.tp1Qty, this.tp2Qty, this.runnerQty);
}

class LiveTrade {
  final String symbol;
  final int    dir;          // 1 = long, -1 = short
  final double entry;
  final double hardSl;       // original SL (reference only)
  double sl;                 // current active SL (moves to breakeven after TP1)
  final double tp1;
  final double tp2;
  double trailStop;
  final TierQty tiers;
  double remainingQty;       // qty still open
  bool tp1Hit = false;
  bool tp2Hit = false;
  int? slOrderId;            // exchange order ID of current STOP_MARKET SL
  final DateTime entryTime;

  LiveTrade({
    required this.symbol,
    required this.dir,
    required this.entry,
    required this.hardSl,
    required this.sl,
    required this.tp1,
    required this.tp2,
    required this.trailStop,
    required this.tiers,
    required this.remainingQty,
    required this.entryTime,
    this.slOrderId,
  });

  String get dirLabel    => dir == 1 ? 'LONG'  : 'SHORT';
  String get openSide    => dir == 1 ? 'BUY'   : 'SELL';
  String get closeSide   => dir == 1 ? 'SELL'  : 'BUY';
  String get posSide     => dir == 1 ? 'LONG'  : 'SHORT';
}

class AssetState {
  final String symbol;
  int qtyPrecision = 2;

  // Candle history (trimmed to _HIST_BARS)
  final List<Candle> c5 = [];    // 5m bars
  List<Candle> c15 = [];         // aggregated 15m
  List<Candle> c45 = [];         // aggregated 45m

  // SR zones — rebuilt on startup, then every 4 hours
  List<SRZone> srZones = [];
  DateTime lastZoneRebuild = DateTime(2000);

  // Latest indicator series (recomputed on each bar close)
  List<SfiBar> sfi5  = [];
  List<SfiBar> sfi45 = [];
  List<double>  rsi  = [];
  List<double>  vol  = [];
  List<double>  atr  = [];

  // Trade state
  LiveTrade? activeTrade;
  int  cooldown     = 0;
  bool pendingEntry = false;
  int  pendingDir   = 0;

  // Gap detection
  DateTime lastBarTime = DateTime(2000);

  AssetState(this.symbol);
}

// ─── INDICATORS  (ported verbatim from v10_sweep_wf.dart) ────────────────────

List<SfiBar> _sfi(List<Candle> cs, int p, double m) {
  if (cs.isEmpty) return [];
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[];
  double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT = 1;
  final out = <SfiBar>[];
  for (int i = 0; i < cs.length; i++) {
    final a = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m * a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m * a;
    int t = prevT;
    if (prevT == -1 && cs[i].close > pDn) t = 1;
    else if (prevT == 1 && cs[i].close < pUp) t = -1;
    out.add(SfiBar(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

List<double> _rsi(List<Candle> cs, int p) {
  final out = <double>[];
  double ag = 0, al = 0;
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(50.0); continue; }
    final ch = cs[i].close - cs[i - 1].close;
    if (i <= p) {
      ag = (ag * (i - 1) + max(ch, 0.0)) / i;
      al = (al * (i - 1) + max(-ch, 0.0)) / i;
    } else {
      ag = (ag * (p - 1) + max(ch, 0.0)) / p;
      al = (al * (p - 1) + max(-ch, 0.0)) / p;
    }
    out.add(al == 0 ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al));
  }
  return out;
}

List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[];
  for (int i = 0; i < cs.length; i++) {
    if (i == 0) { out.add(0.0); continue; }
    final start = max(0, i - p);
    double s = 0;
    for (int j = start; j < i; j++) s += cs[j].volume;  // excludes current bar
    out.add(s / (i - start));
  }
  return out;
}

List<double> _atr(List<Candle> cs, int p) {
  final out = <double>[];
  double prev = cs.isEmpty ? 0 : cs[0].high - cs[0].low;
  for (int i = 0; i < cs.length; i++) {
    final pr = i == 0 ? cs[0].close : cs[i - 1].close;
    final tr = max(cs[i].high - cs[i].low,
                   max((cs[i].high - pr).abs(), (cs[i].low - pr).abs()));
    prev = i == 0 ? tr : (prev * (p - 1) + tr) / p;
    out.add(prev);
  }
  return out;
}

// ─── SIGNAL HELPERS ──────────────────────────────────────────────────────────

bool _rsiDivL(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  int bar = i - 1; double lo = cs[i - 1].low;
  for (int j = i - look; j < i - 1; j++) { if (cs[j].low < lo) { lo = cs[j].low; bar = j; } }
  return cs[i].low <= lo && rsi[i] > rsi[bar];
}

bool _rsiDivS(List<Candle> cs, List<double> rsi, int i, int look) {
  if (i < look + 1) return false;
  int bar = i - 1; double hi = cs[i - 1].high;
  for (int j = i - look; j < i - 1; j++) { if (cs[j].high > hi) { hi = cs[j].high; bar = j; } }
  return cs[i].high >= hi && rsi[i] < rsi[bar];
}

bool _pinL(Candle c) {
  final body = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  return (min(c.open, c.close) - c.low) >= body * 2.0 &&
         (c.close - c.low) / range >= 0.70;
}

bool _pinS(Candle c) {
  final body = (c.close - c.open).abs();
  final range = c.high - c.low;
  if (range < 1e-10) return false;
  return (c.high - max(c.open, c.close)) >= body * 2.0 &&
         (c.high - c.close) / range >= 0.70;
}

bool _engL(List<Candle> cs, int i) {
  if (i == 0) return false;
  final p = cs[i - 1], c = cs[i];
  return p.close < p.open && c.close > c.open && c.open < p.close && c.close > p.open;
}

bool _engS(List<Candle> cs, int i) {
  if (i == 0) return false;
  final p = cs[i - 1], c = cs[i];
  return p.close > p.open && c.close < c.open && c.open > p.close && c.close < p.open;
}

// ─── CANDLE AGGREGATION ───────────────────────────────────────────────────────

List<Candle> _agg(List<Candle> c, int n) {
  final out = <Candle>[];
  for (int i = 0; i + n - 1 < c.length; i += n) {
    double hi = c[i].high, lo = c[i].low, vol = 0;
    for (int j = 0; j < n; j++) {
      hi = max(hi, c[i + j].high);
      lo = min(lo, c[i + j].low);
      vol += c[i + j].volume;
    }
    out.add(Candle(c[i].time, c[i].open, hi, lo, c[i + n - 1].close, vol, out.length));
  }
  return out;
}

// ─── SR ZONE HELPERS ─────────────────────────────────────────────────────────

void _rebuildZones(AssetState st) {
  if (st.c15.length < _SR_LEN15 * 2 + 17) {
    _log('[${st.symbol}] Not enough 15m bars for SR (${st.c15.length})');
    return;
  }
  if (st.c45.length < _SR_LEN45 * 2 + 17) {
    _log('[${st.symbol}] Not enough 45m bars for SR (${st.c45.length})');
    return;
  }
  final sr15 = SupportResistanceIndicator(
      detectionLength: _SR_LEN15, srMargin: 2.0, avoidFBO: true, checkHist: false);
  final r15 = sr15.calculate(st.c15);

  final sr45 = SupportResistanceIndicator(
      detectionLength: _SR_LEN45, srMargin: 2.0, avoidFBO: true, checkHist: false);
  final r45 = sr45.calculate(st.c45);

  st.srZones = [...r15.support, ...r15.resistance, ...r45.support, ...r45.resistance];
  st.lastZoneRebuild = DateTime.now().toUtc();

  final aSup = st.srZones.where((z) => !z.isResistance && z.isActive).length;
  final aRes = st.srZones.where((z) =>  z.isResistance && z.isActive).length;
  _log('[${st.symbol}] Zones rebuilt — $aSup active S / $aRes active R');
}

SRZone? _nearSup(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.isResistance || !z.isActive) continue;
    if (z.boxTop >= price * 1.001) continue;   // must sit below price
    final d = price - z.boxTop;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

SRZone? _nearRes(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (!z.isResistance || !z.isActive) continue;
    if (z.boxBottom <= price * 0.999) continue; // must sit above price
    final d = z.boxBottom - price;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

bool _nearZone(SRZone z, double price, double pct) {
  final buf = price * pct / 100;
  return price >= z.boxBottom - buf && price <= z.boxTop + buf;
}

// ─── ASTERDEX REST API ────────────────────────────────────────────────────────

String _sign(String query) =>
    Hmac(sha256, utf8.encode(_SECRET_KEY)).convert(utf8.encode(query)).toString();

Map<String, String> get _authHdr => {'X-MBX-APIKEY': _API_KEY};
Map<String, String> get _formHdr => {
  'X-MBX-APIKEY': _API_KEY,
  'Content-Type': 'application/x-www-form-urlencoded',
};

Future<dynamic> _get(String path, [Map<String, String> extra = const {}]) async {
  final ts    = DateTime.now().millisecondsSinceEpoch.toString();
  final params = {...extra, 'timestamp': ts};
  final query  = params.entries.map((e) => '${e.key}=${e.value}').join('&');
  final sig    = _sign(query);
  final uri    = Uri.parse('$_REST_BASE$path?$query&signature=$sig');
  final res    = await http.get(uri, headers: _authHdr);
  if (res.statusCode != 200) throw Exception('GET $path → ${res.statusCode}: ${res.body}');
  return jsonDecode(res.body);
}

Future<dynamic> _post(String path, Map<String, String> params) async {
  final ts   = DateTime.now().millisecondsSinceEpoch.toString();
  final all  = {...params, 'timestamp': ts};
  final body = all.entries.map((e) => '${e.key}=${e.value}').join('&');
  final sig  = _sign(body);
  final uri  = Uri.parse('$_REST_BASE$path');
  final res  = await http.post(uri, headers: _formHdr, body: '$body&signature=$sig');
  if (res.statusCode != 200 && res.statusCode != 201) {
    throw Exception('POST $path → ${res.statusCode}: ${res.body}');
  }
  return jsonDecode(res.body);
}

Future<dynamic> _delete(String path, Map<String, String> params) async {
  final ts   = DateTime.now().millisecondsSinceEpoch.toString();
  final all  = {...params, 'timestamp': ts};
  final q    = all.entries.map((e) => '${e.key}=${e.value}').join('&');
  final sig  = _sign(q);
  final uri  = Uri.parse('$_REST_BASE$path?$q&signature=$sig');
  final res  = await http.delete(uri, headers: _authHdr);
  return jsonDecode(res.body);
}

/// Fetch historical klines from Asterdex REST.
Future<List<Candle>> _fetchKlines(String symbol, String interval, int limit) async {
  final uri = Uri.parse(
      '$_REST_BASE/fapi/v1/klines?symbol=$symbol&interval=$interval&limit=$limit');
  final res = await http.get(uri);
  if (res.statusCode != 200) throw Exception('klines failed ${res.statusCode}: ${res.body}');
  final data = jsonDecode(res.body) as List;
  final out = <Candle>[];
  for (final row in data) {
    final r = row as List;
    out.add(Candle(
      DateTime.fromMillisecondsSinceEpoch(r[0] as int, isUtc: true),
      double.parse(r[1].toString()),
      double.parse(r[2].toString()),
      double.parse(r[3].toString()),
      double.parse(r[4].toString()),
      double.parse(r[5].toString()),
      out.length,
    ));
  }
  return out;
}

/// Get lot-size precision from exchangeInfo.
Future<int> _fetchPrecision(String symbol) async {
  try {
    final uri = Uri.parse('$_REST_BASE/fapi/v1/exchangeInfo');
    final res = await http.get(uri);
    if (res.statusCode != 200) return 2;
    final data = jsonDecode(res.body);
    for (final s in (data['symbols'] as List? ?? [])) {
      if (s['symbol'] != symbol) continue;
      for (final f in (s['filters'] as List? ?? [])) {
        if (f['filterType'] == 'LOT_SIZE') {
          final step = f['stepSize'].toString();
          if (!step.contains('.')) return 0;
          final dec = step.split('.')[1].replaceAll(RegExp(r'0+$'), '');
          return dec.isEmpty ? 0 : dec.length;
        }
      }
    }
  } catch (_) {}
  return 2;
}

Future<void> _setLeverage(String symbol, int lev) async {
  try {
    await _post('/fapi/v1/leverage', {'symbol': symbol, 'leverage': lev.toString()});
    _log('[$symbol] Leverage set to ${lev}x');
  } catch (e) {
    _log('[$symbol] setLeverage error: $e');
  }
}

/// Place a MARKET order. Returns orderId or null on failure.
Future<int?> _market({
  required String symbol,
  required String side,
  required String posSide,
  required double qty,
  required int precision,
  bool reduceOnly = false,
}) async {
  final qStr = qty.toStringAsFixed(precision);
  final params = <String, String>{
    'symbol': symbol, 'side': side, 'type': 'MARKET',
    'quantity': qStr, 'positionSide': posSide,
  };
  if (reduceOnly) params['reduceOnly'] = 'true';
  try {
    final r = await _post('/fapi/v1/order', params);
    _log('[$symbol] MARKET $side $qStr → orderId=${r['orderId']}');
    return (r['orderId'] as num?)?.toInt();
  } catch (e) {
    _log('[$symbol] MARKET order error: $e');
    return null;
  }
}

/// Place a STOP_MARKET order (stop-loss protection). Returns orderId or null.
Future<int?> _stopMarket({
  required String symbol,
  required String side,
  required String posSide,
  required double qty,
  required int precision,
  required double stopPrice,
  bool reduceOnly = false,
}) async {
  final qStr  = qty.toStringAsFixed(precision);
  final spStr = stopPrice.toStringAsFixed(8)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
  final params = <String, String>{
    'symbol': symbol, 'side': side, 'type': 'STOP_MARKET',
    'quantity': qStr, 'stopPrice': spStr, 'positionSide': posSide,
  };
  if (reduceOnly) params['reduceOnly'] = 'true';
  try {
    final r = await _post('/fapi/v1/order', params);
    _log('[$symbol] STOP_MARKET $side @ $spStr qty=$qStr → orderId=${r['orderId']}');
    return (r['orderId'] as num?)?.toInt();
  } catch (e) {
    _log('[$symbol] STOP_MARKET error: $e');
    return null;
  }
}

Future<void> _cancelOrder(String symbol, int orderId) async {
  try {
    await _delete('/fapi/v1/order', {'symbol': symbol, 'orderId': orderId.toString()});
    _log('[$symbol] Cancelled order $orderId');
  } catch (e) {
    _log('[$symbol] cancelOrder error: $e');
  }
}

Future<void> _cancelAll(String symbol) async {
  try {
    await _delete('/fapi/v1/allOpenOrders', {'symbol': symbol});
    _log('[$symbol] All orders cancelled');
  } catch (e) {
    _log('[$symbol] cancelAll error: $e');
  }
}

// ─── BOT STATE ────────────────────────────────────────────────────────────────

final Map<String, AssetState> _states = {};

// ─── ON BAR CLOSE  (called when x=true in WS kline) ─────────────────────────

Future<void> _onBarClose(String symbol, Candle bar) async {
  final st = _states[symbol];
  if (st == null) return;

  // 1. Add closed bar, keep rolling window
  st.c5.add(Candle(bar.time, bar.open, bar.high, bar.low, bar.close,
                   bar.volume, st.c5.length));
  if (st.c5.length > _HIST_BARS) {
    st.c5.removeAt(0);
    // Re-index after removal so indices stay clean
    for (int k = 0; k < st.c5.length; k++) {
      final c = st.c5[k];
      st.c5[k] = Candle(c.time, c.open, c.high, c.low, c.close, c.volume, k);
    }
  }

  // 2. Rebuild derived timeframes
  st.c15 = _agg(st.c5, 3);
  st.c45 = _agg(st.c5, 9);

  // 3. Rebuild SR zones every 4 hours
  if (DateTime.now().toUtc().difference(st.lastZoneRebuild).inHours >= 4) {
    _rebuildZones(st);
  }

  final n = st.c5.length;
  if (n < 50) return;   // not enough history yet

  // 4. Recompute all indicators
  st.sfi5  = _sfi(st.c5,  _SFI5_P,  _SFI5_M);
  st.sfi45 = _sfi(st.c45, _SFI45_P, _SFI45_M);
  st.rsi   = _rsi(st.c5, _RSI_P);
  st.vol   = _volSma(st.c5, _VOL_LEN);
  st.atr   = _atr(st.c5, _ATR_P);

  // ATR value used at fill time = ATR of previous bar (mirrors backtest)
  final i    = n - 1;
  final atrV = i > 0 ? st.atr[i - 1] : st.atr[i];

  // 5. Cooldown tick
  if (st.cooldown > 0) st.cooldown--;

  // 6. Gap detection — >15 min between bars = missing candles
  final prevTime = st.lastBarTime;
  st.lastBarTime = bar.time;
  if (prevTime != DateTime(2000) &&
      bar.time.difference(prevTime).inMinutes > 15) {
    _log('[$symbol] ⚠ GAP detected — clearing pending, emergency-closing if active');
    st.pendingEntry = false; st.pendingDir = 0;
    if (st.activeTrade != null) await _emergencyClose(st, bar.close);
    st.cooldown = _COOLDOWN;
    return;
  }

  // 7. Fill pending signal from previous bar (mirrors backtest fill at bar[i].open)
  if (st.pendingEntry && st.cooldown == 0 && st.activeTrade == null) {
    final dir = st.pendingDir;
    st.pendingEntry = false; st.pendingDir = 0;
    await _enterTrade(st, dir, bar.close, atrV);
  }

  // 8. SFI flip check for runner exit (on bar close, uses previous bar's SFI)
  final t = st.activeTrade;
  if (t != null && t.tp1Hit && t.tp2Hit && i > 0) {
    final flip = t.dir == 1 ? st.sfi5[i - 1].flipDn : st.sfi5[i - 1].flipUp;
    if (flip) {
      _log('[$symbol] 🔁 Runner EXIT — SFI flip @ ${bar.close.toStringAsFixed(4)}');
      await _closeRunner(st, 'SFI flip on 5m');
      return;
    }
  }

  // 9. Check entry signals on this closed bar
  if (st.activeTrade == null && !st.pendingEntry && st.cooldown == 0) {
    _checkSignals(st, i, atrV);
  }

  _logState(st, bar, atrV);
}

// ─── INTRA-BAR TICK  (called on every WS kline update, including partial bars) ─

Future<void> _onTick(String symbol, double barH, double barL, double barC) async {
  final st = _states[symbol];
  if (st == null) return;
  final t = st.activeTrade;
  if (t == null) return;

  final atrV = st.atr.isNotEmpty ? st.atr.last : 0.0;

  // Update trailing stop for runner
  if (t.tp1Hit && t.tp2Hit && atrV > 0) {
    t.trailStop = t.dir == 1
        ? max(t.trailStop, barC - _TRAIL_ATR * atrV)
        : min(t.trailStop, barC + _TRAIL_ATR * atrV);
  }

  // Determine what happened this tick
  // Priority: SL > TP1 > TP2 > Trail (mirrors backtest order)
  final slHit    = t.dir == 1 ? barL <= t.sl : barH >= t.sl;
  final tp1Hit   = !t.tp1Hit && (t.dir == 1 ? barH >= t.tp1 : barL <= t.tp1);
  final tp2Hit   = t.tp1Hit && !t.tp2Hit &&
                   (t.dir == 1 ? barH >= t.tp2 : barL <= t.tp2);
  final trailHit = t.tp1Hit && t.tp2Hit &&
                   (t.dir == 1 ? barL <= t.trailStop : barH >= t.trailStop);

  if (slHit) {
    _log('[${t.symbol}] 🛑 SL HIT @ ${t.sl.toStringAsFixed(4)}'
         ' (${t.tp1Hit ? "BE stop" : "full stop-out"})');
    await _cancelSlOrder(st);
    // Market close remaining position (reduceOnly is a safety net)
    await _market(symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
                  qty: t.remainingQty, precision: st.qtyPrecision, reduceOnly: true);
    st.activeTrade = null;
    if (!t.tp1Hit) st.cooldown = _COOLDOWN;  // only cooldown on full stop-out

  } else if (tp1Hit) {
    await _handleTp1(st, atrV);

  } else if (tp2Hit) {
    await _handleTp2(st, atrV);

  } else if (trailHit) {
    _log('[${t.symbol}] 📉 Trail STOP HIT @ ${t.trailStop.toStringAsFixed(4)}');
    await _closeRunner(st, 'trail stop hit');
  }
}

// ─── SIGNAL DETECTION ────────────────────────────────────────────────────────

void _checkSignals(AssetState st, int i, double atrV) {
  final cs    = st.c5;
  final price = cs[i].close;

  // ATR filter — skip choppy bars
  final atrPct = price > 0 ? atrV / price * 100 : 0;
  if (atrPct < _MIN_ATR_PC) return;

  // ── Signal 1: SFI(5,1.2) flip on 5m ──
  final lSfi = st.sfi5[i].flipUp;
  final sSfi = st.sfi5[i].flipDn;

  // ── Signal 2: RSI(14) divergence + extremity gate ──
  final lRsi = _rsiDivL(cs, st.rsi, i, _RSI_LOOK) && st.rsi[i] < _RSI_OS;
  final sRsi = _rsiDivS(cs, st.rsi, i, _RSI_LOOK) && st.rsi[i] > _RSI_OB;

  // ── Signal 3: Volume spike > 2× 20-bar SMA ──
  final volSpike = st.vol[i] > 0 && cs[i].volume >= st.vol[i] * _VOL_MULT;

  // ── Signal 4: Pin bar (wick ≥ 2× body) OR engulfing ──
  final lPin = _pinL(cs[i]) || _engL(cs, i);
  final sPin = _pinS(cs[i]) || _engS(cs, i);

  // Cheap scores (no zone lookup yet)
  int lCheap = (lSfi?1:0) + (lRsi?1:0) + (volSpike?1:0) + (lPin?1:0);
  int sCheap = (sSfi?1:0) + (sRsi?1:0) + (volSpike?1:0) + (sPin?1:0);

  // ── Signal 5: SR proximity (price within 1% of zone) ──
  // Only do zone lookup if cheap score is already close to threshold
  int ls = lCheap; bool lSr = false;
  int ss = sCheap; bool sSr = false;

  if (lCheap >= _MIN_SCORE - 1 || sCheap >= _MIN_SCORE - 1) {
    final nSup = _nearSup(st.srZones, price);
    final nRes = _nearRes(st.srZones, price);
    if (nSup != null && _nearZone(nSup, price, _SR_PROX)) { ls++; lSr = true; }
    if (nRes != null && _nearZone(nRes, price, _SR_PROX)) { ss++; sSr = true; }
  }

  // ── 45m trend gate ──
  // Use the most recently COMPLETED 45m bar's SFI trend.
  // In live, st.c45 only contains complete groups of 9 × 5m bars, so
  // sfi45.last is the last fully-formed 45m bar — same as backtest's sfi45[i45s-1].
  final trend45 = st.sfi45.isNotEmpty ? st.sfi45.last.trend : 0;

  // ── Entry gate ──
  // score >= minScore AND (sfi flip OR sr proximity) AND 45m trend not opposed
  if (ls >= _MIN_SCORE && (lSfi || lSr) && trend45 >= 0) {
    st.pendingEntry = true; st.pendingDir = 1;
    _log('[${st.symbol}] ▲ LONG SIGNAL  score=$ls'
         '  sfi:$lSfi rsi:$lRsi vol:$volSpike pin:$lPin sr:$lSr'
         '  rsi=${st.rsi[i].toStringAsFixed(1)} trend45=$trend45');

  } else if (ss >= _MIN_SCORE && (sSfi || sSr) && trend45 <= 0) {
    st.pendingEntry = true; st.pendingDir = -1;
    _log('[${st.symbol}] ▼ SHORT SIGNAL score=$ss'
         '  sfi:$sSfi rsi:$sRsi vol:$volSpike pin:$sPin sr:$sSr'
         '  rsi=${st.rsi[i].toStringAsFixed(1)} trend45=$trend45');
  }
}

// ─── TRADE ENTRY ─────────────────────────────────────────────────────────────

Future<void> _enterTrade(AssetState st, int dir, double fill, double atrV) async {
  // ATR filter at fill time
  if (fill <= 0 || atrV / fill * 100 < _MIN_ATR_PC) {
    _log('[${st.symbol}] Entry skipped: ATR% too low at fill');
    return;
  }

  // ── SL ──
  final nSup = _nearSup(st.srZones, fill);
  final nRes = _nearRes(st.srZones, fill);

  double slP;
  if (dir == 1) {
    slP = nSup != null
        ? nSup.boxBottom * (1 - _SL_BUF / 100)
        : fill - _SL_ATR * atrV;
    if (slP >= fill) slP = fill - _SL_ATR * atrV;
  } else {
    slP = nRes != null
        ? nRes.boxTop * (1 + _SL_BUF / 100)
        : fill + _SL_ATR * atrV;
    if (slP <= fill) slP = fill + _SL_ATR * atrV;
  }

  // ── TP1 — nearest SR zone (ATR fallback) ──
  double tp1P;
  if (dir == 1) {
    tp1P = nRes != null ? nRes.boxBottom : fill + _TP1_ATR * atrV;
  } else {
    tp1P = nSup != null ? nSup.boxTop : fill - _TP1_ATR * atrV;
  }

  // ── TP2 — second SR zone beyond TP1 (ATR fallback) ──
  double tp2P;
  if (dir == 1) {
    final above = st.srZones
        .where((z) => z.isResistance && z.isActive && z.boxBottom > tp1P)
        .toList()..sort((a, b) => a.boxBottom.compareTo(b.boxBottom));
    tp2P = above.isNotEmpty ? above.first.boxBottom : fill + _TP2_ATR * atrV;
  } else {
    final below = st.srZones
        .where((z) => !z.isResistance && z.isActive && z.boxTop < tp1P)
        .toList()..sort((a, b) => b.boxTop.compareTo(a.boxTop));
    tp2P = below.isNotEmpty ? below.first.boxTop : fill - _TP2_ATR * atrV;
  }

  // ── Geometry validation ──
  final validL = dir ==  1 && tp1P > fill && fill > slP && tp2P > tp1P;
  final validS = dir == -1 && tp1P < fill && fill < slP && tp2P < tp1P;
  if (!validL && !validS) {
    _log('[${st.symbol}] Entry rejected: invalid SL/TP geometry'); return;
  }

  // ── RR check ──
  final rr = (tp1P - fill).abs() / (fill - slP).abs();
  if (rr < _MIN_RR) {
    _log('[${st.symbol}] Entry rejected: RR ${rr.toStringAsFixed(2)} < $_MIN_RR'); return;
  }

  // ── Position size ──
  final rawQty = (_TRADE_NOTIONAL_USDT * _LEVERAGE) / fill;
  final p      = st.qtyPrecision;
  final totalQ = double.parse(rawQty.toStringAsFixed(p));
  if (totalQ <= 0) { _log('[${st.symbol}] Entry rejected: qty too small'); return; }

  // Pre-calculate tier quantities (avoids rounding drift across partial closes)
  final tp1Q   = double.parse((totalQ * _SP1).toStringAsFixed(p));
  final tp2Q   = double.parse((totalQ * _SP2).toStringAsFixed(p));
  final runQ   = double.parse((totalQ - tp1Q - tp2Q).toStringAsFixed(p));
  // runQ may differ slightly from totalQ*0.10 — that's intentional (no leftover)

  final trailStop = dir == 1 ? fill - _TRAIL_ATR * atrV : fill + _TRAIL_ATR * atrV;

  _log('[${st.symbol}] ─── ENTERING ${dir == 1 ? "LONG" : "SHORT"} ───'
       '  fill=${fill.toStringAsFixed(4)}'
       '  qty=${totalQ.toStringAsFixed(p)}'
       '  SL=${slP.toStringAsFixed(4)}'
       '  TP1=${tp1P.toStringAsFixed(4)}'
       '  TP2=${tp2P.toStringAsFixed(4)}'
       '  RR=${rr.toStringAsFixed(2)}x'
       '  tiers: ${tp1Q.toStringAsFixed(p)} / ${tp2Q.toStringAsFixed(p)} / ${runQ.toStringAsFixed(p)}');

  final openSide  = dir == 1 ? 'BUY'  : 'SELL';
  final closeSide = dir == 1 ? 'SELL' : 'BUY';
  final posSide   = dir == 1 ? 'LONG' : 'SHORT';

  // Place entry
  await _market(symbol: st.symbol, side: openSide, posSide: posSide,
                qty: totalQ, precision: p);

  // Place exchange-side SL stop-market (for full position)
  final slId = await _stopMarket(
      symbol: st.symbol, side: closeSide, posSide: posSide,
      qty: totalQ, precision: p, stopPrice: slP, reduceOnly: true);

  st.activeTrade = LiveTrade(
    symbol: st.symbol, dir: dir, entry: fill,
    hardSl: slP, sl: slP, tp1: tp1P, tp2: tp2P,
    trailStop: trailStop,
    tiers: TierQty(tp1Q, tp2Q, runQ),
    remainingQty: totalQ,
    slOrderId: slId,
    entryTime: DateTime.now().toUtc(),
  );
}

// ─── TP1 ─────────────────────────────────────────────────────────────────────

Future<void> _handleTp1(AssetState st, double atrV) async {
  final t = st.activeTrade;
  if (t == null || t.tp1Hit) return;
  t.tp1Hit = true;

  _log('[${t.symbol}] ✅ TP1 @ ${t.tp1.toStringAsFixed(4)}'
       ' — closing ${((_SP1)*100).round()}% (${t.tiers.tp1Qty.toStringAsFixed(st.qtyPrecision)})');

  // Cancel full-size SL, close TP1 tranche
  await _cancelSlOrder(st);
  await _market(symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
                qty: t.tiers.tp1Qty, precision: st.qtyPrecision, reduceOnly: true);

  t.remainingQty = t.tiers.tp2Qty + t.tiers.runnerQty;

  // Move SL to breakeven ± buffer
  t.sl = t.dir == 1 ? t.entry - _BE_BUF * atrV : t.entry + _BE_BUF * atrV;

  // Place new SL at breakeven for remaining qty
  t.slOrderId = await _stopMarket(
      symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
      qty: t.remainingQty, precision: st.qtyPrecision,
      stopPrice: t.sl, reduceOnly: true);

  _log('[${t.symbol}] SL → breakeven ${t.sl.toStringAsFixed(4)}'
       '  remaining=${t.remainingQty.toStringAsFixed(st.qtyPrecision)}');
}

// ─── TP2 ─────────────────────────────────────────────────────────────────────

Future<void> _handleTp2(AssetState st, double atrV) async {
  final t = st.activeTrade;
  if (t == null || t.tp2Hit) return;
  t.tp2Hit = true;

  _log('[${t.symbol}] ✅ TP2 @ ${t.tp2.toStringAsFixed(4)}'
       ' — closing ${((_SP2)*100).round()}% (${t.tiers.tp2Qty.toStringAsFixed(st.qtyPrecision)})');

  await _cancelSlOrder(st);
  final closeQ = min(t.tiers.tp2Qty, t.remainingQty);
  await _market(symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
                qty: closeQ, precision: st.qtyPrecision, reduceOnly: true);

  t.remainingQty = max(0.0, t.remainingQty - closeQ);

  if (t.remainingQty <= 0) {
    _log('[${t.symbol}] Position fully closed (no runner)');
    st.activeTrade = null;
    return;
  }

  // Runner: trail from TP2
  t.trailStop = t.dir == 1
      ? t.tp2 - _TRAIL_ATR * atrV
      : t.tp2 + _TRAIL_ATR * atrV;

  _log('[${t.symbol}] 🏃 Runner active  qty=${t.remainingQty.toStringAsFixed(st.qtyPrecision)}'
       '  trail=${t.trailStop.toStringAsFixed(4)}'
       '  (exit on SFI flip OR trail hit)');
  // Note: runner has no exchange-side SL — monitored via WS ticks.
  // If bot restarts with an open runner, cancel all orders and close manually.
}

// ─── RUNNER CLOSE ────────────────────────────────────────────────────────────

Future<void> _closeRunner(AssetState st, String reason) async {
  final t = st.activeTrade;
  if (t == null) return;
  await _cancelSlOrder(st);
  if (t.remainingQty > 0) {
    await _market(symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
                  qty: t.remainingQty, precision: st.qtyPrecision, reduceOnly: true);
  }
  _log('[${t.symbol}] 🏁 Runner closed ($reason)'
       '  qty=${t.remainingQty.toStringAsFixed(st.qtyPrecision)}');
  st.activeTrade = null;
}

// ─── EMERGENCY CLOSE ─────────────────────────────────────────────────────────

Future<void> _emergencyClose(AssetState st, double price) async {
  final t = st.activeTrade;
  if (t == null) return;
  await _cancelSlOrder(st);
  if (t.remainingQty > 0) {
    await _market(symbol: t.symbol, side: t.closeSide, posSide: t.posSide,
                  qty: t.remainingQty, precision: st.qtyPrecision, reduceOnly: true);
  }
  _log('[${t.symbol}] ⚡ EMERGENCY CLOSE @ ${price.toStringAsFixed(4)}');
  st.activeTrade = null;
}

// ─── SL ORDER HELPER ─────────────────────────────────────────────────────────

Future<void> _cancelSlOrder(AssetState st) async {
  final id = st.activeTrade?.slOrderId;
  if (id != null) {
    await _cancelOrder(st.symbol, id);
    st.activeTrade?.slOrderId = null;
  }
}

// ─── WEBSOCKET ───────────────────────────────────────────────────────────────

Future<void> _runWs() async {
  // Build combined kline stream for all 9 assets
  final streams = _ASSETS.map((s) => '${s.toLowerCase()}@kline_5m').join('/');
  final wsUrl   = '$_WS_BASE/stream?streams=$streams';
  _log('Connecting WebSocket: $wsUrl');

  while (true) {  // outer reconnect loop
    try {
      final ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 20));
      _log('WebSocket connected ✓');

      // Keep-alive ping every 30 s
      final ping = Timer.periodic(const Duration(seconds: 30), (_) {
        if (ws.readyState == WebSocket.open) {
          ws.add(jsonEncode({'method': 'ping'}));
        }
      });

      await for (final raw in ws) {
        try {
          final msg  = jsonDecode(raw.toString());
          final data = (msg['data'] ?? msg) as Map<String, dynamic>;
          if (data['e'] != 'kline') continue;

          final sym = (data['s'] as String).toUpperCase();
          if (!_states.containsKey(sym)) continue;

          final k        = data['k'] as Map<String, dynamic>;
          final barH     = double.parse(k['h'].toString());
          final barL     = double.parse(k['l'].toString());
          final barC     = double.parse(k['c'].toString());
          final isClosed = k['x'] == true;

          // Tick — for intra-bar TP/SL/trail monitoring
          await _onTick(sym, barH, barL, barC);

          // Bar close — update indicators, check signals
          if (isClosed) {
            final barO   = double.parse(k['o'].toString());
            final barV   = double.parse(k['v'].toString());
            final barTs  = DateTime.fromMillisecondsSinceEpoch(
                k['t'] as int, isUtc: true);
            await _onBarClose(sym, Candle(barTs, barO, barH, barL, barC, barV, 0));
          }
        } catch (e, st) {
          _log('WS message error: $e\n$st');
        }
      }

      ping.cancel();
      _log('WebSocket closed — reconnecting in 5 s...');

    } catch (e) {
      _log('WebSocket error: $e — reconnecting in 5 s...');
    }
    await Future.delayed(const Duration(seconds: 5));
  }
}

// ─── STARTUP ─────────────────────────────────────────────────────────────────

Future<void> _startup() async {
  _log('════════════════════════════════════════════════════════');
  _log(' V10 REVERSAL ENGINE — Live Bot  (Asterdex Futures)');
  _log('════════════════════════════════════════════════════════');
  _log('Assets  : ${_ASSETS.join("  ")}');
  _log('Config  : SFI5($_SFI5_P,$_SFI5_M) SFI45($_SFI45_P,$_SFI45_M)'
       '  minScore=$_MIN_SCORE  minRR=$_MIN_RR  srProx=$_SR_PROX%');
  _log('Risk    : ${_TRADE_NOTIONAL_USDT} USDT × ${_LEVERAGE}x ='
       ' ${(_TRADE_NOTIONAL_USDT * _LEVERAGE).toStringAsFixed(0)} USDT notional/trade');
  _log('────────────────────────────────────────────────────────');

  for (final sym in _ASSETS) {
    _log('Init $sym ...');
    final st = AssetState(sym);
    _states[sym] = st;

    // Quantity precision
    st.qtyPrecision = await _fetchPrecision(sym);
    _log('  $sym  precision=${st.qtyPrecision}');

    // Set leverage
    await _setLeverage(sym, _LEVERAGE);

    // Fetch historical 5m candles
    final raw = await _fetchKlines(sym, '5m', _HIST_BARS);
    for (final c in raw) {
      if (c.volume > 0) {
        st.c5.add(Candle(c.time, c.open, c.high, c.low, c.close, c.volume, st.c5.length));
      }
    }
    _log('  $sym  ${st.c5.length} × 5m bars loaded');

    // Build derived timeframes
    st.c15 = _agg(st.c5, 3);
    st.c45 = _agg(st.c5, 9);
    _log('  $sym  ${st.c15.length} × 15m  |  ${st.c45.length} × 45m');

    // Build SR zones
    _rebuildZones(st);

    // Warm up indicators
    st.sfi5  = _sfi(st.c5,  _SFI5_P,  _SFI5_M);
    st.sfi45 = _sfi(st.c45, _SFI45_P, _SFI45_M);
    st.rsi   = _rsi(st.c5, _RSI_P);
    st.vol   = _volSma(st.c5, _VOL_LEN);
    st.atr   = _atr(st.c5, _ATR_P);

    if (st.c5.isNotEmpty) st.lastBarTime = st.c5.last.time;
    _log('  $sym  ✓ ready');

    await Future.delayed(const Duration(milliseconds: 300)); // REST rate-limit
  }

  _log('════════════════════════════════════════════════════════');
  _log(' ALL ASSETS READY — LIVE TRADING ACTIVE');
  _log('════════════════════════════════════════════════════════\n');
}

// ─── LOGGING ─────────────────────────────────────────────────────────────────

IOSink? _logSink;

void _log(String msg) {
  final ts   = DateTime.now().toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
  final line = '[$ts UTC] $msg';
  print(line);
  _logSink?.writeln(line);
}

void _logState(AssetState st, Candle bar, double atrV) {
  final t = st.activeTrade;
  if (t == null) {
    _log('[${st.symbol}] C=${bar.close.toStringAsFixed(4)}'
         '  ATR%=${(atrV/bar.close*100).toStringAsFixed(3)}%'
         '  cd=${st.cooldown}'
         '  pending=${st.pendingEntry ? (st.pendingDir==1?"LONG":"SHORT") : "none"}');
  } else {
    final pnlPct = t.dir == 1
        ? (bar.close - t.entry) / t.entry * 100
        : (t.entry - bar.close) / t.entry * 100;
    _log('[${st.symbol}] [${t.dirLabel}]'
         '  entry=${t.entry.toStringAsFixed(4)}'
         '  sl=${t.sl.toStringAsFixed(4)}'
         '  tp1=${t.tp1Hit ? "✓" : t.tp1.toStringAsFixed(4)}'
         '  tp2=${t.tp2Hit ? "✓" : t.tp2.toStringAsFixed(4)}'
         '  pnl=${pnlPct >= 0 ? "+" : ""}${pnlPct.toStringAsFixed(2)}%'
         '  rem=${t.remainingQty.toStringAsFixed(st.qtyPrecision)}');
  }
}

// ─── MAIN ────────────────────────────────────────────────────────────────────

Future<void> main() async {
  // Open daily log file
  final date    = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final logPath = 'v10_bot_$date.log';
  _logSink = File(logPath).openWrite(mode: FileMode.append);
  _log('Log → $logPath');

  // Graceful shutdown on Ctrl+C
  ProcessSignal.sigint.watch().listen((_) async {
    _log('\n⚠  SIGINT — shutting down gracefully');
    for (final st in _states.values) {
      if (st.activeTrade != null) {
        _log('[${st.symbol}] ⚠ Open trade on shutdown! Cancelling all orders — close manually on exchange!');
        await _cancelAll(st.symbol);
      }
    }
    await _logSink?.flush();
    await _logSink?.close();
    exit(0);
  });

  await _startup();
  await _runWs();  // runs forever, reconnects automatically on disconnect
}