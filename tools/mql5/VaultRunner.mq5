//+------------------------------------------------------------------+
//|                                              VaultRunner.mq5     |
//|   Vault Runner - prop-firm-challenge XAUUSD scalp/grid EA.       |
//|   (Same lineage as Gold Dominator, built for running The5ers-    |
//|   style evaluations - see the compliance mode below.)            |
//|                                                                  |
//|   Clean-room re-implementation of the source martingale grid EA. |
//|   The original ran with NO stop-loss (SL_=0). This reproduces its |
//|   *behaviour*                                                    |
//|   (Black Dragon M5 trend + Stochastic M15 trigger, distance grid, |
//|   martingale sizing, basket take-profit) but adds the risk        |
//|   controls the original lacks:                                    |
//|     - hard stop-loss on every position                            |
//|     - basket money-stop (kills the whole cycle at a max loss)     |
//|     - daily loss limit (money AND percent, whichever first)       |
//|     - equity drawdown kill-switch                                 |
//|     - MartingaleMode toggle: capped grid  <->  single-shot fixed  |
//|     - prop firm challenge compliance mode (InpChallengeMode):     |
//|       static account-wide floor, per-trade % risk cap, guaranteed |
//|       SL on every position, high-impact news blackout             |
//|                                                                  |
//|   NOTE: not compiled/tested in this environment. Compile in       |
//|   MetaEditor (F7) and validate in Strategy Tester before live.    |
//|   The exact entry trigger mirrors CONQUER_SignalProbe; confirm it |
//|   with that probe first, then set SigMode/RequireDragon to match. |
//+------------------------------------------------------------------+
#property copyright "Vault Runner - Execution Desk"
#property version   "3.10"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- candidate entry trigger (match to the EA via the probe first)
enum ENUM_SIGMODE
  {
   SIG_LEVEL = 0,   // Stoch %K simply beyond level
   SIG_CROSS = 1,   // %K crosses the level (leaving oversold/overbought)
   SIG_KD    = 2    // %K crosses %D while beyond the level
  };
enum ENUM_DRAGONMODE
  {
   DRAGON_SLOPE = 0, // EMA rising = bull
   DRAGON_PRICE = 1  // Close vs EMA
  };
enum ENUM_ENTRYMODE
  {
   ENTRY_SIGNAL_CROSS   = 0, // wait for a stochastic cross/level (passive, few trades/day)
   ENTRY_M5_TREND_SCALP = 1  // enter every M5 bar with the trend (like the real GoldScalper)
  };
enum ENUM_SRMODE
  {
   SR_DAILY_PIVOTS = 0,   // classic pivot P/S1/S2/S3/R1/R2/R3 from the prior day's H/L/C
   SR_SWING_LEVELS = 1    // recent swing highs/lows (fractal-style) over a lookback window
  };

//==================== SIGNAL INPUTS (mirror .set) ==================
input string          _s0            = "===== Signal ====="; // ---
input bool             InpDebugLog   = true;         // print WHY each bar's entry was skipped (Experts log)
input ENUM_ENTRYMODE  InpEntryMode   = ENTRY_M5_TREND_SCALP; // HOW it enters (test both)
input int             InpScalpTPPoints = 130;       // scalp mode: fixed TP per trade (points)
input int             InpMinBarsBetweenScalps = 3;  // fresh scalps: require this many InpDragonTF bars since the last one per direction (0 = every bar)
input bool            InpUsePriceCooldown = true;   // also skip a fresh scalp too close to where one just closed (ranging markets)
input int             InpPriceCooldownPts = 150;    // "too close" = within this many points of that recent close
input int             InpPriceCooldownMins = 20;    // how far back to look for a recent same-direction close
input ENUM_TIMEFRAMES InpStochTF     = PERIOD_M15;  // TF_Stoh
input int             InpK           = 7;           // KPeriod
input int             InpD           = 1;           // DPeriod
input int             InpSlowing     = 2;           // Slowing
input double          InpUpLevel     = 90;          // Up_Level
input double          InpDownLevel   = 10;          // Down_Level
input ENUM_SIGMODE    InpSigMode     = SIG_CROSS;   // trigger definition (confirm via probe)
input bool            InpRequireDragon = true;      // require Black Dragon trend to agree
input ENUM_TIMEFRAMES InpDragonTF    = PERIOD_M5;   // TF_DB
input bool            InpUseRealDragon = false;     // read real Black Dragon via iCustom
input string          InpDragonName  = "Black Dragon"; // iCustom name
input int             InpDragonBufUp = 0;           // iCustom up-line buffer
input int             InpDragonBufDn = 1;           // iCustom down-line buffer
input ENUM_DRAGONMODE InpDragonMode  = DRAGON_SLOPE;// proxy trend rule
input int             InpDragonPeriod= 20;          // proxy EMA period
input ENUM_MA_METHOD  InpDragonMethod= MODE_EMA;    // proxy MA method
input ENUM_APPLIED_PRICE InpDragonPrice = PRICE_CLOSE; // proxy MA price

input string          _sSR           = "----- Support/Resistance filter -----"; // ---
input bool            InpUseSRFilter = false;       // only enter near a pivot S/R zone
input ENUM_SRMODE     InpSRMode      = SR_SWING_LEVELS; // which levels to use (real higher-TF structure, not a daily formula)
input ENUM_TIMEFRAMES InpSRSwingTF   = PERIOD_H1;   // swing timeframe #1 - your higher-TF structure
input bool            InpSRUseTF2    = true;        // also combine a second swing timeframe (union, more levels = more trades)
input ENUM_TIMEFRAMES InpSRSwingTF2  = PERIOD_H4;   // swing timeframe #2 - combined with TF1, not an AND-gate
input int             InpSRZonePts   = 150;         // "near" = within this many points of a level
input bool            InpDrawSRLines = true;        // draw the levels on the chart (visual/debug)
input bool            InpUseSRStop   = false;       // place the hard SL just beyond the nearest S/R level
input int             InpSRStopBufferPts = 50;      // extra room beyond the level, so a touch isn't a break
input int             InpSRStopMaxPts    = 2000;    // ignore a level farther than this (falls back to ATR/fixed)
input int             InpSRMaxRetests    = 2;       // stop fading a level once it's rejected price this many times without breaking (0 = no limit)
input int             InpSRRetestLookback= 300;     // bars (on InpSRSwingTF) scanned when counting rejections

//==================== TRADE / SIZING ==============================
input string          _s1            = "===== Position sizing ====="; // ---
input bool            InpTradeBuy    = true;        // Flag_Trade_Buy_
input bool            InpTradeSell   = true;        // Flag_Trade_Sell_
input double          InpInitialLot  = 0.01;        // Lot_Init_ (start lot)
input bool            InpMartingaleMode = true;     // true = capped grid, false = single-shot fixed lot
input bool            InpAutoMultiplier = true;     // AUTO-SOLVE the multiplier from start/max/positions
input double          InpMultiplier  = 1.89;        // Martin_ (used only when AutoMultiplier=false)
input double          InpMaxLot      = 0.13;        // MaxLot_ (target lot at the last position)
input int             InpMaxPositions= 6;           // MaxOrders per direction
input long            InpMagic       = 16082030;    // Magic (unique per variant so they don't clash)
input string          InpComment     = "VaultRunner"; // order comment
input string          _s1b           = "----- Account scaling -----"; // ---
input bool            InpUseAutoLot  = false;       // scale lots & $ limits to account size
input double          InpBalanceAnchor = 1000;      // the balance the lots/limits above are set for

