// =============================================================================
// B07 LIVE TRADING BOT  —  Exact port of B07 backtest (WF-validated)
// =============================================================================
// Strategy : E15m / T45m / SR(15m+30m) / SFI(7,1.5) / prox1.0% /
//            RR≥1.0 / TP0.60 / SL0.20%buf / NO EMA filter / 6-bar cooldown
// Assets   : BCH BNB BTC DOGE ETC ETH LINK SOL XRP (all 9 from backtest)
// Validated: B07 WF — DEPLOY-READY
//            Full 5yr CAGR +31.5% | Train70 +29.1% | OOS30 +37.0%
//            MaxDD 11.6% | OOS Calmar 3.18 | 5/5 years profitable
//            4/4 WF folds profitable | 8/9 assets positive
//            Supersedes C07. Sweep winner robustly validated.
// =============================================================================

import 'dart:async';
import 'dart:math';

import 'model.dart';
import 'support_resistance_2.dart';
import 'msr_asterdex/fetch_candle_data.dart';
import 'msr_asterdex/account_data.dart';
import 'msr_asterdex/aster_recursive_trade_function.dart';

// ─── FROZEN B07 CONFIG (do NOT change — these are the WF-validated params) ───
// B07/SFI(7,1.5)/px1.0/TP0.60/SL0.20/EMAno — deploy-ready sweep winner

const _sfiPeriod  = 7;     // ← B07 (was 5)
const _sfiMult    = 1.5;   // ← B07 (was 1.2)
const _srl15      = 12;    // SR detection length for 15m zones
const _srl30      = 11;    // SR detection length for 30m zones
const _proxPct    = 1.0;   // ← B07 (was 0.8) SR proximity tolerance (%)
const _minRR      = 1.0;   // minimum reward:risk to take a trade
const _tpSplit    = 0.60;  // ← B07 (was 0.70) 60% closed at TP1, 40% runner
const _slBufPct   = 0.20;  // SL placed this % beyond zone edge
const _atrFbMult  = 2.0;   // ATR fallback when no SR zone found
const _useEmaFilter = false; // ← B07: EMAno (filter DISABLED)
const _cooldownN  = 6;     // cooldown in 5m bars after a full SL (no TP1 hit)
const _leverage   = 5;     // exchange leverage

// ─── SFI SIGNAL ──────────────────────────────────────────────────────────────

class _SfiSig {
  final double up, dn;
  final int    trend;   // +1 or -1
  final bool   buy, sell;
  const _SfiSig(this.up, this.dn, this.trend, this.buy, this.sell);
}

// ─── INDICATORS  (identical math to backtest helpers) ────────────────────────

/// Supertrend-style SFI — exact copy of backtest `_sfi()`
List<_SfiSig> _computeSfi(List<Candle> cs, int p, double m) {
  if (cs.length < 2) return [];
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[]; double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  double pUp = cs[0].ohlc4 - m * atr[0];
  double pDn = cs[0].ohlc4 + m * atr[0];
  int prevT  = 1;
  final out  = <_SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a  = atr[i];
    final up = i > 0
        ? (cs[i-1].close > pUp ? max(cs[i].ohlc4 - m*a, pUp) : cs[i].ohlc4 - m*a)
        : cs[i].ohlc4 - m*a;
    final dn = i > 0
        ? (cs[i-1].close < pDn ? min(cs[i].ohlc4 + m*a, pDn) : cs[i].ohlc4 + m*a)
        : cs[i].ohlc4 + m*a;
    int t = prevT;
    if      (prevT == -1 && cs[i].close > pDn) t =  1;
    else if (prevT ==  1 && cs[i].close < pUp) t = -1;
    out.add(_SfiSig(up, dn, t, prevT == -1 && t == 1, prevT == 1 && t == -1));
    pUp = up; pDn = dn; prevT = t;
  }
  return out;
}

