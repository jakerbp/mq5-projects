//+------------------------------------------------------------------+
//|                                                  Sniper_Math.mqh |
//|                   Mathematical & Statistical Helper Functions    |
//+------------------------------------------------------------------+
#property copyright "ZScoreMurreySniper"
#property strict

// NOTE: All globals, enums, structs are defined in ZScoreMurreySniper_v2.mq5
// before this file is #include'd. No extern/forward declarations needed.
//+------------------------------------------------------------------+
string GetBaseCurrency(string symbol)
  {
   if(StringLen(symbol) < 6) return "";
   string c = StringSubstr(symbol, 0, 3);
   StringToUpper(c);
   return c;
  }
string GetQuoteCurrency(string symbol)
  {
   if(StringLen(symbol) < 6) return "";
   string c = StringSubstr(symbol, 3, 3);
   StringToUpper(c);
   return c;
  }

bool CalcMurreyLevelsForSymbolCustom(string sym, ENUM_TIMEFRAMES mmTf, int mmLookback,
                                     double &mm_88, double &mm_48, double &mm_08, double &mmIncrement,
                                     double &mm_plus28, double &mm_plus18, double &mm_minus18, double &mm_minus28)
  {
   if(mmLookback < 8)
      return false;
   double highArr[], lowArr[], closeArr[];
   int copied;
   copied = CopyHigh(sym, mmTf, 1, mmLookback, highArr);
   if(copied < mmLookback)
      return false;
   copied = CopyLow(sym, mmTf, 1, mmLookback, lowArr);
   if(copied < mmLookback)
      return false;
   copied = CopyClose(sym, mmTf, 1, mmLookback, closeArr);
   if(copied < mmLookback)
      return false;

// Find highest/lowest of high, low, close arrays
   double hHigh = highArr[0], hClose = closeArr[0];
   double lLow = lowArr[0], lClose = closeArr[0];
   for(int i = 1; i < mmLookback; i++)
     {
      if(highArr[i] > hHigh)
         hHigh = highArr[i];
      if(closeArr[i] > hClose)
         hClose = closeArr[i];
      if(lowArr[i] < lLow)
         lLow = lowArr[i];
      if(closeArr[i] < lClose)
         lClose = closeArr[i];
     }

   double vHigh = (hHigh + hClose) / 2.0;
   double vLow  = (lLow + lClose) / 2.0;
   double vDist = vHigh - vLow;
   double tmpHigh = vLow < 0 ? -vLow : vHigh;
   double tmpLow  = vLow < 0 ? -vLow - vDist : vLow;
   bool   shift   = vLow < 0;

   // EPS should be declared globally in main file
   double safeHigh = MathMax(tmpHigh, EPS);
   double logTen = MathLog(10.0);
   double log8   = MathLog(8.0);
   double log2   = MathLog(2.0);

   double sfVarBase = MathLog(0.4 * safeHigh) / logTen;
   double sfVar = sfVarBase - MathFloor(sfVarBase);
   double srPow = MathFloor(MathLog(0.4 * safeHigh) / logTen);
   double srSmallPow = MathFloor(MathLog(0.005 * safeHigh) / log8);
   double SR;
   if(safeHigh > 25)
      SR = sfVar > 0 ? MathExp(logTen * (srPow + 1)) : MathExp(logTen * srPow);
   else
      SR = 100 * MathExp(log8 * srSmallPow);

   double safeRange = MathMax(tmpHigh - tmpLow, EPS);
   double nVar1 = MathLog(MathMax(SR / safeRange, EPS)) / log8;
   double nVar2 = nVar1 - MathFloor(nVar1);
   double N;
   if(nVar1 <= 0)
      N = 0;
   else
      N = nVar2 == 0 ? MathFloor(nVar1) : MathFloor(nVar1) + 1;

   double SI = MathMax(SR * MathExp(-N * log8), EPS);
   double ratio = MathMax(safeRange / SI, EPS);
   double M = MathFloor(1.0 / log2 * MathLog(ratio) + 0.0000001);
   double base = SI * MathExp((M - 1) * log2);
   double safeBase = MathMax(base, EPS);
   double I = MathRound((tmpHigh + tmpLow) * 0.5 / safeBase);

   double bot = (I - 1) * safeBase;
   double top = (I + 1) * safeBase;

   bool doShift = tmpHigh - top > 0.175 * (top - bot) || bot - tmpLow > 0.175 * (top - bot);
   int ER = doShift ? 1 : 0;

   double MM2 = ER == 0 ? M : (ER == 1 && M < 2 ? M + 1 : 0);
   double NN = ER == 0 ? N : (ER == 1 && M < 2 ? N : N - 1);

   double finalSI   = ER == 1 ? SR * MathExp(-NN * log8) : SI;
   double finalBase  = MathMax(finalSI * MathExp((MM2 - 1) * log2), EPS);
   double finalI     = ER == 1 ? MathRound((tmpHigh + tmpLow) * 0.5 / finalBase) : I;
   double finalBot   = ER == 1 ? (finalI - 1) * finalBase : bot;
   double finalTop   = ER == 1 ? (finalI + 1) * finalBase : top;

   double increment = (finalTop - finalBot) / 8.0;
   double absTop = shift ? -(finalBot - 3.0 * increment) : finalTop + 3.0 * increment;

   mm_plus28  = absTop - increment;
   mm_plus18  = absTop - 2.0 * increment;
   mm_88      = absTop - 3.0 * increment;
   mm_48      = absTop - 7.0 * increment;
   mm_08      = absTop - 11.0 * increment;
   mm_minus18 = absTop - 12.0 * increment;
   mm_minus28 = absTop - 13.0 * increment;
   mmIncrement = increment;
   return true;
  }

