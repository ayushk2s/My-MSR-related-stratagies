// =============================================================================
// V7 PORTFOLIO SIMULATION — Full 5yr, Compounding, Multi-Asset
// =============================================================================
// V7 #1 frozen config: E15m/T45m/SR15m+30m/SFI5x1.2/px0.8/RR1.0/TP0.70/SL0.20/EMA100
// Tests multiple risk % levels: 2%, 5%, 10%, 15%, 20% of balance per trade
//
// V7 accounting is CLEAN (no realizedPnl accumulator, no double-counting).
// TP1 credits netEq once. Runner/SL credits netEq once. Each portion counted ONCE.
//
// Run: dart MSR/v7_portfolio_sim.dart   (from BOTS/ root)
// =============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';


// ─── FROZEN V7 CONFIG ────────────────────────────────────────────────────────

const _entryTf  = 15;
const _trendTf  = 45;
const _srMask   = 3;    // _B15 | _B30
const _sfiP     = 5;
const _sfiM     = 1.2;
const _proxPct  = 0.8;
const _minRR    = 1.0;
const _vol      = false;
const _tpSplit  = 0.70;
const _slBuf    = 0.20;
const _emaPeriod = 100;

// ─── COSTS (Aster Shield) ────────────────────────────────────────────────────

const _commission = 0.0;
const _slippage   = 0.02;    // 0.04% RT
const _funding    = 0.01;
const _leverage   = 5;
const _cooldown   = 6;
const _atrFb      = 2.0;

const _srl15 = 12;
const _srl30 = 11;
const _srl45 = 10;

const _B15 = 1;
const _B30 = 2;
const _B45 = 4;

// ─── INDICATORS (from v7r3) ──────────────────────────────────────────────────

class SfiSig {
  final double up, dn; final int trend; final bool buy, sell;
  const SfiSig(this.up, this.dn, this.trend, this.buy, this.sell);
}

List<SfiSig> _sfi(List<Candle> cs, int p, double m) {
  final tr = <double>[]; for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high-cs[i].low, max((cs[i].high-prev).abs(), (cs[i].low-prev).abs())));
  }
  final atr = <double>[]; double sum = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { sum += tr[i]; atr.add(sum/(i+1)); } else { atr.add((atr[i-1]*(p-1)+tr[i])/p); }
  }
  double pUp = cs[0].ohlc4 - m*atr[0], pDn = cs[0].ohlc4 + m*atr[0]; int prevT = 1;
  final out = <SfiSig>[];
  for (int i = 0; i < cs.length; i++) {
    final a = atr[i];
    final up = i>0 ? (cs[i-1].close>pUp ? max(cs[i].ohlc4-m*a,pUp) : cs[i].ohlc4-m*a) : cs[i].ohlc4-m*a;
    final dn = i>0 ? (cs[i-1].close<pDn ? min(cs[i].ohlc4+m*a,pDn) : cs[i].ohlc4+m*a) : cs[i].ohlc4+m*a;
    int t = prevT;
    if (prevT==-1 && cs[i].close>pDn) t=1; else if (prevT==1 && cs[i].close<pUp) t=-1;
    out.add(SfiSig(up,dn,t,prevT==-1&&t==1,prevT==1&&t==-1)); pUp=up; pDn=dn; prevT=t;
  }
  return out;
}

List<double> _atrList(List<Candle> cs, int p) {
  final tr = <double>[]; for (int i = 0; i < cs.length; i++) {
    final prev = i == 0 ? cs[0].close : cs[i-1].close;
    tr.add(max(cs[i].high-cs[i].low, max((cs[i].high-prev).abs(), (cs[i].low-prev).abs())));
  }
  final atr = <double>[]; double s = 0;
  for (int i = 0; i < tr.length; i++) {
    if (i < p) { s += tr[i]; atr.add(s/(i+1)); } else { atr.add((atr[i-1]*(p-1)+tr[i])/p); }
  }
  return atr;
}

List<double> _volSma(List<Candle> cs, int p) {
  final out = <double>[]; double s = 0;
  for (int i = 0; i < cs.length; i++) {
    s += cs[i].volume; if (i >= p) s -= cs[i-p].volume;
    out.add(s / (i < p ? i + 1 : p));
  }
  return out;
}

