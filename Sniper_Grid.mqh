//+------------------------------------------------------------------+
//|                                                  Sniper_Grid.mqh |
//|                   Grid Management & Order Execution Functions    |
//+------------------------------------------------------------------+
#property copyright "ZScoreMurreySniper"
#property strict

// NOTE: All globals, enums, structs, and CTrade are defined in ZScoreMurreySniper_v2.mq5
// before this file is #include'd. No extern/forward declarations needed.

//+------------------------------------------------------------------+
//|  HELPER TICKET/PIPS CALCS                                        |
//+------------------------------------------------------------------+
double ResolvePipsOrATR(double inputVal, string symbol)
  {
   if(inputVal == 0)
      return 0;
   double pips = inputVal;
   if(pips < 0)
      pips = MathAbs(pips) * GetRangePipsForSymbol(symbol); // Requires GetRangePipsForSymbol defined
   return pips;
  }

double RoundToTick(string symbol, double price)
  {
   double tick = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0)
      tick = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tick <= 0)
      return price;
   return MathRound(price / tick) * tick;
  }

//+------------------------------------------------------------------+
//|  GRID INCREMENT MATH                                             |
//+------------------------------------------------------------------+
double GetGridExponent()
  {
   if(GridIncrementExponent <= 0)
      return 1.0;
   return GridIncrementExponent;
  }

double GridStepDistance(double baseInc, int existingTrades)
  {
   if(baseInc <= 0)
      return 0;
   int expIdx = existingTrades - 1;
   if(expIdx < 0)
      expIdx = 0;
   double ge = GetGridExponent();
   return baseInc * MathPow(ge, expIdx);
  }

double GridCumulativeOffset(double baseInc, int existingTrades)
  {
   if(baseInc <= 0 || existingTrades <= 0)
      return 0;
   double ge = GetGridExponent();
   if(MathAbs(ge - 1.0) <= 1e-10)
      return baseInc * existingTrades;
   return baseInc * (MathPow(ge, existingTrades) - 1.0) / (ge - 1.0);
  }

//+------------------------------------------------------------------+
//|  STOP LOSS VALIDATION                                            |
//+------------------------------------------------------------------+
bool PrepareValidStopForModify(string symbol, int side, double candidateSL, double &validatedSL)
  {
   validatedSL = 0;
   if(candidateSL <= 0)
      return false;

   double pointLocal = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(pointLocal <= 0)
      return false;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   long stopsLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPts, (double)freezeLevelPts) * pointLocal;
   double bidLocal = SymbolInfoDouble(symbol, SYMBOL_BID);
   double askLocal = SymbolInfoDouble(symbol, SYMBOL_ASK);

   double sl = candidateSL;
   if(side == SIDE_BUY)
     {
      // For BUY positions, SL must stay sufficiently below BID.
      double maxAllowed = bidLocal - minDist;
      if(maxAllowed <= 0)
         return false;
      if(sl > maxAllowed)
         sl = maxAllowed;
      if(sl >= bidLocal - pointLocal * 0.5)
         return false;
     }
   else
     {
      // For SELL positions, SL must stay sufficiently above ASK.
      double minAllowed = askLocal + minDist;
      if(sl < minAllowed)
         sl = minAllowed;
      if(sl <= askLocal + pointLocal * 0.5)
         return false;
     }

   sl = RoundToTick(symbol, sl);
   validatedSL = NormalizeDouble(sl, digits);
   return validatedSL > 0;
  }

//+------------------------------------------------------------------+
//|  EXECUTION (NO SLEEP)                                            |
//+------------------------------------------------------------------+
// Removed Sleep() to prevent blocking the async multi-currency loop.
bool TryOpenPositionWithRetry(string symbol, ENUM_ORDER_TYPE orderType, double lots, double &price, double sl, double tp, string comment)
  {
   for(int attempt = 1; attempt <= TRADE_RETRY_ATTEMPTS; attempt++)
     {
      price = (orderType == ORDER_TYPE_BUY) ?
              SymbolInfoDouble(symbol, SYMBOL_ASK) :
              SymbolInfoDouble(symbol, SYMBOL_BID);
      if(trade.PositionOpen(symbol, orderType, lots, price, sl, tp, comment))
         return true;
      // Removed Sleep(TRADE_RETRY_DELAY_MS) here to unblock thread limits.
     }
   return false;
  }

