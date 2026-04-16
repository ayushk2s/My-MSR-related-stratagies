import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'model.dart';

// ============================================================================
// MODELS
// ============================================================================
//
// class Candle {
//   final DateTime time;
//   final double open;
//   final double high;
//   final double low;
//   final double close;
//   final double volume;
//   final int index;
//
//   Candle({
//     required this.time,
//     required this.open,
//     required this.high,
//     required this.low,
//     required this.close,
//     required this.volume,
//     required this.index,
//   });
//
//   @override
//   String toString() =>
//       '[${index}] ${time.toIso8601String()} O=${open.toStringAsFixed(2)} H=${high.toStringAsFixed(2)} L=${low.toStringAsFixed(2)} C=${close.toStringAsFixed(2)} V=${volume.toStringAsFixed(0)}';
// }

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
  String createdBy; // debug: what created this zone

  // Manipulation sub-zone
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
  }) : lineLeft = lineLeft ?? boxLeft,
       lineRight = lineRight ?? boxRight;

  bool get isActive => !b;

  @override
  String toString() {
    String type = isResistance ? 'RES' : 'SUP';
    String status = b ? 'BROKEN' : 'ACTIVE';
    String flags = '';
    if (t) flags += '[T]';
    if (r) flags += '[R]';
    if (l) flags += '[M]';
    return '$type $status $flags ${boxBottom.toStringAsFixed(2)}-${boxTop.toStringAsFixed(2)} line=${linePrice.toStringAsFixed(2)} bars($boxLeft→$boxRight) m=${m.toStringAsFixed(6)} via:$createdBy';
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

enum SignalType {
  bullishBreakout,
  bearishBreakout,
  testResistance,
  testSupport,
  retestResistance,
  retestSupport,
  rejectionBullish,
  rejectionBearish,
}

class Signal {
  final SignalType type;
  final int barIndex;
  final DateTime time;
  final double price;
  final String description;

  Signal({
    required this.type,
    required this.barIndex,
    required this.time,
    required this.price,
    required this.description,
  });

  @override
  String toString() =>
      '[${type.name}] bar=$barIndex ${time.toIso8601String()} price=${price.toStringAsFixed(2)} — $description';
}

// ============================================================================
// INDICATOR
// ============================================================================

class SupportResistanceIndicator {
  final int detectionLength;
  final double srMargin;
  final bool avoidFBO;
  final bool checkHist;
  final bool showManip;
  final double manipMargin;
  final bool debug;

  SupportResistanceIndicator({
    this.detectionLength = 15,
    this.srMargin = 2.0,
    this.avoidFBO = true,
    this.checkHist = true,
    this.showManip = true,
    this.manipMargin = 1.3,
    this.debug = false,
  });

  late List<SRZone> R;
  late List<SRZone> S;
  late PivotPoint pp;
  late int mss;
  late List<Signal> signals;
  late List<double> _highs;
  late List<double> _lows;
  late List<double> _atr;
  late List<double> _vSMA;

  void _dbg(String msg) {
    if (debug) print("  [DBG] $msg");
  }

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

  ({List<SRZone> resistance, List<SRZone> support, List<Signal> signals})
  calculate(List<Candle> candles) {
    int srLN = detectionLength;
    int n = candles.length;
    if (n < srLN * 2 + 17) {
      print('Need at least ${srLN * 2 + 17} candles, got $n');
      return (resistance: [], support: [], signals: []);
    }

    R = [];
    S = [];
    pp = PivotPoint();
    mss = 0;
    signals = [];

    _highs = candles.map((c) => c.high).toList();
    _lows = candles.map((c) => c.low).toList();
    _atr = _calcATR(candles, 17);
    _vSMA = _calcVolSMA(candles, 17);

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
      DateTime prevTime = i > 0 ? candles[i - 1].time : candles[i].time;

      double prevAtr = (i > 0 && i - 1 < _atr.length) ? _atr[i - 1] : 0;
      double prevVSMA = (i > 0 && i - 1 < _vSMA.length) ? _vSMA[i - 1] : 0;
      bool prevIsLLS =
          prevAtr > 0 && (prevL - min(prevO, prevC)).abs() >= 1.618 * prevAtr;
      bool prevIsLUS =
          prevAtr > 0 && (prevH - max(prevO, prevC)).abs() >= 1.618 * prevAtr;
      bool prevIsHV = prevVSMA > 0 && prevV >= 1.618 * prevVSMA;

      // --- PIVOT HIGH ---
      int phIdx = i - srLN;
      if (phIdx >= srLN && phIdx + srLN < n) {
        double? ppH = _pivotHigh(candles, phIdx, srLN);
        if (ppH != null) {
          _dbg(
            "PIVOT HIGH at bar $phIdx price=${ppH.toStringAsFixed(2)} (confirmed at bar $i = ${candles[i].time})",
          );
          _onPivotHigh(candles, ppH, phIdx, i, srLN);
        }
      }

      // Market structure shift
      if (pp.h > 0 && i > 0) {
        if (prevC > pp.h && curC > pp.h && !pp.hx) {
          pp.hx = true;
          mss = 1;
        }
      }

      // --- PIVOT LOW ---
      int plIdx = i - srLN;
      if (plIdx >= srLN && plIdx + srLN < n) {
        double? ppL = _pivotLow(candles, plIdx, srLN);
        if (ppL != null) {
          _dbg(
            "PIVOT LOW at bar $plIdx price=${ppL.toStringAsFixed(2)} (confirmed at bar $i = ${candles[i].time})",
          );
          _onPivotLow(candles, ppL, plIdx, i, srLN);
        }
      }

      if (pp.l < double.maxFinite && i > 0) {
        if (prevC < pp.l && curC < pp.l && !pp.lx) {
          pp.lx = true;
          mss = -1;
        }
      }

      // --- SIGNALS ---
      if (R.isNotEmpty)
        _resistanceSignals(candles, i, srLN, prevIsLLS, prevIsHV);
      if (R.length > 1 && checkHist)
        _historicalResistanceSignals(candles, i, srLN);
      if (S.length > 1) _supportSignals(candles, i, srLN, prevIsLUS, prevIsHV);
      if (S.length > 2 && checkHist)
        _historicalSupportSignals(candles, i, srLN);
    }

    return (resistance: R, support: S, signals: signals);
  }

  // --- Pivot detection ---
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

  // --- Pivot High Processing ---
  void _onPivotHigh(
    List<Candle> candles,
    double ppH,
    int pivotIdx,
    int curIdx,
    int srLN,
  ) {
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

      bool outsideLR =
          ppH < lR.boxBottom * (1 - lR.m * 0.17 * srMargin) ||
          ppH > lR.boxTop * (1 + lR.m * 0.17 * srMargin);

      if (outsideLR) {
        if (pp.x < lR.boxLeft &&
            pp.x + srLN > lR.boxLeft &&
            curC < lR.boxBottom) {
          _dbg("  -> Overlap guard, skipping");
        } else {
          bool outsideLRt =
              ppH < lRt.boxBottom * (1 - lRt.m * 0.17 * srMargin) ||
              ppH > lRt.boxTop * (1 + lRt.m * 0.17 * srMargin);
          if (outsideLRt) {
            _dbg(
              "  -> NEW R zone: ${newBot.toStringAsFixed(2)}-${newTop.toStringAsFixed(2)} m=${mf.toStringAsFixed(6)}",
            );
            R.insert(
              0,
              SRZone(
                boxTop: newTop,
                boxBottom: newBot,
                boxLeft: pivotIdx,
                boxRight: curIdx,
                linePrice: ppH,
                m: mf,
                isResistance: true,
                createdBy: 'pivotH',
              ),
            );
            if (S.isNotEmpty) S[0].t = false;
          } else {
            _dbg("  -> Extending R[1] (lRt)");
            lRt.boxRight = curIdx;
            lRt.lineRight = curIdx;
          }
        }
      } else {
        if (S.isEmpty || lR.boxTop != S[0].boxTop) {
          _dbg("  -> Extending R[0] (lR)");
          lR.boxRight = curIdx;
          lR.lineRight = curIdx;
        }
      }
    } else {
      _dbg(
        "  -> NEW R zone (first): ${newBot.toStringAsFixed(2)}-${newTop.toStringAsFixed(2)} m=${mf.toStringAsFixed(6)}",
      );
      R.insert(
        0,
        SRZone(
          boxTop: newTop,
          boxBottom: newBot,
          boxLeft: pivotIdx,
          boxRight: curIdx,
          linePrice: ppH,
          m: mf,
          isResistance: true,
          createdBy: 'pivotH',
        ),
      );
      if (S.isNotEmpty) S[0].t = false;
    }
  }

  // --- Pivot Low Processing ---
  void _onPivotLow(
    List<Candle> candles,
    double ppL,
    int pivotIdx,
    int curIdx,
    int srLN,
  ) {
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

      bool outsideLS =
          ppL < lS.boxBottom * (1 - lS.m * 0.17 * srMargin) ||
          ppL > lS.boxTop * (1 + lS.m * 0.17 * srMargin);

      if (outsideLS) {
        if (pp.x < lS.boxLeft && pp.x + srLN > lS.boxLeft && curC > lS.boxTop) {
          _dbg("  -> Overlap guard, skipping");
        } else {
          bool outsideLSt =
              ppL < lSt.boxBottom * (1 - lSt.m * 0.17 * srMargin) ||
              ppL > lSt.boxTop * (1 + lSt.m * 0.17 * srMargin);
          if (outsideLSt) {
            _dbg(
              "  -> NEW S zone: ${newBot.toStringAsFixed(2)}-${newTop.toStringAsFixed(2)} m=${mf.toStringAsFixed(6)}",
            );
            S.insert(
              0,
              SRZone(
                boxTop: newTop,
                boxBottom: newBot,
                boxLeft: pivotIdx,
                boxRight: curIdx,
                linePrice: ppL,
                m: mf,
                isResistance: false,
                createdBy: 'pivotL',
              ),
            );
            if (R.isNotEmpty) R[0].t = false;
          } else {
            _dbg("  -> Extending S[1] (lSt)");
            lSt.boxRight = curIdx;
            lSt.lineRight = curIdx;
          }
        }
      } else {
        if (R.isEmpty || lS.boxBottom != R[0].boxBottom) {
          _dbg("  -> Extending S[0] (lS)");
          lS.boxRight = curIdx;
          lS.lineRight = curIdx;
        }
      }
    } else {
      _dbg(
        "  -> NEW S zone (early): ${newBot.toStringAsFixed(2)}-${newTop.toStringAsFixed(2)} m=${mf.toStringAsFixed(6)}",
      );
      S.insert(
        0,
        SRZone(
          boxTop: newTop,
          boxBottom: newBot,
          boxLeft: pivotIdx,
          boxRight: curIdx,
          linePrice: ppL,
          m: mf,
          isResistance: false,
          createdBy: 'pivotL',
        ),
      );
      if (R.isNotEmpty) R[0].t = false;
    }
  }

  // --- Resistance Signals ---
  void _resistanceSignals(
    List<Candle> candles,
    int i,
    int srLN,
    bool prevIsLLS,
    bool prevIsHV,
  ) {
    SRZone lR = R[0];
    SRZone? lS = S.isNotEmpty ? S[0] : null;

    double curH = candles[i].high;
    double curC = candles[i].close;
    double prevH = i > 0 ? candles[i - 1].high : curH;
    double prevL = i > 0 ? candles[i - 1].low : candles[i].low;
    double prevC = i > 0 ? candles[i - 1].close : curC;
    double prevO = i > 0 ? candles[i - 1].open : candles[i].open;
    int prevI = i > 0 ? i - 1 : i;
    DateTime prevTime = i > 0 ? candles[i - 1].time : candles[i].time;

    if (avoidFBO && prevC > lR.boxTop * (1 + lR.m * 0.17) && !lR.b) {
      _dbg(
        "bar $i: BULLISH BREAKOUT of R[0] (top=${lR.boxTop.toStringAsFixed(2)}, threshold=${(lR.boxTop * (1 + lR.m * 0.17)).toStringAsFixed(2)}, prevC=${prevC.toStringAsFixed(2)})",
      );
      lR.boxRight = prevI;
      lR.lineRight = prevI;
      lR.b = true;
      lR.r = false;
      signals.add(
        Signal(
          type: SignalType.bullishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description: 'Bullish BO above R ${lR.linePrice.toStringAsFixed(2)}',
        ),
      );
      S.insert(
        0,
        SRZone(
          boxTop: lR.boxTop,
          boxBottom: lR.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lR.boxBottom,
          m: lR.m,
          isResistance: false,
          createdBy: 'breakoutR→S',
        ),
      );
    } else if (!avoidFBO && prevC > lR.boxTop && !lR.b) {
      lR.boxRight = prevI;
      lR.lineRight = prevI;
      lR.b = true;
      lR.r = false;
      signals.add(
        Signal(
          type: SignalType.bullishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description: 'Bullish BO above R ${lR.linePrice.toStringAsFixed(2)}',
        ),
      );
      S.insert(
        0,
        SRZone(
          boxTop: lR.boxTop,
          boxBottom: lR.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lR.boxBottom,
          m: lR.m,
          isResistance: false,
          createdBy: 'breakoutR→S',
        ),
      );
    } else if (lS != null &&
        lS.b &&
        prevO < lR.boxTop &&
        prevH > lR.boxBottom &&
        prevC < lR.boxBottom &&
        !lR.r &&
        prevI != lR.boxLeft) {
      _dbg("bar $i: RETEST of R[0]");
      lR.r = true;
      lR.boxRight = i;
      lR.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.retestResistance,
          barIndex: prevI,
          time: prevTime,
          price: prevH,
          description: 'Retest R ${lR.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (prevH > lR.boxBottom &&
        prevC < lR.boxTop &&
        curC < lR.boxTop &&
        !lR.t &&
        !lR.r &&
        !lR.b &&
        (lS == null || !lS.b) &&
        prevI != lR.boxLeft) {
      _dbg("bar $i: TEST of R[0]");
      lR.t = true;
      lR.boxRight = i;
      lR.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.testResistance,
          barIndex: prevI,
          time: prevTime,
          price: prevH,
          description: 'Test R ${lR.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (curH > lR.boxBottom * (1 - lR.m * 0.17) && !lR.b) {
      if (curH > lR.boxBottom) lR.boxRight = i;
      lR.lineRight = i;
    }

    if (prevIsLLS && prevIsHV) {
      signals.add(
        Signal(
          type: SignalType.rejectionBullish,
          barIndex: prevI,
          time: prevTime,
          price: prevL,
          description: 'Rejection of Lower Prices',
        ),
      );
    }
    if (showManip) _processManipR(lR, candles, i, srLN);
  }

  void _historicalResistanceSignals(List<Candle> candles, int i, int srLN) {
    SRZone lR = R[0];
    SRZone lRt = R[1];
    if (lR.boxTop == lRt.boxTop) return;
    SRZone? lSt = S.length > 1 ? S[1] : null;

    double curH = candles[i].high;
    double curC = candles[i].close;
    double prevH = i > 0 ? candles[i - 1].high : curH;
    double prevL = i > 0 ? candles[i - 1].low : candles[i].low;
    double prevC = i > 0 ? candles[i - 1].close : curC;
    double prevO = i > 0 ? candles[i - 1].open : candles[i].open;
    int prevI = i > 0 ? i - 1 : i;
    DateTime prevTime = i > 0 ? candles[i - 1].time : candles[i].time;

    if (avoidFBO && prevC > lRt.boxTop * (1 + lRt.m * 0.17) && !lRt.b) {
      _dbg(
        "bar $i: BULLISH BREAKOUT of hist R[1] (top=${lRt.boxTop.toStringAsFixed(2)})",
      );
      lRt.boxRight = prevI;
      lRt.lineRight = prevI;
      lRt.b = true;
      lRt.r = false;
      signals.add(
        Signal(
          type: SignalType.bullishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description:
              'Bullish BO above hist R ${lRt.linePrice.toStringAsFixed(2)}',
        ),
      );
      S.insert(
        0,
        SRZone(
          boxTop: lRt.boxTop,
          boxBottom: lRt.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lRt.boxBottom,
          m: lRt.m,
          isResistance: false,
          createdBy: 'breakoutHistR→S',
        ),
      );
    } else if (!avoidFBO && prevC > lRt.boxTop && !lRt.b) {
      lRt.boxRight = prevI;
      lRt.lineRight = prevI;
      lRt.b = true;
      lRt.r = false;
      signals.add(
        Signal(
          type: SignalType.bullishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description:
              'Bullish BO above hist R ${lRt.linePrice.toStringAsFixed(2)}',
        ),
      );
      S.insert(
        0,
        SRZone(
          boxTop: lRt.boxTop,
          boxBottom: lRt.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lRt.boxBottom,
          m: lRt.m,
          isResistance: false,
          createdBy: 'breakoutHistR→S',
        ),
      );
    } else if (lSt != null &&
        lSt.b &&
        prevO < lRt.boxTop &&
        prevH > lRt.boxBottom &&
        prevC < lRt.boxBottom &&
        !lRt.r &&
        prevI != lRt.boxLeft) {
      lRt.r = true;
      lRt.boxRight = i;
      lRt.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.retestResistance,
          barIndex: prevI,
          time: prevTime,
          price: prevH,
          description: 'Retest hist R ${lRt.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (prevH > lRt.boxBottom &&
        prevC < lRt.boxTop &&
        curC < lRt.boxTop &&
        !lRt.t &&
        !lRt.b &&
        (lSt == null || !lSt.b) &&
        prevI != lRt.boxLeft) {
      lRt.t = true;
      lRt.boxRight = i;
      lRt.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.testResistance,
          barIndex: prevI,
          time: prevTime,
          price: prevH,
          description: 'Test hist R ${lRt.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (curH > lRt.boxBottom * (1 - lRt.m * 0.17) && !lRt.b) {
      if (curH > lRt.boxBottom) lRt.boxRight = i;
      lRt.lineRight = i;
    }
    if (showManip) _processManipR(lRt, candles, i, srLN);
  }

  // --- Support Signals ---
  void _supportSignals(
    List<Candle> candles,
    int i,
    int srLN,
    bool prevIsLUS,
    bool prevIsHV,
  ) {
    SRZone lS = S[0];
    SRZone? lR = R.isNotEmpty ? R[0] : null;

    double curL = candles[i].low;
    double curC = candles[i].close;
    double prevH = i > 0 ? candles[i - 1].high : candles[i].high;
    double prevL = i > 0 ? candles[i - 1].low : curL;
    double prevC = i > 0 ? candles[i - 1].close : curC;
    double prevO = i > 0 ? candles[i - 1].open : candles[i].open;
    int prevI = i > 0 ? i - 1 : i;
    DateTime prevTime = i > 0 ? candles[i - 1].time : candles[i].time;

    // BEARISH BREAKOUT (FBO ON)
    if (avoidFBO && prevC < lS.boxBottom * (1 - lS.m * 0.17) && !lS.b) {
      _dbg(
        "bar $i: BEARISH BREAKOUT of S[0] (bot=${lS.boxBottom.toStringAsFixed(2)}, threshold=${(lS.boxBottom * (1 - lS.m * 0.17)).toStringAsFixed(2)}, prevC=${prevC.toStringAsFixed(2)})",
      );
      lS.boxRight = prevI;
      lS.lineRight = prevI;
      lS.b = true;
      lS.r = false;
      signals.add(
        Signal(
          type: SignalType.bearishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description: 'Bearish BO below S ${lS.linePrice.toStringAsFixed(2)}',
        ),
      );
      R.insert(
        0,
        SRZone(
          boxTop: lS.boxTop,
          boxBottom: lS.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lS.boxTop,
          m: lS.m,
          isResistance: true,
          createdBy: 'breakoutS→R',
        ),
      );
    }
    // BEARISH BREAKOUT (FBO OFF) — NOTE: separate `if` in Pine, not `else if`
    if (!avoidFBO && prevC < lS.boxBottom && !lS.b) {
      lS.boxRight = prevI;
      lS.lineRight = prevI;
      lS.b = true;
      lS.r = false;
      signals.add(
        Signal(
          type: SignalType.bearishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description: 'Bearish BO below S ${lS.linePrice.toStringAsFixed(2)}',
        ),
      );
      R.insert(
        0,
        SRZone(
          boxTop: lS.boxTop,
          boxBottom: lS.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lS.boxTop,
          m: lS.m,
          isResistance: true,
          createdBy: 'breakoutS→R',
        ),
      );
    }
    // RETEST
    else if (lR != null &&
        lR.b &&
        prevO > lS.boxBottom &&
        prevL < lS.boxTop &&
        prevC > lS.boxTop &&
        !lS.r &&
        prevI != lS.boxLeft) {
      _dbg("bar $i: RETEST of S[0]");
      lS.r = true;
      lS.boxRight = i;
      lS.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.retestSupport,
          barIndex: prevI,
          time: prevTime,
          price: prevL,
          description: 'Retest S ${lS.linePrice.toStringAsFixed(2)}',
        ),
      );
    }
    // TEST
    else if (prevL < lS.boxTop &&
        prevC > lS.boxBottom &&
        curC > lS.boxBottom &&
        !lS.t &&
        !lS.b &&
        (lR == null || !lR.b) &&
        prevI != lS.boxLeft) {
      _dbg("bar $i: TEST of S[0]");
      lS.t = true;
      lS.boxRight = i;
      lS.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.testSupport,
          barIndex: prevI,
          time: prevTime,
          price: prevL,
          description: 'Test S ${lS.linePrice.toStringAsFixed(2)}',
        ),
      );
    }
    // EXTEND
    else if (curL < lS.boxTop * (1 + lS.m * 0.17) && !lS.b) {
      if (curL < lS.boxTop) lS.boxRight = i;
      lS.lineRight = i;
    }

    if (prevIsLUS && prevIsHV) {
      signals.add(
        Signal(
          type: SignalType.rejectionBearish,
          barIndex: prevI,
          time: prevTime,
          price: prevH,
          description: 'Rejection of Higher Prices',
        ),
      );
    }
    if (showManip) _processManipS(lS, candles, i, srLN);
  }

  void _historicalSupportSignals(List<Candle> candles, int i, int srLN) {
    SRZone lS = S[0];
    SRZone lSt = S[1];
    if (lS.boxBottom == lSt.boxBottom) return;
    SRZone? lRt = R.length > 1 ? R[1] : null;

    double curL = candles[i].low;
    double curC = candles[i].close;
    double prevH = i > 0 ? candles[i - 1].high : candles[i].high;
    double prevL = i > 0 ? candles[i - 1].low : curL;
    double prevC = i > 0 ? candles[i - 1].close : curC;
    double prevO = i > 0 ? candles[i - 1].open : candles[i].open;
    int prevI = i > 0 ? i - 1 : i;
    DateTime prevTime = i > 0 ? candles[i - 1].time : candles[i].time;

    if (avoidFBO && prevC < lSt.boxBottom * (1 - lSt.m * 0.17) && !lSt.b) {
      _dbg(
        "bar $i: BEARISH BREAKOUT of hist S[1] (bot=${lSt.boxBottom.toStringAsFixed(2)})",
      );
      lSt.boxRight = prevI;
      lSt.lineRight = prevI;
      lSt.b = true;
      lSt.r = false;
      signals.add(
        Signal(
          type: SignalType.bearishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description:
              'Bearish BO below hist S ${lSt.linePrice.toStringAsFixed(2)}',
        ),
      );
      R.insert(
        0,
        SRZone(
          boxTop: lSt.boxTop,
          boxBottom: lSt.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lSt.boxTop,
          m: lSt.m,
          isResistance: true,
          createdBy: 'breakoutHistS→R',
        ),
      );
    } else if (!avoidFBO && prevC < lSt.boxBottom && !lSt.b) {
      lSt.boxRight = prevI;
      lSt.lineRight = prevI;
      lSt.b = true;
      lSt.r = false;
      signals.add(
        Signal(
          type: SignalType.bearishBreakout,
          barIndex: prevI,
          time: prevTime,
          price: prevC,
          description:
              'Bearish BO below hist S ${lSt.linePrice.toStringAsFixed(2)}',
        ),
      );
      R.insert(
        0,
        SRZone(
          boxTop: lSt.boxTop,
          boxBottom: lSt.boxBottom,
          boxLeft: prevI,
          boxRight: i + 1,
          linePrice: lSt.boxTop,
          m: lSt.m,
          isResistance: true,
          createdBy: 'breakoutHistS→R',
        ),
      );
    } else if (lRt != null &&
        lRt.b &&
        prevO > lSt.boxBottom &&
        prevL < lSt.boxTop &&
        prevC > lSt.boxTop &&
        !lSt.r &&
        prevI != lSt.boxLeft) {
      lSt.r = true;
      lSt.boxRight = i;
      lSt.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.retestSupport,
          barIndex: prevI,
          time: prevTime,
          price: prevL,
          description: 'Retest hist S ${lSt.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (prevL < lSt.boxTop &&
        prevC > lSt.boxBottom &&
        curC > lSt.boxBottom &&
        !lSt.t &&
        !lSt.b &&
        (lRt == null || !lRt.b) &&
        prevI != lSt.boxLeft) {
      lSt.t = true;
      lSt.boxRight = i;
      lSt.lineRight = i;
      signals.add(
        Signal(
          type: SignalType.testSupport,
          barIndex: prevI,
          time: prevTime,
          price: prevL,
          description: 'Test hist S ${lSt.linePrice.toStringAsFixed(2)}',
        ),
      );
    } else if (curL < lSt.boxTop * (1 + lSt.m * 0.17) && !lSt.b) {
      if (curL < lSt.boxTop) lSt.boxRight = i;
      lSt.lineRight = i;
    }
    if (showManip) _processManipS(lSt, candles, i, srLN);
  }

  // --- Manipulation ---
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
    } else if (curH > zone.boxTop &&
        curC <= ub &&
        zone.l &&
        i == zone.boxRight) {
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
    } else if (curL < zone.boxBottom &&
        curC >= lb &&
        zone.l &&
        i == zone.boxRight) {
      zone.lqRight = i + 1;
      zone.lqBottom = max(min(curL, zone.lqBottom), lb);
    } else if (zone.l && (curC <= lb || curC > zone.boxTop)) {
      zone.l = false;
    }
  }

  // --- Technical calcs ---
  List<double> _calcATR(List<Candle> candles, int period) {
    int n = candles.length;
    List<double> tr = List.filled(n, 0.0);
    List<double> atr = List.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      if (i == 0) {
        tr[i] = candles[i].high - candles[i].low;
      } else {
        tr[i] = max(
          candles[i].high - candles[i].low,
          max(
            (candles[i].high - candles[i - 1].close).abs(),
            (candles[i].low - candles[i - 1].close).abs(),
          ),
        );
      }
    }
    double sum = 0;
    for (int i = 0; i < min(period, n); i++) sum += tr[i];
    if (period <= n) atr[period - 1] = sum / period;
    for (int i = period; i < n; i++)
      atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period;
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
// API FETCH
// ============================================================================

