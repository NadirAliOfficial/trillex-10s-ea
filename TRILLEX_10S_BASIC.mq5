//+------------------------------------------------------------------+
//|                                       Trillex_InsaneEA_Scaled.mq5|
//|                 Multi-TF 3 EMA + PSAR + 10s Insane Mode + MM     |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- Inputs ---------------------------------
input group "General"
input long   InpMagicNumber              = 26041201;
input bool   InpOnePositionPerSymbol     = true;
input bool   InpAllowBuy                 = true;
input bool   InpAllowSell                = true;
input bool   InpCloseOnOppositeSignal    = true;

input group "EMA Settings"
input int    InpFastEMA                  = 5;
input int    InpMidEMA                   = 20;
input int    InpSlowEMA                  = 40;

input group "PSAR Settings"
input double InpSarStep                  = 0.02;
input double InpSarMaximum               = 0.2;

input group "Main Timeframes"
input bool   InpUseM5Filter              = true;
input bool   InpUse5SecFilter            = false;
input bool   InpUse10SecFilter           = false;

input group "Insane Mode"
input bool   InpUseInsaneMode            = true;
input bool   InpInsaneRequireM5          = true;
input bool   InpInsaneRequireFreshPSAR   = true;
input int    InpPSARConfirmBars          = 1;   // extra bars PSAR must hold after flip

enum ENUM_EXIT_MODE
{
   EXIT_BY_10S_PSAR_REVERSAL = 0,
   EXIT_BY_10S_EMA5_REVERSE_CLOSE = 1
};
input ENUM_EXIT_MODE InpInsaneExitMode   = EXIT_BY_10S_PSAR_REVERSAL;

input group "Money Management"
input bool   InpUseDynamicLots           = true;
input double InpFixedLots                = 1.0;
input double InpBaseBalanceStep          = 1000.0;
input double InpBaseLot                  = 1.0;
input double InpLotMultiplier            = 10.0;
input double InpMaxSingleOrderLot        = 500.0;
input int    InpMaxSplitOrders           = 20;
input bool   InpUseBalanceInsteadOfEquity= true;
input double InpMaxTotalLotsPerSignal    = 10000.0;

input group "Risk / Orders"
input int    InpStopLossPoints           = 200;  // safety net SL (0 = disabled)
input int    InpTakeProfitPoints         = 0;
input int    InpSlippagePoints           = 20;

input group "Safety / Sessions"
input bool   InpUseSessionFilter         = false;
input int    InpSessionStartHour         = 0;
input int    InpSessionStartMinute       = 0;
input int    InpSessionEndHour           = 23;
input int    InpSessionEndMinute         = 59;
input int    InpMaxSpreadPoints          = 30;   // spread cap — 0 = ignore

input group "Performance"
input int    InpMaxCustomBars            = 800;

//--------------------------- Structs ---------------------------------
struct SecBar
{
   datetime start;
   double   open;
   double   high;
   double   low;
   double   close;
   long     volume;
};

//--------------------------- Globals ---------------------------------
int g_emaFastM1 = INVALID_HANDLE;
int g_emaMidM1  = INVALID_HANDLE;
int g_emaSlowM1 = INVALID_HANDLE;
int g_sarM1     = INVALID_HANDLE;

int g_emaFastM5 = INVALID_HANDLE;
int g_emaMidM5  = INVALID_HANDLE;
int g_emaSlowM5 = INVALID_HANDLE;
int g_sarM5     = INVALID_HANDLE;

datetime g_lastM1BarTime = 0;

SecBar g_cur5s;
bool   g_hasCur5s = false;
SecBar g_bars5s[];

SecBar g_cur10s;
bool   g_hasCur10s = false;
SecBar g_bars10s[];

//--------------------------- Enums -----------------------------------
enum TrendDirection
{
   TREND_NONE = 0,
   TREND_UP   = 1,
   TREND_DOWN = -1
};

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
datetime BucketStart(datetime t, int seconds_step)
{
   return (datetime)(t - (t % seconds_step));
}

