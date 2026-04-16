import 'dart:io';
import 'dart:math';

// ============================================================================
// MODELS
// ============================================================================

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int index;

  Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.index,
  });

  double get ohlc4 => (open + high + low + close) / 4.0;

  @override
  String toString() =>
      '[$index] ${time.toIso8601String()} O=${open.toStringAsFixed(2)} H=${high.toStringAsFixed(2)} L=${low.toStringAsFixed(2)} C=${close.toStringAsFixed(2)} V=${volume.toStringAsFixed(0)}';
}

// ============================================================================
// SR ZONE MODEL & INDICATOR
// ============================================================================

class SRZone {
  double boxTop;
  double boxBottom;
  int boxLeft;
  int boxRight;
  double linePrice;
  int lineLeft;
  int lineRight;
  bool b; // breakout
  bool t; // test
  bool r; // retest
  bool l; // manipulation
  double m; // margin factor
  bool isResistance;
  String createdBy;

  double lqTop;
  double lqBottom;
  int lqLeft;
  int lqRight;

  SRZone({
    required this.boxTop,
    required this.boxBottom,
    required this.boxLeft,
    required this.boxRight,
    required this.linePrice,
    required this.m,
    required this.isResistance,
    this.createdBy = 'pivot',
    int? lineLeft,
    int? lineRight,
    this.b = false,
    this.t = false,
    this.r = false,
    this.l = false,
    this.lqTop = 0,
    this.lqBottom = 0,
    this.lqLeft = 0,
    this.lqRight = 0,
  })  : lineLeft = lineLeft ?? boxLeft,
        lineRight = lineRight ?? boxRight;

  bool get isActive => !b;

  @override
  String toString() {
    String type = isResistance ? 'RES' : 'SUP';
    String status = b ? 'BROKEN' : 'ACTIVE';
    return '$type $status ${boxBottom.toStringAsFixed(2)}-${boxTop.toStringAsFixed(2)} line=${linePrice.toStringAsFixed(2)}';
  }
}

class PivotPoint {
  int x = 0;
  int x1 = 0;
  double h = 0;
  double h1 = 0;
  double l = double.maxFinite;
  double l1 = double.maxFinite;
  bool hx = false;
  bool lx = false;
}

class SupportResistanceIndicator {
  final int detectionLength;
  final double srMargin;
  final bool avoidFBO;
  final bool checkHist;
  final bool showManip;
  final double manipMargin;

  SupportResistanceIndicator({
    this.detectionLength = 15,
    this.srMargin = 2.0,
    this.avoidFBO = true,
    this.checkHist = true,
    this.showManip = true,
    this.manipMargin = 1.3,
  });

  late List<SRZone> R;
  late List<SRZone> S;
  late PivotPoint pp;
  late int mss;
  late List<double> _highs;
  late List<double> _lows;
  late List<double> _atr;
  late List<double> _vSMA;

  double _pHST(int i, int len) {
    double mx = _highs[i];
    for (int j = 1; j < len && (i - j) >= 0; j++) mx = max(mx, _highs[i - j]);
    return mx;
  }

  double _pLST(int i, int len) {
    double mn = _lows[i];
    for (int j = 1; j < len && (i - j) >= 0; j++) mn = min(mn, _lows[i - j]);
    return mn;
  }

  ({List<SRZone> resistance, List<SRZone> support, Map<int, ({List<SRZone> r, List<SRZone> s})> snapshots}) calculate(List<Candle> candles) {
    int srLN = detectionLength;
    int n = candles.length;
    if (n < srLN * 2 + 17) {
      print('Need at least ${srLN * 2 + 17} candles, got $n');
      return (resistance: [], support: [], snapshots: {});
    }

    R = [];
    S = [];
    pp = PivotPoint();
    mss = 0;
    _highs = candles.map((c) => c.high).toList();
    _lows = candles.map((c) => c.low).toList();
    _atr = _calcATR(candles, 17);
    _vSMA = _calcVolSMA(candles, 17);

    Map<int, ({List<SRZone> r, List<SRZone> s})> snapshots = {};

    for (int i = 0; i < n; i++) {
      double curH = candles[i].high;
      double curL = candles[i].low;
      double curC = candles[i].close;
      double curO = candles[i].open;
      double prevH = i > 0 ? candles[i - 1].high : curH;
      double prevL = i > 0 ? candles[i - 1].low : curL;
      double prevC = i > 0 ? candles[i - 1].close : curC;
      double prevO = i > 0 ? candles[i - 1].open : curO;
      double prevV = i > 0 ? candles[i - 1].volume : 0;
      int prevI = i > 0 ? i - 1 : i;
      double prevAtr = (i > 0 && i - 1 < _atr.length) ? _atr[i - 1] : 0;
      double prevVSMA = (i > 0 && i - 1 < _vSMA.length) ? _vSMA[i - 1] : 0;

      bool prevIsLLS = prevAtr > 0 && (prevL - min(prevO, prevC)).abs() >= 1.618 * prevAtr;
      bool prevIsLUS = prevAtr > 0 && (prevH - max(prevO, prevC)).abs() >= 1.618 * prevAtr;
      bool prevIsHV = prevVSMA > 0 && prevV >= 1.618 * prevVSMA;

      // PIVOT HIGH
      int phIdx = i - srLN;
      if (phIdx >= srLN && phIdx + srLN < n) {
        double? ppH = _pivotHigh(candles, phIdx, srLN);
        if (ppH != null) _onPivotHigh(candles, ppH, phIdx, i, srLN);
      }
      if (pp.h > 0 && i > 0) {
        if (prevC > pp.h && curC > pp.h && !pp.hx) {
          pp.hx = true;
          mss = 1;
        }
      }

      // PIVOT LOW
      int plIdx = i - srLN;
      if (plIdx >= srLN && plIdx + srLN < n) {
        double? ppL = _pivotLow(candles, plIdx, srLN);
        if (ppL != null) _onPivotLow(candles, ppL, plIdx, i, srLN);
      }
      if (pp.l < double.maxFinite && i > 0) {
        if (prevC < pp.l && curC < pp.l && !pp.lx) {
          pp.lx = true;
          mss = -1;
        }
      }

      _processZoneInteractions(candles, i, srLN, prevIsLLS, prevIsLUS, prevIsHV);

      // Save snapshot of active zones at this bar
      snapshots[i] = (
      r: R.where((z) => z.isActive).toList(),
      s: S.where((z) => z.isActive).toList(),
      );
    }

    return (resistance: R, support: S, snapshots: snapshots);
  }

