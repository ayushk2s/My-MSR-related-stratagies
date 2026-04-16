// ============================================================================
// SR ZONE BREAKOUT STRATEGY — VERSION 7
// ============================================================================
// WHY BREAKOUT INSTEAD OF BOUNCE (lessons from v5/v6):
//   Bounce WR was only 30% → need 33%+ to profit → not enough margin
//   SOLUSDT 2024-2025 is a TRENDING market → zones break more than they hold
//   Trending markets reward breakout/momentum traders, punish mean-reversion
//
// BREAKOUT LOGIC:
//   LONG : exec candle closes ABOVE resistance (close > chanTop + minBreakPct%)
//          → measured move target = chanTop + channel_width
//          → SL (tight) = chanTop × (1 - slBuf%)   [just below broken level]
//          → SL (wide)  = chanBot × (1 - slBuf%)   [below entire channel]
//          → fill at NEXT bar's open (Fix 2: no snooping)
//
//   SHORT: exec candle closes BELOW support (close < chanBot - minBreakPct%)
//          → measured move target = chanBot - channel_width
//          → SL (tight) = chanBot × (1 + slBuf%)
//          → SL (wide)  = chanTop × (1 + slBuf%)
//          → fill at NEXT bar's open
//
// MATH WHY THIS WORKS:
//   Channel width typically 2-5% of price
//   Tight SL buffer 0.3% → R:R = 2%/0.3% = 6.7:1
//   Break-even WR at 6.7:1 = 1/7.7 = 13%
//   Typical breakout WR = 25-40% → comfortable margin after costs
//
// ALL V5 REALISM FIXES:
//   Fix 1: zones[bar-1] — trade on CLOSED bars only
//   Fix 2: fill at NEXT bar's open
//   Fix 3: same-bar TP+SL → SL wins
//   Fix 4: funding 0.01%/8h
//   Fix 5: blended commission 0.025%
//   Fix 6: vol SMA from previous bars
//   Fix 7: zero-vol + gap candle removal
//
// EXTRA GUARDS:
//   • maxChaseSlippage: skip entry if next open is already X% past signal level
//     (prevents chasing a candle that has already run far from breakout point)
//   • SFI filter: LONG only in uptrend, SHORT only in downtrend (optional)
//   • Min channel width: skip if zone too narrow to give good R:R
//   • Cooldown after SL: don't re-enter same direction immediately
// ============================================================================

import 'dart:io';
import 'dart:math';