/// ATR — exact copy of backtest `_atrList()`
List<double> _computeAtr(List<Candle> cs, int p) {
  final tr = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i - 1].close;
    tr.add(max(cs[i].high - cs[i].low,
               max((cs[i].high - prev).abs(), (cs[i].low - prev).abs())));
  }
  final atr = <double>[]; double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s / (i + 1)); }
    else        { atr.add((atr[i - 1] * (p - 1) + tr[i]) / p); }
  }
  return atr;
}

// ─── CANDLE AGGREGATION  (exact copy of backtest `_agg()`) ───────────────────

List<Candle> _agg(List<Candle> src, int n) {
  final clean = src.where((c) => c.volume > 0).toList();
  final out   = <Candle>[];
  for (int i = 0; i + n - 1 < clean.length; i += n) {
    double hi = clean[i].high, lo = clean[i].low, vol = 0;
    for (int j = 0; j < n; j++) {
      hi  = max(hi, clean[i + j].high);
      lo  = min(lo, clean[i + j].low);
      vol += clean[i + j].volume;
    }
    out.add(Candle(clean[i].time, clean[i].open, hi, lo,
                   clean[i + n - 1].close, vol, out.length));
  }
  return out;
}

// ─── SR HELPERS  (exact port of backtest helpers) ────────────────────────────

/// Known (un-broken) supports at `barIdx`
List<SRZone> _knSup(List<SRZone> zones, List<Candle> cs, int detLen, int barIdx) {
  return zones.where((z) {
    if (z.isResistance) return false;
    if (z.boxLeft + detLen > barIdx) return false;
    for (int b = z.boxLeft + detLen; b <= barIdx && b < cs.length; b++) {
      if (cs[b].close < z.boxBottom) return false; // broken
    }
    return true;
  }).toList();
}

/// Known (un-broken) resistances at `barIdx`
List<SRZone> _knRes(List<SRZone> zones, List<Candle> cs, int detLen, int barIdx) {
  return zones.where((z) {
    if (!z.isResistance) return false;
    if (z.boxLeft + detLen > barIdx) return false;
    for (int b = z.boxLeft + detLen; b <= barIdx && b < cs.length; b++) {
      if (cs[b].close > z.boxTop) return false; // broken
    }
    return true;
  }).toList();
}

/// Nearest support BELOW `price` (zone.boxTop < price×1.005)
SRZone? _nSup(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxTop >= price * 1.005) continue;
    final d = price - z.boxTop;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

/// Nearest resistance ABOVE `price` (zone.boxBottom > price×0.995)
SRZone? _nRes(List<SRZone> zones, double price) {
  SRZone? best; double bd = double.infinity;
  for (final z in zones) {
    if (z.boxBottom < price * 0.995) continue;
    final d = z.boxBottom - price;
    if (d < bd) { bd = d; best = z; }
  }
  return best;
}

/// Is `price` within `pct`% of zone?  — exact copy of backtest `_near()`
bool _nearZone(SRZone z, double price, double pct) {
  final buf = price * pct / 100;
  return price >= z.boxBottom - buf && price <= z.boxTop + buf;
}

// ─── TRADE STATE ─────────────────────────────────────────────────────────────

class _B07Trade {
  final int    id;
  final int    dir;       // +1 long, -1 short
  final double entry;
  final double tp1;
  double       sl;        // starts at SR-based SL; moves to entry after TP1
  final double notional;  // total leveraged notional (used for PnL calc)
  final double totalQty;  // qty on exchange at open
  double       remainQty; // qty still open (after partial TP1 close)
  bool         tp1Hit  = false;
  double       tp1Pnl  = 0;   // gross PnL credited when 70% closed at TP1

  _B07Trade({
    required this.id, required this.dir, required this.entry,
    required this.tp1, required this.sl,
    required this.notional, required this.totalQty,
  }) : remainQty = totalQty;
}

// ─── B07 BOT ─────────────────────────────────────────────────────────────────

class B07Bot {
  // ── Credentials & symbol ──
  final String apiKey, secretKey, symbol;