bool CalcMurreyLevelsForSymbol(string sym, double &mm_88, double &mm_48, double &mm_08, double &mmIncrement,
                               double &mm_plus28, double &mm_plus18, double &mm_minus18, double &mm_minus28)
  {
   return CalcMurreyLevelsForSymbolCustom(sym, (ENUM_TIMEFRAMES)MM_Timeframe, MM_Lookback,
                                          mm_88, mm_48, mm_08, mmIncrement,
                                          mm_plus28, mm_plus18, mm_minus18, mm_minus28);
  }

void CalcMurreyLevels(int pairIdx)
  {
   string sym = activePairs[pairIdx].symbolA;
   double mm88 = 0, mm48 = 0, mm08 = 0, mmInc = 0;
   double mmP28 = 0, mmP18 = 0, mmM18 = 0, mmM28 = 0;
   if(!CalcMurreyLevelsForSymbol(sym, mm88, mm48, mm08, mmInc, mmP28, mmP18, mmM18, mmM28))
      return;
   activePairs[pairIdx].mm_plus28  = mmP28;
   activePairs[pairIdx].mm_plus18  = mmP18;
   activePairs[pairIdx].mm_88      = mm88;
   activePairs[pairIdx].mm_48      = mm48;
   activePairs[pairIdx].mm_08      = mm08;
   activePairs[pairIdx].mm_minus18 = mmM18;
   activePairs[pairIdx].mm_minus28 = mmM28;
   activePairs[pairIdx].mmIncrement = mmInc;
  }

//+------------------------------------------------------------------+
//|  PEARSON CORRELATION                                             |
//+------------------------------------------------------------------+
double CalcPearsonCorrelation(string symA, string symB)
  {
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Corr_Timeframe;
   double closeA[], closeB[];
   int copiedA = CopyClose(symA, tf, 1, Corr_Lookback, closeA);
   int copiedB = CopyClose(symB, tf, 1, Corr_Lookback, closeB);
   if(copiedA < Corr_Lookback || copiedB < Corr_Lookback)
      return 0.0;

   int n = Corr_Lookback;
   double sumX=0, sumY=0, sumXY=0, sumX2=0, sumY2=0;
   for(int i = 0; i < n; i++)
     {
      sumX  += closeA[i];
      sumY  += closeB[i];
      sumXY += closeA[i] * closeB[i];
      sumX2 += closeA[i] * closeA[i];
      sumY2 += closeB[i] * closeB[i];
     }
   double denom = MathSqrt((n*sumX2 - sumX*sumX) * (n*sumY2 - sumY*sumY));
   if(denom < EPS)
      return 0.0;
   return (n*sumXY - sumX*sumY) / denom;
  }

//+------------------------------------------------------------------+
//|  Z-SCORE CALCULATION                                             |
//+------------------------------------------------------------------+
void CalcZScore(int pairIdx)
  {
   string symA = activePairs[pairIdx].symbolA;
   string symB = activePairs[pairIdx].symbolB;
   double closeA[], closeB[];
   int copiedA = CopyClose(symA, PERIOD_CURRENT, 1, Z_Lookback, closeA);
   int copiedB = CopyClose(symB, PERIOD_CURRENT, 1, Z_Lookback, closeB);
   if(copiedA < Z_Lookback || copiedB < Z_Lookback)
     {
      activePairs[pairIdx].zScore = 0;
      return;
     }
// Ratio-based z-score
   double ratios[];
   ArrayResize(ratios, Z_Lookback);
   for(int i = 0; i < Z_Lookback; i++)
     {
      ratios[i] = (closeB[i] > 0) ? closeA[i] / closeB[i] : 0;
     }
   double mean = 0;
   for(int i = 0; i < Z_Lookback; i++)
      mean += ratios[i];
   mean /= Z_Lookback;
   double stdDev = 0;
   for(int i = 0; i < Z_Lookback; i++)
      stdDev += MathPow(ratios[i] - mean, 2);
   stdDev = MathSqrt(stdDev / Z_Lookback);
   double currentRatio = ratios[Z_Lookback - 1];
   activePairs[pairIdx].zScore = (stdDev > 0) ? (currentRatio - mean) / stdDev : 0;
  }
