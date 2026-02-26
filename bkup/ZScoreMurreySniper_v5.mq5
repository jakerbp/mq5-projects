//+------------------------------------------------------------------+
//|                                          ZScoreMurreySniper.mq5  |
//|  Z-Score of Price Ratio + Murrey Math Levels Sniper EA           |
//|  Multi-currency with dynamic Pearson correlation scanner         |
//+------------------------------------------------------------------+
#property copyright "ZScoreMurreySniper"
#property link      ""
#property version   "1.00"
#property strict
#property description "Z-Score + Murrey Math multi-currency sniper grid EA"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
CTrade     trade;
CSymbolInfo cSymbol;

//+------------------------------------------------------------------+
//|  ENUMS                                                           |
//+------------------------------------------------------------------+
enum ENUM_SESSION_DIR
  {
   DIR_BOTH   = 0, // Both
   DIR_LONG   = 1, // Buy Only
   DIR_SHORT  = 2, // Sell Only
  };
enum ENUM_SESSION_END
  {
   CLOSE_ALL              = 0, // Close All Trades
   NO_TRADES_FOR_NEW_CYCLE = 1, // Wait For Sequence To Close
   SESSION_END_PAUSE      = 2  // Pause
  };
enum enumTf
  {
   tfM1=PERIOD_M1, tfM5=PERIOD_M5, tfM15=PERIOD_M15, tfM30=PERIOD_M30,
   tfH1=PERIOD_H1, tfH4=PERIOD_H4, tfD1=PERIOD_D1, tfW1=PERIOD_W1
  };
enum enumTrailFrequency
  {
   trailAtCloseOfBarChart=0, trailAtCloseOfBarM1=1, trailEveryTick=2
  };
enum enumRestart { restartOff=2, restartNextDay=0, restartInHours=1 };
enum enumNewsAction { newsActionClose=0, newsActionManage=1, newsActionPause=2 };
enum enumGlobalEpType { globalEpAbsolute=0, globalEpAmount=1, globalEpPercent=2 };
enum enumLockProfitMode { lpPerSequence=0, lpGlobal=1, lpGlobalPips=2 }; // Per-Sequence, Global Net $, or Global Net Pips
enum enumEntryPriceType { entryOnClose=0, entryOnTick=1 };
enum ENUM_STRATEGY_TYPE { STRAT_MEAN_REVERSION=0, STRAT_TRENDING=1 };
enum enumTrendEntryType { trendEntryBreakRetest=0, trendEntryBreak=1 };
// Legacy enum retained for disabled breakout code paths.
enum enumBreakoutMrDrawdownMode { boMrDdOff=0, boMrDdSameSymbol=1, boMrDdSameCurrency=2 };
enum enumVisualTheme { themeDark=0, themeLight=1 };
enum enumRangeMetric { rangeAtr=0, rangeKeltnerWidth=1 };
enum enumMarkovMode
  {
   markovModeOff=0,        // Markov disabled
   markovModeDirectional=1, // Directional bias only
   markovModeTrending=2,   // Trade only in trending regime
   markovModeRanging=3     // Trade only in ranging regime
  };

//+------------------------------------------------------------------+
//|  CONSTANTS                                                       |
//+------------------------------------------------------------------+
#define SIDE_BUY  0
#define SIDE_SELL 1
#define MAX_PAIRS 10
#define MAX_SYMBOLS 30
#define EPS 1e-10
#define TRADE_RETRY_ATTEMPTS 3
#define TRADE_RETRY_DELAY_MS 250

//+------------------------------------------------------------------+
//|  STRUCTS                                                         |
//+------------------------------------------------------------------+
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
   double            entryMmIncrement; // Frozen mmIncrement at sequence start (static grid)
   datetime          firstOpenTime; // First time an order was opened for this sequence (for Time Decay)
   datetime          lastOpenTime;  // Last time an order was opened for this sequence (spam protection)
   string            tradeSymbol;   // live symbol this sequence is trading (A/B symbol)
   ENUM_STRATEGY_TYPE strategyType; // strategy tag
   double            trailSL;       // legacy trailing state
   double            lpTriggerDist; // Frozen lock-profit trigger distance (price units)
   double            lpTrailDist;   // Frozen trailing distance (price units)
  };

struct ActivePair
  {
   string            symbolA;
   string            symbolB;
   double            correlation;
   double            score;            // scanner ranking score (mode-dependent)
   bool              active;
   bool              tradingEnabled;  // false if pair dropped out but has open trades
   bool              recoveryManagedOnly; // true only for managed-only recovery slots
   double            zScore;
   // Murrey levels (live, recalculated every bar)
   double            mm_88, mm_48, mm_08, mmIncrement, mmIncrementB;
   double            mm_plus28, mm_plus18, mm_minus18, mm_minus28;
   double            currentZ;
   // Entry-time Murrey snapshots (frozen at first sequence entry)
   double            entry_mm_08;        // 0/8 at time buy sequence started
   double            entry_mm_minus18;   // -1/8 at time buy sequence started
   double            entry_mm_minus28;   // -2/8 at time buy sequence started
   double            entry_mm_88;        // 8/8 at time sell sequence started
   double            entry_mm_plus18;    // +1/8 at time sell sequence started
   double            entry_mm_plus28;    // +2/8 at time sell sequence started
   int               buySeqIdx;
   int               sellSeqIdx;
   datetime          lastBuySeqCloseTime;
   datetime          lastSellSeqCloseTime;
  };

struct CorrPair
  {
   int               idxA;
   int               idxB;
   double            absR;
   double            r;
   double            score;
  };


// Include modular headers AFTER all enums/structs/constants are defined
#include "Sniper_Math.mqh"
#include "Sniper_Grid.mqh"
#include "Sniper_UI.mqh"
#include "Sniper_Markov.mqh"
input group "~~~~~~~~~General Settings~~~~~~~~~";
input long    MAGIC_NUMBER = 20250215;             // Magic Number
input bool    EnableLogging = true;                 // Enable Logging
input double  MaxSpreadPips = 3.0;                  // Max Spread (pips, 0=off)

//+------------------------------------------------------------------+
//|  INPUTS - MEAN REVERSION STRATEGY                                |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Mean Reversion Strategy~~~~~~~~~";
input bool    EnableMeanReversion = true;           // Enable Mean Reversion
input bool    AllowNewMeanReversionSequences = true; // Allow New MR Sequences
input enumMarkovMode MeanReversionMarkovMode = markovModeOff; // MR Markov Mode (Off/Directional/Trending/Ranging)
input enumTf  MrMM_Timeframe = tfH1;                // MR Murrey Timeframe
input enumRangeMetric MrRangeMetric = rangeAtr;     // MR Dynamic Range Source
input double  MrMinIncrementBlock_Pips = 0;         // MR Min Increment to Block (0=off, neg=ATR/Keltner mult)
input double  MrMinIncrementExpand_Pips = 0;        // MR Min Increment to Expand (0=off, neg=ATR/Keltner mult)
input bool    AllowNewSequence = true;              // Global gate for opening brand-new sequences
input string  MrSessionStartTime = "00:00";         // MR Session Start
input string  MrSessionEndTime = "23:59";           // MR Session End
input ENUM_SESSION_END MrSessionEndAction = NO_TRADES_FOR_NEW_CYCLE; // MR End Action
input double  MrLotSize = 0.01;                     // MR Base Lot Size
input double  MrLotMultiplier = 1.0;                // MR Lot Multiplier
input double  MrMaxLots = 1.0;                      // MR Max Lots Per Order
input double  MrRiskPercent = 0;                    // MR Risk % (0=use MrLotSize)

input group "~~~~~~~~~Trending Strategy~~~~~~~~~";
input bool    EnableTrendingStrategy = false;       // Enable Trending Strategy
input bool    AllowNewTrendingSequences = true;     // Allow New Trending Sequences
input enumMarkovMode TrendingMarkovMode = markovModeOff; // Trend Markov Mode (Off/Directional/Trending/Ranging)
input enumTrendEntryType TrendEntryType = trendEntryBreakRetest; // Trending Entry Type
input int     TrendEntryMmLevel = 2;                // Trending Entry MM Level for Sell (-2..10, Buy mirrors)
input enumTf  TrendMM_Timeframe = tfH1;             // Trend Murrey Timeframe
input enumRangeMetric TrendRangeMetric = rangeAtr;  // Trend Dynamic Range Source
input double  TrendMinIncrementBlock_Pips = 0;      // Trend Min Increment to Block (0=off, neg=ATR/Keltner mult)
input double  TrendMinIncrementExpand_Pips = 0;     // Trend Min Increment to Expand (0=off, neg=ATR/Keltner mult)
input string  TrendSessionStartTime = "00:00";      // Trend Session Start
input string  TrendSessionEndTime = "23:59";        // Trend Session End
input ENUM_SESSION_END TrendSessionEndAction = NO_TRADES_FOR_NEW_CYCLE; // Trend End Action
input double  TrendLotSizeBase = 0.01;              // Trend Base Lot Size
input double  TrendLotMultiplier = 1.0;             // Trend Lot Multiplier
input double  TrendMaxLots = 1.0;                   // Trend Max Lots Per Order
input double  TrendRiskPercent = 0;                 // Trend Risk % (0=use TrendLotSizeBase)

//+------------------------------------------------------------------+
//|  INPUTS - CURRENCY STRENGTH MATRIX                               |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Currency Strength Matrix~~~~~~~~~";
input bool    UseCurrencyStrengthMatrix = false;    // Use Currency Strength Matrix
input enumTf  StrengthTimeframe = tfD1;             // Strength Timeframe
input int     StrengthLookbackBars = 5;             // Strength Lookback (bars on StrengthTimeframe)
input int     StrengthExtremeCount = 1;             // Strongest/Weakest Buckets (1-2)

//+------------------------------------------------------------------+
//|  INPUTS - SCANNER                                                |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Scanner Settings~~~~~~~~~";
input string  Trade_Symbols = "EURUSD,GBPUSD,AUDUSD,NZDUSD,USDJPY,USDCAD,USDCHF,EURJPY,GBPJPY,EURGBP"; // Symbols
input int     Corr_Lookback = 100;                  // Correlation Lookback (bars)
input enumTf  Corr_Timeframe = tfH1;                // Correlation Timeframe
input int     Max_Pairs = 3;                        // Max Active Pairs
input int     Scanner_IntervalHours = 4;            // Rescan Interval (hours)
input double  Min_Correlation = 0.80;               // Min |r| Threshold

//+------------------------------------------------------------------+
//|  INPUTS - Z-SCORE                                                |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Z-Score Settings~~~~~~~~~";
input int     Z_Lookback = 20;                      // Z-Score Lookback
input double  Z_BuyThreshold = -2.0;                // Z Buy Threshold (negative)
input double  Z_SellThreshold = 2.0;                // Z Sell Threshold (positive)
input bool    UseZScoreEntryFilter = true;          // Require Z thresholds for MR entries

//+------------------------------------------------------------------+
//|  INPUTS - MARKOV FILTER                                          |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Markov Regime Filter~~~~~~~~~";
input enumTf  Markov_RegimeTimeframe = tfH1;        // Regime Detection Timeframe
input int     Markov_Lookback = 50;                 // Momentum Lookback
input int     Markov_ATRLength = 50;                // ATR Length
input int     Markov_SmoothLen = 5;                 // Momentum EMA Smoothing
input double  Markov_TriggerATR = 0.8;              // Trend Entry Threshold (ATR)
input double  Markov_ExitATR = 0.6;                 // Trend Exit Threshold (ATR)
input int     Markov_VolPercentileLookback = 100;   // Volatility Percentile Lookback
input double  Markov_MemoryDecay = 0.97;            // Transition Memory Decay
input bool    Markov_UseSecondOrder = true;         // Use 2nd Order Markov
input int     Markov_EvEmaLength = 20;              // Expected Value EMA Length
input double  Markov_MinSampleSize = 5.0;           // Minimum Effective Sample
input int     Markov_RangeLookback = 50;            // Structural Range Lookback
input int     Markov_MacroLen = 100;                // Macro EMA
input int     Markov_MicroLen = 20;                 // Micro EMA
input int     Markov_SlopeLen = 20;                 // Macro Slope Length
input double  Markov_SlopeFlatAtrMult = 0.10;       // Flat Slope Threshold (ATR multiple)
input int     Markov_MinTrendBars = 10;             // Minimum Trend Duration
input bool    Markov_BlockIfUntrained = false;      // Block Entries Before Model Trained
input double  Markov_MinConfidence = 0.65;          // Min Confidence for Directional Block
input double  Markov_MinProbGap = 0.10;             // Min (P(up)-P(down)) Gap for Directional Block
input double  Markov_MinEdge = 0.02;                // Min |Edge| for Directional Block

//+------------------------------------------------------------------+
//|  LEGACY DISABLED FEATURES (kept for compile compatibility)       |
//+------------------------------------------------------------------+
bool    EnableBreakoutStrategy = false;
enumBreakoutMrDrawdownMode BreakoutMrDrawdownMode = boMrDdOff;
string  Breakout_Symbols = "";
int     Breakout_MM_Lookback = 96;
enumTf  Breakout_MM_Timeframe = tfH1;
int     BreakoutLevelEighth = 2;
double  BreakoutBufferPips = 1.0;
int     BreakoutStopIntervals = 2;
double  BreakoutRiskReward = 1.5;
double  BreakoutLotSize = 0.01;
double  BreakoutRiskPercent = 0;
bool    BreakoutCloseOppositeMRonProfit = false;
double  StagnationDecayHours = 0;
double  StagnationHedgeHours = 0;
double  StagnationHedgeDrawdownAmount = 0;
double  StagnationUnwindNetThreshold = 0.0;

//+------------------------------------------------------------------+
//|  INPUTS - EMA FILTER                                             |
//+------------------------------------------------------------------+
input group "~~~~~~~~~EMA Filter~~~~~~~~~";
input int     EMA_FilterPeriod = 0;                 // EMA Filter Period (0=off)
input enumTf  EMA_FilterTimeframe = tfH1;           // EMA Filter Timeframe

//+------------------------------------------------------------------+
//|  INPUTS - MURREY MATH                                            |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Murrey Math Settings~~~~~~~~~";
input int     MM_Lookback = 96;                     // Murrey Math Lookback
input enumTf  MM_Timeframe = tfH1;                  // Murrey Math Timeframe
input enumEntryPriceType EntryPriceType = entryOnClose; // Entry Source (Close/Tick)
input int     EntryMmLevel = 8;                     // Entry MM Level for Sell (-2..10, Buy mirrors as 8-level)

//+------------------------------------------------------------------+
//|  INPUTS - ATR                                                    |
//+------------------------------------------------------------------+
input group "~~~~~~~~~ATR / Range~~~~~~~~~";
input enumTf  ATRtimeframe = tfH1;                  // ATR Timeframe
input int     AtrPeriod = 14;                       // ATR Period
input enumRangeMetric RangeMetric = rangeAtr;       // Dynamic Range Source for negative multipliers
input enumTf  KeltnerTimeframe = tfH1;              // Keltner ATR Timeframe
input int     KeltnerEmaPeriod = 20;                // Keltner EMA Period (centerline)
input int     KeltnerAtrPeriod = 20;                // Keltner ATR Period
input double  KeltnerAtrMultiplier = 1.5;           // Keltner ATR Multiplier (band half-width)

//+------------------------------------------------------------------+
//|  INPUTS - SESSION                                                |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Trading Session~~~~~~~~~";
input string  SessionStartTime = "00:00";           // Session Start
input string  SessionEndTime = "23:59";             // Session End
input ENUM_SESSION_END SessionEndAction = NO_TRADES_FOR_NEW_CYCLE; // End Action
input ENUM_SESSION_DIR Direction = DIR_BOTH;         // Direction

//+------------------------------------------------------------------+
//|  INPUTS - LOT SIZING                                             |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Lot Sizing~~~~~~~~~";
input double  LotSize = 0.01;                       // [Legacy] Base Lot Size
input double  LotSizeExponent = 1.0;                // [Legacy] Lot Multiplier
input double  MaxLots = 1.0;                        // [Legacy] Max Lots Per Order
input double  RiskPercent = 0;                      // [Legacy] Risk % (0=use LotSize)
input bool    UsePipValueLotNormalization = true;   // Normalize lot size by pip-value ratio across symbols
input string  PipValueReferenceSymbol = "EURUSD";   // Reference symbol for pip-value normalization
input bool    NormalizeLotsPerStrategy = true;      // Apply pip normalization to MR/Trend lots
// Migration notes (old -> new strategy-specific):
// LotSize/LotSizeExponent/MaxLots/RiskPercent -> MrLotSize/MrLotMultiplier/MrMaxLots/MrRiskPercent and Trend* equivalents
// SessionStartTime/SessionEndTime/SessionEndAction -> MrSession* and TrendSession*
// MM_Timeframe/RangeMetric/MinIncrement* -> Mr* and Trend* strategy configs

//+------------------------------------------------------------------+
//|  INPUTS - GRID & TARGETS                                         |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Grid & Targets~~~~~~~~~";
input int     MaxOrders = 20;                       // Max Grid Orders
input bool    BlockOppositeSideStarts = true;       // Block opposite-side sequence starts on same symbol
input int     GridAddThrottleSeconds = 10;          // Min seconds between grid adds per sequence
input double  StopLoss = 0;                         // Stop Loss (pips, neg=ATR/Keltner mult, 0=off)
input double  LockProfitTriggerPips = 0;            // MR Lock Profit Trigger (pips, neg=ATR/Keltner mult)
input double  TrailingStop = 5.0;                   // MR Trailing Stop (pips, neg=ATR/Keltner mult)
input int     LockProfitMinTrades = 0;              // MR Min Trades for Lock Profit
input enumTrailFrequency LockProfitCheckFrequency = trailEveryTick; // MR Lock Trigger Check Frequency
input enumTrailFrequency TrailFrequency = trailEveryTick; // MR Trailing SL Update Frequency
input group "~~~~~~~~~Trending Lock/Trail~~~~~~~~~";
input double  TrendLockProfitTriggerPips = 0;       // Trend Lock Profit Trigger (pips, neg=ATR/Keltner mult)
input double  TrendTrailingStop = 5.0;              // Trend Trailing Stop (pips, neg=ATR/Keltner mult)
input int     TrendLockProfitMinTrades = 0;         // Trend Min Trades for Lock Profit
input enumTrailFrequency TrendLockProfitCheckFrequency = trailEveryTick; // Trend Lock Trigger Check Frequency
input enumTrailFrequency TrendTrailFrequency = trailEveryTick; // Trend Trailing SL Update Frequency
input enumLockProfitMode LockProfitMode = lpPerSequence; // Lock Profit Scope
input double  GlobalLockProfitAmount = 0;            // Global Lock: $ Threshold (0=off)
input double  GlobalTrailingAmount = 0;              // Global Lock: $ Trail From Peak
input double  GlobalLockProfitPips = 0;              // Global Lock: Pips Threshold (0=off)
input double  GlobalTrailingPips = 0;                // Global Lock: Pips Trail From Peak

input group "~~~~~~~~~Grid Increment Control~~~~~~~~~";
input double  MinIncrementBlock_Pips = 0;            // [Legacy] Min Increment to Block (0=off, neg=ATR/Keltner mult)
input double  MinIncrementExpand_Pips = 0;           // [Legacy] Min Increment to Expand (0=off, neg=ATR/Keltner mult)
input double  GridIncrementExponent = 1.0;           // Grid Increment Exponent (1.0=linear)

input group "~~~~~~~~~LP-vs-Murrey Filter~~~~~~~~~";
input enumTf  LP_MM_Timeframe = tfH4;                 // LP Filter: Murrey Timeframe
input int     LP_MM_Lookback = 0;                    // LP Filter: Murrey Lookback (0=off)
input int     LP_MM_BoundaryEighth = 0;               // LP Filter: Boundary N/8 from 8/8 (neg=inward)
input bool    UseLpEmaTradeIntoFilter = false;        // LP Filter: Block trades that cross 20/50/200 EMA on M1/M5/M15/H1/H4/D1

// Stagnation rescue removed.

//+------------------------------------------------------------------+
//|  INPUTS - WEEKEND                                                |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Weekend Closure~~~~~~~~~";
input bool    CloseAllTradesDisableEA = false;       // Close All Friday
input int     DayToClose = 5;                        // Day To Close (5=Fri)
input string  TimeToClose = "20:00";                 // Time To Close
input bool    RestartEA_AfterFridayClose = true;     // Restart After Weekend
input int     DayToRestart = 1;                      // Day To Restart (1=Mon)
input string  TimeToRestart = "01:00";               // Time To Restart

//+------------------------------------------------------------------+
//|  INPUTS - NEWS FILTER                                            |
//+------------------------------------------------------------------+
input group "~~~~News Filter [2026.02.27]~~~~~";
input bool    UseHighImpactNewsFilter = true;        // Use News Filter
input int     HoursBeforeNewsToStop = 2;             // Hours Before News
input int     HoursAfterNewsToStart = 1;             // Hours After News
input int     MinutesBeforeNewsNoTransactions = 5;   // Min Before (no transactions)
input int     MinutesAfterNewsNoTransactions = 5;    // Min After (no transactions)
input bool    UsdAffectsAllPairs = true;             // USD Affects All
input enumNewsAction NewsAction = newsActionManage;  // News Action
input bool    NewsInvert = false;                    // Invert News Filter
input string  NewsInfo = "[Backtesting hardcoded to GMT+2/+3 with US DST]"; // [Info]

//+------------------------------------------------------------------+
//|  INPUTS - SEQUENCE LIMITS                                        |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Sequence Limits~~~~~~~~~";
input int     MaxOpenSequences = 0;                 // Max Concurrent Open MR Sequences (0=off)
input int     MaxSequencesPerDay = 0;                // Max Sequences/Day (0=off)
input int     MaxDailyWinners = 0;                   // Max Daily Winners (0=off)
input int     MaxDailyLosers = 0;                    // Max Daily Losers (0=off)
input enumRestart MaxSequencesRestartEa = restartNextDay; // Restart After Max

//+------------------------------------------------------------------+
//|  INPUTS - SEQUENCE PROTECTION                                    |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Sequence Protection~~~~~~~~~";
input double  MaxLossPerSequence = 0;                // Max Loss Per Sequence $ (0=off)
input bool    EnableZScoreExit = false;               // Z-Score Exit Filter
input double  Z_ExitThreshold = 0;                   // Z Exit Threshold (close when Z crosses 0)
input bool    EnableCorrGuard = false;                // Correlation Breakdown Guard
input double  CorrBreakdownThreshold = 0.5;           // Min Live |r| (force-close below)
input int     CooldownBars = 0;                      // Cooldown (bars after seq close, 0=off)

//+------------------------------------------------------------------+
//|  INPUTS - GLOBAL EQUITY PROTECTION                               |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Global Equity Protection~~~~~~~~~";
input enumGlobalEpType GlobalEpType = globalEpAbsolute; // Equity Stop Type
input double  GlobalEquityStop = 0;                  // Global Equity Stop (0=off)
input double  UltimateTargetBalance = 0;             // Ultimate Target (0=off)
input double  ProfitCloseEquityAmount = 0;           // Daily Profit Target (0=off)
input enumRestart RestartEaAfterLoss = restartNextDay; // Restart After Loss
input string  TimeOfRestart_Equity = "01:00";        // Restart Time
input int     RestartInHours = 0;                    // Restart In Hours
input bool    RescueCloseInDrawdown = false;         // Close In Drawdown If Net Profit
input double  RescueDrawdownThreshold = 0;           // Rescue DD Threshold $ (0=off)

//+------------------------------------------------------------------+
//|  INPUTS - DASHBOARD                                              |
//+------------------------------------------------------------------+
input group "~~~~~~~~~Dashboard~~~~~~~~~";
input bool    ShowDashboard = true;                  // Show Panel
input ENUM_STRATEGY_TYPE DashboardButtonStrategyDefault = STRAT_MEAN_REVERSION; // Dashboard Buy/Sell open strategy
const int     X_Axis = 10;                           // X Position
const int     Y_Axis = 30;                           // Y Position
input enumVisualTheme VisualTheme = themeDark;       // Dashboard/Chart Theme
const int     DashboardWidthPx = 820;                // Fixed Dashboard Width
const int     DashboardHeightPx = 520;               // Fixed Dashboard Height
const bool    DashboardAutoHeight = true;            // Auto height by content/news
const int     DashboardMinHeightPx = 100;            // Min height when auto

//+------------------------------------------------------------------+
//|  NEWS DATA INCLUDE                                               |
//+------------------------------------------------------------------+
#include "hvzone_news_data.mqh"

//+------------------------------------------------------------------+
//|  GLOBAL VARIABLES                                                |
//+------------------------------------------------------------------+
string   propVersion = "1.00";
string   EAName = "ZScoreMurreySniper";
string   version;

// Symbols
string   allSymbols[];
int      numSymbols = 0;
string   breakoutSymbols[];
int      numBreakoutSymbols = 0;

// Currency strength matrix
#define MAX_STRENGTH_CCY 12
string   strengthCurrencies[MAX_STRENGTH_CCY];
double   strengthScores[MAX_STRENGTH_CCY];
int      strengthCounts[MAX_STRENGTH_CCY];
int      strengthRank[MAX_STRENGTH_CCY];
int      strengthCcyCount = 0;
datetime lastStrengthRefreshBarTime = 0;

// Active pairs
ActivePair activePairs[MAX_PAIRS];
int      numActivePairs = 0;
datetime lastScanTime = 0;

// Sequences: MAX_PAIRS * 2 (buy + sell per pair)
SequenceState sequences[MAX_PAIRS * 2];
long     breakoutMagic[MAX_SYMBOLS];
bool     breakoutOpen[MAX_SYMBOLS];
bool     breakoutPrevOpen[MAX_SYMBOLS];
int      breakoutSide[MAX_SYMBOLS];
int      breakoutPrevSide[MAX_SYMBOLS];
double   breakoutPlOpen[MAX_SYMBOLS];
double   breakoutPlPrev[MAX_SYMBOLS];
double   breakoutLastCloseProfit[MAX_SYMBOLS];
datetime breakoutLastCloseTime[MAX_SYMBOLS];
datetime breakoutLastEntryTime[MAX_SYMBOLS];
bool     breakoutCloseMrPending[MAX_SYMBOLS];
int      breakoutCloseMrSidePending[MAX_SYMBOLS];
double   breakoutFrozenUpper[MAX_SYMBOLS];
double   breakoutFrozenLower[MAX_SYMBOLS];
double   breakoutFrozenInc[MAX_SYMBOLS];
datetime breakoutFrozenBarTime[MAX_SYMBOLS];

// Price/time
double   bid, ask, spread;
datetime CurTime;
MqlDateTime now;
bool     newBar = false, newBarM1 = false, newDay = false;
int      lastDay = 0;
bool     firstTickSinceInit = true;
datetime lastBarTime = 0, lastBarTimeM1 = 0;

// ATR
int      atrHandle = INVALID_HANDLE;
string   atrCacheSymbols[];
int      atrCacheHandles[];
string   kcAtrCacheSymbols[];
int      kcAtrCacheHandles[];
string   kcEmaCacheSymbols[];
int      kcEmaCacheHandles[];
double   atrPips = 0;
bool     calculateAtr = false;
double   point, pip;

// EMA cache
string   emaCacheSymbols[];
int      emaCacheHandles[];
ENUM_TIMEFRAMES emaCacheTf[];
int      emaCachePeriod[];

// News
string   page = "";
datetime newsTime[], arrBlockingNews[];
datetime arrBlockingAllDayStart[], arrBlockingAllDayEnd[];
string   newsName[], newsImpact[], newsCurr[];
bool     newsAllDay[], arrBlockingAllDayNoTx[];
int      gmtOffsetHours;
bool     blockingNews = false, blockingNewsNoTransactions = false;
datetime lastNewsDownloadTime;
datetime lastNewsEvalTime = 0;
bool     IsTester, IsVisual;

// Counters
int      sequenceCounter = 0, sequenceCounterWinners = 0, sequenceCounterLosers = 0;
int      sequenceCounterFinal = 0, sequenceCounterWinnersFinal = 0, sequenceCounterLosersFinal = 0;
bool     maxDailyWinnersLosersHit = false;
long     baseMagicNumber;
int      magicCounter = 0;   // Global counter for unique magic number generation

// State
bool     hard_stop = false;
string   stopReason = "";
datetime restartTime = 0, nextStartTime = 0;
bool     time_wait_restart = false;
double   plClosedToday = 0;
int      positionsTotalPrev = 0;
int      closeAll = 0, closeBuy = 0, closeSell = 0;
datetime timeEAstart;
int      epCounter = 0;
int      tradesOpened = 0;
bool     lastOrderBlockedPreSend = false;
int      lastOrderBlockedSeq = -1;
string   lastOrderBlockedSymbol = "";
string   lastOrderBlockedReason = "";
bool     dashboardManualOverrideOpenRisk = false;
int      lastScannedManagedPosTotal = -1;
ENUM_STRATEGY_TYPE dashboardButtonStrategy = STRAT_MEAN_REVERSION;
ENUM_STRATEGY_TYPE pendingOrderStrategy = STRAT_MEAN_REVERSION;
string   pendingOrderSymbol = "";
string   pipValueRefSymbolResolved = "";
double   pipValueRefPip = 0.0;

// Entry bar cache (shift=1 OHLC per symbol)
string   entryBarCacheSymbols[];
datetime entryBarCachePrevBarTime[];
double   entryBarCacheClose[];
double   entryBarCacheHigh[];
double   entryBarCacheLow[];
int      entryBarCacheDigits[];

// Global lock profit
bool     globalLockProfitExec = false;
double   globalPlHigh = 0;

// Global pips lock profit
bool     globalPipsLockExec = false;
double   globalPipsHigh = 0;

// Performance Caching
double   cachedPlToday = 0;
bool     plDirty = true;
datetime lastPlUpdate = 0;

// Panel
int      panelPosY, panelLineNo, x_Axis;
int      panelMaxChars = 0;
int      panelExtraWidthPx = 0;
int      panelLastLines = 40;
int      panelLastChars = 120;
datetime lastDashboardRefresh = 0;
double   scaling;
double   accountOpenPlLow = 0;
double   accountOpenPlHigh = 0;
bool     accountOpenPlInitialized = false;
double   symbolOpenPlLow[];
double   symbolOpenPlHigh[];
bool     symbolOpenPlInitialized[];

// Panel Visibility Toggles
bool     showSymbols = true;
bool     showEvents = true;