//==================== GRID DISTANCE ==============================
input string          _s2            = "===== Grid distance ====="; // ---
input int             InpFixDistance = 235;         // Fix_Distance (points between adds)
input int             InpDynStartPts = 335;         // Dynamic_distance_start (points)
input double          InpDistMult    = 1.35;        // Distance_multiplier

//==================== EXITS ======================================
input string          _s3            = "===== Exits ====="; // ---
input bool            InpUseBasketTPMoney = true;   // take-profit as a money target for the basket
input double          InpBasketTPMoney = 5.0;       // $ profit to close the whole basket
input int             InpTPPoints    = 100;         // fallback TP in points from avg entry (TP_)
input int             InpHardSLPoints= 300;         // fixed hard stop-loss per position (0 = none)
input bool            InpUseATRStop  = true;        // size the hard SL from ATR instead of fixed points
input ENUM_TIMEFRAMES InpATRTimeframe= PERIOD_D1;   // ATR timeframe ("of the day" = D1)
input int             InpATRPeriod   = 14;          // ATR period
input double          InpATRMultiplier = 1.0;       // SL distance = this x ATR (1.0 = one daily range)
input int             InpMinSLPoints = 50;          // floor so the ATR stop is never absurdly tight
input bool            InpUseATRTP    = true;        // size the scalp TP from ATR instead of fixed points
input ENUM_TIMEFRAMES InpATRTPTimeframe = PERIOD_M15; // ATR TF for the TP (intraday, so it's scalp-sized)
input double          InpATRTPMultiplier = 0.5;     // TP distance = this x ATR(InpATRTPTimeframe)
input int             InpMinTPPoints = 30;          // floor for the ATR take-profit
input bool            InpUseTrailing = true;        // trailing stop
input int             InpTrailStart  = 0;           // iTS
input int             InpTrailDist   = 100;         // iTD

//==================== SAFETY KILL-SWITCHES =======================
input string          _s4            = "===== Safety (both active) ====="; // ---
input bool            InpUseBasketMoneyStop = true; // close whole cycle at a max floating loss
input double          InpBasketMaxLoss = 50.0;      // $ max loss for one basket/cycle
input double          InpGridAddMaxLossPct = 60.0;  // block new grid adds once floating loss >= this % of BasketMaxLoss
input bool            InpUseDailyMoneyStop = true;  // halt for the day at a money loss
input double          InpDailyMaxLoss  = 100.0;     // $ daily loss limit
input bool            InpUseDailyPctStop = true;    // halt for the day at a % drawdown
input double          InpDailyMaxPct   = 5.0;       // % of day-start equity
input int             InpMaxSpreadPts  = 0;         // MaxSpred (0 = ignore)
input int             InpStartHour     = 9;         // Start_Hour (matches real EA: 09:00 server)
input int             InpEndHour       = 12;        // End_Hour   (real EA stops entries ~12:00)

//==================== PROP FIRM CHALLENGE COMPLIANCE =============
// Tuned for The5ers Bootcamp: 5% static account drawdown per step (4% once
// funded), mandatory visible SL on every position, 2% max risk per trade
// (default set to 1% here - half the ceiling, since a martingale grid stacks
// several "trades" worth of risk at once), no orders within 2min of high-
// impact news. Set InpChallengeMode=false to fall back to pre-challenge
// behaviour (only the existing basket/daily safety nets apply).
input string          _s5              = "===== Prop firm challenge compliance ====="; // ---
input bool            InpChallengeMode = true;      // master switch for everything in this section
input double          InpChallengeStartBalance = 5000; // set to THIS account's starting balance (5k/10k/20k...)
input double          InpChallengeMaxDDPct = 5.0;   // static account-wide loss limit (5% eval, 4% once funded)
input double          InpChallengeBufferPct = 0.5;  // close out this much % of start balance BEFORE the true floor
input double          InpMaxRiskPct    = 1.0;       // max % of balance risked on any single position/add
input int             InpForceSLFloorPts = 50;      // absolute floor - a position NEVER opens without an SL >= this
input bool            InpUseNewsFilter = true;      // block new orders around high-impact news
input string          InpNewsCurrency  = "USD";     // currency to watch (XAUUSD is USD-quoted)
input int             InpNewsBlockMinsBefore = 2;   // no new orders from this many minutes before...
input int             InpNewsBlockMinsAfter  = 2;   // ...to this many minutes after a qualifying event
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // block at/above this importance