  // ── Sizing ──
  /// Fraction of balance per trade (e.g. 0.10 = 10%, same as backtest 10% run)
  final double riskFraction;
  int _qtyPrecision;

  // ── Per-bot state ──
  _B07Trade? _trade;
  int?      _pendingDir;          // +1 or -1, set at signal bar
  int       _cooldownLeft = 0;    // 5m bars remaining (6 × 5m = 30 min cooldown)
  int       _pendingAge   = 0;    // ticks since pending was set (auto-expire safety)

  // ── 15m bar tracking ──
  // We detect new completed 15m bars by watching c15.last.time
  DateTime? _last15mTime;

  // ── Stats ──
  int    _tradeId = 0;
  double _sessionPnl = 0;
  int    _nTrades = 0, _nWins = 0;

  bool   _running = false;
  Timer? _timer;

  B07Bot({
    required this.apiKey,
    required this.secretKey,
    required this.symbol,
    this.riskFraction = 0.10,     // 10% matches backtest "detailed results" run
    int quantityPrecision = 3,
  }) : _qtyPrecision = quantityPrecision;

  // ── Public API ──────────────────────────────────────────────────────────────

  void start() {
    if (_running) return;
    _running = true;
    print(_banner());
    _setup();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    print('[$symbol] stopped.');
  }

  // ── Setup: leverage + alignment ─────────────────────────────────────────────

