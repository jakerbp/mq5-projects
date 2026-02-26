//+------------------------------------------------------------------+
//|                                             Sniper_Markov.mqh    |
//|  Markov structural regime filter (ported from Pine Script)       |
//+------------------------------------------------------------------+
#ifndef __SNIPER_MARKOV_MQH__
#define __SNIPER_MARKOV_MQH__

#define MARKOV_UPTREND   1
#define MARKOV_NEUTRAL   0
#define MARKOV_DOWNTREND -1
#define MARKOV_ROWS      18
#define MARKOV_COLS      3
#define MARKOV_MODE_OFF        0
#define MARKOV_MODE_DIRECTIONAL 1
#define MARKOV_MODE_TRENDING   2
#define MARKOV_MODE_RANGING    3
#define MARKOV_MODE_DYNAMIC    4

struct MarkovConfig
  {
   int               mode;
   ENUM_TIMEFRAMES   timeframe;
   int               lookbackPeriod;
   int               atrLength;
   int               smoothLen;
   double            triggerThresh;
   double            exitThresh;
   int               volPercentileLb;
   double            memoryDecay;
   bool              useSecondOrder;
   int               evEmaLength;
   double            minSampleSize;
   int               rangeLookback;
   int               macroLen;
   int               microLen;
   int               slopeLen;
   double            slopeFlatAtrMult;
   int               minTrendBars;
   bool              blockIfUntrained;
   double            minConfidence;
   double            minProbGap;
   double            minEdge;
  };

struct MarkovContext
  {
   string            symbol;
   int               atrHandle;
   int               macroHandle;
   int               microHandle;
   bool              initialized;
   datetime          lastBarTime;
   int               state;
   int               prevState;
   int               prev2State;
   int               trendBars;
   bool              hasSmoothed;
   double            smoothedChange;
   double            transMat[MARKOV_ROWS][MARKOV_COLS];
   double            rowTotals[MARKOV_ROWS];
   double            evMatrix[MARKOV_ROWS];
   double            pDown;
   double            pNeu;
   double            pUp;
   double            confidence;
   double            entropyNorm;
   double            expectedValue;
   double            edge;
   double            effectiveSamples;
   bool              valid;
   double            volRatio;
  };

MarkovConfig g_markovCfg;
MarkovContext g_markovCtx[];

int MarkovStateToIndex(const int state)
  {
   if(state == MARKOV_UPTREND)
      return 2;
   if(state == MARKOV_NEUTRAL)
      return 1;
   return 0;
  }

int MarkovRegimeOffset(const bool highVol)
  {
   return highVol ? 9 : 0;
  }

bool MarkovCopyBufferValue(const int handle, const int shift, double &valueOut)
  {
   if(handle == INVALID_HANDLE)
      return false;
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return false;
   valueOut = buf[0];
   return true;
  }

void MarkovResetContext(MarkovContext &ctx)
  {
   ctx.initialized = false;
   ctx.lastBarTime = 0;
   ctx.state = MARKOV_NEUTRAL;
   ctx.prevState = MARKOV_NEUTRAL;
   ctx.prev2State = MARKOV_NEUTRAL;
   ctx.trendBars = 0;
   ctx.hasSmoothed = false;
   ctx.smoothedChange = 0.0;
   ctx.pDown = 0.3333;
   ctx.pNeu = 0.3333;
   ctx.pUp = 0.3333;
   ctx.confidence = 0.0;
   ctx.entropyNorm = 1.0;
   ctx.expectedValue = 0.0;
   ctx.edge = 0.0;
   ctx.effectiveSamples = 0.0;
   ctx.valid = false;
   ctx.volRatio = 1.0;
   for(int r = 0; r < MARKOV_ROWS; r++)
     {
      ctx.rowTotals[r] = 3.0;
      ctx.evMatrix[r] = 0.0;
      for(int c = 0; c < MARKOV_COLS; c++)
         ctx.transMat[r][c] = 1.0;
     }
  }