//==================== STATE ======================================
int      hStoch  = INVALID_HANDLE;
int      hDragon = INVALID_HANDLE;
int      hCustom = INVALID_HANDLE;
int      hATR    = INVALID_HANDLE;   // ATR for the stop (InpATRTimeframe)
int      hATRtp  = INVALID_HANDLE;   // ATR for the TP  (InpATRTPTimeframe, intraday)
double   g_multiplier = 1.89;   // effective martingale multiplier (auto-solved or manual)
//--- effective, account-scaled risk values (= inputs x g_scale)
double   g_scale        = 1.0;  // balance / anchor  (1.0 when auto-lot off)
double   g_initLot      = 0.01;
double   g_maxLot       = 0.13;
double   g_basketTP     = 5.0;
double   g_basketMaxLoss= 50.0;
double   g_dailyMaxLoss = 100.0;
datetime g_lastBar = 0;
datetime g_lastScalpTime[2] = {0,0};   // [0]=last SELL fresh-scalp open time, [1]=last BUY (cooldown gate)
datetime g_day     = 0;
double   g_dayStartEquity = 0;
double   g_equityPeak     = 0;
bool     g_haltedToday    = false;
//--- challenge compliance state
double   g_challengeFloor  = 0.0;   // InpChallengeStartBalance x (1 - MaxDDPct/100), fixed for the account's life
bool     g_challengeHalted = false; // permanent (not daily) - once true, stays flat until manually reset
string   g_challengeHaltGV = "";    // GlobalVariable name used to persist the halt across restarts

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   hStoch = iStochastic(_Symbol, InpStochTF, InpK, InpD, InpSlowing, MODE_SMA, STO_LOWHIGH);
   if(hStoch == INVALID_HANDLE) { Print("Stoch handle failed"); return(INIT_FAILED); }

   if(InpUseATRStop)
     {
      hATR = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
      if(hATR == INVALID_HANDLE)
         Print("WARNING ATR(stop) handle failed - falling back to fixed SL points");
     }
   if(InpUseATRTP)
     {
      hATRtp = iATR(_Symbol, InpATRTPTimeframe, InpATRPeriod);
      if(hATRtp == INVALID_HANDLE)
         Print("WARNING ATR(tp) handle failed - falling back to fixed TP points");
     }

   if(InpUseRealDragon)
     {
      hCustom = iCustom(_Symbol, InpDragonTF, InpDragonName);
      if(hCustom == INVALID_HANDLE)
         Print("WARNING iCustom '", InpDragonName, "' not found - using EMA proxy");
     }
   if(hCustom == INVALID_HANDLE)
     {
      hDragon = iMA(_Symbol, InpDragonTF, InpDragonPeriod, 0, InpDragonMethod, InpDragonPrice);
      if(hDragon == INVALID_HANDLE) { Print("EMA proxy handle failed"); return(INIT_FAILED); }
     }

   //--- account scaling: one factor scales lots AND $ limits together, so the
   //    system behaves identically on any account size (percent limits already scale).
   g_scale = 1.0;
   if(InpUseAutoLot && InpBalanceAnchor > 0.0)
      g_scale = AccountInfoDouble(ACCOUNT_BALANCE) / InpBalanceAnchor;
   if(g_scale <= 0.0) g_scale = 1.0;
   g_initLot       = InpInitialLot   * g_scale;
   g_maxLot        = InpMaxLot        * g_scale;
   g_basketTP      = InpBasketTPMoney * g_scale;
   g_basketMaxLoss = InpBasketMaxLoss * g_scale;
   g_dailyMaxLoss  = InpDailyMaxLoss  * g_scale;

   //--- lot-multiplier auto-solver: pick the multiplier so position N == MaxLot
   g_multiplier = SolveMultiplier();
   PrintFormat("Vault Runner entry mode = %s",
               (InpEntryMode==ENTRY_M5_TREND_SCALP)
               ? StringFormat("M5 TREND SCALP (every %s bar, TP %d pts, stoch=filter)",
                              EnumToString(InpDragonTF), InpScalpTPPoints)
               : "SIGNAL CROSS (passive stochastic trigger)");
   if(InpUseSRFilter || InpUseSRStop)
      PrintFormat("Vault Runner S/R active | entry-filter=%s stop=%s | mode=%s TF1=%s%s zone=%dpts stopBuffer=%dpts stopMax=%dpts maxRetests=%d",
                  (InpUseSRFilter?"ON":"off"), (InpUseSRStop?"ON":"off"),
                  EnumToString(InpSRMode), EnumToString(InpSRSwingTF),
                  (InpSRUseTF2 ? " +TF2="+EnumToString(InpSRSwingTF2) : ""),
                  InpSRZonePts, InpSRStopBufferPts, InpSRStopMaxPts, InpSRMaxRetests);
   PrintLotLadder();

   g_day = DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak     = g_dayStartEquity;

   //--- prop firm challenge compliance: static account-wide floor, fixed once at start
   if(InpChallengeMode)
     {
      g_challengeFloor  = InpChallengeStartBalance * (1.0 - InpChallengeMaxDDPct/100.0);
      g_challengeHaltGV = StringFormat("VR_ChallengeHalt_%I64d_%s", InpMagic, _Symbol);
      g_challengeHalted = (GlobalVariableCheck(g_challengeHaltGV) && GlobalVariableGet(g_challengeHaltGV) > 0.5);
      PrintFormat("Challenge compliance ON | start=%.2f maxDD=%.1f%% -> static floor=%.2f (halt at floor+%.1f%% buffer) | maxRisk=%.1f%%/trade | forceSL>=%dpts | newsFilter=%s (%s, %dm/%dm, >=%s)",
                  InpChallengeStartBalance, InpChallengeMaxDDPct, g_challengeFloor, InpChallengeBufferPct,
                  InpMaxRiskPct, InpForceSLFloorPts,
                  (InpUseNewsFilter?"ON":"off"), InpNewsCurrency, InpNewsBlockMinsBefore, InpNewsBlockMinsAfter,
                  EnumToString(InpNewsMinImportance));
      if(g_challengeHalted)
         PrintFormat("Challenge halt flag already set from a previous run - staying flat. Only clear GlobalVariable '%s' if you're certain the floor was NOT actually breached (e.g. reusing this chart for a new account).",
                     g_challengeHaltGV);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Auto-solve the multiplier from start lot, max lot, position count |
//|   MaxLot = InitialLot * mult^(N-1)  ->  mult = (Max/Init)^(1/(N-1))|
//| Falls back to the manual InpMultiplier when auto is off or inputs  |
//| are degenerate.                                                    |
//+------------------------------------------------------------------+
double SolveMultiplier()
  {
   if(!InpAutoMultiplier)          return(InpMultiplier);
   if(InpMaxPositions<=1)          return(1.0);            // single-shot: no growth
   if(g_initLot<=0.0 || g_maxLot<=g_initLot) return(1.0);
   double m = MathPow(g_maxLot/g_initLot, 1.0/(InpMaxPositions-1)); // ratio same at any scale
   return(NormalizeDouble(m, 3));
  }

//+------------------------------------------------------------------+
//| Log the resulting lot ladder and total exposure at startup.       |
//+------------------------------------------------------------------+
void PrintLotLadder()
  {
   double lot=g_initLot, total=0;
   string line="";
   for(int n=1; n<=InpMaxPositions; n++)
     {
      double norm=NormalizeLot(InpMartingaleMode ? lot : g_initLot);
      total+=norm;
      line+=StringFormat("#%d=%.2f ", n, norm);
      lot*=g_multiplier;
     }
   PrintFormat("Vault Runner ladder | scale=%.2fx (bal %.0f) | mult=%.3f (%s) | %s| total=%.2f lots | stops: TP %.0f / basket %.0f / daily %.0f",
               g_scale, AccountInfoDouble(ACCOUNT_BALANCE), g_multiplier,
               (InpAutoMultiplier?"auto":"manual"), line, total,
               g_basketTP, g_basketMaxLoss, g_dailyMaxLoss);
  }

void OnDeinit(const int reason)
  {
   if(hStoch  != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hATR    != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hATRtp  != INVALID_HANDLE) IndicatorRelease(hATRtp);
   if(hDragon != INVALID_HANDLE) IndicatorRelease(hDragon);
   if(hCustom != INVALID_HANDLE) IndicatorRelease(hCustom);
   for(int i=0;i<20;i++) ObjectDelete(0, "SRLevel_"+IntegerToString(i));
  }

//+------------------------------------------------------------------+
datetime DayStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d); d.hour=0; d.min=0; d.sec=0;
   return(StructToTime(d));
  }

//+------------------------------------------------------------------+
//| Black Dragon state: +1 bull, -1 bear, 0 unknown                  |
//+------------------------------------------------------------------+
int DragonState()
  {
   if(hCustom != INVALID_HANDLE)
     {
      double up[1], dn[1];
      if(CopyBuffer(hCustom, InpDragonBufUp, 1, 1, up) < 1) return(0);
      if(CopyBuffer(hCustom, InpDragonBufDn, 1, 1, dn) < 1) return(0);
      bool upOn = (up[0] != EMPTY_VALUE && up[0] != 0.0);
      bool dnOn = (dn[0] != EMPTY_VALUE && dn[0] != 0.0);
      if(upOn && !dnOn) return(+1);
      if(dnOn && !upOn) return(-1);
      return(0);
     }
   double ema[2];                                   // [0]=older, [1]=newer (bar 1)
   if(CopyBuffer(hDragon, 0, 1, 2, ema) < 2) return(0);
   if(InpDragonMode == DRAGON_SLOPE)
      return(ema[1] > ema[0] ? +1 : (ema[1] < ema[0] ? -1 : 0));
   double cl[1];
   if(CopyClose(_Symbol, InpDragonTF, 1, 1, cl) < 1) return(0);
   return(cl[0] > ema[1] ? +1 : (cl[0] < ema[1] ? -1 : 0));
  }

