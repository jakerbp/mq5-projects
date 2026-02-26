//+------------------------------------------------------------------+
//|                                             Sniper_Strategy.mqh  |
//|  Thin strategy adapters for incremental refactor                |
//+------------------------------------------------------------------+
#ifndef __SNIPER_STRATEGY_MQH__
#define __SNIPER_STRATEGY_MQH__

enum ENUM_ORDER_DIRECTION
  {
   DIR_BUY = 0,
   DIR_SELL = 1
  };

// Implemented in the main EA module (thin wrappers in this phase).
bool EvaluateTrendStart(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut);
bool EvaluateMrStart(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut);
bool ManageMrGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut);
bool ManageTrendGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut);

class IStrategy
  {
public:
   virtual bool      CheckEntry(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut) = 0;
   virtual bool      ManageGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut) = 0;
  };

class CMeanReversionStrategy : public IStrategy
  {
public:
   virtual bool      CheckEntry(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
     {
      return EvaluateMrStart(pairIdx, dir, reasonOut);
     }
   virtual bool      ManageGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
     {
      return ManageMrGrid(pairIdx, dir, reasonOut);
     }
  };

class CTrendStrategy : public IStrategy
  {
public:
   virtual bool      CheckEntry(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
     {
      return EvaluateTrendStart(pairIdx, dir, reasonOut);
     }
   virtual bool      ManageGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
     {
      return ManageTrendGrid(pairIdx, dir, reasonOut);
     }
  };

#endif // __SNIPER_STRATEGY_MQH__