bool TryClosePositionWithRetry(ulong ticket)
  {
   for(int attempt = 1; attempt <= TRADE_RETRY_ATTEMPTS; attempt++)
     {
      if(trade.PositionClose(ticket))
         return true;
      // Removed Sleep(TRADE_RETRY_DELAY_MS) here to prevent EA locking.
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  POSITION COUNTING & TRACKING                                    |
//+------------------------------------------------------------------+
bool HasOpenPositionsByMagic(long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
     }
   return false;
  }

bool GetWorstEntryByMagic(long magic, string symbol, int side, double &worstEntry)
  {
   bool found = false;
   worstEntry = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol)) // Requires SymbolsEqual
         continue;
      long pType = PositionGetInteger(POSITION_TYPE);
      if(side == SIDE_BUY && pType != POSITION_TYPE_BUY)
         continue;
      if(side == SIDE_SELL && pType != POSITION_TYPE_SELL)
         continue;
      double pOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found)
        {
         worstEntry = pOpen;
         found = true;
        }
      else
        {
         if(side == SIDE_BUY && pOpen < worstEntry)
            worstEntry = pOpen;
         if(side == SIDE_SELL && pOpen > worstEntry)
            worstEntry = pOpen;
        }
     }
   return found;
  }

int CountPositionsByMagicSide(long magic, string symbol, int side)
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long pType = PositionGetInteger(POSITION_TYPE);
      if(side == SIDE_BUY && pType == POSITION_TYPE_BUY)
         cnt++;
      if(side == SIDE_SELL && pType == POSITION_TYPE_SELL)
         cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//|  ORDER PLACEMENT LOGIC                                           |