//+------------------------------------------------------------------+
//| SUPPORT / RESISTANCE FILTER                                       |
//|                                                                    |
//| Purpose: the base entry (trend + stochastic-filter, every M5 bar)  |
//| is indiscriminate about WHERE it enters. This filter only lets a   |
//| buy through near a support level, and a sell through near a        |
//| resistance level - the same logic a discretionary trader uses      |
//| pivot/swing zones for. It changes nothing about sizing, exits, or  |
//| the martingale/safety code below - it's purely an extra entry gate.|
//+------------------------------------------------------------------+
double g_srLevels[16];     // pivots use 7; swing mode can hold up to ~7 per timeframe x 2 timeframes
int    g_srCount = 0;
datetime g_srCalcDay = 0;  // recompute once per new day

//+------------------------------------------------------------------+
//| Classic floor-trader pivots from the PRIOR completed daily bar.    |
//| P = (H+L+C)/3 ; R1/S1, R2/S2, R3/S3 per the standard formula.      |
//+------------------------------------------------------------------+
void ComputeDailyPivots()
  {
   g_srCount = 0;
   double h[1], l[1], c[1];
   if(CopyHigh (_Symbol, PERIOD_D1, 1, 1, h) < 1) return;
   if(CopyLow  (_Symbol, PERIOD_D1, 1, 1, l) < 1) return;
   if(CopyClose(_Symbol, PERIOD_D1, 1, 1, c) < 1) return;
   double H=h[0], L=l[0], C=c[0];
   double P = (H+L+C)/3.0;
   double R1 = 2*P-L,        S1 = 2*P-H;
   double R2 = P+(H-L),      S2 = P-(H-L);
   double R3 = H+2*(P-L),    S3 = L-2*(H-P);
   double lv[7] = {S3,S2,S1,P,R1,R2,R3};
   for(int i=0;i<7;i++) g_srLevels[i]=lv[i];
   g_srCount = 7;
  }

//+------------------------------------------------------------------+
//| Recent swing highs/lows (simple fractal: a bar whose high/low is   |
//| the extreme of its lookback-bar neighbourhood on each side) on ONE  |
//| timeframe, appended into g_srLevels[] starting at g_srCount. Real   |
//| swing points, not a formula off a single prior day.                 |
//+------------------------------------------------------------------+
void AppendSwingLevels(ENUM_TIMEFRAMES tf)
  {
   int lookback = 5;                 // bars each side to confirm a fractal
   int scanBars = 200;                // how far back to search for swings
   int cap = ArraySize(g_srLevels);
   int total = MathMin(scanBars, iBars(_Symbol, tf)-lookback*2-2);
   if(total <= 0) return;

   double hi[], lo[];
   if(CopyHigh(_Symbol, tf, 1, total+lookback*2, hi) < total) return;
   if(CopyLow (_Symbol, tf, 1, total+lookback*2, lo) < total) return;
   ArraySetAsSeries(hi, false);
   ArraySetAsSeries(lo, false);

   for(int i=lookback; i<total && g_srCount<cap; i++)
     {
      bool isHigh=true, isLow=true;
      for(int j=1;j<=lookback;j++)
        {
         if(hi[i] <= hi[i-j] || hi[i] <= hi[i+j]) isHigh=false;
         if(lo[i] >= lo[i-j] || lo[i] >= lo[i+j]) isLow=false;
        }
      if(isHigh && g_srCount<cap) g_srLevels[g_srCount++] = hi[i];
      if(isLow  && g_srCount<cap) g_srLevels[g_srCount++] = lo[i];
     }
  }

//+------------------------------------------------------------------+
//| Combines swing levels from TF1 and (optionally) TF2 into one       |
//| merged pool - a level from EITHER timeframe qualifies (union, not  |
//| an AND-gate), so adding a second timeframe means more coverage and |
//| more trade opportunities, not fewer.                               |
//+------------------------------------------------------------------+
void ComputeSwingLevels()
  {
   g_srCount = 0;
   AppendSwingLevels(InpSRSwingTF);
   if(InpSRUseTF2) AppendSwingLevels(InpSRSwingTF2);
  }

//+------------------------------------------------------------------+
void RefreshSRLevels()
  {
   datetime today = DayStart(TimeCurrent());
   if(today == g_srCalcDay) return;    // already computed today
   g_srCalcDay = today;

   if(InpSRMode == SR_DAILY_PIVOTS) ComputeDailyPivots();
   else                             ComputeSwingLevels();

   if(InpDrawSRLines) DrawSRLines();
  }

//+------------------------------------------------------------------+
void DrawSRLines()
  {
   for(int i=0;i<20;i++) ObjectDelete(0, "SRLevel_"+IntegerToString(i));
   for(int i=0;i<g_srCount;i++)
     {
      string name = "SRLevel_"+IntegerToString(i);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_srLevels[i]);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGoldenrod);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
  }