  Future<void> _setup() async {
    try {
      await AsterdexFutureFunctions.setLeverage(symbol, _leverage, apiKey, secretKey);
      print('[$symbol] Leverage → ${_leverage}x');
    } catch (e) { print('[$symbol] WARNING leverage: $e'); }

    try {
      _qtyPrecision = await AsterdexFutureFunctions.getQuantityPrecision(symbol);
      print('[$symbol] Qty precision → $_qtyPrecision dp');
    } catch (e) { print('[$symbol] qty precision fallback ($_qtyPrecision dp): $e'); }

    // Align to next 5m candle boundary
    final now    = DateTime.now();
    final secMod = (now.minute * 60 + now.second) % 300;
    final waitS  = (300 - secMod + 2).clamp(2, 302);
    print('[$symbol] Waiting ${waitS}s to align to 5m boundary…');
    await Future.delayed(Duration(seconds: waitS));
    if (!_running) return;

    await _tick();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _tick());
  }

  // ── Main tick (runs every 5m after alignment) ────────────────────────────────

  Future<void> _tick() async {
    if (!_running) return;
    try {
      // ① Fetch 5m raw candles from exchange
      final c5 = await fetchBinanceCandles(
          symbol: symbol, interval: '5m', limit: 600);
      if (c5.length < 60) { print('[$symbol] Too few candles (${c5.length})'); return; }

      // ② Aggregate to required timeframes  (exact same as backtest _agg)
      //    5m × 3  = 15m   (entry SFI + SR zones)
      //    15m × 2 = 30m   (SR zones only)
      //    5m × 9  = 45m   (trend SFI)
      final c15 = _agg(c5,  3);
      final c30 = _agg(c15, 2);
      final c45 = _agg(c5,  9);

      if (c15.length < 30 || c45.length < 15) {
        print('[$symbol] Insufficient aggregated bars'); return;
      }

      // ③ Compute all indicators on COMPLETED bars
      //    NOTE: B07 disables EMA filter — no EMA computed.
      final sfi15List = _computeSfi(c15, _sfiPeriod, _sfiMult);
      final sfi45List = _computeSfi(c45, _sfiPeriod, _sfiMult);
      final atr5List  = _computeAtr(c5,  14);

      final i15 = c15.length - 1;
      final i45 = c45.length - 1;
      final i30 = c30.length - 1;

      // Latest signals (most recently COMPLETED bar of each TF)
      final sfi15Cur  = sfi15List[i15];              // current 15m bar
      final sfi15Prev = i15 > 0 ? sfi15List[i15-1] : sfi15Cur; // previous 15m bar
      final sfi45Cur  = sfi45List[i45];
      final atr5      = atr5List.last;
      final curBar    = c5.last;
      final price     = curBar.close;

      // ④ SR zones — 15m (detLen=12) and 30m (detLen=11)
      final z15all = _srZones(c15, _srl15);
      final z30all = _srZones(c30, _srl30);

      final allSup = [
        ..._knSup(z15all, c15, _srl15, i15),
        ..._knSup(z30all, c30, _srl30, i30),
      ];
      final allRes = [
        ..._knRes(z15all, c15, _srl15, i15),
        ..._knRes(z30all, c30, _srl30, i30),
      ];

      // ⑤ Detect whether a new completed 15m bar appeared since last tick
      final cur15mTime = c15[i15].time;
      final isNew15m   = (_last15mTime == null || cur15mTime != _last15mTime);

      // Log tick
      print('[$symbol] ${_ts(curBar.time)}'
            ' P=${price.toStringAsFixed(4)}'
            ' SFI15=${sfi15Cur.trend > 0 ? "+1" : "-1"}'
            '${sfi15Cur.buy ? "▲" : sfi15Cur.sell ? "▼" : ""}'
            ' SFI45=${sfi45Cur.trend > 0 ? "+1" : "-1"}'
            ' S=${allSup.length} R=${allRes.length}'
            ' cd=$_cooldownLeft'
            '${isNew15m ? " [NEW-15m]" : ""}');

      // ⑥ Cooldown counter — decrement every 5m tick (6 ticks = 30 min)
      if (_cooldownLeft > 0) _cooldownLeft--;

      // ⑦ STEP A: Fill any pending entry from a previous tick
      //    (backtest fills pending at the NEXT 5m bar after signal — bar i+1)
      if (_trade == null && _pendingDir != null && _cooldownLeft == 0) {
        _pendingAge++;
        if (_pendingAge > 6) {
          // Safety: auto-expire pending after 6 ticks (30 min) without fill
          print('[$symbol] Pending expired after $_pendingAge ticks — cancelled');
          _pendingDir = null;
          _pendingAge = 0;
        } else {
          await _fillPending(curBar, atr5, allSup, allRes);
        }
      }

      // ⑧ STEP B: Manage open trade (TP1, SL, runner)
      if (_trade != null) {
        await _manageTrade(
          _trade!, curBar, sfi15Cur, sfi15Prev, isNew15m,
        );
      }

      // ⑨ STEP C: Signal detection on new 15m bar (backtest: isLast 5m of 15m)
      if (isNew15m) {
        _last15mTime = cur15mTime;
        if (_trade == null && _pendingDir == null && _cooldownLeft == 0) {
          _detectSignal(
            sfi15Cur, sfi45Cur, price, allSup, allRes,
          );
        }
      }

      _printStatus(price);

    } catch (e, st) {
      print('[$symbol] TICK ERROR: $e\n$st');
    }
  }

  // ─── Signal Detection ───────────────────────────────────────────────────────
  //
  // B07 port of backtest "Signal detection" block:
  //   1. SFI(7,1.5) on 15m — detect buy/sell flip
  //   2. 45m SFI trend filter (bearish blocks buy, bullish blocks sell)
  //   3. SR proximity 1.0%   (must be near a known S or R zone)
  //   NOTE: B07 has NO EMA filter (EMAno). Trend is filtered by 45m SFI only.

  void _detectSignal(
    _SfiSig sfi15, _SfiSig sfi45,
    double price, List<SRZone> allSup, List<SRZone> allRes,
  ) {
    bool buyFlip  = sfi15.buy;
    bool sellFlip = sfi15.sell;
    if (!buyFlip && !sellFlip) return;

    // Filter 1 — 45m trend
    if (buyFlip  && sfi45.trend < 0) {
      print('[$symbol]   BUY blocked: 45m SFI bearish'); buyFlip = false;
    }
    if (sellFlip && sfi45.trend > 0) {
      print('[$symbol]   SELL blocked: 45m SFI bullish'); sellFlip = false;
    }
    if (!buyFlip && !sellFlip) return;

    // (EMA filter intentionally omitted — B07 = EMAno)

    // Filter 2 — SR proximity (1.0%)
    if (buyFlip) {
      final ns = _nSup(allSup, price);
      if (ns == null || !_nearZone(ns, price, _proxPct)) {
        print('[$symbol]   BUY blocked: no support within $_proxPct% '
              '(nearest=${ns?.boxTop.toStringAsFixed(4) ?? "none"})');
        buyFlip = false;
      }
    }
    if (sellFlip) {
      final nr = _nRes(allRes, price);
      if (nr == null || !_nearZone(nr, price, _proxPct)) {
        print('[$symbol]   SELL blocked: no resistance within $_proxPct% '
              '(nearest=${nr?.boxBottom.toStringAsFixed(4) ?? "none"})');
        sellFlip = false;
      }
    }

    if (buyFlip) {
      _pendingDir = 1;
      _pendingAge = 0;
      print('[$symbol] ▲ BUY SIGNAL — pending LONG entry on next bar');
    } else if (sellFlip) {
      _pendingDir = -1;
      _pendingAge = 0;
      print('[$symbol] ▼ SELL SIGNAL — pending SHORT entry on next bar');
    }
  }

  // ─── Fill Pending Entry ──────────────────────────────────────────────────────
  //
  // Exact port of backtest "Fill pending" block:
  //   - Fill at current bar's OPEN (next bar after signal)
  //   - SL  = nearest SR zone edge ± slBufPct (ATR×2 fallback)
  //   - TP1 = nearest SR zone on opposite side (ATR×2 fallback)
  //   - Validate direction: TP1 must be on the right side of entry
  //   - RR check: (TP1-entry) / (entry-SL) ≥ minRR

  Future<void> _fillPending(
    Candle bar, double atr, List<SRZone> allSup, List<SRZone> allRes,
  ) async {
    final dir  = _pendingDir!;
    _pendingDir = null;
    _pendingAge = 0;

    final fill = bar.open;  // fill at next-bar open, same as backtest

    final ns = _nSup(allSup, fill);
    final nr = _nRes(allRes, fill);

    final double slP, tp1P;
    if (dir == 1) {
      // LONG: SL = nearest support bottom - buf%, TP1 = nearest resistance bottom
      slP  = ns != null
          ? ns.boxBottom * (1 - _slBufPct / 100)
          : fill - _atrFbMult * atr;
      tp1P = nr != null ? nr.boxBottom : fill + _atrFbMult * atr;
    } else {
      // SHORT: SL = nearest resistance top + buf%, TP1 = nearest support top
      slP  = nr != null
          ? nr.boxTop * (1 + _slBufPct / 100)
          : fill + _atrFbMult * atr;
      tp1P = ns != null ? ns.boxTop : fill - _atrFbMult * atr;
    }

    // Validate (TP1 and SL must bracket entry correctly)
    final valid = dir == 1
        ? (tp1P > fill && fill > slP)
        : (tp1P < fill && fill < slP);
    if (!valid) {
      print('[$symbol]   Invalid levels — skipping'
            ' (dir=$dir fill=${fill.toStringAsFixed(4)}'
            ' tp1=${tp1P.toStringAsFixed(4)} sl=${slP.toStringAsFixed(4)})');
      return;
    }

    // RR check
    final rr = (tp1P - fill).abs() / (fill - slP).abs();
    if (rr < _minRR) {
      print('[$symbol]   RR ${rr.toStringAsFixed(2)} < $_minRR — skipping');
      return;
    }

    // Position sizing: notional = balance × riskFraction × leverage
    double balance;
    try {
      balance = await AsterdexFutureFunctions.getAvailableBalance(apiKey, secretKey);
    } catch (e) { print('[$symbol]   Cannot fetch balance: $e'); return; }

    final notional = balance * riskFraction * _leverage;
    if (notional < 10) {
      print('[$symbol]   Notional \$${notional.toStringAsFixed(2)} too small — skipping');
      return;
    }

    final qty = _roundQty(notional / fill);
    if (qty <= 0) { print('[$symbol]   Qty rounds to 0 — skipping'); return; }

    // Place market order
    try {
      final side    = dir == 1 ? 'BUY'  : 'SELL';
      final posSide = dir == 1 ? 'LONG' : 'SHORT';

      await AsterRecursiveTradeFunction.tradeLimit(
        symbol:       symbol,
        side:         side,
        positionSide: posSide,
        vol:          qty,
        leverage:     _leverage,
      );

      _tradeId++;
      _trade = _B07Trade(
        id: _tradeId, dir: dir, entry: fill,
        tp1: tp1P, sl: slP, notional: notional, totalQty: qty,
      );

      final dirStr = dir == 1 ? 'LONG' : 'SHORT';
      print('[$symbol] ✅ TRADE #$_tradeId $dirStr'
            ' @ ${fill.toStringAsFixed(4)}'
            ' qty=$qty notional=\$${notional.toStringAsFixed(2)}'
            ' TP1=${tp1P.toStringAsFixed(4)}'
            ' SL=${slP.toStringAsFixed(4)}'
            ' RR=${rr.toStringAsFixed(2)}');

    } catch (e) { print('[$symbol] ❌ Order failed: $e'); }
  }

  // ─── Manage Open Trade ───────────────────────────────────────────────────────
  //
  // Exact port of backtest "Exit logic" block.
  //
  // Priority (checked in this order each 5m bar):
  //   1. SL hit → close all remaining, 6-bar cooldown if no TP1 hit
  //   2. TP1 hit (if not yet) → close 70%, move SL to breakeven (entry)
  //   3. Runner exit → check SFI(15m)[i15-1] reversal on new 15m bar close
  //
  // NOTE on runner: backtest checks sfi15[i15-1].sell (PREVIOUS 15m bar),
  //   not the current bar. In live we pass sfi15Prev (second-to-last 15m bar)
  //   to exactly replicate that one-bar lag.

  Future<void> _manageTrade(
    _B07Trade t, Candle bar,
    _SfiSig sfi15Cur, _SfiSig sfi15Prev,
    bool isNew15m,
  ) async {
    // ─ SL check (every 5m bar) ─
    final slHit = t.dir == 1 ? bar.low <= t.sl : bar.high >= t.sl;
    if (slHit) {
      final rem   = t.tp1Hit ? (1 - _tpSplit) : 1.0;
      final gross = t.dir == 1
          ? (t.sl - t.entry) / t.entry * t.notional * rem
          : (t.entry - t.sl) / t.entry * t.notional * rem;
      final net = t.tp1Pnl + gross;
      final lbl = t.tp1Hit ? 'RUNNER SL (breakeven)' : 'FULL SL';

      print('[$symbol] 🛑 #${t.id} $lbl @ ${t.sl.toStringAsFixed(4)}'
            '  net=${_pnl(net)}');

      _sessionPnl += net;
      _nTrades++;
      if (net > 0) _nWins++;

      await _closeRemaining(t, lbl);
      _trade = null;
      // 6-bar (30 min) cooldown only after a FULL SL (TP1 not yet hit)
      if (!t.tp1Hit) _cooldownLeft = _cooldownN;
      return;
    }

    // ─ TP1 check (70% close, every 5m bar) ─
    if (!t.tp1Hit) {
      final tp1Hit = t.dir == 1 ? bar.high >= t.tp1 : bar.low <= t.tp1;
      if (tp1Hit) {
        final closeQty = _roundQty(t.totalQty * _tpSplit);
        final gross70  = t.dir == 1
            ? (t.tp1 - t.entry) / t.entry * t.notional * _tpSplit
            : (t.entry - t.tp1) / t.entry * t.notional * _tpSplit;

        t.tp1Hit    = true;
        t.tp1Pnl    = gross70;
        t.remainQty = _roundQty(t.totalQty * (1 - _tpSplit));
        t.sl        = t.entry;   // ← move SL to breakeven

        print('[$symbol] 🎯 #${t.id} TP1 @ ${t.tp1.toStringAsFixed(4)}'
              '  closed ${(_tpSplit*100).toInt()}% qty=$closeQty'
              '  pnl=+\$${gross70.toStringAsFixed(2)}'
              '  → SL MOVED TO BREAKEVEN ${t.entry.toStringAsFixed(4)}');

        try {
          final side    = t.dir == 1 ? 'SELL' : 'BUY';
          final posSide = t.dir == 1 ? 'LONG' : 'SHORT';
          await AsterRecursiveTradeFunction.exitPartialTrade(
            symbol: symbol, side: side,
            positionSide: posSide, vol: closeQty,
          );
        } catch (e) { print('[$symbol] TP1 close failed: $e'); }
        return; // done this tick
      }
    }

    // ─ Runner exit: SFI(15m) reversal on 15m bar close ─
    // Backtest: checks sfi15[i15-1].sell on LAST 5m of bar i15.
    // In live: isNew15m fires when bar i15 completes; we check sfi15Prev
    // (the bar just BEFORE the latest completed bar, i.e. i15-1).
    if (t.tp1Hit && isNew15m) {
      final reversed = t.dir == 1 ? sfi15Prev.sell : sfi15Prev.buy;
      if (reversed) {
        final rem   = 1 - _tpSplit;
        final gross = t.dir == 1
            ? (bar.close - t.entry) / t.entry * t.notional * rem
            : (t.entry - bar.close) / t.entry * t.notional * rem;
        final net = t.tp1Pnl + gross;

        print('[$symbol] 🏃 #${t.id} RUNNER EXIT (SFI reversal)'
              ' @ ${bar.close.toStringAsFixed(4)}'
              '  net=${_pnl(net)}');

        _sessionPnl += net;
        _nTrades++;
        if (net > 0) _nWins++;

        await _closeRemaining(t, 'RUNNER_SFI');
        _trade = null;
      }
    }
  }

  // ─── Exchange Close ───────────────────────────────────────────────────────

  Future<void> _closeRemaining(_B07Trade t, String reason) async {
    try {
      final side    = t.dir == 1 ? 'SELL' : 'BUY';
      final posSide = t.dir == 1 ? 'LONG' : 'SHORT';
      final qty     = t.tp1Hit ? t.remainQty : t.totalQty;
      await AsterRecursiveTradeFunction.exitPartialTrade(
        symbol: symbol, side: side, positionSide: posSide, vol: qty,
      );
      print('[$symbol] ✅ Closed #${t.id} qty=$qty ($reason)');
    } catch (e) { print('[$symbol] ❌ Close #${t.id} failed: $e'); }
  }

  // ─── SR Zone Computation ──────────────────────────────────────────────────

  List<SRZone> _srZones(List<Candle> cs, int detLen) {
    final sr = SupportResistanceIndicator(
      detectionLength: detLen,
      srMargin:        2.0,
      avoidFBO:        true,
      checkHist:       false,
    ).calculate(cs);
    return [...sr.support, ...sr.resistance];
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  double _roundQty(double qty) {
    final f = pow(10, _qtyPrecision).toDouble();
    return (qty * f).floorToDouble() / f;
  }

  String _pnl(double v) => '${v >= 0 ? "+" : ""}\$${v.toStringAsFixed(2)}';
  String _ts(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${_p(l.month)}-${_p(l.day)} ${_p(l.hour)}:${_p(l.minute)}';
  }
  String _p(int n) => n.toString().padLeft(2, '0');

  void _printStatus(double price) {
    final wr  = _nTrades > 0 ? (_nWins / _nTrades * 100).toStringAsFixed(1) : '0.0';
    final pnl = _pnl(_sessionPnl);
    if (_trade != null) {
      final t   = _trade!;
      final rem = t.tp1Hit ? (1 - _tpSplit) : 1.0;
      final up  = t.dir == 1
          ? (price - t.entry) / t.entry * t.notional * rem
          : (t.entry - price) / t.entry * t.notional * rem;
      print('[$symbol] 📊 PnL=$pnl trades=$_nTrades WR=$wr%  '
            '| OPEN #${t.id} ${t.dir == 1 ? "LONG" : "SHORT"}'
            ' entry=${t.entry.toStringAsFixed(4)}'
            ' tp1=${t.tp1.toStringAsFixed(4)}'
            ' sl=${t.sl.toStringAsFixed(4)}'
            ' tp1Hit=${t.tp1Hit}'
            ' uPnL=${_pnl(up)}');
    } else {
      print('[$symbol] 📊 PnL=$pnl trades=$_nTrades WR=$wr%  '
            '| no position  cd=$_cooldownLeft  pending=$_pendingDir');
    }
  }

  String _banner() => '''
╔══════════════════════════════════════════════════════════════════╗
║  B07 LIVE BOT  [$symbol]  (WF-validated, DEPLOY-READY)
║  Entry   : 15m SFI($_sfiPeriod,$_sfiMult) flip
║  Trend   : 45m SFI trend  (NO EMA filter — B07/EMAno)
║  SR      : 15m(len=$_srl15) + 30m(len=$_srl30), prox ${_proxPct}%
║  TP Split: ${(_tpSplit*100).toInt()}% at TP1 → runner exits on 15m SFI reversal
║  SL      : SR zone edge ± ${_slBufPct}% buf  |  ATR×$_atrFbMult fallback
║  RR      : ≥ $_minRR  |  Cooldown: $_cooldownN × 5m after full SL
║  Size    : ${(riskFraction*100).toStringAsFixed(0)}% balance × ${_leverage}x = ${(riskFraction*100*_leverage).toStringAsFixed(0)}% notional
╚══════════════════════════════════════════════════════════════════╝''';
}

