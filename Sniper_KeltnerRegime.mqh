//+------------------------------------------------------------------+
//|                                         Sniper_KeltnerRegime.mqh |
//|  Keltner Channel structural regime filter (Grid-Safe)            |
//|  Ported from Pine Script logic by jrbp                           |
//+------------------------------------------------------------------+
#ifndef __SNIPER_KELTNER_REGIME_MQH__
#define __SNIPER_KELTNER_REGIME_MQH__

#include "Sniper_Math.mqh"

enum ENUM_KREGIME_STATE
  {
   KREGIME_CALM_RANGE,
   KREGIME_DIRECTIONAL_UP,
   KREGIME_DIRECTIONAL_DOWN,
   KREGIME_CONTAINED_UP,
   KREGIME_CONTAINED_DOWN,
   KREGIME_EXPANDING_UP,
   KREGIME_EXPANDING_DOWN,
   KREGIME_NA
  };

struct KRegimeConfig
  {
   ENUM_TIMEFRAMES   timeframe;
   int               vwmaPeriod;
   int               atrPeriod;
   double            atrMult;
   int               slopeLookback;
   double            flatThreshold;
   double            widthThreshold;
  };

struct KRegimeContext
  {
   string            symbol;
   int               atrHandle;
   bool              initialized;
   datetime          lastBarTime;
   ENUM_KREGIME_STATE prevState;
   ENUM_KREGIME_STATE state;
   double            midSlope;
   double            widthDeltaAtr;
   bool              isTrending;
   bool              isExpanding;
   bool              valid;
  };

KRegimeConfig g_kRegimeCfg;
KRegimeContext g_kRegimeCtx[];