//+------------------------------------------------------------------+
//| Is `price` within InpSRZonePts of ANY computed S/R level?          |
//+------------------------------------------------------------------+
bool NearAnySRLevel(double price)
  {
   double zone = InpSRZonePts * _Point;
   for(int i=0;i<g_srCount;i++)
      if(MathAbs(price - g_srLevels[i]) <= zone) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Entry gate: a level is SUPPORT only while price sits AT/ABOVE it   |
//| (within the zone) - buys only. A level is RESISTANCE only while    |
//| price sits AT/BELOW it (within the zone) - sells only. These two   |
//| ranges are mutually exclusive per level (they only meet at price   |
//| == level), so a single nearby level can no longer wave through     |
//| BOTH a buy and a sell - previously it did, which is exactly how a  |
//| sell fired while price was sitting on support. Selling only        |
//| becomes valid again once price is on the far side of the level     |
//| (a genuine break, not just a touch).                                |
//+------------------------------------------------------------------+
bool SRAllowsEntry(int dir, double price)
  {
   if(InpUseSRFilter || InpUseSRStop) RefreshSRLevels();  // keep levels fresh for either feature
   if(!InpUseSRFilter) return(true);       // filter disabled -> no restriction
   if(g_srCount == 0) return(true);        // no levels yet (e.g. not enough history) -> don't block
   double zone = InpSRZonePts * _Point;
   for(int i=0;i<g_srCount;i++)
     {
      double lv = g_srLevels[i];
      //--- price at/above the level, within the zone = SUPPORT -> buys only
      if(dir>0 && price>=lv && price<=lv+zone)
        {
         if(InpSRMaxRetests>0 && CountRejections(lv,dir)>InpSRMaxRetests)
           {
            if(InpDebugLog) PrintFormat("SR: support %.2f already rejected >%d times without breaking - not fading it, skipping to next level", lv, InpSRMaxRetests);
            continue;
           }
         return(true);
        }
      //--- price at/below the level, within the zone = RESISTANCE -> sells only
      if(dir<0 && price<=lv && price>=lv-zone)
        {
         if(InpSRMaxRetests>0 && CountRejections(lv,dir)>InpSRMaxRetests)
           {
            if(InpDebugLog) PrintFormat("SR: resistance %.2f already rejected >%d times without breaking - not fading it, skipping to next level", lv, InpSRMaxRetests);
            continue;
           }
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| [SAFETY] Count how many recent InpSRSwingTF bars touched `lv`      |
//| (within InpSRZonePts) and got rejected without a decisive close    |
//| through it. Stops counting the moment it finds a bar that DID      |
//| close decisively through the level - that means the level already |
//| broke, so older rejections before that break no longer apply.      |
//| dir>0 -> lv is being read as support (rejections = failed breaks   |
//| below); dir<0 -> lv is resistance (rejections = failed breaks up). |
//+------------------------------------------------------------------+
int CountRejections(double lv, int dir)
  {
   double zone=InpSRZonePts*_Point;
   int available=iBars(_Symbol, InpSRSwingTF);
   int bars=MathMin(InpSRRetestLookback, available-1);
   int touches=0;
   for(int i=1; i<=bars; i++)
     {
      double hi=iHigh(_Symbol, InpSRSwingTF, i);
      double lo=iLow (_Symbol, InpSRSwingTF, i);
      double cl=iClose(_Symbol, InpSRSwingTF, i);
      if(dir>0)
        {
         if(cl<lv-zone) break;              // closed decisively below -> support already broke, stop
         if(lo<=lv+zone) touches++;         // dipped into the zone and held
        }
      else
        {
         if(cl>lv+zone) break;              // closed decisively above -> resistance already broke, stop
         if(hi>=lv-zone) touches++;         // poked into the zone and held
        }
     }
   return(touches);
  }

//+------------------------------------------------------------------+
//| Structure-based stop distance (points) for a position opening at   |
//| `price` in direction `dir`. Places the stop just beyond the         |
//| nearest qualifying S/R level - support below entry for a buy,       |
//| resistance above entry for a sell - plus InpSRStopBufferPts, so a   |
//| touch of the level doesn't stop the trade out, only a real break    |
//| does. Returns 0 if no qualifying level exists within                |
//| InpSRStopMaxPts; the caller then falls back to ATR/fixed points.    |
//+------------------------------------------------------------------+
double SRStopDistance(int dir, double price)
  {
   if(!InpUseSRStop) return(0);
   if(g_srCount == 0) return(0);

   double best = -1;
   for(int i=0;i<g_srCount;i++)
     {
      double lv = g_srLevels[i];
      if(dir>0 && lv < price)                        // support candidate (below entry)
        {
         double dist = price - lv;
         if(best<0 || dist<best) best=dist;
        }
      if(dir<0 && lv > price)                        // resistance candidate (above entry)
        {
         double dist = lv - price;
         if(best<0 || dist<best) best=dist;
        }
     }
   if(best < 0) return(0);                            // nothing on the protective side -> fall back

   double pts = best/_Point + InpSRStopBufferPts;
   if(pts > InpSRStopMaxPts) return(0);                // level too far away to be a useful stop
   return(pts);
  }

//+------------------------------------------------------------------+
//| Entry signal on the just-closed bar: +1 buy, -1 sell, 0 none     |
//+------------------------------------------------------------------+
int Signal()
  {
   double k[2], d[2];                               // [0]=bar2, [1]=bar1 (last closed)
   if(CopyBuffer(hStoch, MAIN_LINE,   1, 2, k) < 2) return(0);
   if(CopyBuffer(hStoch, SIGNAL_LINE, 1, 2, d) < 2) return(0);
   double kNow=k[1], kPrev=k[0], dNow=d[1], dPrev=d[0];

   bool buy=false, sell=false;
   switch(InpSigMode)
     {
      case SIG_LEVEL:
         buy  = (kNow < InpDownLevel);
         sell = (kNow > InpUpLevel);
         break;
      case SIG_CROSS:
         buy  = (kPrev <= InpDownLevel && kNow > InpDownLevel);
         sell = (kPrev >= InpUpLevel   && kNow < InpUpLevel);
         break;
      case SIG_KD:
         buy  = (kPrev <= dPrev && kNow > dNow && kPrev < InpDownLevel);
         sell = (kPrev >= dPrev && kNow < dNow && kPrev > InpUpLevel);
         break;
     }
   if(InpRequireDragon)
     {
      int tr = DragonState();
      if(tr == 0) return(0);
      if(tr < 0) buy  = false;
      if(tr > 0) sell = false;
     }
   if(buy  && InpTradeBuy)  return(+1);
   if(sell && InpTradeSell) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Basket helpers (this symbol + magic only)                        |
//+------------------------------------------------------------------+
void BasketInfo(int dir, int &count, double &vol, double &weighted, double &lastLot, double &lastPrice)
  {
   count=0; vol=0; weighted=0; lastLot=0; lastPrice=0;
   datetime newest=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)    continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)     continue;
      int ptype=(int)PositionGetInteger(POSITION_TYPE);
      if(dir>0 && ptype!=POSITION_TYPE_BUY)  continue;
      if(dir<0 && ptype!=POSITION_TYPE_SELL) continue;
      double v=PositionGetDouble(POSITION_VOLUME);
      double p=PositionGetDouble(POSITION_PRICE_OPEN);
      count++; vol+=v; weighted+=p*v;
      datetime tm=(datetime)PositionGetInteger(POSITION_TIME);
      if(tm>=newest){ newest=tm; lastLot=v; lastPrice=p; }
     }
   if(vol>0) weighted/=vol;
  }

double BasketProfitDir(int dir)  // floating P/L for one direction only
  {
   double pl=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)  continue;
      int ptype=(int)PositionGetInteger(POSITION_TYPE);
      if(dir>0 && ptype!=POSITION_TYPE_BUY)  continue;
      if(dir<0 && ptype!=POSITION_TYPE_SELL) continue;
      pl+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return(pl);
  }

void CloseAllMagic()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)  continue;
      trade.PositionClose(tk);
     }
  }

double NormalizeLot(double lot)
  {
   double step=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn  =SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx  =SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step+0.5)*step;
   lot=MathMax(mn, MathMin(mx, lot));
   lot=MathMin(lot, g_maxLot);           // never exceed the (scaled) user cap
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| $ value of a 1-point move for a 1.0 lot position, broker-agnostic.|
//+------------------------------------------------------------------+
double PointValuePerLot()
  {
   double tickValue=SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize =SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0) return(0.0);
   return(tickValue*(_Point/tickSize));
  }