  void _processZoneInteractions(List<Candle> candles, int i, int srLN, bool prevIsLLS, bool prevIsLUS, bool prevIsHV) {
    double curH = candles[i].high;
    double curL = candles[i].low;
    double curC = candles[i].close;
    double prevC = i > 0 ? candles[i - 1].close : curC;
    double prevH = i > 0 ? candles[i - 1].high : curH;
    double prevO = i > 0 ? candles[i - 1].open : candles[i].open;
    int prevI = i > 0 ? i - 1 : i;

    // Resistance interactions
    if (R.isNotEmpty) {
      SRZone lR = R[0];
      if (avoidFBO && prevC > lR.boxTop * (1 + lR.m * 0.17) && !lR.b) {
        lR.boxRight = prevI;
        lR.lineRight = prevI;
        lR.b = true;
        S.insert(0, SRZone(boxTop: lR.boxTop, boxBottom: lR.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lR.boxBottom, m: lR.m, isResistance: false, createdBy: 'breakoutR→S'));
      } else if (!avoidFBO && prevC > lR.boxTop && !lR.b) {
        lR.boxRight = prevI;
        lR.lineRight = prevI;
        lR.b = true;
        S.insert(0, SRZone(boxTop: lR.boxTop, boxBottom: lR.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lR.boxBottom, m: lR.m, isResistance: false, createdBy: 'breakoutR→S'));
      } else if (curH > lR.boxBottom && !lR.b) {
        if (curH > lR.boxBottom) lR.boxRight = i;
        lR.lineRight = i;
      }
      if (showManip) _processManipR(lR, candles, i, srLN);
    }

    if (R.length > 1 && checkHist) {
      SRZone lRt = R[1];
      if (lRt.boxTop != (R.isNotEmpty ? R[0].boxTop : -1)) {
        if (avoidFBO && prevC > lRt.boxTop * (1 + lRt.m * 0.17) && !lRt.b) {
          lRt.b = true;
          S.insert(0, SRZone(boxTop: lRt.boxTop, boxBottom: lRt.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lRt.boxBottom, m: lRt.m, isResistance: false, createdBy: 'breakoutHistR→S'));
        } else if (!avoidFBO && prevC > lRt.boxTop && !lRt.b) {
          lRt.b = true;
          S.insert(0, SRZone(boxTop: lRt.boxTop, boxBottom: lRt.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lRt.boxBottom, m: lRt.m, isResistance: false, createdBy: 'breakoutHistR→S'));
        }
        if (showManip) _processManipR(lRt, candles, i, srLN);
      }
    }

    // Support interactions
    if (S.isNotEmpty) {
      SRZone lS = S[0];
      if (avoidFBO && prevC < lS.boxBottom * (1 - lS.m * 0.17) && !lS.b) {
        lS.boxRight = prevI;
        lS.lineRight = prevI;
        lS.b = true;
        R.insert(0, SRZone(boxTop: lS.boxTop, boxBottom: lS.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lS.boxTop, m: lS.m, isResistance: true, createdBy: 'breakoutS→R'));
      } else if (!avoidFBO && prevC < lS.boxBottom && !lS.b) {
        lS.boxRight = prevI;
        lS.lineRight = prevI;
        lS.b = true;
        R.insert(0, SRZone(boxTop: lS.boxTop, boxBottom: lS.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lS.boxTop, m: lS.m, isResistance: true, createdBy: 'breakoutS→R'));
      } else if (curL < lS.boxTop && !lS.b) {
        if (curL < lS.boxTop) lS.boxRight = i;
        lS.lineRight = i;
      }
      if (showManip) _processManipS(lS, candles, i, srLN);
    }

    if (S.length > 1 && checkHist) {
      SRZone lSt = S[1];
      if (lSt.boxBottom != (S.isNotEmpty ? S[0].boxBottom : -1)) {
        if (avoidFBO && prevC < lSt.boxBottom * (1 - lSt.m * 0.17) && !lSt.b) {
          lSt.b = true;
          R.insert(0, SRZone(boxTop: lSt.boxTop, boxBottom: lSt.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lSt.boxTop, m: lSt.m, isResistance: true, createdBy: 'breakoutHistS→R'));
        } else if (!avoidFBO && prevC < lSt.boxBottom && !lSt.b) {
          lSt.b = true;
          R.insert(0, SRZone(boxTop: lSt.boxTop, boxBottom: lSt.boxBottom, boxLeft: prevI, boxRight: i + 1, linePrice: lSt.boxTop, m: lSt.m, isResistance: true, createdBy: 'breakoutHistS→R'));
        }
        if (showManip) _processManipS(lSt, candles, i, srLN);
      }
    }
  }

  double? _pivotHigh(List<Candle> candles, int idx, int len) {
    double val = candles[idx].high;
    for (int j = 1; j <= len; j++) {
      if (candles[idx - j].high > val) return null;
    }
    for (int j = 1; j <= len; j++) {
      if (candles[idx + j].high > val) return null;
    }
    return val;
  }

  double? _pivotLow(List<Candle> candles, int idx, int len) {
    double val = candles[idx].low;
    for (int j = 1; j <= len; j++) {
      if (candles[idx - j].low < val) return null;
    }
    for (int j = 1; j <= len; j++) {
      if (candles[idx + j].low < val) return null;
    }
    return val;
  }

  void _onPivotHigh(List<Candle> candles, double ppH, int pivotIdx, int curIdx, int srLN) {
    pp.h1 = pp.h;
    pp.h = ppH;
    pp.x1 = pp.x;
    pp.x = pivotIdx;
    pp.hx = false;

    double pHST = _pHST(curIdx, srLN);
    double pLST = _pLST(curIdx, srLN);
    double mf = pHST > 0 ? (pHST - pLST) / pHST : 0.01;
    double curC = candles[curIdx].close;
    double newTop = ppH;
    double newBot = ppH * (1 - mf * 0.17 * srMargin);

    if (R.length > 1) {
      SRZone lR = R[0];
      SRZone lRt = R[1];
      bool outsideLR = ppH < lR.boxBottom * (1 - lR.m * 0.17 * srMargin) || ppH > lR.boxTop * (1 + lR.m * 0.17 * srMargin);
      if (outsideLR) {
        if (pp.x < lR.boxLeft && pp.x + srLN > lR.boxLeft && curC < lR.boxBottom) {
        } else {
          bool outsideLRt = ppH < lRt.boxBottom * (1 - lRt.m * 0.17 * srMargin) || ppH > lRt.boxTop * (1 + lRt.m * 0.17 * srMargin);
          if (outsideLRt) {
            R.insert(0, SRZone(boxTop: newTop, boxBottom: newBot, boxLeft: pivotIdx, boxRight: curIdx, linePrice: ppH, m: mf, isResistance: true, createdBy: 'pivotH'));
            if (S.isNotEmpty) S[0].t = false;
          } else {
            lRt.boxRight = curIdx;
            lRt.lineRight = curIdx;
          }
        }
      } else {
        if (S.isEmpty || lR.boxTop != S[0].boxTop) {
          lR.boxRight = curIdx;
          lR.lineRight = curIdx;
        }
      }
    } else {
      R.insert(0, SRZone(boxTop: newTop, boxBottom: newBot, boxLeft: pivotIdx, boxRight: curIdx, linePrice: ppH, m: mf, isResistance: true, createdBy: 'pivotH'));
      if (S.isNotEmpty) S[0].t = false;
    }
  }