//+------------------------------------------------------------------+
//| Custom VWMA Calculation: Sum(Close * Volume) / Sum(Volume)       |
//+------------------------------------------------------------------+
double KRegimeCalculateVWMA(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
  {
   double closeBuf[];
   long volBuf[];
   if(CopyClose(symbol, tf, shift, period, closeBuf) < period)
      return 0.0;
   if(CopyTickVolume(symbol, tf, shift, period, volBuf) < period)
      return 0.0;

   double sumPV = 0.0;
   long sumV = 0;
   for(int i = 0; i < period; i++)
     {
      sumPV += closeBuf[i] * (double)volBuf[i];
      sumV += volBuf[i];
     }
   return (sumV > 0) ? (sumPV / (double)sumV) : closeBuf[period - 1];
  }

void KRegimeResetContext(KRegimeContext &ctx)
  {
   ctx.initialized = false;
   ctx.lastBarTime = 0;
   ctx.prevState = KREGIME_NA;
   ctx.state = KREGIME_NA;
   ctx.midSlope = 0.0;
   ctx.widthDeltaAtr = 0.0;
   ctx.isTrending = false;
   ctx.isExpanding = false;
   ctx.valid = false;
  }

void KRegimeSetConfig(const ENUM_TIMEFRAMES timeframe,
                      const int vwmaPeriod,
                      const int atrPeriod,
                      const double atrMult,
                      const int slopeLookback,
                      const double flatThreshold,
                      const double widthThreshold)
  {
   g_kRegimeCfg.timeframe = timeframe;
   g_kRegimeCfg.vwmaPeriod = MathMax(2, vwmaPeriod);
   g_kRegimeCfg.atrPeriod = MathMax(2, atrPeriod);
   g_kRegimeCfg.atrMult = MathMax(0.1, atrMult);
   g_kRegimeCfg.slopeLookback = MathMax(1, slopeLookback);
   g_kRegimeCfg.flatThreshold = flatThreshold;
   g_kRegimeCfg.widthThreshold = widthThreshold;
  }

int KRegimeFindContext(const string symbol)
  {
   for(int i = 0; i < ArraySize(g_kRegimeCtx); i++)
     {
      if(g_kRegimeCtx[i].symbol == symbol)
         return i;
     }
   return -1;
  }

int KRegimeEnsureContext(const string symbol)
  {
   int idx = KRegimeFindContext(symbol);
   if(idx >= 0)
     {
      if(g_kRegimeCtx[idx].atrHandle == INVALID_HANDLE)
         g_kRegimeCtx[idx].atrHandle = iATR(symbol, g_kRegimeCfg.timeframe, g_kRegimeCfg.atrPeriod);
      return idx;
     }

   idx = ArraySize(g_kRegimeCtx);
   ArrayResize(g_kRegimeCtx, idx + 1);
   g_kRegimeCtx[idx].symbol = symbol;
   g_kRegimeCtx[idx].atrHandle = iATR(symbol, g_kRegimeCfg.timeframe, g_kRegimeCfg.atrPeriod);
   KRegimeResetContext(g_kRegimeCtx[idx]);
   return idx;
  }

bool KRegimeUpdateSymbol(const string symbol)
  {
   int idx = KRegimeEnsureContext(symbol);
   if(idx < 0) return false;
   
   KRegimeContext ctx = g_kRegimeCtx[idx];
   if(ctx.atrHandle == INVALID_HANDLE) return false;

   datetime tBar = iTime(symbol, g_kRegimeCfg.timeframe, 1);
   if(tBar <= 0) return false;
   if(ctx.lastBarTime == tBar && ctx.initialized) return true;

   int lb = g_kRegimeCfg.slopeLookback;
   
   // Get HTF Data
   double htfATR = 0.0;
   double atrBuf[];
   if(CopyBuffer(ctx.atrHandle, 0, 1, 1, atrBuf) > 0)
      htfATR = atrBuf[0];
   
   if(htfATR <= 0) return false;

   double v1 = KRegimeCalculateVWMA(symbol, g_kRegimeCfg.timeframe, g_kRegimeCfg.vwmaPeriod, 1);
   double v2 = KRegimeCalculateVWMA(symbol, g_kRegimeCfg.timeframe, g_kRegimeCfg.vwmaPeriod, 1 + lb);
   
   if(v1 <= 0 || v2 <= 0) return false;

   double atrPast = 0.0;
   if(CopyBuffer(ctx.atrHandle, 0, 1 + lb, 1, atrBuf) > 0)
      atrPast = atrBuf[0];
   else
      atrPast = htfATR;

   // Upper/Lower Bands
   double upperNow = v1 + (htfATR * g_kRegimeCfg.atrMult);
   double lowerNow = v1 - (htfATR * g_kRegimeCfg.atrMult);
   
   double upperPrev = v2 + (atrPast * g_kRegimeCfg.atrMult);
   double lowerPrev = v2 - (atrPast * g_kRegimeCfg.atrMult);

   // Slopes
   double upperSlope = (upperNow - upperPrev) / htfATR;
   double lowerSlope = (lowerNow - lowerPrev) / htfATR;
   ctx.midSlope = (upperSlope + lowerSlope) / 2.0;

   // Width Expansion
   double widthNow = upperNow - lowerNow;
   double widthPrev = upperPrev - lowerPrev;
   ctx.widthDeltaAtr = (widthNow - widthPrev) / htfATR;

   // Preserve previous state for transition-aware policies.
   ENUM_KREGIME_STATE priorState = ctx.state;

   // Regime Logic
   ctx.isTrending = MathAbs(ctx.midSlope) > g_kRegimeCfg.flatThreshold;
   ctx.isExpanding = ctx.widthDeltaAtr > g_kRegimeCfg.widthThreshold;
   
   if(!ctx.isTrending && !ctx.isExpanding)
      ctx.state = KREGIME_CALM_RANGE;
   else if(!ctx.isTrending && ctx.isExpanding)
      ctx.state = (ctx.midSlope > 0) ? KREGIME_DIRECTIONAL_UP : KREGIME_DIRECTIONAL_DOWN;
   else if(ctx.isTrending && !ctx.isExpanding)
      ctx.state = (ctx.midSlope > 0) ? KREGIME_CONTAINED_UP : KREGIME_CONTAINED_DOWN;
   else if(ctx.isTrending && ctx.isExpanding)
      ctx.state = (ctx.midSlope > 0) ? KREGIME_EXPANDING_UP : KREGIME_EXPANDING_DOWN;

   ctx.prevState = priorState;
   ctx.lastBarTime = tBar;
   ctx.initialized = true;
   ctx.valid = true;
   
   g_kRegimeCtx[idx] = ctx;
   return true;
  }

void KRegimePrepareSymbols(string &symbols[])
  {
   for(int i = 0; i < ArraySize(symbols); i++)
     {
      if(StringLen(symbols[i]) > 0)
         KRegimeEnsureContext(symbols[i]);
     }
  }

void KRegimeRelease()
  {
   for(int i = 0; i < ArraySize(g_kRegimeCtx); i++)
     {
      if(g_kRegimeCtx[i].atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_kRegimeCtx[i].atrHandle);
     }
   ArrayResize(g_kRegimeCtx, 0);
  }

bool KRegimeGetSnapshot(const string symbol, ENUM_KREGIME_STATE &stateOut, double &midSlopeOut, double &widthDeltaOut, bool &validOut)
  {
   int idx = KRegimeFindContext(symbol);
   if(idx < 0) return false;
   
   stateOut = g_kRegimeCtx[idx].state;
   midSlopeOut = g_kRegimeCtx[idx].midSlope;
   widthDeltaOut = g_kRegimeCtx[idx].widthDeltaAtr;
   validOut = g_kRegimeCtx[idx].valid;
   return true;
  }

bool KRegimeGetTransitionSnapshot(const string symbol,
                                  ENUM_KREGIME_STATE &prevStateOut,
                                  ENUM_KREGIME_STATE &stateOut,
                                  double &midSlopeOut,
                                  double &widthDeltaOut,
                                  bool &validOut)
  {
   int idx = KRegimeFindContext(symbol);
   if(idx < 0) return false;

   prevStateOut = g_kRegimeCtx[idx].prevState;
   stateOut = g_kRegimeCtx[idx].state;
   midSlopeOut = g_kRegimeCtx[idx].midSlope;
   widthDeltaOut = g_kRegimeCtx[idx].widthDeltaAtr;
   validOut = g_kRegimeCtx[idx].valid;
   return true;
  }

bool KRegimeIsRangeState(const ENUM_KREGIME_STATE st)
  {
   return (st == KREGIME_CALM_RANGE ||
           st == KREGIME_DIRECTIONAL_UP ||
           st == KREGIME_DIRECTIONAL_DOWN);
  }

bool KRegimeIsTrendState(const ENUM_KREGIME_STATE st)
  {
   return (st == KREGIME_CONTAINED_UP ||
           st == KREGIME_CONTAINED_DOWN ||
           st == KREGIME_EXPANDING_UP ||
           st == KREGIME_EXPANDING_DOWN);
  }

bool KRegimeIsRangeToTrendTransition(const ENUM_KREGIME_STATE prev, const ENUM_KREGIME_STATE cur)
  {
   return KRegimeIsRangeState(prev) && KRegimeIsTrendState(cur);
  }

bool KRegimeIsTrendToRangeTransition(const ENUM_KREGIME_STATE prev, const ENUM_KREGIME_STATE cur)
  {
   return KRegimeIsTrendState(prev) && KRegimeIsRangeState(cur);
  }

bool KRegimeIsEscalationTransition(const ENUM_KREGIME_STATE prev, const ENUM_KREGIME_STATE cur)
  {
   return ((prev == KREGIME_CONTAINED_UP && cur == KREGIME_EXPANDING_UP) ||
           (prev == KREGIME_CONTAINED_DOWN && cur == KREGIME_EXPANDING_DOWN));
  }

string KRegimeStateName(const ENUM_KREGIME_STATE state)
  {
   switch(state)
     {
      case KREGIME_CALM_RANGE:      return "CALM RNG";
      case KREGIME_DIRECTIONAL_UP:  return "DIR UP";
      case KREGIME_DIRECTIONAL_DOWN:return "DIR DN";
      case KREGIME_CONTAINED_UP:    return "CONT UP";
      case KREGIME_CONTAINED_DOWN:  return "CONT DN";
      case KREGIME_EXPANDING_UP:    return "EXP UP";
      case KREGIME_EXPANDING_DOWN:  return "EXP DN";
      default:                      return "N/A";
     }
  }

double KRegimeGetGridMultiplier(const string symbol);
double KRegimeGetLotMultiplier(const string symbol);

#endif // __SNIPER_KELTNER_REGIME_MQH__