List<double> _emaList(List<Candle> cs, int p) {
  final out = <double>[]; final mul = 2.0/(p+1); double ema = cs[0].close;
  for (int i = 0; i < cs.length; i++) { ema = cs[i].close*mul + ema*(1-mul); out.add(ema); }
  return out;
}

// ─── SR HELPERS ──────────────────────────────────────────────────────────────

List<int?> computeBreakBars(List<SRZone> zones, List<Candle> cs, int len) {
  final out = List<int?>.filled(zones.length, null);
  for (int zi = 0; zi < zones.length; zi++) {
    final z = zones[zi]; final from = z.boxLeft + len;
    for (int b = from; b < cs.length; b++) {
      if (z.isResistance) { if (cs[b].close > z.boxTop) { out[zi] = b; break; } }
      else { if (cs[b].close < z.boxBottom) { out[zi] = b; break; } }
    }
  }
  return out;
}

List<SRZone> _knSup(List<SRZone> z, List<int?> bb, int bar, int len) =>
    [for (int i = 0; i < z.length; i++)
      if (!z[i].isResistance && z[i].boxLeft+len <= bar && (bb[i]==null||bb[i]!>bar)) z[i]];
List<SRZone> _knRes(List<SRZone> z, List<int?> bb, int bar, int len) =>
    [for (int i = 0; i < z.length; i++)
      if (z[i].isResistance && z[i].boxLeft+len <= bar && (bb[i]==null||bb[i]!>bar)) z[i]];

SRZone? _nSup(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) { if (s.boxTop >= p*1.005) continue; final d = p-s.boxTop; if (d<bd) { bd=d; best=s; } }
  return best;
}
SRZone? _nRes(List<SRZone> z, double p) {
  SRZone? best; double bd = double.infinity;
  for (final s in z) { if (s.boxBottom < p*0.995) continue; final d = s.boxBottom-p; if (d<bd) { bd=d; best=s; } }
  return best;
}
bool _near(SRZone z, double p, double pct) {
  final b = p*pct/100; return p >= z.boxBottom-b && p <= z.boxTop+b;
}

// ─── DATA ────────────────────────────────────────────────────────────────────

List<Candle> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync(); final out = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(','); if (p.length < 6) continue;
    final ts = int.tryParse(p[0]); if (ts == null) continue;
    out.add(Candle(DateTime.fromMillisecondsSinceEpoch(ts*1000, isUtc: true),
        double.parse(p[1]),double.parse(p[2]),double.parse(p[3]),double.parse(p[4]),double.parse(p[5]),out.length));
  }
  return out;
}

List<Candle> _clean(List<Candle> raw) {
  final out = <Candle>[]; for (final c in raw) { if (c.volume <= 0) continue;
    out.add(Candle(c.time,c.open,c.high,c.low,c.close,c.volume,out.length)); }
  return out;
}

List<Candle> _agg(List<Candle> c, int n) {
  final out = <Candle>[]; for (int i = 0; i+n-1 < c.length; i += n) {
    double hi=c[i].high,lo=c[i].low,vol=0;
    for (int j = 0; j < n; j++) { hi=max(hi,c[i+j].high); lo=min(lo,c[i+j].low); vol+=c[i+j].volume; }
    out.add(Candle(c[i].time,c[i].open,hi,lo,c[i+n-1].close,vol,out.length));
  }
  return out;
}

// ─── TRADE ───────────────────────────────────────────────────────────────────

class PTrade {
  final String sym;
  final int dir;
  final double entry, tp1, notional;
  double sl;
  bool tp1Hit = false;
  double tp1Pnl = 0;  // PnL from TP1 close (already credited to balance)
  double fee = 0, slp = 0, fund = 0;
  DateTime lastFund;
  PTrade({required this.sym, required this.dir, required this.entry,
    required this.tp1, required this.sl, required this.notional,
    required DateTime entryTime}) : lastFund = entryTime;
}

// ─── EVENT ───────────────────────────────────────────────────────────────────

class Event implements Comparable<Event> {
  final int ai, barIdx;
  final DateTime time;
  Event(this.ai, this.barIdx, this.time);
  @override int compareTo(Event o) => time.compareTo(o.time);
}

// ─── ASSET DATA ──────────────────────────────────────────────────────────────