Future<List<Candle>> fetchMexcCandles({
  required String symbol,
  String interval = "Min5",
  int limit = 1000,
  required int offset,
}) async {
  final intervalSeconds = {
    "Min1": 60,
    "Min5": 300,
    "Min15": 900,
    "Min30": 1800,
    "Min60": 3600,
  };
  if (!intervalSeconds.containsKey(interval))
    throw Exception("Unsupported interval: $interval");
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final step = intervalSeconds[interval]!;
  final end = now - (offset * step);
  final start = end - (limit * step);
  final url =
      'https://contract.mexc.com/api/v1/contract/kline/$symbol?interval=$interval&start=$start&end=$end';
  print("Fetching: $url");
  final response = await http.get(Uri.parse(url));
  if (response.statusCode == 200) {
    final body = jsonDecode(response.body);
    if (body["success"] == true && body["data"] != null) {
      final data = body["data"];
      final times = List<int>.from(data["time"]);
      final opens = List<double>.from(data["open"].map((e) => e.toDouble()));
      final highs = List<double>.from(data["high"].map((e) => e.toDouble()));
      final lows = List<double>.from(data["low"].map((e) => e.toDouble()));
      final closes = List<double>.from(data["close"].map((e) => e.toDouble()));
      final vols = List<double>.from(data["vol"].map((e) => e.toDouble()));
      return List.generate(
        times.length,
        (i) => Candle(
          DateTime.fromMillisecondsSinceEpoch(times[i] * 1000, isUtc: true),
          opens[i],
          highs[i],
          lows[i],
          closes[i],
          vols[i],
          i,
        ),
      );
    } else {
      throw Exception("Invalid response: $body");
    }
  } else {
    throw Exception('Fetch failed: ${response.statusCode}');
  }
}

