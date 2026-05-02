# MSR — Multi-Strategy Crypto Futures Trading Bot

A Dart-based algorithmic trading bot for cryptocurrency perpetual futures markets. Supports **Asterdex** and **MEXC** exchanges with a complete backtesting, walk-forward validation, and live execution pipeline.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Strategies](#strategies)
- [Indicators](#indicators)
- [Project Structure](#project-structure)
- [Setup](#setup)
- [Running the Bot](#running-the-bot)
- [Backtesting](#backtesting)
- [Configuration Reference](#configuration-reference)
- [Security](#security)
- [Dependencies](#dependencies)

---

## Overview

MSR is a futures trading system built on top of two custom indicators — the **SFI (Supertrend-style Follower Indicator)** and **SR Zone detection** — combined with a suite of standard technical filters (RSI, ADX, MACD, Bollinger Bands, OBV, EMA200).

Key capabilities:

- Live multi-asset trading with automatic position management
- DCA (Dollar Cost Averaging) order grid on adverse moves
- Dynamic trailing stop-loss via SFI upLine/dnLine
- Multi-target partial take-profits (ATR-based)
- Full backtesting engine with realistic cost modelling
- Walk-forward out-of-sample (OOS) validation (70% IS / 30% OOS split)
- 26-strategy parameter sweep for systematic optimisation

---

## Architecture

```
bin/
├── main.dart                   ← Live multi-asset bot (Asterdex)
├── checking_main.dart          ← Single-symbol live bot variant
├── model.dart                  ← Candle + domain models
├── sf.dart                     ← SFI indicator engine
├── support_resistance_2.dart   ← SR zone detection
│
├── msr_mexc/                   ← MEXC exchange integration
│   ├── account_data.dart       ← Balance + position queries
│   ├── fetch_candle_data.dart  ← OHLCV data fetcher
│   ├── future_trade.dart       ← Order placement (via local proxy)
│   └── msr_bot.dart            ← MEXC bot (archived)
│
├── msr_asterdex/               ← Asterdex exchange integration
│   ├── account_data.dart       ← Balance, positions, leverage
│   ├── fetch_candle_data.dart  ← OHLCV data fetcher
│   ├── future_trade.dart       ← Asterdex order functions
│   ├── aster_function.dart     ← Core trade execution
│   └── aster_recursive_trade_function.dart
│
├── msr_upgrading/              ← Strategy research & backtesting
│   ├── walk_forward_validation_v5.dart  ← Latest WFV runner
│   ├── backtest_strategy_v8.dart
│   └── v9.dart / v10.dart      ← Strategy hunt sweeps
│
└── new_algo_with_sr/           ← SR breakout strategy series
    ├── grid_sr_backtest_v7.dart ← Latest SR breakout backtest
    └── strategy_hunt_4.dart
```

---

## Strategies

### 1. SFI Trend-Follow (Live Bot — `main.dart`)

Entry on SFI direction flip confirmed by SR zone context. Exits via SFI trailing stop or layered ATR-based take-profit targets.

- **Long**: SFI flips bullish inside or above a support zone
- **Short**: SFI flips bearish inside or below a resistance zone
- **Take-profits**: 5 levels at ATR × [1, 4.5, 7, 9, 11]
- **Stop-loss**: SFI trailing line (upLine for longs, dnLine for shorts)

### 2. SR Zone Breakout (Backtest — `grid_sr_backtest_v7.dart`)

Trades confirmed breakouts through Support/Resistance channels.

- **Long**: candle closes above resistance → enter on next bar's open
- **Short**: candle closes below support → enter on next bar's open
- **Target**: channel width measured move
- **Stop-loss**: tight (0.3% beyond broken level) or wide (far edge of channel)
- Optional SFI trend filter: long only in uptrend, short only in downtrend

### 3. Multi-Indicator Strategy Hunt (`v9.dart` / `v10.dart`)

26-strategy parameter sweep combining:

| Code | Strategy |
|------|----------|
| S1 | SFI-10 baseline |
| S2 | SFI-14 |
| S3 | Donchian-40 breakout |
| S7 | ADX-Don40 (ADX > 20 filter) |
| S8 | RSI-SFI14 (RSI neutral zone 35–65) |
| S9 | Triple (SFI14 + Don40 + ADX) |
| S10 | MACD-SFI |
| S11 | Bollinger Band breakout |
| S12 | OBV-SFI14 |
| S13 | Full confluence |
| S14 | SFI14 + ATR trailing stop |
| S15 | Regime filter (EMA200 bias) |

### 4. MEXC DCA Bot (archived — `msr_mexc/`)

RSI + SFI entry with DCA grid on adverse moves and hard stop-loss.

- Entry: RSI > 70 + SFI bullish (long), RSI < 30 + SFI bearish (short)
- DCA: 2 limit orders at mid and trail stop levels
- Take-profit: price move % target (scales with DCA depth)

---

## Indicators

| Indicator | Parameters | Description |
|-----------|-----------|-------------|
| SFI | period=10, multiplier=1.7 | ATR-based Supertrend-style trailing lines |
| RSI | period=14 | Relative Strength Index |
| ADX + DI+/DI− | period=14 | Trend strength (Wilder smoothing) |
| MACD | 12/26/9 | EMA crossover momentum |
| Bollinger Bands | 20 period, 2 std | Volatility envelope |
| OBV + EMA | OBV-EMA=20 | Volume trend |
| EMA | period=200 | Long-term regime baseline |
| StochRSI | period=14, smooth=3 | RSI of RSI |
| Donchian | period=40 | Highest high / lowest low channel |
| True Range / ATR | Wilder | Volatility sizing for SL and targets |

---

## Project Structure

```
msr/
├── bin/                  ← Executables
├── lib/msr.dart          ← Library root
├── test/msr_test.dart    ← Unit tests
├── pubspec.yaml          ← Dependencies
├── SOLUSDT5m.csv         ← Sample OHLCV data (SOL/USDT 5-minute)
└── wf_results_v10/       ← Walk-forward output CSVs
    wf_results_v11/
```

---

## Setup

### Prerequisites

- [Dart SDK](https://dart.dev/get-dart) ≥ 3.10.4

### Install

```bash
git clone <your-repo-url>
cd msr
dart pub get
```

### API Credentials

**Never commit real API keys.** Set your credentials directly in the `main()` function of the bot file you want to run:

**Asterdex** (`bin/main.dart`, `bin/checking_main.dart`):
```dart
const apiKey    = 'YOUR_API_KEY_HERE';
const secretKey = 'YOUR_SECRET_KEY_HERE';
```

**MEXC** (`bin/msr_mexc/account_data.dart`):
```dart
static String apiKey    = 'YOUR_MEXC_API_KEY';
static String secretKey = 'YOUR_MEXC_SECRET_KEY';
```

> **Recommendation**: Load credentials from environment variables or a local `.env` file that is listed in `.gitignore`.

---

## Running the Bot

### Live Multi-Asset Bot (Asterdex)

Trades SOLUSDT, BNBUSDT, ETHUSDT simultaneously on 5-minute candles.

```bash
dart run bin/main.dart
```

Configure symbols, leverage, and position sizing in the `main()` function:

```dart
final symbols = ['SOLUSDT', 'BNBUSDT', 'ETHUSDT'];

final bots = symbols.map((sym) => TradingBot(BotConfig(
  apiKey:           apiKey,
  secretKey:        secretKey,
  symbol:           sym,
  interval:         '5m',
  candleLimit:      1000,
  leverage:         10,
  positionSizePct:  10.0,
  sfiPeriod:        10,
  sfiMultiplier:    1.7,
  srDetectionLength: 15,
  srMargin:         2.0,
))).toList();
```

### Single-Symbol Bot

```bash
dart run bin/checking_main.dart
```

---

## Backtesting

### SR Zone Breakout Backtest

```bash
dart run bin/new_algo_with_sr/grid_sr_backtest_v7.dart
```

Provide a CSV file of OHLCV data in the format:
```
timestamp,open,high,low,close,volume
```

### Strategy Sweep + Walk-Forward Validation

Runs all 26 strategy variants on a 70/30 in-sample/out-of-sample split and prints a ranked summary:

```bash
dart run bin/msr_upgrading/walk_forward_validation_v5.dart
```

Results are saved to `wf_results_v10/` and `wf_results_v11/`.

Strategies marked **✅** are profitable in **both** IS and OOS periods. Strategies marked **⚠️** are profitable in IS only (overfit).

### Key Backtest Parameters

| Parameter | Description |
|-----------|-------------|
| `slBuf` | Stop-loss buffer as % beyond broken level |
| `minBreakPct` | Minimum breakout distance to confirm signal |
| `maxChaseSlippage` | Skip entry if next open is already X% past signal |
| `fundingRate` | 0.01% per 8h (default) |
| `commission` | 0.025% blended taker (default) |
| `trailAtr` | ATR multiplier for trailing stop (0 = fixed SL) |

---

## Configuration Reference

### `BotConfig` fields

| Field | Default | Description |
|-------|---------|-------------|
| `symbol` | `'SOLUSDT'` | Trading pair |
| `interval` | `'5m'` | Candle timeframe |
| `candleLimit` | `1000` | Candles fetched per cycle |
| `leverage` | `10` | Position leverage |
| `positionSizePct` | `2.0` | % of balance per trade |
| `sfiPeriod` | `10` | SFI ATR period |
| `sfiMultiplier` | `1.7` | SFI ATR multiplier |
| `srDetectionLength` | `15` | Bars to detect SR swing points |
| `srMargin` | `2.0` | SR zone margin % |
| `loopInterval` | `5 min` | Bot cycle frequency |
| `candleOffset` | `0` | `>0` for historical replay |

---

## Security

- All API keys have been removed from source files and replaced with `YOUR_API_KEY_HERE` / `YOUR_SECRET_KEY_HERE` placeholders.
- Add a `.env` file or use environment variables to supply credentials at runtime.
- Add the following to `.gitignore`:

```
.env
*.env
config/secrets.dart
```

> If you previously committed API keys, rotate them immediately on your exchange dashboard.

---

## Dependencies

```yaml
dependencies:
  http: ^1.6.0      # HTTP client for REST API calls
  crypto: ^3.0.0    # HMAC-SHA256 request signing
  path: ^1.9.0      # File path utilities

dev_dependencies:
  lints: ^6.0.0
  test: ^1.25.6
```

Install with:

```bash
dart pub get
```

---

## Disclaimer

This software is for educational and research purposes only. Cryptocurrency futures trading carries significant financial risk including the loss of your entire investment. Use at your own risk. Past backtest performance does not guarantee future live results.