//+------------------------------------------------------------------+
bool OpenOrderWithLots(int seqIdx, ENUM_ORDER_TYPE orderType, string symbol, double lots, string comment, ENUM_STRATEGY_TYPE stratType)
  {
   bool isNewSeqStart = (sequences[seqIdx].tradeCount == 0);
   lastOrderBlockedPreSend = false;
   lastOrderBlockedSeq = -1;
   lastOrderBlockedSymbol = "";
   lastOrderBlockedReason = "";

   if(BlockOppositeSideStarts && !dashboardManualOverrideOpenRisk && sequences[seqIdx].tradeCount == 0)
     {
      if(HasOppositeSequenceOpenOnSymbol(symbol, orderType, seqIdx)) // Requires HasOppositeSequenceOpenOnSymbol
        {
         if(EnableLogging) Print("[ORDER_BLOCKED] Opposite-side start blocked on ", symbol, " seq=", seqIdx);
         lastOrderBlockedPreSend = true;
         lastOrderBlockedSeq = seqIdx;
         lastOrderBlockedSymbol = symbol;
         lastOrderBlockedReason = "opposite_symbol_side_block";
         return false;
        }
     }

   if(blockingNewsNoTransactions && !dashboardManualOverrideOpenRisk)
     {
      if(EnableLogging) Print("[ORDER_BLOCKED] News no-transaction filter on ", symbol, " seq=", seqIdx);
      lastOrderBlockedPreSend = true;
      lastOrderBlockedSeq = seqIdx;
      lastOrderBlockedSymbol = symbol;
      lastOrderBlockedReason = "news_filter";
      return false;
     }

   if(blockingNews && NewsAction == newsActionPause && !dashboardManualOverrideOpenRisk)
     {
      if(EnableLogging) Print("[ORDER_BLOCKED] News PAUSE active on ", symbol, " seq=", seqIdx);
      lastOrderBlockedPreSend = true;
      lastOrderBlockedSeq = seqIdx;
      lastOrderBlockedSymbol = symbol;
      lastOrderBlockedReason = "news_pause";
      return false;
     }

   if(TimeCurrent() - sequences[seqIdx].lastOpenTime < 5)
     {
      lastOrderBlockedPreSend = true;
      lastOrderBlockedSeq = seqIdx;
      lastOrderBlockedSymbol = symbol;
      lastOrderBlockedReason = "spam_guard";
      return false;
     }

   lots = NormalizeLotForSymbol(lots, symbol); // Req: NormalizeLotForSymbol
   if(lots <= 0)
     {
      lastOrderBlockedPreSend = true;
      lastOrderBlockedReason = "invalid_lot";
      return false;
     }

   double emaValue = 0, refPrice = 0;
   if(!EmaFilterAllowsOrder(symbol, orderType, emaValue, refPrice)) // Req: EmaFilterAllowsOrder
     {
      lastOrderBlockedPreSend = true;
      lastOrderBlockedReason = "ema_filter";
      return false;
     }

   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   if(stratType == STRAT_MEAN_REVERSION && sequences[seqIdx].tradeCount > 0)
     {
      int side = (orderType == ORDER_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      double worstEntry = 0;
      if(GetWorstEntryByMagic(sequences[seqIdx].magicNumber, symbol, side, worstEntry))
        {
         double pointSz = SymbolInfoDouble(symbol, SYMBOL_POINT);
         if(pointSz <= 0) pointSz = 0.00001;
         bool worsening = (side == SIDE_BUY) ? (price < worstEntry - pointSz * 0.1) : (price > worstEntry + pointSz * 0.1);
         if(!worsening)
           {
            lastOrderBlockedPreSend = true;
            lastOrderBlockedReason = "non_worsening_grid_add";
            return false;
           }
        }
     }

   // Added formal Margin Verification bug fix here
   double margin_required;
   // We use OrderCalcMargin to preempt "10019 Not enough money" logs
   if(!OrderCalcMargin(orderType, symbol, lots, price, margin_required) || margin_required > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      if(EnableLogging) Print("[ORDER_BLOCKED] Not enough free margin on ", symbol);
      lastOrderBlockedPreSend = true;
      lastOrderBlockedReason = "insufficient_margin";
      return false;
     }

   double slPrice = 0;
   if(StopLoss != 0)
     {
      double slPips = StopLoss;
      if(slPips < 0) slPips = MathAbs(slPips) * GetRangePipsForSymbol(symbol);
      double slDist = slPips * SymbolPipValue(symbol); // Req: SymbolPipValue
      slPrice = (orderType == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
      slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
     }

   trade.SetExpertMagicNumber(sequences[seqIdx].magicNumber);
   trade.SetTypeFilling(ResolveFillingMode(symbol)); // Req: ResolveFillingMode
   string finalComment = comment + "-" + IntegerToString(sequences[seqIdx].tradeCount + 1);
   bool result = TryOpenPositionWithRetry(symbol, orderType, lots, price, slPrice, 0, finalComment);

   if(result)
     {
      sequences[seqIdx].strategyType = stratType;
      if(isNewSeqStart) BuildAndStoreSequenceLockProfile(seqIdx, symbol); // Req: BuildAndStoreSequenceLockProfile
      tradesOpened++;
      sequences[seqIdx].tradeCount++;
      sequences[seqIdx].totalLots += lots;
      sequences[seqIdx].priceLotSum += price * lots;
      sequences[seqIdx].lastOpenTime = TimeCurrent();
      if(sequences[seqIdx].tradeCount == 1)
         sequences[seqIdx].firstOpenTime = TimeCurrent();
      sequences[seqIdx].tradeSymbol = symbol;

      if(orderType == ORDER_TYPE_BUY)
        {
         if(sequences[seqIdx].lowestPrice == 0 || price < sequences[seqIdx].lowestPrice) sequences[seqIdx].lowestPrice = price;
         if(sequences[seqIdx].highestPrice == 0 || price > sequences[seqIdx].highestPrice) sequences[seqIdx].highestPrice = price;
        }
      else
        {
         if(sequences[seqIdx].highestPrice == 0 || price > sequences[seqIdx].highestPrice) sequences[seqIdx].highestPrice = price;
         if(sequences[seqIdx].lowestPrice == 0 || price < sequences[seqIdx].lowestPrice) sequences[seqIdx].lowestPrice = price;
        }
     }
   return result;
  }

bool OpenOrder(int seqIdx, ENUM_ORDER_TYPE orderType, string symbol, ENUM_STRATEGY_TYPE stratType)
  {
   int existingPos = sequences[seqIdx].tradeCount;
   double lots = LotSize;
   for(int i = 0; i < existingPos; i++)
      lots = lots * LotSizeExponent;
   if(lots > MaxLots && MaxLots > 0)
      lots = MaxLots;
   return OpenOrderWithLots(seqIdx, orderType, symbol, lots, pendingOrderComment, stratType);
  }

bool OpenBreakoutOrder(int boIdx, ENUM_ORDER_TYPE orderType, string symbol, double breakLevel, double mmInc)
  {
   if(boIdx < 0 || boIdx >= MAX_SYMBOLS) return false;
   if(mmInc <= 0) return false;
   if(blockingNewsNoTransactions) return false;
   if(blockingNews && NewsAction == newsActionPause) return false;
   if(TimeCurrent() - breakoutLastEntryTime[boIdx] < 5) return false;

   double pointLocal = SymbolPointValue(symbol);
   if(pointLocal <= 0) return false;
   double bidLocal = SymbolInfoDouble(symbol, SYMBOL_BID);
   double askLocal = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double spreadPts = (askLocal - bidLocal) / pointLocal;
   double maxSpreadPts = MaxSpreadPointsForSymbol(MaxSpreadPips, symbol); 
   if(MaxSpreadPips > 0 && spreadPts > maxSpreadPts) return false;

   double emaValue = 0, refPrice = 0;
   if(!EmaFilterAllowsOrder(symbol, orderType, emaValue, refPrice)) return false;

   int side = (orderType == ORDER_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
   if(IsLpBeyondMurreyBoundary(symbol, side)) return false; // Req: IsLpBeyondMurreyBoundary
   if(IsLpTradeIntoEmaBlocked(symbol, side)) return false;  // Req: IsLpTradeIntoEmaBlocked

   // Added formal Margin Verification bug fix here
   double margin_required;
   double lots = BreakoutLotSize;
   double entryRef = (orderType == ORDER_TYPE_BUY) ? askLocal : bidLocal;
   // We use OrderCalcMargin to preempt "10019 Not enough money" logs
   if(!OrderCalcMargin(orderType, symbol, lots, entryRef, margin_required) || margin_required > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      return false;
     }

   int stopIntervals = BreakoutStopIntervals < 1 ? 1 : BreakoutStopIntervals;
   double sl = (orderType == ORDER_TYPE_BUY) ? breakLevel - (stopIntervals * mmInc) : breakLevel + (stopIntervals * mmInc);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);

   double stopDistance = MathAbs(entryRef - sl);
   if(stopDistance <= 0) return false;

   if(BreakoutRiskPercent > 0) lots = CalcRiskLotsForSymbol(symbol, BreakoutRiskPercent, stopDistance);
   lots = NormalizeLotNoMinClamp(lots, symbol);
   if(lots <= 0) return false;

   double rr = BreakoutRiskReward > 0 ? BreakoutRiskReward : 1.0;
   double tp = (orderType == ORDER_TYPE_BUY) ? entryRef + (rr * stopDistance) : entryRef - (rr * stopDistance);
   tp = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(breakoutMagic[boIdx]);
   trade.SetTypeFilling(ResolveFillingMode(symbol));
   string comment = "ZSM-BO-" + IntegerToString(orderType == ORDER_TYPE_BUY ? 0 : 1);
   bool ok = TryOpenPositionWithRetry(symbol, orderType, lots, entryRef, sl, tp, comment);
   if(ok) breakoutLastEntryTime[boIdx] = TimeCurrent();
   return ok;
  }

//+------------------------------------------------------------------+
//|  CLOSE SEQUENCES                                                 |
//+------------------------------------------------------------------+
void CloseSequence(int seqIdx, string reason)
  {
   long magic = sequences[seqIdx].magicNumber;
   bool closeFailed = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic)
        {
         ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         if(!TryClosePositionWithRetry(ticket)) closeFailed = true;
        }
     }
  }