//+------------------------------------------------------------------+
//| [SAFETY] Cap a candidate lot so $ risk to its stop never exceeds  |
//| InpMaxRiskPct of current balance (The5ers: 2% ceiling per trade;  |
//| default here is 1%, since a martingale grid stacks several legs). |
//| Rounds DOWN only, so the cap is never breached by rounding.       |
//| Returns 0 if even the broker's minimum lot would risk too much -  |
//| caller must skip the trade rather than open oversized.            |
//+------------------------------------------------------------------+
double RiskCappedLot(double rawLot, double slPts)
  {
   if(!InpChallengeMode || InpMaxRiskPct<=0.0 || slPts<=0.0) return(rawLot);
   double ptVal=PointValuePerLot();
   if(ptVal<=0.0) return(rawLot);        // can't price it - don't block, other nets still apply
   double riskCash=AccountInfoDouble(ACCOUNT_BALANCE)*InpMaxRiskPct/100.0;
   double maxLot=riskCash/(slPts*ptVal);
   double step=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); if(step<=0) step=0.01;
   double mn  =SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double flooredMax=MathFloor(maxLot/step)*step;
   if(flooredMax < mn)
     {
      if(InpDebugLog) PrintFormat("RISK CAP: even min lot %.2f would risk more than %.1f%% of balance at %.0f pts SL -> skip",
                                   mn, InpMaxRiskPct, slPts);
      return(0.0);
     }
   return(NormalizeLot(MathMin(rawLot, flooredMax)));
  }

//+------------------------------------------------------------------+
//| [SAFETY] Absolute floor - a position NEVER opens with SL<=0.      |
//+------------------------------------------------------------------+
double ClampSLFloor(double pts)
  {
   if(InpChallengeMode && pts < InpForceSLFloorPts) return((double)InpForceSLFloorPts);
   return(pts);
  }

//+------------------------------------------------------------------+
//| [SAFETY] True while a high-impact InpNewsCurrency event is within |
//| the block window - The5ers forbids order execution 2min either    |
//| side of high-impact news.                                         |
//+------------------------------------------------------------------+
bool NewsBlackoutActive()
  {
   if(!InpChallengeMode || !InpUseNewsFilter) return(false);
   datetime now=TimeCurrent();
   datetime from=now-(InpNewsBlockMinsBefore+5)*60;
   datetime to  =now+(InpNewsBlockMinsAfter +5)*60;
   MqlCalendarValue vals[];
   int n=CalendarValueHistory(vals, from, to, NULL, InpNewsCurrency);
   for(int i=0; i<n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev)) continue;
      if(ev.importance < InpNewsMinImportance) continue;
      datetime evTime=vals[i].time;
      if(now>=evTime-InpNewsBlockMinsBefore*60 && now<=evTime+InpNewsBlockMinsAfter*60)
        {
         if(InpDebugLog) PrintFormat("NEWS BLOCK: %s high-impact event at %s, now %s within -%dm/+%dm window",
                                      InpNewsCurrency, TimeToString(evTime,TIME_DATE|TIME_MINUTES),
                                      TimeToString(now,TIME_DATE|TIME_MINUTES),
                                      InpNewsBlockMinsBefore, InpNewsBlockMinsAfter);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| [SAFETY] True if a same-direction position closed within the last |
//| InpPriceCooldownMins minutes within InpPriceCooldownPts of `price`|
//| - stops a ranging market re-selling/re-buying the same spot it    |
//| just got stopped/closed out of, over and over.                    |
//+------------------------------------------------------------------+
bool PriceCooldownBlocks(int dir, double price)
  {
   if(!InpUsePriceCooldown || InpPriceCooldownPts<=0) return(false);
   datetime from=TimeCurrent()-InpPriceCooldownMins*60;
   if(!HistorySelect(from, TimeCurrent()+60)) return(false);
   int total=HistoryDealsTotal();
   //--- closing a BUY position takes a SELL deal, and vice versa
   ENUM_DEAL_TYPE closingType=(dir>0)?DEAL_TYPE_SELL:DEAL_TYPE_BUY;
   for(int i=total-1; i>=0; i--)
     {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC)!=InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL)!=_Symbol) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      if((ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE)!=closingType) continue;
      double closePrice=HistoryDealGetDouble(tk, DEAL_PRICE);
      if(MathAbs(price-closePrice)<=InpPriceCooldownPts*_Point)
        {
         if(InpDebugLog) PrintFormat("SKIP: %s price cooldown - closed a position %.1fpts from here (%.2f) within last %d min",
                                      (dir>0?"BUY":"SELL"), MathAbs(price-closePrice)/_Point, closePrice, InpPriceCooldownMins);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- day rollover: reset the daily halt & baselines
   datetime today=DayStart(TimeCurrent());
   if(today!=g_day)
     {
      g_day=today;
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      g_equityPeak=g_dayStartEquity;
      g_haltedToday=false;
     }

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>g_equityPeak) g_equityPeak=equity;

   //================= CHALLENGE FLOOR [most severe - checked first] =
   // Static, account-wide, never resets: once equity crosses the challenge's
   // own loss limit the step/account has already failed, so this halts for
   // good (persisted via GlobalVariable) rather than resuming next day.
   if(InpChallengeMode)
     {
      double buffer = InpChallengeStartBalance*InpChallengeBufferPct/100.0;
      double line   = g_challengeFloor + buffer;
      if(!g_challengeHalted && equity<=line)
        {
         CloseAllMagic();
         g_challengeHalted=true;
         GlobalVariableSet(g_challengeHaltGV, 1.0);
         PrintFormat("CHALLENGE HALT: equity %.2f <= floor+buffer %.2f (floor %.2f, buffer %.2f) - static account drawdown limit reached, trading stopped for good on this attach",
                     equity, line, g_challengeFloor, buffer);
        }
      if(g_challengeHalted){ CloseAllMagic(); return; }
     }

   //================= SAFETY: whichever limit trips first ===========
   double dayLoss = g_dayStartEquity - equity;                 // >0 means down on the day
   double ddPct   = (g_equityPeak>0)?(g_equityPeak-equity)/g_equityPeak*100.0:0.0;

   if(!g_haltedToday)
     {
      bool moneyHit = InpUseDailyMoneyStop && dayLoss >= g_dailyMaxLoss;
      bool pctHit   = InpUseDailyPctStop   && ddPct   >= InpDailyMaxPct;
      if(moneyHit || pctHit)
        {
         CloseAllMagic();
         g_haltedToday=true;
         PrintFormat("SAFETY HALT for the day: dayLoss=%.2f (lim %.2f) dd=%.2f%% (lim %.2f%%)",
                     dayLoss, g_dailyMaxLoss, ddPct, InpDailyMaxPct);
         return;
        }
     }
   if(g_haltedToday){ CloseAllMagic(); return; }   // stay flat until next day

   //================= BASKET-LEVEL EXITS ============================
   ManageDirection(+1);
   ManageDirection(-1);

   //================= NEW ENTRY (once per closed bar) ===============
   // Scalp mode clocks off the M5 (Dragon) bar; cross mode off the chart bar.
   ENUM_TIMEFRAMES entryTF = (InpEntryMode==ENTRY_M5_TREND_SCALP) ? InpDragonTF : PERIOD_CURRENT;
   datetime bar=(datetime)iTime(_Symbol, entryTF, 0);
   if(bar==g_lastBar) return;
   g_lastBar=bar;

   if(!SessionOpen())
     {
      if(InpDebugLog)
        {
         MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
         PrintFormat("SKIP: outside session hours (now=%d server hr, window %02d:00-%02d:00)",
                     dtNow.hour, InpStartHour, InpEndHour);
        }
      return;
     }
   if(InpMaxSpreadPts>0)
     {
      long spr=SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spr>InpMaxSpreadPts)
        {
         if(InpDebugLog) PrintFormat("SKIP: spread %d pts > max %d pts", spr, InpMaxSpreadPts);
         return;
        }
     }

   if(InpEntryMode==ENTRY_M5_TREND_SCALP)
     {
      TryScalpEntry();                               // enter every M5 bar with the trend
     }
   else
     {
      int sig=Signal();                              // passive: wait for a stochastic cross
      if(sig==0) return;
      if(NewsBlackoutActive()) return;
      int cnt; double vol,wavg,lLot,lPrice;
      BasketInfo(sig, cnt, vol, wavg, lLot, lPrice);
      if(cnt==0)
        {
         double price=(sig>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
         if(SRAllowsEntry(sig, price)) OpenFirst(sig); // start a new cycle only on a signal near S/R
        }
     }
  }