// ============================================================================
// MAIN — with data validation
// ============================================================================

void main() async {
  try {
    print("=== Fetching Candles ===");
    List<Candle> candles = await fetchMexcCandles(
      symbol: 'SOL_USDT',
      interval: 'Min5',
      limit: 1000,
      offset: 92
    );
    print("Fetched ${candles.length} candles.");
    print("First: ${candles.first}");
    print("Last:  ${candles.last}");

    // Print some candles around the area visible in the screenshot
    // The screenshot shows time around 20:00-21:00 on Feb 20 with the big spike to ~1980
    print("\n=== CANDLE DATA SAMPLE (look for the ~1980 spike) ===");
    for (var c in candles) {
      if (c.high > 1975) {
        print("  $c");
      }
    }

    print("\n=== Running Indicator (debug=true) ===");
    final indicator = SupportResistanceIndicator(
      detectionLength: 15,
      srMargin: 2.0,
      avoidFBO: true,
      checkHist: true,
      showManip: true,
      manipMargin: 1.3,
      debug: true,
    );

    final result = indicator.calculate(candles);

    print("\n\n--- ALL R ZONES ---");
    for (int idx = 0; idx < result.resistance.length; idx++) {
      print("  R[$idx] ${result.resistance[idx]}");
    }
    print("\n--- ALL S ZONES ---");
    for (int idx = 0; idx < result.support.length; idx++) {
      print("  S[$idx] ${result.support[idx]}");
    }

    print("\n--- ACTIVE NEAR PRICE (1950-1990 range) ---");
    double priceRef = candles.last.close;
    print("Current price: ${priceRef.toStringAsFixed(2)}");

    print("\n  Active R zones near price:");
    for (var z in result.resistance) {
      if (z.isActive &&
          z.boxBottom < priceRef + 30 &&
          z.boxTop > priceRef - 30) {
        print("    $z");
      }
    }
    print("\n  Active S zones near price:");
    for (var z in result.support) {
      if (z.isActive &&
          z.boxBottom < priceRef + 30 &&
          z.boxTop > priceRef - 30) {
        print("    $z");
      }
    }

    print("\n--- SIGNALS (last 25) ---");
    int start = result.signals.length > 25 ? result.signals.length - 25 : 0;
    for (int idx = start; idx < result.signals.length; idx++) {
      print("  ${result.signals[idx]}");
    }

    print("\n=== Summary ===");
    int rAct = result.resistance.where((z) => z.isActive).length;
    int sAct = result.support.where((z) => z.isActive).length;
    print("R: ${result.resistance.length} total, $rAct active");
    print("S: ${result.support.length} total, $sAct active");
    print("Signals: ${result.signals.length}");
  } catch (e, st) {
    print("Error: $e\n$st");
  }
}
