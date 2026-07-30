//+------------------------------------------------------------------+
//|                                          CONQUER_SignalProbe.mq5  |
//|   Diagnostic overlay to reverse-engineer the CONQUER EA trigger   |
//|                                                                  |
//|   Purpose: this indicator does NOT trade. It plots a BUY/SELL      |
//|   arrow wherever a *candidate* entry rule fires, so you can lay it |
//|   over the real EA's arrows in Strategy Tester Visual Mode and see |
//|   which hypothesis matches. Flip SignalMode / RequireDragon until  |
//|   the probe arrows line up with the EA's actual entries.           |
//|                                                                  |
//|   Signal engines mirror the EA's .set:                            |
//|     - Trend  : "Black Dragon" (M5)  -> proxy = EMA slope, or read  |
//|                the REAL Black Dragon via iCustom (UseRealDragon).  |
//|     - Trigger: Stochastic (M15) K7 D1 Slow2, levels 90 / 10.       |
//+------------------------------------------------------------------+
#property copyright "Execution Desk - signal probe"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- BUY arrow
#property indicator_label1  "ProbeBuy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2
//--- SELL arrow
#property indicator_label2  "ProbeSell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//--- how the candidate trigger is defined (flip these to find the match)
enum ENUM_SIGMODE
  {
   SIG_LEVEL = 0,   // Stoch simply beyond level (K < Down / K > Up)
   SIG_CROSS = 1,   // Stoch %K crosses the level (exit oversold/overbought)
   SIG_KD    = 2    // Stoch %K crosses %D while beyond the level
  };

//--- how the Black Dragon proxy decides bull/bear (only used if !UseRealDragon)
enum ENUM_DRAGONMODE
  {
   DRAGON_SLOPE = 0, // EMA rising = bull, falling = bear
   DRAGON_PRICE = 1  // Close above EMA = bull, below = bear
  };

//==================== INPUTS (mirror the EA .set) ===================
input string          _sep0            = "----- Stochastic (from .set) -----"; // ---
input ENUM_TIMEFRAMES InpStochTF       = PERIOD_M15;  // TF_Stoh
input int             InpK             = 7;           // KPeriod
input int             InpD             = 1;           // DPeriod
input int             InpSlowing       = 2;           // Slowing
input double          InpUpLevel       = 90;          // Up_Level
input double          InpDownLevel     = 10;          // Down_Level

input string          _sep1            = "----- Black Dragon (trend filter) -----"; // ---
input bool            InpRequireDragon = true;        // must Dragon confirm the direction?
input ENUM_TIMEFRAMES InpDragonTF      = PERIOD_M5;   // TF_DB
input bool            InpUseRealDragon = false;       // read the REAL Black Dragon via iCustom?
input string          InpDragonName    = "Black Dragon"; // iCustom name (path in \Indicators)
input int             InpDragonBufUp   = 0;           // iCustom buffer index holding the "up/blue" line
input int             InpDragonBufDn   = 1;           // iCustom buffer index holding the "down/red" line
//--- proxy settings (used when UseRealDragon = false)
input ENUM_DRAGONMODE InpDragonMode    = DRAGON_SLOPE;// how proxy colors the trend
input int             InpDragonPeriod  = 20;          // proxy EMA period (tune to match the real line)
input ENUM_MA_METHOD  InpDragonMethod  = MODE_EMA;    // proxy MA method
input ENUM_APPLIED_PRICE InpDragonPrice= PRICE_CLOSE; // proxy MA price

input string          _sep2            = "----- Probe behaviour -----"; // ---
input ENUM_SIGMODE    InpSigMode       = SIG_CROSS;   // candidate trigger definition
input bool            InpOnlyClosedBars= true;        // evaluate confirmed bars only (avoid repaint)
input bool            InpMarkTransition= true;        // arrow only on the bar the rule turns true
input bool            InpPrintLog      = true;        // print each signal to the Experts log
input bool            InpShowPanel     = true;        // show live state panel on chart

//==================== BUFFERS / HANDLES =============================
double BuyBuf[];
double SellBuf[];