bool CloseBreakoutPositions(string reason)
  {
   bool closedAny = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsBreakoutPositionComment(PositionGetString(POSITION_COMMENT))) continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(TryClosePositionWithRetry(ticket)) closedAny = true;
     }
   return closedAny;
  }

void CloseAll(string reason)
  {
   for(int i = 0; i < numActivePairs; i++)
     {
      CloseSequence(activePairs[i].buySeqIdx, reason);
      CloseSequence(activePairs[i].sellSeqIdx, reason);
     }
   CloseBreakoutPositions(reason);
   // Fallback sweep: close any remaining managed/hedge positions not mapped in activePairs.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      bool shouldClose = IsManagedPositionComment(comment) || StringFind(comment, "ZSHEDGE") == 0;
      if(!shouldClose) continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      TryClosePositionWithRetry(ticket);
     }
  }

//+------------------------------------------------------------------+
//|  ACCOUNT METRICS                                                 |
//+------------------------------------------------------------------+
int TotalManagedPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(IsManagedPositionComment(comment) || StringFind(comment, "ZSHEDGE") == 0) cnt++;
     }
   return cnt;
  }

int TotalPositions() { return TotalManagedPositions(); }

double TotalPlOpenLive()
  {
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) // Already bug-fixed backwards iteration
     {
      if(PositionGetTicket(i) == 0) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(comment) && StringFind(comment, "ZSHEDGE") != 0) continue;
      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + GetOpenPositionCommission(positionId);
     }
   return total;
  }

double TotalPlOpen() { return TotalPlOpenLive(); }

double GetTotalPipsProfit()
  {
   double totalPips = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(comment) && StringFind(comment, "ZSHEDGE") != 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double pVal = SymbolPipValue(sym);
      if(pVal <= 0) continue;
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      long posType = PositionGetInteger(POSITION_TYPE);
      double curPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double pips = (posType == POSITION_TYPE_BUY) ? (curPrice - openPx) / pVal : (openPx - curPrice) / pVal;
      totalPips += pips;
     }
   return totalPips;
  }
