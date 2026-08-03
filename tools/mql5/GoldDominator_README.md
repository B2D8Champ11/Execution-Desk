# Gold Dominator — safer XAUUSD grid EA

A clean-room MT5 Expert Advisor that reproduces the source EA's behaviour
(Black Dragon M5 trend + Stochastic M15 trigger, distance grid, martingale
sizing, basket take-profit) **plus the risk controls the original doesn't have.**
The original `.ex5` runs `SL_=0` — no stop-loss at all — which is the main danger
with any martingale. This replaces that with real kill-switches.

> ⚠️ **Not compiled or tested in this environment.** Compile in MetaEditor (F7)
> and validate in **Strategy Tester** on your broker/symbol before ANY live use.
> A martingale — even a capped one — can still lose the account in a strong trend.

## Install (this one is an Expert Advisor, not an indicator)

1. MT5 → **File → Open Data Folder** → put `GoldDominator.mq5` in **`MQL5\Experts\`**.
2. MetaEditor → **F7** to compile → it appears in Navigator under *Expert Advisors*.
3. Drag onto a chart, tick **Allow Algo Trading**.

## Safety: original vs this replica

| Risk control | CONQUER original | Gold Dominator |
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

## Entry modes (`InpEntryMode`) — test both

Analysis of 960 real CONQUER fills (live account, June) showed the source EA is a
**high-frequency M5 trend-scalper**: it enters on ~80% of M5 bars in the trend direction
(median 5.0 min between entries, ~40 trades/day), banks a small fixed profit (~130 pts) in
1–5 min, and uses martingale averaging only to rescue stuck legs. So there are two modes:

- **`ENTRY_M5_TREND_SCALP` (default)** — the faithful replica. Every M5 bar, if Black Dragon
  points a direction, open a fresh fixed-lot scalp with its own **TP (`InpScalpTPPoints`, 130)**
  and hard SL. The **stochastic is a filter** (won't buy when already ≥ Up_Level, won't sell
  when ≤ Down_Level), not the trigger. Trades often, like the real one.
- **`ENTRY_SIGNAL_CROSS`** — the earlier passive mode. Waits for a stochastic cross at 90/10;
  a handful of trades a day. Kept so you can compare.

**Both modes keep every safety feature** — hard SL, basket money-stop, daily money/percent
limits, equity halt, session/spread filters. In scalp mode the basket *take-profit* is off
(each trade carries its own TP); the basket *money-stop* and all daily limits stay active.

To test: run two charts (or two Strategy Tester passes) — same inputs, one on each
`InpEntryMode` — and compare. The Experts log prints the active mode on startup.

## Lot-multiplier auto-solver (`InpAutoMultiplier`)

Instead of guessing the multiplier, set your **start lot**, **max lot**, and **how many
positions** you want — the EA solves the multiplier so the last position lands exactly on
your max lot:

```
multiplier = (MaxLot / InitialLot) ^ (1 / (MaxPositions − 1))
```

`InpAutoMultiplier=true` (default) computes it at startup and **ignores** `InpMultiplier`.
The resulting ladder + total exposure are printed to the Experts log on init, e.g.:

```
Gold Dominator ladder | mult=1.670 (auto) | #1=0.01 #2=0.02 #3=0.03 #4=0.05 #5=0.08 #6=0.13 | total=0.32 lots
```

Worked examples for start 0.01 → max 0.13:

| Positions | Auto multiplier | Ladder (rounded) |
|-----------|-----------------|------------------|
| 5 | **1.90** (≈ your original 1.89) | 0.01 · 0.02 · 0.04 · 0.07 · 0.13 |
| 6 | **1.67** | 0.01 · 0.02 · 0.03 · 0.05 · 0.08 · 0.13 |
| 7 | **1.51** | 0.01 · 0.02 · 0.02 · 0.04 · 0.06 · 0.09 · 0.13 |

So more positions ⇒ smaller multiplier ⇒ gentler steps. To pin the exact 1.89 you had,
either set `MaxPositions=5`, or turn `InpAutoMultiplier=false` and use `InpMultiplier=1.89`.

## ATR-based hard stop (`InpUseATRStop`)

Instead of a fixed 300-point stop, size the hard SL from **volatility**, so it's wide in
fast markets and tight in quiet ones:

```
SL distance = InpATRMultiplier x ATR(InpATRTimeframe)   (floored by InpMinSLPoints)
```

- `InpUseATRStop = false` (default) → fixed `InpHardSLPoints`.
- `InpUseATRStop = true`, `InpATRTimeframe = D1`, `InpATRMultiplier = 1.0` → the stop is **one
  average daily range** away — a genuine *disaster brake* on stuck martingale legs (the original
  had none). Use a smaller multiplier (0.3–0.5) for a tighter scalp stop.
- Falls back to the fixed points if ATR data isn't ready yet, so it never opens with no stop.

The stop applies to every entry (first, scalp, and grid adds). Because ATR is in price, the
point distance auto-adjusts to your broker's gold digits.

### ATR take-profit (`InpUseATRTP`)

The scalp target can scale with volatility too. It uses its **own intraday timeframe**
(`InpATRTPTimeframe`, default M15) so the target stays scalp-sized — using the *daily* ATR
here makes the TP thousands of points away and it never fills:

```
TP distance = InpATRTPMultiplier x ATR(InpATRTPTimeframe)   (floored by InpMinTPPoints)
```

> **Trailing-stop fix (v1.01):** the trailing stop now only moves once a trade is in profit by
> more than `InpTrailDist`, and never locks a stop worse than break-even. With the old code,
> `InpTrailStart=0` + `InpTrailDist=100` pulled the stop to ~$1 above entry at break-even and
> noise-stopped almost every trade for a small loss. If you're on an older compile, set
> `InpUseTrailing=false` as an immediate workaround.

`InpUseATRTP = true` replaces the fixed `InpScalpTPPoints`. The **ratio of the two multipliers
sets your risk:reward**, independent of how volatile the day is:
- `InpATRMultiplier = 1.0`, `InpATRTPMultiplier = 0.25` → wide stop / small target (martingale style)
- `InpATRMultiplier = 0.5`, `InpATRTPMultiplier = 0.5` → 1:1 R:R that breathes with volatility (safer style)

## The three variants (run side by side)

Each is a separate file with a **unique Magic number**, so they never touch each other's trades:

| File | Magic | Session | ATR SL/TP | Purpose |
|------|-------|---------|-----------|---------|
| `GoldDominator`    | 16082020 | all day | off | V1 — baseline |
| `GoldDominator_V2` | 16082021 | 09:00–12:00 | off | session-tuned replica |
| `GoldDominator_V3` | 16082022 | 09:00–12:00 | **on** | volatility-adaptive (ATR stop + ATR TP) |

Put all three in `MQL5\Experts`, compile each (F7), and attach to separate charts to compare.

## Scaling to bigger accounts (`InpUseAutoLot`)

Set the strategy once for a reference balance, then let it scale to any account size.
One factor — `balance ÷ InpBalanceAnchor` — multiplies **both the lots and the dollar
safety limits together**, so risk stays proportional and behaviour is identical at every size.

- `InpUseAutoLot = false` (default) → uses the exact lots/limits you typed.
- `InpUseAutoLot = true` with `InpBalanceAnchor = 1000` → the 0.01/0.13 lots and $5/$50/$100
  limits are "per $1,000", and scale up from there:

| Account | Scale | Start lot | Max lot | Basket TP | Basket stop | Daily stop |
|---------|-------|-----------|---------|-----------|-------------|------------|
| $1,000  | 1×    | 0.01 | 0.13 | $5  | $50  | $100 |
| $10,000 | 10×   | 0.10 | 1.30 | $50 | $500 | $1,000 |
| $100,000| 100×  | 1.00 | 13.0 | $500| $5,000 | $10,000 |

The percent-based limit (`InpDailyMaxPct`, 5%) already scales on its own. The multiplier and
position count are unchanged — only the size scales. The startup log prints the applied scale,
e.g. `scale=10.00x (bal 10000) | ... | stops: TP 50 / basket 500 / daily 1000`.

> Scale is read from account **balance at attach time**. Re-attach (or restart) to pick up a
> new balance. Note that on a $100k account the martingale's *total* exposure scales up too —
> keep `InpBasketMaxLoss`/`InpDailyMaxPct` sensible, and always demo-test at the new size first.

## Defaults (match your earlier request)

`InitialLot=0.01`, `MaxLot=0.13`, `MaxPositions=6`, signal inputs mirror your `.set`
(Stoch M15 7/1/2, 90/10; Black Dragon M5). With auto-solve on, 6 positions ⇒ multiplier
≈ 1.67; set `MaxPositions=5` for the ≈1.89 you started with.

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