double NormalizeVolume(double volume)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      lotStep = 0.01;

   volume = MathMax(volume, minLot);
   volume = MathMin(volume, maxLot);

   double steps = MathFloor(volume / lotStep + 1e-8);
   double result = steps * lotStep;

   int digitsVol = 2;
   if(lotStep == 1.0) digitsVol = 0;
   else if(lotStep == 0.1) digitsVol = 1;
   else if(lotStep == 0.01) digitsVol = 2;
   else if(lotStep == 0.001) digitsVol = 3;

   return NormalizeDouble(result, digitsVol);
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_points = (ask - bid) / _Point;

   return (spread_points <= InpMaxSpreadPoints);
}

bool IsSessionOK()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMin   = InpSessionEndHour * 60 + InpSessionEndMinute;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);

   return (nowMin >= startMin || nowMin <= endMin);
}

bool HasOpenPositionBySymbol(string symbol)
{
   return PositionSelect(symbol);
}

int GetPositionTypeBySymbol(string symbol)
{
   if(!PositionSelect(symbol))
      return -1;

   return (int)PositionGetInteger(POSITION_TYPE);
}

bool ClosePositionBySymbol(string symbol)
{
   if(!PositionSelect(symbol))
      return true;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return trade.PositionClose(symbol);
}

void BuildSLTP(bool isBuy, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(InpStopLossPoints > 0)
         sl = NormalizePrice(ask - InpStopLossPoints * _Point);
      if(InpTakeProfitPoints > 0)
         tp = NormalizePrice(ask + InpTakeProfitPoints * _Point);
   }
   else
   {
      if(InpStopLossPoints > 0)
         sl = NormalizePrice(bid + InpStopLossPoints * _Point);
      if(InpTakeProfitPoints > 0)
         tp = NormalizePrice(bid - InpTakeProfitPoints * _Point);
   }
}

//+------------------------------------------------------------------+
//| Dynamic lot model                                                |
//+------------------------------------------------------------------+
double GetReferenceCapital()
{
   if(InpUseBalanceInsteadOfEquity)
      return AccountInfoDouble(ACCOUNT_BALANCE);

   return AccountInfoDouble(ACCOUNT_EQUITY);
}

double GetDynamicTargetLots()
{
   double capital = GetReferenceCapital();

   if(capital <= 0.0 || InpBaseBalanceStep <= 0.0 || InpBaseLot <= 0.0 || InpLotMultiplier <= 0.0)
      return InpFixedLots;

   double ratio = capital / InpBaseBalanceStep;
   int tier = 0;

   if(ratio >= 1.0)
      tier = (int)MathFloor(MathLog10(ratio) + 1e-9);
   else
      tier = 0;

   double lots = InpBaseLot * MathPow(InpLotMultiplier, tier);

   if(InpMaxTotalLotsPerSignal > 0.0)
      lots = MathMin(lots, InpMaxTotalLotsPerSignal);

   return lots;
}

double GetTradeLotsTotal()
{
   if(!InpUseDynamicLots)
      return NormalizeVolume(InpFixedLots);

   return GetDynamicTargetLots();
}