class AD {
  final String sym;
  final List<Candle> c5, c15, c30, c45, c60;
  final List<SfiSig> sfi15, sfi45;
  final List<double> atr5, volSma5;
  final List<double> ema45_100;
  final List<SRZone> z15, z30;
  final List<int?> bb15, bb30;
  final List<int> m5to15, m5to30, m5to45, m5to60;
  final Set<int> gapBars;
  AD({required this.sym, required this.c5, required this.c15, required this.c30,
    required this.c45, required this.c60, required this.sfi15, required this.sfi45,
    required this.atr5, required this.volSma5, required this.ema45_100,
    required this.z15, required this.z30, required this.bb15, required this.bb30,
    required this.m5to15, required this.m5to30, required this.m5to45, required this.m5to60,
    required this.gapBars});
}

AD _loadAsset(String sym, String p5, {String? p15}) {
  final c5 = _clean(_loadCsv(p5));
  late final List<Candle> c15, c30, c45;
  if (p15 != null && File(p15).existsSync()) {
    c15 = _clean(_loadCsv(p15)); c30 = _agg(c15,2); c45 = _agg(c15,3);
  } else { c15 = _agg(c5,3); c30 = _agg(c5,6); c45 = _agg(c5,9); }
  final c60 = _agg(c5, 12);

  final sfi15 = _sfi(c15, _sfiP, _sfiM);
  final sfi45 = _sfi(c45, _sfiP, _sfiM);

  List<SRZone> zones(List<Candle> cs, int len) {
    final sr = SupportResistanceIndicator(detectionLength: len, srMargin: 2.0, avoidFBO: true, checkHist: false);
    final r = sr.calculate(cs); return [...r.support, ...r.resistance];
  }
  final z15 = zones(c15, _srl15); final z30 = zones(c30, _srl30);

  final m5to15=List<int>.filled(c5.length,0); final m5to30=List<int>.filled(c5.length,0);
  final m5to45=List<int>.filled(c5.length,0); final m5to60=List<int>.filled(c5.length,0);
  int cur15=0,cur30=0,cur45=0,cur60=0;
  for (int i = 0; i < c5.length; i++) {
    final t = c5[i].time;
    while (cur15+1<c15.length && !c15[cur15+1].time.isAfter(t)) cur15++;
    while (cur30+1<c30.length && !c30[cur30+1].time.isAfter(t)) cur30++;
    while (cur45+1<c45.length && !c45[cur45+1].time.isAfter(t)) cur45++;
    while (cur60+1<c60.length && !c60[cur60+1].time.isAfter(t)) cur60++;
    m5to15[i]=cur15; m5to30[i]=cur30; m5to45[i]=cur45; m5to60[i]=cur60;
  }

  final gapBars = <int>{}; for (int i=1;i<c5.length;i++) {
    if (c5[i].time.difference(c5[i-1].time).inMinutes > 15) gapBars.add(i); }

  return AD(sym:sym, c5:c5, c15:c15, c30:c30, c45:c45, c60:c60,
    sfi15:sfi15, sfi45:sfi45, atr5:_atrList(c5,14), volSma5:_volSma(c5,20),
    ema45_100:_emaList(c45,100), z15:z15, z30:z30,
    bb15:computeBreakBars(z15,c15,_srl15), bb30:computeBreakBars(z30,c30,_srl30),
    m5to15:m5to15, m5to30:m5to30, m5to45:m5to45, m5to60:m5to60, gapBars:gapBars);
}

// ─── RUN ONE RISK LEVEL ──────────────────────────────────────────────────────

({double finalBal, double maxDdPct, int trades, int wins, double cagr,
  List<(DateTime, double)> curve, Map<String, double> assetPnl,
  int maxConcurrent, double avgConcurrent, Map<String, int> assetTrades,
  Map<String, int> assetWins, double avgWin, double avgLoss,
  List<double> tradeResults, double maxNotionalPct})