//+------------------------------------------------------------------+
//| M5 TREND SCALP: open a fresh scalp each M5 bar in the trend       |
//| direction. Stochastic is a FILTER (skip when already exhausted),  |
//| not the trigger. Each scalp gets its own small TP + the hard SL.  |
//| Same safety net (basket-stop, daily limits) still applies.        |
//+------------------------------------------------------------------+
void TryScalpEntry()
  {
   if(NewsBlackoutActive())
     {
      if(InpDebugLog) Print("SKIP: news blackout window active");
      return;
     }
   int trend = DragonState();
   if(trend == 0)
     {
      if(InpDebugLog) Print("SKIP: no clear Dragon trend (EMA flat/undecided)");
      return;                                         // no clear trend -> stand aside
     }
   int dir = (trend > 0) ? +1 : -1;
   if(dir>0 && !InpTradeBuy)
     { if(InpDebugLog) Print("SKIP: trend is BUY but Flag_Trade_Buy_ is false"); return; }
   if(dir<0 && !InpTradeSell)
     { if(InpDebugLog) Print("SKIP: trend is SELL but Flag_Trade_Sell_ is false"); return; }

   //--- stochastic filter: don't pile in at the exhaustion extreme
   double k[1];
   if(CopyBuffer(hStoch, MAIN_LINE, 1, 1, k) < 1) return;
   if(dir>0 && k[0] >= InpUpLevel)
     {
      if(InpDebugLog) PrintFormat("SKIP: trend=BUY but stoch exhausted, k=%.2f >= UpLevel=%.1f", k[0], InpUpLevel);
      return;                                          // already overbought -> no new buy
     }
   if(dir<0 && k[0] <= InpDownLevel)
     {
      if(InpDebugLog) PrintFormat("SKIP: trend=SELL but stoch exhausted, k=%.2f <= DownLevel=%.1f", k[0], InpDownLevel);
      return;                                          // already oversold  -> no new sell
     }

   //--- respect the per-direction position cap
   int cnt; double vol,wavg,lLot,lPrice;
   BasketInfo(dir, cnt, vol, wavg, lLot, lPrice);
   if(cnt >= InpMaxPositions)
     {
      if(InpDebugLog) PrintFormat("SKIP: %s position cap reached (%d/%d)", (dir>0?"BUY":"SELL"), cnt, InpMaxPositions);
      return;
     }

   //--- cooldown: don't open a fresh scalp every single bar just because the
   //    trend hasn't flipped - require a few InpDragonTF bars to pass since
   //    the last fresh scalp in this direction.
   int idx=(dir>0)?1:0;
   if(InpMinBarsBetweenScalps>0 && g_lastScalpTime[idx]>0)
     {
      long elapsedSec=(long)(TimeCurrent()-g_lastScalpTime[idx]);
      long needSec=(long)InpMinBarsBetweenScalps*PeriodSeconds(InpDragonTF);
      if(elapsedSec<needSec)
        {
         if(InpDebugLog) PrintFormat("SKIP: %s cooldown active (%ds of %ds since last fresh scalp)",
                                      (dir>0?"BUY":"SELL"), elapsedSec, needSec);
         return;
        }
     }

   //--- S/R filter: only buy near support, only sell near resistance
   double price = (dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(!SRAllowsEntry(dir, price))
     {
      if(InpDebugLog) PrintFormat("SKIP: %s blocked by S/R filter (price=%.2f, no qualifying level within %dpts)",
                                   (dir>0?"BUY":"SELL"), price, InpSRZonePts);
      return;
     }

   //--- price cooldown: don't re-sell/re-buy the exact spot a position just
   //    closed at (ranging markets flogging the same zone over and over)
   if(PriceCooldownBlocks(dir, price)) return;

   if(InpDebugLog) PrintFormat("ENTRY: %s (trend agrees, k=%.2f, cnt=%d/%d, S/R OK) @ %.2f",
                                (dir>0?"BUY":"SELL"), k[0], cnt, InpMaxPositions, price);
   OpenScalp(dir);
   g_lastScalpTime[idx]=TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Current hard-SL distance in POINTS (0 = no stop). Priority:        |
//| structure (nearest S/R level + buffer, if InpUseSRStop finds one)  |
//| -> ATR(InpATRTimeframe) x InpATRMultiplier, floored by              |
//| InpMinSLPoints -> fixed InpHardSLPoints. Each falls through to the |
//| next when it isn't available/applicable, so a trade always gets a  |
//| stop.                                                               |
//+------------------------------------------------------------------+
double HardSLPoints(int dir, double price)
  {
   double srPts = SRStopDistance(dir, price);
   if(srPts > 0) return(ClampSLFloor(srPts));

   if(InpUseATRStop && hATR!=INVALID_HANDLE)
     {
      double a[1];
      if(CopyBuffer(hATR, 0, 1, 1, a)==1 && a[0]>0.0)
        {
         double pts=(a[0]/_Point)*InpATRMultiplier;
         if(pts < InpMinSLPoints) pts=InpMinSLPoints;
         return(ClampSLFloor(pts));
        }
     }
   return(ClampSLFloor((double)InpHardSLPoints));    // fixed fallback (0 = none unless InpChallengeMode forces a floor)
  }

//+------------------------------------------------------------------+
//| Current scalp TP distance in POINTS (0 = none). ATR mode:         |
//| distance = InpATRTPMultiplier x ATR, floored by InpMinTPPoints.   |
//+------------------------------------------------------------------+
double ScalpTPPoints()
  {
   if(InpUseATRTP && hATRtp!=INVALID_HANDLE)
     {
      double a[1];
      if(CopyBuffer(hATRtp, 0, 1, 1, a)==1 && a[0]>0.0)
        {
         double pts=(a[0]/_Point)*InpATRTPMultiplier;
         if(pts < InpMinTPPoints) pts=InpMinTPPoints;
         return(pts);
        }
     }
   return((double)InpScalpTPPoints);                 // fixed fallback
  }

//+------------------------------------------------------------------+
void OpenScalp(int dir)
  {
   double price=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slPts=HardSLPoints(dir, price);
   double lot=RiskCappedLot(NormalizeLot(g_initLot), slPts); // fresh scalps use the (scaled) base lot, then risk-capped
   if(lot<=0.0) return;                                // risk cap: no valid size fits InpMaxRiskPct
   double sl=0, tp=0;
   if(slPts>0)
      sl=(dir>0)?price-slPts*_Point:price+slPts*_Point;
   double tpPts=ScalpTPPoints();
   if(tpPts>0)
      tp=(dir>0)?price+tpPts*_Point:price-tpPts*_Point;
   if(dir>0) trade.Buy (lot,_Symbol,0,sl,tp,InpComment);
   else      trade.Sell(lot,_Symbol,0,sl,tp,InpComment);
  }

//+------------------------------------------------------------------+
bool SessionOpen()
  {
   if(InpStartHour==0 && InpEndHour==0) return(true);
   MqlDateTime d; TimeToStruct(TimeCurrent(), d);
   if(InpStartHour<=InpEndHour) return(d.hour>=InpStartHour && d.hour<InpEndHour);
   return(d.hour>=InpStartHour || d.hour<InpEndHour); // wraps midnight
  }

//+------------------------------------------------------------------+
void OpenFirst(int dir)
  {
   double price=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slPts=HardSLPoints(dir, price);
   double lot=RiskCappedLot(NormalizeLot(g_initLot), slPts);
   if(lot<=0.0) return;                                // risk cap: no valid size fits InpMaxRiskPct
   double sl=0;
   if(slPts>0)
      sl=(dir>0)?price-slPts*_Point:price+slPts*_Point;
   if(dir>0) trade.Buy (lot,_Symbol,0,sl,0,InpComment);
   else      trade.Sell(lot,_Symbol,0,sl,0,InpComment);
  }

//+------------------------------------------------------------------+
//| Manage one direction: basket TP, basket money-stop, grid, trail  |
//+------------------------------------------------------------------+
void ManageDirection(int dir)
  {
   int cnt; double vol,wavg,lLot,lPrice;
   BasketInfo(dir, cnt, vol, wavg, lLot, lPrice);
   if(cnt==0) return;

   double bp=BasketProfitDir(dir);  // floating P/L for this direction's basket only

   //--- basket money-stop [SAFETY]: kill the cycle at max floating loss (BOTH modes)
   if(InpUseBasketMoneyStop && bp<=-g_basketMaxLoss){ CloseAllDir(dir); return; }

   //--- basket TAKE-PROFIT: cross mode only. In scalp mode each trade carries its
   //    own TP, so we don't force-close the batch on a small combined profit.
   if(InpEntryMode!=ENTRY_M5_TREND_SCALP)
     {
      if(InpUseBasketTPMoney && bp>=g_basketTP){ CloseAllDir(dir); return; }
      if(!InpUseBasketTPMoney && InpTPPoints>0)
        {
         double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double movePts=(dir>0)?(cur-wavg)/_Point:(wavg-cur)/_Point;
         if(movePts>=InpTPPoints){ CloseAllDir(dir); return; }
        }
     }

   //--- grid add (only in martingale/grid mode)
   //    [SAFETY] once floating loss is already most of the way to the basket
   //    money-stop, stop adding new (bigger) legs — let the money-stop close
   //    the basket at its cap instead of the grid piling one more large lot
   //    into a fast move right before the close fires.
   if(InpUseBasketMoneyStop && InpGridAddMaxLossPct>0 && bp<=-(g_basketMaxLoss*InpGridAddMaxLossPct/100.0))
     {
      if(InpDebugLog) PrintFormat("GRID: add blocked, dir=%d floating=%.2f already past %.0f%% of basket cap %.2f",
                                   dir, bp, InpGridAddMaxLossPct, g_basketMaxLoss);
     }
   else if(InpMartingaleMode && cnt<InpMaxPositions)
     {
      double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double adversePts=(dir>0)?(lPrice-cur)/_Point:(cur-lPrice)/_Point;
      double need=NextDistance(cnt);
      if(adversePts>=need && !NewsBlackoutActive())
        {
         double slPts=HardSLPoints(dir, cur);
         double lot=RiskCappedLot(NormalizeLot(lLot*g_multiplier), slPts);
         if(lot<=0.0)
           {
            if(InpDebugLog) PrintFormat("GRID: add blocked by risk cap, dir=%d (no valid lot fits %.1f%% risk at %.0f pts SL)",
                                         dir, InpMaxRiskPct, slPts);
           }
         else
           {
            double sl=0;
            if(slPts>0)
               sl=(dir>0)?cur-slPts*_Point:cur+slPts*_Point;
            if(dir>0) trade.Buy (lot,_Symbol,0,sl,0,InpComment);
            else      trade.Sell(lot,_Symbol,0,sl,0,InpComment);
           }
        }
     }

   //--- trailing stop on the basket (moves each position's SL)
   if(InpUseTrailing) TrailDirection(dir);
  }

//+------------------------------------------------------------------+
double NextDistance(int count)
  {
   // Fixed spacing until the running distance passes DynStart, then *mult each step.
   double running=InpFixDistance*count;
   if(running<InpDynStartPts) return(InpFixDistance);
   int steps=1+(int)((running-InpDynStartPts)/MathMax(1,InpFixDistance));
   return(InpFixDistance*MathPow(InpDistMult, steps));
  }

//+------------------------------------------------------------------+
void CloseAllDir(int dir)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)  continue;
      int ptype=(int)PositionGetInteger(POSITION_TYPE);
      if(dir>0 && ptype!=POSITION_TYPE_BUY)  continue;
      if(dir<0 && ptype!=POSITION_TYPE_SELL) continue;
      trade.PositionClose(tk);
     }
  }