import '../model.dart';
import '../support_resistance_2.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class BreakConfig {
  final String label;
  final String symbol;
  final String csv15m, csvExec, execLabel;
  final int    htfMultiplier;

  final double commissionPct;
  final double slippagePct;
  final double fundingRatePct;
  final int    fundingIntervalHrs;

  final double baseNotionalUSDT;
  final double leverage;

  final double slBufferPct;        // % buffer for SL
  final bool   tightSL;            // true = SL just below broken level; false = SL below entire channel
  final bool   sfiFilter;          // only trade in SFI trend direction
  final double minBreakoutPct;     // close must be this % above/below chanTop/chanBot to signal
  final double maxChasePct;        // skip entry if next open is this % past signal level (chasing)
  final int    cooldownBars;       // exec bars to wait after SL before re-entry
  final int    maxHoldBars;        // force-exit after N exec bars (0 = unlimited)
  final double minChannelWidthPct; // skip if channel < this %

  final int    srDetectionLength;
  final double srMargin;
  final int    sfiPeriod;
  final double sfiMultiplier;
  final int    execIntervalMinutes;

  const BreakConfig({
    required this.label,
    required this.symbol,
    required this.csv15m,
    required this.csvExec,
    this.execLabel           = '5m',
    this.htfMultiplier       = 3,
    this.commissionPct       = 0.025,
    this.slippagePct         = 0.04,
    this.fundingRatePct      = 0.01,
    this.fundingIntervalHrs  = 8,
    this.baseNotionalUSDT    = 20.0,
    this.leverage            = 5.0,
    this.slBufferPct         = 0.3,
    this.tightSL             = true,
    this.sfiFilter           = true,
    this.minBreakoutPct      = 0.0,
    this.maxChasePct         = 0.5,
    this.cooldownBars        = 5,
    this.maxHoldBars         = 0,
    this.minChannelWidthPct  = 1.0,
    this.srDetectionLength   = 10,
    this.srMargin            = 2.0,
    this.sfiPeriod           = 10,
    this.sfiMultiplier       = 1.7,
    this.execIntervalMinutes = 5,
  });

  String get htfLabel {
    final m = 15 * htfMultiplier;
    return m < 60 ? '${m}m' : '${m ~/ 60}h';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULT
// ─────────────────────────────────────────────────────────────────────────────

class BreakResult {
  final BreakConfig config;
  final int    totalTrades, wins, losses;
  final int    tpExits, slExits, sameBarSl, maxHoldExits, skippedChase;
  final double grossPnl, totalFees, totalSlippage, totalFunding, netPnl;
  final double maxDdPct, returnPct, calmar, pf;
  final double avgRR, avgHoldMins;
  final String grade;

  BreakResult({
    required this.config,
    required this.totalTrades, required this.wins, required this.losses,
    required this.tpExits, required this.slExits,
    required this.sameBarSl, required this.maxHoldExits, required this.skippedChase,
    required this.grossPnl, required this.totalFees,
    required this.totalSlippage, required this.totalFunding,
    required this.netPnl, required this.maxDdPct,
    required this.returnPct, required this.calmar,
    required this.pf, required this.avgRR, required this.avgHoldMins,
    required this.grade,
  });

  double get winRate => totalTrades == 0 ? 0 : wins / totalTrades * 100;
}

// ─────────────────────────────────────────────────────────────────────────────
// INTERNALS
// ─────────────────────────────────────────────────────────────────────────────

class _BarZones {
  final List<SRZone> activeR, activeS;
  final int sfiTrend;
  _BarZones(this.activeR, this.activeS, this.sfiTrend);
}

enum _Dir { long, short }

class _Trade {
  final int      id;
  final _Dir     dir;
  final double   entryPrice, qty, notionalUSDT;
  final double   tpPrice, slPrice, plannedRR;
  final DateTime entryTime;
  final int      entryBarIdx;
  double         fundingPaid = 0.0;
  bool           isOpen      = true;
  double         exitPrice   = 0;
  DateTime?      exitTime;
  String         exitReason  = '';

  _Trade({
    required this.id, required this.dir,
    required this.entryPrice, required this.qty, required this.notionalUSDT,
    required this.tpPrice, required this.slPrice, required this.plannedRR,
    required this.entryTime, required this.entryBarIdx,
  });

  double grossPnl() {
    if (exitPrice == 0) return 0;
    return dir == _Dir.long
        ? (exitPrice - entryPrice) * qty
        : (entryPrice - exitPrice) * qty;
  }

  double fees(BreakConfig c)     => notionalUSDT * c.leverage * c.commissionPct / 100 * 2;
  double slippage(BreakConfig c) => notionalUSDT * c.leverage * c.slippagePct / 100 * 2;
}

class _Pending {
  final _Dir   dir;
  final double signalLevel; // chanTop for LONG, chanBot for SHORT
  final double tpPrice, slPrice, plannedRR;
  final double notional;
  _Pending({
    required this.dir, required this.signalLevel,
    required this.tpPrice, required this.slPrice,
    required this.plannedRR, required this.notional,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SFI
// ─────────────────────────────────────────────────────────────────────────────

class _SfiInd {
  int trend(List<Candle> cs, int period, double mult) {
    final tr  = <double>[];
    for (int i = 0; i < cs.length; i++) {
      final p = i == 0 ? cs[i].close : cs[i-1].close;
      tr.add([cs[i].high-cs[i].low, (cs[i].high-p).abs(), (cs[i].low-p).abs()].reduce(max));
    }
    final atr = <double>[];
    for (int i = 0; i < tr.length; i++) {
      if (i == 0) { atr.add(tr[0]); }
      else if (i < period) { atr.add((atr[i-1]*(i)+tr[i])/(i+1)); }
      else { atr.add((atr[i-1]*(period-1)+tr[i])/period); }
    }
    double pUp = cs[0].ohlc4 - mult*(atr.isNotEmpty ? atr[0] : 0);
    double pDn = cs[0].ohlc4 + mult*(atr.isNotEmpty ? atr[0] : 0);
    int t = 1;
    for (int i = 0; i < cs.length; i++) {
      final a = i < atr.length ? atr[i] : atr.last;
      final up = i>0 ? (cs[i-1].close>pUp ? max(cs[i].ohlc4-mult*a,pUp) : cs[i].ohlc4-mult*a) : cs[i].ohlc4-mult*a;
      final dn = i>0 ? (cs[i-1].close<pDn ? min(cs[i].ohlc4+mult*a,pDn) : cs[i].ohlc4+mult*a) : cs[i].ohlc4+mult*a;
      if (t==-1 && cs[i].close>pDn) t=1;
      else if (t==1 && cs[i].close<pUp) t=-1;
      pUp=up; pDn=dn;
    }
    return t;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<Candle> _loadCsv(String path) {
  final lines = File(path).readAsLinesSync();
  final out = <Candle>[];
  for (int i = 1; i < lines.length; i++) {
    final p = lines[i].split(',');
    if (p.length < 6) continue;
    out.add(Candle(DateTime.parse(p[0]+'Z'),
        double.parse(p[1]), double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4]),
        double.parse(p[5]), i-1));
  }
  return out;
}

List<Candle> _aggregate(List<Candle> c15, int mult) {
  final out = <Candle>[];
  int idx = 0;
  for (int i = 0; i+mult-1 < c15.length; i += mult) {
    double hi=c15[i].high, lo=c15[i].low, vol=0;
    for (int j=0;j<mult;j++) { hi=max(hi,c15[i+j].high); lo=min(lo,c15[i+j].low); vol+=c15[i+j].volume; }
    out.add(Candle(c15[i].time, c15[i].open, hi, lo, c15[i+mult-1].close, vol, idx++));
  }
  return out;
}

List<Candle> _clean(List<Candle> raw, int intervalMin) {
  final out = <Candle>[];
  for (int i = 0; i < raw.length; i++) {
    if (raw[i].volume <= 0) continue;
    if (out.isNotEmpty && raw[i].time.difference(out.last.time).inMinutes > intervalMin*3) continue;
    out.add(raw[i]);
  }
  return out;
}

// Fix 1: zones[i] computed from bars [0..i]; use zones[bar-1] during bar's window
List<_BarZones> _precompute(List<Candle> htf, BreakConfig cfg) {
  final sr  = SupportResistanceIndicator(
      detectionLength: cfg.srDetectionLength, srMargin: cfg.srMargin,
      avoidFBO: true, checkHist: true, showManip: false);
  final sfi = _SfiInd();
  final min = cfg.srDetectionLength * 2 + 20;
  final out = <_BarZones>[];
  for (int i = 0; i < htf.length; i++) {
    if (i < min) { out.add(_BarZones([],[],1)); continue; }
    final sub = htf.sublist(0, i+1);
    final res = sr.calculate(sub);
    out.add(_BarZones(
      res.resistance.where((z)=>z.isActive).toList(),
      res.support.where((z)=>z.isActive).toList(),
      sfi.trend(sub, cfg.sfiPeriod, cfg.sfiMultiplier),
    ));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKTESTER
// ─────────────────────────────────────────────────────────────────────────────

BreakResult runBacktest(BreakConfig cfg, List<_BarZones> zones,
    List<Candle> htf, List<Candle> execRaw) {

  final exec = _clean(execRaw, cfg.execIntervalMinutes);

  final trades      = <_Trade>[];
  int   tradeId     = 0;
  double netEq=0, grossEq=0, totalFee=0, totalSlip=0, totalFund=0;
  double peakEq=0, maxDd=0;
  int    sameBarSlCnt=0, skippedChaseCnt=0;

  _Trade?  active;
  _Pending? pending;
  DateTime lastFunding  = DateTime(2000);
  int longCd=0, shortCd=0;
  int totalBars = 0;

  final volBuf = <double>[];
  const volP = 20;

  for (int bar = 0; bar < htf.length; bar++) {
    // Fix 1: use zones from previous closed bar
    final bz = zones[bar > 0 ? bar-1 : 0];
    if (bz.activeR.isEmpty || bz.activeS.isEmpty) { pending=null; continue; }

    final chanTop = bz.activeR.first.boxBottom;   // top of tradeable channel
    final chanBot = bz.activeS.first.boxTop;      // bottom of tradeable channel
    final slLevelLong  = cfg.tightSL
        ? chanTop * (1 - cfg.slBufferPct/100)     // just below broken resistance
        : chanBot * (1 - cfg.slBufferPct/100);    // below entire channel
    final slLevelShort = cfg.tightSL
        ? chanBot * (1 + cfg.slBufferPct/100)     // just above broken support
        : chanTop * (1 + cfg.slBufferPct/100);    // above entire channel

    if (chanTop <= chanBot) { pending=null; continue; }
    final chanWidth = chanTop - chanBot;
    if (chanWidth / chanBot * 100 < cfg.minChannelWidthPct) { pending=null; continue; }

    final sfiTrend = bz.sfiTrend;

    final winStart = htf[bar].time;
    final winEnd   = bar+1 < htf.length
        ? htf[bar+1].time
        : winStart.add(Duration(minutes: 15*cfg.htfMultiplier));

    final bars = exec.where((c)=>!c.time.isBefore(winStart)&&c.time.isBefore(winEnd)).toList();

    for (int ei = 0; ei < bars.length; ei++) {
      final c    = bars[ei];
      final barN = totalBars + ei;

      // ── Fix 2: Fill pending at this bar's OPEN ──────────────────────────
      if (pending != null && active == null) {
        final pe   = pending!;
        pending    = null;
        final fill = c.open;

        // Anti-chase: skip if price has already run too far past signal level
        final chased = pe.dir == _Dir.long
            ? fill > pe.signalLevel * (1 + cfg.maxChasePct/100)
            : fill < pe.signalLevel * (1 - cfg.maxChasePct/100);

        if (chased) {
          skippedChaseCnt++;
        } else {
          // Validate TP still reachable and SL not already hit
          final tpOk = pe.dir==_Dir.long ? fill < pe.tpPrice : fill > pe.tpPrice;
          final slOk = pe.dir==_Dir.long ? fill > pe.slPrice : fill < pe.slPrice;

          if (tpOk && slOk) {
            final tpD  = (pe.tpPrice - fill).abs();
            final slD  = (fill - pe.slPrice).abs();
            final actRR = slD > 0 ? tpD/slD : 0.0;

            if (actRR >= 1.0) {
              final qty = pe.notional / fill;
              active = _Trade(
                id: tradeId++, dir: pe.dir,
                entryPrice: fill, qty: qty, notionalUSDT: pe.notional,
                tpPrice: pe.tpPrice, slPrice: pe.slPrice,
                plannedRR: actRR, entryTime: c.time, entryBarIdx: barN,
              );
              trades.add(active!);
            }
          }
        }
      }

      // ── Fix 4: Funding every 8h ─────────────────────────────────────────
      if (active != null && active!.isOpen &&
          c.time.difference(lastFunding).inHours >= cfg.fundingIntervalHrs) {
        lastFunding = c.time;
        active!.fundingPaid += active!.notionalUSDT * cfg.leverage * cfg.fundingRatePct/100;
      }

      // ── Fix 3: TP / SL — SL wins if both hit same bar ───────────────────
      if (active != null && active!.isOpen) {
        final t = active!;
        bool tpH=false, slH=false;
        if (t.dir==_Dir.long) { tpH=c.high>=t.tpPrice; slH=c.low<=t.slPrice; }
        else                  { tpH=c.low<=t.tpPrice;  slH=c.high>=t.slPrice; }

        String rsn=''; double at=0; bool closed=false;
        if      (tpH&&slH) { rsn='SL'; at=t.slPrice; closed=true; sameBarSlCnt++; }
        else if (tpH)      { rsn='TP'; at=t.tpPrice; closed=true; }
        else if (slH)      { rsn='SL'; at=t.slPrice; closed=true; }

        if (!closed && cfg.maxHoldBars>0 && barN-t.entryBarIdx>=cfg.maxHoldBars) {
          rsn='MAX_HOLD'; at=c.close; closed=true;
        }

        if (closed) {
          t.isOpen=false; t.exitPrice=at; t.exitTime=c.time; t.exitReason=rsn;
          final gp=t.grossPnl(); final fee=t.fees(cfg); final slip=t.slippage(cfg);
          grossEq+=gp; totalFee+=fee; totalSlip+=slip; totalFund+=t.fundingPaid;
          netEq+=gp-fee-slip-t.fundingPaid;
          if (rsn=='SL'||rsn=='MAX_HOLD') {
            if (t.dir==_Dir.long) longCd=cfg.cooldownBars;
            else shortCd=cfg.cooldownBars;
          }
          active=null;
        }
      }

      // ── Fix 6: Volume SMA from PREVIOUS bars ────────────────────────────
      final volSma = volBuf.length>=volP
          ? volBuf.fold(0.0,(s,v)=>s+v)/volBuf.length : 0.0;
      volBuf.add(c.volume);
      if (volBuf.length>volP) volBuf.removeAt(0);
      final volOk = volBuf.length<volP || c.volume>=volSma*0.7;

      if (longCd>0) longCd--;
      if (shortCd>0) shortCd--;

      // ── New breakout signal ──────────────────────────────────────────────
      if (active==null && pending==null && volOk) {
        // LONG breakout: close above resistance
        final longOk = !cfg.sfiFilter || sfiTrend>=0;
        if (longOk && longCd==0) {
          final broke = c.close > chanTop*(1+cfg.minBreakoutPct/100);
          if (broke) {
            final tp = chanTop + chanWidth;           // measured move
            final sl = slLevelLong;
            final tpD = tp - c.close;
            final slD = c.close - sl;
            final rr  = slD>0 ? tpD/slD : 0.0;
            if (rr>=1.0 && tpD>0 && slD>0) {
              pending = _Pending(
                dir: _Dir.long, signalLevel: chanTop,
                tpPrice: tp, slPrice: sl,
                plannedRR: rr, notional: cfg.baseNotionalUSDT,
              );
            }
          }
        }

        // SHORT breakdown: close below support
        final shortOk = !cfg.sfiFilter || sfiTrend<0;
        if (pending==null && shortOk && shortCd==0) {
          final broke = c.close < chanBot*(1-cfg.minBreakoutPct/100);
          if (broke) {
            final tp = chanBot - chanWidth;           // measured move
            final sl = slLevelShort;
            final tpD = c.close - tp;
            final slD = sl - c.close;
            final rr  = slD>0 ? tpD/slD : 0.0;
            if (rr>=1.0 && tpD>0 && slD>0) {
              pending = _Pending(
                dir: _Dir.short, signalLevel: chanBot,
                tpPrice: tp, slPrice: sl,
                plannedRR: rr, notional: cfg.baseNotionalUSDT,
              );
            }
          }
        }
      }

      // ── Drawdown ─────────────────────────────────────────────────────────
      double openPnl = 0;
      if (active!=null && active!.isOpen) {
        final t=active!;
        final raw = t.dir==_Dir.long
            ? (c.close-t.entryPrice)*t.qty
            : (t.entryPrice-c.close)*t.qty;
        openPnl = raw - t.fees(cfg) - t.slippage(cfg) - t.fundingPaid;
      }
      final cur = netEq+openPnl;
      if (cur>peakEq) peakEq=cur;
      final dd=peakEq-cur;
      if (dd>maxDd) maxDd=dd;
    }
    totalBars += bars.length;
  }

  // Force-close
  if (active!=null && active!.isOpen) {
    final t=active!;
    t.isOpen=false; t.exitPrice=exec.last.close;
    t.exitTime=exec.last.time; t.exitReason='END_OF_DATA';
    final gp=t.grossPnl(); final fee=t.fees(cfg); final slip=t.slippage(cfg);
    grossEq+=gp; totalFee+=fee; totalSlip+=slip; totalFund+=t.fundingPaid;
    netEq+=gp-fee-slip-t.fundingPaid;
  }

  final closed   = trades.where((t)=>t.exitReason.isNotEmpty).toList();
  final wins     = closed.where((t)=>t.grossPnl()>0).length;
  final losses   = closed.length-wins;
  final tpEx     = closed.where((t)=>t.exitReason=='TP').length;
  final slEx     = closed.where((t)=>t.exitReason=='SL').length;
  final mhEx     = closed.where((t)=>t.exitReason=='MAX_HOLD').length;

  final aw = wins>0
      ? closed.where((t)=>t.grossPnl()>0).fold(0.0,(s,t)=>s+t.grossPnl())/wins : 0.0;
  final al = losses>0
      ? closed.where((t)=>t.grossPnl()<=0).fold(0.0,(s,t)=>s+t.grossPnl()).abs()/losses : 0.0;
  final pf = al>0 ? (aw*wins)/(al*losses) : double.infinity;

  final dep     = cfg.baseNotionalUSDT * cfg.leverage;
  final retPct  = dep>0 ? netEq/dep*100 : 0.0;
  final ddPct   = dep>0 ? maxDd/dep*100 : 0.0;
  final calmar  = ddPct.abs()>0 ? retPct/ddPct.abs() : 0.0;

  final avgRR   = closed.isEmpty ? 0.0
      : closed.fold(0.0,(s,t)=>s+t.plannedRR)/closed.length;
  final avgHold = closed.isEmpty ? 0.0
      : closed.fold(0.0,(s,t){
          if (t.exitTime==null) return s;
          return s+t.exitTime!.difference(t.entryTime).inMinutes.toDouble();
        })/closed.length;

  String grade;
  if      (calmar>=5 && retPct>=50 && ddPct<20) grade='A ★★★';
  else if (calmar>=3 && retPct>=30 && ddPct<30) grade='B ★★';
  else if (calmar>=1 && retPct>=10 && ddPct<40) grade='C ★';
  else if (retPct>0)                             grade='D';
  else                                           grade='F ✗';

  return BreakResult(
    config: cfg, totalTrades: closed.length,
    wins: wins, losses: losses,
    tpExits: tpEx, slExits: slEx,
    sameBarSl: sameBarSlCnt, maxHoldExits: mhEx, skippedChase: skippedChaseCnt,
    grossPnl: grossEq, totalFees: totalFee,
    totalSlippage: totalSlip, totalFunding: totalFund,
    netPnl: netEq, maxDdPct: ddPct.abs(),
    returnPct: retPct, calmar: calmar,
    pf: pf, avgRR: avgRR, avgHoldMins: avgHold,
    grade: grade,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// REPORT
// ─────────────────────────────────────────────────────────────────────────────

void printReport(BreakResult r) {
  final c   = r.config;
  final sep = '═' * 74;
  print('\n╔$sep╗');
  print('║  ${r.config.label.padRight(72)}║');
  print('╠$sep╣');
  print('║  HTF:${c.htfLabel.padRight(5)} Exec:${c.execLabel.padRight(4)} '
      'SFI:${c.sfiFilter?"ON ":"OFF"} '
      'SL:${c.tightSL?"tight":"wide "} ${c.slBufferPct}%  '
      'Break≥${c.minBreakoutPct}%  MaxChase:${c.maxChasePct}%  '
      'Cooldown:${c.cooldownBars}bars${' '*5}║');
  print('╠$sep╣');
  print('║  Gross:${_f(r.grossPnl,11)} Fees:${_f(-r.totalFees,9)} '
      'Slip:${_f(-r.totalSlippage,9)} Fund:${_f(-r.totalFunding,8)} '
      'NET:${_f(r.netPnl,10)}║');
  print('╠$sep╣');
  print('║  Trades:${r.totalTrades.toString().padLeft(4)}  '
      'WR:${r.winRate.toStringAsFixed(1).padLeft(5)}%  '
      'TP:${r.tpExits.toString().padLeft(4)}  '
      'SL:${r.slExits.toString().padLeft(4)}  '
      'SameBar→SL:${r.sameBarSl.toString().padLeft(3)}  '
      'MaxHold:${r.maxHoldExits.toString().padLeft(3)}  '
      'SkipChase:${r.skippedChase.toString().padLeft(3)}${' '*4}║');
  print('║  PF:${r.pf.isInfinite?" ∞   ":r.pf.toStringAsFixed(2).padLeft(5)}  '
      'AvgRR:${r.avgRR.toStringAsFixed(1).padLeft(5)}  '
      'AvgHold:${(r.avgHoldMins/60).toStringAsFixed(1).padLeft(5)}h  '
      'Return:${r.returnPct.toStringAsFixed(1).padLeft(7)}%  '
      'DD:${r.maxDdPct.toStringAsFixed(1).padLeft(5)}%  '
      'Calmar:${r.calmar.toStringAsFixed(2).padLeft(6)}${' '*4}║');
  print('║  GRADE: ${r.grade.padRight(65)}║');
  print('╚$sep╝');
}

void printMasterTable(List<BreakResult> results) {
  final sorted = [...results]..sort((a,b)=>b.calmar.compareTo(a.calmar));
  final sep = '═'*116;
  print('\n╔$sep╗');
  print('║${_c('MASTER RANKING — SR ZONE BREAKOUT STRATEGY (v7, BIAS-FREE)', 116)}║');
  print('╠═══╦══════════════════════════════════════════════╦══════╦══════╦════════╦═══════╦═══════╦════════════════╣');
  print('║ # ║ Config                                       ║  WR% ║ AvgRR║  Net\$  ║  DD%  ║  Ret% ║ Calmar  Grade  ║');
  print('╠═══╬══════════════════════════════════════════════╬══════╬══════╬════════╬═══════╬═══════╬════════════════╣');
  for (int i=0;i<sorted.length;i++) {
    final r  = sorted[i];
    final lb = r.config.label.length>45
        ? r.config.label.substring(0,45) : r.config.label.padRight(45);
    final wr  = r.winRate.toStringAsFixed(1).padLeft(5);
    final rr  = r.avgRR.toStringAsFixed(1).padLeft(5);
    final net = _f2(r.netPnl).padLeft(7);
    final dd  = r.maxDdPct.toStringAsFixed(1).padLeft(5);
    final ret = r.returnPct.toStringAsFixed(1).padLeft(6);
    final cal = r.calmar.toStringAsFixed(1).padLeft(6);
    print('║${(i+1).toString().padLeft(3)}║ $lb║$wr%║$rr  ║$net ║$dd%  ║$ret% ║$cal  ${r.grade.padRight(7)}║');
  }
  print('╚═══╩══════════════════════════════════════════════╩══════╩══════╩════════╩═══════╩═══════╩════════════════╝');

  final best = sorted.first;
  print('\n  BEST: ${best.config.label}');
  print('  Net:\$${best.netPnl.toStringAsFixed(2)}  Return:${best.returnPct.toStringAsFixed(1)}%'
      '  Calmar:${best.calmar.toStringAsFixed(2)}  Grade:${best.grade}');
  print('\n  All 7 forward-bias fixes from v5 applied — these numbers are realistic.');
}

String _c(String s, int w) {
  final pad = ((w - s.length) / 2).floor();
  return ' '*pad + s + ' '*(w - s.length - pad);
}
String _f(double v, int w)  => ((v>=0?'+':'')+v.toStringAsFixed(2)).padRight(w);
String _f2(double v) => (v>=0?'+':'')+v.toStringAsFixed(1);

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  const p5m  = '/Users/ayush/Desktop/candlestick data/5m/SOLUSDT5m.csv';
  const p15m = '/Users/ayush/Desktop/candlestick data/15m/SOLUSDT15m.csv';

  print('Loading & cleaning candles...');
  final c15m = _loadCsv(p15m);
  final c5m  = _clean(_loadCsv(p5m), 5);
  print('  15m: ${c15m.length}  5m (clean): ${c5m.length}\n');

  final htf30 = _aggregate(c15m, 2);
  final htf45 = _aggregate(c15m, 3);
  final htf60 = _aggregate(c15m, 4);

  print('Pre-computing zones (Fix 1: zones[bar-1] used at execution time)...');
  final base = BreakConfig(label:'_', symbol:'SOLUSDT', csv15m:p15m, csvExec:p5m);
  final z30  = _precompute(htf30, base);  print('  30m done');
  final z45  = _precompute(htf45, base);  print('  45m done');
  final z60  = _precompute(htf60, base);  print('  60m done\n');

  final htfM = {2:htf30, 3:htf45, 4:htf60};
  final zM   = {2:z30,   3:z45,   4:z60};

  // (label, htfMult, sfi, tightSL, breakPct, maxChase, cooldown, maxHold)
  final matrix = [
    // ─ 30m HTF ─
    ('30m | SFI=ON  | tight SL | break≥0.0%', 2, true,  true,  0.0, 0.5, 5, 0),
    ('30m | SFI=ON  | tight SL | break≥0.1%', 2, true,  true,  0.1, 0.5, 5, 0),
    ('30m | SFI=OFF | tight SL | break≥0.0%', 2, false, true,  0.0, 0.5, 5, 0),
    ('30m | SFI=ON  | wide SL  | break≥0.0%', 2, true,  false, 0.0, 0.5, 5, 0),

    // ─ 45m HTF ─
    ('45m | SFI=ON  | tight SL | break≥0.0%', 3, true,  true,  0.0, 0.5, 5, 0),
    ('45m | SFI=ON  | tight SL | break≥0.1%', 3, true,  true,  0.1, 0.5, 5, 0),
    ('45m | SFI=OFF | tight SL | break≥0.0%', 3, false, true,  0.0, 0.5, 5, 0),
    ('45m | SFI=ON  | wide SL  | break≥0.0%', 3, true,  false, 0.0, 0.5, 5, 0),
    ('45m | SFI=ON  | tight SL | break≥0.2%', 3, true,  true,  0.2, 0.5, 5, 0),
    ('45m | SFI=ON  | tight SL | break≥0.0% | CD=3', 3, true, true, 0.0, 0.5, 3, 0),

    // ─ 60m HTF ─
    ('60m | SFI=ON  | tight SL | break≥0.0%', 4, true,  true,  0.0, 0.5, 5, 0),
    ('60m | SFI=ON  | tight SL | break≥0.1%', 4, true,  true,  0.1, 0.5, 5, 0),
    ('60m | SFI=OFF | tight SL | break≥0.0%', 4, false, true,  0.0, 0.5, 5, 0),
    ('60m | SFI=ON  | wide SL  | break≥0.0%', 4, true,  false, 0.0, 0.5, 5, 0),
  ];

  final results = <BreakResult>[];

  for (final (lbl, htm, sfi, tight, brk, chase, cd, mh) in matrix) {
    final cfg = BreakConfig(
      label: lbl, symbol: 'SOLUSDT', csv15m: p15m, csvExec: p5m,
      execLabel: '5m', htfMultiplier: htm,
      commissionPct: 0.025, slippagePct: 0.04,
      fundingRatePct: 0.01, fundingIntervalHrs: 8,
      baseNotionalUSDT: 20.0, leverage: 5.0,
      slBufferPct: 0.3, tightSL: tight,
      sfiFilter: sfi, minBreakoutPct: brk,
      maxChasePct: chase, cooldownBars: cd,
      maxHoldBars: mh, minChannelWidthPct: 1.0,
      srDetectionLength: 10, srMargin: 2.0,
      sfiPeriod: 10, sfiMultiplier: 1.7,
      execIntervalMinutes: 5,
    );
    print('Running: $lbl...');
    final res = runBacktest(cfg, zM[htm]!, htfM[htm]!, c5m);
    results.add(res);
    printReport(res);
  }

  printMasterTable(results);
}