void MarkovSetConfig(const int mode,
                     const ENUM_TIMEFRAMES timeframe,
                     const int lookbackPeriod,
                     const int atrLength,
                     const int smoothLen,
                     const double triggerThresh,
                     const double exitThresh,
                     const int volPercentileLb,
                     const double memoryDecay,
                     const bool useSecondOrder,
                     const int evEmaLength,
                     const double minSampleSize,
                     const int rangeLookback,
                     const int macroLen,
                     const int microLen,
                     const int slopeLen,
                     const double slopeFlatAtrMult,
                     const int minTrendBars,
                     const bool blockIfUntrained,
                     const double minConfidence,
                     const double minProbGap,
                     const double minEdge)
  {
   g_markovCfg.mode = mode;
   if(g_markovCfg.mode < MARKOV_MODE_OFF || g_markovCfg.mode > MARKOV_MODE_DYNAMIC)
      g_markovCfg.mode = MARKOV_MODE_OFF;
   g_markovCfg.timeframe = timeframe;
   g_markovCfg.lookbackPeriod = MathMax(1, lookbackPeriod);
   g_markovCfg.atrLength = MathMax(1, atrLength);
   g_markovCfg.smoothLen = MathMax(1, smoothLen);
   g_markovCfg.triggerThresh = triggerThresh;
   g_markovCfg.exitThresh = exitThresh;
   g_markovCfg.volPercentileLb = MathMax(10, volPercentileLb);
   g_markovCfg.memoryDecay = MathMin(0.999, MathMax(0.90, memoryDecay));
   g_markovCfg.useSecondOrder = useSecondOrder;
   g_markovCfg.evEmaLength = MathMax(1, evEmaLength);
   g_markovCfg.minSampleSize = MathMax(1.0, minSampleSize);
   g_markovCfg.rangeLookback = MathMax(5, rangeLookback);
   g_markovCfg.macroLen = MathMax(2, macroLen);
   g_markovCfg.microLen = MathMax(2, microLen);
   g_markovCfg.slopeLen = MathMax(1, slopeLen);
   g_markovCfg.slopeFlatAtrMult = MathMax(0.0, slopeFlatAtrMult);
   g_markovCfg.minTrendBars = MathMax(0, minTrendBars);
   g_markovCfg.blockIfUntrained = blockIfUntrained;
   g_markovCfg.minConfidence = MathMin(1.0, MathMax(0.0, minConfidence));
   g_markovCfg.minProbGap = MathMax(0.0, minProbGap);
   g_markovCfg.minEdge = MathMax(0.0, minEdge);
  }

int MarkovFindContext(const string symbol)
  {
   for(int i = 0; i < ArraySize(g_markovCtx); i++)
     {
      if(g_markovCtx[i].symbol == symbol)
         return i;
     }
   return -1;
  }

void MarkovReleaseContext(MarkovContext &ctx)
  {
   if(ctx.atrHandle != INVALID_HANDLE)
      IndicatorRelease(ctx.atrHandle);
   if(ctx.macroHandle != INVALID_HANDLE)
      IndicatorRelease(ctx.macroHandle);
   if(ctx.microHandle != INVALID_HANDLE)
      IndicatorRelease(ctx.microHandle);
   ctx.atrHandle = INVALID_HANDLE;
   ctx.macroHandle = INVALID_HANDLE;
   ctx.microHandle = INVALID_HANDLE;
  }

int MarkovEnsureContext(const string symbol)
  {
   int idx = MarkovFindContext(symbol);
   if(idx >= 0)
     {
      // Self-heal indicator handles if they became invalid.
      if(g_markovCtx[idx].atrHandle == INVALID_HANDLE ||
         g_markovCtx[idx].macroHandle == INVALID_HANDLE ||
         g_markovCtx[idx].microHandle == INVALID_HANDLE)
        {
         MarkovReleaseContext(g_markovCtx[idx]);
         g_markovCtx[idx].atrHandle = iATR(symbol, g_markovCfg.timeframe, g_markovCfg.atrLength);
         g_markovCtx[idx].macroHandle = iMA(symbol, g_markovCfg.timeframe, g_markovCfg.macroLen, 0, MODE_EMA, PRICE_CLOSE);
         g_markovCtx[idx].microHandle = iMA(symbol, g_markovCfg.timeframe, g_markovCfg.microLen, 0, MODE_EMA, PRICE_CLOSE);
         MarkovResetContext(g_markovCtx[idx]);
        }
      return idx;
     }

   idx = ArraySize(g_markovCtx);
   ArrayResize(g_markovCtx, idx + 1);
   g_markovCtx[idx].symbol = symbol;
   g_markovCtx[idx].atrHandle = iATR(symbol, g_markovCfg.timeframe, g_markovCfg.atrLength);
   g_markovCtx[idx].macroHandle = iMA(symbol, g_markovCfg.timeframe, g_markovCfg.macroLen, 0, MODE_EMA, PRICE_CLOSE);
   g_markovCtx[idx].microHandle = iMA(symbol, g_markovCfg.timeframe, g_markovCfg.microLen, 0, MODE_EMA, PRICE_CLOSE);
   MarkovResetContext(g_markovCtx[idx]);
   return idx;
  }

