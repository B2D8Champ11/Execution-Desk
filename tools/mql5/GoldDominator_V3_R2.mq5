//+------------------------------------------------------------------+
//|                                          GoldDominator_V3_R2.mq5  |
//|   Gold Dominator V3 R2 - safer XAUUSD scalp/grid EA (session).   |
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
//|                                                                  |
//|   NOTE: not compiled/tested in this environment. Compile in       |
//|   MetaEditor (F7) and validate in Strategy Tester before live.    |
//|   The exact entry trigger mirrors CONQUER_SignalProbe; confirm it |
//|   with that probe first, then set SigMode/RequireDragon to match. |
//+------------------------------------------------------------------+
#property copyright "Gold Dominator V3_R2 - Execution Desk"
#property version   "1.30"
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
input ENUM_ENTRYMODE  InpEntryMode   = ENTRY_M5_TREND_SCALP; // HOW it enters (test both)
input int             InpScalpTPPoints = 130;       // scalp mode: fixed TP per trade (points)
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
input ENUM_SRMODE     InpSRMode      = SR_DAILY_PIVOTS; // which levels to use
input int             InpSRZonePts   = 150;         // "near" = within this many points of a level
input bool            InpDrawSRLines = true;        // draw the levels on the chart (visual/debug)
input bool            InpUseSRStop   = false;       // place the hard SL just beyond the nearest S/R level
input int             InpSRStopBufferPts = 50;      // extra room beyond the level, so a touch isn't a break
input int             InpSRStopMaxPts    = 2000;    // ignore a level farther than this (falls back to ATR/fixed)

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
input long            InpMagic       = 16082022;    // Magic (unique per variant so they don't clash)
input string          InpComment     = "GoldDominatorV3R2"; // order comment
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
input bool            InpUseDailyMoneyStop = true;  // halt for the day at a money loss
input double          InpDailyMaxLoss  = 100.0;     // $ daily loss limit
input bool            InpUseDailyPctStop = true;    // halt for the day at a % drawdown
input double          InpDailyMaxPct   = 5.0;       // % of day-start equity
input int             InpMaxSpreadPts  = 0;         // MaxSpred (0 = ignore)
input int             InpStartHour     = 9;         // Start_Hour (matches real EA: 09:00 server)
input int             InpEndHour       = 12;        // End_Hour   (real EA stops entries ~12:00)

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
datetime g_day     = 0;
double   g_dayStartEquity = 0;
double   g_equityPeak     = 0;
bool     g_haltedToday    = false;

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
   PrintFormat("Gold Dominator entry mode = %s",
               (InpEntryMode==ENTRY_M5_TREND_SCALP)
               ? StringFormat("M5 TREND SCALP (every %s bar, TP %d pts, stoch=filter)",
                              EnumToString(InpDragonTF), InpScalpTPPoints)
               : "SIGNAL CROSS (passive stochastic trigger)");
   if(InpUseSRFilter || InpUseSRStop)
      PrintFormat("Gold Dominator S/R active | entry-filter=%s stop=%s | mode=%s zone=%dpts stopBuffer=%dpts stopMax=%dpts",
                  (InpUseSRFilter?"ON":"off"), (InpUseSRStop?"ON":"off"),
                  EnumToString(InpSRMode), InpSRZonePts, InpSRStopBufferPts, InpSRStopMaxPts);
   PrintLotLadder();

   g_day = DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak     = g_dayStartEquity;
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
   PrintFormat("Gold Dominator ladder | scale=%.2fx (bal %.0f) | mult=%.3f (%s) | %s| total=%.2f lots | stops: TP %.0f / basket %.0f / daily %.0f",
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
double g_srLevels[7];      // up to 7 levels (pivots: S3,S2,S1,P,R1,R2,R3)
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
//| the extreme of its InpSRSwingLookback-bar neighbourhood on each    |
//| side). Cheaper alternative to pivots; adapts to recent structure   |
//| instead of yesterday's range.                                     |
//+------------------------------------------------------------------+
void ComputeSwingLevels()
  {
   g_srCount = 0;
   int lookback = 5;                 // bars each side to confirm a fractal
   int scanBars = 200;                // how far back to search for swings
   int total = MathMin(scanBars, iBars(_Symbol, PERIOD_H1)-lookback*2-2);
   if(total <= 0) return;

   double hi[], lo[];
   if(CopyHigh(_Symbol, PERIOD_H1, 1, total+lookback*2, hi) < total) return;
   if(CopyLow (_Symbol, PERIOD_H1, 1, total+lookback*2, lo) < total) return;
   ArraySetAsSeries(hi, false);
   ArraySetAsSeries(lo, false);

   for(int i=lookback; i<total && g_srCount<7; i++)
     {
      bool isHigh=true, isLow=true;
      for(int j=1;j<=lookback;j++)
        {
         if(hi[i] <= hi[i-j] || hi[i] <= hi[i+j]) isHigh=false;
         if(lo[i] >= lo[i-j] || lo[i] >= lo[i+j]) isLow=false;
        }
      if(isHigh) g_srLevels[g_srCount++] = hi[i];
      if(isLow && g_srCount<7) g_srLevels[g_srCount++] = lo[i];
     }
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
//| Entry gate: for a BUY, price must be near a level that sits AT or  |
//| BELOW current price (support); for a SELL, near a level AT or      |
//| ABOVE current price (resistance). Keeps buys off resistance and    |
//| sells off support, not just "near any line".                       |
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
      if(MathAbs(price - lv) > zone) continue;
      if(dir>0 && lv <= price+zone) return(true);   // buy near/below price = support
      if(dir<0 && lv >= price-zone) return(true);   // sell near/above price = resistance
     }
   return(false);
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

   if(!SessionOpen()) return;
   if(InpMaxSpreadPts>0)
     {
      long spr=SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spr>InpMaxSpreadPts) return;
     }

   if(InpEntryMode==ENTRY_M5_TREND_SCALP)
     {
      TryScalpEntry();                               // enter every M5 bar with the trend
     }
   else
     {
      int sig=Signal();                              // passive: wait for a stochastic cross
      if(sig==0) return;
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
   int trend = DragonState();
   if(trend == 0) return;                            // no clear trend -> stand aside
   int dir = (trend > 0) ? +1 : -1;
   if(dir>0 && !InpTradeBuy)  return;
   if(dir<0 && !InpTradeSell) return;

   //--- stochastic filter: don't pile in at the exhaustion extreme
   double k[1];
   if(CopyBuffer(hStoch, MAIN_LINE, 1, 1, k) < 1) return;
   if(dir>0 && k[0] >= InpUpLevel)   return;         // already overbought -> no new buy
   if(dir<0 && k[0] <= InpDownLevel) return;         // already oversold  -> no new sell

   //--- respect the per-direction position cap
   int cnt; double vol,wavg,lLot,lPrice;
   BasketInfo(dir, cnt, vol, wavg, lLot, lPrice);
   if(cnt >= InpMaxPositions) return;

   //--- S/R filter: only buy near support, only sell near resistance
   double price = (dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(!SRAllowsEntry(dir, price)) return;

   OpenScalp(dir);
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
   if(srPts > 0) return(srPts);

   if(InpUseATRStop && hATR!=INVALID_HANDLE)
     {
      double a[1];
      if(CopyBuffer(hATR, 0, 1, 1, a)==1 && a[0]>0.0)
        {
         double pts=(a[0]/_Point)*InpATRMultiplier;
         if(pts < InpMinSLPoints) pts=InpMinSLPoints;
         return(pts);
        }
     }
   return((double)InpHardSLPoints);                  // fixed fallback (0 = none)
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
   double lot=NormalizeLot(g_initLot);               // fresh scalps use the (scaled) base lot
   double price=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=0, tp=0;
   double slPts=HardSLPoints(dir, price);
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
   double lot=NormalizeLot(g_initLot);
   double price=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=0;
   double slPts=HardSLPoints(dir, price);
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
   if(InpMartingaleMode && cnt<InpMaxPositions)
     {
      double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double adversePts=(dir>0)?(lPrice-cur)/_Point:(cur-lPrice)/_Point;
      double need=NextDistance(cnt);
      if(adversePts>=need)
        {
         double lot=NormalizeLot(lLot*g_multiplier);
         double sl=0;
         double slPts=HardSLPoints(dir, cur);
         if(slPts>0)
            sl=(dir>0)?cur-slPts*_Point:cur+slPts*_Point;
         if(dir>0) trade.Buy (lot,_Symbol,0,sl,0,InpComment);
         else      trade.Sell(lot,_Symbol,0,sl,0,InpComment);
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