bool SendSplitOrders(bool isBuy)
{
   double totalLots = GetTradeLotsTotal();
   if(totalLots <= 0.0)
      return false;

   double symbolMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double effectiveMaxSingle = InpMaxSingleOrderLot;

   if(symbolMaxLot > 0.0)
      effectiveMaxSingle = MathMin(effectiveMaxSingle, symbolMaxLot);

   if(effectiveMaxSingle <= 0.0)
      return false;

   double sl, tp;
   BuildSLTP(isBuy, sl, tp);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   int sentOrders = 0;
   double remaining = totalLots;
   bool atLeastOneSent = false;

   while(remaining > 0.0 && sentOrders < InpMaxSplitOrders)
   {
      double chunk = MathMin(remaining, effectiveMaxSingle);
      chunk = NormalizeVolume(chunk);

      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(chunk < minLot)
         break;

      bool ok = false;
      if(isBuy)
         ok = trade.Buy(chunk, _Symbol, 0.0, sl, tp, "Scaled Buy");
      else
         ok = trade.Sell(chunk, _Symbol, 0.0, sl, tp, "Scaled Sell");

      if(!ok)
      {
         Print("Order send failed. Retcode=", trade.ResultRetcode(),
               " Desc=", trade.ResultRetcodeDescription(),
               " Chunk=", DoubleToString(chunk, 2));
         break;
      }

      atLeastOneSent = true;
      remaining -= chunk;
      sentOrders++;
   }

   if(remaining > 0.0)
   {
      Print("Not all requested lots were sent. Remaining lots=", DoubleToString(remaining, 2),
            " SentOrders=", sentOrders);
   }

   return atLeastOneSent;
}

bool OpenBuy()
{
   if(!InpAllowBuy)
      return false;

   if(InpOnePositionPerSymbol && HasOpenPositionBySymbol(_Symbol))
      return false;

   return SendSplitOrders(true);
}

bool OpenSell()
{
   if(!InpAllowSell)
      return false;

   if(InpOnePositionPerSymbol && HasOpenPositionBySymbol(_Symbol))
      return false;

   return SendSplitOrders(false);
}

//+------------------------------------------------------------------+
//| Synthetic seconds bars                                           |
//+------------------------------------------------------------------+
void PushClosedBar(SecBar &arr[], const SecBar &bar)
{
   int sz = ArraySize(arr);
   ArrayResize(arr, sz + 1);
   arr[sz] = bar;

   if(ArraySize(arr) > InpMaxCustomBars)
   {
      int newSize = ArraySize(arr) - 1;
      for(int i = 0; i < newSize; i++)
         arr[i] = arr[i + 1];
      ArrayResize(arr, newSize);
   }
}

// Uses mid-price to reduce spread noise in real tick mode
bool UpdateSyntheticBar(const int secStep, SecBar &currentBar, bool &hasCurrent, SecBar &history[])
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double mid = (tick.bid + tick.ask) * 0.5;
   datetime bucket = BucketStart(tick.time, secStep);
   bool closedNewBar = false;

   if(!hasCurrent)
   {
      currentBar.start  = bucket;
      currentBar.open   = mid;
      currentBar.high   = mid;
      currentBar.low    = mid;
      currentBar.close  = mid;
      currentBar.volume = 1;
      hasCurrent = true;
      return false;
   }

   if(bucket == currentBar.start)
   {
      if(mid > currentBar.high) currentBar.high = mid;
      if(mid < currentBar.low)  currentBar.low  = mid;
      currentBar.close = mid;
      currentBar.volume++;
   }
   else if(bucket > currentBar.start)
   {
      PushClosedBar(history, currentBar);
      closedNewBar = true;

      currentBar.start  = bucket;
      currentBar.open   = mid;
      currentBar.high   = mid;
      currentBar.low    = mid;
      currentBar.close  = mid;
      currentBar.volume = 1;
   }

   return closedNewBar;
}

//+------------------------------------------------------------------+
//| Synthetic EMA / PSAR                                             |
//+------------------------------------------------------------------+
bool ExtractOHLC(const SecBar &bars[], double &open[], double &high[], double &low[], double &close[])
{
   int n = ArraySize(bars);
   if(n <= 0)
      return false;

   ArrayResize(open, n);
   ArrayResize(high, n);
   ArrayResize(low, n);
   ArrayResize(close, n);

   for(int i = 0; i < n; i++)
   {
      open[i]  = bars[i].open;
      high[i]  = bars[i].high;
      low[i]   = bars[i].low;
      close[i] = bars[i].close;
   }
   return true;
}