void MarkovPrepareSymbols(string &symbols[])
  {
   if(g_markovCfg.mode == MARKOV_MODE_OFF)
     return;
   for(int i = 0; i < ArraySize(symbols); i++)
     {
      string s = symbols[i];
      if(StringLen(s) == 0)
         continue;
      MarkovEnsureContext(s);
     }
  }

void MarkovRelease()
  {
   for(int i = 0; i < ArraySize(g_markovCtx); i++)
      MarkovReleaseContext(g_markovCtx[i]);
   ArrayResize(g_markovCtx, 0);
  }

double MarkovPercentileLinear(double &vals[], const double percentile01)
  {
   int n = ArraySize(vals);
   if(n <= 0)
      return 0.0;
   double p = percentile01;
   if(p < 0.0)
      p = 0.0;
   if(p > 1.0)
      p = 1.0;
   double work[];
   ArrayResize(work, n);
   for(int i = 0; i < n; i++)
      work[i] = vals[i];
   ArraySort(work);
   if(n == 1)
      return work[0];
   double rank = (n - 1) * p;
   int lo = (int)MathFloor(rank);
   int hi = (int)MathCeil(rank);
   if(lo == hi)
      return work[lo];
   double frac = rank - lo;
   return work[lo] + frac * (work[hi] - work[lo]);
  }

void MarkovMeanStd(double &vals[], double &meanOut, double &stdOut)
  {
   int n = ArraySize(vals);
   meanOut = 0.0;
   stdOut = 0.0;
   if(n <= 0)
      return;
   for(int i = 0; i < n; i++)
      meanOut += vals[i];
   meanOut /= (double)n;
   if(n == 1)
      return;
   double ss = 0.0;
   for(int j = 0; j < n; j++)
     {
      double d = vals[j] - meanOut;
      ss += d * d;
     }
   stdOut = MathSqrt(ss / (double)(n - 1));
  }

double MarkovSafeProbEntropyTerm(const double p)
  {
   if(p <= 0.0)
      return 0.0;
  return p * MathLog(p);
  }

bool MarkovBuildRangeWidthSeries(const double &closeBuf[], const int lb, double &widthOut[])
  {
   int n = ArraySize(closeBuf);
   if(lb <= 0 || n < lb)
      return false;

   int windows = n - lb + 1;
   ArrayResize(widthOut, windows);

   int maxQ[], minQ[];
   ArrayResize(maxQ, n);
   ArrayResize(minQ, n);
   int maxHead = 0, maxTail = 0, minHead = 0, minTail = 0;

   for(int i = 0; i < n; i++)
     {
      while(maxTail > maxHead && closeBuf[maxQ[maxTail - 1]] <= closeBuf[i])
         maxTail--;
      maxQ[maxTail++] = i;
      while(maxTail > maxHead && maxQ[maxHead] <= i - lb)
         maxHead++;

      while(minTail > minHead && closeBuf[minQ[minTail - 1]] >= closeBuf[i])
         minTail--;
      minQ[minTail++] = i;
      while(minTail > minHead && minQ[minHead] <= i - lb)
         minHead++;

      if(i >= lb - 1)
        {
         int w = i - (lb - 1);
         double hh = closeBuf[maxQ[maxHead]];
         double ll = closeBuf[minQ[minHead]];
         widthOut[w] = hh - ll;
        }
     }

   return (ArraySize(widthOut) > 0);
  }