// =============================================================================
// MAIN  —  All 9 B07-validated assets
// =============================================================================

Future<void> main() async {
  // ── Replace with your real credentials ──
  const apiKey    = 'YOUR_API_KEY_HERE';
  const secretKey = 'YOUR_SECRET_KEY_HERE';

  // B07 backtest assets — all 9 from the WF validation sweep.
  // BNB is the lone negative (-$61) per OOS; all 8 others were profitable.
  // Tuple: (symbol, qty decimal precision)
  final assets = <(String, int)>[
    ('BCHUSDT',  2),  // BCH  typically 2 dp
    ('BNBUSDT',  2),  // BNB
    ('BTCUSDT',  3),  // BTC
    ('DOGEUSDT', 0),  // DOGE whole units
    ('ETCUSDT',  2),  // ETC
    ('ETHUSDT',  3),  // ETH
    ('LINKUSDT', 2),  // LINK
    ('SOLUSDT',  2),  // SOL
    ('XRPUSDT',  1),  // XRP
  ];

  // Risk fraction — matches the "10% risk" detailed results in the backtest.
  // Adjust down (e.g. 0.02–0.05) if you want lower drawdown.
  const riskFraction = 0.10;

final bots = assets.map((asset) => B07Bot(
  apiKey: apiKey,
  secretKey: secretKey,
  symbol: asset.$1,
  riskFraction: riskFraction,
  quantityPrecision: asset.$2,
)).toList();

  // Stagger starts 3 s apart to avoid rate-limit bursts
  for (final bot in bots) {
    bot.start();
    await Future.delayed(const Duration(seconds: 3));
  }

  print('\n[MAIN] ${bots.length} B07 bots running'
        ' (${assets.map((a) => a.$1).join(", ")})'
        '  riskFraction=$riskFraction × ${_leverage}x'
        '  Press Ctrl+C to stop.\n');

  // Keep process alive
  await Completer<void>().future;
}