int    hStoch  = INVALID_HANDLE;
int    hDragon = INVALID_HANDLE;   // EMA proxy
int    hCustom = INVALID_HANDLE;   // real Black Dragon (iCustom)

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuf,  INDICATOR_DATA);
   SetIndexBuffer(1, SellBuf, INDICATOR_DATA);
   ArraySetAsSeries(BuyBuf,  false);
   ArraySetAsSeries(SellBuf, false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);            // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234);            // down arrow
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   hStoch = iStochastic(_Symbol, InpStochTF, InpK, InpD, InpSlowing, MODE_SMA, STO_LOWHIGH);
   if(hStoch == INVALID_HANDLE)
     { Print("Probe: failed to create Stochastic handle"); return(INIT_FAILED); }

   if(InpUseRealDragon)
     {
      hCustom = iCustom(_Symbol, InpDragonTF, InpDragonName);
      if(hCustom == INVALID_HANDLE)
         Print("Probe: WARNING could not load iCustom '", InpDragonName,
               "' - falling back to EMA proxy. Check the name/path.");
     }
   if(hCustom == INVALID_HANDLE) // proxy (either chosen, or fallback)
     {
      hDragon = iMA(_Symbol, InpDragonTF, InpDragonPeriod, 0, InpDragonMethod, InpDragonPrice);
      if(hDragon == INVALID_HANDLE)
        { Print("Probe: failed to create EMA proxy handle"); return(INIT_FAILED); }
     }

   IndicatorSetString(INDICATOR_SHORTNAME, "CONQUER SignalProbe");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hStoch  != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hDragon != INVALID_HANDLE) IndicatorRelease(hDragon);
   if(hCustom != INVALID_HANDLE) IndicatorRelease(hCustom);
   ObjectDelete(0, "ProbePanel");
  }

