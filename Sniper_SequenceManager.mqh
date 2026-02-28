//+------------------------------------------------------------------+
//|                                     Sniper_SequenceManager.mqh   |
//|  Sequence state encapsulation for ZScoreMurreySniper             |
//+------------------------------------------------------------------+
#ifndef __SNIPER_SEQUENCE_MANAGER_MQH__
#define __SNIPER_SEQUENCE_MANAGER_MQH__

struct SequenceState
  {
   int               pairIdx;
   int               side;           // 0=Buy, 1=Sell
   bool              active;
   int               tradeCount;
   double            lowestPrice;
   double            highestPrice;
   double            avgPrice;
   double            totalLots;
   double            priceLotSum;
   bool              lockProfitExec;
   double            plOpen;
   double            plHigh;
   double            plPrev;
   int               prevTradeCount;
   long              magicNumber;
   int               seqId;
   double            entryMmIncrement;
   datetime          firstOpenTime;
   datetime          lastOpenTime;
   string            tradeSymbol;
   ENUM_STRATEGY_TYPE strategyType;
   double            trailSL;
   double            lpTriggerDist;
   double            lpTrailDist;
   ulong             tickets[100];   // Performance: cached tickets for fast trailing
   int               ticketCount;
  };

class CSequenceManager
  {
public:
   SequenceState     m_sequences[MAX_PAIRS * 2];

   void              InitDefaults()
     {
      for(int i = 0; i < MAX_PAIRS * 2; i++)
        {
         m_sequences[i].pairIdx = -1;
         m_sequences[i].side = i % 2;
         m_sequences[i].active = false;
         m_sequences[i].tradeCount = 0;
         m_sequences[i].lowestPrice = 0;
         m_sequences[i].highestPrice = 0;
         m_sequences[i].avgPrice = 0;
         m_sequences[i].totalLots = 0;
         m_sequences[i].priceLotSum = 0;
         m_sequences[i].lockProfitExec = false;
         m_sequences[i].plOpen = 0;
         m_sequences[i].plHigh = 0;
         m_sequences[i].plPrev = 0;
         m_sequences[i].prevTradeCount = 0;
         m_sequences[i].magicNumber = 0;
         m_sequences[i].seqId = i;
         m_sequences[i].entryMmIncrement = 0;
         m_sequences[i].firstOpenTime = 0;
         m_sequences[i].lastOpenTime = 0;
         m_sequences[i].tradeSymbol = "";
         m_sequences[i].strategyType = STRAT_MEAN_REVERSION;
         m_sequences[i].trailSL = 0;
         m_sequences[i].lpTriggerDist = 0;
         m_sequences[i].lpTrailDist = 0;
         m_sequences[i].ticketCount = 0;
         ArrayInitialize(m_sequences[i].tickets, 0);
        }
     }

   SequenceState     Get(int idx) const
     {
      return m_sequences[idx];
     }

   void              ResetRuntimeMetrics(int seqIdx)
     {
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         return;
      m_sequences[seqIdx].tradeCount = 0;
      m_sequences[seqIdx].plOpen = 0;
      m_sequences[seqIdx].totalLots = 0;
      m_sequences[seqIdx].priceLotSum = 0;
      m_sequences[seqIdx].lowestPrice = 0;
      m_sequences[seqIdx].highestPrice = 0;
      m_sequences[seqIdx].avgPrice = 0;
      m_sequences[seqIdx].ticketCount = 0;
     }

   void              AccumulatePosition(int seqIdx, double lots, double openPrice, double pl, int side, ulong ticket)
     {
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         return;

      m_sequences[seqIdx].tradeCount++;
      if(m_sequences[seqIdx].tradeCount == 1)
         m_sequences[seqIdx].side = side;

      m_sequences[seqIdx].totalLots += lots;
      m_sequences[seqIdx].priceLotSum += openPrice * lots;
      m_sequences[seqIdx].plOpen += pl;

      if(m_sequences[seqIdx].lowestPrice == 0 || openPrice < m_sequences[seqIdx].lowestPrice)
         m_sequences[seqIdx].lowestPrice = openPrice;
      if(m_sequences[seqIdx].highestPrice == 0 || openPrice > m_sequences[seqIdx].highestPrice)
         m_sequences[seqIdx].highestPrice = openPrice;
       
       if(m_sequences[seqIdx].ticketCount < 100)
       {
          m_sequences[seqIdx].tickets[m_sequences[seqIdx].ticketCount] = ticket;
          m_sequences[seqIdx].ticketCount++;
       }
     }

   void              FinalizeSequence(int seqIdx)
     {
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         return;

      if(m_sequences[seqIdx].totalLots > 0)
         m_sequences[seqIdx].avgPrice = m_sequences[seqIdx].priceLotSum / m_sequences[seqIdx].totalLots;
      else
         m_sequences[seqIdx].avgPrice = 0;

      if(m_sequences[seqIdx].plOpen > m_sequences[seqIdx].plHigh)
         m_sequences[seqIdx].plHigh = m_sequences[seqIdx].plOpen;
     }

   bool              NeedsReconstruct(int seqIdx, int pairIdx, ActivePair &pair)
     {
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         return false;
      if(pairIdx < 0 || pairIdx >= MAX_PAIRS)
         return false;
      if(m_sequences[seqIdx].tradeCount <= 0)
         return false;
      if(m_sequences[seqIdx].entryMmIncrement <= EPS)
         return true;
      if(m_sequences[seqIdx].side == SIDE_BUY)
         return (pair.entry_mm_08 == 0 || pair.entry_mm_minus28 == 0);
      return (pair.entry_mm_88 == 0 || pair.entry_mm_plus28 == 0);
     }

   void              OnSequenceClosed(int seqIdx)
     {
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         return;
      m_sequences[seqIdx].lockProfitExec = false;
      m_sequences[seqIdx].plHigh = 0;
      m_sequences[seqIdx].trailSL = 0;
      m_sequences[seqIdx].entryMmIncrement = 0;
      m_sequences[seqIdx].firstOpenTime = 0;
      m_sequences[seqIdx].lastOpenTime = 0;
      m_sequences[seqIdx].tradeSymbol = "";
      m_sequences[seqIdx].lpTriggerDist = 0;
      m_sequences[seqIdx].lpTrailDist = 0;
      m_sequences[seqIdx].ticketCount = 0;
      ArrayInitialize(m_sequences[seqIdx].tickets, 0);
     }
  };

extern CSequenceManager g_seqMgr;

#endif // __SNIPER_SEQUENCE_MANAGER_MQH__