bool MarkovUpdateSymbol(const string symbol)
  {
   if(g_markovCfg.mode == MARKOV_MODE_OFF)
     return false;

   int idx = MarkovEnsureContext(symbol);
   if(idx < 0)
      return false;
   MarkovContext ctx = g_markovCtx[idx];

   if(ctx.atrHandle == INVALID_HANDLE || ctx.macroHandle == INVALID_HANDLE || ctx.microHandle == INVALID_HANDLE)
      return false;

   datetime tBar = iTime(symbol, g_markovCfg.timeframe, 1);
   if(tBar <= 0)
      return false;
   if(ctx.lastBarTime == tBar)
      return true;

   int barsCount = Bars(symbol, g_markovCfg.timeframe);
   int warmupBars = g_markovCfg.lookbackPeriod + 3;
   bool canTrain = (barsCount > warmupBars);

   int needClose = MathMax(g_markovCfg.lookbackPeriod + 3, g_markovCfg.rangeLookback * 2 + 4);
   double closeBuf[];
   if(CopyClose(symbol, g_markovCfg.timeframe, 1, needClose, closeBuf) < needClose)
      return false;

   double atrNeed[];
   int needAtr = g_markovCfg.volPercentileLb + 4;
   if(CopyBuffer(ctx.atrHandle, 0, 1, needAtr, atrNeed) < needAtr)
      return false;

   double atrNow = atrNeed[0];
   if(atrNow <= 0)
      return false;

   double lookbackClose = closeBuf[g_markovCfg.lookbackPeriod];
   double priceChange = closeBuf[0] - lookbackClose;
   double rawNormChange = priceChange / atrNow;
   double momAlpha = 2.0 / (g_markovCfg.smoothLen + 1.0);
   if(!ctx.hasSmoothed)
     {
      ctx.smoothedChange = rawNormChange;
      ctx.hasSmoothed = true;
     }
   else
      ctx.smoothedChange = ctx.smoothedChange + momAlpha * (rawNormChange - ctx.smoothedChange);

   double macroNow = 0.0, macroPast = 0.0, microNow = 0.0;
   if(!MarkovCopyBufferValue(ctx.macroHandle, 1, macroNow))
      return false;
   if(!MarkovCopyBufferValue(ctx.macroHandle, 1 + g_markovCfg.slopeLen, macroPast))
      return false;
   if(!MarkovCopyBufferValue(ctx.microHandle, 1, microNow))
      return false;

   bool macroUp = (microNow > macroNow);
   bool macroDown = (microNow < macroNow);
   double macroSlope = macroNow - macroPast;
   bool strongUpSlope = (macroSlope > 0.0);
   bool strongDownSlope = (macroSlope < 0.0);
   // ATR-normalized flat-slope detection so thresholds are symbol-agnostic.
   bool flatSlope = (MathAbs(macroSlope) < (atrNow * g_markovCfg.slopeFlatAtrMult));

   int lb = g_markovCfg.rangeLookback;
   double widthSeries[];
   if(!MarkovBuildRangeWidthSeries(closeBuf, lb, widthSeries))
      return false;
   if(ArraySize(widthSeries) > lb)
      ArrayResize(widthSeries, lb);
   double rangeWidth = widthSeries[0];
   double rangeMa = 0.0, rangeStd = 0.0;
   MarkovMeanStd(widthSeries, rangeMa, rangeStd);
   bool compression = (rangeWidth < (rangeMa - 0.5 * rangeStd));

   int newState = ctx.state;
   if(newState == MARKOV_NEUTRAL)
     {
      if(ctx.smoothedChange > g_markovCfg.triggerThresh && macroUp && strongUpSlope && !compression)
         newState = MARKOV_UPTREND;
      else if(ctx.smoothedChange < -g_markovCfg.triggerThresh && macroDown && strongDownSlope && !compression)
         newState = MARKOV_DOWNTREND;
     }
   else if(newState == MARKOV_UPTREND)
     {
      bool canExit = (ctx.trendBars > g_markovCfg.minTrendBars);
      if(canExit && ((macroDown && ctx.smoothedChange < -g_markovCfg.exitThresh) || flatSlope || compression))
         newState = MARKOV_NEUTRAL;
     }
   else if(newState == MARKOV_DOWNTREND)
     {
      bool canExit = (ctx.trendBars > g_markovCfg.minTrendBars);
      if(canExit && ((macroUp && ctx.smoothedChange > g_markovCfg.exitThresh) || flatSlope || compression))
         newState = MARKOV_NEUTRAL;
     }

   if(newState == ctx.state)
      ctx.trendBars++;
   else
      ctx.trendBars = 0;

   int prevState = ctx.prevState;
   int prev2State = ctx.prev2State;

   double volSample[];
   ArrayResize(volSample, g_markovCfg.volPercentileLb);
   for(int i = 0; i < g_markovCfg.volPercentileLb; i++)
      volSample[i] = atrNeed[i];
   double atrMedian = MarkovPercentileLinear(volSample, 0.5);
   bool highVolNow = (atrNow > atrMedian);
   ctx.volRatio = (atrMedian > 0.0) ? (atrNow / atrMedian) : 1.0;

   bool highVolPrev = false;
   if(g_markovCfg.volPercentileLb + 1 < ArraySize(atrNeed))
     {
      double volSamplePrev[];
      ArrayResize(volSamplePrev, g_markovCfg.volPercentileLb);
      for(int i = 0; i < g_markovCfg.volPercentileLb; i++)
         volSamplePrev[i] = atrNeed[i + 1];
      double atrMedianPrev = MarkovPercentileLinear(volSamplePrev, 0.5);
      highVolPrev = (atrNeed[1] > atrMedianPrev);
     }

   if(canTrain)
     {
      int regimeUpd = MarkovRegimeOffset(highVolPrev);
      int orderUpd = g_markovCfg.useSecondOrder ?
                     (MarkovStateToIndex(prev2State) * 3 + MarkovStateToIndex(prevState)) :
                     MarkovStateToIndex(prevState);
      int rowUpd = regimeUpd + orderUpd;
      int colUpd = MarkovStateToIndex(newState);

      for(int r = 0; r < MARKOV_ROWS; r++)
        {
         double total = 0.0;
         for(int c = 0; c < MARKOV_COLS; c++)
           {
            ctx.transMat[r][c] *= g_markovCfg.memoryDecay;
            total += ctx.transMat[r][c];
           }
         ctx.rowTotals[r] = total;
        }

      ctx.transMat[rowUpd][colUpd] += 1.0;
      ctx.rowTotals[rowUpd] += 1.0;

      double evAlpha = 2.0 / (g_markovCfg.evEmaLength + 1.0);
      double atrPrev = atrNeed[1];
      double fwdReturn = 0.0;
      if(atrPrev > 0.0)
         fwdReturn = (closeBuf[0] - closeBuf[1]) / atrPrev;
      ctx.evMatrix[rowUpd] = ctx.evMatrix[rowUpd] + evAlpha * (fwdReturn - ctx.evMatrix[rowUpd]);
     }

   int regimePred = MarkovRegimeOffset(highVolNow);
   int orderPred = g_markovCfg.useSecondOrder ?
                   (MarkovStateToIndex(prevState) * 3 + MarkovStateToIndex(newState)) :
                   MarkovStateToIndex(newState);
   int predRow = regimePred + orderPred;

   double c0 = ctx.transMat[predRow][0];
   double c1 = ctx.transMat[predRow][1];
   double c2 = ctx.transMat[predRow][2];
   double totalTrans = c0 + c1 + c2;

   ctx.effectiveSamples = ctx.rowTotals[predRow];
   ctx.valid = canTrain && (ctx.effectiveSamples >= g_markovCfg.minSampleSize) && (totalTrans > 0);
   if(ctx.valid)
     {
      ctx.pDown = c0 / totalTrans;
      ctx.pNeu = c1 / totalTrans;
      ctx.pUp = c2 / totalTrans;
      ctx.expectedValue = ctx.evMatrix[predRow];
     }
   else
     {
      ctx.pDown = 0.3333;
      ctx.pNeu = 0.3333;
      ctx.pUp = 0.3333;
      ctx.expectedValue = 0.0;
     }

   double entropy = -(MarkovSafeProbEntropyTerm(ctx.pUp) +
                      MarkovSafeProbEntropyTerm(ctx.pNeu) +
                      MarkovSafeProbEntropyTerm(ctx.pDown));
   ctx.entropyNorm = entropy / MathLog(3.0);
   if(ctx.entropyNorm < 0.0)
      ctx.entropyNorm = 0.0;
   if(ctx.entropyNorm > 1.0)
      ctx.entropyNorm = 1.0;
   ctx.confidence = 1.0 - ctx.entropyNorm;

   ctx.edge = ctx.expectedValue * ctx.confidence;

   ctx.prev2State = prevState;
   ctx.prevState = newState;
   ctx.state = newState;
   ctx.lastBarTime = tBar;
   ctx.initialized = true;
   g_markovCtx[idx] = ctx;
   return true;
  }