  void _onPivotLow(List<Candle> candles, double ppL, int pivotIdx, int curIdx, int srLN) {
    pp.l1 = pp.l;
    pp.l = ppL;
    pp.x1 = pp.x;
    pp.x = pivotIdx;
    pp.lx = false;

    double pHST = _pHST(curIdx, srLN);
    double pLST = _pLST(curIdx, srLN);
    double mf = pHST > 0 ? (pHST - pLST) / pHST : 0.01;
    double curC = candles[curIdx].close;
    double newTop = ppL * (1 + mf * 0.17 * srMargin);
    double newBot = ppL;

    if (S.length > 2) {
      SRZone lS = S[0];
      SRZone lSt = S[1];
      bool outsideLS = ppL < lS.boxBottom * (1 - lS.m * 0.17 * srMargin) || ppL > lS.boxTop * (1 + lS.m * 0.17 * srMargin);
      if (outsideLS) {
        if (pp.x < lS.boxLeft && pp.x + srLN > lS.boxLeft && curC > lS.boxTop) {
        } else {
          bool outsideLSt = ppL < lSt.boxBottom * (1 - lSt.m * 0.17 * srMargin) || ppL > lSt.boxTop * (1 + lSt.m * 0.17 * srMargin);
          if (outsideLSt) {
            S.insert(0, SRZone(boxTop: newTop, boxBottom: newBot, boxLeft: pivotIdx, boxRight: curIdx, linePrice: ppL, m: mf, isResistance: false, createdBy: 'pivotL'));
            if (R.isNotEmpty) R[0].t = false;
          } else {
            lSt.boxRight = curIdx;
            lSt.lineRight = curIdx;
          }
        }
      } else {
        if (R.isEmpty || lS.boxBottom != R[0].boxBottom) {
          lS.boxRight = curIdx;
          lS.lineRight = curIdx;
        }
      }
    } else {
      S.insert(0, SRZone(boxTop: newTop, boxBottom: newBot, boxLeft: pivotIdx, boxRight: curIdx, linePrice: ppL, m: mf, isResistance: false, createdBy: 'pivotL'));
      if (R.isNotEmpty) R[0].t = false;
    }
  }

  void _processManipR(SRZone zone, List<Candle> candles, int i, int srLN) {
    double curH = candles[i].high;
    double curC = candles[i].close;
    double ub = zone.boxTop * (1 + zone.m * 0.17 * manipMargin);
    if (curH > zone.boxTop && curC <= ub && !zone.l && i == zone.boxRight) {
      if (zone.lqRight + srLN > i) {
        zone.lqRight = i + 1;
        zone.lqTop = min(max(curH, zone.lqTop), ub);
      } else {
        zone.lqLeft = i - 1;
        zone.lqTop = min(curH, ub);
        zone.lqRight = i + 1;
        zone.lqBottom = zone.boxTop;
      }
      zone.l = true;
    } else if (curH > zone.boxTop && curC <= ub && zone.l && i == zone.boxRight) {
      zone.lqRight = i + 1;
      zone.lqTop = min(max(curH, zone.lqTop), ub);
    } else if (zone.l && (curC >= ub || curC < zone.boxBottom)) {
      zone.l = false;
    }
  }

  void _processManipS(SRZone zone, List<Candle> candles, int i, int srLN) {
    double curL = candles[i].low;
    double curC = candles[i].close;
    double lb = zone.boxBottom * (1 - zone.m * 0.17 * manipMargin);
    if (curL < zone.boxBottom && curC >= lb && !zone.l && i == zone.boxRight) {
      if (zone.lqRight + srLN > i) {
        zone.lqRight = i + 1;
        zone.lqBottom = max(min(curL, zone.lqBottom), lb);
      } else {
        zone.lqLeft = i - 1;
        zone.lqTop = zone.boxBottom;
        zone.lqRight = i + 1;
        zone.lqBottom = max(curL, lb);
      }
      zone.l = true;
    } else if (curL < zone.boxBottom && curC >= lb && zone.l && i == zone.boxRight) {
      zone.lqRight = i + 1;
      zone.lqBottom = max(min(curL, zone.lqBottom), lb);
    } else if (zone.l && (curC <= lb || curC > zone.boxTop)) {
      zone.l = false;
    }
  }

  List<double> _calcATR(List<Candle> candles, int period) {
    int n = candles.length;
    List<double> tr = List.filled(n, 0.0);
    List<double> atr = List.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      if (i == 0) {
        tr[i] = candles[i].high - candles[i].low;
      } else {
        tr[i] = max(candles[i].high - candles[i].low, max((candles[i].high - candles[i - 1].close).abs(), (candles[i].low - candles[i - 1].close).abs()));
      }
    }
    double sum = 0;
    for (int i = 0; i < min(period, n); i++) sum += tr[i];
    if (period <= n) atr[period - 1] = sum / period;
    for (int i = period; i < n; i++) atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period;
    return atr;
  }

  List<double> _calcVolSMA(List<Candle> candles, int period) {
    int n = candles.length;
    List<double> sma = List.filled(n, 0.0);
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += candles[i].volume;
      if (i >= period) sum -= candles[i - period].volume;
      if (i >= period - 1) sma[i] = sum / period;
    }
    return sma;
  }
}

// ============================================================================
// SFI INDICATOR
// ============================================================================

class SfiSignal {
  final double upLine;
  final double dnLine;
  final int trend;
  final bool buySignal;
  final bool sellSignal;

  SfiSignal({
    required this.upLine,
    required this.dnLine,
    required this.trend,
    required this.buySignal,
    required this.sellSignal,
  });
}

class SfiIndicator {
  List<double> calculateTR(List<Candle> candles) {
    List<double> trList = [];
    for (int i = 0; i < candles.length; i++) {
      double previousClose = i == 0 ? candles[i].close : candles[i - 1].close;
      double tr = [
        candles[i].high - candles[i].low,
        (candles[i].high - previousClose).abs(),
        (candles[i].low - previousClose).abs()
      ].reduce((a, b) => a > b ? a : b);
      trList.add(tr);
    }
    return trList;
  }

  List<double> calculateWilderATR(List<double> trList, int period) {
    List<double> atr = [];
    if (trList.isEmpty) return atr;
    double sum = 0.0;
    for (int i = 0; i < trList.length; i++) {
      if (i < period) {
        sum += trList[i];
        atr.add(sum / (i + 1));
      } else if (i == period) {
        double initial = trList.sublist(0, period).reduce((a, b) => a + b) / period;
        atr.add(initial);
      } else {
        double prevAtr = atr[i - 1];
        double newAtr = ((prevAtr * (period - 1)) + trList[i]) / period;
        atr.add(newAtr);
      }
    }
    return atr;
  }

