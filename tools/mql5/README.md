# CONQUER Signal Probe

A **diagnostic MT5 indicator** to reverse-engineer the exact entry trigger of the
CONQUER EA (`CONQUER__EAEX5.ex5`). The `.ex5` is encrypted and cannot be
decompiled, so this recovers the rule **empirically**: it draws a BUY/SELL arrow
wherever a *candidate* rule fires, and you overlay it on the EA's real arrows in
Strategy Tester Visual Mode until they line up.

It does **not** trade. It only plots arrows and logs the indicator state.

## What it mirrors (from `fully_automated_stochastic.set`)

| Engine | Source in .set | Probe input |
|--------|----------------|-------------|
| Stochastic trigger | `TF_Stoh=15`, `KPeriod=7`, `DPeriod=1`, `Slowing=2`, `Up_Level=90`, `Down_Level=10` | `InpStochTF`, `InpK/D/Slowing`, `InpUp/DownLevel` |
| Black Dragon trend | `TF_DB=5` | `InpDragonTF` + proxy or real iCustom |

## Install

1. Copy `CONQUER_SignalProbe.mq5` into `MQL5/Indicators/` of your MT5 data folder
   (MT5 → File → Open Data Folder).
2. Open it in MetaEditor and press **F7** to compile. You should get
   `0 errors, 0 warnings` and a `CONQUER_SignalProbe.ex5` next to it.

## Test procedure (find the exact trigger)

1. MT5 → **View → Strategy Tester**. Select `CONQUER__EAEX5`, load your `.set`,
   pick the symbol/period you trade, tick **Visual mode**, and Start.
2. When the visual chart opens, drag **CONQUER_SignalProbe** onto it. Also drag
   the real **Black Dragon** indicator and a standard **Stochastic (7,1,2, 90/10)**
   on so you can eyeball them.
3. Compare the probe's arrows against the EA's arrows/entries:
   - **Arrows match** → that `InpSigMode` + `InpRequireDragon` combo is the rule.
   - **Probe fires but EA doesn't** → the real rule is stricter; try a different mode.
   - **EA fires but probe doesn't** → the real rule is looser; relax the gate.
4. Iterate through the three `InpSigMode` values and toggle `InpRequireDragon`
   until they align. The Experts log prints every probe signal with the K/D values
   so you can diff exact bars.

### Which hypotheses to try, in order

| `InpSigMode` | Candidate BUY rule (SELL symmetric) |
|--------------|-------------------------------------|
| `SIG_LEVEL`  | Stoch %K simply **below 10** |
| `SIG_CROSS`  | Stoch %K **crosses up through 10** (leaving oversold) — most common for this style |
| `SIG_KD`     | %K crosses %D while oversold (near-degenerate here since `DPeriod=1`) |

Toggle `InpRequireDragon` off to see if Black Dragon is even part of the entry, or
on to require the M5 trend to agree.

### Matching the Black Dragon line

- Best: set `InpUseRealDragon=true` and `InpDragonName="Black Dragon"` (the exact
  file name in `MQL5/Indicators`). Set `InpDragonBufUp/Dn` to the buffer indexes of
  its blue/red lines (check the indicator's Data Window — usually 0 and 1).
- If you don't have the indicator file, leave `InpUseRealDragon=false` and tune the
  EMA proxy (`InpDragonPeriod`, `InpDragonMode`) until the proxy's bull/bear flips
  visually match the real Dragon color changes.

## Limitations

- **Not compiled/tested here** — this repo has no MT5 toolchain. Compile in
  MetaEditor (F7) before use; it's written to compile clean, but you are the first
  to run it.
- Higher-timeframe values (M5/M15) **repaint** on the still-forming bar. Keep
  `InpOnlyClosedBars=true` while matching so you compare confirmed bars.
- The proxy is an approximation of Black Dragon; use `InpUseRealDragon` for exactness.