bool MarkovGetSnapshot(const string symbol,
                       int &stateOut,
                       double &confidenceOut,
                       double &edgeOut,
                       double &pUpOut,
                       double &pDownOut,
                       double &effectiveNOut,
                       double &volRatioOut,
                       bool &validOut)
  {
   int idx = MarkovFindContext(symbol);
   if(idx < 0)
      return false;
   stateOut = g_markovCtx[idx].state;
   confidenceOut = g_markovCtx[idx].confidence;
   edgeOut = g_markovCtx[idx].edge;
   pUpOut = g_markovCtx[idx].pUp;
   pDownOut = g_markovCtx[idx].pDown;
   effectiveNOut = g_markovCtx[idx].effectiveSamples;
   volRatioOut = g_markovCtx[idx].volRatio;
   validOut = g_markovCtx[idx].valid;
   return true;
  }

bool MarkovAllowMrEntry(const string symbol, const int side, string &reasonOut)
  {
   reasonOut = "";
   if(g_markovCfg.mode == MARKOV_MODE_OFF)
      return true;

   MarkovUpdateSymbol(symbol);

   int st = MARKOV_NEUTRAL;
   double conf = 0.0, edge = 0.0, pUp = 0.0, pDown = 0.0, effN = 0.0, volRatio = 1.0;
   bool valid = false;
   if(!MarkovGetSnapshot(symbol, st, conf, edge, pUp, pDown, effN, volRatio, valid))
     {
      reasonOut = "no_ctx";
      return !g_markovCfg.blockIfUntrained;
     }

   if(!valid)
     {
      reasonOut = "n_low";
      if(g_markovCfg.mode != MARKOV_MODE_DIRECTIONAL && g_markovCfg.mode != MARKOV_MODE_DYNAMIC)
         return false;
      return !g_markovCfg.blockIfUntrained;
     }

   double dynamicConfReq = g_markovCfg.minConfidence;
   if(volRatio > 1.2)
      dynamicConfReq = MathMin(1.0, dynamicConfReq * MathMin(1.5, volRatio));

   bool regimeTrending = (st != MARKOV_NEUTRAL && conf >= dynamicConfReq);
   bool regimeRanging = !regimeTrending;

   if(g_markovCfg.mode == MARKOV_MODE_TRENDING && !regimeTrending)
     {
      reasonOut = "regime_not_trending";
      return false;
     }
   if(g_markovCfg.mode == MARKOV_MODE_RANGING && !regimeRanging)
     {
      reasonOut = "regime_not_ranging";
      return false;
     }

   double probGapUp = pUp - pDown;
   double probGapDown = pDown - pUp;

   if(side == SIDE_BUY)
     {
      bool trendBiasDown = (st == MARKOV_DOWNTREND && conf >= dynamicConfReq &&
                            probGapDown >= g_markovCfg.minProbGap);
      bool edgeBiasDown = (edge <= -g_markovCfg.minEdge);
      if(trendBiasDown || edgeBiasDown)
        {
         reasonOut = "bear_bias";
         return false;
        }
     }
   else
     {
      bool trendBiasUp = (st == MARKOV_UPTREND && conf >= dynamicConfReq &&
                          probGapUp >= g_markovCfg.minProbGap);
      bool edgeBiasUp = (edge >= g_markovCfg.minEdge);
      if(trendBiasUp || edgeBiasUp)
        {
         reasonOut = "bull_bias";
         return false;
        }
     }

  return true;
  }

string MarkovStateName(const int state)
  {
   if(state == MARKOV_UPTREND)
      return "UPTREND";
   if(state == MARKOV_DOWNTREND)
      return "DOWNTREND";
   return "NEUTRAL";
  }

bool MarkovGetStateText(const string symbol, string &stateTextOut)
  {
   int st = MARKOV_NEUTRAL;
   double conf = 0.0, edge = 0.0, pUp = 0.0, pDown = 0.0, effN = 0.0, volRatio = 1.0;
   bool valid = false;
   if(!MarkovGetSnapshot(symbol, st, conf, edge, pUp, pDown, effN, volRatio, valid))
      return false;
   stateTextOut = MarkovStateName(st);
   return true;
  }

#endif // __SNIPER_MARKOV_MQH__
