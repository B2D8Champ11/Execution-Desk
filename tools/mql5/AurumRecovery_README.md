# Aurum Recovery — safer XAUUSD grid EA

A clean-room MT5 Expert Advisor that reproduces the source EA's behaviour
(Black Dragon M5 trend + Stochastic M15 trigger, distance grid, martingale
sizing, basket take-profit) **plus the risk controls the original doesn't have.**
The original `.ex5` runs `SL_=0` — no stop-loss at all — which is the main danger
with any martingale. This replaces that with real kill-switches.

> ⚠️ **Not compiled or tested in this environment.** Compile in MetaEditor (F7)
> and validate in **Strategy Tester** on your broker/symbol before ANY live use.
> A martingale — even a capped one — can still lose the account in a strong trend.

## Install (this one is an Expert Advisor, not an indicator)

1. MT5 → **File → Open Data Folder** → put `AurumRecovery.mq5` in **`MQL5\Experts\`**.
2. MetaEditor → **F7** to compile → it appears in Navigator under *Expert Advisors*.
3. Drag onto a chart, tick **Allow Algo Trading**.

## Safety: original vs this replica

| Risk control | CONQUER original | Aurum Recovery |
|--------------|------------------|--------------|
| Hard stop-loss per trade | ❌ `SL_=0` (none) | ✅ `InpHardSLPoints` (default 300) |
| Basket money-stop (kills the whole cycle) | ❌ | ✅ `InpBasketMaxLoss` ($50) |
| Daily loss limit — money | ❌ | ✅ `InpDailyMaxLoss` ($100) |
| Daily loss limit — percent | ❌ | ✅ `InpDailyMaxPct` (5%) |
| Turn martingale OFF | ❌ | ✅ `InpMartingaleMode=false` |
| Lot cap | `MaxLot_=2.0` | `InpMaxLot=0.13` |
| Positions cap | 7 | `InpMaxPositions=6` |

Both daily limits are active at once — **whichever trips first** closes everything
and halts trading until the next day (auto-resets at day rollover).

## The two modes (`InpMartingaleMode`)

- **`true` (default) — capped grid:** the "safer replica". Starts 0.01, each averaging
  add ×1.89 up to the 0.13 cap, max 6 positions, basket closes at +$5 or is killed at
  −$50. This mirrors the original's recovery style but with a hard floor on the loss.
- **`false` — single-shot:** no grid at all. One 0.01 position at a time with the hard
  SL/TP. Much lower risk, but behaves nothing like the original (no averaging).

## Defaults (match your earlier request)

`InitialLot=0.01`, `Multiplier=1.89`, `MaxLot=0.13`, `MaxPositions=6`, signal inputs
mirror your `.set` (Stoch M15 7/1/2, 90/10; Black Dragon M5).

## Before trusting the entries

The entry trigger here is the **same inference** as `CONQUER_SignalProbe`. Confirm the
real rule first with the probe (flip `InpSigMode` until its arrows match the original
EA), then set the **same** `InpSigMode` / `InpRequireDragon` here so this EA enters
where the original does.

## Known simplifications

- Grid spacing (`NextDistance`) approximates the original's `Fix_Distance` /
  `Dynamic_distance_start` / `Distance_multiplier`; tune to taste.
- Basket P/L is measured per direction. If you run buys and sells at once, each side is
  managed independently.
- `InpUseRealDragon=true` + `InpDragonName` reads the actual Black Dragon indicator for
  an exact trend match; otherwise an EMA proxy is used.