//+------------------------------------------------------------------+
//| Is Black Dragon bullish at the M5 bar mapped from chart time t?  |
//| Returns +1 bull, -1 bear, 0 unknown/insufficient data.           |
//+------------------------------------------------------------------+
int DragonState(datetime t)
  {
   int shift = iBarShift(_Symbol, InpDragonTF, t, false);
   if(shift < 0) return(0);

   if(hCustom != INVALID_HANDLE)
     {
      double up[2], dn[2];
      if(CopyBuffer(hCustom, InpDragonBufUp, shift, 1, up) < 1) return(0);
      if(CopyBuffer(hCustom, InpDragonBufDn, shift, 1, dn) < 1) return(0);
      // Black Dragon typically draws only one of the two lines per bar.
      bool upOn = (up[0] != EMPTY_VALUE && up[0] != 0.0);
      bool dnOn = (dn[0] != EMPTY_VALUE && dn[0] != 0.0);
      if(upOn && !dnOn) return(+1);
      if(dnOn && !upOn) return(-1);
      return(0);
     }

   // ---- EMA proxy ----
   double ema[2];
   if(CopyBuffer(hDragon, 0, shift, 2, ema) < 2) return(0); // ema[0]=older, ema[1]=newer
   if(InpDragonMode == DRAGON_SLOPE)
      return(ema[1] > ema[0] ? +1 : (ema[1] < ema[0] ? -1 : 0));

   // DRAGON_PRICE: close of that M5 bar vs EMA
   double cl[1];
   if(CopyClose(_Symbol, InpDragonTF, shift, 1, cl) < 1) return(0);
   return(cl[0] > ema[1] ? +1 : (cl[0] < ema[1] ? -1 : 0));
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   if(prev_calculated == 0)          // clean start: bar 0 is never evaluated below
     { BuyBuf[0] = EMPTY_VALUE; SellBuf[0] = EMPTY_VALUE; }

   int start = (prev_calculated > 1) ? prev_calculated - 1 : 1;
   int last  = InpOnlyClosedBars ? rates_total - 2 : rates_total - 1; // skip forming bar if requested
   if(last < start) return(rates_total);

   for(int i = start; i <= last; i++)
     {
      BuyBuf[i]  = EMPTY_VALUE;
      SellBuf[i] = EMPTY_VALUE;

      //--- map this chart bar to its M15 stochastic bar
      int sShift = iBarShift(_Symbol, InpStochTF, time[i], false);
      if(sShift < 0) continue;

      double k[2], d[2];   // [0]=older (sShift+1), [1]=current (sShift)
      if(CopyBuffer(hStoch, MAIN_LINE,   sShift, 2, k) < 2) continue;
      if(CopyBuffer(hStoch, SIGNAL_LINE, sShift, 2, d) < 2) continue;
      double kNow = k[1], kPrev = k[0];
      double dNow = d[1], dPrev = d[0];

      //--- candidate trigger, per selected mode
      bool buyTrig = false, sellTrig = false;
      switch(InpSigMode)
        {
         case SIG_LEVEL:
            buyTrig  = (kNow < InpDownLevel);
            sellTrig = (kNow > InpUpLevel);
            break;
         case SIG_CROSS: // leaving the extreme zone
            buyTrig  = (kPrev <= InpDownLevel && kNow > InpDownLevel);
            sellTrig = (kPrev >= InpUpLevel   && kNow < InpUpLevel);
            break;
         case SIG_KD:    // %K crosses %D while still in the extreme zone
            //  NOTE: with DPeriod=1 the signal line ~ main line, so this
            //  mode is nearly degenerate for the EA's real settings.
            buyTrig  = (kPrev <= dPrev && kNow > dNow && kPrev < InpDownLevel);
            sellTrig = (kPrev >= dPrev && kNow < dNow && kPrev > InpUpLevel);
            break;
        }

      //--- Black Dragon trend gate
      if(InpRequireDragon)
        {
         int trend = DragonState(time[i]);
         if(trend == 0) { buyTrig = false; sellTrig = false; }
         else
           {
            if(trend < 0) buyTrig  = false; // need bull to buy
            if(trend > 0) sellTrig = false; // need bear to sell
           }
        }

      //--- only fire on the bar the rule turns true (looks like an entry)
      if(InpMarkTransition)
        {
         bool prevBuy  = (i > 0 && BuyBuf[i-1]  != EMPTY_VALUE);
         bool prevSell = (i > 0 && SellBuf[i-1] != EMPTY_VALUE);
         if(buyTrig  && prevBuy)  buyTrig  = false;
         if(sellTrig && prevSell) sellTrig = false;
        }

      double pad = 2.0 * _Point * MathMax(1, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
      if(buyTrig)
        {
         BuyBuf[i] = low[i] - pad;
         if(InpPrintLog)
            PrintFormat("PROBE BUY  %s  K=%.1f(prev %.1f) D=%.1f  mode=%d",
                        TimeToString(time[i], TIME_DATE|TIME_MINUTES), kNow, kPrev, dNow, InpSigMode);
        }
      if(sellTrig)
        {
         SellBuf[i] = high[i] + pad;
         if(InpPrintLog)
            PrintFormat("PROBE SELL %s  K=%.1f(prev %.1f) D=%.1f  mode=%d",
                        TimeToString(time[i], TIME_DATE|TIME_MINUTES), kNow, kPrev, dNow, InpSigMode);
        }
     }

   if(InpShowPanel) UpdatePanel();
   return(rates_total);
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   double k[1], d[1];
   if(CopyBuffer(hStoch, MAIN_LINE,   0, 1, k) < 1) return;
   if(CopyBuffer(hStoch, SIGNAL_LINE, 0, 1, d) < 1) return;
   int trend = DragonState(TimeCurrent());
   string trs = (trend > 0 ? "BULL" : (trend < 0 ? "BEAR" : "n/a"));
   string txt = StringFormat("PROBE  K=%.1f  D=%.1f  Dragon=%s  mode=%d  gate=%s",
                             k[0], d[0], trs, InpSigMode, (InpRequireDragon ? "on" : "off"));
   if(ObjectFind(0, "ProbePanel") < 0)
     {
      ObjectCreate(0, "ProbePanel", OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "ProbePanel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, "ProbePanel", OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, "ProbePanel", OBJPROP_YDISTANCE, 22);
      ObjectSetInteger(0, "ProbePanel", OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, "ProbePanel", OBJPROP_COLOR, clrGold);
     }
   ObjectSetString(0, "ProbePanel", OBJPROP_TEXT, txt);
  }
//+------------------------------------------------------------------+