  List<SfiSignal> calculateSfiMagic(List<Candle> candles, {
    int period = 10,
    double multiplier = 1.7,
  }) {
    final trList = calculateTR(candles);
    final atrListWilder = calculateWilderATR(trList, period);
    List<SfiSignal> signals = [];
    if (candles.isEmpty) return signals;

    double prevUp = candles[0].ohlc4 - multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    double prevDn = candles[0].ohlc4 + multiplier * (atrListWilder.isNotEmpty ? atrListWilder[0] : 0.0);
    int previousTrend = 1;

    for (int i = 0; i < candles.length; i++) {
      Candle c = candles[i];
      double atr = (i < atrListWilder.length) ? atrListWilder[i] : (atrListWilder.isNotEmpty ? atrListWilder.last : 0.0);
      double ohlc4 = c.ohlc4;
      double rawUp = ohlc4 - multiplier * atr;
      double rawDn = ohlc4 + multiplier * atr;

      double up;
      double dn;
      if (i > 0) {
        up = candles[i - 1].close > prevUp ? max(rawUp, prevUp) : rawUp;
        dn = candles[i - 1].close < prevDn ? min(rawDn, prevDn) : rawDn;
      } else {
        up = rawUp;
        dn = rawDn;
      }

      int trend = previousTrend;
      if (previousTrend == -1 && c.close > prevDn) {
        trend = 1;
      } else if (previousTrend == 1 && c.close < prevUp) {
        trend = -1;
      }

      bool buySignal = previousTrend == -1 && trend == 1;
      bool sellSignal = previousTrend == 1 && trend == -1;

      signals.add(SfiSignal(upLine: up, dnLine: dn, trend: trend, buySignal: buySignal, sellSignal: sellSignal));

      prevUp = up;
      prevDn = dn;
      previousTrend = trend;
    }
    return signals;
  }
}

// ============================================================================
// BACKTEST ENGINE
// ============================================================================

enum TradeDirection { long, short }
enum TradeStatus { open, closedTP, closedSignalReverse, closedSL, closedEnd }

class BacktestTrade {
  final int id;
  final TradeDirection direction;
  final int entryBar;
  final DateTime entryTime;
  final double entryPrice;
  final double totalQty;
  final double tp1Price;       // 1st take-profit level (1x ATR)
  final double stopLoss;       // SFI line as initial SL
  final String srZoneInfo;

  double remainingQty;
  double realizedPnl = 0.0;
  int? exitBar;
  DateTime? exitTime;
  double? exitPrice;
  TradeStatus status = TradeStatus.open;
  bool firstTPHit = false;
  List<String> log = [];

  BacktestTrade({
    required this.id,
    required this.direction,
    required this.entryBar,
    required this.entryTime,
    required this.entryPrice,
    required this.totalQty,
    required this.tp1Price,
    required this.stopLoss,
    required this.srZoneInfo,
  }) : remainingQty = totalQty;

  double get pnlPercent => (realizedPnl / (entryPrice * totalQty)) * 100;

  @override
  String toString() {
    String dir = direction == TradeDirection.long ? 'LONG' : 'SHORT';
    return '#$id $dir entry=${entryPrice.toStringAsFixed(4)} qty=$totalQty '
        'pnl=${realizedPnl.toStringAsFixed(4)} (${pnlPercent.toStringAsFixed(2)}%) '
        'status=${status.name} zone=$srZoneInfo';
  }
}

class BacktestResult {
  final List<BacktestTrade> trades;
  final double initialBalance;
  final double finalBalance;
  final int totalTrades;
  final int winTrades;
  final int lossTrades;
  final double winRate;
  final double totalPnl;
  final double maxDrawdown;
  final double profitFactor;
  final List<double> equityCurve;
  final double totalFees;
  final double totalSlippage;

  BacktestResult({
    required this.trades,
    required this.initialBalance,
    required this.finalBalance,
    required this.totalTrades,
    required this.winTrades,
    required this.lossTrades,
    required this.winRate,
    required this.totalPnl,
    required this.maxDrawdown,
    required this.profitFactor,
    required this.equityCurve,
    required this.totalFees,
    required this.totalSlippage,
  });
}

class Backtester {
  final double initialBalance;
  final double positionSizePct;
  final double tp1AtrMultiplier;  // ATR multiplier for TP1 (e.g. 1.0)
  final int atrPeriod;
  final bool verbose;

  // Fees & Slippage (as percentages, e.g. 0.04 = 0.04%)
  final double makerFeePct;   // limit orders (TP1 hit = maker)
  final double takerFeePct;   // market orders (entry, SL, signal reverse = taker)
  final double slippagePct;   // applied on market orders only

  double totalFeesDeducted = 0.0;
  double totalSlippageDeducted = 0.0;

  Backtester({
    this.initialBalance = 10000.0,
    this.positionSizePct = 2.0,
    this.tp1AtrMultiplier = 1.0,
    this.atrPeriod = 14,
    this.verbose = true,
    this.makerFeePct = 0.04,    // Binance maker 0.04%
    this.takerFeePct = 0.06,    // Binance taker 0.06%
    this.slippagePct = 0.02,    // 0.02% slippage
  });

  /// Apply slippage to a price. For buys, price goes UP. For sells, price goes DOWN.
  double _applySlippage(double price, bool isBuy) {
    double slip = price * slippagePct / 100.0;
    return isBuy ? price + slip : price - slip;
  }

  /// Calculate fee amount on a notional value. Returns the fee to deduct.
  double _calcFee(double price, double qty, {required bool isMaker}) {
    double feePct = isMaker ? makerFeePct : takerFeePct;
    return (price * qty) * feePct / 100.0;
  }