void CalcEMA(const double &price[], int period, double &ema[])
{
   int n = ArraySize(price);
   ArrayResize(ema, n);
   if(n <= 0 || period <= 0)
      return;

   double alpha = 2.0 / (period + 1.0);
   ema[0] = price[0];

   for(int i = 1; i < n; i++)
      ema[i] = alpha * price[i] + (1.0 - alpha) * ema[i - 1];
}

void CalcPSAR(const double &high[], const double &low[], const double &close[],
              double step, double maxAF, double &sar[])
{
   int n = ArraySize(close);
   ArrayResize(sar, n);

   if(n <= 0)
      return;

   if(n == 1)
   {
      sar[0] = low[0];
      return;
   }

   bool upTrend = (close[1] >= close[0]);
   double af = step;
   double ep = upTrend ? MathMax(high[0], high[1]) : MathMin(low[0], low[1]);

   sar[0] = upTrend ? low[0] : high[0];
   sar[1] = sar[0];

   for(int i = 2; i < n; i++)
   {
      sar[i] = sar[i - 1] + af * (ep - sar[i - 1]);

      if(upTrend)
      {
         sar[i] = MathMin(sar[i], low[i - 1]);
         sar[i] = MathMin(sar[i], low[i - 2]);

         if(low[i] < sar[i])
         {
            upTrend = false;
            sar[i] = ep;
            ep = low[i];
            af = step;
         }
         else
         {
            if(high[i] > ep)
            {
               ep = high[i];
               af = MathMin(af + step, maxAF);
            }
         }
      }
      else
      {
         sar[i] = MathMax(sar[i], high[i - 1]);
         sar[i] = MathMax(sar[i], high[i - 2]);

         if(high[i] > sar[i])
         {
            upTrend = true;
            sar[i] = ep;
            ep = high[i];
            af = step;
         }
         else
         {
            if(low[i] < ep)
            {
               ep = low[i];
               af = MathMin(af + step, maxAF);
            }
         }
      }
   }
}

TrendDirection GetSyntheticTrend(const SecBar &bars[])
{
   int n = ArraySize(bars);
   if(n < MathMax(InpSlowEMA + 5, 20))
      return TREND_NONE;

   double o[], h[], l[], c[];
   if(!ExtractOHLC(bars, o, h, l, c))
      return TREND_NONE;

   double emaFast[], emaMid[], emaSlow[], sar[];
   CalcEMA(c, InpFastEMA, emaFast);
   CalcEMA(c, InpMidEMA, emaMid);
   CalcEMA(c, InpSlowEMA, emaSlow);
   CalcPSAR(h, l, c, InpSarStep, InpSarMaximum, sar);

   int i = n - 1;

   bool up   = (emaFast[i] > emaMid[i] && emaMid[i] > emaSlow[i] && sar[i] < c[i]);
   bool down = (emaFast[i] < emaMid[i] && emaMid[i] < emaSlow[i] && sar[i] > c[i]);

   if(up) return TREND_UP;
   if(down) return TREND_DOWN;
   return TREND_NONE;
}

