//+------------------------------------------------------------------+
//|                                                 CONQUER_Safe.mq5  |
//|   Clean-room, safer re-implementation of the CONQUER EA.          |
//|                                                                  |
//|   The original CONQUER__EAEX5.ex5 is a martingale grid scalper    |
//|   with NO stop-loss (SL_=0). This EA reproduces its *behaviour*   |
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
#property copyright "Execution Desk - safer CONQUER replica"
#property version   "1.00"
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

//==================== SIGNAL INPUTS (mirror .set) ==================
input string          _s0            = "===== Signal ====="; // ---
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

//==================== TRADE / SIZING ==============================
input string          _s1            = "===== Position sizing ====="; // ---
input bool            InpTradeBuy    = true;        // Flag_Trade_Buy_
input bool            InpTradeSell   = true;        // Flag_Trade_Sell_
input double          InpInitialLot  = 0.01;        // Lot_Init_ (start lot)
input bool            InpMartingaleMode = true;     // true = capped grid, false = single-shot fixed lot
input double          InpMultiplier  = 1.89;        // Martin_
input double          InpMaxLot      = 0.13;        // MaxLot_
input int             InpMaxPositions= 6;           // MaxOrders per direction
input long            InpMagic       = 16082020;    // Magic
input string          InpComment     = "CONQUER_Safe"; // order comment

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
input int             InpHardSLPoints= 300;         // hard stop-loss per position (0 = none) [ADDED SAFETY]
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
input int             InpStartHour     = 0;         // Start_Hour (0/0 = all day)
input int             InpEndHour       = 0;         // End_Hour

//==================== STATE ======================================
int      hStoch  = INVALID_HANDLE;
int      hDragon = INVALID_HANDLE;
int      hCustom = INVALID_HANDLE;
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

   g_day = DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak     = g_dayStartEquity;
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hStoch  != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hDragon != INVALID_HANDLE) IndicatorRelease(hDragon);
   if(hCustom != INVALID_HANDLE) IndicatorRelease(hCustom);
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
   lot=MathMin(lot, InpMaxLot);          // never exceed user cap
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
      bool moneyHit = InpUseDailyMoneyStop && dayLoss >= InpDailyMaxLoss;
      bool pctHit   = InpUseDailyPctStop   && ddPct   >= InpDailyMaxPct;
      if(moneyHit || pctHit)
        {
         CloseAllMagic();
         g_haltedToday=true;
         PrintFormat("SAFETY HALT for the day: dayLoss=%.2f (lim %.2f) dd=%.2f%% (lim %.2f%%)",
                     dayLoss, InpDailyMaxLoss, ddPct, InpDailyMaxPct);
         return;
        }
     }
   if(g_haltedToday){ CloseAllMagic(); return; }   // stay flat until next day

   //================= BASKET-LEVEL EXITS ============================
   ManageDirection(+1);
   ManageDirection(-1);

   //================= NEW SIGNAL (once per closed bar) ==============
   datetime bar=(datetime)iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar==g_lastBar) return;
   g_lastBar=bar;

   if(!SessionOpen()) return;
   if(InpMaxSpreadPts>0)
     {
      long spr=SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spr>InpMaxSpreadPts) return;
     }

   int sig=Signal();
   if(sig==0) return;

   int cnt; double vol,wavg,lLot,lPrice;
   BasketInfo(sig, cnt, vol, wavg, lLot, lPrice);
   if(cnt==0) OpenFirst(sig);                        // start a new cycle only on a signal
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
   double lot=NormalizeLot(InpInitialLot);
   double price=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=0;
   if(InpHardSLPoints>0)
      sl=(dir>0)?price-InpHardSLPoints*_Point:price+InpHardSLPoints*_Point;
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

   //--- basket money take-profit
   if(InpUseBasketTPMoney && bp>=InpBasketTPMoney){ CloseAllDir(dir); return; }

   //--- basket money-stop [SAFETY]: kill the cycle at max floating loss
   if(InpUseBasketMoneyStop && bp<=-InpBasketMaxLoss){ CloseAllDir(dir); return; }

   //--- points-based basket TP fallback (from weighted-average entry)
   if(!InpUseBasketTPMoney && InpTPPoints>0)
     {
      double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double movePts=(dir>0)?(cur-wavg)/_Point:(wavg-cur)/_Point;
      if(movePts>=InpTPPoints){ CloseAllDir(dir); return; }
     }

   //--- grid add (only in martingale/grid mode)
   if(InpMartingaleMode && cnt<InpMaxPositions)
     {
      double cur=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double adversePts=(dir>0)?(lPrice-cur)/_Point:(cur-lPrice)/_Point;
      double need=NextDistance(cnt);
      if(adversePts>=need)
        {
         double lot=NormalizeLot(lLot*InpMultiplier);
         double sl=0;
         if(InpHardSLPoints>0)
            sl=(dir>0)?cur-InpHardSLPoints*_Point:cur+InpHardSLPoints*_Point;
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
      if(profitPts<InpTrailStart) continue;
      double newSL=(dir>0)?cur-InpTrailDist*_Point:cur+InpTrailDist*_Point;
      bool better=(dir>0)?(sl==0 || newSL>sl):(sl==0 || newSL<sl);
      if(better) trade.PositionModify(tk, NormalizeDouble(newSL,_Digits), PositionGetDouble(POSITION_TP));
     }
  }
//+------------------------------------------------------------------+