//+------------------------------------------------------------------+
//|  HELPER FUNCTIONS                                                |
//+------------------------------------------------------------------+
int SeqIdx(int pairIdx, int side) { return pairIdx * 2 + side; }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMagicInUseAnywhere(long magic)
  {
   if(magic <= 0)
      return true;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].magicNumber == magic)
         return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(IsManagedPositionComment(cmt) || IsHedgePositionComment(cmt))
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
long AllocateUnusedSequenceMagic()
  {
   while(true)
     {
      magicCounter++;
      long candidate = baseMagicNumber + 100 + magicCounter;
      if(!IsMagicInUseAnywhere(candidate))
         return candidate;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime stringToTime(string timeStr)
  {
   return StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " " + timeStr);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLotForSymbol(double lots, string symbol)
  {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0)
      minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(maxLot <= 0)
      maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lotStep <= 0)
      lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int stepDigits = 0;
   double probeStep = lotStep;
   while(stepDigits < 8 && MathAbs(probeStep - MathRound(probeStep)) > 1e-8)
     {
      probeStep *= 10.0;
      stepDigits++;
     }
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(lots, stepDigits);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
  {
   return NormalizeLotForSymbol(lots, _Symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetLegacyBaseLotSize()
  {
   return NormalizeLot(LotSize);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetStrategyLotConfig(const ENUM_STRATEGY_TYPE strat, double &baseLotOut, double &multOut, double &maxLotsOut, double &riskPctOut)
  {
   if(strat == STRAT_TRENDING)
     {
      baseLotOut = TrendLotSizeBase;
      multOut = TrendLotMultiplier;
      maxLotsOut = TrendMaxLots;
      riskPctOut = TrendRiskPercent;
      return;
     }
   baseLotOut = MrLotSize;
   multOut = MrLotMultiplier;
   maxLotsOut = MrMaxLots;
   riskPctOut = MrRiskPercent;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double SymbolPointValue(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_POINT);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double SymbolPipValue(string symbol)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pt = SymbolPointValue(symbol);
   if(digits == 3 || digits == 5)
      return pt * 10.0;
   return pt;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResolvePipValueReference()
  {
   string ref = PipValueReferenceSymbol;
   StringTrimLeft(ref);
   StringTrimRight(ref);
   if(StringLen(ref) > 0 && SymbolInfoInteger(ref, SYMBOL_EXIST))
     {
      double p = SymbolPipValue(ref);
      if(p > 0)
        {
         pipValueRefSymbolResolved = ref;
         pipValueRefPip = p;
         return;
        }
     }

   pipValueRefSymbolResolved = "";
   pipValueRefPip = 0.0;
   for(int i = 0; i < numSymbols; i++)
     {
      string s = allSymbols[i];
      double p = SymbolPipValue(s);
      if(StringLen(s) > 0 && p > 0)
        {
         pipValueRefSymbolResolved = s;
         pipValueRefPip = p;
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetPipValueNormalizationFactor(const string symbol)
  {
   if(!UsePipValueLotNormalization || !NormalizeLotsPerStrategy)
      return 1.0;
   if(pipValueRefPip <= 0.0)
      ResolvePipValueReference();
   double tgt = SymbolPipValue(symbol);
   if(pipValueRefPip <= 0.0 || tgt <= 0.0)
      return 1.0;
   return pipValueRefPip / tgt;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetBaseLotSizeForStrategy(const ENUM_STRATEGY_TYPE strat, const string symbol)
  {
   double baseLot = 0.0, mult = 1.0, maxLotsLocal = 0.0, riskPct = 0.0;
   GetStrategyLotConfig(strat, baseLot, mult, maxLotsLocal, riskPct);
   if(baseLot <= 0.0)
      baseLot = GetLegacyBaseLotSize();
   double normFactor = GetPipValueNormalizationFactor(symbol);
   return NormalizeLotForSymbol(baseLot * normFactor, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double MaxSpreadPointsForSymbol(double spreadPips, string symbol)
  {
   double pointValue = SymbolPointValue(symbol);
   double pipValue = SymbolPipValue(symbol);
   if(pointValue <= 0 || pipValue <= 0)
      return 0;
   return spreadPips * (pipValue / pointValue);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SupportsFillingMode(string symbol, ENUM_ORDER_TYPE_FILLING mode)
  {
   long fillingFlags = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if(fillingFlags <= 0)
      return false;
   if(mode == ORDER_FILLING_FOK)
      return ((fillingFlags & ORDER_FILLING_FOK) == ORDER_FILLING_FOK);
   if(mode == ORDER_FILLING_IOC)
      return ((fillingFlags & ORDER_FILLING_IOC) == ORDER_FILLING_IOC);
   if(mode == ORDER_FILLING_RETURN)
      return ((fillingFlags & ORDER_FILLING_RETURN) == ORDER_FILLING_RETURN);
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING ResolveFillingMode(string symbol)
  {
   if(SupportsFillingMode(symbol, ORDER_FILLING_FOK))
      return ORDER_FILLING_FOK;
   if(SupportsFillingMode(symbol, ORDER_FILLING_IOC))
      return ORDER_FILLING_IOC;
   if(SupportsFillingMode(symbol, ORDER_FILLING_RETURN))
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_IOC;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NextLotForStrategy(int existingPositions, const ENUM_STRATEGY_TYPE strat, const string symbol)
  {
   double baseLot = GetBaseLotSizeForStrategy(strat, symbol);
   double lotMult = 1.0, maxLotsLocal = 0.0, riskPct = 0.0, tmpBase = 0.0;
   GetStrategyLotConfig(strat, tmpBase, lotMult, maxLotsLocal, riskPct);
   double lot = baseLot;
   for(int i = 0; i < existingPositions; i++)
      lot = lot * lotMult;
   if(lot > maxLotsLocal && maxLotsLocal > 0)
      lot = maxLotsLocal;
   return NormalizeLotForSymbol(lot, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NextLot(int existingPositions)
  {
   string sym = pendingOrderSymbol;
   if(StringLen(sym) == 0)
      sym = _Symbol;
   return NextLotForStrategy(existingPositions, pendingOrderStrategy, sym);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLotNoMinClamp(double lots, string symbol)
  {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0)
      minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(maxLot <= 0)
      maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lotStep <= 0)
      lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lots < minLot - EPS)
      return 0;
   if(lots > maxLot)
      lots = maxLot;

   int stepDigits = 0;
   double probeStep = lotStep;
   while(stepDigits < 8 && MathAbs(probeStep - MathRound(probeStep)) > 1e-8)
     {
      probeStep *= 10.0;
      stepDigits++;
     }

   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot - EPS)
      return 0;
   return NormalizeDouble(lots, stepDigits);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalcRiskLotsForSymbol(string symbol, double riskPercent, double stopDistancePrice)
  {
   double baseLot = 0.0, mult = 1.0, maxLotsLocal = 0.0, strategyRiskPct = 0.0;
   GetStrategyLotConfig(pendingOrderStrategy, baseLot, mult, maxLotsLocal, strategyRiskPct);
   double rp = (strategyRiskPct > 0.0) ? strategyRiskPct : riskPercent;
   if(rp <= 0 || stopDistancePrice <= 0)
      return 0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0)
      return 0;
   double riskMoney = equity * rp / 100.0;
   if(riskMoney <= 0)
      return 0;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
      return 0;

   double stopTicks = stopDistancePrice / tickSize;
   if(stopTicks <= 0)
      return 0;
   double riskPerLot = stopTicks * tickValue;
   if(riskPerLot <= 0)
      return 0;

   double rawLots = riskMoney / riskPerLot;
   return NormalizeLotNoMinClamp(rawLots, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetAtrHandleForSymbol(string symbol)
  {
   for(int i = 0; i < ArraySize(atrCacheSymbols); i++)
     {
      if(atrCacheSymbols[i] == symbol)
        {
         if(atrCacheHandles[i] != INVALID_HANDLE)
            return atrCacheHandles[i];
         atrCacheHandles[i] = iATR(symbol, (ENUM_TIMEFRAMES)ATRtimeframe, AtrPeriod);
         return atrCacheHandles[i];
        }
     }

   int handle = iATR(symbol, (ENUM_TIMEFRAMES)ATRtimeframe, AtrPeriod);
   int newIdx = ArraySize(atrCacheSymbols);
   ArrayResize(atrCacheSymbols, newIdx + 1);
   ArrayResize(atrCacheHandles, newIdx + 1);
   atrCacheSymbols[newIdx] = symbol;
   atrCacheHandles[newIdx] = handle;
   return handle;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ReleaseAtrCache()
  {
   for(int i = 0; i < ArraySize(atrCacheHandles); i++)
     {
      if(atrCacheHandles[i] != INVALID_HANDLE)
         IndicatorRelease(atrCacheHandles[i]);
     }
   ArrayResize(atrCacheSymbols, 0);
   ArrayResize(atrCacheHandles, 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetAtrPipsForSymbol(string symbol)
  {
   int handle = GetAtrHandleForSymbol(symbol);
   if(handle == INVALID_HANDLE)
      return atrPips;
   double atrBuf[];
   double val = atrPips;
   if(CopyBuffer(handle, 0, 0, 1, atrBuf) > 0)
     {
      double sp = SymbolPipValue(symbol);
      if(sp > 0)
         val = atrBuf[0] / sp;
     }
   return val;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetKeltnerAtrHandleForSymbol(string symbol)
  {
   for(int i = 0; i < ArraySize(kcAtrCacheSymbols); i++)
     {
      if(kcAtrCacheSymbols[i] == symbol)
        {
         if(kcAtrCacheHandles[i] != INVALID_HANDLE)
            return kcAtrCacheHandles[i];
         kcAtrCacheHandles[i] = iATR(symbol, (ENUM_TIMEFRAMES)KeltnerTimeframe, KeltnerAtrPeriod);
         return kcAtrCacheHandles[i];
        }
     }

   int handle = iATR(symbol, (ENUM_TIMEFRAMES)KeltnerTimeframe, KeltnerAtrPeriod);
   int newIdx = ArraySize(kcAtrCacheSymbols);
   ArrayResize(kcAtrCacheSymbols, newIdx + 1);
   ArrayResize(kcAtrCacheHandles, newIdx + 1);
   kcAtrCacheSymbols[newIdx] = symbol;
   kcAtrCacheHandles[newIdx] = handle;
   return handle;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetKeltnerEmaHandleForSymbol(string symbol)
  {
   int emaPeriod = KeltnerEmaPeriod;
   if(emaPeriod <= 0)
      emaPeriod = 1;
   for(int i = 0; i < ArraySize(kcEmaCacheSymbols); i++)
     {
      if(kcEmaCacheSymbols[i] == symbol)
        {
         if(kcEmaCacheHandles[i] != INVALID_HANDLE)
            return kcEmaCacheHandles[i];
         kcEmaCacheHandles[i] = iMA(symbol, (ENUM_TIMEFRAMES)KeltnerTimeframe, emaPeriod, 0, MODE_EMA, PRICE_TYPICAL);
         return kcEmaCacheHandles[i];
        }
     }

   int handle = iMA(symbol, (ENUM_TIMEFRAMES)KeltnerTimeframe, emaPeriod, 0, MODE_EMA, PRICE_TYPICAL);
   int newIdx = ArraySize(kcEmaCacheSymbols);
   ArrayResize(kcEmaCacheSymbols, newIdx + 1);
   ArrayResize(kcEmaCacheHandles, newIdx + 1);
   kcEmaCacheSymbols[newIdx] = symbol;
   kcEmaCacheHandles[newIdx] = handle;
   return handle;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ReleaseKeltnerCache()
  {
   for(int i = 0; i < ArraySize(kcAtrCacheHandles); i++)
     {
      if(kcAtrCacheHandles[i] != INVALID_HANDLE)
         IndicatorRelease(kcAtrCacheHandles[i]);
     }
   for(int i = 0; i < ArraySize(kcEmaCacheHandles); i++)
     {
      if(kcEmaCacheHandles[i] != INVALID_HANDLE)
         IndicatorRelease(kcEmaCacheHandles[i]);
     }
   ArrayResize(kcAtrCacheSymbols, 0);
   ArrayResize(kcAtrCacheHandles, 0);
   ArrayResize(kcEmaCacheSymbols, 0);
   ArrayResize(kcEmaCacheHandles, 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetKeltnerWidthPipsForSymbol(string symbol)
  {
   int atrHandleLocal = GetKeltnerAtrHandleForSymbol(symbol);
   int emaHandleLocal = GetKeltnerEmaHandleForSymbol(symbol);
   if(atrHandleLocal == INVALID_HANDLE || emaHandleLocal == INVALID_HANDLE)
      return 0;
   double atrBuf[], emaBuf[];
   if(CopyBuffer(atrHandleLocal, 0, 0, 1, atrBuf) <= 0)
      return 0;
   if(CopyBuffer(emaHandleLocal, 0, 0, 1, emaBuf) <= 0)
      return 0;
   double sp = SymbolPipValue(symbol);
   if(sp <= 0)
      return 0;
   double mult = KeltnerAtrMultiplier;
   if(mult <= 0)
      mult = 1.0;
   // Proper Keltner channel:
   // center = EMA(typical), upper = center + ATR*mult, lower = center - ATR*mult.
   double center = emaBuf[0];
   double upper = center + atrBuf[0] * mult;
   double lower = center - atrBuf[0] * mult;
   return MathAbs(upper - lower) / sp;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetRangePipsForSymbol(string symbol)
  {
   if(RangeMetric == rangeKeltnerWidth)
     {
      double kcw = GetKeltnerWidthPipsForSymbol(symbol);
      if(kcw > 0)
         return kcw;
     }
   return GetAtrPipsForSymbol(symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetRangePipsForSymbolByMetric(const enumRangeMetric metric, string symbol)
  {
   if(metric == rangeKeltnerWidth)
     {
      double kcw = GetKeltnerWidthPipsForSymbol(symbol);
      if(kcw > 0)
         return kcw;
     }
   return GetAtrPipsForSymbol(symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ResolveATRForSymbol(double inputVal, string symbol)
  {
   if(inputVal < 0)
      return MathAbs(inputVal) * GetRangePipsForSymbol(symbol);
   return inputVal;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ResolveMinIncrement(double inputVal, string symbol)
  {
   if(inputVal == 0)
      return 0;
   double pips = inputVal;
   if(pips < 0)
      pips = MathAbs(pips) * GetRangePipsForSymbol(symbol);
   return pips * SymbolPipValue(symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
enumRangeMetric GetStrategyRangeMetric(const ENUM_STRATEGY_TYPE strat)
  {
   if(strat == STRAT_TRENDING)
      return TrendRangeMetric;
   return MrRangeMetric;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ResolveMinIncrementForStrategy(double inputVal, string symbol, const ENUM_STRATEGY_TYPE strat)
  {
   if(inputVal == 0)
      return 0;
   double pips = inputVal;
   if(pips < 0)
      pips = MathAbs(pips) * GetRangePipsForSymbolByMetric(GetStrategyRangeMetric(strat), symbol);
   return pips * SymbolPipValue(symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ResolvePipsOrRangeForStrategy(double inputVal, string symbol, const ENUM_STRATEGY_TYPE strat)
  {
   if(inputVal < 0)
      return MathAbs(inputVal) * GetRangePipsForSymbolByMetric(GetStrategyRangeMetric(strat), symbol);
   return inputVal;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool isNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool isNewBarM1()
  {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != lastBarTimeM1)
     {
      lastBarTimeM1 = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSessionOpen()
  {
   datetime startDt = stringToTime(SessionStartTime);
   datetime endDt = stringToTime(SessionEndTime);
   if(startDt < endDt)
      return (CurTime >= startDt && CurTime < endDt);
   else
      return (CurTime >= startDt || CurTime < endDt);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSessionWindowOpen(const string startTime, const string endTime)
  {
   datetime startDt = stringToTime(startTime);
   datetime endDt = stringToTime(endTime);
   if(startDt < endDt)
      return (CurTime >= startDt && CurTime < endDt);
   return (CurTime >= startDt || CurTime < endDt);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsStrategySessionOpen(const ENUM_STRATEGY_TYPE strat)
  {
   if(strat == STRAT_TRENDING)
      return IsSessionWindowOpen(TrendSessionStartTime, TrendSessionEndTime);
   return IsSessionWindowOpen(MrSessionStartTime, MrSessionEndTime);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_SESSION_END GetStrategySessionEndAction(const ENUM_STRATEGY_TYPE strat)
  {
   if(strat == STRAT_TRENDING)
      return TrendSessionEndAction;
   return MrSessionEndAction;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CanOpenSide(int side)
  {
   if(Direction == DIR_LONG && side == SIDE_SELL)
      return false;
   if(Direction == DIR_SHORT && side == SIDE_BUY)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsManagedPositionComment(string comment)
  {
   return (StringFind(comment, "ZSM") == 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMrPositionComment(string comment)
  {
   if(!IsManagedPositionComment(comment))
      return false;
   if(IsBreakoutPositionComment(comment))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBreakoutPositionComment(string comment)
  {
   return (StringFind(comment, "ZSM-BO") == 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsHedgePositionComment(string comment)
  {
   return (StringFind(comment, "ZSHEDGE") == 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetOpenPositionCommission(long positionId)
  {
   if(positionId <= 0)
      return 0.0;
   if(!HistorySelectByPosition((ulong)positionId))
      return 0.0;
   double commission = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType == DEAL_ENTRY_IN || entryType == DEAL_ENTRY_INOUT)
         commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
     }
   return commission;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double MmLevelByEighth(double mm08, double mmInc, int levelEighth)
  {
   int level = levelEighth;
   if(level < -2)
      level = -2;
   if(level > 10)
      level = 10;
   return mm08 + (level * mmInc);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ResolveEntryBarPrice(double lastClose, double lastHigh, double lastLow, int side)
  {
   if(EntryPriceType == entryOnTick)
     {
      if(side == SIDE_BUY)
         return lastLow;   // down-cross checks use candle low
      return lastHigh;                // up-cross checks use candle high
     }
   return lastClose;
  }

//+------------------------------------------------------------------+
//|  SYMBOL PARSING                                                  |
//+------------------------------------------------------------------+
void ParseSymbols()
  {
   string result[];
   int count = StringSplit(Trade_Symbols, ',', result);
   numSymbols = 0;
   ArrayResize(allSymbols, count);
   for(int i = 0; i < count; i++)
     {
      string s = result[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) > 0 && SymbolInfoInteger(s, SYMBOL_EXIST))
        {
         allSymbols[numSymbols] = s;
         numSymbols++;
        }
      else
         if(StringLen(s) > 0)
           {
            Print("[Scanner] Symbol not found: ", s);
           }
     }
   ArrayResize(allSymbols, numSymbols);
   ArrayResize(symbolOpenPlLow, numSymbols);
   ArrayResize(symbolOpenPlHigh, numSymbols);
   ArrayResize(symbolOpenPlInitialized, numSymbols);
   for(int i = 0; i < numSymbols; i++)
     {
      symbolOpenPlLow[i] = 0;
      symbolOpenPlHigh[i] = 0;
      symbolOpenPlInitialized[i] = false;
     }
   Print("[Scanner] Parsed ", numSymbols, " valid symbols");
  }

//+------------------------------------------------------------------+
//|  CURRENCY STRENGTH MATRIX                                        |
//+------------------------------------------------------------------+
int StrengthFindCurrencyIndex(const string ccy)
  {
   for(int i = 0; i < strengthCcyCount; i++)
     {
      if(strengthCurrencies[i] == ccy)
         return i;
     }
   return -1;
  }

int StrengthEnsureCurrency(const string ccy)
  {
   if(StringLen(ccy) != 3)
      return -1;
   int idx = StrengthFindCurrencyIndex(ccy);
   if(idx >= 0)
      return idx;
   if(strengthCcyCount >= MAX_STRENGTH_CCY)
      return -1;
   idx = strengthCcyCount++;
   strengthCurrencies[idx] = ccy;
   strengthScores[idx] = 0.0;
   strengthCounts[idx] = 0;
   strengthRank[idx] = idx;
   return idx;
  }

bool BuildCurrencyStrengthMatrix()
  {
   if(!UseCurrencyStrengthMatrix)
      return false;

   for(int i = 0; i < MAX_STRENGTH_CCY; i++)
     {
      strengthCurrencies[i] = "";
      strengthScores[i] = 0.0;
      strengthCounts[i] = 0;
      strengthRank[i] = i;
     }
   strengthCcyCount = 0;

   int lb = MathMax(2, StrengthLookbackBars);
   ENUM_TIMEFRAMES strengthTf = (ENUM_TIMEFRAMES)StrengthTimeframe;
   for(int i = 0; i < numSymbols; i++)
     {
      string sym = allSymbols[i];
      string base = GetBaseCurrency(sym);
      string quote = GetQuoteCurrency(sym);
      if(StringLen(base) != 3 || StringLen(quote) != 3)
         continue;

      double c0 = iClose(sym, strengthTf, 1);
      double cL = iClose(sym, strengthTf, lb + 1);
      if(c0 <= 0 || cL <= 0)
         continue;

      double ret = (c0 / cL) - 1.0;
      int bIdx = StrengthEnsureCurrency(base);
      int qIdx = StrengthEnsureCurrency(quote);
      if(bIdx < 0 || qIdx < 0)
         continue;

      strengthScores[bIdx] += ret;
      strengthCounts[bIdx]++;
      strengthScores[qIdx] -= ret;
      strengthCounts[qIdx]++;
     }

   for(int i = 0; i < strengthCcyCount; i++)
     {
      if(strengthCounts[i] > 0)
         strengthScores[i] /= (double)strengthCounts[i];
      strengthRank[i] = i;
     }

   for(int a = 0; a < strengthCcyCount - 1; a++)
     {
      int best = a;
      for(int b = a + 1; b < strengthCcyCount; b++)
        {
         if(strengthScores[strengthRank[b]] > strengthScores[strengthRank[best]])
            best = b;
        }
      if(best != a)
        {
         int tmp = strengthRank[a];
         strengthRank[a] = strengthRank[best];
         strengthRank[best] = tmp;
        }
     }

   return (strengthCcyCount >= 4);
  }

bool RefreshStrengthMatrixIfNeeded(const bool forceRefresh=false)
  {
   if(!UseCurrencyStrengthMatrix)
      return false;

   ENUM_TIMEFRAMES strengthTf = (ENUM_TIMEFRAMES)StrengthTimeframe;
   datetime tfBarTime = iTime(_Symbol, strengthTf, 1);
   if(tfBarTime <= 0)
      tfBarTime = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   if(forceRefresh || lastStrengthRefreshBarTime == 0 || tfBarTime != lastStrengthRefreshBarTime)
     {
      bool ok = BuildCurrencyStrengthMatrix();
      if(ok)
         lastStrengthRefreshBarTime = tfBarTime;
      return ok;
     }
   return false;
  }

int StrengthRankOf(const string ccy)
  {
   int idx = StrengthFindCurrencyIndex(ccy);
   if(idx < 0)
      return -1;
   for(int r = 0; r < strengthCcyCount; r++)
     {
      if(strengthRank[r] == idx)
         return r;
     }
   return -1;
  }

bool IsTrendStrengthQualified(const string symbol, const int side)
  {
   if(!UseCurrencyStrengthMatrix)
      return true;
   if(strengthCcyCount < 4)
      return false;
   string base = GetBaseCurrency(symbol);
   string quote = GetQuoteCurrency(symbol);
   int rBase = StrengthRankOf(base);
   int rQuote = StrengthRankOf(quote);
   if(rBase < 0 || rQuote < 0)
      return false;
   int ext = StrengthExtremeCount;
   if(ext < 1)
      ext = 1;
   if(ext > 2)
      ext = 2;
   bool baseStrong = (rBase <= ext - 1);
   bool baseWeak = (rBase >= strengthCcyCount - ext);
   bool quoteStrong = (rQuote <= ext - 1);
   bool quoteWeak = (rQuote >= strengthCcyCount - ext);
   if(side == SIDE_BUY)
      return (baseStrong && quoteWeak);
   return (baseWeak && quoteStrong);
  }

bool IsRangeStrengthQualified(const string symbol)
  {
   if(!UseCurrencyStrengthMatrix)
      return true;
   if(strengthCcyCount < 4)
      return false;
   string base = GetBaseCurrency(symbol);
   string quote = GetQuoteCurrency(symbol);
   int rBase = StrengthRankOf(base);
   int rQuote = StrengthRankOf(quote);
   if(rBase < 0 || rQuote < 0)
      return false;
   int ext = StrengthExtremeCount;
   if(ext < 1)
      ext = 1;
   if(ext > 2)
      ext = 2;
   int lo = ext;
   int hi = strengthCcyCount - ext - 1;
   if(hi < lo)
      return false;
   return (rBase >= lo && rBase <= hi && rQuote >= lo && rQuote <= hi);
  }

bool AnyStrategyMarkovEnabled()
  {
   return (MeanReversionMarkovMode != markovModeOff ||
           TrendingMarkovMode != markovModeOff);
  }

bool GetMarkovRegimeFlags(const string symbol, const enumMarkovMode modeIn,
                          bool &trendingOut, bool &rangingOut, int &stateOut)
  {
   trendingOut = false;
   rangingOut = false;
   stateOut = MARKOV_NEUTRAL;
   enumMarkovMode mode = modeIn;
   if(mode == markovModeOff)
      return false;
   MarkovUpdateSymbol(symbol);
   double conf = 0.0, edge = 0.0, pUp = 0.0, pDown = 0.0, effN = 0.0, volRatio = 1.0;
   bool valid = false;
   if(!MarkovGetSnapshot(symbol, stateOut, conf, edge, pUp, pDown, effN, volRatio, valid))
      return false;
   if(!valid)
      return false;
      
   double dynamicConfReq = Markov_MinConfidence;
   if(volRatio > 1.2)
      dynamicConfReq = MathMin(1.0, dynamicConfReq * MathMin(1.5, volRatio));
      
   trendingOut = (stateOut != MARKOV_NEUTRAL && conf >= dynamicConfReq);
   rangingOut = !trendingOut;
   return true;
  }

bool MarkovModeAllowsEntry(const string symbol, const int side, const bool isTrendStrategy,
                           const enumMarkovMode modeIn, string &reasonOut)
  {
   reasonOut = "";
   enumMarkovMode mode = modeIn;
   if(mode == markovModeOff)
      return true;

   MarkovUpdateSymbol(symbol);
   int st = MARKOV_NEUTRAL;
   double conf = 0.0, edge = 0.0, pUp = 0.0, pDown = 0.0, effN = 0.0, volRatio = 1.0;
   bool valid = false;
   if(!MarkovGetSnapshot(symbol, st, conf, edge, pUp, pDown, effN, volRatio, valid))
     {
      reasonOut = "no_ctx";
      return !Markov_BlockIfUntrained;
     }
   if(!valid)
     {
      reasonOut = "n_low";
      return !Markov_BlockIfUntrained;
     }

   double dynamicConfReq = Markov_MinConfidence;
   if(volRatio > 1.2)
      dynamicConfReq = MathMin(1.0, dynamicConfReq * MathMin(1.5, volRatio));

   bool regimeTrending = (st != MARKOV_NEUTRAL && conf >= dynamicConfReq);
   bool regimeRanging = !regimeTrending;

   if(mode == markovModeTrending)
     {
      if(!regimeTrending)
        {
         reasonOut = "regime_not_trending";
         return false;
        }
      if(isTrendStrategy)
        {
         if((side == SIDE_BUY && st != MARKOV_UPTREND) ||
            (side == SIDE_SELL && st != MARKOV_DOWNTREND))
           {
            reasonOut = "trend_state_mismatch";
            return false;
           }
        }
     }
   else
      if(mode == markovModeRanging && !regimeRanging)
        {
         reasonOut = "regime_not_ranging";
         return false;
        }

   // Directional bias guard (applies in directional mode and as an extra safety in trending mode).
   if(mode == markovModeDirectional || mode == markovModeTrending)
     {
      double probGapUp = pUp - pDown;
      double probGapDown = pDown - pUp;
      if(side == SIDE_BUY)
        {
         bool trendBiasDown = (st == MARKOV_DOWNTREND && conf >= Markov_MinConfidence &&
                               probGapDown >= Markov_MinProbGap);
         bool edgeBiasDown = (edge <= -Markov_MinEdge);
         if(trendBiasDown || edgeBiasDown)
           {
            reasonOut = "bear_bias";
            return false;
           }
        }
      else
        {
         bool trendBiasUp = (st == MARKOV_UPTREND && conf >= Markov_MinConfidence &&
                             probGapUp >= Markov_MinProbGap);
         bool edgeBiasUp = (edge >= Markov_MinEdge);
         if(trendBiasUp || edgeBiasUp)
           {
            reasonOut = "bull_bias";
            return false;
           }
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetMarkovDashboardState(const string symbol, string &stateOut, string &confOut)
  {
   stateOut = "N/A";
   confOut = "N/A";
   if(!AnyStrategyMarkovEnabled())
      return;

   MarkovUpdateSymbol(symbol);
   int st = MARKOV_NEUTRAL;
   double conf = 0.0, edge = 0.0, pUp = 0.0, pDown = 0.0, effN = 0.0, volRatio = 1.0;
   bool valid = false;
   if(!MarkovGetSnapshot(symbol, st, conf, edge, pUp, pDown, effN, volRatio, valid) || !valid)
      return;

   if(st == MARKOV_UPTREND)
      stateOut = "UPTREND";
   else if(st == MARKOV_DOWNTREND)
      stateOut = "DOWNTREND";
   else
      stateOut = "NEUTRAL";

   int confPct = (int)MathRound(conf * 100.0);
   if(confPct < 0)
      confPct = 0;
   if(confPct > 100)
      confPct = 100;
   confOut = IntegerToString(confPct) + "%";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetStrategyMMTimeframe(const ENUM_STRATEGY_TYPE strat)
  {
   if(strat == STRAT_TRENDING)
      return (ENUM_TIMEFRAMES)TrendMM_Timeframe;
   return (ENUM_TIMEFRAMES)MrMM_Timeframe;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ParseBreakoutSymbols()
  {
   string result[];
   int count = StringSplit(Breakout_Symbols, ',', result);
   numBreakoutSymbols = 0;
   ArrayResize(breakoutSymbols, count);
   for(int i = 0; i < count; i++)
     {
      string s = result[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) > 0 && SymbolInfoInteger(s, SYMBOL_EXIST))
        {
         if(numBreakoutSymbols >= MAX_SYMBOLS)
           {
            Print("[Breakout] MAX_SYMBOLS (", MAX_SYMBOLS, ") reached, skipping: ", s);
            continue;
           }
         breakoutSymbols[numBreakoutSymbols] = s;
         numBreakoutSymbols++;
        }
      else
         if(StringLen(s) > 0)
            Print("[Breakout] Symbol not found: ", s);
     }
   ArrayResize(breakoutSymbols, numBreakoutSymbols);
   Print("[Breakout] Parsed ", numBreakoutSymbols, " valid symbols");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindBreakoutSymbolIndex(string symbol)
  {
   for(int i = 0; i < numBreakoutSymbols; i++)
     {
      if(SymbolsEqual(breakoutSymbols[i], symbol))
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// GetBaseCurrency and GetQuoteCurrency are now in Sniper_Math.mqh

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetOtherPairSymbol(int pairIdx, string symbol)
  {
   if(symbol == activePairs[pairIdx].symbolA)
      return activePairs[pairIdx].symbolB;
   return activePairs[pairIdx].symbolA;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetSequenceTradeSymbol(int seqIdx, int pairIdx)
  {
   if(StringLen(sequences[seqIdx].tradeSymbol) > 0)
      return sequences[seqIdx].tradeSymbol;
   return activePairs[pairIdx].symbolA;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindEntryBarCacheIndex(string symbol)
  {
   for(int i = 0; i < ArraySize(entryBarCacheSymbols); i++)
     {
      if(entryBarCacheSymbols[i] == symbol)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ClearEntryBarCache()
  {
   ArrayResize(entryBarCacheSymbols, 0);
   ArrayResize(entryBarCachePrevBarTime, 0);
   ArrayResize(entryBarCacheClose, 0);
   ArrayResize(entryBarCacheHigh, 0);
   ArrayResize(entryBarCacheLow, 0);
   ArrayResize(entryBarCacheDigits, 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ShouldScanPositionsEveryTick()
  {
   if(MaxLossPerSequence > 0)
      return true;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].tradeCount <= 0)
         continue;
      bool isTrend = (sequences[i].strategyType == STRAT_TRENDING);
      enumTrailFrequency freq = sequences[i].lockProfitExec ?
                                (isTrend ? TrendTrailFrequency : TrailFrequency) :
                                (isTrend ? TrendLockProfitCheckFrequency : LockProfitCheckFrequency);
      if(freq == trailEveryTick)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SequenceNeedsReconstruct(const int seqIdx, const int pairIdx)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   if(pairIdx < 0 || pairIdx >= MAX_PAIRS)
      return false;
   if(sequences[seqIdx].tradeCount <= 0)
      return false;
   if(sequences[seqIdx].entryMmIncrement <= EPS)
      return true;
   if(sequences[seqIdx].side == SIDE_BUY)
      return (activePairs[pairIdx].entry_mm_08 == 0 || activePairs[pairIdx].entry_mm_minus28 == 0);
   return (activePairs[pairIdx].entry_mm_88 == 0 || activePairs[pairIdx].entry_mm_plus28 == 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ReadEntryBarPrices(string symbol, double &downCrossPrice, double &upCrossPrice,
                        double &closePriceOut, int &symDigits, double &symSpread)
  {
   datetime prevBarTime = iTime(symbol, PERIOD_CURRENT, 1);
   if(prevBarTime <= 0)
      return false;

   int cIdx = FindEntryBarCacheIndex(symbol);
   if(cIdx < 0)
     {
      cIdx = ArraySize(entryBarCacheSymbols);
      ArrayResize(entryBarCacheSymbols, cIdx + 1);
      ArrayResize(entryBarCachePrevBarTime, cIdx + 1);
      ArrayResize(entryBarCacheClose, cIdx + 1);
      ArrayResize(entryBarCacheHigh, cIdx + 1);
      ArrayResize(entryBarCacheLow, cIdx + 1);
      ArrayResize(entryBarCacheDigits, cIdx + 1);
      entryBarCacheSymbols[cIdx] = symbol;
      entryBarCachePrevBarTime[cIdx] = 0;
     }

   if(entryBarCachePrevBarTime[cIdx] != prevBarTime)
     {
      MqlRates rates[];
      if(CopyRates(symbol, PERIOD_CURRENT, 1, 1, rates) < 1)
         return false;
      entryBarCacheClose[cIdx] = rates[0].close;
      entryBarCacheHigh[cIdx] = rates[0].high;
      entryBarCacheLow[cIdx] = rates[0].low;
      entryBarCacheDigits[cIdx] = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      entryBarCachePrevBarTime[cIdx] = prevBarTime;
     }

   double lastClose = entryBarCacheClose[cIdx];
   double lastHigh = entryBarCacheHigh[cIdx];
   double lastLow = entryBarCacheLow[cIdx];
   downCrossPrice = ResolveEntryBarPrice(lastClose, lastHigh, lastLow, SIDE_BUY);
   upCrossPrice = ResolveEntryBarPrice(lastClose, lastHigh, lastLow, SIDE_SELL);
   symDigits = entryBarCacheDigits[cIdx];
   double bidLocal = SymbolInfoDouble(symbol, SYMBOL_BID);
   double askLocal = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double pointLocal = SymbolInfoDouble(symbol, SYMBOL_POINT);
   closePriceOut = lastClose;
   if(pointLocal <= 0)
      return false;
   symSpread = (askLocal - bidLocal) / pointLocal;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetEmaValue(string symbol, ENUM_TIMEFRAMES timeframe, int period, int shift, double &emaValue)
  {
   emaValue = 0;
   if(period <= 0)
      return false;

   // Search cache for matching handle
   int handle = INVALID_HANDLE;
   for(int i = 0; i < ArraySize(emaCacheSymbols); i++)
     {
      if(emaCacheSymbols[i] == symbol && emaCacheTf[i] == timeframe && emaCachePeriod[i] == period)
        {
         handle = emaCacheHandles[i];
         break;
        }
     }

   // Create and cache if not found
   if(handle == INVALID_HANDLE)
     {
      handle = iMA(symbol, timeframe, period, 0, MODE_EMA, PRICE_CLOSE);
      if(handle == INVALID_HANDLE)
         return false;
      int idx = ArraySize(emaCacheSymbols);
      ArrayResize(emaCacheSymbols, idx + 1);
      ArrayResize(emaCacheHandles, idx + 1);
      ArrayResize(emaCacheTf, idx + 1);
      ArrayResize(emaCachePeriod, idx + 1);
      emaCacheSymbols[idx] = symbol;
      emaCacheHandles[idx] = handle;
      emaCacheTf[idx] = timeframe;
      emaCachePeriod[idx] = period;
     }

   double emaBuf[];
   bool ok = (CopyBuffer(handle, 0, shift, 1, emaBuf) > 0);
   if(!ok)
      return false;
   emaValue = emaBuf[0];
   return true;
  }

//+------------------------------------------------------------------+
//|
//+------------------------------------------------------------------+
void ReleaseEmaCache()
  {
   for(int i = 0; i < ArraySize(emaCacheHandles); i++)
     {
      if(emaCacheHandles[i] != INVALID_HANDLE)
         IndicatorRelease(emaCacheHandles[i]);
     }
   ArrayResize(emaCacheSymbols, 0);
   ArrayResize(emaCacheHandles, 0);
   ArrayResize(emaCacheTf, 0);
   ArrayResize(emaCachePeriod, 0);
  }

//+------------------------------------------------------------------+
//|  LP-vs-Murrey Boundary Filter                                    |
//+------------------------------------------------------------------+
bool IsLpBeyondMurreyBoundary(string symbol, int side)
  {
   if(LP_MM_Lookback <= 0)
      return false;
   if(LockProfitTriggerPips == 0)
      return false;  // no LP configured, nothing to check

   // Calculate LP trigger distance in price units
   double lpTriggerPips = ResolvePipsOrATR(LockProfitTriggerPips, symbol);
   double lpTriggerPrice = lpTriggerPips * SymbolPipValue(symbol);
   if(lpTriggerPrice <= 0)
      return false;

   // Calculate higher-TF Murrey levels
   double mm88 = 0, mm48 = 0, mm08 = 0, inc = 0;
   double p28 = 0, p18 = 0, m18 = 0, m28 = 0;
   if(!CalcMurreyLevelsForSymbolCustom(symbol, (ENUM_TIMEFRAMES)LP_MM_Timeframe, LP_MM_Lookback,
                                       mm88, mm48, mm08, inc, p28, p18, m18, m28))
      return false;
   if(inc <= 0)
      return false;

   if(side == SIDE_BUY)
     {
      // Buy LP target = entry (ask) + trigger distance
      double entryPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double projectedLp = entryPrice + lpTriggerPrice;
      // Boundary = mm_88 + N * inc  (the +N/8 level)
      double boundary = mm88 + LP_MM_BoundaryEighth * inc;
      if(projectedLp > boundary)
        {
         if(EnableLogging)
            Print("[LpMurreyFilter] BUY blocked on ", symbol,
                  " projLP=", DoubleToString(projectedLp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " > boundary(+", LP_MM_BoundaryEighth, "/8)=", DoubleToString(boundary, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " mm88=", DoubleToString(mm88, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " inc=", DoubleToString(inc, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
         return true;
        }
     }
   else // SIDE_SELL
     {
      // Sell LP target = entry (bid) - trigger distance
      double entryPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
      double projectedLp = entryPrice - lpTriggerPrice;
      // Boundary = mm_08 - N * inc  (the -N/8 level)
      double boundary = mm08 - LP_MM_BoundaryEighth * inc;
      if(projectedLp < boundary)
        {
         if(EnableLogging)
            Print("[LpMurreyFilter] SELL blocked on ", symbol,
                  " projLP=", DoubleToString(projectedLp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " < boundary(-", LP_MM_BoundaryEighth, "/8)=", DoubleToString(boundary, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " mm08=", DoubleToString(mm08, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                  " inc=", DoubleToString(inc, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
         return true;
        }
     }
  return false;
  }

//+------------------------------------------------------------------+
//|  LP-vs-EMA Trade-Into Filter                                     |
//+------------------------------------------------------------------+
bool IsLpTradeIntoEmaBlocked(string symbol, int side)
  {
   if(!UseLpEmaTradeIntoFilter)
      return false;
   if(LockProfitTriggerPips == 0)
      return false;  // no LP configured, nothing to check

   double lpTriggerPips = ResolvePipsOrATR(LockProfitTriggerPips, symbol);
   double lpTriggerPrice = lpTriggerPips * SymbolPipValue(symbol);
   if(lpTriggerPrice <= 0)
      return false;

   double entryPrice = (side == SIDE_BUY) ?
                       SymbolInfoDouble(symbol, SYMBOL_ASK) :
                       SymbolInfoDouble(symbol, SYMBOL_BID);
   if(entryPrice <= 0)
      return false;

   double projectedLp = (side == SIDE_BUY) ?
                        (entryPrice + lpTriggerPrice) :
                        (entryPrice - lpTriggerPrice);

   ENUM_TIMEFRAMES emaTfs[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
   int emaPeriods[] = {20, 50, 200};

   for(int t = 0; t < ArraySize(emaTfs); t++)
     {
      for(int p = 0; p < ArraySize(emaPeriods); p++)
        {
         double emaValue = 0;
         if(!GetEmaValue(symbol, emaTfs[t], emaPeriods[p], 1, emaValue))
            continue; // fail-open if EMA can't be read

         bool blocked = false;
         if(side == SIDE_BUY)
            blocked = (entryPrice < emaValue && projectedLp > emaValue);
         else
            blocked = (entryPrice > emaValue && projectedLp < emaValue);

         if(blocked)
           {
            if(EnableLogging)
              {
               int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
               Print("[LpEmaFilter] ", (side == SIDE_BUY ? "BUY" : "SELL"),
                     " blocked on ", symbol,
                     " entry=", DoubleToString(entryPrice, digits),
                     " projLP=", DoubleToString(projectedLp, digits),
                     " crosses EMA", emaPeriods[p], " ", EnumToString(emaTfs[t]),
                     "=", DoubleToString(emaValue, digits));
              }
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool EmaFilterAllowsOrder(string symbol, ENUM_ORDER_TYPE orderType, double &emaValue, double &refPrice)
  {
   emaValue = 0;
   refPrice = 0;
   if(EMA_FilterPeriod <= 0)
      return true;
   if(orderType != ORDER_TYPE_BUY && orderType != ORDER_TYPE_SELL)
      return true;

   if(!GetEmaValue(symbol, (ENUM_TIMEFRAMES)EMA_FilterTimeframe, EMA_FilterPeriod, 1, emaValue))
      return true; // fail-open if EMA can't be read

   refPrice = (orderType == ORDER_TYPE_BUY) ?
              SymbolInfoDouble(symbol, SYMBOL_ASK) :
              SymbolInfoDouble(symbol, SYMBOL_BID);

// Rule: no buys below EMA, no sells above EMA
   if(orderType == ORDER_TYPE_BUY && refPrice < emaValue)
      return false;
   if(orderType == ORDER_TYPE_SELL && refPrice > emaValue)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  DIRECTIONAL EXPOSURE FILTER (trade-time)                        |
//|  Blocks a new trade if same-direction currency exposure exists    |
//|  BUY EURUSD = Long EUR + Short USD                               |
//|  SELL EURUSD = Short EUR + Long USD                              |
//+------------------------------------------------------------------+
bool HasDirectionalConflict(string symbol, ENUM_ORDER_TYPE orderType, int skipPairIdx)
  {
   string nB = GetBaseCurrency(symbol);
   string nQ = GetQuoteCurrency(symbol);

// Directions: +1 = Buying (Long), -1 = Selling (Short)
   int nBDir = (orderType == ORDER_TYPE_BUY) ? 1 : -1;
   int nQDir = (orderType == ORDER_TYPE_BUY) ? -1 : 1;

   for(int p = 0; p < numActivePairs; p++)
     {
      if(p == skipPairIdx)
         continue;

      // Check both Buy and Sell sequences of the other pair
      int seqs[2];
      seqs[0] = activePairs[p].buySeqIdx;
      seqs[1] = activePairs[p].sellSeqIdx;

      for(int s=0; s<2; s++)
        {
         int sIdx = seqs[s];
         if(sIdx < 0 || sIdx >= MAX_PAIRS * 2)
            continue;

         if(sequences[sIdx].tradeCount > 0)
           {
            // Use the actual symbol this sequence is trading.
            // Falling back to symbolA misclassifies exposure when the entry was on symbolB.
            string pSym = sequences[sIdx].tradeSymbol;
            if(StringLen(pSym) == 0)
               pSym = activePairs[p].symbolA;

            if(StringLen(pSym) < 6)
               continue;

            string pB = GetBaseCurrency(pSym);
            string pQ = GetQuoteCurrency(pSym);

            // Existing directions for this active sequence
            int pBDir = (sequences[sIdx].side == SIDE_BUY) ? 1 : -1;
            int pQDir = (sequences[sIdx].side == SIDE_BUY) ? -1 : 1;

            // Conflict if we try to move the same currency in the same direction
            if((nB == pB && nBDir == pBDir) || // e.g. Both Long EUR
               (nB == pQ && nBDir == pQDir) || // e.g. New Long EUR vs Old Long EUR (as quote)
               (nQ == pB && nQDir == pBDir) || // e.g. New Short USD vs Old Short USD (as base)
               (nQ == pQ && nQDir == pQDir))   // e.g. Both Short USD
               return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  SAME-SYMBOL OPPOSITE-SIDE START FILTER                          |
//|  Blocks starting a new sequence opposite to an open symbol side  |
//+------------------------------------------------------------------+
bool HasOppositeSequenceOpenOnSymbol(string symbol, ENUM_ORDER_TYPE orderType, int skipSeqIdx)
  {
   int newSide = (orderType == ORDER_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(i == skipSeqIdx)
         continue;
      if(sequences[i].tradeCount <= 0)
         continue;
      if(StringLen(sequences[i].tradeSymbol) == 0)
         continue;
      if(sequences[i].tradeSymbol != symbol)
         continue;
      if(sequences[i].side != newSide)
         return true;
     }
  return false;
 }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenBreakoutPositionOnSymbol(string symbol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      if(!IsBreakoutPositionComment(PositionGetString(POSITION_COMMENT)))
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  PEARSON CORRELATION                                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|  Recover magic only when unique for this symbol+side             |
//+------------------------------------------------------------------+
bool TryDetectUniqueOpenSeqMagicForSymbolSide(string symbol, long posType, long &magicOut)
  {
   magicOut = 0;
   bool seen = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(comment) || IsBreakoutPositionComment(comment) || IsHedgePositionComment(comment))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(!seen)
        {
         magicOut = mg;
         seen = true;
        }
      else
         if(mg != magicOut)
            return false; // ambiguous mapping on same symbol+side
     }
   return seen;
  }

//+------------------------------------------------------------------+
//|  SCANNER: Build Active Portfolio                                 |
//+------------------------------------------------------------------+
void RunScanner()
  {
   if(numSymbols < 2)
      return;

// Generate candidate combinations.
   int maxCombos = (numSymbols * (numSymbols - 1) / 2);
   CorrPair combos[];
   ArrayResize(combos, maxCombos);
   int numCombos = 0;

   for(int i = 0; i < numSymbols; i++)
     {
      for(int j = i + 1; j < numSymbols; j++)
        {
         double r = 1.0;
         if(Min_Correlation > 0)
            r = CalcPearsonCorrelation(allSymbols[i], allSymbols[j]);
            
         double absR = MathAbs(r);
         if(absR < Min_Correlation)
            continue;
         double rankScore = absR;

         combos[numCombos].idxA = i;
         combos[numCombos].idxB = j;
         combos[numCombos].r = r;
         combos[numCombos].absR = absR;
         combos[numCombos].score = rankScore;
         numCombos++;
        }
     }
   ArrayResize(combos, numCombos);

// Sort by score descending (simple bubble sort, small N).
   for(int i = 0; i < numCombos - 1; i++)
     {
      for(int j = i + 1; j < numCombos; j++)
        {
         if(combos[j].score > combos[i].score)
           {
            CorrPair tmp = combos[i];
            combos[i] = combos[j];
            combos[j] = tmp;
           }
        }
     }

   ActivePair newPairs[];
   ArrayResize(newPairs, 0);
   int selected = 0;

   for(int i = 0; i < numCombos && selected < Max_Pairs && selected < MAX_PAIRS; i++)
     {
      string sA = allSymbols[combos[i].idxA];
      string sB = allSymbols[combos[i].idxB];
      // Scanner-level filter: no duplicate symbols across pairs
      bool symbolUsed = false;
      for(int j = 0; j < selected; j++)
        {
         if(newPairs[j].symbolA == sA || newPairs[j].symbolB == sA ||
            newPairs[j].symbolA == sB || newPairs[j].symbolB == sB)
           {
            symbolUsed = true;
            break;
           }
        }
      if(symbolUsed)
         continue;
      // NOTE: Directional exposure filtering is done at trade-entry time
      // via HasDirectionalConflict() — not here at scanner level

      // Create pair — carry over state if it already exists
      ArrayResize(newPairs, selected + 1);

      // Check if this pair existed in previous portfolio
      bool carried = false;
      for(int old = 0; old < numActivePairs; old++)
        {
         if(activePairs[old].symbolA == sA && activePairs[old].symbolB == sB)
           {
            // CARRY OVER: Preserve all auxiliary state (cooldowns, entry snapshots)
            newPairs[selected] = activePairs[old];
            carried = true;
            break;
           }
        }
      if(!carried)
        {
         // Fresh pair — initialize from scratch
         newPairs[selected].symbolA = sA;
         newPairs[selected].symbolB = sB;
         newPairs[selected].recoveryManagedOnly = false;
         newPairs[selected].score = 0.0;
         newPairs[selected].zScore = 0;
         newPairs[selected].entry_mm_08 = 0;
         newPairs[selected].entry_mm_minus18 = 0;
         newPairs[selected].entry_mm_minus28 = 0;
         newPairs[selected].entry_mm_88 = 0;
         newPairs[selected].entry_mm_plus18 = 0;
         newPairs[selected].entry_mm_plus28 = 0;
         newPairs[selected].lastBuySeqCloseTime = 0;
         newPairs[selected].lastSellSeqCloseTime = 0;
        }
      // Update fields that may change on rescan
      if(carried)
         newPairs[selected].recoveryManagedOnly = false;
      newPairs[selected].correlation = combos[i].r;
      newPairs[selected].score = combos[i].score;
      newPairs[selected].active = true;
      newPairs[selected].tradingEnabled = true;
      newPairs[selected].buySeqIdx = SeqIdx(selected, SIDE_BUY);
      newPairs[selected].sellSeqIdx = SeqIdx(selected, SIDE_SELL);
      selected++;

      if(EnableLogging)
         Print("[Scanner] Selected: ", sA, " vs ", sB,
               " r=", DoubleToString(combos[i].r, 4),
               " score=", DoubleToString(combos[i].score, 3),
               carried ? " (state preserved)" : " (new)");
     }

// Preserve existing pairs with open trades
   for(int old = 0; old < numActivePairs; old++)
     {
      if(!activePairs[old].active)
         continue;
      int bIdx = activePairs[old].buySeqIdx;
      int sIdx = activePairs[old].sellSeqIdx;
      bool hasOpenTrades = false;
      long bMagic = sequences[bIdx].magicNumber;
      long sMagic = sequences[sIdx].magicNumber;
      for(int pos = PositionsTotal() - 1; pos >= 0; pos--)
        {
         if(PositionGetTicket(pos) == 0)
            continue;
         long pm = PositionGetInteger(POSITION_MAGIC);
         if(pm == bMagic || pm == sMagic)
           {
            hasOpenTrades = true;
            break;
           }
        }

      // Check per-symbol news block...
      bool found = false;
      for(int n = 0; n < selected; n++)
        {
         if(newPairs[n].symbolA == activePairs[old].symbolA &&
            newPairs[n].symbolB == activePairs[old].symbolB)
           {
            found = true;
            break;
           }
        }
      if(!found && hasOpenTrades)
        {
         // Keep pair but disable new entries
         if(selected < MAX_PAIRS)
           {
            ArrayResize(newPairs, selected + 1);
            newPairs[selected] = activePairs[old];
            newPairs[selected].tradingEnabled = false;
            newPairs[selected].recoveryManagedOnly = false;
            newPairs[selected].buySeqIdx = SeqIdx(selected, SIDE_BUY);
            newPairs[selected].sellSeqIdx = SeqIdx(selected, SIDE_SELL);
            selected++;
            if(EnableLogging)
               Print("[Scanner] Keeping dropped pair with full context (no new starts): ",
                     activePairs[old].symbolA, " vs ", activePairs[old].symbolB);
           }
        }
     }

// Restart-safety: keep any symbol with EA-owned open positions under managed-only mode
   for(int pos = PositionsTotal() - 1; pos >= 0; pos--)
     {
      if(PositionGetTicket(pos) == 0)
         continue;
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(comment) || IsBreakoutPositionComment(comment))
         continue;

      bool foundSymbol = false;
      for(int n = 0; n < selected; n++)
        {
         if(newPairs[n].symbolA == posSymbol)
           {
            foundSymbol = true;
            break;
           }
        }
      if(foundSymbol || selected >= MAX_PAIRS)
         continue;

      ArrayResize(newPairs, selected + 1);
      newPairs[selected].symbolA = posSymbol;
      newPairs[selected].symbolB = posSymbol; // Placeholder for management-only recovery
      newPairs[selected].correlation = 0;
      newPairs[selected].score = 0.0;
      newPairs[selected].zScore = 0;
      newPairs[selected].active = true;
      newPairs[selected].tradingEnabled = false;
      newPairs[selected].recoveryManagedOnly = true;
      newPairs[selected].entry_mm_08 = 0;
      newPairs[selected].entry_mm_minus18 = 0;
      newPairs[selected].entry_mm_minus28 = 0;
      newPairs[selected].entry_mm_88 = 0;
      newPairs[selected].entry_mm_plus18 = 0;
      newPairs[selected].entry_mm_plus28 = 0;
      newPairs[selected].lastBuySeqCloseTime = 0;
      newPairs[selected].lastSellSeqCloseTime = 0;
      selected++;
      if(EnableLogging)
         Print("[Scanner] Recovery: added managed-only symbol ", posSymbol, " with open positions");
     }

// Apply new portfolio using temp buffer to prevent state corruption
   SequenceState tempSequences[MAX_PAIRS * 2];
// Initialize temp with clean defaults
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      tempSequences[i].magicNumber = 0;
      tempSequences[i].tradeCount = 0;
      tempSequences[i].plOpen = 0;
      tempSequences[i].plHigh = 0;
      tempSequences[i].avgPrice = 0;
      tempSequences[i].lockProfitExec = false;
      tempSequences[i].active = false;
      tempSequences[i].side = i % 2;
      tempSequences[i].seqId = i;
      tempSequences[i].firstOpenTime = 0;
      tempSequences[i].lastOpenTime = 0;
      tempSequences[i].tradeSymbol = "";
      tempSequences[i].strategyType = STRAT_MEAN_REVERSION;
      tempSequences[i].trailSL = 0;
      tempSequences[i].lpTriggerDist = 0;
      tempSequences[i].lpTrailDist = 0;
     }

   for(int i = 0; i < selected; i++)
     {
      int newBuyIdx = SeqIdx(i, SIDE_BUY);
      int newSellIdx = SeqIdx(i, SIDE_SELL);

      // Search for this pair in the OLD activePairs to preserve state & magic
      int oldBuyIdx = -1;
      int oldSellIdx = -1;
      for(int old = 0; old < numActivePairs; old++)
        {
         if(activePairs[old].symbolA == newPairs[i].symbolA &&
            activePairs[old].symbolB == newPairs[i].symbolB)
           {
            oldBuyIdx = activePairs[old].buySeqIdx;
            oldSellIdx = activePairs[old].sellSeqIdx;
            break;
           }
        }

      if(oldBuyIdx >= 0)
        {
         // EXISTING PAIR: Preserve state and magic number
         tempSequences[newBuyIdx] = sequences[oldBuyIdx];
         tempSequences[newSellIdx] = sequences[oldSellIdx];
         if(EnableLogging)
           {
            Print("[ScannerMap] Carry pair ", newPairs[i].symbolA, "/", newPairs[i].symbolB,
                  " -> buyMagic=", tempSequences[newBuyIdx].magicNumber,
                  " sellMagic=", tempSequences[newSellIdx].magicNumber);
           }
        }
      else
        {
          // NEW PAIR: recover only if symbol+side maps to a unique open magic.
          // If ambiguous, allocate a fresh magic to avoid binding to the wrong sequence.
          long recoveredBuyMagic = 0, recoveredSellMagic = 0;
          bool buyRecovered = TryDetectUniqueOpenSeqMagicForSymbolSide(newPairs[i].symbolA, POSITION_TYPE_BUY, recoveredBuyMagic);
          bool sellRecovered = TryDetectUniqueOpenSeqMagicForSymbolSide(newPairs[i].symbolA, POSITION_TYPE_SELL, recoveredSellMagic);
          if(newPairs[i].symbolB != newPairs[i].symbolA)
            {
             long buyMagicB = 0, sellMagicB = 0;
             bool buyRecoveredB = TryDetectUniqueOpenSeqMagicForSymbolSide(newPairs[i].symbolB, POSITION_TYPE_BUY, buyMagicB);
             bool sellRecoveredB = TryDetectUniqueOpenSeqMagicForSymbolSide(newPairs[i].symbolB, POSITION_TYPE_SELL, sellMagicB);
             if(!buyRecovered && buyRecoveredB)
               {
                recoveredBuyMagic = buyMagicB;
                buyRecovered = true;
               }
             if(!sellRecovered && sellRecoveredB)
               {
                recoveredSellMagic = sellMagicB;
                sellRecovered = true;
               }
            }

          // For counter-allocated (fresh) magics, skip any value currently used by an
          // open managed position so we never accidentally steal a position's magic number.
          if(buyRecovered && recoveredBuyMagic > 0)
             tempSequences[newBuyIdx].magicNumber = recoveredBuyMagic;
          else
             tempSequences[newBuyIdx].magicNumber = AllocateUnusedSequenceMagic();
          if(sellRecovered && recoveredSellMagic > 0)
             tempSequences[newSellIdx].magicNumber = recoveredSellMagic;
          else
             tempSequences[newSellIdx].magicNumber = AllocateUnusedSequenceMagic();
         if(EnableLogging)
           {
            Print("[ScannerMap] New pair ", newPairs[i].symbolA, "/", newPairs[i].symbolB,
                  " recovery=", (newPairs[i].recoveryManagedOnly ? "true" : "false"),
                  " -> buyMagic=", tempSequences[newBuyIdx].magicNumber,
                  " sellMagic=", tempSequences[newSellIdx].magicNumber);
           }
        }
      // Update internal indices
      tempSequences[newBuyIdx].pairIdx = i;
      tempSequences[newBuyIdx].seqId = newBuyIdx;
      tempSequences[newBuyIdx].side = SIDE_BUY;
      tempSequences[newBuyIdx].active = true;
      tempSequences[newSellIdx].pairIdx = i;
      tempSequences[newSellIdx].seqId = newSellIdx;
      tempSequences[newSellIdx].side = SIDE_SELL;
      tempSequences[newSellIdx].active = true;

      newPairs[i].buySeqIdx = newBuyIdx;
      newPairs[i].sellSeqIdx = newSellIdx;
     }

// Commit: overwrite from temp buffer
   numActivePairs = selected;
   for(int i = 0; i < selected; i++)
      activePairs[i] = newPairs[i];
   for(int i = 0; i < MAX_PAIRS * 2; i++)
      sequences[i] = tempSequences[i];

   lastScanTime = TimeCurrent();
   Print("[Scanner] Active portfolio: ", numActivePairs, " pairs mode=PearsonOnly");
  }

//+------------------------------------------------------------------+
//|  MURREY MATH: Port of f_calcMurreyCore from LVLS_Algo            |
//+------------------------------------------------------------------+
// CalcMurreyLevels is now in Sniper_Math.mqh

//+------------------------------------------------------------------+
//|  Z-SCORE CALCULATION                                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  POSITION SCANNING                                               |
//+------------------------------------------------------------------+
void ScanPositions()
  {
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      sequences[i].prevTradeCount = sequences[i].tradeCount;
      sequences[i].plPrev = sequences[i].plOpen;
      sequences[i].tradeCount = 0;
      sequences[i].plOpen = 0;
      sequences[i].totalLots = 0;
      sequences[i].priceLotSum = 0;
      sequences[i].lowestPrice = 0;
      sequences[i].highestPrice = 0;
     }
   for(int i = 0; i < MAX_SYMBOLS; i++)
     {
      breakoutPrevOpen[i] = breakoutOpen[i];
      breakoutPlPrev[i] = breakoutPlOpen[i];
      breakoutPrevSide[i] = breakoutSide[i];
      breakoutOpen[i] = false;
      breakoutPlOpen[i] = 0;
      breakoutSide[i] = -1;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string posComment = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(posComment))
         continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      double posProfit = PositionGetDouble(POSITION_PROFIT) +
                         PositionGetDouble(POSITION_SWAP) +
                         GetOpenPositionCommission(positionId);
      long posType = PositionGetInteger(POSITION_TYPE);

      if(IsBreakoutPositionComment(posComment))
        {
         int boIdx = FindBreakoutSymbolIndex(posSymbol);
         if(boIdx >= 0 && boIdx < MAX_SYMBOLS)
           {
            breakoutOpen[boIdx] = true;
            breakoutPlOpen[boIdx] += posProfit;
            breakoutSide[boIdx] = (posType == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
           }
         continue;
        }

      int seqIdx = -1;
      for(int p = 0; p < numActivePairs; p++)
        {
         if(magic == sequences[activePairs[p].buySeqIdx].magicNumber)
            seqIdx = activePairs[p].buySeqIdx;
         else
            if(magic == sequences[activePairs[p].sellSeqIdx].magicNumber)
               seqIdx = activePairs[p].sellSeqIdx;
         if(seqIdx >= 0)
            break;
        }
      if(seqIdx < 0)
        {
         for(int s = 0; s < MAX_PAIRS * 2; s++)
           {
            if(magic == sequences[s].magicNumber)
              {
               seqIdx = s;
               break;
              }
           }
        }
      if(seqIdx < 0)
        {
         if(EnableLogging)
            Print("[SCAN_MISS] No seq for magic=", magic, " sym=", posSymbol, " comment=", posComment);
         continue;
        }
      if(StringLen(sequences[seqIdx].tradeSymbol) == 0)
         sequences[seqIdx].tradeSymbol = posSymbol;

      double posLots = PositionGetDouble(POSITION_VOLUME);
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      sequences[seqIdx].tradeCount++;
      if(sequences[seqIdx].tradeCount == 1)
         sequences[seqIdx].side = (posType == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      sequences[seqIdx].totalLots += posLots;
      sequences[seqIdx].priceLotSum += posPrice * posLots;
      sequences[seqIdx].plOpen += posProfit;

      if(StringFind(posComment, "ZSM") == 0)
         sequences[seqIdx].strategyType = STRAT_MEAN_REVERSION;

      if(posType == POSITION_TYPE_BUY)
        {
         if(sequences[seqIdx].lowestPrice == 0 || posPrice < sequences[seqIdx].lowestPrice)
            sequences[seqIdx].lowestPrice = posPrice;
         if(sequences[seqIdx].highestPrice == 0 || posPrice > sequences[seqIdx].highestPrice)
            sequences[seqIdx].highestPrice = posPrice;
        }
      if(posType == POSITION_TYPE_SELL)
        {
         if(sequences[seqIdx].highestPrice == 0 || posPrice > sequences[seqIdx].highestPrice)
            sequences[seqIdx].highestPrice = posPrice;
         if(sequences[seqIdx].lowestPrice == 0 || posPrice < sequences[seqIdx].lowestPrice)
            sequences[seqIdx].lowestPrice = posPrice;
        }

     }

   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].totalLots > 0)
         sequences[i].avgPrice = sequences[i].priceLotSum / sequences[i].totalLots;
      else
         sequences[i].avgPrice = 0;
      if(sequences[i].tradeCount > 0 && StringLen(sequences[i].tradeSymbol) > 0)
         EnsureSequenceLockProfile(i, sequences[i].tradeSymbol);
      if(sequences[i].plOpen > sequences[i].plHigh)
         sequences[i].plHigh = sequences[i].plOpen;
      if(sequences[i].tradeCount == 0 && sequences[i].prevTradeCount > 0)
         OnSequenceClose(i);
     }

   for(int i = 0; i < numBreakoutSymbols && i < MAX_SYMBOLS; i++)
     {
      if(breakoutPrevOpen[i] && !breakoutOpen[i])
        {
         breakoutLastCloseProfit[i] = breakoutPlPrev[i];
         breakoutLastCloseTime[i] = CurTime;
         if(BreakoutCloseOppositeMRonProfit &&
            breakoutLastCloseProfit[i] > 0 &&
            (breakoutPrevSide[i] == SIDE_BUY || breakoutPrevSide[i] == SIDE_SELL))
           {
            breakoutCloseMrPending[i] = true;
            breakoutCloseMrSidePending[i] = breakoutPrevSide[i];
           }
        }
      if(!breakoutPrevOpen[i] && breakoutOpen[i])
         breakoutCloseMrPending[i] = false;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnSequenceClose(int seqIdx)
  {
   if(sequences[seqIdx].plPrev > 0)
     {
      sequenceCounterWinners++;
     }
   else
     {
      sequenceCounterLosers++;
     }
   sequenceCounter++;
   sequences[seqIdx].lockProfitExec = false;
   sequences[seqIdx].plHigh = 0;
   sequences[seqIdx].trailSL = 0;
   sequences[seqIdx].entryMmIncrement = 0;  // Reset frozen grid for next sequence
   sequences[seqIdx].firstOpenTime = 0;
   sequences[seqIdx].lastOpenTime = 0;
   sequences[seqIdx].tradeSymbol = "";
   ClearSequenceLockProfile(seqIdx);
  }

//+------------------------------------------------------------------+
//|  RECONSTRUCT: Rebuild frozen snapshots after restart/reshuffle   |
//+------------------------------------------------------------------+
void ReconstructSequenceMemory(int seqIdx, int pairIdx)
  {
   if(sequences[seqIdx].tradeCount <= 0)
      return;
   string seqSym = GetSequenceTradeSymbol(seqIdx, pairIdx);
   double mm88 = 0, mm48 = 0, mm08 = 0, mmInc = 0;
   double mmP28 = 0, mmP18 = 0, mmM18 = 0, mmM28 = 0;
   if(!CalcMurreyLevelsForSymbol(seqSym, mm88, mm48, mm08, mmInc, mmP28, mmP18, mmM18, mmM28))
      return;
   int side = sequences[seqIdx].side;
   if(side == SIDE_BUY)
     {
      if(activePairs[pairIdx].entry_mm_minus28 != 0 && sequences[seqIdx].entryMmIncrement > EPS)
         return;
      if(mm08 == 0 && mmM28 == 0)
         return;
      if(mmInc <= EPS)
         return;  // data not ready yet, skip until a valid increment is available
      activePairs[pairIdx].entry_mm_08 = mm08;
      activePairs[pairIdx].entry_mm_minus18 = mmM18;
      activePairs[pairIdx].entry_mm_minus28 = mmM28;
      if(sequences[seqIdx].entryMmIncrement <= EPS)
         sequences[seqIdx].entryMmIncrement = mmInc;
      if(EnableLogging)
         Print("[RECONSTRUCT] BUY ", seqSym,
               " mm08=", DoubleToString(activePairs[pairIdx].entry_mm_08, 5),
               " mm-2/8=", DoubleToString(activePairs[pairIdx].entry_mm_minus28, 5),
               " inc=", DoubleToString(sequences[seqIdx].entryMmIncrement, 5),
               " mmInc=", DoubleToString(mmInc, 5));
     }
   else
     {
      if(activePairs[pairIdx].entry_mm_plus28 != 0 && sequences[seqIdx].entryMmIncrement > EPS)
         return;
      if(mm88 == 0 && mmP28 == 0)
         return;
      if(mmInc <= EPS)
         return;  // data not ready yet, skip until a valid increment is available
      activePairs[pairIdx].entry_mm_88 = mm88;
      activePairs[pairIdx].entry_mm_plus18 = mmP18;
      activePairs[pairIdx].entry_mm_plus28 = mmP28;
      if(sequences[seqIdx].entryMmIncrement <= EPS)
         sequences[seqIdx].entryMmIncrement = mmInc;
      if(EnableLogging)
         Print("[RECONSTRUCT] SELL ", seqSym,
               " mm88=", DoubleToString(activePairs[pairIdx].entry_mm_88, 5),
               " mm+2/8=", DoubleToString(activePairs[pairIdx].entry_mm_plus28, 5),
               " inc=", DoubleToString(sequences[seqIdx].entryMmIncrement, 5),
               " mmInc=", DoubleToString(mmInc, 5));
     }
  }

//+------------------------------------------------------------------+
//|  OPEN ORDER                                                      |
//+------------------------------------------------------------------+
bool OpenOrderWithContext(int seqIdx, ENUM_ORDER_TYPE orderType, string symbol, ENUM_STRATEGY_TYPE strat)
  {
   pendingOrderStrategy = strat;
   pendingOrderSymbol = symbol;
   bool opened = OpenOrder(seqIdx, orderType, symbol, strat);
   pendingOrderSymbol = "";
   return opened;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  ASYNC CLOSING FUNCTIONS                                         |
//+------------------------------------------------------------------+
void AsyncCloseSequence(int seqIdx, string reason)
  {
   if(EnableLogging) Print("[ASYNC_CLOSE] Sequence ", seqIdx, " Reason: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != sequences[seqIdx].magicNumber) continue;
      
      MqlTradeRequest req = {};
      MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = PositionGetString(POSITION_SYMBOL);
      req.volume = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(req.symbol, (type == POSITION_TYPE_BUY) ? SYMBOL_BID : SYMBOL_ASK);
      req.deviation = 100;
      req.magic = magic;
      OrderSendAsync(req, res);
     }
   sequences[seqIdx].tradeCount = 0;
   sequences[seqIdx].plOpen = 0;
  }

void AsyncCloseAll(string reason)
  {
   if(EnableLogging) Print("[ASYNC_CLOSE_ALL] Reason: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      
      bool isOurs = false;
      for(int s=0; s<MAX_PAIRS*2; s++) {
         if(sequences[s].magicNumber == magic && sequences[s].active) {
            isOurs = true; break;
         }
      }
      if(!isOurs) continue;
      
      MqlTradeRequest req = {};
      MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = PositionGetString(POSITION_SYMBOL);
      req.volume = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(req.symbol, (type == POSITION_TYPE_BUY) ? SYMBOL_BID : SYMBOL_ASK);
      req.deviation = 100;
      req.magic = magic;
      OrderSendAsync(req, res);
     }
     
   for(int s=0; s<MAX_PAIRS*2; s++) {
      sequences[s].tradeCount = 0;
      sequences[s].plOpen = 0;
   }
  }

//+------------------------------------------------------------------+
//|  CLOSE SEQUENCE                                                  |
//+------------------------------------------------------------------+
void CloseSequencesByStrategy(const ENUM_STRATEGY_TYPE strat, const string reason)
  {
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].tradeCount <= 0)
         continue;
      if(sequences[i].strategyType != strat)
         continue;
      AsyncCloseSequence(i, reason);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  TRAILING / LOCK PROFIT (Murrey-level based)                     |
//+------------------------------------------------------------------+
void TrailingForSequence(int seqIdx, int pairIdx)
  {
   if(sequences[seqIdx].tradeCount == 0)
      return;

   long magic = sequences[seqIdx].magicNumber;
   string sym = GetSequenceTradeSymbol(seqIdx, pairIdx);
   if(StringLen(sym) == 0)
      sym = activePairs[pairIdx].symbolA;
   int side = sequences[seqIdx].side;

// MR/Trending trailing (shared lock-profit logic)
   if(sequences[seqIdx].strategyType == STRAT_MEAN_REVERSION ||
      sequences[seqIdx].strategyType == STRAT_TRENDING)
     {
      if(LockProfitMode == lpGlobal)
         return;
      bool isTrend = (sequences[seqIdx].strategyType == STRAT_TRENDING);
      int minTrades = isTrend ? TrendLockProfitMinTrades : LockProfitMinTrades;
      if(minTrades > 0 && sequences[seqIdx].tradeCount < minTrades)
         return;

      double avgP = sequences[seqIdx].avgPrice;
      if(avgP == 0)
         return;

      EnsureSequenceLockProfile(seqIdx, sym);
      double effLP = sequences[seqIdx].lpTriggerDist;
      if(effLP < 0)
         return;

      double effTSL = sequences[seqIdx].lpTrailDist;
      if(effTSL <= 0)
         return;

      double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
      double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);

      if(side == SIDE_BUY)
        {
         if(!sequences[seqIdx].lockProfitExec)
           {
            if(curBid >= avgP + effLP)
              {
               sequences[seqIdx].lockProfitExec = true;
               if(EnableLogging)
                  Print("[LockProfit] BUY activated for pair ", pairIdx);
              }
           }
         if(sequences[seqIdx].lockProfitExec)
           {
            double newSL = curBid - effTSL;
            double validSL = 0;
            if(!PrepareValidStopForModify(sym, SIDE_BUY, newSL, validSL))
               return;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
              {
               if(PositionGetTicket(i) == 0)
                  continue;
               if(PositionGetInteger(POSITION_MAGIC) != magic)
                  continue;
               if(PositionGetString(POSITION_SYMBOL) != sym)
                  continue;
               double curSL = PositionGetDouble(POSITION_SL);
               if(validSL > curSL || curSL == 0)
                 {
                  trade.SetExpertMagicNumber(magic);
                  trade.PositionModify(PositionGetInteger(POSITION_TICKET), validSL, PositionGetDouble(POSITION_TP));
                 }
              }
           }
        }
      else   // SELL
        {
         if(!sequences[seqIdx].lockProfitExec)
           {
            if(curAsk <= avgP - effLP)
              {
               sequences[seqIdx].lockProfitExec = true;
               if(EnableLogging)
                  Print("[LockProfit] SELL activated for pair ", pairIdx);
              }
           }
         if(sequences[seqIdx].lockProfitExec)
           {
            double newSL = curAsk + effTSL;
            double validSL = 0;
            if(!PrepareValidStopForModify(sym, SIDE_SELL, newSL, validSL))
               return;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
              {
               if(PositionGetTicket(i) == 0)
                  continue;
               if(PositionGetInteger(POSITION_MAGIC) != magic)
                  continue;
               if(PositionGetString(POSITION_SYMBOL) != sym)
                  continue;
               double curSL = PositionGetDouble(POSITION_SL);
               if(validSL < curSL || curSL == 0)
                 {
                  trade.SetExpertMagicNumber(magic);
                  trade.PositionModify(PositionGetInteger(POSITION_TICKET), validSL, PositionGetDouble(POSITION_TP));
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//|  CHECK STAGNATION HEDGE                                          |
//+------------------------------------------------------------------+
bool IsSequenceHedged(long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == magic &&
         StringFind(PositionGetString(POSITION_COMMENT), "ZSHEDGE") == 0)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SequenceGridAddsAllowed(int seqIdx)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   long magic = sequences[seqIdx].magicNumber;
   if(magic <= 0)
      return true;
   return !IsSequenceHedged(magic);
  }

void CheckStagnationHedge(int seqIdx)
  {
   if(StagnationHedgeDrawdownAmount <= 0 || sequences[seqIdx].tradeCount <= 0)
      return;
   // Hedge only when sequence drawdown breaches configured threshold.
   if(sequences[seqIdx].plOpen > -StagnationHedgeDrawdownAmount + EPS)
      return;
   // If lock-profit already engaged, let normal trailing manage the exit.
   if(sequences[seqIdx].lockProfitExec)
      return;
   long magic = sequences[seqIdx].magicNumber;
   if(IsSequenceHedged(magic))
      return; // Already hedged

   string sym = sequences[seqIdx].tradeSymbol;
   int side = sequences[seqIdx].side;
   int hedgeSide = (side == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
   int nTrades = sequences[seqIdx].tradeCount;
   double totalVol = sequences[seqIdx].totalLots;
   
   if(nTrades <= 0 || totalVol <= 0) return;

   double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double volMin =  SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double volMax =  SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(volStep <= 0 || volMin <= 0 || volMax <= 0)
     {
      if(EnableLogging)
         Print("[StagnationHedge] Invalid volume constraints on ", sym,
               " step=", DoubleToString(volStep, 6),
               " min=", DoubleToString(volMin, 6),
               " max=", DoubleToString(volMax, 6));
      return;
     }

   double exponent = GridIncrementExponent;
   if(exponent <= 0) exponent = 1.0;
   
   double sumRatios = 0;
   double ratios[];
   ArrayResize(ratios, nTrades);
   for(int i = 0; i < nTrades; i++)
     {
      ratios[i] = MathPow(exponent, i);
      sumRatios += ratios[i];
     }

   double lotsPlaced = 0;
   double hedgeLots[];
   ArrayResize(hedgeLots, nTrades);
   
   for(int i = 0; i < nTrades; i++)
     {
      double exactLot = (ratios[i] / sumRatios) * totalVol;
      double safeLot = MathRound(exactLot / volStep) * volStep;
      if(safeLot < volMin) safeLot = volMin;
      if(safeLot > volMax) safeLot = volMax;
      hedgeLots[i] = safeLot;
      lotsPlaced += safeLot;
     }

   double diff = totalVol - lotsPlaced;
   if(MathAbs(diff) > EPS)
     {
      int largestIdx = nTrades - 1;
      hedgeLots[largestIdx] += diff;
      hedgeLots[largestIdx] = MathRound(hedgeLots[largestIdx] / volStep) * volStep;
     }

   // Open the Hedge Trades
   for(int i = 0; i < nTrades; i++)
     {
      if(hedgeLots[i] >= volMin)
        {
         trade.SetExpertMagicNumber(magic);
         if(hedgeSide == SIDE_BUY)
            trade.Buy(hedgeLots[i], sym, SymbolInfoDouble(sym, SYMBOL_ASK), 0, 0, "ZSHEDGE");
         else
            trade.Sell(hedgeLots[i], sym, SymbolInfoDouble(sym, SYMBOL_BID), 0, 0, "ZSHEDGE");
         
         if(EnableLogging)
            Print("[StagnationHedge] Opened ", (hedgeSide == SIDE_BUY ? "BUY" : "SELL"), " ", DoubleToString(hedgeLots[i], 2), " on ", sym);
        }
     }
  }

//+------------------------------------------------------------------+
//|  ASYMMETRIC PAIR UNWINDING                                       |
//+------------------------------------------------------------------+
struct PosNode
  {
   ulong  ticket;
   double profit; 
  };

void SortPosNodesDesc(PosNode &arr[])
  {
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
     {
      for(int j = 0; j < n - i - 1; j++)
        {
         if(arr[j].profit < arr[j + 1].profit)
           {
            PosNode temp = arr[j];
            arr[j] = arr[j + 1];
            arr[j + 1] = temp;
           }
        }
     }
  }

void ProcessAsymmetricUnwinds()
  {
   for(int seqIdx = 0; seqIdx < MAX_PAIRS * 2; seqIdx++)
     {
      long magic = sequences[seqIdx].magicNumber;
      if(magic <= 0) continue;
      if(!IsSequenceHedged(magic)) continue;

      PosNode orig[], hedge[];
      int origC = 0, hedgeC = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

         double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + GetOpenPositionCommission(PositionGetInteger(POSITION_IDENTIFIER));
         string cmt = PositionGetString(POSITION_COMMENT);

         if(StringFind(cmt, "ZSHEDGE") == 0)
           {
            ArrayResize(hedge, hedgeC + 1);
            hedge[hedgeC].ticket = ticket;
            hedge[hedgeC].profit = pnl;
            hedgeC++;
           }
         else if(IsManagedPositionComment(cmt))
           {
            ArrayResize(orig, origC + 1);
            orig[origC].ticket = ticket;
            orig[origC].profit = pnl;
            origC++;
           }
        }

      if(hedgeC > 0)
        {
         // If hedge legs remain but original legs are gone, flush stale hedge basket.
         if(origC == 0)
           {
            for(int j = 0; j < hedgeC; j++)
               trade.PositionClose(hedge[j].ticket);
            if(EnableLogging)
               Print("[Unwind] Closed stale hedge-only basket magic=", magic, " legs=", hedgeC);
            continue;
           }

         double netAll = 0;
         for(int j = 0; j < origC; j++)
            netAll += orig[j].profit;
         for(int j = 0; j < hedgeC; j++)
            netAll += hedge[j].profit;
         double netThr = StagnationUnwindNetThreshold;
         // Hard basket release: if combined hedged basket reaches threshold, flush all legs.
         if(netAll >= netThr - EPS)
           {
            if(EnableLogging)
               Print("[Unwind] Net-positive hedge basket close magic=", magic,
                     " net=", DoubleToString(netAll, 2),
                     " thr=", DoubleToString(netThr, 2));
            AsyncCloseSequence(seqIdx, "Stagnation Hedge Net Basket Exit");
            continue;
           }

         SortPosNodesDesc(orig);
         SortPosNodesDesc(hedge);

         bool closedPair = false;
         if(hedge[0].profit > 0)
           {
            for(int j = 0; j < origC; j++)
              {
               if(orig[j].profit < 0 && hedge[0].profit + orig[j].profit >= netThr - EPS)
                 {
                  trade.PositionClose(hedge[0].ticket);
                  trade.PositionClose(orig[j].ticket);
                  closedPair = true;
                  if(EnableLogging) Print("[Unwind] Closed Hedge #", hedge[0].ticket, " vs Orig #", orig[j].ticket, " Net=", DoubleToString(hedge[0].profit + orig[j].profit, 2));
                  break;
                 }
              }
           }
         if(closedPair) continue; 

         if(orig[0].profit > 0)
           {
            for(int j = 0; j < hedgeC; j++)
              {
               if(hedge[j].profit < 0 && orig[0].profit + hedge[j].profit >= netThr - EPS)
                 {
                  trade.PositionClose(orig[0].ticket);
                  trade.PositionClose(hedge[j].ticket);
                  if(EnableLogging) Print("[Unwind] Closed Orig #", orig[0].ticket, " vs Hedge #", hedge[j].ticket, " Net=", DoubleToString(orig[0].profit + hedge[j].profit, 2));
                  break;
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//|  NEWS FUNCTIONS                                                  |
//+------------------------------------------------------------------+
string geturl(string url)
  {
   string cookie=NULL, headers;
   char post[], result[];
   readNewsPageFile();
   if(page == "")
     {
      int res = WebRequest("GET", url, cookie, NULL, 10000, post, 0, result, headers);
      if(GetLastError() == 4014)
        {
         Alert("Web request for NEWS not active. Add https://nfs.faireconomy.media");
         ExpertRemove();
        }
      page = CharArrayToString(result, 0, -1, CP_UTF8);
      writeNewsPageFile();
     }
   return page;
  }

string newsNameStr, newsCurrStr, newsDateStr, newsTimeStr, newsImpactStr;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int NthSundayOfMonth(int year, int month, int nth)
  {
   datetime firstDay = StringToTime(StringFormat("%04d.%02d.01", year, month));
   MqlDateTime firstStruct;
   TimeToStruct(firstDay, firstStruct);
   int firstSunday = 1 + ((7 - firstStruct.day_of_week) % 7);
   return firstSunday + (nth - 1) * 7;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime UsDstStart(int year)
  {
   int day = NthSundayOfMonth(year, 3, 2);
   return StringToTime(StringFormat("%04d.03.%02d", year, day));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime UsDstEnd(int year)
  {
   int day = NthSundayOfMonth(year, 11, 1);
   return StringToTime(StringFormat("%04d.11.%02d", year, day));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetTesterNewsOffsetHours(datetime dt)
  {
   MqlDateTime d;
   TimeToStruct(dt, d);
   datetime start = UsDstStart(d.year);
   datetime endd = UsDstEnd(d.year);
   if(dt >= start && dt < endd)
      return 3;
   return 2;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime formatFfNewsTime(string date, string time2)
  {
   datetime dt = StringToTime(StringSubstr(date,6,4)+"."+StringSubstr(date,0,2)+"."+StringSubstr(date,3,2));
   string t = time2;
   StringTrimLeft(t);
   StringTrimRight(t);
   string tLower = t;
   StringToLower(tLower);
   int colonPos = StringFind(tLower, ":");
   int h = 0, m = 0;
   if(colonPos >= 0)
     {
      h = (int)StringToInteger(StringSubstr(tLower, 0, colonPos));
      m = (int)StringToInteger(StringSubstr(tLower, colonPos+1, 2));
      if(h < 12 && StringFind(tLower, "pm") >= 0)
         h = h+12;
      if(h == 12 && StringFind(tLower, "am") >= 0)
         h = h-12;
     }
   if(IsTester)
      gmtOffsetHours = GetTesterNewsOffsetHours(dt);
   return(dt + h*3600 + m*60 + gmtOffsetHours*3600);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsAllDayNewsTimeString(string time2)
  {
   string t = time2;
   StringTrimLeft(t);
   StringTrimRight(t);
   StringToLower(t);
   if(StringLen(t) == 0)
      return false;
   if(StringFind(t, "all day") >= 0)
      return true;
   if(StringFind(t, "day") >= 0 && StringFind(t, ":") < 0)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void parseNews()
  {
   gmtOffsetHours = (int)MathRound((TimeCurrent() - TimeGMT())/3600.0);
   int pos1=0, pos2=0, s=0;
   ArrayResize(newsName, 0, 200);
   ArrayResize(newsCurr, 0, 200);
   ArrayResize(newsTime, 0, 200);
   ArrayResize(newsImpact, 0, 200);
   ArrayResize(newsAllDay, 0, 200);
   datetime newsTimeDt;
   for(int i=0; i<=1000; i++)
     {
      pos1 = StringFind(page, "<title>", pos2);
      if(pos1<0)
         break;
      pos2 = StringFind(page, "</title>", pos1);
      if(pos2 < 0)
         break;
      newsNameStr = StringSubstr(page, pos1+7, pos2-pos1-7);
      pos1 = StringFind(page, "<country>", pos2);
      if(pos1 < 0)
         break;
      pos2 = StringFind(page, "</country>", pos1);
      if(pos2 < 0)
         break;
      newsCurrStr = StringSubstr(page, pos1+9, pos2-pos1-9);
      pos1 = StringFind(page, "<date><![CDATA[", pos2);
      if(pos1 < 0)
         break;
      pos2 = StringFind(page, "]]></date>", pos1);
      if(pos2 < 0)
         break;
      newsDateStr = StringSubstr(page, pos1+15, pos2-pos1-15);
      pos1 = StringFind(page, "<time><![CDATA[", pos2);
      if(pos1 < 0)
         break;
      pos2 = StringFind(page, "]]></time>", pos1);
      if(pos2 < 0)
         break;
      newsTimeStr = StringSubstr(page, pos1+15, pos2-pos1-15);
      pos1 = StringFind(page, "<impact><![CDATA[", pos2);
      if(pos1 < 0)
         break;
      pos2 = StringFind(page, "]]></impact>", pos1);
      if(pos2 < 0)
         break;
      newsImpactStr = StringSubstr(page, pos1+17, pos2-pos1-17);
      if(newsImpactStr != "High")
         continue;
      // Multi-currency: check if news affects any active pair
      bool affects = false;
      for(int p=0; p<numActivePairs; p++)
        {
         if(StringFind(activePairs[p].symbolA, newsCurrStr) >= 0 ||
            StringFind(activePairs[p].symbolB, newsCurrStr) >= 0 ||
            newsCurrStr == "All" || (UsdAffectsAllPairs && newsCurrStr == "USD"))
           { affects = true; break; }
        }
      if(!affects)
         continue;
      bool isAllDay = IsAllDayNewsTimeString(newsTimeStr);
      newsTimeDt = formatFfNewsTime(newsDateStr, newsTimeStr);
      if(TimeToString(newsTimeDt, TIME_DATE) != TimeToString(TimeCurrent(), TIME_DATE) &&
         TimeToString(newsTimeDt, TIME_DATE) != TimeToString(TimeCurrent()+24*3600, TIME_DATE))
         continue;
      ArrayResize(newsName, s+1, 200);
      ArrayResize(newsCurr, s+1, 200);
      ArrayResize(newsTime, s+1, 200);
      ArrayResize(newsImpact, s+1, 200);
      ArrayResize(newsAllDay, s+1, 200);
      newsName[s] = newsNameStr;
      newsCurr[s] = newsCurrStr;
      newsTime[s] = newsTimeDt;
      newsImpact[s] = newsImpactStr;
      newsAllDay[s] = isAllDay;
      s++;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void readHistoricalNews()
  {
   ArrayResize(newsName, 0, 1000);
   ArrayResize(newsCurr, 0, 1000);
   ArrayResize(newsTime, 0, 1000);
   ArrayResize(newsAllDay, 0, 1000);
   int s=0;
   for(int i=0; i<ArraySize(newsNameArr); i++)
     {
      // Multi-currency: include all high-impact news
      bool affects = false;
      for(int p=0; p<numActivePairs; p++)
        {
         if(StringFind(activePairs[p].symbolA, newsCurrArr[i]) >= 0 ||
            StringFind(activePairs[p].symbolB, newsCurrArr[i]) >= 0 ||
            newsCurrArr[i] == "All" || (UsdAffectsAllPairs && newsCurrArr[i] == "USD"))
           { affects = true; break; }
        }
      // If no pairs yet, include USD/EUR/GBP/JPY news
      if(numActivePairs == 0)
        {
         if(newsCurrArr[i] == "USD" || newsCurrArr[i] == "EUR" || newsCurrArr[i] == "GBP" ||
            newsCurrArr[i] == "All")
            affects = true;
        }
      if(!affects)
         continue;

      ArrayResize(newsName, s+1, 1000);
      ArrayResize(newsCurr, s+1, 1000);
      ArrayResize(newsTime, s+1, 1000);
      ArrayResize(newsAllDay, s+1, 1000);
      datetime dt = newsTimeArr[i];
      gmtOffsetHours = GetTesterNewsOffsetHours(dt);
      newsName[s] = newsNameArr[i];
      newsCurr[s] = newsCurrArr[i];
      newsTime[s] = newsTimeArr[i] + gmtOffsetHours*3600;
      newsAllDay[s] = false;
      s++;
     }
  }

void downLoadNewsFile()
  {
   if(!IsTester && (TimeCurrent() >= lastNewsDownloadTime + 5*3600 ||
                    TimeToString(TimeCurrent(), TIME_DATE) != TimeToString(lastNewsDownloadTime, TIME_DATE)))
     {
      lastNewsDownloadTime = TimeCurrent();
      geturl("https://nfs.faireconomy.media/ff_calendar_thisweek.xml");
      parseNews();
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool isThereBlockingNews()
  {
   blockingNewsNoTransactions = false;
   for(int i=0; i<ArraySize(arrBlockingAllDayStart); i++)
     {
      if(TimeCurrent() >= arrBlockingAllDayStart[i] &&
         TimeCurrent() < arrBlockingAllDayEnd[i])
        {
         if(arrBlockingAllDayNoTx[i])
            blockingNewsNoTransactions = true;
         return NewsInvert ? false : true;
        }
     }
   for(int i=0; i<ArraySize(arrBlockingNews); i++)
     {
      if(TimeCurrent() >= arrBlockingNews[i] - HoursBeforeNewsToStop*3600 &&
         TimeCurrent() < arrBlockingNews[i] + HoursAfterNewsToStart*3600)
        {
         // Check no-transactions window for THIS matching event
         if(UseHighImpactNewsFilter &&
            (MinutesBeforeNewsNoTransactions != 0 || MinutesAfterNewsNoTransactions != 0))
           {
            if(TimeCurrent() >= arrBlockingNews[i] - (MinutesBeforeNewsNoTransactions+1)*60 &&
               TimeCurrent() < arrBlockingNews[i] + MinutesAfterNewsNoTransactions*60)
               blockingNewsNoTransactions = true;
           }
         return NewsInvert ? false : true;
        }
     }
   return NewsInvert ? true : false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void populateBlockingNews()
  {
   ArrayResize(arrBlockingNews, 0, 20);
   ArrayResize(arrBlockingAllDayStart, 0, 20);
   ArrayResize(arrBlockingAllDayEnd, 0, 20);
   ArrayResize(arrBlockingAllDayNoTx, 0, 20);
   int s=0, sAllDay=0;
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   for(int i=0; i<ArraySize(newsName); i++)
     {
      if(i >= ArraySize(newsAllDay))
         continue;
      if(newsAllDay[i])
        {
         datetime dayStart = StringToTime(TimeToString(newsTime[i], TIME_DATE));
         datetime blockStart = dayStart - HoursBeforeNewsToStop*3600;
         datetime blockEnd = dayStart + 24*3600 + HoursAfterNewsToStart*3600;
         if(blockEnd < today - HoursAfterNewsToStart*3600 ||
            blockStart > today + (24+HoursBeforeNewsToStop)*3600)
            continue;
         ArrayResize(arrBlockingAllDayStart, sAllDay+1, 20);
         ArrayResize(arrBlockingAllDayEnd, sAllDay+1, 20);
         ArrayResize(arrBlockingAllDayNoTx, sAllDay+1, 20);
         arrBlockingAllDayStart[sAllDay] = blockStart;
         arrBlockingAllDayEnd[sAllDay] = blockEnd;
         arrBlockingAllDayNoTx[sAllDay] = (UseHighImpactNewsFilter &&
                                           (MinutesBeforeNewsNoTransactions != 0 || MinutesAfterNewsNoTransactions != 0));
         sAllDay++;
         continue;
        }
      if(newsTime[i] >= today - HoursAfterNewsToStart*3600 &&
         newsTime[i] <= today + (24+HoursBeforeNewsToStop)*3600)
        {
         ArrayResize(arrBlockingNews, s+1, 20);
         arrBlockingNews[s] = newsTime[i];
         s++;
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void readNewsPageFile()
  {
   datetime modifiedDate = (datetime)FileGetInteger("News.txt", FILE_MODIFY_DATE, true);
   datetime today = StringToTime(TimeToString(TimeLocal(), TIME_DATE));
   page = "";
   if(modifiedDate >= today)
     {
      int h = FileOpen("News.txt", FILE_READ|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
      if(h == INVALID_HANDLE)
         return;
      while(!FileIsEnding(h))
        {
         string str = FileReadString(h);
         page = page + str;
        }
      FileClose(h);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void writeNewsPageFile()
  {
   int h = FileOpen("News.txt", FILE_READ|FILE_WRITE|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWrite(h, page);
   FileFlush(h);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//|  STOP / RESTART CHECKS                                           |
//+------------------------------------------------------------------+
void ScheduleRestartAfterLoss()
  {
   restartTime = 0;
   time_wait_restart = false;
   if(RestartEaAfterLoss == restartOff)
      return;

   if(RestartEaAfterLoss == restartNextDay)
     {
      datetime nextDay = CurTime + 24 * 3600;
      restartTime = StringToTime(TimeToString(nextDay, TIME_DATE) + " " + TimeOfRestart_Equity);
      time_wait_restart = true;
      return;
     }

   if(RestartEaAfterLoss == restartInHours)
     {
      int hrs = RestartInHours;
      if(hrs <= 0)
         hrs = 1;
      restartTime = CurTime + hrs * 3600;
      time_wait_restart = true;
      return;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CheckStopOfEA()
  {
   if(!hard_stop)
      return false;

   if(restartTime > 0 && TimeCurrent() >= restartTime)
     {
      hard_stop = false;
      stopReason = "";
      restartTime = 0;
      time_wait_restart = false;
      maxDailyWinnersLosersHit = false;
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsOurDeal(ulong dealTicket)
  {
   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   if(IsManagedPositionComment(comment))
      return true;
   if(magic == baseMagicNumber)
      return true;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].magicNumber > 0 && magic == sequences[i].magicNumber)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double getPlClosedToday()
  {
// Cache check: if not dirty and update time matches current time (to handle same-tick calls), return cached
// For better safety, we rely on plDirty flag set by OnTradeTransaction
   if(!plDirty && lastPlUpdate == TimeCurrent())
      return cachedPlToday;

   double pl = 0;
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(HistorySelect(today, TimeCurrent()))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT)
            continue;
         if(!IsOurDeal(ticket))
            continue;
         pl += HistoryDealGetDouble(ticket, DEAL_PROFIT) +
               HistoryDealGetDouble(ticket, DEAL_SWAP) +
               HistoryDealGetDouble(ticket, DEAL_COMMISSION);
        }
     }
   cachedPlToday = pl;
   plDirty = false;
   lastPlUpdate = TimeCurrent();
   return pl;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
// Invalidate P/L cache on any deal addition (close/partial close)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      plDirty = true;
     }
  }

//+------------------------------------------------------------------+
//|  DASHBOARD                                                       |
//+------------------------------------------------------------------+
void ApplyVisualTheme()
  {
   color bg = ThemeChartBackground();
   color fg = ThemeChartForeground();
   color outline = (VisualTheme == themeLight) ? C'78,78,78' : C'192,192,192';
   color bullFill = ThemeBullCandle();
   color bearFill = ThemeBearCandle();
   color grid = (VisualTheme == themeLight) ? C'214,217,224' : C'58,64,76';

   ChartSetInteger(0, CHART_COLOR_BACKGROUND, bg);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, fg);
   ChartSetInteger(0, CHART_COLOR_GRID, grid);
    ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, bullFill);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, bearFill);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, outline);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, outline);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, fg);
   ChartSetInteger(0, CHART_COLOR_BID, fg);
   ChartSetInteger(0, CHART_COLOR_ASK, fg);
   ChartSetInteger(0, CHART_COLOR_LAST, fg);
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, C'128,132,140');
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
color ThemeChartBackground()
  {
   return (VisualTheme == themeLight) ? clrWhite : clrBlack;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
color ThemeChartForeground()
  {
   return (VisualTheme == themeLight) ? C'26,26,26' : C'232,232,232';
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
color ThemeBullCandle()
  {
   // Bull: hollow in dark mode (black body), hollow in light mode (white body).
   return (VisualTheme == themeLight) ? clrWhite : clrBlack;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
color ThemeBearCandle()
  {
   // Bear: filled with outline color family.
   return (VisualTheme == themeLight) ? C'78,78,78' : C'192,192,192';
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SymbolsEqual(string a, string b)
  {
   string aa = a;
   string bb = b;
   StringToUpper(aa);
   StringToUpper(bb);
   return aa == bb;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string KeyToken(string s)
  {
   string t = s;
   StringToUpper(t);
   StringReplace(t, ".", "_");
   StringReplace(t, "#", "_");
   StringReplace(t, " ", "_");
   StringReplace(t, "-", "_");
   return t;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string LpTrigKeyLegacy(long magic)  { return EAName + "_LP_TRG_" + IntegerToString((int)magic); }
string LpTrailKeyLegacy(long magic) { return EAName + "_LP_TRL_" + IntegerToString((int)magic); }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string LpTrigKey(long magic, int side, string symbol)
  {
   return EAName + "_LP_TRG_" + IntegerToString((int)magic) + "_" +
          IntegerToString(side) + "_" + KeyToken(symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string LpTrailKey(long magic, int side, string symbol)
  {
   return EAName + "_LP_TRL_" + IntegerToString((int)magic) + "_" +
          IntegerToString(side) + "_" + KeyToken(symbol);
  }

string LastDeinitReasonKey()
  {
   return EAName + "_LAST_DEINIT_" + DoubleToString((double)ChartID(), 0);
  }

void SaveLastDeinitReason(const int reason)
  {
   GlobalVariableSet(LastDeinitReasonKey(), (double)reason);
  }

int ConsumeLastDeinitReason()
  {
   string key = LastDeinitReasonKey();
   if(!GlobalVariableCheck(key))
      return -1;
   int reason = (int)GlobalVariableGet(key);
   GlobalVariableDel(key);
   return reason;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ClearSequenceLockProfile(int seqIdx)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   string sym = sequences[seqIdx].tradeSymbol;
   int side = sequences[seqIdx].side;
   if(StringLen(sym) > 0)
     {
      GlobalVariableDel(LpTrigKey(sequences[seqIdx].magicNumber, side, sym));
      GlobalVariableDel(LpTrailKey(sequences[seqIdx].magicNumber, side, sym));
     }
   // Legacy cleanup
   GlobalVariableDel(LpTrigKeyLegacy(sequences[seqIdx].magicNumber));
   GlobalVariableDel(LpTrailKeyLegacy(sequences[seqIdx].magicNumber));
   sequences[seqIdx].lpTriggerDist = 0;
   sequences[seqIdx].lpTrailDist = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool LoadSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   int side = sequences[seqIdx].side;
   string kTrig = LpTrigKey(sequences[seqIdx].magicNumber, side, symbol);
   string kTrail = LpTrailKey(sequences[seqIdx].magicNumber, side, symbol);
   bool hasTrig = GlobalVariableCheck(kTrig);
   bool hasTrail = GlobalVariableCheck(kTrail);

   if(hasTrig || hasTrail)
     {
      sequences[seqIdx].lpTriggerDist = hasTrig ? GlobalVariableGet(kTrig) : 0;
      sequences[seqIdx].lpTrailDist = hasTrail ? GlobalVariableGet(kTrail) : 0;
      return true;
     }

   // Legacy fallback (older builds keyed only by magic)
   string kTrigOld = LpTrigKeyLegacy(sequences[seqIdx].magicNumber);
   string kTrailOld = LpTrailKeyLegacy(sequences[seqIdx].magicNumber);
   bool hasTrigOld = GlobalVariableCheck(kTrigOld);
   bool hasTrailOld = GlobalVariableCheck(kTrailOld);
   if(!hasTrigOld && !hasTrailOld)
      return false;
   sequences[seqIdx].lpTriggerDist = hasTrigOld ? GlobalVariableGet(kTrigOld) : 0;
   sequences[seqIdx].lpTrailDist = hasTrailOld ? GlobalVariableGet(kTrailOld) : 0;
   // Migrate forward to symbol/side-specific keys.
   GlobalVariableSet(kTrig, sequences[seqIdx].lpTriggerDist);
   GlobalVariableSet(kTrail, sequences[seqIdx].lpTrailDist);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SaveSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   int side = sequences[seqIdx].side;
   GlobalVariableSet(LpTrigKey(sequences[seqIdx].magicNumber, side, symbol), sequences[seqIdx].lpTriggerDist);
   GlobalVariableSet(LpTrailKey(sequences[seqIdx].magicNumber, side, symbol), sequences[seqIdx].lpTrailDist);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildAndStoreSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   if(StringLen(symbol) == 0)
      return;
   double pVal = SymbolPipValue(symbol);
   if(pVal <= 0)
      return;

   bool isTrend = (sequences[seqIdx].strategyType == STRAT_TRENDING);
   double trigInput = isTrend ? TrendLockProfitTriggerPips : LockProfitTriggerPips;
   double trailInput = isTrend ? TrendTrailingStop : TrailingStop;
   ENUM_STRATEGY_TYPE strat = isTrend ? STRAT_TRENDING : STRAT_MEAN_REVERSION;
   double trigDist = ResolvePipsOrRangeForStrategy(trigInput, symbol, strat) * pVal;
   double trailDist = ResolvePipsOrRangeForStrategy(trailInput, symbol, strat) * pVal;

   if(trigDist < 0)
      trigDist = 0;
   if(trailDist < 0)
      trailDist = 0;

   sequences[seqIdx].lpTriggerDist = trigDist;
   sequences[seqIdx].lpTrailDist = trailDist;
   SaveSequenceLockProfile(seqIdx, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void EnsureSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   if(sequences[seqIdx].tradeCount <= 0)
      return;
   if(sequences[seqIdx].lpTriggerDist > 0 || sequences[seqIdx].lpTrailDist > 0)
      return;
   if(LoadSequenceLockProfile(seqIdx, symbol))
      return;
   BuildAndStoreSequenceLockProfile(seqIdx, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindInputSymbolIndex(string symbol)
  {
   for(int i = 0; i < numSymbols; i++)
     {
      if(SymbolsEqual(allSymbols[i], symbol))
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindSequenceByMagic(long magic)
  {
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].magicNumber == magic)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SequenceHasLiveManagedPositions(int seqIdx, string symbol = "")
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   long magic = sequences[seqIdx].magicNumber;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      if(StringLen(symbol) > 0 && !SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountOpenMrSequences()
  {
   int cnt = 0;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(sequences[i].tradeCount > 0 || SequenceHasLiveManagedPositions(i))
         cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasManagedPositionsOnSymbol(string symbol, bool &hasBuy, bool &hasSell)
  {
   hasBuy = false;
   hasSell = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long posType = PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
         hasBuy = true;
      else
         if(posType == POSITION_TYPE_SELL)
            hasSell = true;
      if(hasBuy && hasSell)
         return true;
     }
   return hasBuy || hasSell;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildSymbolOpenStats(double &symPl[], double &symPips[], int &symPosCount[],
                          int &symBuyCount[], int &symSellCount[], double &symLots[])
  {
   ArrayResize(symPl, numSymbols);
   ArrayResize(symPips, numSymbols);
   ArrayResize(symPosCount, numSymbols);
   ArrayResize(symBuyCount, numSymbols);
   ArrayResize(symSellCount, numSymbols);
   ArrayResize(symLots, numSymbols);
   double symPipLotSum[];
   ArrayResize(symPipLotSum, numSymbols);

   for(int i = 0; i < numSymbols; i++)
     {
      symPl[i] = 0;
      symPips[i] = 0;
      symPosCount[i] = 0;
      symBuyCount[i] = 0;
      symSellCount[i] = 0;
      symLots[i] = 0;
      symPipLotSum[i] = 0;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      int idx = FindInputSymbolIndex(posSymbol);
      if(idx < 0)
         continue;

      string posComment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(posComment) && !IsHedgePositionComment(posComment))
         continue;

      double lots = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      long posType = PositionGetInteger(POSITION_TYPE);
      double posProfit = PositionGetDouble(POSITION_PROFIT) +
                         PositionGetDouble(POSITION_SWAP) +
                         GetOpenPositionCommission(positionId);

      double pipValue = SymbolPipValue(posSymbol);
      double curPrice = (posType == POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(posSymbol, SYMBOL_BID) :
                        SymbolInfoDouble(posSymbol, SYMBOL_ASK);
      double posPips = 0;
      if(pipValue > 0)
        {
         if(posType == POSITION_TYPE_BUY)
            posPips = (curPrice - openPrice) / pipValue;
         else
            posPips = (openPrice - curPrice) / pipValue;
        }

      symPl[idx] += posProfit;
      symPosCount[idx]++;
      if(posType == POSITION_TYPE_BUY)
         symBuyCount[idx]++;
      else
         if(posType == POSITION_TYPE_SELL)
            symSellCount[idx]++;
      symLots[idx] += lots;
      symPipLotSum[idx] += posPips * lots;
     }

   for(int i = 0; i < numSymbols; i++)
     {
     if(symLots[i] > 0)
        symPips[i] = symPipLotSum[i] / symLots[i];
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildSymbolSideOpenStats(double &buyPl[], double &sellPl[], double &buyLots[], double &sellLots[],
                              int &buyPosCount[], int &sellPosCount[])
  {
   ArrayResize(buyPl, numSymbols);
   ArrayResize(sellPl, numSymbols);
   ArrayResize(buyLots, numSymbols);
   ArrayResize(sellLots, numSymbols);
   ArrayResize(buyPosCount, numSymbols);
   ArrayResize(sellPosCount, numSymbols);
   for(int i = 0; i < numSymbols; i++)
     {
      buyPl[i] = 0;
      sellPl[i] = 0;
      buyLots[i] = 0;
      sellLots[i] = 0;
      buyPosCount[i] = 0;
      sellPosCount[i] = 0;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      int idx = FindInputSymbolIndex(posSymbol);
      if(idx < 0)
         continue;

      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      double posProfit = PositionGetDouble(POSITION_PROFIT) +
                         PositionGetDouble(POSITION_SWAP) +
                         GetOpenPositionCommission(positionId);
      double lots = PositionGetDouble(POSITION_VOLUME);
      long posType = PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
        {
         buyPl[idx] += posProfit;
         buyLots[idx] += lots;
         buyPosCount[idx]++;
        }
      else
         if(posType == POSITION_TYPE_SELL)
           {
            sellPl[idx] += posProfit;
            sellLots[idx] += lots;
            sellPosCount[idx]++;
           }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetSequenceLiveStopPrice(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return 0;
   if(!SequenceHasLiveManagedPositions(seqIdx, symbol) && sequences[seqIdx].tradeCount <= 0)
      return 0;

   if(StringLen(symbol) == 0)
      return 0;

   long magic = sequences[seqIdx].magicNumber;
   int side = sequences[seqIdx].side;
   double best = 0;
   bool found = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0)
         continue;

      if(!found)
        {
         best = sl;
         found = true;
        }
      else
        {
         // Tightest lock level by side.
         if(side == SIDE_BUY && sl > best)
            best = sl;
         if(side == SIDE_SELL && sl < best)
            best = sl;
        }
     }
   return found ? best : 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetSequenceAvgPriceFallback(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2 || StringLen(symbol) == 0)
      return 0;
   long magic = sequences[seqIdx].magicNumber;
   double volSum = 0;
   double pxVolSum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double px = PositionGetDouble(POSITION_PRICE_OPEN);
      volSum += vol;
      pxVolSum += px * vol;
     }
   if(volSum <= 0)
      return 0;
   return pxVolSum / volSum;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetSequenceLockArmPrice(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return 0;
   if(!SequenceHasLiveManagedPositions(seqIdx, symbol) && sequences[seqIdx].tradeCount <= 0)
      return 0;

   if(StringLen(symbol) == 0)
      return 0;
   double avgP = sequences[seqIdx].avgPrice;
   if(avgP <= 0)
      avgP = GetSequenceAvgPriceFallback(seqIdx, symbol);
   if(avgP <= 0)
      return 0;
   int side = sequences[seqIdx].side;
   if(sequences[seqIdx].lpTriggerDist <= 0 && sequences[seqIdx].lpTrailDist <= 0)
     {
      if(!LoadSequenceLockProfile(seqIdx, symbol))
         BuildAndStoreSequenceLockProfile(seqIdx, symbol);
     }
   double triggerDist = sequences[seqIdx].lpTriggerDist;
   if(triggerDist <= 0)
      return avgP;
   return (side == SIDE_BUY) ? (avgP + triggerDist) : (avgP - triggerDist);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildSymbolLockLevels(double &buyLock[], bool &buyLockActive[], double &buyArm[],
                           double &sellLock[], bool &sellLockActive[], double &sellArm[])
  {
   ArrayResize(buyLock, numSymbols);
   ArrayResize(buyLockActive, numSymbols);
   ArrayResize(buyArm, numSymbols);
   ArrayResize(sellLock, numSymbols);
   ArrayResize(sellLockActive, numSymbols);
   ArrayResize(sellArm, numSymbols);

   for(int i = 0; i < numSymbols; i++)
     {
      buyLock[i] = 0;
      buyLockActive[i] = false;
      buyArm[i] = 0;
      sellLock[i] = 0;
      sellLockActive[i] = false;
      sellArm[i] = 0;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      int sIdxInput = FindInputSymbolIndex(symbol);
      if(sIdxInput < 0)
         continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int seqIdx = FindSequenceByMagic(magic);
      if(seqIdx < 0 )
         continue;

      int side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      double armPrice = GetSequenceLockArmPrice(seqIdx, symbol);
      double liveStop = GetSequenceLiveStopPrice(seqIdx, symbol);
      bool active = (liveStop > 0);

      if(side == SIDE_BUY)
        {
         if(active)
           {
            if(!buyLockActive[sIdxInput] || liveStop > buyLock[sIdxInput])
               buyLock[sIdxInput] = liveStop;
            buyLockActive[sIdxInput] = true;
           }
         if(armPrice > 0 && (buyArm[sIdxInput] == 0 || armPrice < buyArm[sIdxInput]))
            buyArm[sIdxInput] = armPrice;
        }
      else
        {
         if(active)
           {
            if(!sellLockActive[sIdxInput] || liveStop < sellLock[sIdxInput])
               sellLock[sIdxInput] = liveStop;
            sellLockActive[sIdxInput] = true;
           }
         if(armPrice > 0 && (sellArm[sIdxInput] == 0 || armPrice > sellArm[sIdxInput]))
            sellArm[sIdxInput] = armPrice;
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenSequenceForSymbolSide(string symbol, int side)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long posType = PositionGetInteger(POSITION_TYPE);
      if(side == SIDE_BUY && posType == POSITION_TYPE_BUY)
         return true;
      if(side == SIDE_SELL && posType == POSITION_TYPE_SELL)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindStartSequenceForSymbolSide(string symbol, int side)
  {
   for(int p = 0; p < numActivePairs; p++)
     {
      bool inPair = (activePairs[p].symbolA == symbol || activePairs[p].symbolB == symbol);
      if(!inPair)
         continue;
      int seqIdx = (side == SIDE_BUY) ? activePairs[p].buySeqIdx : activePairs[p].sellSeqIdx;
      if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
         continue;
      if(SequenceHasLiveManagedPositions(seqIdx))
         continue;
      return seqIdx;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CloseAllSequencesForSymbolSide(string symbol, int side, string reason)
  {
   bool closedAny = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(!IsMrPositionComment(PositionGetString(POSITION_COMMENT)))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long posType = PositionGetInteger(POSITION_TYPE);
      if(side == SIDE_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(side == SIDE_SELL && posType != POSITION_TYPE_SELL)
         continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(TryClosePositionWithRetry(ticket))
         closedAny = true;
      else
         if(EnableLogging)
            Print("[Close] Failed to close ticket ", (long)ticket, " by symbol-side close. ",
                  symbol, " ", (side == SIDE_BUY ? "BUY" : "SELL"), " reason=", reason);
     }
   if(closedAny && EnableLogging)
      Print("[Close] Symbol-side close executed: ", symbol, " ", (side == SIDE_BUY ? "BUY" : "SELL"),
            " reason=", reason);
   return closedAny;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CloseMeanReversionBySymbolSide(string symbol, int side, string reason)
  {
   bool closedAny = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long posType = PositionGetInteger(POSITION_TYPE);
      if(side == SIDE_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(side == SIDE_SELL && posType != POSITION_TYPE_SELL)
         continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(TryClosePositionWithRetry(ticket))
         closedAny = true;
      else
         if(EnableLogging)
            Print("[Close] Failed MR symbol-side close ticket ", (long)ticket,
                  " reason=", reason);
     }
   return closedAny;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpposingMeanReversionDrawdown(string symbol, int breakoutTradeSide)
  {
   int mrSide = (breakoutTradeSide == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
   int count = 0;
   double pl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), symbol))
         continue;
      long posType = PositionGetInteger(POSITION_TYPE);
      int side = (posType == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      if(side != mrSide)
         continue;
      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      pl += PositionGetDouble(POSITION_PROFIT) +
            PositionGetDouble(POSITION_SWAP) +
            GetOpenPositionCommission(positionId);
      count++;
     }
   return (count > 0 && pl < 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CurrencyExposureDirsForTrade(string symbol, int side, string &baseCcy, int &baseDir, string &quoteCcy, int &quoteDir)
  {
   baseCcy = GetBaseCurrency(symbol);
   quoteCcy = GetQuoteCurrency(symbol);
   baseDir = (side == SIDE_BUY) ? 1 : -1;
   quoteDir = (side == SIDE_BUY) ? -1 : 1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpposingMeanReversionDrawdownByCurrency(string breakoutSymbol, int breakoutTradeSide)
  {
   string boBase = "", boQuote = "";
   int boBaseDir = 0, boQuoteDir = 0;
   CurrencyExposureDirsForTrade(breakoutSymbol, breakoutTradeSide, boBase, boBaseDir, boQuote, boQuoteDir);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;

      long positionId = PositionGetInteger(POSITION_IDENTIFIER);
      double pl = PositionGetDouble(POSITION_PROFIT) +
                  PositionGetDouble(POSITION_SWAP) +
                  GetOpenPositionCommission(positionId);
      if(pl >= 0)
         continue;

      string mrSym = PositionGetString(POSITION_SYMBOL);
      long posType = PositionGetInteger(POSITION_TYPE);
      int mrSide = (posType == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      string mrBase = "", mrQuote = "";
      int mrBaseDir = 0, mrQuoteDir = 0;
      CurrencyExposureDirsForTrade(mrSym, mrSide, mrBase, mrBaseDir, mrQuote, mrQuoteDir);

      bool oppositeExposure =
         (boBase == mrBase && boBaseDir == -mrBaseDir) ||
         (boBase == mrQuote && boBaseDir == -mrQuoteDir) ||
         (boQuote == mrBase && boQuoteDir == -mrBaseDir) ||
         (boQuote == mrQuote && boQuoteDir == -mrQuoteDir);

      if(oppositeExposure)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool BreakoutDrawdownGateAllows(string symbol, int breakoutTradeSide)
  {
   if(BreakoutMrDrawdownMode == boMrDdOff)
      return true;
   if(BreakoutMrDrawdownMode == boMrDdSameSymbol)
      return HasOpposingMeanReversionDrawdown(symbol, breakoutTradeSide);
   if(BreakoutMrDrawdownMode == boMrDdSameCurrency)
      return HasOpposingMeanReversionDrawdownByCurrency(symbol, breakoutTradeSide);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ProcessBreakoutProfitMrClosures()
  {
   for(int i = 0; i < numBreakoutSymbols && i < MAX_SYMBOLS; i++)
     {
      if(!breakoutCloseMrPending[i])
         continue;
      int boSide = breakoutCloseMrSidePending[i];
      int mrSideToClose = (boSide == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
      string symbol = breakoutSymbols[i];
      bool closed = CloseMeanReversionBySymbolSide(symbol, mrSideToClose,
                                                   "Breakout Profit Close-Link");
      if(EnableLogging)
        {
         Print("[Breakout->MR] symbol=", symbol,
               " boSide=", (boSide == SIDE_BUY ? "BUY" : "SELL"),
               " mrCloseSide=", (mrSideToClose == SIDE_BUY ? "BUY" : "SELL"),
               " closed=", (closed ? "1" : "0"),
               " pl=", DoubleToString(breakoutLastCloseProfit[i], 2));
        }
      breakoutCloseMrPending[i] = false;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CloseSequencesByNetSign(bool closeProfit)
  {
   ScanPositions();
   int closed = 0;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(!SequenceHasLiveManagedPositions(i))
         continue;
      if(closeProfit)
        {
         if(sequences[i].plOpen <= 0)
            continue;
        }
      else
        {
         if(sequences[i].plOpen >= 0)
            continue;
        }
      AsyncCloseSequence(i, closeProfit ? "Dashboard Close Profit" : "Dashboard Close Loss");
      closed++;
     }
   return closed;
  }

// UpsertSymbolActionButton and UpsertSymbolJumpButton are now in Sniper_UI.mqh

//+------------------------------------------------------------------+
//|  NEWS STATUS HELPERS                                              |
//+------------------------------------------------------------------+
void GetCurrencyNewsStatus(string currency, bool &blockManage, bool &blockNoTx)
  {
   blockManage = false;
   blockNoTx = false;

   if(!UseHighImpactNewsFilter)
      return;

   datetime nowTime = TimeCurrent();
   for(int i = 0; i < ArraySize(newsName); i++)
     {
      string evCurr = newsCurr[i];
      bool affects = (evCurr == currency || evCurr == "All" || (UsdAffectsAllPairs && evCurr == "USD"));
      if(!affects)
         continue;

      datetime evTime = newsTime[i];
      if(MinutesBeforeNewsNoTransactions != 0 || MinutesAfterNewsNoTransactions != 0)
        {
         if(nowTime >= evTime - (MinutesBeforeNewsNoTransactions + 1) * 60 &&
            nowTime < evTime + MinutesAfterNewsNoTransactions * 60)
            blockNoTx = true;
        }
      if(nowTime >= evTime - HoursBeforeNewsToStop * 3600 &&
         nowTime < evTime + HoursAfterNewsToStart * 3600)
         blockManage = true;

      if(blockManage && blockNoTx)
         return;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string CurrencyStatusTag(bool blockManage, bool blockNoTx)
  {
   if(blockManage)
      return "BLK";
   if(blockNoTx)
      return "NTX";
   return "OK";
  }

//+------------------------------------------------------------------+
//|  LOCK PROFIT CHART LINES                                          |
//+------------------------------------------------------------------+
void UpdateLockProfitChartLines()
  {
   if(IsTester && !IsVisual)
      return;
   string buyName = EAName + "_lock_buy";
   string sellName = EAName + "_lock_sell";
   color buyClr = (VisualTheme == themeLight) ? C'28,88,188' : C'120,190,255';
   color sellClr = (VisualTheme == themeLight) ? C'178,110,26' : C'255,196,124';
   double buyPlot = 0, sellPlot = 0;
   double buyArmPlot = 0, sellArmPlot = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(PositionGetString(POSITION_SYMBOL), _Symbol))
         continue;

      int seqIdx = FindSequenceByMagic(PositionGetInteger(POSITION_MAGIC));
      if(seqIdx < 0 )
         continue;

      int side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      double arm = GetSequenceLockArmPrice(seqIdx, _Symbol);
      double liveStop = GetSequenceLiveStopPrice(seqIdx, _Symbol);

      if(side == SIDE_BUY)
        {
         if(liveStop > 0 && (buyPlot == 0 || liveStop > buyPlot))
            buyPlot = liveStop;
         if(arm > 0 && (buyArmPlot == 0 || arm < buyArmPlot))
            buyArmPlot = arm;
        }
      else
        {
         if(liveStop > 0 && (sellPlot == 0 || liveStop < sellPlot))
            sellPlot = liveStop;
         if(arm > 0 && (sellArmPlot == 0 || arm > sellArmPlot))
            sellArmPlot = arm;
        }
     }

   if(buyPlot <= 0)
      buyPlot = buyArmPlot;
   if(sellPlot <= 0)
      sellPlot = sellArmPlot;

   ENUM_LINE_STYLE buyStyle = STYLE_DOT;
   ENUM_LINE_STYLE sellStyle = STYLE_DOT;

   UpsertLockLine(buyName, buyPlot, buyClr, buyStyle);
   UpsertLockLine(sellName, sellPlot, sellClr, sellStyle);
  }

//+------------------------------------------------------------------+
//|  TOP ACTION BUTTONS                                               |
//+------------------------------------------------------------------+
void UpsertTopActionButton(string suffix, string label, int x, int y, int w, int h)
  {
   string objName = EAName + "_" + suffix;
   if(ObjectFind(0, objName) < 0)
      ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);

   color bg = (VisualTheme == themeLight) ? C'235,240,248' : C'48,56,70';
   color txt = ThemeTextMain();

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, h);
   ObjectSetString(0, objName, OBJPROP_TEXT, label);
   ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, txt);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 3);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, objName, OBJPROP_STATE, false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpsertTopActionButtons()
  {
   int panelW = DashboardWidthPx > 0 ? DashboardWidthPx : 820;
   int btnW = 82;
   int btnH = 16;
   int gap = 4;
   int y = Y_Axis - 8 + 28;
   int xRight = X_Axis - 8 + panelW - 10;
   int x = xRight - (btnW * 4 + gap * 3);

   string stratLbl = (dashboardButtonStrategy == STRAT_TRENDING) ? "ENTRY:TREND" : "ENTRY:MR";
   UpsertTopActionButton("entry_mode", stratLbl, x, y, btnW, btnH);
   x += (btnW + gap);
   UpsertTopActionButton("close_all", "CLOSE ALL", x, y, btnW, btnH);
   UpsertTopActionButton("close_profit", "CLOSE PROF", x + btnW + gap, y, btnW, btnH);
   UpsertTopActionButton("close_loss", "CLOSE LOSS", x + (btnW + gap) * 2, y, btnW, btnH);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

void DrawDashboard()
  {
   if(!ShowDashboard)
      return;
   if(IsTester && !IsVisual)
      return; // Performance Optimization
   panelLineNo = 0;
   panelMaxChars = 0;
   panelExtraWidthPx = 0;
   x_Axis = X_Axis;
   panelPosY = Y_Axis;
   DrawPanelFrame(panelLastLines, panelLastChars);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   plClosedToday = getPlClosedToday();
   int managedPosTotal = TotalManagedPositions();
   double totalPl = TotalPlOpenLive();
   if(managedPosTotal == 0)
     {
      accountOpenPlLow = 0;
      accountOpenPlHigh = 0;
      accountOpenPlInitialized = false;
     }
   if(!accountOpenPlInitialized)
     {
      accountOpenPlLow = totalPl;
      accountOpenPlHigh = totalPl;
      accountOpenPlInitialized = true;
     }
   else
     {
      if(totalPl < accountOpenPlLow)
         accountOpenPlLow = totalPl;
      if(totalPl > accountOpenPlHigh)
         accountOpenPlHigh = totalPl;
     }

   color txtMain = ThemeTextMain();
   color txtMuted = ThemeTextMuted();
   color txtInv = ThemePanelBackground();
   color txtOk = (VisualTheme == themeLight) ? C'0,128,0' : C'90,220,110';
   color txtWarn = (VisualTheme == themeLight) ? C'165,80,0' : C'255,190,110';
   color txtBad = (VisualTheme == themeLight) ? C'190,28,28' : C'255,120,120';

   PanelHeaderLabel("hdr", "ZScoreMurreySniper v" + version, txtMain);
   PanelLabel("eq", "Equity: " + DoubleToString(equity, 2) +
              "  Bal: " + DoubleToString(balance, 2), txtMain);
   double totalPips = GetTotalPipsProfit();
   PanelLabel("pl", "Open: " + DoubleToString(totalPl, 2) +
              " [" + DoubleToString(accountOpenPlLow, 2) + "/" + DoubleToString(accountOpenPlHigh, 2) + "]" +
              "  Pips: " + DoubleToString(totalPips, 1) +
              "  Today: " + DoubleToString(plClosedToday, 2),
              totalPl >= 0 ? txtOk : txtBad);
   if(globalLockProfitExec)
      PanelLabel("gl_peak", "Global $ Peak: " + DoubleToString(globalPlHigh, 2), txtWarn);
   if(globalPipsLockExec)
      PanelLabel("gp_peak", "Global Pips Peak: " + DoubleToString(globalPipsHigh, 1), txtWarn);
   if(hard_stop)
      PanelLabel("stop", "!! STOPPED: " + stopReason, txtBad);

   int tableW = GetTableAreaWidth();

   int symbolsHdrRow = panelLineNo;
   DrawSectionBand("symbols", symbolsHdrRow, tableW, false);
   PanelHeaderLabel("sep1", "     Symbols", clrWhite);
   UpsertSectionToggleButton("sym", X_Axis, symbolsHdrRow, showSymbols);

   if(showSymbols)
     {
      int tblHdrRow = panelLineNo;
      int cw = 7; // ~7px per char for Consolas 9pt
      int c_sym = 0;
      int c_bNum = 11*cw;
      int c_bLot = 16*cw;
      int c_bPl = 23*cw;
      int c_sNum = 30*cw;
      int c_sLot = 35*cw;
      int c_sPl = 42*cw;
      int c_net = 49*cw;
      int c_mk = 620;
      int c_cf = 700;

      UpsertInlineLabel("tblh_sym", "SYMBOL", c_sym, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_bnum", "B#", c_bNum, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_blot", "BLot", c_bLot, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_bpl", "B$", c_bPl, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_snum", "S#", c_sNum, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_slot", "SLot", c_sLot, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_spl", "S$", c_sPl, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_net", "NET", c_net, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_r", "[LOW/HI]      LP            NEWS", 420, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_mk", "MK", c_mk, tblHdrRow, txtMuted, true);
      UpsertInlineLabel("tblh_cf", "CF", c_cf, tblHdrRow, txtMuted, true);
      panelLineNo++; // Manual increment since we used discrete inline labels instead of PanelLabel
      DrawHeaderDivider("symbols", panelLineNo, tableW);
     }
   else
     {
      // Cleanup headers if hidden
      ObjectDelete(0, EAName + "_tblh_sym");
      ObjectDelete(0, EAName + "_tblh_bnum");
      ObjectDelete(0, EAName + "_tblh_blot");
      ObjectDelete(0, EAName + "_tblh_bpl");
      ObjectDelete(0, EAName + "_tblh_snum");
      ObjectDelete(0, EAName + "_tblh_slot");
      ObjectDelete(0, EAName + "_tblh_spl");
      ObjectDelete(0, EAName + "_tblh_net");
      ObjectDelete(0, EAName + "_tblh_r");
      ObjectDelete(0, EAName + "_tblh_mk");
      ObjectDelete(0, EAName + "_tblh_cf");
      ObjectDelete(0, EAName + "_hdrdiv_symbols");
      // Legacy cleanup
      ObjectDelete(0, EAName + "_tblh_l");
     }

   double symPl[];
   double symPips[];
   int symPosCount[];
   int symBuyCount[];
   int symSellCount[];
   double symLots[];
   BuildSymbolOpenStats(symPl, symPips, symPosCount, symBuyCount, symSellCount, symLots);
   double buyPl[];
   double sellPl[];
   double buyLots[];
   double sellLots[];
   int buyPosCount[];
   int sellPosCount[];
   BuildSymbolSideOpenStats(buyPl, sellPl, buyLots, sellLots, buyPosCount, sellPosCount);
   double buyLock[], buyArm[], sellLock[], sellArm[];
   bool buyLockActive[], sellLockActive[];
   BuildSymbolLockLevels(buyLock, buyLockActive, buyArm, sellLock, sellLockActive, sellArm);

   ObjectDelete(0, EAName + "_tbl_mode");
   ObjectDelete(0, EAName + "_tbl_up");
   ObjectDelete(0, EAName + "_tbl_dn");

   for(int i = 0; i < numSymbols; i++)
     {
      int rowLine = panelLineNo;
      string symbol = allSymbols[i];

      if(symPosCount[i] <= 0)
        {
         symbolOpenPlLow[i] = 0;
         symbolOpenPlHigh[i] = 0;
         symbolOpenPlInitialized[i] = false;
        }
      if(!symbolOpenPlInitialized[i])
        {
         symbolOpenPlLow[i] = symPl[i];
         symbolOpenPlHigh[i] = symPl[i];
         symbolOpenPlInitialized[i] = true;
        }
      else
        {
         if(symPl[i] < symbolOpenPlLow[i])
            symbolOpenPlLow[i] = symPl[i];
         if(symPl[i] > symbolOpenPlHigh[i])
            symbolOpenPlHigh[i] = symPl[i];
        }

      bool baseBlock = false, baseNoTx = false, quoteBlock = false, quoteNoTx = false;
      GetCurrencyNewsStatus(GetBaseCurrency(symbol), baseBlock, baseNoTx);
      GetCurrencyNewsStatus(GetQuoteCurrency(symbol), quoteBlock, quoteNoTx);
      string newsStatus = GetBaseCurrency(symbol) + ":" + CurrencyStatusTag(baseBlock, baseNoTx) +
                          "/" + GetQuoteCurrency(symbol) + ":" + CurrencyStatusTag(quoteBlock, quoteNoTx);

      if(showSymbols)
        {
         DrawSymbolRowBackground(i, rowLine);

         color neutralClr = txtMain;
         if(baseBlock || quoteBlock) neutralClr = txtBad;
         else if(baseNoTx || quoteNoTx) neutralClr = txtWarn;

         color buyPlClr = neutralClr;
         if(buyPl[i] > 0.00001)        buyPlClr = txtOk;
         else if(buyPl[i] < -0.00001)  buyPlClr = txtBad;

         color sellPlClr = neutralClr;
         if(sellPl[i] > 0.00001)        sellPlClr = txtOk;
         else if(sellPl[i] < -0.00001)  sellPlClr = txtBad;

         color netPlClr = neutralClr;
         if(symPl[i] > 0.00001)        netPlClr = txtOk;
         else if(symPl[i] < -0.00001)  netPlClr = txtBad;

         int cw = 7;
         int c_sym = 0;
         int c_bNum = 11*cw;
         int c_bLot = 16*cw;
         int c_bPl = 23*cw;
         int c_sNum = 30*cw;
         int c_sLot = 35*cw;
         int c_sPl = 42*cw;
         int c_net = 49*cw;
         int c_mk = 620;
         int c_cf = 700;

         UpsertInlineLabel("symrow_sym_" + IntegerToString(i), "          ", c_sym, rowLine, neutralClr); // Placeholder for jump button
         UpsertInlineLabel("symrow_bnum_" + IntegerToString(i), StringFormat("%2d", buyPosCount[i]), c_bNum, rowLine, neutralClr);
         UpsertInlineLabel("symrow_blot_" + IntegerToString(i), StringFormat("%4.2f", buyLots[i]), c_bLot, rowLine, neutralClr);
         UpsertInlineLabel("symrow_bpl_" + IntegerToString(i), StringFormat("%5.1f", buyPl[i]), c_bPl, rowLine, buyPlClr);
         
         UpsertInlineLabel("symrow_snum_" + IntegerToString(i), StringFormat("%2d", sellPosCount[i]), c_sNum, rowLine, neutralClr);
         UpsertInlineLabel("symrow_slot_" + IntegerToString(i), StringFormat("%4.2f", sellLots[i]), c_sLot, rowLine, neutralClr);
         UpsertInlineLabel("symrow_spl_" + IntegerToString(i), StringFormat("%5.1f", sellPl[i]), c_sPl, rowLine, sellPlClr);
         
         UpsertInlineLabel("symrow_net_" + IntegerToString(i), StringFormat("%6.1f", symPl[i]), c_net, rowLine, netPlClr);

         // Right-hand columns: LOW/HI, LP, NEWS
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         string buyLpTxt = "-";
         string sellLpTxt = "-";
         if(buyLockActive[i] && buyLock[i] > 0)
            buyLpTxt = DoubleToString(buyLock[i], digits);
         else if(buyArm[i] > 0)
            buyLpTxt = DoubleToString(buyArm[i], digits);
            
         if(sellLockActive[i] && sellLock[i] > 0)
            sellLpTxt = DoubleToString(sellLock[i], digits);
         else if(sellArm[i] > 0)
            sellLpTxt = DoubleToString(sellArm[i], digits);

         string lpPair = buyLpTxt + "/" + sellLpTxt;
         if(StringLen(lpPair) > 13) lpPair = StringSubstr(lpPair, 0, 13);
         
         string newsCell = newsStatus;
         if(StringLen(newsCell) > 7) newsCell = StringSubstr(newsCell, 0, 7);
         
         string rowR = StringFormat("[%6.1f/%6.1f] %-11s    %-7s", symbolOpenPlLow[i], symbolOpenPlHigh[i], lpPair, newsCell);
         string mkState = "N/A";
         string mkConf = "N/A";
         GetMarkovDashboardState(symbol, mkState, mkConf);
         
         UpsertInlineLabel("symrow_r_" + IntegerToString(i), rowR, 420, rowLine, neutralClr);
         UpsertInlineLabel("symrow_mk_" + IntegerToString(i), mkState, c_mk, rowLine, neutralClr);
         UpsertInlineLabel("symrow_cf_" + IntegerToString(i), mkConf, c_cf, rowLine, neutralClr);
         UpsertSymbolJumpButton(i, rowLine, symbol);
         UpsertSymbolActionButton(i, SIDE_BUY, rowLine, HasOpenSequenceForSymbolSide(symbol, SIDE_BUY));
         UpsertSymbolActionButton(i, SIDE_SELL, rowLine, HasOpenSequenceForSymbolSide(symbol, SIDE_SELL));
         panelLineNo++;
        }
      else
        {
         ObjectDelete(0, EAName + "_rowbg_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_sym_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_bnum_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_blot_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_bpl_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_snum_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_slot_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_spl_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_net_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_r_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_mk_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_cf_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symgoto_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_btn_" + IntegerToString(i) + "_buy");
         ObjectDelete(0, EAName + "_btn_" + IntegerToString(i) + "_sell");
         // Cleanup old ones just in case
         ObjectDelete(0, EAName + "_symrow_l_" + IntegerToString(i));
         ObjectDelete(0, EAName + "_symrow_sm_" + IntegerToString(i));
        }
     }
   for(int i = numSymbols; i < MAX_SYMBOLS; i++)
     {
      ObjectDelete(0, EAName + "_rowbg_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_sym_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_bnum_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_blot_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_bpl_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_snum_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_slot_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_spl_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_net_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_r_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_mk_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_cf_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symgoto_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_btn_" + IntegerToString(i) + "_buy");
      ObjectDelete(0, EAName + "_btn_" + IntegerToString(i) + "_sell");
      // Cleanup old ones
      ObjectDelete(0, EAName + "_symrow_l_" + IntegerToString(i));
      ObjectDelete(0, EAName + "_symrow_sm_" + IntegerToString(i));
     }
   for(int i = 0; i < MAX_SYMBOLS * 2; i++)
      ObjectDelete(0, EAName + "_symrow_" + IntegerToString(i));

   int eventsHdrRow = panelLineNo;
   DrawSectionBand("events", eventsHdrRow, tableW, true);
   PanelHeaderLabel("sep_evt", "     Events (Today/Tomorrow)", clrWhite);
   UpsertSectionToggleButton("evt", X_Axis, eventsHdrRow, showEvents);

   if(showEvents)
     {
      int n = ArraySize(newsName);
      if(!UseHighImpactNewsFilter)
         PanelLabel("evt_off", "News filter disabled.", txtMuted);
      else
         if(n <= 0)
            PanelLabel("evt_none", "No high-impact events loaded.", txtMuted);
         else
           {
            int idx[];
            ArrayResize(idx, n);
            for(int i = 0; i < n; i++)
               idx[i] = i;
            for(int i = 0; i < n - 1; i++)
              {
               int minIdx = i;
               for(int j = i + 1; j < n; j++)
                 {
                  if(newsTime[idx[j]] < newsTime[idx[minIdx]])
                     minIdx = j;
                 }
               if(minIdx != i)
                 {
                  int tmp = idx[i];
                  idx[i] = idx[minIdx];
                  idx[minIdx] = tmp;
                 }
              }

            datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
            datetime tomorrow = today + 24 * 3600;
            int shown = 0;
            datetime nextEvtTime = 0;

            // Find the immediate next upcoming event (for orange highlighting)
            for(int k = 0; k < n; k++)
              {
               if(newsTime[idx[k]] > TimeCurrent())
                 {
                  nextEvtTime = newsTime[idx[k]];
                  break;
                 }
              }

            for(int k = 0; k < n; k++)
              {
               int ii = idx[k];
               datetime ev = newsTime[ii];
               datetime evDay = StringToTime(TimeToString(ev, TIME_DATE));
               if(evDay != today && evDay != tomorrow)
                  continue;
                  
               string dayTag = (evDay == today) ? "Today" : "Tomorrow";
               string evName = newsName[ii];
               if(StringLen(evName) > 36)
                  evName = StringSubstr(evName, 0, 36) + "...";
               string evRow = StringFormat("%-8s %5s  %-3s  %s",
                                           dayTag, TimeToString(ev, TIME_MINUTES), newsCurr[ii], evName);
               
               color evClr = txtMain;
               if(ev < TimeCurrent())
                  evClr = txtMuted; // Past events are dimmed
               else if(ev == nextEvtTime)
                  evClr = (VisualTheme == themeLight) ? C'240,120,0' : C'255,150,50'; // Next event is orange
                  
               PanelLabel("evt_" + IntegerToString(shown), evRow, evClr);
               shown++;
             }
            if(shown == 0)
               PanelLabel("evt_none2", "No events scheduled for today/tomorrow.", txtMuted);
            
            // Clean up any old labels above the 'shown' count
            for(int j=shown; j<10; j++)
              ObjectDelete(0, EAName + "_evt_" + IntegerToString(j));
           }
     }
   else
     {
      // Cleanup events when hidden
      ObjectDelete(0, EAName + "_evt_off");
      ObjectDelete(0, EAName + "_evt_none");
      ObjectDelete(0, EAName + "_evt_none2");
      for(int j=0; j<10; j++)
         ObjectDelete(0, EAName + "_evt_" + IntegerToString(j));
     }

   panelLastLines = panelLineNo;
   panelLastChars = panelMaxChars;
   UpsertTopActionButtons();
   if(hard_stop)
      UpsertRestartNowButton();
   else
      ObjectDelete(0, EAName + "_restart_now");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ClearDashboard()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, EAName + "_") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//|  EXPERT INITIALIZATION                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   int lastDeinitReason = ConsumeLastDeinitReason();
   bool chartChangeReload = (lastDeinitReason == REASON_CHARTCHANGE);
   version = propVersion;
   IsTester = MQLInfoInteger(MQL_TESTER);
   IsVisual = MQLInfoInteger(MQL_VISUAL_MODE);
   timeEAstart = TimeCurrent();
   baseMagicNumber = MAGIC_NUMBER;

// Point/pip calc
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   pip = SymbolPipValue(_Symbol);

// Check hedging
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) !=
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("Hedging mode required! Enable hedging on your account.");
      return INIT_FAILED;
     }

// Trade settings
   trade.SetExpertMagicNumber(baseMagicNumber);
   trade.SetDeviationInPoints(30);
   ENUM_ORDER_TYPE_FILLING initFilling = ResolveFillingMode(_Symbol);
   trade.SetTypeFilling(initFilling);
   if(EnableLogging)
      Print("[Init] Filling mode for ", _Symbol, " = ", (int)initFilling);
   trade.SetAsyncMode(false);

// ATR handle
   atrHandle = iATR(_Symbol, (ENUM_TIMEFRAMES)ATRtimeframe, AtrPeriod);
   calculateAtr = (StopLoss < 0 || TrailingStop < 0);

   // Parse symbols
   ParseSymbols();
   dashboardButtonStrategy = DashboardButtonStrategyDefault;
   ResolvePipValueReference();
   int markovEngineMode = AnyStrategyMarkovEnabled() ? (int)markovModeDirectional : (int)markovModeOff;
   MarkovSetConfig(markovEngineMode,
                   (ENUM_TIMEFRAMES)Markov_RegimeTimeframe,
                   Markov_Lookback,
                   Markov_ATRLength,
                   Markov_SmoothLen,
                   Markov_TriggerATR,
                   Markov_ExitATR,
                   Markov_VolPercentileLookback,
                   Markov_MemoryDecay,
                   Markov_UseSecondOrder,
                   Markov_EvEmaLength,
                   Markov_MinSampleSize,
                   Markov_RangeLookback,
                   Markov_MacroLen,
                   Markov_MicroLen,
                   Markov_SlopeLen,
                   Markov_SlopeFlatAtrMult,
                   Markov_MinTrendBars,
                   Markov_BlockIfUntrained,
                   Markov_MinConfidence,
                   Markov_MinProbGap,
                   Markov_MinEdge);
   MarkovPrepareSymbols(allSymbols);
   RefreshStrengthMatrixIfNeeded(true);

// Chart cleanup: keep user-added chart indicators on symbol/timeframe changes.
   if(!chartChangeReload)
      ClearChartIndicatorsAndGrid();

// Set structural fields only; do NOT wipe magic numbers, LP profile data,
// or trade state here — RunScanner re-initialises tempSequences from scratch
// and carries over preserved data on symbol change.
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      sequences[i].side = i % 2;
      sequences[i].seqId = i;
     }
   for(int i = 0; i < MAX_SYMBOLS; i++)
     {
      breakoutMagic[i] = baseMagicNumber + 50000 + i;
      breakoutOpen[i] = false;
      breakoutPrevOpen[i] = false;
      breakoutSide[i] = -1;
      breakoutPrevSide[i] = -1;
      breakoutPlOpen[i] = 0;
      breakoutPlPrev[i] = 0;
      breakoutLastCloseProfit[i] = 0;
      breakoutLastCloseTime[i] = 0;
      breakoutLastEntryTime[i] = 0;
      breakoutCloseMrPending[i] = false;
      breakoutCloseMrSidePending[i] = -1;
      breakoutFrozenUpper[i] = 0;
      breakoutFrozenLower[i] = 0;
      breakoutFrozenInc[i] = 0;
      breakoutFrozenBarTime[i] = 0;
     }

   // Run initial scanner
   RunScanner();
   // Rebuild live sequence state immediately on attach/reload (before first tick)
   // so LP lines/buttons/dashboard are correct even in low/no-tick moments.
   ScanPositions();
   UpdateLockProfitChartLines();

// News
   if(UseHighImpactNewsFilter)
     {
      if(IsTester)
        {
         readHistoricalNews();
        }
      else
        {
         lastNewsDownloadTime = 0;
         downLoadNewsFile();
        }
      populateBlockingNews();
     }

// Chart style / theme
   ApplyVisualTheme();

   Print("=== ", EAName, " v", version, " initialized ===");
   Print("Pairs: ", numActivePairs, " | Magic: ", baseMagicNumber);
// 1-second timer for dashboard/line resync (also keeps news refresh logic alive).
   EventSetTimer(1);
   // Post-init resync retries: MT5 can expose open positions a fraction later than OnInit.
   // Retry briefly so LP lines/buttons are present without requiring manual symbol change.
   for(int k = 0; k < 8; k++)
     {
      ScanPositions();
      DrawDashboard();
      UpdateLockProfitChartLines();
      ChartRedraw(0);

      bool hasBuy = false, hasSell = false;
      bool hasManagedOnChart = HasManagedPositionsOnSymbol(_Symbol, hasBuy, hasSell);
      bool buyLineOk = (!hasBuy || ObjectFind(0, EAName + "_lock_buy") >= 0);
      bool sellLineOk = (!hasSell || ObjectFind(0, EAName + "_lock_sell") >= 0);
      if(!hasManagedOnChart || (buyLineOk && sellLineOk))
         break;
      Sleep(125);
     }
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  TIMER EVENT: Non-blocking news download                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(UseHighImpactNewsFilter && !IsTester)
     {
      downLoadNewsFile();
      populateBlockingNews();
     }
   if(IsTester && !IsVisual)
      return;

   // Timer-based state refresh: covers no-tick periods after attach/reload.
   ScanPositions();
   UpdateLockProfitChartLines();
   if(ShowDashboard)
      DrawDashboard();
   if(bNeedsRedraw)
     {
      ChartRedraw(0);
      bNeedsRedraw = false;
     }
  }

//+------------------------------------------------------------------+
//|  EXPERT DEINITIALIZATION                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveLastDeinitReason(reason);
   EventKillTimer();
   ClearDashboard();
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   ReleaseAtrCache();
   ReleaseKeltnerCache();
   ReleaseEmaCache();
   MarkovRelease();
   Print(EAName, " deinitialized. Reason: ", reason);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void RunBreakoutEntryEngine()
  {
   if(!EnableBreakoutStrategy)
      return;
   if(numBreakoutSymbols <= 0)
      return;
   if(!AllowNewSequence)
      return;
   if(!IsSessionOpen())
      return;
   if(maxDailyWinnersLosersHit)
      return;
   if(blockingNews && NewsAction == newsActionPause)
      return;

   int level = BreakoutLevelEighth;
   if(level < 1)
      level = 1;
   if(level > 8)
      level = 8;

   for(int i = 0; i < numBreakoutSymbols && i < MAX_SYMBOLS; i++)
     {
      string sym = breakoutSymbols[i];
      if(StringLen(sym) == 0)
         continue;
      SymbolSelect(sym, true);
      if(HasOpenBreakoutPositionOnSymbol(sym) || breakoutOpen[i])
         continue;

      // Freeze breakout levels per-symbol, per-bar to avoid moving triggers intrabar.
      datetime symBarTime = iTime(sym, PERIOD_CURRENT, 0);
      bool refreshFrozen = (symBarTime <= 0 ||
                            breakoutFrozenBarTime[i] != symBarTime ||
                            breakoutFrozenInc[i] <= 0 ||
                            breakoutFrozenUpper[i] == 0 ||
                            breakoutFrozenLower[i] == 0);
      if(refreshFrozen)
        {
         int boLookback = Breakout_MM_Lookback;
         if(boLookback < 8)
            boLookback = 8;
         double mm88 = 0, mm48 = 0, mm08 = 0, mmInc = 0;
         double mmP28 = 0, mmP18 = 0, mmM18 = 0, mmM28 = 0;
         if(!CalcMurreyLevelsForSymbolCustom(sym, (ENUM_TIMEFRAMES)Breakout_MM_Timeframe, boLookback,
                                             mm88, mm48, mm08, mmInc, mmP28, mmP18, mmM18, mmM28))
            continue;
         if(mmInc <= 0)
            continue;
         breakoutFrozenInc[i] = mmInc;
         breakoutFrozenUpper[i] = mm88 + (level * mmInc); // +N/8
         breakoutFrozenLower[i] = mm08 - (level * mmInc); // -N/8
         breakoutFrozenBarTime[i] = symBarTime;
        }
      double mmInc = breakoutFrozenInc[i];
      double upperBreakLevel = breakoutFrozenUpper[i];
      double lowerBreakLevel = breakoutFrozenLower[i];
      if(mmInc <= 0 || upperBreakLevel == 0 || lowerBreakLevel == 0)
         continue;

      double pipValue = SymbolPipValue(sym);
      if(pipValue <= 0)
         continue;
      double buffer = BreakoutBufferPips * pipValue;

      double bidLocal = SymbolInfoDouble(sym, SYMBOL_BID);
      double askLocal = SymbolInfoDouble(sym, SYMBOL_ASK);

      bool triggerBuy = (askLocal >= upperBreakLevel + buffer);
      bool triggerSell = (bidLocal <= lowerBreakLevel - buffer);
      if(triggerBuy && !triggerSell && CanOpenSide(SIDE_BUY))
        {
         if(!BreakoutDrawdownGateAllows(sym, SIDE_BUY))
            continue;
         OpenBreakoutOrder(i, ORDER_TYPE_BUY, sym, upperBreakLevel, mmInc);
        }
      else
         if(triggerSell && !triggerBuy && CanOpenSide(SIDE_SELL))
           {
            if(!BreakoutDrawdownGateAllows(sym, SIDE_SELL))
               continue;
            OpenBreakoutOrder(i, ORDER_TYPE_SELL, sym, lowerBreakLevel, mmInc);
           }
     }
  }

//+------------------------------------------------------------------+
//|  EXPERT TICK FUNCTION                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   CurTime = TimeCurrent();
   TimeToStruct(CurTime, now);
   newBar = isNewBar();
   newBarM1 = isNewBarM1();
   if(newBar)
      ClearEntryBarCache();

// Efficiency Early Exit: Skip computation if nothing to manage and no new bar to process
   int totalPos = TotalManagedPositions();
   bool mrSessionOpen = IsStrategySessionOpen(STRAT_MEAN_REVERSION);
   bool trendSessionOpen = IsStrategySessionOpen(STRAT_TRENDING);
   bool anyStrategySessionOpen = (mrSessionOpen && EnableMeanReversion) || (trendSessionOpen && EnableTrendingStrategy);
   if(totalPos == 0 && !anyStrategySessionOpen && !newBar && !newBarM1)
      return;

// New day detection
   if(now.day != lastDay)
     {
      newDay = true;
      lastDay = now.day;
      sequenceCounterFinal = sequenceCounter;
      sequenceCounterWinnersFinal = sequenceCounterWinners;
      sequenceCounterLosersFinal = sequenceCounterLosers;
      sequenceCounter = 0;
      sequenceCounterWinners = 0;
      sequenceCounterLosers = 0;
      maxDailyWinnersLosersHit = false;
      RefreshStrengthMatrixIfNeeded(true);
      if(UseHighImpactNewsFilter)
        {
         if(IsTester)
           {
            readHistoricalNews();
            populateBlockingNews();
           }
         // Live news now handled by OnTimer
        }
     }
   else
      newDay = false;

   if(!newDay)
      RefreshStrengthMatrixIfNeeded(false);

// ATR
   if(calculateAtr || newBar)
     {
      double atrBuf[];
      if(atrHandle != INVALID_HANDLE && pip > 0 && CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0)
         atrPips = atrBuf[0] / pip;
     }

// Scan positions across all pairs
   if(totalPos > 0)
     {
      bool shouldScanNow = false;
      if(totalPos != lastScannedManagedPosTotal)
         shouldScanNow = true;
      else
         if(newBar || newBarM1)
            shouldScanNow = true;
      if(!shouldScanNow && ShouldScanPositionsEveryTick())
         shouldScanNow = true;

      if(shouldScanNow)
        {
         ScanPositions();
         lastScannedManagedPosTotal = totalPos;
        }
     }
   else
     {
      // Light reset of internal counts if no positions
      for(int i = 0; i < MAX_PAIRS * 2; i++)
        {
         sequences[i].prevTradeCount = sequences[i].tradeCount;
         sequences[i].tradeCount = 0;
         sequences[i].plOpen = 0;
        }
      lastScannedManagedPosTotal = 0;
     }

   // Keep lock-profit chart levels synchronized on every tick.
   UpdateLockProfitChartLines();

// Hard stop check
   if(CheckStopOfEA())
     {
      DrawDashboard();
      return;
     }

// News filter
   if(UseHighImpactNewsFilter)
     {
      if(lastNewsEvalTime == 0 || (CurTime - lastNewsEvalTime) >= 60 || newBarM1 || newBar)
        {
         blockingNews = isThereBlockingNews();
         lastNewsEvalTime = CurTime;
        }
      if(blockingNews && NewsAction == newsActionClose)
        {
         AsyncCloseAll("News Close");
         DrawDashboard();
         return;
        }
     }

// Weekend closure
   if(CloseAllTradesDisableEA && now.day_of_week == DayToClose)
     {
      datetime closeTime = stringToTime(TimeToClose);
      if(CurTime >= closeTime)
        {
         AsyncCloseAll("Weekend Close");
         if(!RestartEA_AfterFridayClose)
           {
            hard_stop = true;
            stopReason = "Weekend Closed";
           }
         else
           {
            // calc restart time
            int daysToRestart = DayToRestart - now.day_of_week;
            if(daysToRestart <= 0)
               daysToRestart += 7;
            restartTime = StringToTime(TimeToString(CurTime + daysToRestart * 86400, TIME_DATE) + " " + TimeToRestart);
            hard_stop = true;
            stopReason = "Weekend-Restart";
           }
         DrawDashboard();
         return;
        }
     }

// Equity protection
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

// Per-sequence max loss (close individual sequences, not all)
   if(MaxLossPerSequence > 0)
     {
      for(int sq = 0; sq < MAX_PAIRS * 2; sq++)
        {
         if(sequences[sq].tradeCount > 0 && sequences[sq].plOpen <= -MaxLossPerSequence)
           {
            AsyncCloseSequence(sq, "Max Seq Loss (" + DoubleToString(sequences[sq].plOpen, 2) + ")");
           }
        }
     }

// Global equity stop
   if(GlobalEquityStop > 0)
     {
      double eqThreshold = GlobalEquityStop;
      if(GlobalEpType == globalEpAmount)
         eqThreshold = balance - GlobalEquityStop;
      else
         if(GlobalEpType == globalEpPercent)
            eqThreshold = balance * (1.0 - GlobalEquityStop / 100.0);
      if(equity <= eqThreshold)
        {
         AsyncCloseAll("Global Equity Stop");
         hard_stop = true;
         stopReason = "Global EQ Stop";
         ScheduleRestartAfterLoss();
         DrawDashboard();
         return;
        }
     }

// Ultimate target
   if(UltimateTargetBalance > 0 && balance >= UltimateTargetBalance)
     {
      AsyncCloseAll("Ultimate Target");
      hard_stop = true;
      stopReason = "Target Balance Hit";
      ScheduleRestartAfterLoss();
      DrawDashboard();
      return;
     }

// Daily profit target
   if(ProfitCloseEquityAmount > 0)
     {
      double dayPl = getPlClosedToday() + TotalPlOpen();
      if(dayPl >= ProfitCloseEquityAmount)
        {
         AsyncCloseAll("Daily Profit Target");
         hard_stop = true;
         stopReason = "Daily Target Hit";
         ScheduleRestartAfterLoss();
         DrawDashboard();
         return;
        }
     }

// Global Rescue Logic
   if(RescueCloseInDrawdown && RescueDrawdownThreshold > 0)
     {
      double totalOpenPL = TotalPlOpen();
      if(totalOpenPL > 0)
        {
         double worstPL = 0;
         bool hasWorst = false;
         for(int sq = 0; sq < MAX_PAIRS * 2; sq++)
           {
            if(sequences[sq].tradeCount > 0)
              {
               if(!hasWorst || sequences[sq].plOpen < worstPL)
                 {
                  worstPL = sequences[sq].plOpen;
                  hasWorst = true;
                 }
              }
           }
         if(hasWorst && worstPL <= -RescueDrawdownThreshold)
           {
            AsyncCloseAll("Rescue Close: Net PL " + DoubleToString(totalOpenPL, 2) + " covers worst draw " + DoubleToString(worstPL, 2));
            DrawDashboard();
            return;
           }
        }
     }

// Sequence limits
   if(MaxSequencesPerDay > 0 && sequenceCounter >= MaxSequencesPerDay)
     {
      maxDailyWinnersLosersHit = true;
     }
   if(MaxDailyWinners > 0 && sequenceCounterWinners >= MaxDailyWinners)
     {
      maxDailyWinnersLosersHit = true;
     }
   if(MaxDailyLosers > 0 && sequenceCounterLosers >= MaxDailyLosers)
     {
      maxDailyWinnersLosersHit = true;
     }

// Re-scan periodically
   if(Scanner_IntervalHours > 0 && CurTime >= lastScanTime + Scanner_IntervalHours * 3600)
     {
      RunScanner();
      // Re-calc indicators after rescan
      for(int p = 0; p < numActivePairs; p++)
        {
         CalcMurreyLevels(p);
         CalcZScore(p);
        }
     }

// Process each active pair on new bar
   if(newBar)
     {
      for(int p = 0; p < numActivePairs; p++)
        {
         CalcMurreyLevels(p);
         CalcZScore(p);
         if(AnyStrategyMarkovEnabled())
           {
            string mkSymA = activePairs[p].symbolA;
            string mkSymB = activePairs[p].symbolB;
            if(StringLen(mkSymA) > 0)
               MarkovUpdateSymbol(mkSymA);
            if(StringLen(mkSymB) > 0 && mkSymB != mkSymA)
               MarkovUpdateSymbol(mkSymB);
           }
        }
     }

// Session checks
   mrSessionOpen = IsStrategySessionOpen(STRAT_MEAN_REVERSION);
   trendSessionOpen = IsStrategySessionOpen(STRAT_TRENDING);
   anyStrategySessionOpen = (mrSessionOpen && EnableMeanReversion) || (trendSessionOpen && EnableTrendingStrategy);

//=== MAIN TRADING LOOP PER PAIR ===
// Efficiency Gate: Only run pair logic if we have positions or are looking to open new ones
   if(totalPos > 0 || (anyStrategySessionOpen && !maxDailyWinnersLosersHit))
     {
      int openMrSequenceCount = 0;
      bool loggedMaxOpenSeqBlock = false;
      if(MaxOpenSequences > 0)
         openMrSequenceCount = CountOpenMrSequences();
      for(int p = 0; p < numActivePairs; p++)
        {
         string symA = activePairs[p].symbolA;
         string symB = activePairs[p].symbolB;
         if(StringLen(symA) == 0)
            continue;

         double mmInc = activePairs[p].mmIncrement;
         double mmIncB = activePairs[p].mmIncrementB;
         double zScore = activePairs[p].currentZ;
         string sym = symA; // pair label / legacy logging
         int bIdx = activePairs[p].buySeqIdx;
         int sIdx = activePairs[p].sellSeqIdx;
         bool buyStartedNow = false;
         bool sellStartedNow = false;

         // Track extreme market prices for sequence management
         if(sequences[bIdx].tradeCount > 0)
           {
            string bSym = sequences[bIdx].tradeSymbol;
            if(StringLen(bSym)>0)
              {
               double curBid = SymbolInfoDouble(bSym, SYMBOL_BID);
               if(sequences[bIdx].highestPrice == 0 || curBid > sequences[bIdx].highestPrice)
                  sequences[bIdx].highestPrice = curBid;
               if(sequences[bIdx].lowestPrice == 0 || curBid < sequences[bIdx].lowestPrice)
                  sequences[bIdx].lowestPrice = curBid;
              }
           }
         if(sequences[sIdx].tradeCount > 0)
           {
            string sSym = sequences[sIdx].tradeSymbol;
            if(StringLen(sSym)>0)
              {
               double curAsk = SymbolInfoDouble(sSym, SYMBOL_ASK);
               if(sequences[sIdx].highestPrice == 0 || curAsk > sequences[sIdx].highestPrice)
                  sequences[sIdx].highestPrice = curAsk;
               if(sequences[sIdx].lowestPrice == 0 || curAsk < sequences[sIdx].lowestPrice)
                  sequences[sIdx].lowestPrice = curAsk;
              }
           }

         // Rebuild frozen snapshots if lost (restart/reshuffle safety)
         /* if(EnableLogging && (sequences[bIdx].tradeCount > 0 || sequences[sIdx].tradeCount > 0))
             Print("[PAIR_TC] pair=", p, " ", activePairs[p].symbolA, "/", activePairs[p].symbolB,
                   " bTC=", sequences[bIdx].tradeCount, " sTC=", sequences[sIdx].tradeCount,
                   " bMagic=", sequences[bIdx].magicNumber, " sMagic=", sequences[sIdx].magicNumber);*/
         if((newBar || newBarM1 || firstTickSinceInit) && SequenceNeedsReconstruct(bIdx, p))
            ReconstructSequenceMemory(bIdx, p);
         if((newBar || newBarM1 || firstTickSinceInit) && SequenceNeedsReconstruct(sIdx, p))
            ReconstructSequenceMemory(sIdx, p);

         // ---- TRAILING (runs every tick or per bar) ----
         // BUY trailing
         if(sequences[bIdx].tradeCount > 0)
           {
            bool doTrailBuy = false;
            bool buyIsTrend = (sequences[bIdx].strategyType == STRAT_TRENDING);
            enumTrailFrequency checkFreq = sequences[bIdx].lockProfitExec ?
                                           (buyIsTrend ? TrendTrailFrequency : TrailFrequency) :
                                           (buyIsTrend ? TrendLockProfitCheckFrequency : LockProfitCheckFrequency);
            if(checkFreq == trailEveryTick)
               doTrailBuy = true;
            else
               if(checkFreq == trailAtCloseOfBarM1 && newBarM1)
                  doTrailBuy = true;
               else
                  if(checkFreq == trailAtCloseOfBarChart && newBar)
                     doTrailBuy = true;
            if(doTrailBuy)
               TrailingForSequence(bIdx, p);
           }

         // SELL trailing
         if(sequences[sIdx].tradeCount > 0)
           {
            bool doTrailSell = false;
            bool sellIsTrend = (sequences[sIdx].strategyType == STRAT_TRENDING);
            enumTrailFrequency checkFreq = sequences[sIdx].lockProfitExec ?
                                           (sellIsTrend ? TrendTrailFrequency : TrailFrequency) :
                                           (sellIsTrend ? TrendLockProfitCheckFrequency : LockProfitCheckFrequency);
            if(checkFreq == trailEveryTick)
               doTrailSell = true;
            else
               if(checkFreq == trailAtCloseOfBarM1 && newBarM1)
                  doTrailSell = true;
               else
                  if(checkFreq == trailAtCloseOfBarChart && newBar)
                     doTrailSell = true;
            if(doTrailSell)
               TrailingForSequence(sIdx, p);
           }
         if(EnableZScoreExit && newBar)
           {
            // Close BUY sequence when Z-Score reverts above exit threshold (mean reversion complete)
            if(sequences[bIdx].tradeCount > 0 &&
               sequences[bIdx].strategyType == STRAT_MEAN_REVERSION)
              {
               if(activePairs[p].zScore >= Z_ExitThreshold)
                 {
                  if(EnableLogging)
                     Print("[ZExit] BUY closed for pair ", p,
                           " ", sym, " Z=", DoubleToString(activePairs[p].zScore, 2),
                           " crossed exit threshold ", DoubleToString(Z_ExitThreshold, 2));
                  AsyncCloseSequence(bIdx, "Z-Score Exit (Z=" + DoubleToString(activePairs[p].zScore, 2) + ")");
                 }
              }
            // Close SELL sequence when Z-Score reverts below negative exit threshold
            if(sequences[sIdx].tradeCount > 0 &&
               sequences[sIdx].strategyType == STRAT_MEAN_REVERSION)
              {
               if(activePairs[p].zScore <= -Z_ExitThreshold)
                 {
                  if(EnableLogging)
                     Print("[ZExit] SELL closed for pair ", p,
                           " ", sym, " Z=", DoubleToString(activePairs[p].zScore, 2),
                           " crossed exit threshold -", DoubleToString(Z_ExitThreshold, 2));
                  AsyncCloseSequence(sIdx, "Z-Score Exit (Z=" + DoubleToString(activePairs[p].zScore, 2) + ")");
                 }
              }
           }

         // === CORRELATION BREAKDOWN GUARD ===
         if(EnableCorrGuard && newBar &&
            (sequences[bIdx].tradeCount > 0 || sequences[sIdx].tradeCount > 0))
           {
            // Recalculate live correlation for this pair
            double liveCorr = CalcPearsonCorrelation(activePairs[p].symbolA, activePairs[p].symbolB);
            activePairs[p].correlation = liveCorr;  // update stored value
            if(MathAbs(liveCorr) < CorrBreakdownThreshold)
              {
               if(EnableLogging)
                  Print("[CorrGuard] Correlation breakdown for pair ", p,
                        " ", activePairs[p].symbolA, "/", activePairs[p].symbolB,
                        " |r|=", DoubleToString(MathAbs(liveCorr), 3),
                        " < ", DoubleToString(CorrBreakdownThreshold, 2));
               if(sequences[bIdx].tradeCount > 0)
                  AsyncCloseSequence(bIdx, "Corr Breakdown (r=" + DoubleToString(liveCorr, 3) + ")");
               if(sequences[sIdx].tradeCount > 0)
                  AsyncCloseSequence(sIdx, "Corr Breakdown (r=" + DoubleToString(liveCorr, 3) + ")");
              }
           }

         // ---- ENTRIES: Only on new bar + session open ----
         if(!newBar)
            continue;
         if(!anyStrategySessionOpen && sequences[bIdx].tradeCount == 0 && sequences[sIdx].tradeCount == 0)
             continue;
         if(!AllowNewSequence && sequences[bIdx].tradeCount == 0 && sequences[sIdx].tradeCount == 0)
            continue;
         bool allowNewStarts = activePairs[p].tradingEnabled;
         if(!allowNewStarts && sequences[bIdx].tradeCount == 0 && sequences[sIdx].tradeCount == 0)
            continue;
         if(blockingNews && NewsAction == newsActionPause &&
               sequences[bIdx].tradeCount == 0 && sequences[sIdx].tradeCount == 0)
             continue;
         if(maxDailyWinnersLosersHit)
            continue;

         double downCrossA = 0, upCrossA = 0, spreadA = 0, closeA = 0;
         int digitsA = 0;
         if(!ReadEntryBarPrices(symA, downCrossA, upCrossA, closeA, digitsA, spreadA))
            continue;
         double downCrossB = 0, upCrossB = 0, spreadB = 0, closeB = 0;
         int digitsB = 0;
         if(!ReadEntryBarPrices(symB, downCrossB, upCrossB, closeB, digitsB, spreadB))
            continue;
         string downPriceLabel = (EntryPriceType == entryOnTick) ? "low" : "close";
         string upPriceLabel = (EntryPriceType == entryOnTick) ? "high" : "close";

         int sellEntryLevelEighth = EntryMmLevel;
         int buyEntryLevelEighth = 8 - sellEntryLevelEighth;
         if(sellEntryLevelEighth < -2)
            sellEntryLevelEighth = -2;
         if(sellEntryLevelEighth > 10)
            sellEntryLevelEighth = 10;
         buyEntryLevelEighth = 8 - sellEntryLevelEighth;

         double mm88B = 0, mm48B = 0, mm08B = 0;
         double mmP28B = 0, mmP18B = 0, mmM18B = 0, mmM28B = 0;
         if(!CalcMurreyLevelsForSymbol(symB, mm88B, mm48B, mm08B, mmIncB, mmP28B, mmP18B, mmM18B, mmM28B))
            continue;

         // Strategy-specific Murrey snapshots for start conditions.
         double mrMm88A = activePairs[p].mm_88, mrMm08A = activePairs[p].mm_08, mrIncA = mmInc;
         double mrMmP28A = activePairs[p].mm_plus28, mrMmP18A = activePairs[p].mm_plus18;
         double mrMmM18A = activePairs[p].mm_minus18, mrMmM28A = activePairs[p].mm_minus28;
         double mrMm88B = mm88B, mrMm08B = mm08B, mrIncB = mmIncB;
         double mrMmP28B = mmP28B, mrMmP18B = mmP18B, mrMmM18B = mmM18B, mrMmM28B = mmM28B;
         ENUM_TIMEFRAMES mrTf = GetStrategyMMTimeframe(STRAT_MEAN_REVERSION);
         if(mrTf != (ENUM_TIMEFRAMES)MM_Timeframe)
           {
            double mrMm48A = 0.0, mrMm48B = 0.0;
            CalcMurreyLevelsForSymbolCustom(symA, mrTf, MM_Lookback, mrMm88A, mrMm48A, mrMm08A, mrIncA, mrMmP28A, mrMmP18A, mrMmM18A, mrMmM28A);
            CalcMurreyLevelsForSymbolCustom(symB, mrTf, MM_Lookback, mrMm88B, mrMm48B, mrMm08B, mrIncB, mrMmP28B, mrMmP18B, mrMmM18B, mrMmM28B);
           }

         double trMm88A = activePairs[p].mm_88, trMm08A = activePairs[p].mm_08, trIncA = mmInc;
         double trMm88B = mm88B, trMm08B = mm08B, trIncB = mmIncB;
         ENUM_TIMEFRAMES trTf = GetStrategyMMTimeframe(STRAT_TRENDING);
         if(trTf != (ENUM_TIMEFRAMES)MM_Timeframe)
           {
            double trMm48A = 0.0, trMm48B = 0.0;
            double trMmP28A = 0.0, trMmP18A = 0.0, trMmM18A = 0.0, trMmM28A = 0.0;
            double trMmP28B = 0.0, trMmP18B = 0.0, trMmM18B = 0.0, trMmM28B = 0.0;
            CalcMurreyLevelsForSymbolCustom(symA, trTf, MM_Lookback, trMm88A, trMm48A, trMm08A, trIncA, trMmP28A, trMmP18A, trMmM18A, trMmM28A);
            CalcMurreyLevelsForSymbolCustom(symB, trTf, MM_Lookback, trMm88B, trMm48B, trMm08B, trIncB, trMmP28B, trMmP18B, trMmM18B, trMmM28B);
           }
         if(mrIncA <= EPS && mrIncB <= EPS && trIncA <= EPS && trIncB <= EPS)
            continue;

         double buyEntryLevelPriceA = MmLevelByEighth(mrMm08A, mrIncA, buyEntryLevelEighth);
         double sellEntryLevelPriceA = MmLevelByEighth(mrMm08A, mrIncA, sellEntryLevelEighth);
         double buyEntryLevelPriceB = MmLevelByEighth(mrMm08B, mrIncB, buyEntryLevelEighth);
         double sellEntryLevelPriceB = MmLevelByEighth(mrMm08B, mrIncB, sellEntryLevelEighth);

         int trendSellLevelEighth = TrendEntryMmLevel;
         if(trendSellLevelEighth < -2)
            trendSellLevelEighth = -2;
         if(trendSellLevelEighth > 10)
            trendSellLevelEighth = 10;
         int trendBuyLevelEighth = 8 - trendSellLevelEighth;
         double trendBuyLevelPriceA = MmLevelByEighth(trMm08A, trIncA, trendBuyLevelEighth);
         double trendSellLevelPriceA = MmLevelByEighth(trMm08A, trIncA, trendSellLevelEighth);
         double trendBuyLevelPriceB = MmLevelByEighth(trMm08B, trIncB, trendBuyLevelEighth);
         double trendSellLevelPriceB = MmLevelByEighth(trMm08B, trIncB, trendSellLevelEighth);

         string buySym = GetSequenceTradeSymbol(bIdx, p);
         string sellSym = GetSequenceTradeSymbol(sIdx, p);
         if(StringLen(buySym) == 0)
            buySym = symA;
         if(StringLen(sellSym) == 0)
            sellSym = symA;
         double buyDownCross = 0, buyUpCross = 0, buySpread = 0, buyClose = 0;
         int buyDigits = 0;
         if(!ReadEntryBarPrices(buySym, buyDownCross, buyUpCross, buyClose, buyDigits, buySpread))
            continue;
         double sellDownCross = 0, sellUpCross = 0, sellSpread = 0, sellClose = 0;
         int sellDigits = 0;
         if(!ReadEntryBarPrices(sellSym, sellDownCross, sellUpCross, sellClose, sellDigits, sellSpread))
            continue;
         double maxSpreadPtsA = MaxSpreadPointsForSymbol(MaxSpreadPips, symA);
         double maxSpreadPtsB = MaxSpreadPointsForSymbol(MaxSpreadPips, symB);
         double maxSpreadPtsBuySym = MaxSpreadPointsForSymbol(MaxSpreadPips, buySym);
         double maxSpreadPtsSellSym = MaxSpreadPointsForSymbol(MaxSpreadPips, sellSym);

         bool routeMrBuy = EnableMeanReversion;
         bool routeTrendBuy = EnableTrendingStrategy;
         bool routeMrSell = EnableMeanReversion;
         bool routeTrendSell = EnableTrendingStrategy;

         // === TRENDING BUY ENTRY ===
         if(routeTrendBuy && trendSessionOpen && !buyStartedNow && allowNewStarts && CanOpenSide(SIDE_BUY) && sequences[bIdx].tradeCount == 0)
           {
            if(AllowNewTrendingSequences)
              {
               string trendBuySym = "";
               double trendBuyInc = 0, trendBuyCross = 0, trendBuyLevelPrice = 0;
               int trendBuyDigits = 0;
               double bestTrendBuyBreach = -1e10;

               bool aTrendBreak = (trIncA > EPS && upCrossA >= trendBuyLevelPriceA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA));
               bool bTrendBreak = (trIncB > EPS && upCrossB >= trendBuyLevelPriceB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB));
               bool aTrendRetest = (trIncA > EPS && upCrossA >= (trendBuyLevelPriceA + trIncA - EPS) && downCrossA <= trendBuyLevelPriceA);
               bool bTrendRetest = (trIncB > EPS && upCrossB >= (trendBuyLevelPriceB + trIncB - EPS) && downCrossB <= trendBuyLevelPriceB);
               double trendBlockThrA = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symA, STRAT_TRENDING);
               double trendBlockThrB = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symB, STRAT_TRENDING);
               bool aOk = ((TrendEntryType == trendEntryBreak) ? aTrendBreak : aTrendRetest) &&
                          (trendBlockThrA <= 0 || trIncA >= trendBlockThrA - EPS);
               bool bOk = ((TrendEntryType == trendEntryBreak) ? bTrendBreak : bTrendRetest) &&
                          (trendBlockThrB <= 0 || trIncB >= trendBlockThrB - EPS);

               if(aOk)
                 {
                  double breachA = trIncA > EPS ? (upCrossA - trendBuyLevelPriceA) / trIncA : 0;
                  if(breachA > bestTrendBuyBreach)
                    {
                     bestTrendBuyBreach = breachA;
                     trendBuySym = symA;
                     trendBuyInc = trIncA;
                     trendBuyCross = upCrossA;
                     trendBuyLevelPrice = trendBuyLevelPriceA;
                     trendBuyDigits = digitsA;
                    }
                 }
               if(bOk)
                 {
                  double breachB = trIncB > EPS ? (upCrossB - trendBuyLevelPriceB) / trIncB : 0;
                  if(breachB > bestTrendBuyBreach)
                    {
                     bestTrendBuyBreach = breachB;
                     trendBuySym = symB;
                     trendBuyInc = trIncB;
                     trendBuyCross = upCrossB;
                     trendBuyLevelPrice = trendBuyLevelPriceB;
                     trendBuyDigits = digitsB;
                    }
                 }

               if(StringLen(trendBuySym) > 0)
                 {
                  string markovTrendBuyReason = "";
                  if(!MarkovModeAllowsEntry(trendBuySym, SIDE_BUY, true, TrendingMarkovMode, markovTrendBuyReason))
                    {
                     if(EnableLogging)
                        Print("[MarkovFilter] TREND BUY blocked on ", trendBuySym,
                              " reason=", markovTrendBuyReason);
                     trendBuySym = "";
                    }
                 }

               if(StringLen(trendBuySym) > 0 && !IsTrendStrengthQualified(trendBuySym, SIDE_BUY))
                  trendBuySym = "";

               bool trendBuyOnCooldown = false;
               if(StringLen(trendBuySym) > 0 && CooldownBars > 0 && activePairs[p].lastBuySeqCloseTime > 0)
                 {
                  int barsSinceClose = iBarShift(trendBuySym, PERIOD_CURRENT, activePairs[p].lastBuySeqCloseTime);
                  if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                     trendBuyOnCooldown = true;
                 }

               if(StringLen(trendBuySym) > 0 && trendBuyOnCooldown)
                  trendBuySym = "";

               if(StringLen(trendBuySym) > 0 && HasDirectionalConflict(trendBuySym, ORDER_TYPE_BUY, p))
                  trendBuySym = "";

               if(StringLen(trendBuySym) > 0)
                 {
                  if(MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
                     trendBuySym = "";
                 }

               if(StringLen(trendBuySym) > 0)
                 {
                  if(EnableLogging)
                     Print("[TrendEntry] BUY ", trendBuySym, " level=", DoubleToString(trendBuyLevelPrice, trendBuyDigits),
                           " cross=", DoubleToString(trendBuyCross, trendBuyDigits));
                  sequences[bIdx].entryMmIncrement = trendBuyInc;
                  bool openedTrendBuy = OpenOrderWithContext(bIdx, ORDER_TYPE_BUY, trendBuySym, STRAT_TRENDING);
                  if(openedTrendBuy)
                    {
                     buyStartedNow = true;
                     if(MaxOpenSequences > 0)
                        openMrSequenceCount++;
                  }
                 }
              }
           }

         // === SNIPER BUY ENTRY (Mean Reversion) ===
         if(routeMrBuy && mrSessionOpen && !buyStartedNow && allowNewStarts && CanOpenSide(SIDE_BUY) && sequences[bIdx].tradeCount == 0)
           {
            if(!AllowNewMeanReversionSequences)
              {
               // Skip new MR starts if disabled
              }
            else
              {
               // Block checks are done per-candidate inside the breach loop below.
               double blockThrA = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symA, STRAT_MEAN_REVERSION);

               int liveBuyCount = CountPositionsByMagicSide(sequences[bIdx].magicNumber, symA, SIDE_BUY);
               if(symB != symA)
                  liveBuyCount += CountPositionsByMagicSide(sequences[bIdx].magicNumber, symB, SIDE_BUY);
               if(StringLen(sequences[bIdx].tradeSymbol) > 0 &&
                  sequences[bIdx].tradeSymbol != symA &&
                  sequences[bIdx].tradeSymbol != symB)
                  liveBuyCount += CountPositionsByMagicSide(sequences[bIdx].magicNumber, sequences[bIdx].tradeSymbol, SIDE_BUY);
               if(liveBuyCount > 0)
                 {
                  if(EnableLogging)
                     Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] BUY tradeCount=0 but live magic positions=", liveBuyCount,
                           " pair=", symA, "/", symB);
                 }
               else
                 {
                  string buyEntrySym = "";
                  double buyEntryInc = 0, buyEntryLevelPrice = 0, buyEntryCross = 0;
                  int buyEntryDigits = 0;
                  double buyEntryMM08 = 0, buyEntryMMm18 = 0, buyEntryMMm28 = 0;
                  double bestBuyBreach = -1e10;

                  bool zBuyPass = (!UseZScoreEntryFilter || activePairs[p].zScore <= Z_BuyThreshold);
                  if(zBuyPass)
                    {
                     // Candidate A
                     if(mrIncA > EPS && downCrossA <= buyEntryLevelPriceA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA))
                       {
                        // BLOCK CHECK A
                        bool blockedA = false;
                        if(blockThrA > 0 && mrIncA < blockThrA - EPS)
                           blockedA = true;

                        if(!blockedA)
                          {
                           double breachA = mrIncA > EPS ? (buyEntryLevelPriceA - downCrossA) / mrIncA : 0;
                           if(breachA > bestBuyBreach)
                             {
                              bestBuyBreach = breachA;
                              buyEntrySym = symA;
                              buyEntryInc = mrIncA;
                              buyEntryLevelPrice = buyEntryLevelPriceA;
                              buyEntryCross = downCrossA;
                              buyEntryDigits = digitsA;
                              buyEntryMM08 = mrMm08A;
                              buyEntryMMm18 = mrMmM18A;
                              buyEntryMMm28 = mrMmM28A;
                             }
                          }
                        else
                           if(EnableLogging)
                             {
                              // Print("[Block] BUY blocked on ", symA, " inc=", DoubleToString(mmInc, 5), " < min=", DoubleToString(blockThrA, 5));
                             }
                       }
                     // Candidate B
                     if(mrIncB > EPS && downCrossB <= buyEntryLevelPriceB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB))
                       {
                        // BLOCK CHECK B
                        bool blockedB = false;
                        double blockThrB = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symB, STRAT_MEAN_REVERSION);
                        if(blockThrB > 0 && mrIncB < blockThrB - EPS)
                           blockedB = true;

                        if(!blockedB)
                          {
                           double breachB = mrIncB > EPS ? (buyEntryLevelPriceB - downCrossB) / mrIncB : 0;
                           if(breachB > bestBuyBreach)
                             {
                              bestBuyBreach = breachB;
                              buyEntrySym = symB;
                              buyEntryInc = mrIncB;
                              buyEntryLevelPrice = buyEntryLevelPriceB;
                              buyEntryCross = downCrossB;
                              buyEntryDigits = digitsB;
                              buyEntryMM08 = mm08B;
                              buyEntryMMm18 = mmM18B;
                              buyEntryMMm28 = mmM28B;
                             }
                          }
                        else
                           if(EnableLogging)
                             {
                              // Print("[Block] BUY blocked on ", symB, " inc=", DoubleToString(mmIncB, 5), " < min=", DoubleToString(blockThrB, 5));
                             }
                       }
                    }

                  // Cooldown check uses candidate symbol to keep bar-count semantics consistent.
                  bool buyOnCooldown = false;
                  if(StringLen(buyEntrySym) > 0 && CooldownBars > 0 && activePairs[p].lastBuySeqCloseTime > 0)
                    {
                     int barsSinceClose = iBarShift(buyEntrySym, PERIOD_CURRENT, activePairs[p].lastBuySeqCloseTime);
                     if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                        buyOnCooldown = true;
                    }

                  if(!buyOnCooldown && StringLen(buyEntrySym) > 0)
                    {
                     string markovBuyReason = "";
                     if(!MarkovModeAllowsEntry(buyEntrySym, SIDE_BUY, false, MeanReversionMarkovMode, markovBuyReason))
                       {
                        if(EnableLogging)
                           Print("[MarkovFilter] BUY blocked on ", buyEntrySym,
                                 " reason=", markovBuyReason);
                        buyEntrySym = "";
                       }
                    }

                  if(!buyOnCooldown && StringLen(buyEntrySym) > 0 && !IsRangeStrengthQualified(buyEntrySym))
                    {
                     if(EnableLogging)
                        Print("[StrengthFilter] BUY MR blocked on ", buyEntrySym, " (not mid-matrix)");
                     buyEntrySym = "";
                    }

                  if(!buyOnCooldown && StringLen(buyEntrySym) > 0)
                    {
                     // Directional exposure check
                     if(HasDirectionalConflict(buyEntrySym, ORDER_TYPE_BUY, p))
                       {
                        if(EnableLogging)
                           Print("[Filter] BUY blocked on ", buyEntrySym, " - directional exposure conflict");
                       }
                     else
                       {
                        // EXPAND MODE Check
                        double expandThr = ResolveMinIncrementForStrategy(MrMinIncrementExpand_Pips, buyEntrySym, STRAT_MEAN_REVERSION);
                        if(expandThr > 0 && buyEntryInc < expandThr)
                          {
                           if(EnableLogging)
                              Print("[Expand] BUY grid on ", buyEntrySym,
                                    " natural=", DoubleToString(buyEntryInc, 5),
                                    " expanded=", DoubleToString(expandThr, 5));
                           buyEntryInc = expandThr;
                          }

                        // LP-vs-Murrey/EMA boundary filters (new sequence starts only)
                        if(IsLpBeyondMurreyBoundary(buyEntrySym, SIDE_BUY))
                          {
                           // Blocked by LP filter — logged inside helper
                          }
                        else
                           if(IsLpTradeIntoEmaBlocked(buyEntrySym, SIDE_BUY))
                             {
                              // Blocked by LP-EMA trade-into filter — logged inside helper
                             }
                        else
                          {
                           if(MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
                             {
                              if(EnableLogging && !loggedMaxOpenSeqBlock)
                                {
                                 Print("[SeqCap] MaxOpenSequences reached (", openMrSequenceCount, "/", MaxOpenSequences,
                                       "). Blocking new MR starts.");
                                 loggedMaxOpenSeqBlock = true;
                                }
                             }
                           else
                             {
                         if(EnableLogging)
                            Print("[Entry] SNIPER BUY: ", buyEntrySym,
                                  " Z=", DoubleToString(activePairs[p].zScore, 2),
                                  " ", downPriceLabel, "=", DoubleToString(buyEntryCross, buyEntryDigits),
                                  " mm", IntegerToString(buyEntryLevelEighth), "/8=", DoubleToString(buyEntryLevelPrice, buyEntryDigits));
                         // Freeze Murrey increment for this sequence (static grid)
                         sequences[bIdx].entryMmIncrement = buyEntryInc;
                         bool openedBuy = OpenOrderWithContext(bIdx, ORDER_TYPE_BUY, buyEntrySym, STRAT_MEAN_REVERSION);
                         if(openedBuy && MaxOpenSequences > 0)
                            openMrSequenceCount++;
                         // Snapshot entry-time Murrey levels for frozen sequence thresholds
                         activePairs[p].entry_mm_08 = buyEntryMM08;
                         activePairs[p].entry_mm_minus18 = buyEntryMMm18;
                         activePairs[p].entry_mm_minus28 = buyEntryMMm28;
                         if(EnableLogging)
                           {
                            Print("[SEQ_SNAPSHOT] BUY ", buyEntrySym,
                                  " mm08=", DoubleToString(activePairs[p].entry_mm_08, buyEntryDigits),
                                  " mm-1/8=", DoubleToString(activePairs[p].entry_mm_minus18, buyEntryDigits),
                                  " mm-2/8=", DoubleToString(activePairs[p].entry_mm_minus28, buyEntryDigits),
                                  " inc=", DoubleToString(sequences[bIdx].entryMmIncrement, buyEntryDigits));
                           }
                          }
                             }
                        }
                     }
                 }
               }
            }
                 // Grid step for existing BUY
            else
               if(sequences[bIdx].strategyType == STRAT_MEAN_REVERSION &&
                  sequences[bIdx].tradeCount > 0 && sequences[bIdx].tradeCount < MaxOrders)
                 {
                  if(!SequenceGridAddsAllowed(bIdx))
                    {
                     if(EnableLogging)
                        Print("[GridFreeze] BUY adds frozen due to hedge on magic=", sequences[bIdx].magicNumber);
                     continue;
                    }
                  int buyGridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
                  if(TimeCurrent() - sequences[bIdx].lastOpenTime > buyGridThrottleSec)
                    {
                     if(MaxSpreadPips > 0 && buySpread > maxSpreadPtsBuySym)
                       {
                        if(EnableLogging)
                           Print("[SpreadFilter] BUY add blocked on ", buySym,
                                 " spread=", DoubleToString(buySpread, 1));
                       }
                     else
                       {
                        // Next step using FROZEN mmIncrement (static grid)
                        double buyBaseInc = (buySym == symB ? mrIncB : mrIncA);
                        double frozenInc = sequences[bIdx].entryMmIncrement > EPS ? sequences[bIdx].entryMmIncrement : buyBaseInc;
                        
                        // Apply Minimum Increment Floor manually during grid expansion
                        double blockThr = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, buySym, STRAT_MEAN_REVERSION);
                        if(blockThr > 0 && frozenInc < blockThr)
                          {
                           if(EnableLogging) 
                              Print("[GridFloor] BUY ", buySym, " expanding grid step from ", DoubleToString(frozenInc, 5), " to ", DoubleToString(blockThr, 5));
                           frozenInc = blockThr;
                          }
                        if(frozenInc <= 0)
                          {
                           if(EnableLogging)
                              Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] BUY frozenInc<=0 on ", buySym);
                          }
                        else
                          {
                           double worstBuy = 0;
                           if(!GetWorstEntryByMagic(sequences[bIdx].magicNumber, buySym, SIDE_BUY, worstBuy))
                             {
                                if(EnableLogging)
                                   Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] BUY positions not found for tracked sequence on ", buySym);
                             }
                           else
                             {
                              double cumOff = GridCumulativeOffset(frozenInc, sequences[bIdx].tradeCount);
                              double stepOff = GridStepDistance(frozenInc, sequences[bIdx].tradeCount);
                              double nextLevel = 0;
                              bool useSnapshotAnchor = (activePairs[p].entry_mm_08 > 0);
                              if(useSnapshotAnchor)
                                {
                                 // Snapshot anchor sanity: if span to live worst entry is wildly inconsistent,
                                 // the anchor likely belongs to a different symbol/sequence after remap/restart.
                                 double observedSpan = activePairs[p].entry_mm_08 - worstBuy;
                                 double tol = MathMax(stepOff * 3.0, SymbolPointValue(buySym) * 20.0);
                                 if(observedSpan < -tol || observedSpan > (cumOff + tol * 3.0))
                                   {
                                    useSnapshotAnchor = false;
                                    if(EnableLogging)
                                       Print("[SEQ_SNAPSHOT_MISMATCH] BUY ", buySym,
                                             " anchor=", DoubleToString(activePairs[p].entry_mm_08, buyDigits),
                                             " worst=", DoubleToString(worstBuy, buyDigits),
                                             " observedSpan=", DoubleToString(observedSpan, buyDigits),
                                             " expectedCum=", DoubleToString(cumOff, buyDigits),
                                             " -> fallback to worst-entry grid");
                                    activePairs[p].entry_mm_08 = 0;
                                    activePairs[p].entry_mm_minus18 = 0;
                                    activePairs[p].entry_mm_minus28 = 0;
                                   }
                                }
                              if(useSnapshotAnchor)
                                 nextLevel = activePairs[p].entry_mm_08 - cumOff;
                              else
                                 nextLevel = worstBuy - stepOff;
                              if(nextLevel >= worstBuy - SymbolPointValue(buySym) * 0.1)
                                {
                                 if(EnableLogging)
                                    Print("[SEQ_GRID_GUARD] BUY blocked invalid nextLevel on ", buySym,
                                          " nextLevel=", DoubleToString(nextLevel, buyDigits),
                                          " worst=", DoubleToString(worstBuy, buyDigits));
                                 continue;
                                }
                              if(EnableLogging)
                                 Print("[GRID_LEVEL] BUY ", buySym,
                                       " count=", sequences[bIdx].tradeCount,
                                       " nextLevel=", DoubleToString(nextLevel, buyDigits),
                                       " ", downPriceLabel, "=", DoubleToString(buyDownCross, buyDigits),
                                       " entry_mm08=", DoubleToString(activePairs[p].entry_mm_08, 5),
                                       " frozenInc=", DoubleToString(frozenInc, 5),
                                       " entryMmInc=", DoubleToString(sequences[bIdx].entryMmIncrement, 5),
                                       " buyBaseInc=", DoubleToString(buyBaseInc, 5),
                                       " cumOff=", DoubleToString(cumOff, 5));
                              if(buyClose <= nextLevel)
                                {
                                 if(EnableLogging)
                                    Print("[Grid] BUY add #", sequences[bIdx].tradeCount + 1,
                                          " ", buySym, " close=", DoubleToString(buyClose, buyDigits),
                                          " NextLevel=", DoubleToString(nextLevel, buyDigits));
                                 OpenOrderWithContext(bIdx, ORDER_TYPE_BUY, buySym, sequences[bIdx].strategyType);
                                }
                             }
                          }
                       }
                    }
                 }
            else
               if(sequences[bIdx].strategyType == STRAT_TRENDING &&
                  sequences[bIdx].tradeCount > 0 && sequences[bIdx].tradeCount < MaxOrders)
                 {
                  int buyGridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
                  if(TimeCurrent() - sequences[bIdx].lastOpenTime > buyGridThrottleSec)
                    {
                     if(MaxSpreadPips > 0 && buySpread > maxSpreadPtsBuySym)
                        continue;
                     double trendInc = sequences[bIdx].entryMmIncrement > EPS ? sequences[bIdx].entryMmIncrement :
                                       (buySym == symB ? trIncB : trIncA);
                     double trendExpandThr = ResolveMinIncrementForStrategy(TrendMinIncrementExpand_Pips, buySym, STRAT_TRENDING);
                     if(trendExpandThr > 0 && trendInc < trendExpandThr)
                        trendInc = trendExpandThr;
                     if(trendInc <= 0)
                        continue;
                     double anchor = sequences[bIdx].avgPrice;
                     if(anchor <= 0)
                        continue;
                     int n = sequences[bIdx].tradeCount;
                     double requiredHigh = anchor + (2.0 * n * trendInc);
                     double retestLevel = anchor + ((2.0 * n - 1.0) * trendInc);
                     if(sequences[bIdx].highestPrice >= requiredHigh && buyClose <= retestLevel)
                       {
                        if(EnableLogging)
                           Print("[TrendScale] BUY add #", n + 1, " ", buySym,
                                 " high=", DoubleToString(sequences[bIdx].highestPrice, buyDigits),
                                 " retest=", DoubleToString(retestLevel, buyDigits));
                        OpenOrderWithContext(bIdx, ORDER_TYPE_BUY, buySym, STRAT_TRENDING);
                       }
                    }
                 }
         // === TRENDING SELL ENTRY ===
         if(routeTrendSell && trendSessionOpen && !sellStartedNow && allowNewStarts && CanOpenSide(SIDE_SELL) && sequences[sIdx].tradeCount == 0)
           {
            if(AllowNewTrendingSequences)
              {
               string trendSellSym = "";
               double trendSellInc = 0, trendSellCross = 0, trendSellLevelPrice = 0;
               int trendSellDigits = 0;
               double bestTrendSellBreach = -1e10;

               bool aTrendBreak = (trIncA > EPS && downCrossA <= trendSellLevelPriceA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA));
               bool bTrendBreak = (trIncB > EPS && downCrossB <= trendSellLevelPriceB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB));
               bool aTrendRetest = (trIncA > EPS && downCrossA <= (trendSellLevelPriceA - trIncA + EPS) && upCrossA >= trendSellLevelPriceA);
               bool bTrendRetest = (trIncB > EPS && downCrossB <= (trendSellLevelPriceB - trIncB + EPS) && upCrossB >= trendSellLevelPriceB);
               double trendBlockThrA = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symA, STRAT_TRENDING);
               double trendBlockThrB = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symB, STRAT_TRENDING);
               bool aOk = ((TrendEntryType == trendEntryBreak) ? aTrendBreak : aTrendRetest) &&
                          (trendBlockThrA <= 0 || trIncA >= trendBlockThrA - EPS);
               bool bOk = ((TrendEntryType == trendEntryBreak) ? bTrendBreak : bTrendRetest) &&
                          (trendBlockThrB <= 0 || trIncB >= trendBlockThrB - EPS);

               if(aOk)
                 {
                  double breachA = trIncA > EPS ? (trendSellLevelPriceA - downCrossA) / trIncA : 0;
                  if(breachA > bestTrendSellBreach)
                    {
                     bestTrendSellBreach = breachA;
                     trendSellSym = symA;
                     trendSellInc = trIncA;
                     trendSellCross = downCrossA;
                     trendSellLevelPrice = trendSellLevelPriceA;
                     trendSellDigits = digitsA;
                    }
                 }
               if(bOk)
                 {
                  double breachB = trIncB > EPS ? (trendSellLevelPriceB - downCrossB) / trIncB : 0;
                  if(breachB > bestTrendSellBreach)
                    {
                     bestTrendSellBreach = breachB;
                     trendSellSym = symB;
                     trendSellInc = trIncB;
                     trendSellCross = downCrossB;
                     trendSellLevelPrice = trendSellLevelPriceB;
                     trendSellDigits = digitsB;
                    }
                 }

               if(StringLen(trendSellSym) > 0)
                 {
                  string markovTrendSellReason = "";
                  if(!MarkovModeAllowsEntry(trendSellSym, SIDE_SELL, true, TrendingMarkovMode, markovTrendSellReason))
                    {
                     if(EnableLogging)
                        Print("[MarkovFilter] TREND SELL blocked on ", trendSellSym,
                              " reason=", markovTrendSellReason);
                     trendSellSym = "";
                    }
                 }

               if(StringLen(trendSellSym) > 0 && !IsTrendStrengthQualified(trendSellSym, SIDE_SELL))
                  trendSellSym = "";

               bool trendSellOnCooldown = false;
               if(StringLen(trendSellSym) > 0 && CooldownBars > 0 && activePairs[p].lastSellSeqCloseTime > 0)
                 {
                  int barsSinceClose = iBarShift(trendSellSym, PERIOD_CURRENT, activePairs[p].lastSellSeqCloseTime);
                  if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                     trendSellOnCooldown = true;
                 }

               if(StringLen(trendSellSym) > 0 && trendSellOnCooldown)
                  trendSellSym = "";

               if(StringLen(trendSellSym) > 0 && HasDirectionalConflict(trendSellSym, ORDER_TYPE_SELL, p))
                  trendSellSym = "";

               if(StringLen(trendSellSym) > 0)
                 {
                  if(MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
                     trendSellSym = "";
                 }

               if(StringLen(trendSellSym) > 0)
                 {
                  if(EnableLogging)
                     Print("[TrendEntry] SELL ", trendSellSym, " level=", DoubleToString(trendSellLevelPrice, trendSellDigits),
                           " cross=", DoubleToString(trendSellCross, trendSellDigits));
                  sequences[sIdx].entryMmIncrement = trendSellInc;
                  bool openedTrendSell = OpenOrderWithContext(sIdx, ORDER_TYPE_SELL, trendSellSym, STRAT_TRENDING);
                  if(openedTrendSell)
                    {
                     sellStartedNow = true;
                     if(MaxOpenSequences > 0)
                        openMrSequenceCount++;
                    }
                 }
              }
           }

         // === SNIPER SELL ENTRY (Mean Reversion) ===
         if(routeMrSell && mrSessionOpen && !sellStartedNow && allowNewStarts && CanOpenSide(SIDE_SELL) && sequences[sIdx].tradeCount == 0)
           {
            if(!AllowNewMeanReversionSequences)
              {
               // Skip
              }
            else
              {
               int liveSellCount = CountPositionsByMagicSide(sequences[sIdx].magicNumber, symA, SIDE_SELL);
               if(symB != symA)
                  liveSellCount += CountPositionsByMagicSide(sequences[sIdx].magicNumber, symB, SIDE_SELL);
               if(StringLen(sequences[sIdx].tradeSymbol) > 0 &&
                  sequences[sIdx].tradeSymbol != symA &&
                  sequences[sIdx].tradeSymbol != symB)
                  liveSellCount += CountPositionsByMagicSide(sequences[sIdx].magicNumber, sequences[sIdx].tradeSymbol, SIDE_SELL);
               if(liveSellCount > 0)
                 {
                  if(EnableLogging)
                     Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] SELL tradeCount=0 but live magic positions=", liveSellCount,
                           " pair=", symA, "/", symB);
                 }
               else
                 {
                  string sellEntrySym = "";
                  double sellEntryInc = 0, sellEntryLevelPrice = 0, sellEntryCross = 0;
                  int sellEntryDigits = 0;
                  double sellEntryMM88 = 0, sellEntryMMp18 = 0, sellEntryMMp28 = 0;
                  double bestSellBreach = -1e10;

                  bool zSellPass = (!UseZScoreEntryFilter || activePairs[p].zScore >= Z_SellThreshold);
                  if(zSellPass)
                    {
                     // Candidate A
                     if(mrIncA > EPS && upCrossA >= sellEntryLevelPriceA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA))
                       {
                        // BLOCK CHECK A
                        bool blockedA = false;
                        double blockThrA = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symA, STRAT_MEAN_REVERSION);
                        if(blockThrA > 0 && mrIncA < blockThrA - EPS)
                           blockedA = true;

                        if(!blockedA)
                          {
                           double breachA = mrIncA > EPS ? (upCrossA - sellEntryLevelPriceA) / mrIncA : 0;
                           if(breachA > bestSellBreach)
                             {
                              bestSellBreach = breachA;
                              sellEntrySym = symA;
                              sellEntryInc = mrIncA;
                              sellEntryLevelPrice = sellEntryLevelPriceA;
                              sellEntryCross = upCrossA;
                              sellEntryDigits = digitsA;
                              sellEntryMM88 = mrMm88A;
                              sellEntryMMp18 = mrMmP18A;
                              sellEntryMMp28 = mrMmP28A;
                             }
                          }
                       }
                     // Candidate B
                     if(mrIncB > EPS && upCrossB >= sellEntryLevelPriceB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB))
                       {
                        // BLOCK CHECK B
                        bool blockedB = false;
                        double blockThrB = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symB, STRAT_MEAN_REVERSION);
                        if(blockThrB > 0 && mrIncB < blockThrB - EPS)
                           blockedB = true;

                        if(!blockedB)
                          {
                           double breachB = mrIncB > EPS ? (upCrossB - sellEntryLevelPriceB) / mrIncB : 0;
                           if(breachB > bestSellBreach)
                             {
                              bestSellBreach = breachB;
                              sellEntrySym = symB;
                              sellEntryInc = mrIncB;
                              sellEntryLevelPrice = sellEntryLevelPriceB;
                              sellEntryCross = upCrossB;
                              sellEntryDigits = digitsB;
                              sellEntryMM88 = mm88B;
                              sellEntryMMp18 = mmP18B;
                              sellEntryMMp28 = mmP28B;
                             }
                          }
                       }
                    }

                  bool sellOnCooldown = false;
                  if(StringLen(sellEntrySym) > 0 && CooldownBars > 0 && activePairs[p].lastSellSeqCloseTime > 0)
                    {
                     int barsSinceClose = iBarShift(sellEntrySym, PERIOD_CURRENT, activePairs[p].lastSellSeqCloseTime);
                     if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                        sellOnCooldown = true;
                    }

                  if(!sellOnCooldown && StringLen(sellEntrySym) > 0)
                    {
                     string markovSellReason = "";
                     if(!MarkovModeAllowsEntry(sellEntrySym, SIDE_SELL, false, MeanReversionMarkovMode, markovSellReason))
                       {
                        if(EnableLogging)
                           Print("[MarkovFilter] SELL blocked on ", sellEntrySym,
                                 " reason=", markovSellReason);
                        sellEntrySym = "";
                       }
                    }

                  if(!sellOnCooldown && StringLen(sellEntrySym) > 0 && !IsRangeStrengthQualified(sellEntrySym))
                    {
                     if(EnableLogging)
                        Print("[StrengthFilter] SELL MR blocked on ", sellEntrySym, " (not mid-matrix)");
                     sellEntrySym = "";
                    }

                  if(!sellOnCooldown && StringLen(sellEntrySym) > 0)
                    {
                     // Directional exposure check
                     if(HasDirectionalConflict(sellEntrySym, ORDER_TYPE_SELL, p))
                       {
                        if(EnableLogging)
                           Print("[Filter] SELL blocked on ", sellEntrySym, " - directional exposure conflict");
                       }
                     else
                       {
                        // EXPAND MODE Check
                        double expandThr = ResolveMinIncrementForStrategy(MrMinIncrementExpand_Pips, sellEntrySym, STRAT_MEAN_REVERSION);
                        if(expandThr > 0 && sellEntryInc < expandThr)
                          {
                           if(EnableLogging)
                              Print("[Expand] SELL grid on ", sellEntrySym,
                                    " natural=", DoubleToString(sellEntryInc, 5),
                                    " expanded=", DoubleToString(expandThr, 5));
                           sellEntryInc = expandThr;
                          }

                        // LP-vs-Murrey/EMA boundary filters (new sequence starts only)
                        if(IsLpBeyondMurreyBoundary(sellEntrySym, SIDE_SELL))
                          {
                           // Blocked by LP filter — logged inside helper
                          }
                        else
                           if(IsLpTradeIntoEmaBlocked(sellEntrySym, SIDE_SELL))
                             {
                              // Blocked by LP-EMA trade-into filter — logged inside helper
                             }
                        else
                          {
                           if(MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
                             {
                              if(EnableLogging && !loggedMaxOpenSeqBlock)
                                {
                                 Print("[SeqCap] MaxOpenSequences reached (", openMrSequenceCount, "/", MaxOpenSequences,
                                       "). Blocking new MR starts.");
                                 loggedMaxOpenSeqBlock = true;
                                }
                             }
                           else
                             {
                            if(EnableLogging)
                            Print("[Entry] SNIPER SELL: ", sellEntrySym,
                                  " Z=", DoubleToString(activePairs[p].zScore, 2),
                                  " ", upPriceLabel, "=", DoubleToString(sellEntryCross, sellEntryDigits),
                                  " mm", IntegerToString(sellEntryLevelEighth), "/8=", DoubleToString(sellEntryLevelPrice, sellEntryDigits));
                         // Freeze Murrey increment for this sequence (static grid)
                         sequences[sIdx].entryMmIncrement = sellEntryInc;
                         bool openedSell = OpenOrderWithContext(sIdx, ORDER_TYPE_SELL, sellEntrySym, STRAT_MEAN_REVERSION);
                         if(openedSell && MaxOpenSequences > 0)
                            openMrSequenceCount++;
                         // Snapshot entry-time Murrey levels for frozen sequence thresholds
                         activePairs[p].entry_mm_88 = sellEntryMM88;
                         activePairs[p].entry_mm_plus18 = sellEntryMMp18;
                         activePairs[p].entry_mm_plus28 = sellEntryMMp28;
                         if(EnableLogging)
                           {
                            Print("[SEQ_SNAPSHOT] SELL ", sellEntrySym,
                                  " mm88=", DoubleToString(activePairs[p].entry_mm_88, sellEntryDigits),
                                  " mm+1/8=", DoubleToString(activePairs[p].entry_mm_plus18, sellEntryDigits),
                                  " mm+2/8=", DoubleToString(activePairs[p].entry_mm_plus28, sellEntryDigits),
                                  " inc=", DoubleToString(sequences[sIdx].entryMmIncrement, sellEntryDigits));
                           }
                          }
                             }
                        }
                    }
                 }
              }
           }
               // Grid step for existing SELL
            else
               if(sequences[sIdx].strategyType == STRAT_MEAN_REVERSION &&
                  sequences[sIdx].tradeCount > 0 && sequences[sIdx].tradeCount < MaxOrders)
                 {
                  if(!SequenceGridAddsAllowed(sIdx))
                    {
                     if(EnableLogging)
                        Print("[GridFreeze] SELL adds frozen due to hedge on magic=", sequences[sIdx].magicNumber);
                     continue;
                    }
                  int sellGridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
                  if(EnableLogging)
                     Print("[SELL_GRID_ENTRY] pair=", p, " sTC=", sequences[sIdx].tradeCount,
                           " lastOpen=", sequences[sIdx].lastOpenTime,
                           " throttle=", sellGridThrottleSec,
                           " diff=", (TimeCurrent() - sequences[sIdx].lastOpenTime));
                  if(TimeCurrent() - sequences[sIdx].lastOpenTime > sellGridThrottleSec)
                    {
                     if(EnableLogging)
                        Print("[SELL_GRID_THROTTLE_OK] spread=", DoubleToString(sellSpread,1),
                              " max=", DoubleToString(maxSpreadPtsSellSym,1));
                     if(MaxSpreadPips > 0 && sellSpread > maxSpreadPtsSellSym)
                       {
                        if(EnableLogging)
                           Print("[SpreadFilter] SELL add blocked on ", sellSym,
                                 " spread=", DoubleToString(sellSpread, 1));
                       }
                     else
                       {
                        double sellBaseInc = (sellSym == symB ? mrIncB : mrIncA);
                        double frozenInc = sequences[sIdx].entryMmIncrement > EPS ? sequences[sIdx].entryMmIncrement : sellBaseInc;
                        
                        // Apply Minimum Increment Floor manually during grid expansion
                        double blockThr = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, sellSym, STRAT_MEAN_REVERSION);
                        if(blockThr > 0 && frozenInc < blockThr)
                          {
                           if(EnableLogging) 
                              Print("[GridFloor] SELL ", sellSym, " expanding grid step from ", DoubleToString(frozenInc, 5), " to ", DoubleToString(blockThr, 5));
                           frozenInc = blockThr;
                          }
                        if(frozenInc <= 0)
                          {
                           if(EnableLogging)
                              Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] SELL frozenInc<=0 on ", sellSym);
                          }
                        else
                          {
                           double worstSell = 0;
                           if(!GetWorstEntryByMagic(sequences[sIdx].magicNumber, sellSym, SIDE_SELL, worstSell))
                             {
                                if(EnableLogging)
                                   Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] SELL positions not found for tracked sequence on ", sellSym);
                             }
                           else
                             {
                              double cumOff = GridCumulativeOffset(frozenInc, sequences[sIdx].tradeCount);
                              double stepOff = GridStepDistance(frozenInc, sequences[sIdx].tradeCount);
                              double nextLevel = 0;
                              bool useSnapshotAnchor = (activePairs[p].entry_mm_88 > 0);
                              if(useSnapshotAnchor)
                                {
                                 double observedSpan = worstSell - activePairs[p].entry_mm_88;
                                 double tol = MathMax(stepOff * 3.0, SymbolPointValue(sellSym) * 20.0);
                                 if(observedSpan < -tol || observedSpan > (cumOff + tol * 3.0))
                                   {
                                    useSnapshotAnchor = false;
                                    if(EnableLogging)
                                       Print("[SEQ_SNAPSHOT_MISMATCH] SELL ", sellSym,
                                             " anchor=", DoubleToString(activePairs[p].entry_mm_88, sellDigits),
                                             " worst=", DoubleToString(worstSell, sellDigits),
                                             " observedSpan=", DoubleToString(observedSpan, sellDigits),
                                             " expectedCum=", DoubleToString(cumOff, sellDigits),
                                             " -> fallback to worst-entry grid");
                                    activePairs[p].entry_mm_88 = 0;
                                    activePairs[p].entry_mm_plus18 = 0;
                                    activePairs[p].entry_mm_plus28 = 0;
                                   }
                                }
                              if(useSnapshotAnchor)
                                 nextLevel = activePairs[p].entry_mm_88 + cumOff;
                              else
                                 nextLevel = worstSell + stepOff;
                              if(nextLevel <= worstSell + SymbolPointValue(sellSym) * 0.1)
                                {
                                 if(EnableLogging)
                                    Print("[SEQ_GRID_GUARD] SELL blocked invalid nextLevel on ", sellSym,
                                          " nextLevel=", DoubleToString(nextLevel, sellDigits),
                                          " worst=", DoubleToString(worstSell, sellDigits));
                                 continue;
                                }
                              if(EnableLogging)
                                 Print("[GRID_LEVEL] SELL ", sellSym,
                                       " count=", sequences[sIdx].tradeCount,
                                       " nextLevel=", DoubleToString(nextLevel, sellDigits),
                                       " ", upPriceLabel, "=", DoubleToString(sellUpCross, sellDigits));
                              if(sellClose >= nextLevel)
                                {
                                 if(EnableLogging)
                                    Print("[Grid] SELL add #", sequences[sIdx].tradeCount + 1,
                                          " ", sellSym, " close=", DoubleToString(sellClose, sellDigits),
                                          " NextLevel=", DoubleToString(nextLevel, sellDigits));
                                 OpenOrderWithContext(sIdx, ORDER_TYPE_SELL, sellSym, sequences[sIdx].strategyType);
                                }
                             }
                          }
                       }
                    }
                 }
            else
               if(sequences[sIdx].strategyType == STRAT_TRENDING &&
                  sequences[sIdx].tradeCount > 0 && sequences[sIdx].tradeCount < MaxOrders)
                 {
                  int sellGridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
                  if(TimeCurrent() - sequences[sIdx].lastOpenTime > sellGridThrottleSec)
                    {
                     if(MaxSpreadPips > 0 && sellSpread > maxSpreadPtsSellSym)
                        continue;
                     double trendInc = sequences[sIdx].entryMmIncrement > EPS ? sequences[sIdx].entryMmIncrement :
                                       (sellSym == symB ? trIncB : trIncA);
                     double trendExpandThr = ResolveMinIncrementForStrategy(TrendMinIncrementExpand_Pips, sellSym, STRAT_TRENDING);
                     if(trendExpandThr > 0 && trendInc < trendExpandThr)
                        trendInc = trendExpandThr;
                     if(trendInc <= 0)
                        continue;
                     double anchor = sequences[sIdx].avgPrice;
                     if(anchor <= 0)
                        continue;
                     int n = sequences[sIdx].tradeCount;
                     double requiredLow = anchor - (2.0 * n * trendInc);
                     double retestLevel = anchor - ((2.0 * n - 1.0) * trendInc);
                     if(sequences[sIdx].lowestPrice <= requiredLow && sellClose >= retestLevel)
                       {
                        if(EnableLogging)
                           Print("[TrendScale] SELL add #", n + 1, " ", sellSym,
                                 " low=", DoubleToString(sequences[sIdx].lowestPrice, sellDigits),
                                 " retest=", DoubleToString(retestLevel, sellDigits));
                        OpenOrderWithContext(sIdx, ORDER_TYPE_SELL, sellSym, STRAT_TRENDING);
                       }
                    }
                 }
            // === COOLDOWN: Track sequence close times ===
            if(sequences[bIdx].prevTradeCount > 0 && sequences[bIdx].tradeCount == 0)
              {
               if(CooldownBars > 0)
                  activePairs[p].lastBuySeqCloseTime = CurTime;
               activePairs[p].entry_mm_08 = 0;
               activePairs[p].entry_mm_minus18 = 0;
               activePairs[p].entry_mm_minus28 = 0;
               sequences[bIdx].tradeSymbol = "";
              }
            if(sequences[sIdx].prevTradeCount > 0 && sequences[sIdx].tradeCount == 0)
              {
               if(CooldownBars > 0)
                  activePairs[p].lastSellSeqCloseTime = CurTime;
               activePairs[p].entry_mm_88 = 0;
               activePairs[p].entry_mm_plus18 = 0;
               activePairs[p].entry_mm_plus28 = 0;
               sequences[sIdx].tradeSymbol = "";
              }
          } // end pair loop
        } // end efficiency gate

      // === GLOBAL LOCK PROFIT MODE ($) ===
      if(LockProfitMode == lpGlobal && GlobalLockProfitAmount > 0 && TotalPositions() > 0)
        {
         double totalPl = TotalPlOpen();
         if(totalPl > globalPlHigh)
            globalPlHigh = totalPl;
         if(!globalLockProfitExec)
           {
            if(totalPl >= GlobalLockProfitAmount)
              {
               globalLockProfitExec = true;
               if(EnableLogging)
                  Print("[GlobalLock] Activated! Net P/L: ", DoubleToString(totalPl, 2));
              }
           }
         if(globalLockProfitExec && GlobalTrailingAmount > 0)
           {
            if(totalPl <= globalPlHigh - GlobalTrailingAmount)
              {
               AsyncCloseAll("Global Lock Profit Trail Hit (Peak: " + DoubleToString(globalPlHigh, 2) +
                        " Current: " + DoubleToString(totalPl, 2) + ")");
               globalLockProfitExec = false;
               globalPlHigh = 0;
              }
           }
        }

      // === GLOBAL LOCK PROFIT MODE (Pips) ===
      if(LockProfitMode == lpGlobalPips && GlobalLockProfitPips != 0 && TotalPositions() > 0)
        {
         double totalPips = GetTotalPipsProfit();
         if(totalPips > globalPipsHigh)
            globalPipsHigh = totalPips;

         double triggerPips = ResolvePipsOrATR(GlobalLockProfitPips, _Symbol); // Use base symbol for trigger resolution
         if(!globalPipsLockExec)
           {
            if(totalPips >= triggerPips)
              {
               globalPipsLockExec = true;
               if(EnableLogging)
                  Print("[GlobalPipsLock] Activated! Net Pips: ", DoubleToString(totalPips, 1),
                        " (Trigger: ", DoubleToString(triggerPips, 1), ")");
              }
           }
         if(globalPipsLockExec && GlobalTrailingPips != 0)
           {
            double trailPips = ResolvePipsOrATR(GlobalTrailingPips, _Symbol);
            if(totalPips <= globalPipsHigh - trailPips)
              {
               AsyncCloseAll("Global Pips Lock Profit Trail Hit (Peak: " + DoubleToString(globalPipsHigh, 1) +
                        " Current: " + DoubleToString(totalPips, 1) + ")");
               globalPipsLockExec = false;
               globalPipsHigh = 0;
              }
           }
        }

      // Reset global locks when no positions
      if(TotalPositions() == 0)
        {
         globalLockProfitExec = false;
         globalPlHigh = 0;
         globalPipsLockExec = false;
         globalPipsHigh = 0;
        }

      // Session end actions per strategy (new starts are already gated above).
      if(!mrSessionOpen && GetStrategySessionEndAction(STRAT_MEAN_REVERSION) == CLOSE_ALL && TotalPositions() > 0)
         CloseSequencesByStrategy(STRAT_MEAN_REVERSION, "MR Session End");
      if(!trendSessionOpen && GetStrategySessionEndAction(STRAT_TRENDING) == CLOSE_ALL && TotalPositions() > 0)
         CloseSequencesByStrategy(STRAT_TRENDING, "Trend Session End");

      // Dashboard: refresh values every second, reusing existing objects (no full teardown).
      if(firstTickSinceInit || CurTime != lastDashboardRefresh)
        {
         DrawDashboard();
         lastDashboardRefresh = CurTime;
         firstTickSinceInit = false;
        }
      
      if(bNeedsRedraw)
        {
         ChartRedraw(0);
         bNeedsRedraw = false;
        }
     }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  CHART EVENTS (Dashboard Buttons)                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(TotalManagedPositions() > 0)
        {
         ScanPositions();
         UpdateLockProfitChartLines();
        }
      DrawDashboard();
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   // Handle section toggles
   if(sparam == EAName + "_sectgl_sym")
     {
      showSymbols = !showSymbols;
      DrawDashboard();
      return;
     }
   if(sparam == EAName + "_sectgl_evt")
     {
      showEvents = !showEvents;
      DrawDashboard();
      return;
     }

   if(StringFind(sparam, EAName + "_symgoto_") == 0)
     {
      for(int i = 0; i < numSymbols; i++)
        {
         if(sparam != EAName + "_symgoto_" + IntegerToString(i))
            continue;
         string symbol = allSymbols[i];
         string curChartSymbol = ChartSymbol(0);
         ENUM_TIMEFRAMES curChartPeriod = (ENUM_TIMEFRAMES)ChartPeriod(0);
         if(!SymbolsEqual(curChartSymbol, symbol) || curChartPeriod != (ENUM_TIMEFRAMES)_Period)
            ChartSetSymbolPeriod(0, symbol, (ENUM_TIMEFRAMES)_Period);
         if(TotalManagedPositions() > 0)
           {
            ScanPositions();
            UpdateLockProfitChartLines();
           }
         DrawDashboard();
         return;
        }
     }
   if(sparam == EAName + "_close_all")
     {
      ScanPositions();
      AsyncCloseAll("Dashboard Close All");
      DrawDashboard();
      return;
     }
   if(sparam == EAName + "_entry_mode")
     {
      dashboardButtonStrategy = (dashboardButtonStrategy == STRAT_MEAN_REVERSION) ? STRAT_TRENDING : STRAT_MEAN_REVERSION;
      DrawDashboard();
      return;
     }
   if(sparam == EAName + "_close_profit")
     {
      ScanPositions();
      CloseSequencesByNetSign(true);
      DrawDashboard();
      return;
     }
   if(sparam == EAName + "_close_loss")
     {
      ScanPositions();
      CloseSequencesByNetSign(false);
      DrawDashboard();
      return;
     }
   if(sparam == EAName + "_restart_now")
     {
      hard_stop = false;
      stopReason = "";
      restartTime = 0;
      time_wait_restart = false;
      maxDailyWinnersLosersHit = false;
      if(EnableLogging)
         Print("[Dashboard] Manual restart requested");
      DrawDashboard();
      return;
     }
   if(StringFind(sparam, EAName + "_btn_") != 0)
      return;

   for(int i = 0; i < numSymbols; i++)
     {
      string buyBtn = EAName + "_btn_" + IntegerToString(i) + "_buy";
      string sellBtn = EAName + "_btn_" + IntegerToString(i) + "_sell";
      int side = -1;
      if(sparam == buyBtn)
         side = SIDE_BUY;
      else
         if(sparam == sellBtn)
            side = SIDE_SELL;
      if(side < 0)
         continue;

      string symbol = allSymbols[i];
      bool hasOpen = HasOpenSequenceForSymbolSide(symbol, side);
      if(hasOpen)
        {
         CloseAllSequencesForSymbolSide(symbol, side, "Dashboard " + (side == SIDE_BUY ? "BUY" : "SELL") + " Close");
        }
      else
        {
         int seqIdx = FindStartSequenceForSymbolSide(symbol, side);
         if(seqIdx < 0)
           {
            // Dashboard override: bypass pair-gating, find ANY empty sequence slot
            for(int s = 0; s < MAX_PAIRS * 2; s++)
              {
               if(sequences[s].tradeCount == 0 && !SequenceHasLiveManagedPositions(s))
                 {
                  seqIdx = s;
                  break;
                 }
              }
           }
         if(seqIdx < 0)
           {
            if(EnableLogging)
               Print("[DASH_BTN] No available sequence slot for ", symbol, " side=", (side == SIDE_BUY ? "BUY" : "SELL"));
           }
         else
           {
            ENUM_ORDER_TYPE orderType = (side == SIDE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            ENUM_STRATEGY_TYPE strat = dashboardButtonStrategy;
            if(sequences[seqIdx].magicNumber <= 0)
               sequences[seqIdx].magicNumber = AllocateUnusedSequenceMagic();
            sequences[seqIdx].side = side;  // ensure side matches button click
            dashboardManualOverrideOpenRisk = true;
            bool opened = OpenOrderWithContext(seqIdx, orderType, symbol, strat);
            dashboardManualOverrideOpenRisk = false;
            if(!opened && EnableLogging)
               Print("[DASH_BTN] Start failed on ", symbol, " side=", (side == SIDE_BUY ? "BUY" : "SELL"));
           }
        }

     DrawDashboard();
     break;
    }
  }

//+------------------------------------------------------------------+
int FindHoldTrackerIndex(const ulong positionId, ulong &positionIds[])
  {
   for(int i = 0; i < ArraySize(positionIds); i++)
     {
      if(positionIds[i] == positionId)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|  Build hold-time stats from deal history (seconds)              |
//|  Also derives activity stats (closed positions/day and /month)  |
//+------------------------------------------------------------------+
int ComputeHoldTimeStats(double &avgHoldSecOut, double &maxHoldSecOut,
                         double &daysSpanOut, double &monthsSpanOut,
                         double &closedPerDayOut, double &closedPerMonthOut)
  {
   avgHoldSecOut = 0.0;
   maxHoldSecOut = 0.0;
   daysSpanOut = 0.0;
    monthsSpanOut = 0.0;
   closedPerDayOut = 0.0;
   closedPerMonthOut = 0.0;
   if(!HistorySelect(0, TimeCurrent()))
      return 0;

   ulong posIds[];
   double netVol[];
   datetime firstInTime[];
   bool isOpen[];

   double totalHold = 0.0;
   int closedCount = 0;
   datetime firstDealTime = 0;
   datetime lastDealTime = 0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(positionId == 0)
         continue;

      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType != DEAL_ENTRY_IN && entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT)
         continue;

      double vol = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      if(vol <= 0.0)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(firstDealTime == 0 || dealTime < firstDealTime)
         firstDealTime = dealTime;
      if(lastDealTime == 0 || dealTime > lastDealTime)
         lastDealTime = dealTime;
      int idx = FindHoldTrackerIndex(positionId, posIds);
      if(idx < 0)
        {
         idx = ArraySize(posIds);
         ArrayResize(posIds, idx + 1);
         ArrayResize(netVol, idx + 1);
         ArrayResize(firstInTime, idx + 1);
         ArrayResize(isOpen, idx + 1);
         posIds[idx] = positionId;
         netVol[idx] = 0.0;
         firstInTime[idx] = 0;
         isOpen[idx] = false;
        }

      if(entryType == DEAL_ENTRY_IN || entryType == DEAL_ENTRY_INOUT)
        {
         if(!isOpen[idx] || netVol[idx] <= 1e-10)
           {
            firstInTime[idx] = dealTime;
            isOpen[idx] = true;
            netVol[idx] = 0.0;
           }
         netVol[idx] += vol;
        }

      if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_INOUT)
        {
         if(!isOpen[idx])
            continue;
         netVol[idx] -= vol;
         if(netVol[idx] <= 1e-10)
           {
            double holdSec = (double)(dealTime - firstInTime[idx]);
            if(holdSec < 0.0)
               holdSec = 0.0;
            totalHold += holdSec;
            closedCount++;
            if(holdSec > maxHoldSecOut)
               maxHoldSecOut = holdSec;
            netVol[idx] = 0.0;
            isOpen[idx] = false;
            firstInTime[idx] = 0;
           }
        }
     }

   if(closedCount > 0)
      avgHoldSecOut = totalHold / (double)closedCount;
   if(firstDealTime > 0 && lastDealTime > firstDealTime)
      daysSpanOut = (double)(lastDealTime - firstDealTime) / 86400.0;
   if(daysSpanOut < 1.0)
      daysSpanOut = 1.0;
   monthsSpanOut = daysSpanOut / 30.0;
   if(monthsSpanOut < (1.0 / 30.0))
      monthsSpanOut = (1.0 / 30.0);
   closedPerDayOut = (double)closedCount / daysSpanOut;
   closedPerMonthOut = (double)closedCount / monthsSpanOut;
   return closedCount;
  }

//+------------------------------------------------------------------+
//|  Custom optimization score for MT5 tester                        |
//|  Zero score if profit<=0 or PF<1                                 |
//|  Higher: profit, PF, recovery factor                             |
//|  Lower: average/max hold time                                    |
//|  Activity: reward more trades up to ~2/day, penalize <4/month    |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit = TesterStatistics(STAT_PROFIT);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   if(profit <= 0.0 || pf < 1.0 || !MathIsValidNumber(profit) || !MathIsValidNumber(pf))
      return 0.0;

   double rf = TesterStatistics(STAT_RECOVERY_FACTOR);
   if(!MathIsValidNumber(rf) || rf < 0.0)
      rf = 0.0;

   double avgHoldSec = 0.0, maxHoldSec = 0.0;
   double daysSpan = 0.0, monthsSpan = 0.0, closedPerDay = 0.0, closedPerMonth = 0.0;
   int closedCount = ComputeHoldTimeStats(avgHoldSec, maxHoldSec, daysSpan, monthsSpan,
                                          closedPerDay, closedPerMonth);
   double avgHoldHours = avgHoldSec / 3600.0;
   double maxHoldHours = maxHoldSec / 3600.0;

   // Profit component is logarithmic to avoid large-balance domination.
   double profitTerm = MathLog(1.0 + profit);
   double pfTerm = MathMin(5.0, pf);
   double rfTerm = MathMin(10.0, rf);

   // Penalize longer holding durations (both average and worst case).
   double holdPenalty = 1.0 / (1.0 + (avgHoldHours / 24.0) + (maxHoldHours / 168.0));
   if(holdPenalty < 0.0)
      holdPenalty = 0.0;

   // Activity component:
   // - fewer than ~4 closed positions per month gets penalized
   // - more activity helps up to ~2/day, then only slight diminishing boost
   double minMonthly = 4.0;
   double targetDaily = 2.0;
   double monthlyFactor = 1.0;
   if(closedPerMonth < minMonthly)
     {
      double ratio = closedPerMonth / minMonthly;
      if(ratio < 0.0)
         ratio = 0.0;
      monthlyFactor = ratio;
     }
   double dailyFactor = 0.0;
   if(closedPerDay <= targetDaily)
      dailyFactor = MathSqrt(MathMax(0.0, closedPerDay / targetDaily)); // diminishing rise to 1.0
   else
     {
      double excessRatio = (closedPerDay - targetDaily) / targetDaily;
      // Very mild extra reward above target, capped hard.
      dailyFactor = 1.0 + 0.10 * MathMin(1.0, MathLog(1.0 + excessRatio) / MathLog(3.0));
     }
   if(closedCount <= 0)
      dailyFactor = 0.0;

   // Composite: higher PF/RF/profit improve score; higher hold times reduce it.
   double qualityTerm = pfTerm * (1.0 + 0.20 * rfTerm);
   double activityTerm = monthlyFactor * dailyFactor;
   double score = profitTerm * qualityTerm * holdPenalty * activityTerm;
   if(!MathIsValidNumber(score) || score < 0.0)
      return 0.0;
   return score;
  }

//+------------------------------------------------------------------+