  BacktestResult run(List<Candle> candles) {
    totalFeesDeducted = 0.0;
    totalSlippageDeducted = 0.0;

    print('═══════════════════════════════════════════════════════════');
    print('  BACKTESTING ENGINE');
    print('  Candles: ${candles.length} | Balance: \$${initialBalance.toStringAsFixed(2)}');
    print('  Position Size: ${positionSizePct}% | TP1 ATR mult: ${tp1AtrMultiplier}x');
    print('  Maker Fee: ${makerFeePct}% | Taker Fee: ${takerFeePct}% | Slippage: ${slippagePct}%');
    print('  Exit remaining 50% on signal reversal');
    print('═══════════════════════════════════════════════════════════\n');

    // Step 1: Calculate SR zones
    print('[1/3] Computing Support/Resistance zones...');
    final srIndicator = SupportResistanceIndicator(
      detectionLength: 15,
      srMargin: 2.0,
      avoidFBO: true,
      checkHist: true,
      showManip: true,
      manipMargin: 1.3,
    );
    final srResult = srIndicator.calculate(candles);
    print('  → R zones: ${srResult.resistance.length}, S zones: ${srResult.support.length}\n');

    // Step 2: Calculate SFI signals
    print('[2/3] Computing SFI Magic signals...');
    final sfiIndicator = SfiIndicator();
    final sfiSignals = sfiIndicator.calculateSfiMagic(candles, period: 10, multiplier: 1.7);
    int buys = sfiSignals.where((s) => s.buySignal).length;
    int sells = sfiSignals.where((s) => s.sellSignal).length;
    print('  → SFI Buy signals: $buys, Sell signals: $sells\n');

    // Step 3: Compute ATR for TP
    final trList = sfiIndicator.calculateTR(candles);
    final atrList = sfiIndicator.calculateWilderATR(trList, atrPeriod);

    // Step 4: Run backtest
    print('[3/3] Running backtest...\n');

    double balance = initialBalance;
    List<BacktestTrade> allTrades = [];
    List<BacktestTrade> openTrades = [];
    List<double> equityCurve = [initialBalance];
    int tradeId = 0;

    for (int i = 0; i < candles.length; i++) {
      Candle c = candles[i];
      SfiSignal sfi = sfiSignals[i];
      double atr = (i < atrList.length) ? atrList[i] : (atrList.isNotEmpty ? atrList.last : 0.0);

      // Get active SR zones at this bar
      var snapshot = srResult.snapshots[i];
      List<SRZone> activeSupports = snapshot?.s ?? [];
      List<SRZone> activeResistances = snapshot?.r ?? [];

      // ─── CLOSE REMAINING 50% ON SIGNAL REVERSAL ──────────────
      // This runs BEFORE entry so we close old trades first on the
      // same candle that gives the new signal.

      List<BacktestTrade> toRemove = [];

      for (var trade in openTrades) {
        if (trade.direction == TradeDirection.long) {
          // ── Check SL (before TP1 only) ── [taker + slippage: sell at worse price]
          if (!trade.firstTPHit && c.low <= trade.stopLoss && trade.remainingQty > 0) {
            double exitP = _applySlippage(trade.stopLoss, false); // selling → price slips down
            double pnl = (exitP - trade.entryPrice) * trade.remainingQty;
            double fee = _calcFee(exitP, trade.remainingQty, isMaker: false);
            pnl -= fee;
            totalFeesDeducted += fee;
            totalSlippageDeducted += (trade.stopLoss - exitP).abs() * trade.remainingQty;
            trade.realizedPnl += pnl;
            balance += pnl;
            trade.remainingQty = 0;
            trade.exitBar = i;
            trade.exitTime = c.time;
            trade.exitPrice = exitP;
            trade.status = TradeStatus.closedSL;
            trade.log.add('SL HIT bar=$i price=${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ✗ LONG #${trade.id} SL HIT @ ${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            toRemove.add(trade);
            continue;
          }

          // ── Check TP1 hit → close 50% ── [maker: limit order, no slippage]
          if (!trade.firstTPHit && c.high >= trade.tp1Price && trade.remainingQty > 0) {
            double closeQty = trade.remainingQty * 0.5;
            double pnl = (trade.tp1Price - trade.entryPrice) * closeQty;
            double fee = _calcFee(trade.tp1Price, closeQty, isMaker: true);
            pnl -= fee;
            totalFeesDeducted += fee;
            trade.realizedPnl += pnl;
            trade.remainingQty -= closeQty;
            trade.firstTPHit = true;
            balance += pnl;
            trade.log.add('TP1 HIT bar=$i price=${trade.tp1Price.toStringAsFixed(4)} closed=${closeQty.toStringAsFixed(6)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ✓ LONG #${trade.id} TP1 hit @ ${trade.tp1Price.toStringAsFixed(4)} closed 50% fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
          }

          // ── Signal reversal → close remaining ── [taker + slippage: market sell]
          if (sfi.sellSignal && trade.remainingQty > 0) {
            double exitP = _applySlippage(c.close, false); // selling → price slips down
            double pnl = (exitP - trade.entryPrice) * trade.remainingQty;
            double fee = _calcFee(exitP, trade.remainingQty, isMaker: false);
            pnl -= fee;
            totalFeesDeducted += fee;
            totalSlippageDeducted += (c.close - exitP).abs() * trade.remainingQty;
            trade.realizedPnl += pnl;
            balance += pnl;
            trade.remainingQty = 0;
            trade.exitBar = i;
            trade.exitTime = c.time;
            trade.exitPrice = exitP;
            trade.status = TradeStatus.closedSignalReverse;
            trade.log.add('SIGNAL REVERSE bar=$i price=${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ⟲ LONG #${trade.id} SIGNAL REVERSE (sell) @ ${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)} total=${trade.realizedPnl.toStringAsFixed(4)}');
            toRemove.add(trade);
          }

        } else {
          // SHORT trade management

          // ── Check SL (before TP1 only) ── [taker + slippage: buy to cover at worse price]
          if (!trade.firstTPHit && c.high >= trade.stopLoss && trade.remainingQty > 0) {
            double exitP = _applySlippage(trade.stopLoss, true); // buying → price slips up
            double pnl = (trade.entryPrice - exitP) * trade.remainingQty;
            double fee = _calcFee(exitP, trade.remainingQty, isMaker: false);
            pnl -= fee;
            totalFeesDeducted += fee;
            totalSlippageDeducted += (exitP - trade.stopLoss).abs() * trade.remainingQty;
            trade.realizedPnl += pnl;
            balance += pnl;
            trade.remainingQty = 0;
            trade.exitBar = i;
            trade.exitTime = c.time;
            trade.exitPrice = exitP;
            trade.status = TradeStatus.closedSL;
            trade.log.add('SL HIT bar=$i price=${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ✗ SHORT #${trade.id} SL HIT @ ${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            toRemove.add(trade);
            continue;
          }

          // ── Check TP1 hit → close 50% ── [maker: limit order, no slippage]
          if (!trade.firstTPHit && c.low <= trade.tp1Price && trade.remainingQty > 0) {
            double closeQty = trade.remainingQty * 0.5;
            double pnl = (trade.entryPrice - trade.tp1Price) * closeQty;
            double fee = _calcFee(trade.tp1Price, closeQty, isMaker: true);
            pnl -= fee;
            totalFeesDeducted += fee;
            trade.realizedPnl += pnl;
            trade.remainingQty -= closeQty;
            trade.firstTPHit = true;
            balance += pnl;
            trade.log.add('TP1 HIT bar=$i price=${trade.tp1Price.toStringAsFixed(4)} closed=${closeQty.toStringAsFixed(6)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ✓ SHORT #${trade.id} TP1 hit @ ${trade.tp1Price.toStringAsFixed(4)} closed 50% fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
          }

          // ── Signal reversal → close remaining ── [taker + slippage: market buy to cover]
          if (sfi.buySignal && trade.remainingQty > 0) {
            double exitP = _applySlippage(c.close, true); // buying → price slips up
            double pnl = (trade.entryPrice - exitP) * trade.remainingQty;
            double fee = _calcFee(exitP, trade.remainingQty, isMaker: false);
            pnl -= fee;
            totalFeesDeducted += fee;
            totalSlippageDeducted += (exitP - c.close).abs() * trade.remainingQty;
            trade.realizedPnl += pnl;
            balance += pnl;
            trade.remainingQty = 0;
            trade.exitBar = i;
            trade.exitTime = c.time;
            trade.exitPrice = exitP;
            trade.status = TradeStatus.closedSignalReverse;
            trade.log.add('SIGNAL REVERSE bar=$i price=${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
            if (verbose) print('    ⟲ SHORT #${trade.id} SIGNAL REVERSE (buy) @ ${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)} total=${trade.realizedPnl.toStringAsFixed(4)}');
            toRemove.add(trade);
          }
        }
      }

      openTrades.removeWhere((t) => toRemove.contains(t));

      // ─── ENTRY LOGIC ─────────────────────────────────────────
      // Enter on the SAME candle that gives the signal.
      // LONG: buySignal (SFI flips to 1) + candle CLOSE is within/touching a support zone
      // SHORT: sellSignal (SFI flips to -1) + candle CLOSE is within/touching a resistance zone

      // LONG ENTRY
      if (sfi.buySignal && activeSupports.isNotEmpty && !_hasOpenTrade(openTrades, TradeDirection.long)) {
        // Find support zone BELOW current price that the candle bounced off.
        // Valid support bounce:
        //   - The candle's LOW dips INTO or TOUCHES the zone (low <= boxTop)
        //   - The candle CLOSES ABOVE the zone top (rejection/bounce)
        //   - The close must be above boxTop (not sitting inside the zone)
        SRZone? bestZone;
        double minDist = double.maxFinite;

        for (var zone in activeSupports) {
          // Wick dips into zone: low reaches into [boxBottom .. boxTop]
          bool wickDipsIntoZone = c.low <= zone.boxTop && c.low >= zone.boxBottom * 0.998;

          // Close is ABOVE the zone top → proper bounce/rejection
          bool closeAboveZone = c.close > zone.boxTop;

          if (wickDipsIntoZone && closeAboveZone) {
            double dist = c.close - zone.boxTop; // how far above the zone we closed
            if (dist < minDist) {
              minDist = dist;
              bestZone = zone;
            }
          }
        }

        if (bestZone != null && atr > 0) {
          // Entry is a market order → taker fee + slippage
          double entryP = _applySlippage(c.close, true); // buying → price slips up
          double qty = (balance * positionSizePct / 100) / entryP;
          if (qty > 0) {
            double entryFee = _calcFee(entryP, qty, isMaker: false);
            balance -= entryFee; // deduct entry fee from balance immediately
            totalFeesDeducted += entryFee;
            totalSlippageDeducted += (entryP - c.close).abs() * qty;

            double tp1 = entryP + tp1AtrMultiplier * atr;
            double sl = sfi.upLine; // SFI up line as SL for longs

            tradeId++;
            var trade = BacktestTrade(
              id: tradeId,
              direction: TradeDirection.long,
              entryBar: i,
              entryTime: c.time,
              entryPrice: entryP,
              totalQty: qty,
              tp1Price: tp1,
              stopLoss: sl,
              srZoneInfo: 'SUP ${bestZone.boxBottom.toStringAsFixed(2)}-${bestZone.boxTop.toStringAsFixed(2)}',
            );
            trade.log.add('ENTRY bar=$i price=${entryP.toStringAsFixed(4)} (raw=${c.close.toStringAsFixed(4)}) qty=${qty.toStringAsFixed(6)} fee=${entryFee.toStringAsFixed(4)} TP1=${tp1.toStringAsFixed(4)} SL=${sl.toStringAsFixed(4)}');
            openTrades.add(trade);
            allTrades.add(trade);
            if (verbose) print('  ▲ LONG #$tradeId @ ${entryP.toStringAsFixed(4)} (slip from ${c.close.toStringAsFixed(4)}) [${c.time}] zone=${trade.srZoneInfo} fee=${entryFee.toStringAsFixed(4)}');
          }
        }
      }

      // SHORT ENTRY
      if (sfi.sellSignal && activeResistances.isNotEmpty && !_hasOpenTrade(openTrades, TradeDirection.short)) {
        // Find resistance zone ABOVE current price that the candle rejected off.
        // Valid resistance rejection:
        //   - The candle's HIGH pokes INTO or TOUCHES the zone (high >= boxBottom)
        //   - The candle CLOSES BELOW the zone bottom (rejection)
        //   - The close must be below boxBottom (not sitting inside the zone)
        SRZone? bestZone;
        double minDist = double.maxFinite;

        for (var zone in activeResistances) {
          // Wick pokes into zone: high reaches into [boxBottom .. boxTop]
          bool wickPokesIntoZone = c.high >= zone.boxBottom && c.high <= zone.boxTop * 1.002;

          // Close is BELOW the zone bottom → proper rejection
          bool closeBelowZone = c.close < zone.boxBottom;

          if (wickPokesIntoZone && closeBelowZone) {
            double dist = zone.boxBottom - c.close; // how far below the zone we closed
            if (dist < minDist) {
              minDist = dist;
              bestZone = zone;
            }
          }
        }

        if (bestZone != null && atr > 0) {
          // Entry is a market order → taker fee + slippage
          double entryP = _applySlippage(c.close, false); // selling/shorting → price slips down
          double qty = (balance * positionSizePct / 100) / entryP;
          if (qty > 0) {
            double entryFee = _calcFee(entryP, qty, isMaker: false);
            balance -= entryFee;
            totalFeesDeducted += entryFee;
            totalSlippageDeducted += (c.close - entryP).abs() * qty;

            double tp1 = entryP - tp1AtrMultiplier * atr;
            double sl = sfi.dnLine; // SFI dn line as SL for shorts

            tradeId++;
            var trade = BacktestTrade(
              id: tradeId,
              direction: TradeDirection.short,
              entryBar: i,
              entryTime: c.time,
              entryPrice: entryP,
              totalQty: qty,
              tp1Price: tp1,
              stopLoss: sl,
              srZoneInfo: 'RES ${bestZone.boxBottom.toStringAsFixed(2)}-${bestZone.boxTop.toStringAsFixed(2)}',
            );
            trade.log.add('ENTRY bar=$i price=${entryP.toStringAsFixed(4)} (raw=${c.close.toStringAsFixed(4)}) qty=${qty.toStringAsFixed(6)} fee=${entryFee.toStringAsFixed(4)} TP1=${tp1.toStringAsFixed(4)} SL=${sl.toStringAsFixed(4)}');
            openTrades.add(trade);
            allTrades.add(trade);
            if (verbose) print('  ▼ SHORT #$tradeId @ ${entryP.toStringAsFixed(4)} (slip from ${c.close.toStringAsFixed(4)}) [${c.time}] zone=${trade.srZoneInfo} fee=${entryFee.toStringAsFixed(4)}');
          }
        }
      }

      equityCurve.add(balance);
    }

    // Close remaining open trades at last candle price (market order → taker + slippage)
    for (var trade in openTrades) {
      double rawExitP = candles.last.close;
      bool isBuy = trade.direction == TradeDirection.short; // shorts buy to cover
      double exitP = _applySlippage(rawExitP, isBuy);
      double pnl;
      if (trade.direction == TradeDirection.long) {
        pnl = (exitP - trade.entryPrice) * trade.remainingQty;
      } else {
        pnl = (trade.entryPrice - exitP) * trade.remainingQty;
      }
      double fee = _calcFee(exitP, trade.remainingQty, isMaker: false);
      pnl -= fee;
      totalFeesDeducted += fee;
      totalSlippageDeducted += (exitP - rawExitP).abs() * trade.remainingQty;
      trade.realizedPnl += pnl;
      balance += pnl;
      trade.remainingQty = 0;
      trade.exitBar = candles.length - 1;
      trade.exitTime = candles.last.time;
      trade.exitPrice = exitP;
      trade.status = TradeStatus.closedEnd;
      trade.log.add('FORCED EXIT bar=${candles.length - 1} price=${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
      if (verbose) print('  ⊘ FORCED EXIT #${trade.id} @ ${exitP.toStringAsFixed(4)} fee=${fee.toStringAsFixed(4)} pnl=${pnl.toStringAsFixed(4)}');
    }
    equityCurve.add(balance);

    // Compute stats
    int wins = allTrades.where((t) => t.realizedPnl > 0).length;
    int losses = allTrades.where((t) => t.realizedPnl <= 0).length;
    double totalPnl = balance - initialBalance;
    double grossProfit = allTrades.where((t) => t.realizedPnl > 0).fold(0.0, (s, t) => s + t.realizedPnl);
    double grossLoss = allTrades.where((t) => t.realizedPnl <= 0).fold(0.0, (s, t) => s + t.realizedPnl.abs());
    double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : grossProfit > 0 ? double.infinity : 0;

    double peak = initialBalance;
    double maxDD = 0;
    for (var eq in equityCurve) {
      if (eq > peak) peak = eq;
      double dd = (peak - eq) / peak * 100;
      if (dd > maxDD) maxDD = dd;
    }

    return BacktestResult(
      trades: allTrades,
      initialBalance: initialBalance,
      finalBalance: balance,
      totalTrades: allTrades.length,
      winTrades: wins,
      lossTrades: losses,
      winRate: allTrades.isNotEmpty ? wins / allTrades.length * 100 : 0,
      totalPnl: totalPnl,
      maxDrawdown: maxDD,
      profitFactor: profitFactor,
      equityCurve: equityCurve,
      totalFees: totalFeesDeducted,
      totalSlippage: totalSlippageDeducted,
    );
  }

  bool _hasOpenTrade(List<BacktestTrade> openTrades, TradeDirection dir) {
    return openTrades.any((t) => t.direction == dir);
  }
}

// ============================================================================
// CSV LOADER
// ============================================================================

List<Candle> loadCandlesFromCSV(String filePath) {
  final file = File(filePath);
  if (!file.existsSync()) {
    throw Exception('CSV file not found: $filePath');
  }

  final lines = file.readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#')).toList();
  if (lines.isEmpty) throw Exception('CSV file is empty');

  String sep = ',';
  if (lines[0].contains('\t') && !lines[0].contains(',')) sep = '\t';
  if (lines[0].contains(';') && !lines[0].contains(',')) sep = ';';

  int startIdx = 0;
  List<String> firstParts = lines[0].split(sep).map((s) => s.trim().toLowerCase()).toList();
  if (firstParts.any((p) => ['time', 'date', 'timestamp', 'datetime', 'open', 'close'].contains(p))) {
    startIdx = 1;
    print('  CSV header detected: ${lines[0]}');
  }

  int colTime = 0, colOpen = 1, colHigh = 2, colLow = 3, colClose = 4, colVol = 5;

  if (startIdx == 1) {
    for (int c = 0; c < firstParts.length; c++) {
      String h = firstParts[c];
      if (['time', 'date', 'timestamp', 'datetime', 'unix', 'epoch'].contains(h)) colTime = c;
      else if (h == 'open' || h == 'o') colOpen = c;
      else if (h == 'high' || h == 'h') colHigh = c;
      else if (h == 'low' || h == 'l') colLow = c;
      else if (h == 'close' || h == 'c') colClose = c;
      else if (['volume', 'vol', 'v'].contains(h)) colVol = c;
    }
  }

  List<Candle> candles = [];
  for (int i = startIdx; i < lines.length; i++) {
    try {
      List<String> parts = lines[i].split(sep).map((s) => s.trim()).toList();
      if (parts.length < 5) continue;

      DateTime time;
      String timeStr = parts[colTime];
      double? ts = double.tryParse(timeStr);
      if (ts != null) {
        if (ts > 1e12) {
          time = DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true);
        } else {
          time = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt(), isUtc: true);
        }
      } else {
        time = DateTime.parse(timeStr);
      }

      double open = double.parse(parts[colOpen]);
      double high = double.parse(parts[colHigh]);
      double low = double.parse(parts[colLow]);
      double close = double.parse(parts[colClose]);
      double volume = parts.length > colVol ? (double.tryParse(parts[colVol]) ?? 0) : 0;

      candles.add(Candle(
        time: time,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume,
        index: candles.length,
      ));
    } catch (e) {
      if (candles.isEmpty) print('  Warning: Could not parse line $i: ${lines[i]} ($e)');
    }
  }

  return candles;
}

// ============================================================================
// REPORT GENERATOR
// ============================================================================

void printReport(BacktestResult result) {
  print('\n');
  print('╔═══════════════════════════════════════════════════════════╗');
  print('║               BACKTEST RESULTS SUMMARY                   ║');
  print('╠═══════════════════════════════════════════════════════════╣');
  print('║  Initial Balance:   \$${result.initialBalance.toStringAsFixed(2).padLeft(12)}              ║');
  print('║  Final Balance:     \$${result.finalBalance.toStringAsFixed(2).padLeft(12)}              ║');
  print('║  Total P&L:         \$${result.totalPnl.toStringAsFixed(2).padLeft(12)}              ║');
  print('║  Return:             ${(result.totalPnl / result.initialBalance * 100).toStringAsFixed(2).padLeft(11)}%              ║');
  print('╠═══════════════════════════════════════════════════════════╣');
  print('║  Total Trades:       ${result.totalTrades.toString().padLeft(8)}                    ║');
  print('║  Winning Trades:     ${result.winTrades.toString().padLeft(8)}                    ║');
  print('║  Losing Trades:      ${result.lossTrades.toString().padLeft(8)}                    ║');
  print('║  Win Rate:           ${result.winRate.toStringAsFixed(2).padLeft(7)}%                    ║');
  print('╠═══════════════════════════════════════════════════════════╣');
  print('║  Profit Factor:      ${result.profitFactor.toStringAsFixed(2).padLeft(8)}                    ║');
  print('║  Max Drawdown:       ${result.maxDrawdown.toStringAsFixed(2).padLeft(7)}%                    ║');
  print('╠═══════════════════════════════════════════════════════════╣');
  print('║  Total Fees Paid:   \$${result.totalFees.toStringAsFixed(2).padLeft(12)}              ║');
  print('║  Total Slippage:    \$${result.totalSlippage.toStringAsFixed(2).padLeft(12)}              ║');
  print('║  Fees+Slip Cost:    \$${(result.totalFees + result.totalSlippage).toStringAsFixed(2).padLeft(12)}              ║');
  print('╚═══════════════════════════════════════════════════════════╝');

  if (result.trades.length >= 5) {
    var sorted = List<BacktestTrade>.from(result.trades)..sort((a, b) => b.realizedPnl.compareTo(a.realizedPnl));
    print('\n── Top 5 Trades ───────────────────────────────────────────');
    for (int i = 0; i < min(5, sorted.length); i++) {
      var t = sorted[i];
      print('  #${t.id} ${t.direction == TradeDirection.long ? "LONG" : "SHORT"} pnl=+${t.realizedPnl.toStringAsFixed(4)} (${t.pnlPercent.toStringAsFixed(2)}%)');
    }
    print('\n── Bottom 5 Trades ────────────────────────────────────────');
    for (int i = sorted.length - 1; i >= max(0, sorted.length - 5); i--) {
      var t = sorted[i];
      print('  #${t.id} ${t.direction == TradeDirection.long ? "LONG" : "SHORT"} pnl=${t.realizedPnl.toStringAsFixed(4)} (${t.pnlPercent.toStringAsFixed(2)}%)');
    }
  }

  var longs = result.trades.where((t) => t.direction == TradeDirection.long).toList();
  var shorts = result.trades.where((t) => t.direction == TradeDirection.short).toList();
  double longPnl = longs.fold(0.0, (s, t) => s + t.realizedPnl);
  double shortPnl = shorts.fold(0.0, (s, t) => s + t.realizedPnl);
  int longWins = longs.where((t) => t.realizedPnl > 0).length;
  int shortWins = shorts.where((t) => t.realizedPnl > 0).length;

  print('\n── Direction Breakdown ────────────────────────────────────');
  print('  LONG:  ${longs.length} trades, ${longWins} wins (${longs.isNotEmpty ? (longWins / longs.length * 100).toStringAsFixed(1) : "0"}%), PnL: \$${longPnl.toStringAsFixed(2)}');
  print('  SHORT: ${shorts.length} trades, ${shortWins} wins (${shorts.isNotEmpty ? (shortWins / shorts.length * 100).toStringAsFixed(1) : "0"}%), PnL: \$${shortPnl.toStringAsFixed(2)}');
}

void exportResultsCSV(BacktestResult result, String outPath) {
  StringBuffer sb = StringBuffer();
  sb.writeln('trade_id,direction,entry_time,entry_bar,entry_price,exit_time,exit_bar,exit_price,qty,realized_pnl,pnl_pct,status,sr_zone');
  for (var t in result.trades) {
    sb.writeln('${t.id},'
        '${t.direction == TradeDirection.long ? "LONG" : "SHORT"},'
        '${t.entryTime.toIso8601String()},'
        '${t.entryBar},'
        '${t.entryPrice},'
        '${t.exitTime?.toIso8601String() ?? ""},'
        '${t.exitBar ?? ""},'
        '${t.exitPrice ?? ""},'
        '${t.totalQty},'
        '${t.realizedPnl},'
        '${t.pnlPercent},'
        '${t.status.name},'
        '${t.srZoneInfo}');
  }

  sb.writeln('\n# Equity Curve');
  sb.writeln('bar_index,equity');
  for (int i = 0; i < result.equityCurve.length; i++) {
    sb.writeln('$i,${result.equityCurve[i]}');
  }

  File(outPath).writeAsStringSync(sb.toString());
  print('\n  Results exported to: $outPath');
}

// ============================================================================
// MAIN
// ============================================================================

void main(List<String> args) {
  String csvPath = '/Users/ayush/StudioProjects/msr_bot/lib/SOLUSDT5m.csv';
  double balance = 10000.0;
  double riskPct = 2.0;
  bool verbose = true;

  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--csv' && i + 1 < args.length) csvPath = args[++i];
    if (args[i] == '--balance' && i + 1 < args.length) balance = double.parse(args[++i]);
    if (args[i] == '--risk' && i + 1 < args.length) riskPct = double.parse(args[++i]);
    if (args[i] == '--quiet') verbose = false;
    if (args[i] == '--help') {
      print('Usage: dart run backtest.dart [options]');
      print('  --csv <path>       Path to CSV file (default: candles.csv)');
      print('  --balance <amt>    Initial balance (default: 10000)');
      print('  --risk <pct>       Position size % (default: 2.0)');
      print('  --quiet            Suppress trade-by-trade output');
      print('  --help             Show this help');
      print('\nCSV format: timestamp,open,high,low,close,volume');
      return;
    }
  }

  print('Loading candles from: $csvPath');
  List<Candle> candles = loadCandlesFromCSV(csvPath);
  print('Loaded ${candles.length} candles');
  if (candles.length < 50) {
    print('ERROR: Need at least 50 candles for backtesting');
    return;
  }
  print('Range: ${candles.first.time} → ${candles.last.time}');
  print('Price: ${candles.first.close.toStringAsFixed(4)} → ${candles.last.close.toStringAsFixed(4)}\n');

  final backtester = Backtester(
    initialBalance: balance,
    positionSizePct: riskPct,
    tp1AtrMultiplier: 1.0,
    atrPeriod: 14,
    verbose: verbose,
  );

  final result = backtester.run(candles);
  printReport(result);

  String outPath = csvPath.replaceAll('.csv', '_backtest_results.csv');
  exportResultsCSV(result, outPath);
}