// Requires PSAR to hold its new direction for InpPSARConfirmBars extra bars
// before treating the flip as a valid entry signal.
bool GetSyntheticFreshPSARSignal(const SecBar &bars[], TrendDirection &signalDir)
{
   signalDir = TREND_NONE;

   int confirmBars = MathMax(InpPSARConfirmBars, 0);
   int minBars = MathMax(InpSlowEMA + 10 + confirmBars, 25 + confirmBars);

   int n = ArraySize(bars);
   if(n < minBars)
      return false;

   double o[], h[], l[], c[];
   if(!ExtractOHLC(bars, o, h, l, c))
      return false;

   double emaFast[], emaMid[], emaSlow[], sar[];
   CalcEMA(c, InpFastEMA, emaFast);
   CalcEMA(c, InpMidEMA, emaMid);
   CalcEMA(c, InpSlowEMA, emaSlow);
   CalcPSAR(h, l, c, InpSarStep, InpSarMaximum, sar);

   // flipBar is the bar where the PSAR crossed; confirmBars bars must have
   // held the same direction from flipBar up to and including the current bar.
   int cur     = n - 1;
   int flipBar = cur - confirmBars;         // where the flip happened
   int prevBar = flipBar - 1;               // bar before the flip

   if(prevBar < 0)
      return false;

   bool prevSarBelow = (sar[prevBar] < c[prevBar]);
   bool flipSarBelow = (sar[flipBar] < c[flipBar]);

   bool freshBuyPSAR  = (!prevSarBelow && flipSarBelow);
   bool freshSellPSAR = ( prevSarBelow && !flipSarBelow);

   if(!freshBuyPSAR && !freshSellPSAR)
      return false;

   // Verify PSAR held the new direction through all confirmation bars
   for(int j = flipBar; j <= cur; j++)
   {
      if(freshBuyPSAR  && !(sar[j] < c[j])) return false;
      if(freshSellPSAR && !(sar[j] > c[j])) return false;
   }

   bool emaBull = (emaFast[cur] > emaMid[cur] && emaMid[cur] > emaSlow[cur]);
   bool emaBear = (emaFast[cur] < emaMid[cur] && emaMid[cur] < emaSlow[cur]);

   if(freshBuyPSAR && emaBull)
   {
      signalDir = TREND_UP;
      return true;
   }

   if(freshSellPSAR && emaBear)
   {
      signalDir = TREND_DOWN;
      return true;
   }

   return false;
}

bool IsSyntheticPSARReversalAgainstPosition(const SecBar &bars[], int posType)
{
   int n = ArraySize(bars);
   if(n < 3)
      return false;

   double o[], h[], l[], c[];
   if(!ExtractOHLC(bars, o, h, l, c))
      return false;

   double sar[];
   CalcPSAR(h, l, c, InpSarStep, InpSarMaximum, sar);

   int i = n - 1;

   if(posType == POSITION_TYPE_BUY)  return (sar[i] > c[i]);
   if(posType == POSITION_TYPE_SELL) return (sar[i] < c[i]);

   return false;
}

bool IsSyntheticEMA5ReverseCloseAgainstPosition(const SecBar &bars[], int posType)
{
   int n = ArraySize(bars);
   if(n < MathMax(InpFastEMA + 3, 10))
      return false;

   double o[], h[], l[], c[];
   if(!ExtractOHLC(bars, o, h, l, c))
      return false;

   double emaFast[];
   CalcEMA(c, InpFastEMA, emaFast);

   int i = n - 1;

   if(posType == POSITION_TYPE_BUY)  return (c[i] < emaFast[i]);
   if(posType == POSITION_TYPE_SELL) return (c[i] > emaFast[i]);

   return false;
}

//+------------------------------------------------------------------+
//| Standard timeframe trend                                         |
//+------------------------------------------------------------------+
bool GetTfValues(int emaFastHandle, int emaMidHandle, int emaSlowHandle, int sarHandle,
                 ENUM_TIMEFRAMES tf,
                 double &emaFast, double &emaMid, double &emaSlow, double &sar, double &closePrice)
{
   double bufFast[1], bufMid[1], bufSlow[1], bufSar[1], closeBuf[1];

   if(CopyBuffer(emaFastHandle, 0, 1, 1, bufFast) < 1) return false;
   if(CopyBuffer(emaMidHandle,  0, 1, 1, bufMid)  < 1) return false;
   if(CopyBuffer(emaSlowHandle, 0, 1, 1, bufSlow) < 1) return false;
   if(CopyBuffer(sarHandle,     0, 1, 1, bufSar)  < 1) return false;
   if(CopyClose(_Symbol, tf, 1, 1, closeBuf) < 1) return false;

   emaFast    = bufFast[0];
   emaMid     = bufMid[0];
   emaSlow    = bufSlow[0];
   sar        = bufSar[0];
   closePrice = closeBuf[0];
   return true;
}