_runSim(List<AD> assets, List<String> syms, double startBal, double riskPct) {

  // Build timeline
  final events = <Event>[];
  for (int ai = 0; ai < assets.length; ai++) {
    for (int bi = 1; bi < assets[ai].c5.length; bi++) {
      events.add(Event(ai, bi, assets[ai].c5[bi].time));
    }
  }
  events.sort();

  double balance = startBal, peak = startBal, maxDd = 0, maxDdPct = 0;
  int totalTrades = 0, totalWins = 0;
  final openTrades = <PTrade>[];
  final cooldowns = List<int>.filled(assets.length, 0);
  final pendDirs = List<int?>.filled(assets.length, null);
  final assetPnl = <String, double>{for (final s in syms) s: 0.0};
  final assetTrades = <String, int>{for (final s in syms) s: 0};
  final assetWins = <String, int>{for (final s in syms) s: 0};
  final curve = <(DateTime, double)>[];
  DateTime lastSnap = DateTime(2000);

  // Tracking concurrent positions + trade sizes
  int maxConcurrent = 0;
  int concurrentSamples = 0;
  double concurrentSum = 0;
  double maxNotionalPct = 0;  // max total notional / balance at any point
  final tradeResults = <double>[];  // each trade's net PnL

  for (final ev in events) {
    final ai = ev.ai; final i = ev.barIdx; final d = assets[ai];
    final c = d.c5[i]; final i15 = d.m5to15[i]; final i45 = d.m5to45[i];
    if (cooldowns[ai] > 0) cooldowns[ai]--;

    final hasPos = openTrades.any((t) => t.sym == d.sym);

    // Gap
    if (d.gapBars.contains(i)) {
      pendDirs[ai] = null;
      for (final t in openTrades.where((t) => t.sym == d.sym).toList()) {
        final prevC = d.c5[i-1].close;
        final rem = t.tp1Hit ? (1-_tpSplit) : 1.0;
        final gp = t.dir==1 ? (prevC-t.entry)/t.entry*t.notional*rem : (t.entry-prevC)/t.entry*t.notional*rem;
        final cost = t.notional*rem*(_commission+_slippage)/100*2;
        final net = gp - cost - t.fund;
        balance += net;
        final totalNet = t.tp1Pnl + net;
        if (totalNet > 0) totalWins++;
        totalTrades++; assetTrades[d.sym] = assetTrades[d.sym]! + 1;
        if (totalNet > 0) { assetWins[d.sym] = assetWins[d.sym]! + 1; }
        assetPnl[d.sym] = assetPnl[d.sym]! + totalNet;
        tradeResults.add(totalNet);
        openTrades.remove(t);
      }
      cooldowns[ai] = _cooldown; continue;
    }

    // Funding
    for (final t in openTrades.where((t) => t.sym == d.sym)) {
      if (c.time.difference(t.lastFund).inHours >= 8) {
        t.lastFund = c.time;
        final rem = t.tp1Hit ? (1-_tpSplit) : 1.0;
        t.fund += t.notional * rem * _funding / 100;
      }
    }

    // Fill pending
    if (!hasPos && pendDirs[ai] != null && cooldowns[ai] == 0) {
      final dir = pendDirs[ai]!; pendDirs[ai] = null;
      final fill = c.open; final atr = d.atr5[i];

      // Get zones
      final sup = <SRZone>[]; final res = <SRZone>[];
      sup.addAll(_knSup(d.z15, d.bb15, i15, _srl15));
      sup.addAll(_knSup(d.z30, d.bb30, d.m5to30[i], _srl30));
      res.addAll(_knRes(d.z15, d.bb15, i15, _srl15));
      res.addAll(_knRes(d.z30, d.bb30, d.m5to30[i], _srl30));

      final ns = _nSup(sup, fill); final nr = _nRes(res, fill);
      double slP, tp1P;
      if (dir==1) {
        slP = ns!=null ? ns.boxBottom*(1-_slBuf/100) : fill-_atrFb*atr;
        tp1P = nr!=null ? nr.boxBottom : fill+_atrFb*atr;
      } else {
        slP = nr!=null ? nr.boxTop*(1+_slBuf/100) : fill+_atrFb*atr;
        tp1P = ns!=null ? ns.boxTop : fill-_atrFb*atr;
      }

      final validL = dir==1 && tp1P>fill && fill>slP;
      final validS = dir==-1 && tp1P<fill && fill<slP;
      bool rrOk = true;
      if (_minRR > 0 && (validL||validS)) {
        rrOk = (fill-slP).abs() > 0 && (tp1P-fill).abs()/(fill-slP).abs() >= _minRR;
      }

      if ((validL||validS) && rrOk && openTrades.length < 9) {
        final notional = balance * riskPct * _leverage;
        if (notional > 10) {  // minimum trade size
          openTrades.add(PTrade(sym:d.sym, dir:dir, entry:fill, tp1:tp1P, sl:slP,
            notional:notional, entryTime:c.time));
        }
      }
    }

    // Exit logic
    for (final t in openTrades.where((t) => t.sym == d.sym).toList()) {
      final sp = _tpSplit;
      final tpH = t.dir==1 ? c.high>=t.tp1 : c.low<=t.tp1;
      final slH = t.dir==1 ? c.low<=t.sl : c.high>=t.sl;

      if (slH) {
        final rem = t.tp1Hit ? (1-sp) : 1.0;
        final gp = t.dir==1 ? (t.sl-t.entry)/t.entry*t.notional*rem : (t.entry-t.sl)/t.entry*t.notional*rem;
        final cost = t.notional*rem*(_commission+_slippage)/100*2;
        final net = gp - cost - t.fund;
        balance += net;
        final totalNet = t.tp1Pnl + net;
        if (totalNet > 0) { totalWins++; assetWins[d.sym] = assetWins[d.sym]! + 1; }
        totalTrades++; assetTrades[d.sym] = assetTrades[d.sym]! + 1;
        assetPnl[d.sym] = assetPnl[d.sym]! + totalNet;
        tradeResults.add(totalNet);
        openTrades.remove(t);
        if (!t.tp1Hit) cooldowns[ai] = _cooldown;

      } else if (!t.tp1Hit && tpH) {
        if (sp >= 1.0) {
          // 100% close
          final gp = t.dir==1 ? (t.tp1-t.entry)/t.entry*t.notional : (t.entry-t.tp1)/t.entry*t.notional;
          final cost = t.notional*(_commission+_slippage)/100*2;
          final net = gp - cost - t.fund;
          balance += net;
          if (net > 0) { totalWins++; assetWins[d.sym] = assetWins[d.sym]! + 1; }
          totalTrades++; assetTrades[d.sym] = assetTrades[d.sym]! + 1;
          assetPnl[d.sym] = assetPnl[d.sym]! + net;
          tradeResults.add(net);
          openTrades.remove(t);
        } else {
          // Partial close — credit TP1 portion to balance
          t.tp1Hit = true;
          final gp70 = t.dir==1 ? (t.tp1-t.entry)/t.entry*t.notional*sp : (t.entry-t.tp1)/t.entry*t.notional*sp;
          final cost70 = t.notional*sp*(_commission+_slippage)/100*2;
          t.tp1Pnl = gp70 - cost70;
          balance += t.tp1Pnl;
          t.sl = t.entry;  // breakeven
        }

      } else if (t.tp1Hit) {
        // Runner — check SFI reversal on 15m
        final isLast = (i+1 >= d.c5.length) || (d.m5to15[i+1] != i15);
        if (isLast && i15 > 0 && i15 < d.sfi15.length) {
          final reversed = t.dir==1 ? d.sfi15[i15-1].sell : d.sfi15[i15-1].buy;
          if (reversed) {
            final rem = 1-sp;
            final gp30 = t.dir==1 ? (c.close-t.entry)/t.entry*t.notional*rem : (t.entry-c.close)/t.entry*t.notional*rem;
            final cost30 = t.notional*rem*(_commission+_slippage)/100*2;
            final net = gp30 - cost30 - t.fund;
            balance += net;
            final totalNet = t.tp1Pnl + net;
            if (totalNet > 0) { totalWins++; assetWins[d.sym] = assetWins[d.sym]! + 1; }
            totalTrades++; assetTrades[d.sym] = assetTrades[d.sym]! + 1;
            assetPnl[d.sym] = assetPnl[d.sym]! + totalNet;
            tradeResults.add(totalNet);
            openTrades.remove(t);
          }
        }
      }
    }

    // Drawdown
    double equity = balance;
    for (final t in openTrades) {
      final aIdx = syms.indexOf(t.sym);
      final price = assets[aIdx].c5[min(i, assets[aIdx].c5.length-1)].close;
      final rem = t.tp1Hit ? (1-_tpSplit) : 1.0;
      equity += t.dir==1 ? (price-t.entry)/t.entry*t.notional*rem : (t.entry-price)/t.entry*t.notional*rem;
    }
    if (equity > peak) peak = equity;
    final dd = peak - equity;
    if (dd > maxDd) maxDd = dd;
    final ddP = peak > 0 ? dd/peak*100 : 0.0;
    if (ddP > maxDdPct) maxDdPct = ddP;

    // Track concurrent positions
    if (openTrades.isNotEmpty) {
      final nc = openTrades.length;
      if (nc > maxConcurrent) maxConcurrent = nc;
      concurrentSum += nc;
      concurrentSamples++;
      // Track total notional exposure as % of balance
      final totalNot = openTrades.fold(0.0, (s, t) => s + t.notional * (t.tp1Hit ? (1-_tpSplit) : 1.0));
      final notPct = balance > 0 ? totalNot / balance * 100 : 0.0;
      if (notPct > maxNotionalPct) maxNotionalPct = notPct;
    }

    // Snapshot daily
    if (c.time.difference(lastSnap).inHours >= 24) {
      lastSnap = c.time; curve.add((c.time, equity));
    }

    // Signal detection
    if (!hasPos && pendDirs[ai] == null && cooldowns[ai] == 0) {
      // 15m SFI flip detection (on last 5m bar of 15m candle)
      final isLast = (i+1 >= d.c5.length) || (d.m5to15[i+1] != i15);
      if (isLast && i15 < d.sfi15.length) {
        bool buyFlip = d.sfi15[i15].buy;
        bool sellFlip = d.sfi15[i15].sell;

        // 45m trend filter
        if (i45 > 0 && i45 < d.sfi45.length) {
          final trend = d.sfi45[i45-1].trend;
          if (trend < 0) buyFlip = false;
          if (trend > 0) sellFlip = false;
        }

        // EMA filter
        if (i45 > 0 && i45 < d.ema45_100.length) {
          final emaVal = d.ema45_100[i45-1];
          if (buyFlip && c.close < emaVal) buyFlip = false;
          if (sellFlip && c.close > emaVal) sellFlip = false;
        }

        // SR proximity
        if (buyFlip || sellFlip) {
          final sup = <SRZone>[]; final res = <SRZone>[];
          sup.addAll(_knSup(d.z15, d.bb15, i15, _srl15));
          sup.addAll(_knSup(d.z30, d.bb30, d.m5to30[i], _srl30));
          res.addAll(_knRes(d.z15, d.bb15, i15, _srl15));
          res.addAll(_knRes(d.z30, d.bb30, d.m5to30[i], _srl30));

          if (buyFlip) {
            final ns = _nSup(sup, c.close);
            if (ns == null || !_near(ns, c.close, _proxPct)) buyFlip = false;
          }
          if (sellFlip) {
            final nr = _nRes(res, c.close);
            if (nr == null || !_near(nr, c.close, _proxPct)) sellFlip = false;
          }
        }

        if (buyFlip) pendDirs[ai] = 1;
        if (sellFlip) pendDirs[ai] = -1;
      }
    }
  }

  // Force close
  for (final t in openTrades) {
    final ai = syms.indexOf(t.sym); final d = assets[ai];
    final rem = t.tp1Hit ? (1-_tpSplit) : 1.0;
    final ep = d.c5.last.close;
    final gp = t.dir==1 ? (ep-t.entry)/t.entry*t.notional*rem : (t.entry-ep)/t.entry*t.notional*rem;
    final cost = t.notional*rem*(_commission+_slippage)/100*2;
    final net = gp - cost - t.fund;
    balance += net;
    final totalNet = t.tp1Pnl + net;
    totalTrades++; assetTrades[t.sym] = assetTrades[t.sym]! + 1;
    if (totalNet > 0) { totalWins++; assetWins[t.sym] = assetWins[t.sym]! + 1; }
    assetPnl[t.sym] = assetPnl[t.sym]! + totalNet;
    tradeResults.add(totalNet);
  }

  final years = events.isNotEmpty ? events.last.time.difference(events.first.time).inDays / 365.25 : 1.0;
  final cagr = (pow(balance / startBal, 1.0 / years) - 1) * 100;
  final avgConc = concurrentSamples > 0 ? concurrentSum / concurrentSamples : 0.0;

  // Compute avg win / avg loss
  final winTrades = tradeResults.where((r) => r > 0).toList();
  final lossTrades = tradeResults.where((r) => r <= 0).toList();
  final avgW = winTrades.isNotEmpty ? winTrades.fold(0.0, (s, r) => s + r) / winTrades.length : 0.0;
  final avgL = lossTrades.isNotEmpty ? lossTrades.fold(0.0, (s, r) => s + r) / lossTrades.length : 0.0;

  return (finalBal: balance, maxDdPct: maxDdPct, trades: totalTrades,
    wins: totalWins, cagr: cagr.toDouble(), curve: curve, assetPnl: assetPnl,
    maxConcurrent: maxConcurrent, avgConcurrent: avgConc,
    assetTrades: assetTrades, assetWins: assetWins,
    avgWin: avgW, avgLoss: avgL, tradeResults: tradeResults,
    maxNotionalPct: maxNotionalPct);
}