//+------------------------------------------------------------------+
void TrailDirection(int dir)
  {
   if(InpTrailDist<=0) return;
   double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)  continue;
      int ptype=(int)PositionGetInteger(POSITION_TYPE);
      if(dir>0 && ptype!=POSITION_TYPE_BUY)  continue;
      if(dir<0 && ptype!=POSITION_TYPE_SELL) continue;
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  =PositionGetDouble(POSITION_SL);
      double profitPts=(dir>0)?(cur-open)/_Point:(open-cur)/_Point;
      //--- must be in profit by MORE than the trail distance, otherwise the
      //    locked stop would sit at a loss and noise-stop the trade (the V3 bug).
      if(profitPts < InpTrailStart)   continue;
      if(profitPts <= InpTrailDist)   continue;
      double newSL=(dir>0)?cur-InpTrailDist*_Point:cur+InpTrailDist*_Point;
      //--- never lock worse than break-even
      if(dir>0 && newSL<open) newSL=open;
      if(dir<0 && newSL>open) newSL=open;
      bool better=(dir>0)?(sl==0 || newSL>sl):(sl==0 || newSL<sl);
      if(better) trade.PositionModify(tk, NormalizeDouble(newSL,_Digits), PositionGetDouble(POSITION_TP));
     }
  }
//+------------------------------------------------------------------+
