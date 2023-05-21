# TRILLEX 10S BASIC — MT5 Scalping EA for XAUUSD

Multi-timeframe scalping Expert Advisor for MetaTrader 5, designed for XAUUSD.
Uses 3 EMA stack (5/20/40) + Parabolic SAR across M1 and M5 with a proprietary
10-second synthetic bar engine for ultra-fast signal generation (Insane Mode).

---

## Strategy Overview

- **Normal Mode** — Signals fire on new M1 bar close when M1 and M5 EMA/PSAR align
- **Insane Mode** — Signals fire on new 10-second synthetic bar close with fresh PSAR flip confirmed by EMA alignment on M1 and M5
- **Exits** — Position closed on PSAR reversal or EMA5 cross on the 10s bars, or on opposite signal

---

## Changes in This Version (Live-Ready Build)

### 1. Spread Filter Active by Default
`InpMaxSpreadPoints` default changed from `0` (disabled) to `30`.
The EA now skips entry ticks when spread exceeds the threshold, preventing entries during high-spread windows common in XAUUSD live and news conditions.

### 2. Safety Stop Loss Added
`InpStopLossPoints` default changed from `0` (no SL) to `200`.
Provides a hard stop as a safety net on every position. Core lot sizing and MM structure are untouched.

### 3. PSAR Confirmation Bars (New Parameter)
`InpPSARConfirmBars` (default `1`) requires the PSAR to hold its new direction for N additional bars after the flip before the signal is treated as valid.
Eliminates single-bar PSAR flips caused by real-tick noise that do not exist in synthetic backtesting ticks.

### 4. Mid-Price Synthetic Bars
Synthetic 5s and 10s bars now use `(bid + ask) / 2` instead of bid-only.
Prevents spread fluctuations from being misread as directional price moves in real tick mode.

---

## Recommended Settings for Live XAUUSD

| Parameter | Value |
|---|---|
| InpUseInsaneMode | true |
| InpInsaneRequireM5 | true |
| InpInsaneRequireFreshPSAR | true |
| InpPSARConfirmBars | 1 |
| InpMaxSpreadPoints | 30 |
| InpStopLossPoints | 200 |
| InpUseSessionFilter | true |
| InpSessionStartHour | 9 |
| InpSessionEndHour | 21 |

---

## Files

- `TRILLEX_10S_BASIC.mq5` — Full EA source, compile in MetaEditor and attach to XAUUSD M1 chart
<!-- updated: 2023-05-21-r01 -->