// ─── MAIN ────────────────────────────────────────────────────────────────────

void main() {
  final startTime = DateTime.now();
  const base = '/Users/ayush/Desktop/candlestick data';
  final syms = ['BCHUSDT','BNBUSDT','BTCUSDT','DOGEUSDT','ETCUSDT','ETHUSDT','LINKUSDT','SOLUSDT','XRPUSDT'];
  final symNames = ['BCH','BNB','BTC','DOGE','ETC','ETH','LINK','SOL','XRP'];

  print('=' * 100);
  print(' V7 PORTFOLIO SIMULATION — Compounding Test');
  print(' Strategy: E15m/T45m/SR15m+30m/SFI5x1.2/px0.8/RR1.0/TP0.70/SL0.20/EMA100');
  print(' Fees: Aster Shield (0.04% RT)');
  print('=' * 100);

  // Load assets
  final assets = <AD>[];
  for (int ai = 0; ai < symNames.length; ai++) {
    final sym = symNames[ai];
    stdout.write('  Loading ${sym}USDT...');
    final p5 = '$base/5m/${sym}USDT5m.csv';
    final p15 = '$base/15m${sym}USDT15m.csv';
    assets.add(_loadAsset(syms[ai], p5, p15: p15));
    print(' ${assets.last.c5.length} bars');
  }
  print('  Loaded in ${DateTime.now().difference(startTime).inSeconds}s\n');

  // Test multiple risk levels
  const startBal = 1000.0;
  const riskLevels = [0.02, 0.05, 0.10, 0.15, 0.20];

  print('  ${"Risk%".padRight(8)} | ${"Final".padLeft(12)} | ${"Return".padLeft(10)} | ${"CAGR".padLeft(8)} | ${"MaxDD".padLeft(8)} | ${"Trades".padLeft(7)} | ${"WR%".padLeft(6)}');
  print('  ' + '-' * 75);

  for (final risk in riskLevels) {
    final r = _runSim(assets, syms, startBal, risk);
    final retPct = (r.finalBal - startBal) / startBal * 100;
    final wr = r.trades > 0 ? r.wins / r.trades * 100 : 0.0;
    print('  ${(risk*100).toStringAsFixed(0).padLeft(3)}%     |'
          ' \$${r.finalBal.toStringAsFixed(2).padLeft(11)} |'
          ' ${retPct >= 0 ? "+" : ""}${retPct.toStringAsFixed(1).padLeft(8)}% |'
          ' ${r.cagr >= 0 ? "+" : ""}${r.cagr.toStringAsFixed(1).padLeft(6)}% |'
          ' ${r.maxDdPct.toStringAsFixed(1).padLeft(6)}% |'
          ' ${r.trades.toString().padLeft(6)} |'
          ' ${wr.toStringAsFixed(1).padLeft(5)}%');
  }

  // Show detailed result for 10% risk
  print('\n');
  _hdr('DETAILED RESULTS — 10% Risk Per Trade');
  final best = _runSim(assets, syms, startBal, 0.10);
  final retPctB = (best.finalBal - startBal) / startBal * 100;
  final wrB = best.trades > 0 ? best.wins / best.trades * 100 : 0.0;

  print('  Starting balance   : \$${startBal.toStringAsFixed(2)}');
  print('  Final balance      : \$${best.finalBal.toStringAsFixed(2)}');
  print('  Total return       : ${retPctB >= 0 ? "+" : ""}${retPctB.toStringAsFixed(1)}%');
  print('  CAGR               : ${best.cagr >= 0 ? "+" : ""}${best.cagr.toStringAsFixed(1)}%');
  print('  Max drawdown       : ${best.maxDdPct.toStringAsFixed(1)}%');
  print('  Calmar ratio       : ${best.maxDdPct > 0 ? (best.cagr / best.maxDdPct).toStringAsFixed(2) : "N/A"}');
  print('  Total trades       : ${best.trades}');
  print('  Win rate           : ${wrB.toStringAsFixed(1)}%');
  print('  Avg win            : \$${best.avgWin.toStringAsFixed(2)}');
  print('  Avg loss           : \$${best.avgLoss.toStringAsFixed(2)}');
  print('  Payoff ratio       : ${best.avgLoss != 0 ? (best.avgWin / best.avgLoss.abs()).toStringAsFixed(2) : "N/A"}x');
  print('  Edge per trade     : \$${(best.finalBal - startBal) > 0 ? ((best.finalBal - startBal) / best.trades).toStringAsFixed(2) : "0.00"}');

  print('\n  POSITION EXPOSURE:');
  print('  Max concurrent     : ${best.maxConcurrent} positions');
  print('  Avg concurrent     : ${best.avgConcurrent.toStringAsFixed(2)} positions');
  print('  Max notional/bal   : ${best.maxNotionalPct.toStringAsFixed(1)}% of balance');
  print('  Risk per trade     : 10% of balance x ${_leverage}x = ${10*_leverage}% notional');
  print('  Worst case (${best.maxConcurrent} open): ${best.maxConcurrent * 10 * _leverage}% notional');

  print('\n  PER-ASSET BREAKDOWN:');
  print('  ${"Asset".padRight(12)} | ${"Trades".padLeft(7)} | ${"WR%".padLeft(6)} | ${"PnL".padLeft(12)}');
  print('  ' + '-' * 45);
  for (final sym in syms) {
    final tr = best.assetTrades[sym] ?? 0;
    final w = best.assetWins[sym] ?? 0;
    final wr = tr > 0 ? (w/tr*100).toStringAsFixed(1) : '0.0';
    final pnl = best.assetPnl[sym] ?? 0.0;
    print('  ${sym.padRight(12)} | ${tr.toString().padLeft(7)} | ${wr.padLeft(5)}% | ${pnl >= 0 ? "+" : ""}\$${pnl.toStringAsFixed(2).padLeft(10)}');
  }

  print('\n  EQUITY CURVE:');
  print('  ${"Date".padRight(12)} | ${"Balance".padLeft(12)} | Growth');
  print('  ' + '-' * 40);
  final step = max(1, best.curve.length ~/ 20);
  for (int i = 0; i < best.curve.length; i += step) {
    final (date, eq) = best.curve[i];
    final growth = (eq / startBal * 100 - 100);
    print('  ${date.toString().substring(0,10)} | \$${eq.toStringAsFixed(2).padLeft(11)} | ${growth >= 0 ? "+" : ""}${growth.toStringAsFixed(1)}%');
  }
  if (best.curve.isNotEmpty) {
    final (date, eq) = best.curve.last;
    final growth = (eq / startBal * 100 - 100);
    print('  ${date.toString().substring(0,10)} | \$${eq.toStringAsFixed(2).padLeft(11)} | ${growth >= 0 ? "+" : ""}${growth.toStringAsFixed(1)}%  <- final');
  }

  // Longest winning/losing streaks
  int curStreak = 0, maxWinStreak = 0, maxLoseStreak = 0;
  bool lastWin = false;
  for (final r in best.tradeResults) {
    if (r > 0) {
      curStreak = lastWin ? curStreak + 1 : 1;
      lastWin = true;
      if (curStreak > maxWinStreak) maxWinStreak = curStreak;
    } else {
      curStreak = !lastWin ? curStreak + 1 : 1;
      lastWin = false;
      if (curStreak > maxLoseStreak) maxLoseStreak = curStreak;
    }
  }
  print('\n  STREAKS:');
  print('  Longest win streak  : $maxWinStreak trades');
  print('  Longest lose streak : $maxLoseStreak trades');

  // Biggest single trade
  if (best.tradeResults.isNotEmpty) {
    final bestTrade = best.tradeResults.reduce(max);
    final worstTrade = best.tradeResults.reduce(min);
    print('\n  EXTREMES:');
    print('  Best single trade   : +\$${bestTrade.toStringAsFixed(2)}');
    print('  Worst single trade  : \$${worstTrade.toStringAsFixed(2)}');
  }

  print('\n  Runtime: ${DateTime.now().difference(startTime).inSeconds}s');
}

void _hdr(String t) {
  const w = 100; final p = max(0, (w - t.length - 2) ~/ 2);
  print('=' * p + ' $t ' + '=' * max(0, w - p - t.length - 2));
}