TrendDirection GetM1Trend()
{
   double ef, em, es, sar, c;
   if(!GetTfValues(g_emaFastM1, g_emaMidM1, g_emaSlowM1, g_sarM1, PERIOD_M1, ef, em, es, sar, c))
      return TREND_NONE;

   bool up   = (ef > em && em > es && sar < c);
   bool down = (ef < em && em < es && sar > c);

   if(up) return TREND_UP;
   if(down) return TREND_DOWN;
   return TREND_NONE;
}

TrendDirection GetM5Trend()
{
   double ef, em, es, sar, c;
   if(!GetTfValues(g_emaFastM5, g_emaMidM5, g_emaSlowM5, g_sarM5, PERIOD_M5, ef, em, es, sar, c))
      return TREND_NONE;

   bool up   = (ef > em && em > es && sar < c);
   bool down = (ef < em && em < es && sar > c);

   if(up) return TREND_UP;
   if(down) return TREND_DOWN;
   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| Combined logic                                                   |
//+------------------------------------------------------------------+
TrendDirection GetCombinedTrendNormal()
{
   TrendDirection m1 = GetM1Trend();
   if(m1 == TREND_NONE)
      return TREND_NONE;

   if(InpUseM5Filter)
   {
      TrendDirection m5 = GetM5Trend();
      if(m5 != m1)
         return TREND_NONE;
   }

   if(InpUse5SecFilter)
   {
      TrendDirection t5 = GetSyntheticTrend(g_bars5s);
      if(t5 != m1)
         return TREND_NONE;
   }

   if(InpUse10SecFilter)
   {
      TrendDirection t10 = GetSyntheticTrend(g_bars10s);
      if(t10 != m1)
         return TREND_NONE;
   }

   return m1;
}

TrendDirection GetCombinedTrendInsaneBase()
{
   TrendDirection m1 = GetM1Trend();
   if(m1 == TREND_NONE)
      return TREND_NONE;

   if(InpInsaneRequireM5)
   {
      TrendDirection m5 = GetM5Trend();
      if(m5 != m1)
         return TREND_NONE;
   }

   return m1;
}

//+------------------------------------------------------------------+
//| Signal processing                                                |
//+------------------------------------------------------------------+
void ProcessNormalModeOnNewM1Bar()
{
   TrendDirection finalTrend = GetCombinedTrendNormal();
   if(finalTrend == TREND_NONE)
      return;

   if(HasOpenPositionBySymbol(_Symbol))
   {
      if(InpCloseOnOppositeSignal)
      {
         int posType = GetPositionTypeBySymbol(_Symbol);
         if((posType == POSITION_TYPE_BUY  && finalTrend == TREND_DOWN) ||
            (posType == POSITION_TYPE_SELL && finalTrend == TREND_UP))
         {
            ClosePositionBySymbol(_Symbol);
         }
      }
      return;
   }

   if(finalTrend == TREND_UP)
      OpenBuy();
   else if(finalTrend == TREND_DOWN)
      OpenSell();
}

void ProcessInsaneModeOnNew10sBar()
{
   TrendDirection baseTrend = GetCombinedTrendInsaneBase();
   if(baseTrend == TREND_NONE)
      return;

   TrendDirection tenSecSignal = TREND_NONE;
   bool haveFreshPSARSignal = GetSyntheticFreshPSARSignal(g_bars10s, tenSecSignal);

   if(InpInsaneRequireFreshPSAR)
   {
      if(!haveFreshPSARSignal)
         return;

      if(tenSecSignal != baseTrend)
         return;
   }
   else
   {
      TrendDirection tenSecTrend = GetSyntheticTrend(g_bars10s);
      if(tenSecTrend != baseTrend)
         return;
   }

   if(HasOpenPositionBySymbol(_Symbol))
   {
      if(InpCloseOnOppositeSignal)
      {
         int posType = GetPositionTypeBySymbol(_Symbol);
         if((posType == POSITION_TYPE_BUY  && baseTrend == TREND_DOWN) ||
            (posType == POSITION_TYPE_SELL && baseTrend == TREND_UP))
         {
            ClosePositionBySymbol(_Symbol);
         }
      }
      return;
   }

   if(baseTrend == TREND_UP)
      OpenBuy();
   else if(baseTrend == TREND_DOWN)
      OpenSell();
}

void ProcessInsaneExitsOnNew10sBar()
{
   if(!HasOpenPositionBySymbol(_Symbol))
      return;

   int posType = GetPositionTypeBySymbol(_Symbol);
   if(posType != POSITION_TYPE_BUY && posType != POSITION_TYPE_SELL)
      return;

   bool exitNow = false;

   if(InpInsaneExitMode == EXIT_BY_10S_PSAR_REVERSAL)
      exitNow = IsSyntheticPSARReversalAgainstPosition(g_bars10s, posType);
   else
      exitNow = IsSyntheticEMA5ReverseCloseAgainstPosition(g_bars10s, posType);

   if(exitNow)
      ClosePositionBySymbol(_Symbol);
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   g_emaFastM1 = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_emaMidM1  = iMA(_Symbol, PERIOD_M1, InpMidEMA,  0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowM1 = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_sarM1     = iSAR(_Symbol, PERIOD_M1, InpSarStep, InpSarMaximum);

   g_emaFastM5 = iMA(_Symbol, PERIOD_M5, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_emaMidM5  = iMA(_Symbol, PERIOD_M5, InpMidEMA,  0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowM5 = iMA(_Symbol, PERIOD_M5, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_sarM5     = iSAR(_Symbol, PERIOD_M5, InpSarStep, InpSarMaximum);

   if(g_emaFastM1 == INVALID_HANDLE || g_emaMidM1 == INVALID_HANDLE || g_emaSlowM1 == INVALID_HANDLE || g_sarM1 == INVALID_HANDLE ||
      g_emaFastM5 == INVALID_HANDLE || g_emaMidM5 == INVALID_HANDLE || g_emaSlowM5 == INVALID_HANDLE || g_sarM5 == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   g_lastM1BarTime = iTime(_Symbol, PERIOD_M1, 0);

   ArrayResize(g_bars5s, 0);
   ArrayResize(g_bars10s, 0);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaFastM1 != INVALID_HANDLE) IndicatorRelease(g_emaFastM1);
   if(g_emaMidM1  != INVALID_HANDLE) IndicatorRelease(g_emaMidM1);
   if(g_emaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM1);
   if(g_sarM1     != INVALID_HANDLE) IndicatorRelease(g_sarM1);

   if(g_emaFastM5 != INVALID_HANDLE) IndicatorRelease(g_emaFastM5);
   if(g_emaMidM5  != INVALID_HANDLE) IndicatorRelease(g_emaMidM5);
   if(g_emaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM5);
   if(g_sarM5     != INVALID_HANDLE) IndicatorRelease(g_sarM5);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsSessionOK())
      return;

   if(!IsSpreadOK())
      return;

   bool new5sClosed  = UpdateSyntheticBar(5,  g_cur5s,  g_hasCur5s,  g_bars5s);
   bool new10sClosed = UpdateSyntheticBar(10, g_cur10s, g_hasCur10s, g_bars10s);

   datetime m1bar0 = iTime(_Symbol, PERIOD_M1, 0);
   bool newM1Bar = false;

   if(m1bar0 != 0 && m1bar0 != g_lastM1BarTime)
   {
      g_lastM1BarTime = m1bar0;
      newM1Bar = true;
   }

   if(new10sClosed && ArraySize(g_bars10s) > 5)
      ProcessInsaneExitsOnNew10sBar();

   if(InpUseInsaneMode)
   {
      if(new10sClosed && ArraySize(g_bars10s) > MathMax(InpSlowEMA + 10 + InpPSARConfirmBars, 25 + InpPSARConfirmBars))
         ProcessInsaneModeOnNew10sBar();
   }
   else
   {
      if(newM1Bar)
         ProcessNormalModeOnNewM1Bar();
   }
}
