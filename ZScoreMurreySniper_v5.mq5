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
enum enumTrendAddMode { trendAddProfitRetest=0, trendAddAdverseAveraging=1, trendAddBoth=2 };
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
enum ENUM_DECISION_MODE { decisionLegacyParity=0, decisionRankedDeterministic=1 };
enum ENUM_STRATEGY_TIEBREAK { stratTrendFirst=0, stratMrFirst=1 };
enum ENUM_SIDE_TIEBREAK { sideBuyFirst=0, sideSellFirst=1 };

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
struct ActivePair
  {
   string            symbolA;
   string            symbolB;
   double            score;            // scanner ranking score (mode-dependent)
   bool              active;
   bool              tradingEnabled;  // false if pair dropped out but has open trades
   bool              recoveryManagedOnly; // true only for managed-only recovery slots
   // Murrey levels (live, recalculated every bar)
   double            mm_88, mm_48, mm_08, mmIncrement, mmIncrementB;
   double            mm_plus28, mm_plus18, mm_minus18, mm_minus28;
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
   datetime          trendBreachTimeBuy;
   datetime          trendBreachTimeSell;
   double            trendBreachPriceBuy;
   double            trendBreachPriceSell;
  };

struct CorrPair
  {
   int               idxA;
   int               idxB;
   double            absR;
   double            r;
   double            score;
  };

struct TickPositionRow
  {
   ulong             ticket;
   long              positionId;
   string            symbol;
   long              magic;
   long              type;
   string            comment;
   double            volume;
   double            openPrice;
   double            profit;
   double            swap;
   double            commission;
   double            sl;
  };


// Include modular headers AFTER all enums/structs/constants are defined
#include "Sniper_SequenceManager.mqh"
#include "Sniper_Math.mqh"
// Temporary compatibility bridge for legacy grid module.
#define sequences g_seqMgr.m_sequences
#include "Sniper_Grid.mqh"
#undef sequences
#include "Sniper_UI.mqh"
#include "Sniper_Markov.mqh"
#include "Sniper_Strategy.mqh"
input group "~~~~~~~~~General Settings~~~~~~~~~";
input long    MAGIC_NUMBER = 20250215;             // Magic Number
input group "#### Scanner & Symbol Selection ####";
input string  Trade_Symbols = "EURUSD,GBPUSD,AUDUSD,NZDUSD,USDJPY,USDCAD,USDCHF,EURJPY,GBPJPY,EURGBP"; // Symbols
input int     Max_Active_Symbols = 3;               // Max Active Symbols (Portfolio)
input int     Scanner_IntervalHours = 4;            // Rescan Interval (hours)
input bool    UseCurrencyStrengthMatrix = false;    // Use Currency Strength Matrix
input enumTf  StrengthTimeframe = tfD1;             // Strength Timeframe
input int     StrengthLookbackBars = 5;             // Strength Lookback (bars on StrengthTimeframe)
input double  StrengthExtremePercent = 25.0;        // Strongest/Weakest Percent (0-100)
input ENUM_DECISION_MODE DecisionMode = decisionLegacyParity; // Legacy parity or ranked deterministic
input ENUM_STRATEGY_TIEBREAK StrategyTieBreak = stratTrendFirst; // Strategy priority when capped
input ENUM_SIDE_TIEBREAK SideTieBreak = sideBuyFirst; // Side priority when capped
input int     MaxStartsPerBar = 0;                   // Max sequence starts per bar (0=off)
input int     MaxAddsPerBar = 0;                     // Max grid adds per bar (0=off)

input group "#### Mean Reversion Strategy ####";
input bool    EnableMeanReversion = true;           // Enable Mean Reversion
input bool    AllowNewMeanReversionSequences = true; // Allow New MR Sequences
input enumMarkovMode MeanReversionMarkovMode = markovModeOff; // MR Markov Mode (Off/Directional/Trending/Ranging)
input enumTf  MrMM_Timeframe = tfH1;                // MR Murrey Timeframe
input int     MrMM_Lookback = 96;                  // MR Murrey Lookback
input int     EntryMmLevel = 8;                     // MR Entry MM Level for Sell (-2..10, Buy mirrors as 8-level)
input enumRangeMetric MrRangeMetric = rangeAtr;     // MR Dynamic Range Source
input double  MrMinIncrementBlock_Pips = 0;         // MR Min Increment to Block (0=off, neg=ATR/Keltner mult)
input double  MrMinIncrementExpand_Pips = 0;        // MR Min Increment to Expand (0=off, neg=ATR/Keltner mult)
input string  MrSessionStartTime = "00:00";         // MR Session Start
input string  MrSessionEndTime = "23:59";           // MR Session End
input ENUM_SESSION_END MrSessionEndAction = NO_TRADES_FOR_NEW_CYCLE; // MR End Action
input double  MrLotSize = 0.01;                     // MR Base Lot Size
input double  MrLotMultiplier = 1.0;                // MR Lot Multiplier
input double  MrMaxLots = 1.0;                      // MR Max Lots Per Order
input double  MrRiskPercent = 0;                    // MR Risk % (0=use MrLotSize)
input double  LockProfitTriggerPips = 0;            // MR Lock Profit Trigger (pips, neg=ATR/Keltner mult)
input double  TrailingStop = 5.0;                   // MR Trailing Stop (pips, neg=ATR/Keltner mult)
input int     LockProfitMinTrades = 0;              // MR Min Trades for Lock Profit
input enumTrailFrequency LockProfitCheckFrequency = trailEveryTick; // MR Lock Trigger Check Frequency
input enumTrailFrequency TrailFrequency = trailEveryTick; // MR Trailing SL Update Frequency

input group "#### Trending Strategy ####";
input bool    EnableTrendingStrategy = false;       // Enable Trending Strategy
input bool    AllowNewTrendingSequences = true;     // Allow New Trending Sequences
input enumMarkovMode TrendingMarkovMode = markovModeOff; // Trend Markov Mode (Off/Directional/Trending/Ranging)
input enumTrendEntryType TrendEntryType = trendEntryBreakRetest; // Trending Entry Type
input enumTrendAddMode TrendAddMode = trendAddProfitRetest; // Trend Add Mode
input int     TrendEntryMmLevel = 2;                // Trending Entry MM Level for Sell (-2..10, Buy mirrors)
input enumTf  TrendMM_Timeframe = tfH1;             // Trend Murrey Timeframe
input int     TrendMM_Lookback = 96;                // Trend Murrey Lookback
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
input double  TrendLockProfitTriggerPips = 0;       // Trend Lock Profit Trigger (pips, neg=ATR/Keltner mult)
input double  TrendTrailingStop = 5.0;              // Trend Trailing Stop (pips, neg=ATR/Keltner mult)
input int     Trend_RetestWindow_Bars = 60;          // Retest Window (Bars)
input int     TrendLockProfitMinTrades = 0;         // Trend Min Trades for Lock Profit
input enumTrailFrequency TrendLockProfitCheckFrequency = trailEveryTick; // Trend Lock Trigger Check Frequency
input enumTrailFrequency TrendTrailFrequency = trailEveryTick; // Trend Trailing SL Update Frequency

input group "#### Grid & Sequence Management ####";
input int     MaxOrders = 20;                       // Max Grid Orders
input bool    BlockOppositeSideStarts = true;       // Block opposite-side sequence starts on same symbol
input int     GridAddThrottleSeconds = 10;          // Min seconds between grid adds per sequence
input double  StopLoss = 0;                         // Stop Loss (pips, neg=ATR/Keltner mult, 0=off)
input double  GridIncrementExponent = 1.0;           // Grid Increment Exponent (1.0=linear)
input int     CooldownBars = 0;                      // Cooldown (bars after seq close, 0=off)
input double  MaxLossPerSequence = 0;                // Max Loss Per Sequence $ (0=off)
input int     MaxOpenSequences = 0;                 // Max Concurrent Open Sequences (0=off)
input int     MaxSequencesPerDay = 0;                // Max Sequences/Day (0=off)
input int     MaxDailyWinners = 0;                   // Max Daily Winners (0=off)
input int     MaxDailyLosers = 0;                    // Max Daily Losers (0=off)
input enumRestart MaxSequencesRestartEa = restartNextDay; // Restart After Max

//input group "#### MM Levels ####";
const enumEntryPriceType EntryPriceType = entryOnTick; // Entry Source (Close/Tick)

input group "#### Range Settings ####";
input enumTf  ATRtimeframe = tfH1;                  // ATR Timeframe
input int     AtrPeriod = 14;                       // ATR Period
input enumRangeMetric RangeMetric = rangeAtr;       // Dynamic Range Source for negative multipliers
input enumTf  KeltnerTimeframe = tfH1;              // Keltner ATR Timeframe
input int     KeltnerEmaPeriod = 20;                // Keltner EMA Period (centerline)
input int     KeltnerAtrPeriod = 20;                // Keltner ATR Period
input double  KeltnerAtrMultiplier = 1.5;           // Keltner ATR Multiplier (band half-width)
const int     EMA_FilterPeriod = 0;                 // EMA Filter Period (0=off)
const enumTf  EMA_FilterTimeframe = tfH1;           // EMA Filter Timeframe

input group "#### Markov Regime Filter ####";
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

input group "#### LP-vs-Murrey Filter ####";
input enumTf  LP_MM_Timeframe = tfH4;                 // LP Filter: Murrey Timeframe
input int     LP_MM_Lookback = 0;                    // LP Filter: Murrey Lookback (0=off)
input int     LP_MM_BoundaryEighth = 0;               // LP Filter: Boundary N/8 from 8/8 (neg=inward)
input bool    UseLpEmaTradeIntoFilter = false;        // LP Filter: Block trades that cross 20/50/200 EMA on M1/M5/M15/H1/H4/D1

input group "#### News Filter ####";
input bool    UseHighImpactNewsFilter = true;        // Use News Filter
input int     HoursBeforeNewsToStop = 2;             // Hours Before News
input int     HoursAfterNewsToStart = 1;             // Hours After News
input int     MinutesBeforeNewsNoTransactions = 5;   // Min Before (no transactions)
input int     MinutesAfterNewsNoTransactions = 5;    // Min After (no transactions)
input bool    UsdAffectsAllPairs = true;             // USD Affects All
input enumNewsAction NewsAction = newsActionManage;  // News Action
input bool    NewsInvert = false;                    // Invert News Filter
input string  NewsInfo = "[Backtesting hardcoded to GMT+2/+3 with US DST]"; // [Info]

input group "#### Global Protections & Session ####";
input string  SessionStartTime = "00:00";           // Session Start
input string  SessionEndTime = "23:59";             // Session End
input ENUM_SESSION_END SessionEndAction = NO_TRADES_FOR_NEW_CYCLE; // End Action
input ENUM_SESSION_DIR Direction = DIR_BOTH;         // Direction
input bool    UsePipValueLotNormalization = true;   // Normalize lot size by pip-value ratio across symbols
input string  PipValueReferenceSymbol = "EURUSD";   // Reference symbol for pip-value normalization
input bool    NormalizeLotsPerStrategy = true;      // Apply pip normalization to MR/Trend lots
input enumLockProfitMode LockProfitMode = lpPerSequence; // Lock Profit Scope
input double  GlobalLockProfitAmount = 0;            // Global Lock: $ Threshold (0=off)
input double  GlobalTrailingAmount = 0;              // Global Lock: $ Trail From Peak
input double  GlobalLockProfitPips = 0;              // Global Lock: Pips Threshold (0=off)
input double  GlobalTrailingPips = 0;                // Global Lock: Pips Trail From Peak
input enumGlobalEpType GlobalEpType = globalEpAbsolute; // Equity Stop Type
input double  GlobalEquityStop = 0;                  // Global Equity Stop (0=off)
input double  UltimateTargetBalance = 0;             // Ultimate Target (0=off)
input double  ProfitCloseEquityAmount = 0;           // Daily Profit Target (0=off)
input enumRestart RestartEaAfterLoss = restartNextDay; // Restart After Loss
input string  TimeOfRestart_Equity = "01:00";        // Restart Time
input int     RestartInHours = 0;                    // Restart In Hours
input double  RescueDrawdownThreshold = 0;           // Rescue DD Threshold $ (0=off)
input double  RescueNetProfitTarget = 0;             // Rescue Net Profit Target $

input group "#### Weekend Closure ####";
input bool    CloseAllTradesDisableEA = false;       // Close All Friday
input int     DayToClose = 5;                        // Day To Close (5=Fri)
input string  TimeToClose = "20:00";                 // Time To Close
input bool    RestartEA_AfterFridayClose = true;     // Restart After Weekend
input int     DayToRestart = 1;                      // Day To Restart (1=Mon)
input string  TimeToRestart = "01:00";               // Time To Restart

input group "#### General & Appearance ####";
input bool    EnableLogging = true;                 // Enable Logging
input double  MaxSpreadPips = 3.0;                  // Max Spread (pips, 0=off)
input bool    ShowDashboard = true;                  // Show Panel
input ENUM_STRATEGY_TYPE DashboardButtonStrategyDefault = STRAT_MEAN_REVERSION; // Dashboard Buy/Sell open strategy
const int     X_Axis = 10;                           // X Position
const int     Y_Axis = 30;                           // Y Position
input enumVisualTheme VisualTheme = themeDark;       // Dashboard/Chart Theme
const int     DashboardWidthPx = 820;                // Fixed Dashboard Width
const int     DashboardHeightPx = 520;               // Fixed Dashboard Height
const bool    DashboardAutoHeight = true;            // Auto height by content/news
const int     DashboardMinHeightPx = 100;            // Min height when auto
input bool    EnablePerfTiming = false;              // Log internal timing metrics (tester)
input int     PerfLogEveryNBars = 50;                // Timing log cadence (bars)

input group "#### Legacy Inputs ####";
input bool    AllowNewSequence = true;              // Global gate for opening brand-new sequences
input double  LotSize = 0.01;                       // [Legacy] Base Lot Size
input double  LotSizeExponent = 1.0;                // [Legacy] Lot Multiplier
input double  MaxLots = 1.0;                        // [Legacy] Max Lots Per Order
input double  RiskPercent = 0;                      // [Legacy] Risk % (0=use LotSize)
input double  MinIncrementBlock_Pips = 0;            // [Legacy] Min Increment to Block (0=off, neg=ATR/Keltner mult)
input double  MinIncrementExpand_Pips = 0;           // [Legacy] Min Increment to Expand (0=off, neg=ATR/Keltner mult)

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
//|  NEWS DATA INCLUDE                                               |
//+------------------------------------------------------------------+
// --- Performance Cache ---
int      g_cachedTotalManagedPositions = 0;
int      g_cachedActiveManagedSequences = 0;
uint     g_lastDashboardUpdate         = 0;
uint     g_lastChartLinesUpdate        = 0;
int      g_lastPositionsTotal          = 0;
datetime g_lastMmBarTime[MAX_PAIRS];
// Symbol Tick Cache
string   g_tickCacheSymbols[MAX_SYMBOLS + 50];
MqlTick  g_tickCacheTicks[MAX_SYMBOLS + 50];
int      g_tickCacheCount = 0;
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
CSequenceManager g_seqMgr;
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

// Equity series for R² curve-quality score in OnTester (populated each new bar, tester only)
double   g_equitySeries[];
int      g_equityCount = 0;

struct SymFloatingEquity
  {
   string symbol;
   int trades;
   double closedProfit;
   double grossProfit;
   double grossLoss;
   double peakEquity;
   double maxDrawdown;
   double equitySamples[]; 
   int    sampleCount;
  };
SymFloatingEquity g_symEquityTracker[];
int g_symEquityTrackerCount = 0;
int g_symEquityLastDealsTotal = 0;

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
string   pendingOrderComment = "ZSM-MR";  // Set before OpenOrder to tag position comments
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
CMeanReversionStrategy g_mrStrategy;
CTrendStrategy g_trendStrategy;

// Murrey memoization cache (per symbol/timeframe/lookback/bar)
string   murreyCacheSymbol[];
ENUM_TIMEFRAMES murreyCacheTf[];
int      murreyCacheLookback[];
datetime murreyCacheBarTime[];
double   murreyCacheMm88[];
double   murreyCacheMm48[];
double   murreyCacheMm08[];
double   murreyCacheInc[];
double   murreyCacheP28[];
double   murreyCacheP18[];
double   murreyCacheM18[];
double   murreyCacheM28[];

// Open-position commission cache by POSITION_IDENTIFIER
#define COMMISSION_CACHE_SIZE 8192
long     commissionCachePosId[COMMISSION_CACHE_SIZE];
double   commissionCacheValue[COMMISSION_CACHE_SIZE];
bool     commissionCacheUsed[COMMISSION_CACHE_SIZE];

// Per-tick position snapshot (reduces repeated terminal queries within a tick).
TickPositionRow tickPosRows[];
datetime tickPosSnapshotTime = 0;
// Sequence magic lookup cache.
long     seqMagicCacheMagic[];
int      seqMagicCacheSeqIdx[];
bool     seqMagicCacheDirty = true;
// Performance counters.
ulong    perfScanUsAcc = 0;
ulong    perfPairUsAcc = 0;
ulong    perfMarkovUsAcc = 0;
int      perfBarsCount = 0;

//+------------------------------------------------------------------+
//|  HELPER FUNCTIONS                                                |
//+------------------------------------------------------------------+
int SeqIdx(int pairIdx, int side) { return pairIdx * 2 + side; }

bool EvaluateTrendStart(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
  {
   reasonOut = "delegated_on_tick";
   return false;
  }

bool EvaluateMrStart(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
  {
   reasonOut = "delegated_on_tick";
   return false;
  }

bool ManageMrGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
  {
   reasonOut = "delegated_on_tick";
   return false;
  }

bool ManageTrendGrid(const int pairIdx, const ENUM_ORDER_DIRECTION dir, string &reasonOut)
  {
   reasonOut = "delegated_on_tick";
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMagicInUseAnywhere(long magic)
  {
   if(magic <= 0)
      return true;
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(g_seqMgr.m_sequences[i].magicNumber == magic)
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

void ResetCommissionCache()
  {
   for(int i = 0; i < COMMISSION_CACHE_SIZE; i++)
      commissionCacheUsed[i] = false;
  }

int CommissionCacheIndex(const long positionId)
  {
   if(positionId <= 0)
      return -1;
   uint h = (uint)positionId;
   int idx = (int)(h % COMMISSION_CACHE_SIZE);
   for(int probe = 0; probe < COMMISSION_CACHE_SIZE; probe++)
     {
      int s = (idx + probe) % COMMISSION_CACHE_SIZE;
      if(!commissionCacheUsed[s] || commissionCachePosId[s] == positionId)
         return s;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetOpenPositionCommission(long positionId)
  {
   if(positionId <= 0)
      return 0.0;

   int slot = CommissionCacheIndex(positionId);
   if(slot >= 0 && commissionCacheUsed[slot] && commissionCachePosId[slot] == positionId)
      return commissionCacheValue[slot];

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
   if(slot >= 0)
     {
      commissionCachePosId[slot] = positionId;
      commissionCacheValue[slot] = commission;
      commissionCacheUsed[slot] = true;
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
   int ext = (int)MathRound(strengthCcyCount * StrengthExtremePercent / 100.0);
   if(ext < 1) ext = 1;
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
   int ext = (int)MathRound(strengthCcyCount * StrengthExtremePercent / 100.0);
   if(ext < 1) ext = 1;
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
      if(mode == markovModeTrending || mode == markovModeRanging)
         return false;
      return !Markov_BlockIfUntrained;
     }
   if(!valid)
     {
      reasonOut = "n_low";
      if(mode == markovModeTrending || mode == markovModeRanging)
         return false;
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
         bool trendBiasDown = (st == MARKOV_DOWNTREND && conf >= dynamicConfReq &&
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
         bool trendBiasUp = (st == MARKOV_UPTREND && conf >= dynamicConfReq &&
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
   if(StringLen(g_seqMgr.m_sequences[seqIdx].tradeSymbol) > 0)
      return g_seqMgr.m_sequences[seqIdx].tradeSymbol;
   return activePairs[pairIdx].symbolA;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ClearTickCache() { g_tickCacheCount = 0; }
bool GetCachedTick(string symbol, MqlTick &tick)
  {
   for(int i = 0; i < g_tickCacheCount; i++)
     {
      if(g_tickCacheSymbols[i] == symbol)
        {
         tick = g_tickCacheTicks[i];
         return true;
        }
     }
   if(SymbolInfoTick(symbol, tick))
     {
      if(g_tickCacheCount < MAX_SYMBOLS + 50)
        {
         g_tickCacheSymbols[g_tickCacheCount] = symbol;
         g_tickCacheTicks[g_tickCacheCount] = tick;
         g_tickCacheCount++;
        }
      return true;
     }
   return false;
  }

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

int FindMurreyCacheIndex(const string symbol, const ENUM_TIMEFRAMES tf, const int lookback, const datetime barTime)
  {
   for(int i = 0; i < ArraySize(murreyCacheSymbol); i++)
     {
      if(murreyCacheSymbol[i] == symbol &&
         murreyCacheTf[i] == tf &&
         murreyCacheLookback[i] == lookback &&
         murreyCacheBarTime[i] == barTime)
         return i;
     }
   return -1;
  }

void ClearMurreyMemoCache()
  {
   ArrayResize(murreyCacheSymbol, 0);
   ArrayResize(murreyCacheTf, 0);
   ArrayResize(murreyCacheLookback, 0);
   ArrayResize(murreyCacheBarTime, 0);
   ArrayResize(murreyCacheMm88, 0);
   ArrayResize(murreyCacheMm48, 0);
   ArrayResize(murreyCacheMm08, 0);
   ArrayResize(murreyCacheInc, 0);
   ArrayResize(murreyCacheP28, 0);
   ArrayResize(murreyCacheP18, 0);
   ArrayResize(murreyCacheM18, 0);
   ArrayResize(murreyCacheM28, 0);
  }

bool CachedCalcMurreyLevelsForSymbolCustom(const string symbol, const ENUM_TIMEFRAMES tf, const int lookback,
                                           double &mm88, double &mm48, double &mm08, double &inc,
                                           double &p28, double &p18, double &m18, double &m28)
  {
   datetime barTime = iTime(symbol, tf, 1);
   if(barTime <= 0)
      return CalcMurreyLevelsForSymbolCustom(symbol, tf, lookback, mm88, mm48, mm08, inc, p28, p18, m18, m28);

   int idx = FindMurreyCacheIndex(symbol, tf, lookback, barTime);
   if(idx >= 0)
     {
      mm88 = murreyCacheMm88[idx];
      mm48 = murreyCacheMm48[idx];
      mm08 = murreyCacheMm08[idx];
      inc = murreyCacheInc[idx];
      p28 = murreyCacheP28[idx];
      p18 = murreyCacheP18[idx];
      m18 = murreyCacheM18[idx];
      m28 = murreyCacheM28[idx];
      return true;
     }

   if(!CalcMurreyLevelsForSymbolCustom(symbol, tf, lookback, mm88, mm48, mm08, inc, p28, p18, m18, m28))
      return false;

   int n = ArraySize(murreyCacheSymbol);
   ArrayResize(murreyCacheSymbol, n + 1);
   ArrayResize(murreyCacheTf, n + 1);
   ArrayResize(murreyCacheLookback, n + 1);
   ArrayResize(murreyCacheBarTime, n + 1);
   ArrayResize(murreyCacheMm88, n + 1);
   ArrayResize(murreyCacheMm48, n + 1);
   ArrayResize(murreyCacheMm08, n + 1);
   ArrayResize(murreyCacheInc, n + 1);
   ArrayResize(murreyCacheP28, n + 1);
   ArrayResize(murreyCacheP18, n + 1);
   ArrayResize(murreyCacheM18, n + 1);
   ArrayResize(murreyCacheM28, n + 1);

   murreyCacheSymbol[n] = symbol;
   murreyCacheTf[n] = tf;
   murreyCacheLookback[n] = lookback;
   murreyCacheBarTime[n] = barTime;
   murreyCacheMm88[n] = mm88;
   murreyCacheMm48[n] = mm48;
   murreyCacheMm08[n] = mm08;
   murreyCacheInc[n] = inc;
   murreyCacheP28[n] = p28;
   murreyCacheP18[n] = p18;
   murreyCacheM18[n] = m18;
   murreyCacheM28[n] = m28;
   return true;
  }

bool CachedCalcMurreyLevelsForSymbol(const string symbol,
                                     double &mm88, double &mm48, double &mm08, double &inc,
                                     double &p28, double &p18, double &m18, double &m28)
  {
   // Fallback uses MR settings if strategy-specific context is missing
   return CachedCalcMurreyLevelsForSymbolCustom(symbol,
                                                (ENUM_TIMEFRAMES)MrMM_Timeframe,
                                                MrMM_Lookback,
                                                mm88, mm48, mm08, inc, p28, p18, m18, m28);
  }

bool MarkovUpdateUniqueOncePerBar(const string symbol, string &updatedSymbols[])
  {
   if(StringLen(symbol) == 0)
      return false;
   for(int i = 0; i < ArraySize(updatedSymbols); i++)
     {
      if(updatedSymbols[i] == symbol)
         return true;
     }
   int n = ArraySize(updatedSymbols);
   ArrayResize(updatedSymbols, n + 1);
   updatedSymbols[n] = symbol;
   return MarkovUpdateSymbol(symbol);
  }

void MaybeUpdateLockProfitChartLines()
  {
   if(IsTester && !IsVisual)
      return;
   if(GetTickCount() - g_lastChartLinesUpdate < 1000 && !newBar)
      return;
   UpdateLockProfitChartLines();
   g_lastChartLinesUpdate = GetTickCount();
  }

void MaybeDrawDashboard()
  {
   if(IsTester && !IsVisual)
      return;
   if(GetTickCount() - g_lastDashboardUpdate < 1000 && !newBar)
      return;
   DrawDashboard();
   g_lastDashboardUpdate = GetTickCount();
  }

void InvalidateTickPositionSnapshot()
  {
   tickPosSnapshotTime = 0;
   ArrayResize(tickPosRows, 0);
  }

void RefreshTickPositionSnapshot(const bool forceRefresh=false)
  {
   datetime snapTime = TimeCurrent();
   if(!forceRefresh && tickPosSnapshotTime == snapTime)
      return;

   ArrayResize(tickPosRows, 0);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      int n = ArraySize(tickPosRows);
      ArrayResize(tickPosRows, n + 1);
      tickPosRows[n].ticket = ticket;
      tickPosRows[n].positionId = PositionGetInteger(POSITION_IDENTIFIER);
      tickPosRows[n].symbol = PositionGetString(POSITION_SYMBOL);
      tickPosRows[n].magic = PositionGetInteger(POSITION_MAGIC);
      tickPosRows[n].type = PositionGetInteger(POSITION_TYPE);
      tickPosRows[n].comment = PositionGetString(POSITION_COMMENT);
      tickPosRows[n].volume = PositionGetDouble(POSITION_VOLUME);
      tickPosRows[n].openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      tickPosRows[n].profit = PositionGetDouble(POSITION_PROFIT);
      tickPosRows[n].swap = PositionGetDouble(POSITION_SWAP);
      tickPosRows[n].commission = GetOpenPositionCommission(tickPosRows[n].positionId);
      tickPosRows[n].sl = PositionGetDouble(POSITION_SL);
     }
   tickPosSnapshotTime = snapTime;
  }

void MarkSequenceMagicCacheDirty()
  {
   seqMagicCacheDirty = true;
  }

void RebuildSequenceMagicCache()
  {
   ArrayResize(seqMagicCacheMagic, 0);
   ArrayResize(seqMagicCacheSeqIdx, 0);
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      long mg = g_seqMgr.m_sequences[i].magicNumber;
      if(mg <= 0)
         continue;
      int n = ArraySize(seqMagicCacheMagic);
      ArrayResize(seqMagicCacheMagic, n + 1);
      ArrayResize(seqMagicCacheSeqIdx, n + 1);
      seqMagicCacheMagic[n] = mg;
      seqMagicCacheSeqIdx[n] = i;
     }
   seqMagicCacheDirty = false;
  }

ulong PerfNowUs()
  {
   return GetMicrosecondCount();
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
      if(g_seqMgr.m_sequences[i].tradeCount <= 0)
         continue;
      bool isTrend = (g_seqMgr.m_sequences[i].strategyType == STRAT_TRENDING);
      enumTrailFrequency freq = g_seqMgr.m_sequences[i].lockProfitExec ?
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
   return g_seqMgr.NeedsReconstruct(seqIdx, pairIdx, activePairs[pairIdx]);
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
    MqlTick tick;
    if(!GetCachedTick(symbol, tick))
       return false;
    double bidLocal = tick.bid;
    double askLocal = tick.ask;
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
   if(!CachedCalcMurreyLevelsForSymbolCustom(symbol, (ENUM_TIMEFRAMES)LP_MM_Timeframe, LP_MM_Lookback,
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

         if(g_seqMgr.m_sequences[sIdx].tradeCount > 0)
           {
            // Use the actual symbol this sequence is trading.
            // Falling back to symbolA misclassifies exposure when the entry was on symbolB.
            string pSym = g_seqMgr.m_sequences[sIdx].tradeSymbol;
            if(StringLen(pSym) == 0)
               pSym = activePairs[p].symbolA;

            if(StringLen(pSym) < 6)
               continue;

            string pB = GetBaseCurrency(pSym);
            string pQ = GetQuoteCurrency(pSym);

            // Existing directions for this active sequence
            int pBDir = (g_seqMgr.m_sequences[sIdx].side == SIDE_BUY) ? 1 : -1;
            int pQDir = (g_seqMgr.m_sequences[sIdx].side == SIDE_BUY) ? -1 : 1;

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
      if(g_seqMgr.m_sequences[i].tradeCount <= 0)
         continue;
      if(StringLen(g_seqMgr.m_sequences[i].tradeSymbol) == 0)
         continue;
      if(g_seqMgr.m_sequences[i].tradeSymbol != symbol)
         continue;
      if(g_seqMgr.m_sequences[i].side != newSide)
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
   if(numSymbols < 1)
      return;
   ClearMurreyMemoCache();
   ArrayInitialize(g_lastMmBarTime, 0);
   RefreshTickPositionSnapshot(true);

// Generate candidates (single symbols).
   int numCombos = numSymbols;
   CorrPair combos[];
   ArrayResize(combos, numCombos);
   for(int i = 0; i < numSymbols; i++)
     {
      double score = 1.0;
      if(UseCurrencyStrengthMatrix)
        {
         string base = GetBaseCurrency(allSymbols[i]);
         string quote = GetQuoteCurrency(allSymbols[i]);
         int rBase = StrengthRankOf(base);
         int rQuote = StrengthRankOf(quote);
         if(rBase >= 0 && rQuote >= 0)
           {
            // Score based on distance between currencies (higher = stronger trend candidate)
            score = MathAbs(strengthScores[StrengthFindCurrencyIndex(base)] - strengthScores[StrengthFindCurrencyIndex(quote)]);
           }
        }
      combos[i].idxA = i;
      combos[i].idxB = i; // Solo symbol mode
      combos[i].score = score;
     }

   // Sort candidates by score descending if strength is active
   if(UseCurrencyStrengthMatrix)
     {
      for(int a = 0; a < numCombos - 1; a++)
        {
         int best = a;
         for(int b = a + 1; b < numCombos; b++)
           {
            if(combos[b].score > combos[best].score)
               best = b;
           }
         if(best != a)
           {
            CorrPair tmp = combos[a];
            combos[a] = combos[best];
            combos[best] = tmp;
           }
        }
     }

   ActivePair newPairs[];
   ArrayResize(newPairs, 0);
   int selected = 0;

   for(int i = 0; i < numCombos && selected < Max_Active_Symbols && selected < MAX_PAIRS; i++)
     {
      string sA = allSymbols[combos[i].idxA];
      string sB = allSymbols[combos[i].idxB];

      // Scanner-level filter: no duplicate symbols (obvious for solo)
      bool symbolUsed = false;
      for(int j = 0; j < selected; j++)
        {
         if(newPairs[j].symbolA == sA)
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
         newPairs[selected].entry_mm_08 = 0;
         newPairs[selected].entry_mm_minus18 = 0;
         newPairs[selected].entry_mm_minus28 = 0;
         newPairs[selected].entry_mm_88 = 0;
         newPairs[selected].entry_mm_plus18 = 0;
         newPairs[selected].entry_mm_plus28 = 0;
         newPairs[selected].lastBuySeqCloseTime = 0;
         newPairs[selected].lastSellSeqCloseTime = 0;
         newPairs[selected].trendBreachTimeBuy = 0;
         newPairs[selected].trendBreachTimeSell = 0;
        }
      // Update fields that may change on rescan
      if(carried)
         newPairs[selected].recoveryManagedOnly = false;
      newPairs[selected].score = combos[i].score;
      newPairs[selected].active = true;
      newPairs[selected].tradingEnabled = true;
      newPairs[selected].buySeqIdx = SeqIdx(selected, SIDE_BUY);
      newPairs[selected].sellSeqIdx = SeqIdx(selected, SIDE_SELL);
      selected++;

      if(EnableLogging)
         Print("[Scanner] Selected: ", sA,
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
      long bMagic = g_seqMgr.m_sequences[bIdx].magicNumber;
      long sMagic = g_seqMgr.m_sequences[sIdx].magicNumber;
      for(int pos = 0; pos < ArraySize(tickPosRows); pos++)
        {
         long pm = tickPosRows[pos].magic;
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
   for(int pos = 0; pos < ArraySize(tickPosRows); pos++)
     {
      string posSymbol = tickPosRows[pos].symbol;
      string comment = tickPosRows[pos].comment;
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
      newPairs[selected].score = 0.0;
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
      newPairs[selected].trendBreachTimeBuy = 0;
      newPairs[selected].trendBreachTimeSell = 0;
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
         // EXISTING: Preserve state and magic number
         tempSequences[newBuyIdx] = g_seqMgr.m_sequences[oldBuyIdx];
         tempSequences[newSellIdx] = g_seqMgr.m_sequences[oldSellIdx];
         if(EnableLogging)
           {
            Print("[ScannerMap] Carry symbol ", newPairs[i].symbolA,
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
            Print("[ScannerMap] New symbol ", newPairs[i].symbolA,
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

// Orphan rescue: any open managed position whose magic wasn't claimed above
   // must be force-bound now so ScanPositions never loses it.
   // This happens when pair-selection drops a symbol that still has open trades.
   for(int oi = PositionsTotal() - 1; oi >= 0; oi--)
     {
      if(PositionGetTicket(oi) == 0) continue;
      string oSym = PositionGetString(POSITION_SYMBOL);
      string oCmt = PositionGetString(POSITION_COMMENT);
      if(!IsManagedPositionComment(oCmt) || IsBreakoutPositionComment(oCmt) || IsHedgePositionComment(oCmt))
         continue;
      long oMagic = PositionGetInteger(POSITION_MAGIC);
      if(oMagic <= 0) continue;

      // Check if this magic is already claimed in tempSequences
      bool claimed = false;
      for(int s2 = 0; s2 < MAX_PAIRS * 2; s2++)
        {
         if(tempSequences[s2].magicNumber == oMagic)
           {
            claimed = true;
            break;
           }
        }
      if(claimed) continue;

      // Find the first tempSequences slot with no magic (=0) and no active pair assignment,
      // OR a slot whose magic matches (shouldn't happen but safe to handle).
      int freeSlot = -1;
      for(int s2 = 0; s2 < MAX_PAIRS * 2; s2++)
        {
         if(tempSequences[s2].magicNumber == 0 || tempSequences[s2].magicNumber == oMagic)
           {
            freeSlot = s2;
            break;
           }
        }
      if(freeSlot < 0)
        {
         // All slots taken — expand beyond MAX_PAIRS*2 isn't possible, so just log
         Print("[OrphanRescue] No free slot for orphan magic=", oMagic, " sym=", oSym, " — trades may be unmanaged.");
         continue;
        }

      // Claim it
      tempSequences[freeSlot].magicNumber = oMagic;
      tempSequences[freeSlot].active      = true;
      tempSequences[freeSlot].tradeSymbol = oSym;
      tempSequences[freeSlot].side        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      Print("[OrphanRescue] Rescued orphan magic=", oMagic, " sym=", oSym,
            " -> slot=", freeSlot);
     }

// Commit: overwrite from temp buffer
   numActivePairs = selected;
   for(int i = 0; i < selected; i++)
      activePairs[i] = newPairs[i];
   for(int i = 0; i < MAX_PAIRS * 2; i++)
      g_seqMgr.m_sequences[i] = tempSequences[i];
   MarkSequenceMagicCacheDirty();

   lastScanTime = TimeCurrent();
   Print("[Scanner] Active portfolio: ", numActivePairs, " symbols mode=PortfolioTrader");
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
   // 1. Reset Performance Counters
   g_cachedTotalManagedPositions = 0;
   g_cachedActiveManagedSequences = 0;
   bool seqIsActive[MAX_PAIRS * 2];
   ArrayInitialize(seqIsActive, false);

   // 2. Refresh Snapshot (smart refresh)
   RefreshTickPositionSnapshot(false);

   // 3. Reset Sequence Metrics
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      g_seqMgr.m_sequences[i].prevTradeCount = g_seqMgr.m_sequences[i].tradeCount;
      g_seqMgr.m_sequences[i].plPrev = g_seqMgr.m_sequences[i].plOpen;
      g_seqMgr.ResetRuntimeMetrics(i);
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

   // 4. Main Scanning Loop
   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string posComment = tickPosRows[i].comment;
      if(!IsManagedPositionComment(posComment))
         continue;
      
      // Increment total managed count
      g_cachedTotalManagedPositions++;

      long magic = tickPosRows[i].magic;
      string posSymbol = tickPosRows[i].symbol;
      double posProfit = tickPosRows[i].profit + tickPosRows[i].swap + tickPosRows[i].commission;
      long posType = tickPosRows[i].type;

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

      // Fast Magic Lookup
      int seqIdx = FindSequenceByMagic(magic);

      if(seqIdx < 0)
        {
         if(EnableLogging)
            Print("[SCAN_MISS] No seq for magic=", magic, " sym=", posSymbol, " comment=", posComment);
         continue;
        }

      // Count unique active MR sequences
      if(!seqIsActive[seqIdx])
        {
         seqIsActive[seqIdx] = true;
         g_cachedActiveManagedSequences++;
        }

      if(StringLen(g_seqMgr.m_sequences[seqIdx].tradeSymbol) == 0)
         g_seqMgr.m_sequences[seqIdx].tradeSymbol = posSymbol;

      double posLots = tickPosRows[i].volume;
      double posPrice = tickPosRows[i].openPrice;

      g_seqMgr.AccumulatePosition(seqIdx, posLots, posPrice, posProfit,
                                  (posType == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL,
                                  tickPosRows[i].ticket);

      // Preserve strategy tag based on comment
      if(StringFind(posComment, "ZSM-TREND") == 0 || StringFind(posComment, "ZSM-TR") == 0)
         g_seqMgr.m_sequences[seqIdx].strategyType = STRAT_TRENDING;
      else if(StringFind(posComment, "ZSM-MR") == 0)
         g_seqMgr.m_sequences[seqIdx].strategyType = STRAT_MEAN_REVERSION;

      if(EnableLogging)
         Print("[STRAT_TAG] ", posSymbol, " magic=", magic,
               " comment=", posComment,
               " strategy=", (g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING ? "TREND" : "MR"));
     }

   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      g_seqMgr.FinalizeSequence(i);
      if(g_seqMgr.m_sequences[i].tradeCount > 0 && StringLen(g_seqMgr.m_sequences[i].tradeSymbol) > 0)
         EnsureSequenceLockProfile(i, g_seqMgr.m_sequences[i].tradeSymbol);
      if(g_seqMgr.m_sequences[i].tradeCount == 0 && g_seqMgr.m_sequences[i].prevTradeCount > 0)
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
   if(g_seqMgr.m_sequences[seqIdx].plPrev > 0)
     {
      sequenceCounterWinners++;
     }
   else
     {
      sequenceCounterLosers++;
     }
   sequenceCounter++;
   g_seqMgr.OnSequenceClosed(seqIdx);
   ClearSequenceLockProfile(seqIdx);
  }

//+------------------------------------------------------------------+
//|  RECONSTRUCT: Rebuild frozen snapshots after restart/reshuffle   |
//+------------------------------------------------------------------+
void ReconstructSequenceMemory(int seqIdx, int pairIdx)
  {
   if(g_seqMgr.m_sequences[seqIdx].tradeCount <= 0)
      return;
   // Trend sequences manage their own increment via Keltner/ATR — don't overwrite with Murrey Math base value
   if(g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING &&
      g_seqMgr.m_sequences[seqIdx].entryMmIncrement > EPS)
      return;
   string seqSym = GetSequenceTradeSymbol(seqIdx, pairIdx);
   double mm88 = 0, mm48 = 0, mm08 = 0, mmInc = 0;
   double mmP28 = 0, mmP18 = 0, mmM18 = 0, mmM28 = 0;
   
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)MrMM_Timeframe;
   int lookback = MrMM_Lookback;
   if(g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING)
     {
      tf = (ENUM_TIMEFRAMES)TrendMM_Timeframe;
      lookback = TrendMM_Lookback;
     }

   if(!CachedCalcMurreyLevelsForSymbolCustom(seqSym, tf, lookback, mm88, mm48, mm08, mmInc, mmP28, mmP18, mmM18, mmM28))
      return;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   if(side == SIDE_BUY)
     {
      if(activePairs[pairIdx].entry_mm_minus28 != 0 && g_seqMgr.m_sequences[seqIdx].entryMmIncrement > EPS)
         return;
      if(mm08 == 0 && mmM28 == 0)
         return;
      if(mmInc <= EPS)
         return;  // data not ready yet, skip until a valid increment is available
      activePairs[pairIdx].entry_mm_08 = mm08;
      activePairs[pairIdx].entry_mm_minus18 = mmM18;
      activePairs[pairIdx].entry_mm_minus28 = mmM28;
      if(g_seqMgr.m_sequences[seqIdx].entryMmIncrement <= EPS)
         g_seqMgr.m_sequences[seqIdx].entryMmIncrement = mmInc;
      if(EnableLogging)
         Print("[RECONSTRUCT] BUY ", seqSym,
               " mm08=", DoubleToString(activePairs[pairIdx].entry_mm_08, 5),
               " mm-2/8=", DoubleToString(activePairs[pairIdx].entry_mm_minus28, 5),
               " inc=", DoubleToString(g_seqMgr.m_sequences[seqIdx].entryMmIncrement, 5),
               " mmInc=", DoubleToString(mmInc, 5));
     }
   else
     {
      if(activePairs[pairIdx].entry_mm_plus28 != 0 && g_seqMgr.m_sequences[seqIdx].entryMmIncrement > EPS)
         return;
      if(mm88 == 0 && mmP28 == 0)
         return;
      if(mmInc <= EPS)
         return;  // data not ready yet, skip until a valid increment is available
      activePairs[pairIdx].entry_mm_88 = mm88;
      activePairs[pairIdx].entry_mm_plus18 = mmP18;
      activePairs[pairIdx].entry_mm_plus28 = mmP28;
      if(g_seqMgr.m_sequences[seqIdx].entryMmIncrement <= EPS)
         g_seqMgr.m_sequences[seqIdx].entryMmIncrement = mmInc;
      if(EnableLogging)
         Print("[RECONSTRUCT] SELL ", seqSym,
               " mm88=", DoubleToString(activePairs[pairIdx].entry_mm_88, 5),
               " mm+2/8=", DoubleToString(activePairs[pairIdx].entry_mm_plus28, 5),
               " inc=", DoubleToString(g_seqMgr.m_sequences[seqIdx].entryMmIncrement, 5),
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
   // Tag position comment so ScanPositions can identify strategy type on restart
   pendingOrderComment = (strat == STRAT_TRENDING) ? "ZSM-TR" : "ZSM-MR";
   // Set strategyType on the sequence BEFORE opening — this was previously never done,
   // leaving trend entries mis-tagged as STRAT_MEAN_REVERSION
   g_seqMgr.m_sequences[seqIdx].strategyType = strat;
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
      if(magic != g_seqMgr.m_sequences[seqIdx].magicNumber) continue;
      
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
      bool sent = OrderSendAsync(req, res);
      if(!sent && EnableLogging)
         Print("[ASYNC_CLOSE_ERR] ticket=", ticket, " magic=", magic, " retcode=", (int)res.retcode);
     }
   g_seqMgr.m_sequences[seqIdx].tradeCount = 0;
   g_seqMgr.m_sequences[seqIdx].plOpen = 0;
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
         if(g_seqMgr.m_sequences[s].magicNumber == magic && g_seqMgr.m_sequences[s].active) {
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
      bool sent = OrderSendAsync(req, res);
      if(!sent && EnableLogging)
         Print("[ASYNC_CLOSE_ALL_ERR] ticket=", ticket, " magic=", magic, " retcode=", (int)res.retcode);
     }
     
   for(int s=0; s<MAX_PAIRS*2; s++) {
      g_seqMgr.m_sequences[s].tradeCount = 0;
      g_seqMgr.m_sequences[s].plOpen = 0;
   }
  }

//+------------------------------------------------------------------+
//|  CLOSE SEQUENCE                                                  |
//+------------------------------------------------------------------+
void CloseSequencesByStrategy(const ENUM_STRATEGY_TYPE strat, const string reason)
  {
   for(int i = 0; i < MAX_PAIRS * 2; i++)
     {
      if(g_seqMgr.m_sequences[i].tradeCount <= 0)
         continue;
      if(g_seqMgr.m_sequences[i].strategyType != strat)
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
void TrailingForSequence(int seqIdx, int pairIdx, double currentBid, double currentAsk)
  {
   if(g_seqMgr.m_sequences[seqIdx].tradeCount == 0)
      return;

   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   string sym = GetSequenceTradeSymbol(seqIdx, pairIdx);
   if(StringLen(sym) == 0)
      sym = activePairs[pairIdx].symbolA;
   int side = g_seqMgr.m_sequences[seqIdx].side;

// MR/Trending trailing (shared lock-profit logic)
   if(g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_MEAN_REVERSION ||
      g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING)
     {
      if(LockProfitMode == lpGlobal)
         return;
      bool isTrend = (g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING);
      int minTrades = isTrend ? TrendLockProfitMinTrades : LockProfitMinTrades;
      if(minTrades > 0 && g_seqMgr.m_sequences[seqIdx].tradeCount < minTrades)
         return;

      double avgP = g_seqMgr.m_sequences[seqIdx].avgPrice;
      if(avgP == 0)
         return;

      EnsureSequenceLockProfile(seqIdx, sym);
      double effLP = g_seqMgr.m_sequences[seqIdx].lpTriggerDist;
      if(effLP < 0)
         return;

      double effTSL = g_seqMgr.m_sequences[seqIdx].lpTrailDist;
      if(effTSL <= 0)
         return;

      // Use passed bid/ask
      double curBid = currentBid;
      double curAsk = currentAsk;

      if(side == SIDE_BUY)
        {
         if(!g_seqMgr.m_sequences[seqIdx].lockProfitExec)
           {
            if(curBid >= avgP + effLP)
              {
               g_seqMgr.m_sequences[seqIdx].lockProfitExec = true;
               if(EnableLogging)
                  Print("[LockProfit] BUY activated for pair ", pairIdx);
              }
           }
         if(g_seqMgr.m_sequences[seqIdx].lockProfitExec)
           {
            double newSL = curBid - effTSL;
            double validSL = 0;
            if(!PrepareValidStopForModify(sym, SIDE_BUY, newSL, validSL))
               return;
            for(int k = 0; k < g_seqMgr.m_sequences[seqIdx].ticketCount; k++)
              {
               ulong ticket = g_seqMgr.m_sequences[seqIdx].tickets[k];
               if(PositionSelectByTicket(ticket))
                 {
                  double curSL = PositionGetDouble(POSITION_SL);
                  if(validSL > curSL || curSL == 0)
                    {
                     trade.SetExpertMagicNumber(magic);
                     trade.PositionModify(ticket, validSL, PositionGetDouble(POSITION_TP));
                    }
                 }
              }
           }
        }
      else   // SELL
        {
         if(!g_seqMgr.m_sequences[seqIdx].lockProfitExec)
           {
            if(curAsk <= avgP - effLP)
              {
               g_seqMgr.m_sequences[seqIdx].lockProfitExec = true;
               if(EnableLogging)
                  Print("[LockProfit] SELL activated for pair ", pairIdx);
              }
           }
         if(g_seqMgr.m_sequences[seqIdx].lockProfitExec)
           {
            double newSL = curAsk + effTSL;
            double validSL = 0;
            if(!PrepareValidStopForModify(sym, SIDE_SELL, newSL, validSL))
               return;
            for(int k = 0; k < g_seqMgr.m_sequences[seqIdx].ticketCount; k++)
              {
               ulong ticket = g_seqMgr.m_sequences[seqIdx].tickets[k];
               if(PositionSelectByTicket(ticket))
                 {
                  double curSL = PositionGetDouble(POSITION_SL);
                  if(validSL < curSL || curSL == 0)
                    {
                     trade.SetExpertMagicNumber(magic);
                     trade.PositionModify(ticket, validSL, PositionGetDouble(POSITION_TP));
                    }
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
   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   if(magic <= 0)
      return true;
   return !IsSequenceHedged(magic);
  }

void CheckStagnationHedge(int seqIdx)
  {
   if(StagnationHedgeDrawdownAmount <= 0 || g_seqMgr.m_sequences[seqIdx].tradeCount <= 0)
      return;
   // Hedge only when sequence drawdown breaches configured threshold.
   if(g_seqMgr.m_sequences[seqIdx].plOpen > -StagnationHedgeDrawdownAmount + EPS)
      return;
   // If lock-profit already engaged, let normal trailing manage the exit.
   if(g_seqMgr.m_sequences[seqIdx].lockProfitExec)
      return;
   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   if(IsSequenceHedged(magic))
      return; // Already hedged

   string sym = g_seqMgr.m_sequences[seqIdx].tradeSymbol;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   int hedgeSide = (side == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
   int nTrades = g_seqMgr.m_sequences[seqIdx].tradeCount;
   double totalVol = g_seqMgr.m_sequences[seqIdx].totalLots;
   
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
      long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
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
      if(g_seqMgr.m_sequences[i].magicNumber > 0 && magic == g_seqMgr.m_sequences[i].magicNumber)
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
   // Distinct bid/ask colours: bid = blue, ask = orange-red (theme-aware)
   color bidCol = (VisualTheme == themeLight) ? C'0,100,200'   : clrDodgerBlue;
   color askCol = (VisualTheme == themeLight) ? C'200,50,50'   : clrOrangeRed;

   ChartSetInteger(0, CHART_COLOR_BACKGROUND, bg);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, fg);
   ChartSetInteger(0, CHART_COLOR_GRID, grid);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, bullFill);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, bearFill);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, outline);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, outline);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, fg);
   ChartSetInteger(0, CHART_COLOR_BID, bidCol);
   ChartSetInteger(0, CHART_COLOR_ASK, askCol);
   ChartSetInteger(0, CHART_COLOR_LAST, fg);
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, C'128,132,140');
   ChartSetInteger(0, CHART_SHOW_BID_LINE, true);
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, true);
   ChartSetInteger(0, CHART_SHOW_VOLUMES, 0);   // hide tick volume
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
   string sym = g_seqMgr.m_sequences[seqIdx].tradeSymbol;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   if(StringLen(sym) > 0)
     {
      GlobalVariableDel(LpTrigKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, sym));
      GlobalVariableDel(LpTrailKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, sym));
     }
   // Legacy cleanup
   GlobalVariableDel(LpTrigKeyLegacy(g_seqMgr.m_sequences[seqIdx].magicNumber));
   GlobalVariableDel(LpTrailKeyLegacy(g_seqMgr.m_sequences[seqIdx].magicNumber));
   g_seqMgr.m_sequences[seqIdx].lpTriggerDist = 0;
   g_seqMgr.m_sequences[seqIdx].lpTrailDist = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool LoadSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   string kTrig = LpTrigKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, symbol);
   string kTrail = LpTrailKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, symbol);
   bool hasTrig = GlobalVariableCheck(kTrig);
   bool hasTrail = GlobalVariableCheck(kTrail);

   if(hasTrig || hasTrail)
     {
      g_seqMgr.m_sequences[seqIdx].lpTriggerDist = hasTrig ? GlobalVariableGet(kTrig) : 0;
      g_seqMgr.m_sequences[seqIdx].lpTrailDist = hasTrail ? GlobalVariableGet(kTrail) : 0;
      return true;
     }

   // Legacy fallback (older builds keyed only by magic)
   string kTrigOld = LpTrigKeyLegacy(g_seqMgr.m_sequences[seqIdx].magicNumber);
   string kTrailOld = LpTrailKeyLegacy(g_seqMgr.m_sequences[seqIdx].magicNumber);
   bool hasTrigOld = GlobalVariableCheck(kTrigOld);
   bool hasTrailOld = GlobalVariableCheck(kTrailOld);
   if(!hasTrigOld && !hasTrailOld)
      return false;
   g_seqMgr.m_sequences[seqIdx].lpTriggerDist = hasTrigOld ? GlobalVariableGet(kTrigOld) : 0;
   g_seqMgr.m_sequences[seqIdx].lpTrailDist = hasTrailOld ? GlobalVariableGet(kTrailOld) : 0;
   // Migrate forward to symbol/side-specific keys.
   GlobalVariableSet(kTrig, g_seqMgr.m_sequences[seqIdx].lpTriggerDist);
   GlobalVariableSet(kTrail, g_seqMgr.m_sequences[seqIdx].lpTrailDist);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SaveSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   GlobalVariableSet(LpTrigKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, symbol), g_seqMgr.m_sequences[seqIdx].lpTriggerDist);
   GlobalVariableSet(LpTrailKey(g_seqMgr.m_sequences[seqIdx].magicNumber, side, symbol), g_seqMgr.m_sequences[seqIdx].lpTrailDist);
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

   bool isTrend = (g_seqMgr.m_sequences[seqIdx].strategyType == STRAT_TRENDING);
   double trigInput = isTrend ? TrendLockProfitTriggerPips : LockProfitTriggerPips;
   double trailInput = isTrend ? TrendTrailingStop : TrailingStop;
   ENUM_STRATEGY_TYPE strat = isTrend ? STRAT_TRENDING : STRAT_MEAN_REVERSION;
   double trigDist = ResolvePipsOrRangeForStrategy(trigInput, symbol, strat) * pVal;
   double trailDist = ResolvePipsOrRangeForStrategy(trailInput, symbol, strat) * pVal;

   if(trigDist < 0)
      trigDist = 0;
   if(trailDist < 0)
      trailDist = 0;

   g_seqMgr.m_sequences[seqIdx].lpTriggerDist = trigDist;
   g_seqMgr.m_sequences[seqIdx].lpTrailDist = trailDist;
   SaveSequenceLockProfile(seqIdx, symbol);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void EnsureSequenceLockProfile(int seqIdx, string symbol)
  {
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return;
   if(g_seqMgr.m_sequences[seqIdx].tradeCount <= 0)
      return;
   if(g_seqMgr.m_sequences[seqIdx].lpTriggerDist > 0 || g_seqMgr.m_sequences[seqIdx].lpTrailDist > 0)
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
   if(magic <= 0)
      return -1;
   if(seqMagicCacheDirty)
      RebuildSequenceMagicCache();
   for(int i = 0; i < ArraySize(seqMagicCacheMagic); i++)
     {
      if(seqMagicCacheMagic[i] == magic)
         return seqMagicCacheSeqIdx[i];
     }
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SequenceHasLiveManagedPositions(int seqIdx, string symbol = "")
  {
   RefreshTickPositionSnapshot(false);
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return false;
   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      if(tickPosRows[i].magic != magic)
         continue;
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      if(StringLen(symbol) > 0 && !SymbolsEqual(tickPosRows[i].symbol, symbol))
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
   return g_cachedActiveManagedSequences;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasManagedPositionsOnSymbol(string symbol, bool &hasBuy, bool &hasSell)
  {
   RefreshTickPositionSnapshot(false);
   hasBuy = false;
   hasSell = false;
   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      if(!SymbolsEqual(tickPosRows[i].symbol, symbol))
         continue;
      long posType = tickPosRows[i].type;
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
   RefreshTickPositionSnapshot(false);
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

   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string posSymbol = tickPosRows[i].symbol;
      int idx = FindInputSymbolIndex(posSymbol);
      if(idx < 0)
         continue;

      string posComment = tickPosRows[i].comment;
      if(!IsMrPositionComment(posComment) && !IsHedgePositionComment(posComment))
         continue;

      double lots = tickPosRows[i].volume;
      double openPrice = tickPosRows[i].openPrice;
      long posType = tickPosRows[i].type;
      double posProfit = tickPosRows[i].profit + tickPosRows[i].swap + tickPosRows[i].commission;

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
   RefreshTickPositionSnapshot(false);
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

   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment) && !IsHedgePositionComment(comment))
         continue;
      string posSymbol = tickPosRows[i].symbol;
      int idx = FindInputSymbolIndex(posSymbol);
      if(idx < 0)
         continue;

      double posProfit = tickPosRows[i].profit + tickPosRows[i].swap + tickPosRows[i].commission;
      double lots = tickPosRows[i].volume;
      long posType = tickPosRows[i].type;
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
   RefreshTickPositionSnapshot(false);
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2)
      return 0;
   if(g_seqMgr.m_sequences[seqIdx].tradeCount <= 0 && !SequenceHasLiveManagedPositions(seqIdx, symbol))
      return 0;

   if(StringLen(symbol) == 0)
      return 0;

   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   double best = 0;
   bool found = false;

   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      if(tickPosRows[i].magic != magic)
         continue;
      if(!SymbolsEqual(tickPosRows[i].symbol, symbol))
         continue;
      double sl = tickPosRows[i].sl;
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
   RefreshTickPositionSnapshot(false);
   if(seqIdx < 0 || seqIdx >= MAX_PAIRS * 2 || StringLen(symbol) == 0)
      return 0;
   long magic = g_seqMgr.m_sequences[seqIdx].magicNumber;
   double volSum = 0;
   double pxVolSum = 0;
   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      if(tickPosRows[i].magic != magic)
         continue;
      if(!SymbolsEqual(tickPosRows[i].symbol, symbol))
         continue;
      double vol = tickPosRows[i].volume;
      double px = tickPosRows[i].openPrice;
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
   if(!SequenceHasLiveManagedPositions(seqIdx, symbol) && g_seqMgr.m_sequences[seqIdx].tradeCount <= 0)
      return 0;

   if(StringLen(symbol) == 0)
      return 0;
   double avgP = g_seqMgr.m_sequences[seqIdx].avgPrice;
   if(avgP <= 0)
      avgP = GetSequenceAvgPriceFallback(seqIdx, symbol);
   if(avgP <= 0)
      return 0;
   int side = g_seqMgr.m_sequences[seqIdx].side;
   if(g_seqMgr.m_sequences[seqIdx].lpTriggerDist <= 0 && g_seqMgr.m_sequences[seqIdx].lpTrailDist <= 0)
     {
      if(!LoadSequenceLockProfile(seqIdx, symbol))
         BuildAndStoreSequenceLockProfile(seqIdx, symbol);
     }
   double triggerDist = g_seqMgr.m_sequences[seqIdx].lpTriggerDist;
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
   RefreshTickPositionSnapshot(false);
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

   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment))
         continue;

      string symbol = tickPosRows[i].symbol;
      int sIdxInput = FindInputSymbolIndex(symbol);
      if(sIdxInput < 0)
         continue;

      long magic = tickPosRows[i].magic;
      int seqIdx = FindSequenceByMagic(magic);
      if(seqIdx < 0 )
         continue;

      int side = (tickPosRows[i].type == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
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
   RefreshTickPositionSnapshot(false);
   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(tickPosRows[i].symbol, symbol))
         continue;
      long posType = tickPosRows[i].type;
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
         if(g_seqMgr.m_sequences[i].plOpen <= 0)
            continue;
        }
      else
        {
         if(g_seqMgr.m_sequences[i].plOpen >= 0)
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
   RefreshTickPositionSnapshot(false);
   string buyName = EAName + "_lock_buy";
   string sellName = EAName + "_lock_sell";
   color buyClr = (VisualTheme == themeLight) ? C'28,88,188' : C'120,190,255';
   color sellClr = (VisualTheme == themeLight) ? C'178,110,26' : C'255,196,124';
   double buyPlot = 0, sellPlot = 0;
   double buyArmPlot = 0, sellArmPlot = 0;

   for(int i = 0; i < ArraySize(tickPosRows); i++)
     {
      string comment = tickPosRows[i].comment;
      if(!IsMrPositionComment(comment))
         continue;
      if(!SymbolsEqual(tickPosRows[i].symbol, _Symbol))
         continue;

      int seqIdx = FindSequenceByMagic(tickPosRows[i].magic);
      if(seqIdx < 0 )
         continue;

      int side = (tickPosRows[i].type == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
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
   RefreshTickPositionSnapshot(true);
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
   g_seqMgr.InitDefaults();
   MarkSequenceMagicCacheDirty();
   ResetCommissionCache();
   ClearMurreyMemoCache();
   InvalidateTickPositionSnapshot();

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
      g_seqMgr.m_sequences[i].side = i % 2;
      g_seqMgr.m_sequences[i].seqId = i;
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
   MaybeUpdateLockProfitChartLines();

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

// Chart style / theme — skip on symbol/period change to preserve any manual user adjustments.
   if(!chartChangeReload)
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
      MaybeDrawDashboard();
      MaybeUpdateLockProfitChartLines();
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
   MaybeUpdateLockProfitChartLines();
   if(ShowDashboard)
      MaybeDrawDashboard();
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
   // On symbol/period change: keep dashboard objects (inc. LP lines) intact so
   // re-init on the same chart window finds them without a repaint flash.
   // All other reasons (remove, settings change, etc.) do a full cleanup.
   if(reason != REASON_CHARTCHANGE)
      ClearDashboard();
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   ReleaseAtrCache();
   ReleaseKeltnerCache();
   ReleaseEmaCache();
   // ClearMurreyMemoCache() intentionally removed — OnInit clears it anyway.
   InvalidateTickPositionSnapshot();
   ArrayResize(seqMagicCacheMagic, 0);
   ArrayResize(seqMagicCacheSeqIdx, 0);
   seqMagicCacheDirty = true;
   ResetCommissionCache();
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
         if(!CachedCalcMurreyLevelsForSymbolCustom(sym, (ENUM_TIMEFRAMES)Breakout_MM_Timeframe, boLookback,
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
//|  Update per-symbol floating equity samples (Tester Only)         |
//+------------------------------------------------------------------+
void UpdateSymbolEquitySamples()
  {
   if(!HistorySelect(0, TimeCurrent())) return;
   
   int currentDeals = HistoryDealsTotal();
   for(int i = g_symEquityLastDealsTotal; i < currentDeals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      long dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
        {
         string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(sym == "") continue;
         double pl = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         
         int idx = -1;
         for(int j=0; j<g_symEquityTrackerCount; j++)
           {
            if(g_symEquityTracker[j].symbol == sym) { idx = j; break; }
           }
         if(idx < 0)
           {
            idx = g_symEquityTrackerCount;
            g_symEquityTrackerCount++;
            ArrayResize(g_symEquityTracker, g_symEquityTrackerCount);
            g_symEquityTracker[idx].symbol = sym;
            g_symEquityTracker[idx].trades = 0;
            g_symEquityTracker[idx].closedProfit = 0;
            g_symEquityTracker[idx].grossProfit = 0;
            g_symEquityTracker[idx].grossLoss = 0;
            g_symEquityTracker[idx].maxDrawdown = 0;
            g_symEquityTracker[idx].peakEquity = 0;
            g_symEquityTracker[idx].sampleCount = 0;
            ArrayResize(g_symEquityTracker[idx].equitySamples, 100);
           }
           
         g_symEquityTracker[idx].closedProfit += pl;
         if(pl > 0.0) g_symEquityTracker[idx].grossProfit += pl;
         else if(pl < 0.0) g_symEquityTracker[idx].grossLoss += MathAbs(pl);
         g_symEquityTracker[idx].trades++;
        }
     }
   g_symEquityLastDealsTotal = currentDeals;

   double floatingPL[];
   ArrayResize(floatingPL, g_symEquityTrackerCount);
   ArrayInitialize(floatingPL, 0.0);
   
   int totalPos = PositionsTotal();
   for(int i=0; i<totalPos; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0)
        {
         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic != 0) // Track all positions with a magic number from our EA
           {
            double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            int idx = -1;
            for(int j=0; j<g_symEquityTrackerCount; j++)
              {
               if(g_symEquityTracker[j].symbol == sym) { idx = j; break; }
              }
            if(idx < 0)
              {
               idx = g_symEquityTrackerCount;
               g_symEquityTrackerCount++;
               ArrayResize(g_symEquityTracker, g_symEquityTrackerCount);
               ArrayResize(floatingPL, g_symEquityTrackerCount);
               floatingPL[idx] = 0; 
               g_symEquityTracker[idx].symbol = sym;
               g_symEquityTracker[idx].trades = 0;
               g_symEquityTracker[idx].closedProfit = 0;
               g_symEquityTracker[idx].grossProfit = 0;
               g_symEquityTracker[idx].grossLoss = 0;
               g_symEquityTracker[idx].maxDrawdown = 0;
               g_symEquityTracker[idx].peakEquity = 0;
               g_symEquityTracker[idx].sampleCount = 0;
               ArrayResize(g_symEquityTracker[idx].equitySamples, 100);
              }
            floatingPL[idx] += pl;
           }
        }
     }
     
   for(int j=0; j<g_symEquityTrackerCount; j++)
     {
      double currentEquity = g_symEquityTracker[j].closedProfit + floatingPL[j];
      
      int sc = g_symEquityTracker[j].sampleCount;
      int cap = ArraySize(g_symEquityTracker[j].equitySamples);
      if(sc >= cap)
         ArrayResize(g_symEquityTracker[j].equitySamples, cap + 1000); 
         
      g_symEquityTracker[j].equitySamples[sc] = currentEquity;
      g_symEquityTracker[j].sampleCount++;
      
      if(currentEquity > g_symEquityTracker[j].peakEquity)
         g_symEquityTracker[j].peakEquity = currentEquity;
         
      double dd = g_symEquityTracker[j].peakEquity - currentEquity;
      if(dd > g_symEquityTracker[j].maxDrawdown)
         g_symEquityTracker[j].maxDrawdown = dd;
     }
  }

//+------------------------------------------------------------------+
//|  EXPERT TICK FUNCTION                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   CurTime = TimeCurrent();
   InvalidateTickPositionSnapshot();
   ClearTickCache();
   TimeToStruct(CurTime, now);
   newBar = isNewBar();
   newBarM1 = isNewBarM1();

   // Declare session variables in outer scope to fix compilation errors
   bool mrSessionOpen = IsStrategySessionOpen(STRAT_MEAN_REVERSION);
   bool trendSessionOpen = IsStrategySessionOpen(STRAT_TRENDING);
   bool anyStrategySessionOpen = (mrSessionOpen && EnableMeanReversion) || (trendSessionOpen && EnableTrendingStrategy);
   int totalPos = g_cachedTotalManagedPositions;

   if(newBar)
     {
      ClearEntryBarCache();
      ClearMurreyMemoCache();
      // Equity-curve sampling for OnTester R² score (tester only, every new bar)
      if(IsTester)
        {
         double eq = AccountInfoDouble(ACCOUNT_EQUITY);
         if(MathIsValidNumber(eq))
           {
            ArrayResize(g_equitySeries, g_equityCount + 1);
            g_equitySeries[g_equityCount] = eq;
            g_equityCount++;
           }
         UpdateSymbolEquitySamples();
        }
     }

// Efficiency Early Exit: Skip computation if nothing to manage and no new bar to process
   if(PositionsTotal() == 0)
     {
      g_cachedTotalManagedPositions = 0;
      g_cachedActiveManagedSequences = 0;
      totalPos = 0;
      if(!newBar && !newBarM1)
         return;
     }
   else
     {
      if(g_cachedTotalManagedPositions == 0 && !anyStrategySessionOpen && !newBar && !newBarM1)
         return;
     }

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
   int currentTotalPos = PositionsTotal();
   if(g_cachedTotalManagedPositions > 0 || currentTotalPos > 0)
     {
      ulong scanUsStart = EnablePerfTiming ? PerfNowUs() : 0;
      bool shouldScanNow = (currentTotalPos != g_lastPositionsTotal || newBar || newBarM1 || ShouldScanPositionsEveryTick());

      if(shouldScanNow)
        {
         ScanPositions();
         g_lastPositionsTotal = currentTotalPos;
        }
      totalPos = g_cachedTotalManagedPositions; // Update local tracker
      if(EnablePerfTiming)
         perfScanUsAcc += (PerfNowUs() - scanUsStart);
     }
   else
     {
      // Light reset of internal counts if no positions
      for(int i = 0; i < MAX_PAIRS * 2; i++)
        {
         g_seqMgr.m_sequences[i].prevTradeCount = g_seqMgr.m_sequences[i].tradeCount;
         g_seqMgr.ResetRuntimeMetrics(i);
        }
      g_lastPositionsTotal = 0;
      totalPos = 0;
     }

   // Keep lock-profit chart levels synchronized on every tick.
   MaybeUpdateLockProfitChartLines();

// Hard stop check
   if(CheckStopOfEA())
     {
      MaybeDrawDashboard();
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
         MaybeDrawDashboard();
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
         MaybeDrawDashboard();
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
         if(g_seqMgr.m_sequences[sq].tradeCount > 0 && g_seqMgr.m_sequences[sq].plOpen <= -MaxLossPerSequence)
           {
            AsyncCloseSequence(sq, "Max Seq Loss (" + DoubleToString(g_seqMgr.m_sequences[sq].plOpen, 2) + ")");
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
         MaybeDrawDashboard();
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
      MaybeDrawDashboard();
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
         MaybeDrawDashboard();
         return;
        }
     }

// Global Rescue Logic
   if(RescueDrawdownThreshold > 0)
     {
      double totalOpenPL = TotalPlOpen();
      if(totalOpenPL >= RescueNetProfitTarget)
        {
         bool closedAny = false;
         for(int sq = 0; sq < MAX_PAIRS * 2; sq++)
           {
            if(g_seqMgr.m_sequences[sq].tradeCount > 0 && g_seqMgr.m_sequences[sq].plOpen <= -RescueDrawdownThreshold)
              {
               AsyncCloseAll("Rescue Close ALL: Net PL " + DoubleToString(totalOpenPL, 2) +
                             " (seq draw " + DoubleToString(g_seqMgr.m_sequences[sq].plOpen, 2) + ")");
               closedAny = true;
               break;
              }
           }
         if(closedAny)
           {
            MaybeDrawDashboard();
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
        }
     }

// Process each active pair on new bar
   if(newBar)
     {
      ulong pairUsStart = EnablePerfTiming ? PerfNowUs() : 0;
      ulong markovUsStart = 0;
      string mkUpdatedSymbols[];
      for(int p = 0; p < numActivePairs; p++)
        {
         CalcMurreyLevels(p);
         if(AnyStrategyMarkovEnabled())
           {
            if(EnablePerfTiming && markovUsStart == 0)
               markovUsStart = PerfNowUs();
            string mkSymA = activePairs[p].symbolA;
            string mkSymB = activePairs[p].symbolB;
            if(StringLen(mkSymA) > 0)
               MarkovUpdateUniqueOncePerBar(mkSymA, mkUpdatedSymbols);
            if(StringLen(mkSymB) > 0 && mkSymB != mkSymA)
               MarkovUpdateUniqueOncePerBar(mkSymB, mkUpdatedSymbols);
           }
        }
      if(EnablePerfTiming)
        {
         perfPairUsAcc += (PerfNowUs() - pairUsStart);
         if(markovUsStart > 0)
            perfMarkovUsAcc += (PerfNowUs() - markovUsStart);
        }
     }

// Session checks
   mrSessionOpen = IsStrategySessionOpen(STRAT_MEAN_REVERSION);
   trendSessionOpen = IsStrategySessionOpen(STRAT_TRENDING);
   anyStrategySessionOpen = (mrSessionOpen && EnableMeanReversion) || (trendSessionOpen && EnableTrendingStrategy);
   bool skipOpenStagesThisTick = false;

   // Session end forced-close actions should preempt any new opens on the same tick.
   if(!mrSessionOpen && GetStrategySessionEndAction(STRAT_MEAN_REVERSION) == CLOSE_ALL && TotalPositions() > 0)
     {
      CloseSequencesByStrategy(STRAT_MEAN_REVERSION, "MR Session End");
      skipOpenStagesThisTick = true;
     }
   if(!trendSessionOpen && GetStrategySessionEndAction(STRAT_TRENDING) == CLOSE_ALL && TotalPositions() > 0)
     {
      CloseSequencesByStrategy(STRAT_TRENDING, "Trend Session End");
      skipOpenStagesThisTick = true;
     }

//=== MAIN TRADING LOOP PER PAIR ===
// Efficiency Gate: Only run pair logic if we have positions or are looking to open new ones
   if(totalPos > 0 || (anyStrategySessionOpen && !maxDailyWinnersLosersHit))
     {
      ulong pairLogicUsStart = EnablePerfTiming ? PerfNowUs() : 0;
      int openMrSequenceCount = 0;
      bool loggedMaxOpenSeqBlock = false;
      int startsExecutedThisBar = 0;
      int addsExecutedThisBar = 0;
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
         string sym = symA; // pair label / legacy logging
         int bIdx = activePairs[p].buySeqIdx;
         int sIdx = activePairs[p].sellSeqIdx;
         bool buyStartedNow = false;
         bool sellStartedNow = false;

         // Get current bid/ask for symA using tick cache
         MqlTick tickA;
         if(!GetCachedTick(symA, tickA))
            continue;
         double curBidA = tickA.bid;
         double curAskA = tickA.ask;

         // Track extreme market prices for sequence management
         if(g_seqMgr.m_sequences[bIdx].tradeCount > 0)
           {
            string bSym = g_seqMgr.m_sequences[bIdx].tradeSymbol;
            if(StringLen(bSym)>0)
              {
               double curBid = SymbolInfoDouble(bSym, SYMBOL_BID);
               if(g_seqMgr.m_sequences[bIdx].highestPrice == 0 || curBid > g_seqMgr.m_sequences[bIdx].highestPrice)
                  g_seqMgr.m_sequences[bIdx].highestPrice = curBid;
               if(g_seqMgr.m_sequences[bIdx].lowestPrice == 0 || curBid < g_seqMgr.m_sequences[bIdx].lowestPrice)
                  g_seqMgr.m_sequences[bIdx].lowestPrice = curBid;
              }
           }
         if(g_seqMgr.m_sequences[sIdx].tradeCount > 0)
           {
            string sSym = g_seqMgr.m_sequences[sIdx].tradeSymbol;
            if(StringLen(sSym)>0)
              {
               double curAsk = SymbolInfoDouble(sSym, SYMBOL_ASK);
               if(g_seqMgr.m_sequences[sIdx].highestPrice == 0 || curAsk > g_seqMgr.m_sequences[sIdx].highestPrice)
                  g_seqMgr.m_sequences[sIdx].highestPrice = curAsk;
               if(g_seqMgr.m_sequences[sIdx].lowestPrice == 0 || curAsk < g_seqMgr.m_sequences[sIdx].lowestPrice)
                  g_seqMgr.m_sequences[sIdx].lowestPrice = curAsk;
              }
           }

         // Rebuild frozen snapshots if lost (restart/reshuffle safety)
         /* if(EnableLogging && (g_seqMgr.m_sequences[bIdx].tradeCount > 0 || g_seqMgr.m_sequences[sIdx].tradeCount > 0))
             Print("[PAIR_TC] pair=", p, " ", activePairs[p].symbolA, "/", activePairs[p].symbolB,
                   " bTC=", g_seqMgr.m_sequences[bIdx].tradeCount, " sTC=", g_seqMgr.m_sequences[sIdx].tradeCount,
                   " bMagic=", g_seqMgr.m_sequences[bIdx].magicNumber, " sMagic=", g_seqMgr.m_sequences[sIdx].magicNumber);*/
         if((newBar || newBarM1 || firstTickSinceInit) && SequenceNeedsReconstruct(bIdx, p))
            ReconstructSequenceMemory(bIdx, p);
         if((newBar || newBarM1 || firstTickSinceInit) && SequenceNeedsReconstruct(sIdx, p))
            ReconstructSequenceMemory(sIdx, p);

         // ---- TRAILING (runs every tick or per bar) ----
         // BUY trailing
         if(g_seqMgr.m_sequences[bIdx].tradeCount > 0)
           {
            bool doTrailBuy = false;
            bool buyIsTrend = (g_seqMgr.m_sequences[bIdx].strategyType == STRAT_TRENDING);
            enumTrailFrequency checkFreq = g_seqMgr.m_sequences[bIdx].lockProfitExec ?
                                           (buyIsTrend ? TrendTrailFrequency : TrailFrequency) :
                                           (buyIsTrend ? TrendLockProfitCheckFrequency : LockProfitCheckFrequency);
            if(checkFreq == trailEveryTick)
               doTrailBuy = true;
            else if(checkFreq == trailAtCloseOfBarM1 && newBarM1)
               doTrailBuy = true;
            else if(checkFreq == trailAtCloseOfBarChart && newBar)
               doTrailBuy = true;

            if(doTrailBuy)
               TrailingForSequence(bIdx, p, curBidA, curAskA);
           }

         // SELL trailing
         if(g_seqMgr.m_sequences[sIdx].tradeCount > 0)
           {
            bool doTrailSell = false;
            bool sellIsTrend = (g_seqMgr.m_sequences[sIdx].strategyType == STRAT_TRENDING);
            enumTrailFrequency checkFreq = g_seqMgr.m_sequences[sIdx].lockProfitExec ?
                                           (sellIsTrend ? TrendTrailFrequency : TrailFrequency) :
                                           (sellIsTrend ? TrendLockProfitCheckFrequency : LockProfitCheckFrequency);
            if(checkFreq == trailEveryTick)
               doTrailSell = true;
            else if(checkFreq == trailAtCloseOfBarM1 && newBarM1)
               doTrailSell = true;
            else if(checkFreq == trailAtCloseOfBarChart && newBar)
               doTrailSell = true;

            if(doTrailSell)
               TrailingForSequence(sIdx, p, curBidA, curAskA);
           }

         // ---- ENTRIES: Only on new bar + session open ----
         if(!newBar)
            continue;
         if(!anyStrategySessionOpen && g_seqMgr.m_sequences[bIdx].tradeCount == 0 && g_seqMgr.m_sequences[sIdx].tradeCount == 0)
             continue;
         if(!AllowNewSequence && g_seqMgr.m_sequences[bIdx].tradeCount == 0 && g_seqMgr.m_sequences[sIdx].tradeCount == 0)
            continue;
         bool allowNewStarts = activePairs[p].tradingEnabled;
         if(!allowNewStarts && g_seqMgr.m_sequences[bIdx].tradeCount == 0 && g_seqMgr.m_sequences[sIdx].tradeCount == 0)
            continue;
         if(blockingNews && NewsAction == newsActionPause &&
               g_seqMgr.m_sequences[bIdx].tradeCount == 0 && g_seqMgr.m_sequences[sIdx].tradeCount == 0)
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
         // Primary lookup uses MR settings as the baseline for activePairs sync
         if(!CachedCalcMurreyLevelsForSymbolCustom(symB, (ENUM_TIMEFRAMES)MrMM_Timeframe, MrMM_Lookback, mm88B, mm48B, mm08B, mmIncB, mmP28B, mmP18B, mmM18B, mmM28B))
            continue;

          // Strategy-specific Murrey snapshots for start conditions.
          // MR baseline is already updated by the scanner using MrMM_Timeframe/Lookback
          double mrMm88A = activePairs[p].mm_88, mrMm08A = activePairs[p].mm_08, mrIncA = mmInc;
          double mrMmP28A = activePairs[p].mm_plus28, mrMmP18A = activePairs[p].mm_plus18;
          double mrMmM18A = activePairs[p].mm_minus18, mrMmM28A = activePairs[p].mm_minus28;
          double mrMm88B = mm88B, mrMm08B = mm08B, mrIncB = mmIncB;
          double mrMmP28B = mmP28B, mrMmP18B = mmP18B, mrMmM18B = mmM18B, mrMmM28B = mmM28B;

          double trMm88A = activePairs[p].mm_88, trMm08A = activePairs[p].mm_08, trIncA = mmInc;
          double trMm88B = mm88B, trMm08B = mm08B, trIncB = mmIncB;
          double trMm48A = 0.0, trMm48B = 0.0;
          double trMmP28A = 0.0, trMmP18A = 0.0, trMmM18A = 0.0, trMmM28A = 0.0;
          double trMmP28B = 0.0, trMmP18B = 0.0, trMmM18B = 0.0, trMmM28B = 0.0;
          
          ENUM_TIMEFRAMES trTf = (ENUM_TIMEFRAMES)TrendMM_Timeframe;
          // If Trending uses a different timeframe or lookback than the scanner (MR), recalculate
          if(trTf != (ENUM_TIMEFRAMES)MrMM_Timeframe || TrendMM_Lookback != MrMM_Lookback)
            {
             CachedCalcMurreyLevelsForSymbolCustom(symA, trTf, TrendMM_Lookback, trMm88A, trMm48A, trMm08A, trIncA, trMmP28A, trMmP18A, trMmM18A, trMmM28A);
             CachedCalcMurreyLevelsForSymbolCustom(symB, trTf, TrendMM_Lookback, trMm88B, trMm48B, trMm08B, trIncB, trMmP28B, trMmP18B, trMmM18B, trMmM28B);
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

         bool routeMr = EnableMeanReversion;
         bool routeTrend = EnableTrendingStrategy;
         if(skipOpenStagesThisTick)
            continue;
         int preferredDir = (DecisionMode == decisionRankedDeterministic && SideTieBreak == sideSellFirst) ? 1 : 0;

         // === TRENDING ENTRY (consolidated BUY/SELL flow) ===
         for(int sideRank = 0; sideRank < 2; sideRank++)
           {
            int dirIdx = (sideRank == 0 ? preferredDir : (1 - preferredDir));
            bool isBuy = (dirIdx == 0);
            int sideVal = isBuy ? SIDE_BUY : SIDE_SELL;
            int seqIdx = isBuy ? bIdx : sIdx;
            bool startedNow = isBuy ? buyStartedNow : sellStartedNow;
            if(!routeTrend || !trendSessionOpen || startedNow || !allowNewStarts || !CanOpenSide(sideVal) || g_seqMgr.m_sequences[seqIdx].tradeCount != 0)
               continue;
            bool scarceStartSlots = ((MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences - 1) ||
                                     (DecisionMode == decisionRankedDeterministic && MaxStartsPerBar > 0 && startsExecutedThisBar >= MaxStartsPerBar - 1));
            bool mrCompetes = routeMr && mrSessionOpen;
            if(DecisionMode == decisionRankedDeterministic &&
               StrategyTieBreak == stratMrFirst &&
               mrCompetes &&
               scarceStartSlots)
               continue;
            if(DecisionMode == decisionRankedDeterministic && MaxStartsPerBar > 0 && startsExecutedThisBar >= MaxStartsPerBar)
              {
               if(EnableLogging)
                  Print("[Priority] Start budget hit. Blocking TREND ", (isBuy ? "BUY" : "SELL"), " on ", symA, "/", symB);
               continue;
              }
            if(!AllowNewTrendingSequences)
               continue;

            string trendSym = "";
            double trendInc = 0, trendCross = 0, trendLevelPrice = 0;
            int trendDigits = 0;
            double bestTrendBreach = -1e10;

            double levelA = isBuy ? trendBuyLevelPriceA : trendSellLevelPriceA;
            double levelB = isBuy ? trendBuyLevelPriceB : trendSellLevelPriceB;
            bool aTrendBreak = isBuy ? (trIncA > EPS && upCrossA >= levelA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA))
                                     : (trIncA > EPS && downCrossA <= levelA && (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA));
            bool bTrendBreak = isBuy ? (trIncB > EPS && upCrossB >= levelB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB))
                                     : (trIncB > EPS && downCrossB <= levelB && (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB));
            // Track Breaches (Sensitive to 15% of an increment)
            if(isBuy) {
               if(upCrossA >= levelA + 0.15 * trIncA - EPS) {
                  activePairs[p].trendBreachTimeBuy = TimeCurrent();
                  activePairs[p].trendBreachPriceBuy = levelA;
               }
               if(upCrossB >= levelB + 0.15 * trIncB - EPS) {
                  activePairs[p].trendBreachTimeBuy = TimeCurrent();
                  activePairs[p].trendBreachPriceBuy = levelB;
               }
            } else {
               if(downCrossA <= levelA - 0.15 * trIncA + EPS) {
                  activePairs[p].trendBreachTimeSell = TimeCurrent();
                  activePairs[p].trendBreachPriceSell = levelA;
               }
               if(downCrossB <= levelB - 0.15 * trIncB + EPS) {
                  activePairs[p].trendBreachTimeSell = TimeCurrent();
                  activePairs[p].trendBreachPriceSell = levelB;
               }
            }

             bool aTrendRetest = false;
             datetime bTimeA = isBuy ? activePairs[p].trendBreachTimeBuy : activePairs[p].trendBreachTimeSell;
             double bPriceA = isBuy ? activePairs[p].trendBreachPriceBuy : activePairs[p].trendBreachPriceSell;
             if(bTimeA > 0) {
                int bBarsA = iBarShift(symA, PERIOD_CURRENT, bTimeA);
                if(bBarsA >= 0 && bBarsA <= Trend_RetestWindow_Bars) {
                   if(isBuy) aTrendRetest = (downCrossA <= bPriceA + EPS && upCrossA >= bPriceA - EPS);
                   else aTrendRetest = (upCrossA >= bPriceA - EPS && downCrossA <= bPriceA + EPS);
                } else {
                   if(isBuy) { activePairs[p].trendBreachTimeBuy = 0; activePairs[p].trendBreachPriceBuy = 0; }
                   else { activePairs[p].trendBreachTimeSell = 0; activePairs[p].trendBreachPriceSell = 0; }
                }
             }
            bool bTrendRetest = aTrendRetest; // For solo mode, B follows A logic or uses same breach state
            double trendBlockThrA = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symA, STRAT_TRENDING);
            double trendBlockThrB = ResolveMinIncrementForStrategy(TrendMinIncrementBlock_Pips, symB, STRAT_TRENDING);
            bool aOk = ((TrendEntryType == trendEntryBreak) ? aTrendBreak : aTrendRetest) &&
                       (trendBlockThrA <= 0 || trIncA >= trendBlockThrA - EPS);
            bool bOk = ((TrendEntryType == trendEntryBreak) ? bTrendBreak : bTrendRetest) &&
                       (trendBlockThrB <= 0 || trIncB >= trendBlockThrB - EPS);

            if(aOk)
              {
               double breachA = trIncA > EPS ? (isBuy ? (upCrossA - levelA) : (levelA - downCrossA)) / trIncA : 0;
               if(breachA > bestTrendBreach)
                 {
                  bestTrendBreach = breachA;
                  trendSym = symA;
                  trendInc = trIncA;
                  trendCross = isBuy ? upCrossA : downCrossA;
                  trendLevelPrice = levelA;
                  trendDigits = digitsA;
                 }
              }
            if(bOk)
              {
               double breachB = trIncB > EPS ? (isBuy ? (upCrossB - levelB) : (levelB - downCrossB)) / trIncB : 0;
               if(breachB > bestTrendBreach)
                 {
                  bestTrendBreach = breachB;
                  trendSym = symB;
                  trendInc = trIncB;
                  trendCross = isBuy ? upCrossB : downCrossB;
                  trendLevelPrice = levelB;
                  trendDigits = digitsB;
                 }
              }

            if(StringLen(trendSym) > 0)
              {
               string markovTrendReason = "";
               if(!MarkovModeAllowsEntry(trendSym, sideVal, true, TrendingMarkovMode, markovTrendReason))
                 {
                  if(EnableLogging)
                     Print("[MarkovFilter] TREND ", (isBuy ? "BUY" : "SELL"), " blocked on ", trendSym,
                           " reason=", markovTrendReason);
                  trendSym = "";
                 }
              }

            if(StringLen(trendSym) > 0 && !IsTrendStrengthQualified(trendSym, sideVal))
               trendSym = "";

            bool trendOnCooldown = false;
            if(StringLen(trendSym) > 0 && CooldownBars > 0)
              {
               datetime lastClose = isBuy ? activePairs[p].lastBuySeqCloseTime : activePairs[p].lastSellSeqCloseTime;
               if(lastClose > 0)
                 {
                  int barsSinceClose = iBarShift(trendSym, PERIOD_CURRENT, lastClose);
                  if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                     trendOnCooldown = true;
                 }
              }
            if(StringLen(trendSym) > 0 && trendOnCooldown)
               trendSym = "";

            ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            if(StringLen(trendSym) > 0 && HasDirectionalConflict(trendSym, orderType, p))
               trendSym = "";

            if(StringLen(trendSym) > 0 && MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
               trendSym = "";

            if(StringLen(trendSym) > 0)
              {
               if(EnableLogging)
                  Print("[TrendEntry] ", (isBuy ? "BUY " : "SELL "), trendSym,
                        " level=", DoubleToString(trendLevelPrice, trendDigits),
                        " cross=", DoubleToString(trendCross, trendDigits));
               g_seqMgr.m_sequences[seqIdx].entryMmIncrement = trendInc;
                bool openedTrend = OpenOrderWithContext(seqIdx, orderType, trendSym, STRAT_TRENDING);
                if(openedTrend)
                  {
                   if(isBuy) {
                      buyStartedNow = true;
                      activePairs[p].trendBreachTimeBuy = 0;
                      activePairs[p].trendBreachPriceBuy = 0;
                   } else {
                      sellStartedNow = true;
                      activePairs[p].trendBreachTimeSell = 0;
                      activePairs[p].trendBreachPriceSell = 0;
                   }
                  if(MaxOpenSequences > 0)
                     openMrSequenceCount++;
                  if(DecisionMode == decisionRankedDeterministic)
                     startsExecutedThisBar++;
                 }
              }
           }

         // === MR ENTRY (consolidated BUY/SELL flow) ===
         for(int sideRank = 0; sideRank < 2; sideRank++)
           {
            int dirIdx = (sideRank == 0 ? preferredDir : (1 - preferredDir));
            bool isBuy = (dirIdx == 0);
            int sideVal = isBuy ? SIDE_BUY : SIDE_SELL;
            int seqIdx = isBuy ? bIdx : sIdx;
            bool startedNow = isBuy ? buyStartedNow : sellStartedNow;
            if(!routeMr || !mrSessionOpen || startedNow || !allowNewStarts || !CanOpenSide(sideVal) || g_seqMgr.m_sequences[seqIdx].tradeCount != 0)
               continue;
            bool scarceStartSlots = ((MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences - 1) ||
                                     (DecisionMode == decisionRankedDeterministic && MaxStartsPerBar > 0 && startsExecutedThisBar >= MaxStartsPerBar - 1));
            if(DecisionMode == decisionRankedDeterministic &&
               StrategyTieBreak == stratTrendFirst &&
               routeTrend && trendSessionOpen &&
               scarceStartSlots)
               continue;
            if(DecisionMode == decisionRankedDeterministic && MaxStartsPerBar > 0 && startsExecutedThisBar >= MaxStartsPerBar)
              {
               if(EnableLogging)
                  Print("[Priority] Start budget hit. Blocking MR ", (isBuy ? "BUY" : "SELL"), " on ", symA, "/", symB);
               continue;
              }
            if(!AllowNewMeanReversionSequences)
               continue;

            int liveCount = CountPositionsByMagicSide(g_seqMgr.m_sequences[seqIdx].magicNumber, symA, sideVal);
            if(symB != symA)
               liveCount += CountPositionsByMagicSide(g_seqMgr.m_sequences[seqIdx].magicNumber, symB, sideVal);
            if(StringLen(g_seqMgr.m_sequences[seqIdx].tradeSymbol) > 0 &&
               g_seqMgr.m_sequences[seqIdx].tradeSymbol != symA &&
               g_seqMgr.m_sequences[seqIdx].tradeSymbol != symB)
               liveCount += CountPositionsByMagicSide(g_seqMgr.m_sequences[seqIdx].magicNumber, g_seqMgr.m_sequences[seqIdx].tradeSymbol, sideVal);
            if(liveCount > 0)
              {
               if(EnableLogging)
                  Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] ", (isBuy ? "BUY" : "SELL"),
                        " tradeCount=0 but live magic positions=", liveCount,
                        " pair=", symA, "/", symB);
               continue;
              }

            string mrEntrySym = "";
            double mrEntryInc = 0, mrEntryLevelPrice = 0, mrEntryCross = 0;
            int mrEntryDigits = 0;
            double mrAnchor1 = 0, mrAnchor2 = 0, mrAnchor3 = 0;
            double bestBreach = -1e10;

            // [MR_DIAG]: one line per new bar per pair/side showing why entry fires or not.
            // Set EnableLogging=false to silence. Check Experts log for these lines.
            if(EnableLogging)
              {
               double dLevel  = isBuy ? buyEntryLevelPriceA : sellEntryLevelPriceA;
               double dCross  = isBuy ? downCrossA : upCrossA;
               double dBlkThr = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symA, STRAT_MEAN_REVERSION);
               bool dPriceHit = (mrIncA > EPS) && (isBuy ? (dCross <= dLevel) : (dCross >= dLevel));
               bool dIncBlk   = (dBlkThr > 0 && mrIncA < dBlkThr - EPS);
               Print("[MR_DIAG] ", (isBuy?"BUY":"SELL"), " ", symA,
                     " tf=", EnumToString(GetStrategyMMTimeframe(STRAT_MEAN_REVERSION)),
                     " level=", DoubleToString(dLevel, digitsA),
                     " barPx=", DoubleToString(dCross, digitsA),
                     " inc=", DoubleToString(mrIncA, digitsA),
                     " blkThr=", DoubleToString(dBlkThr, digitsA),
                     " hit=",  (dPriceHit?"Y":"N"),
                     " blk=",  (dIncBlk?"Y":"N"),
                     " sess=", (mrSessionOpen?"Y":"N"),
                     " sprdPips=", DoubleToString(spreadA > 0 ? spreadA/SymbolInfoDouble(symA,SYMBOL_POINT) : 0, 1),
                     "/", DoubleToString(MaxSpreadPips, 1));
              }
               double levelA = isBuy ? buyEntryLevelPriceA : sellEntryLevelPriceA;
               double levelB = isBuy ? buyEntryLevelPriceB : sellEntryLevelPriceB;
               double crossA = isBuy ? downCrossA : upCrossA;
               double crossB = isBuy ? downCrossB : upCrossB;

               bool aHit = (mrIncA > EPS) &&
                           (isBuy ? (crossA <= levelA) : (crossA >= levelA)) &&
                           (MaxSpreadPips <= 0 || spreadA <= maxSpreadPtsA);
               bool bHit = (mrIncB > EPS) &&
                           (isBuy ? (crossB <= levelB) : (crossB >= levelB)) &&
                           (MaxSpreadPips <= 0 || spreadB <= maxSpreadPtsB);

               double blockThrA = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symA, STRAT_MEAN_REVERSION);
               double blockThrB = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, symB, STRAT_MEAN_REVERSION);

               if(aHit && !(blockThrA > 0 && mrIncA < blockThrA - EPS))
                 {
                  double breachA = mrIncA > EPS ? (isBuy ? (levelA - crossA) : (crossA - levelA)) / mrIncA : 0;
                  if(breachA > bestBreach)
                    {
                     bestBreach = breachA;
                     mrEntrySym = symA;
                     mrEntryInc = mrIncA;
                     mrEntryLevelPrice = levelA;
                     mrEntryCross = crossA;
                     mrEntryDigits = digitsA;
                     if(isBuy)
                       {
                        mrAnchor1 = mrMm08A;
                        mrAnchor2 = mrMmM18A;
                        mrAnchor3 = mrMmM28A;
                       }
                     else
                       {
                        mrAnchor1 = mrMm88A;
                        mrAnchor2 = mrMmP18A;
                        mrAnchor3 = mrMmP28A;
                       }
                    }
                 }

               if(bHit && !(blockThrB > 0 && mrIncB < blockThrB - EPS))
                 {
                  double breachB = mrIncB > EPS ? (isBuy ? (levelB - crossB) : (crossB - levelB)) / mrIncB : 0;
                  if(breachB > bestBreach)
                    {
                     bestBreach = breachB;
                     mrEntrySym = symB;
                     mrEntryInc = mrIncB;
                     mrEntryLevelPrice = levelB;
                     mrEntryCross = crossB;
                     mrEntryDigits = digitsB;
                     if(isBuy)
                       {
                        mrAnchor1 = mm08B;
                        mrAnchor2 = mmM18B;
                        mrAnchor3 = mmM28B;
                       }
                     else
                       {
                        mrAnchor1 = mm88B;
                        mrAnchor2 = mmP18B;
                        mrAnchor3 = mmP28B;
                       }
                    }
                 }


            bool onCooldown = false;
            if(StringLen(mrEntrySym) > 0 && CooldownBars > 0)
              {
               datetime lastClose = isBuy ? activePairs[p].lastBuySeqCloseTime : activePairs[p].lastSellSeqCloseTime;
               if(lastClose > 0)
                 {
                  int barsSinceClose = iBarShift(mrEntrySym, PERIOD_CURRENT, lastClose);
                  if(barsSinceClose >= 0 && barsSinceClose < CooldownBars)
                     onCooldown = true;
                 }
              }

            if(!onCooldown && StringLen(mrEntrySym) > 0)
              {
               string markovReason = "";
               if(!MarkovModeAllowsEntry(mrEntrySym, sideVal, false, MeanReversionMarkovMode, markovReason))
                 {
                  if(EnableLogging)
                     Print("[MarkovFilter] ", (isBuy ? "BUY" : "SELL"), " blocked on ", mrEntrySym,
                           " reason=", markovReason);
                  mrEntrySym = "";
                 }
              }

            if(!onCooldown && StringLen(mrEntrySym) > 0 && !IsRangeStrengthQualified(mrEntrySym))
              {
               if(EnableLogging)
                  Print("[StrengthFilter] ", (isBuy ? "BUY" : "SELL"), " MR blocked on ", mrEntrySym, " (not mid-matrix)");
               mrEntrySym = "";
              }

            ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            if(!onCooldown && StringLen(mrEntrySym) > 0)
              {
               if(HasDirectionalConflict(mrEntrySym, orderType, p))
                  mrEntrySym = "";
               else
                 {
                  double expandThr = ResolveMinIncrementForStrategy(MrMinIncrementExpand_Pips, mrEntrySym, STRAT_MEAN_REVERSION);
                  if(expandThr > 0 && mrEntryInc < expandThr)
                     mrEntryInc = expandThr;

                  if(IsLpBeyondMurreyBoundary(mrEntrySym, sideVal))
                     mrEntrySym = "";
                  else if(IsLpTradeIntoEmaBlocked(mrEntrySym, sideVal))
                     mrEntrySym = "";
                  else if(MaxOpenSequences > 0 && openMrSequenceCount >= MaxOpenSequences)
                    {
                     if(EnableLogging && !loggedMaxOpenSeqBlock)
                       {
                        Print("[SeqCap] MaxOpenSequences reached (", openMrSequenceCount, "/", MaxOpenSequences,
                              "). Blocking new MR starts.");
                        loggedMaxOpenSeqBlock = true;
                       }
                     mrEntrySym = "";
                    }
                 }
              }

            if(StringLen(mrEntrySym) > 0)
              {
               if(EnableLogging)
                  Print("[Entry] SNIPER ", (isBuy ? "BUY" : "SELL"), ": ", mrEntrySym,
                        " ", (isBuy ? downPriceLabel : upPriceLabel), "=",
                        DoubleToString(mrEntryCross, mrEntryDigits),
                        " mm", IntegerToString(isBuy ? buyEntryLevelEighth : sellEntryLevelEighth),
                        "/8=", DoubleToString(mrEntryLevelPrice, mrEntryDigits));
               g_seqMgr.m_sequences[seqIdx].entryMmIncrement = mrEntryInc;
               bool openedMr = OpenOrderWithContext(seqIdx, orderType, mrEntrySym, STRAT_MEAN_REVERSION);
               if(openedMr && MaxOpenSequences > 0)
                  openMrSequenceCount++;
               if(openedMr && DecisionMode == decisionRankedDeterministic)
                  startsExecutedThisBar++;
               if(isBuy)
                 {
                  activePairs[p].entry_mm_08 = mrAnchor1;
                  activePairs[p].entry_mm_minus18 = mrAnchor2;
                  activePairs[p].entry_mm_minus28 = mrAnchor3;
                  buyStartedNow = true;
                 }
               else
                 {
                  activePairs[p].entry_mm_88 = mrAnchor1;
                  activePairs[p].entry_mm_plus18 = mrAnchor2;
                  activePairs[p].entry_mm_plus28 = mrAnchor3;
                  sellStartedNow = true;
                 }
              }
           }
         // === TREND GRID ADDS (consolidated BUY/SELL flow) ===
         for(int sideRank = 0; sideRank < 2; sideRank++)
           {
            int dirIdx = (sideRank == 0 ? preferredDir : (1 - preferredDir));
            bool isBuy = (dirIdx == 0);
            int seqIdx = isBuy ? bIdx : sIdx;
            if(g_seqMgr.m_sequences[seqIdx].strategyType != STRAT_TRENDING ||
               g_seqMgr.m_sequences[seqIdx].tradeCount <= 0 ||
               g_seqMgr.m_sequences[seqIdx].tradeCount >= MaxOrders)
               continue;
            if(DecisionMode == decisionRankedDeterministic &&
               StrategyTieBreak == stratMrFirst &&
               MaxAddsPerBar > 0 && addsExecutedThisBar >= MaxAddsPerBar - 1)
               continue;
            if(DecisionMode == decisionRankedDeterministic && MaxAddsPerBar > 0 && addsExecutedThisBar >= MaxAddsPerBar)
              {
               if(EnableLogging)
                  Print("[Priority] Add budget hit. Blocking TREND ", (isBuy ? "BUY" : "SELL"), " add on ", symA, "/", symB);
               continue;
              }

            int gridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
            if(TimeCurrent() - g_seqMgr.m_sequences[seqIdx].lastOpenTime <= gridThrottleSec)
               continue;

            string activeSym = isBuy ? buySym : sellSym;
            double activeSpread = isBuy ? buySpread : sellSpread;
            double maxSpreadPts = isBuy ? maxSpreadPtsBuySym : maxSpreadPtsSellSym;
            double activeClose = isBuy ? buyClose : sellClose;
            int activeDigits = isBuy ? buyDigits : sellDigits;
            double execPrice = SymbolInfoDouble(activeSym, isBuy ? SYMBOL_ASK : SYMBOL_BID);
            if(execPrice <= 0)
               execPrice = activeClose;

            if(MaxSpreadPips > 0 && activeSpread > maxSpreadPts)
               continue;

            double trendInc = g_seqMgr.m_sequences[seqIdx].entryMmIncrement > EPS ? g_seqMgr.m_sequences[seqIdx].entryMmIncrement :
                              (activeSym == symB ? trIncB : trIncA);
            double trendExpandThr = ResolveMinIncrementForStrategy(TrendMinIncrementExpand_Pips, activeSym, STRAT_TRENDING);
            if(trendExpandThr > 0 && trendInc < trendExpandThr)
               trendInc = trendExpandThr;
            if(trendInc <= 0)
               continue;

            double anchor = g_seqMgr.m_sequences[seqIdx].avgPrice;
            if(anchor <= 0)
               continue;

            int n = g_seqMgr.m_sequences[seqIdx].tradeCount;
            bool allowProfitRetest = (TrendAddMode == trendAddProfitRetest || TrendAddMode == trendAddBoth);
            bool allowAdverseAvg = (TrendAddMode == trendAddAdverseAveraging || TrendAddMode == trendAddBoth);
            bool addTriggered = false;
            string addModeTag = "";
            double logRetestLevel = 0.0;

            if(allowProfitRetest)
              {
               double requiredBound = isBuy ? (anchor + (2.0 * n * trendInc))
                                            : (anchor - (2.0 * n * trendInc));
               double retestLevel = isBuy ? (anchor + ((2.0 * n - 1.0) * trendInc))
                                          : (anchor - ((2.0 * n - 1.0) * trendInc));
               bool boundMet = isBuy ? (g_seqMgr.m_sequences[seqIdx].highestPrice >= requiredBound)
                                     : (g_seqMgr.m_sequences[seqIdx].lowestPrice <= requiredBound);
               bool retestHit = isBuy ? (execPrice <= retestLevel)
                                      : (execPrice >= retestLevel);
               if(boundMet && retestHit)
                 {
                  addTriggered = true;
                  addModeTag = "TrendScale";
                  logRetestLevel = retestLevel;
                 }
              }

            if(!addTriggered && allowAdverseAvg)
              {
               double requiredAdverse = isBuy ? (anchor - (2.0 * n * trendInc))
                                              : (anchor + (2.0 * n * trendInc));
               double retestAdverse = isBuy ? (anchor - ((2.0 * n - 1.0) * trendInc))
                                            : (anchor + ((2.0 * n - 1.0) * trendInc));
               bool adverseBoundMet = isBuy ? (g_seqMgr.m_sequences[seqIdx].lowestPrice <= requiredAdverse)
                                            : (g_seqMgr.m_sequences[seqIdx].highestPrice >= requiredAdverse);
               bool adverseRetestHit = isBuy ? (execPrice >= retestAdverse)
                                             : (execPrice <= retestAdverse);
               if(adverseBoundMet && adverseRetestHit)
                 {
                  addTriggered = true;
                  addModeTag = "TrendAdverse";
                  logRetestLevel = retestAdverse;
                 }
              }

            if(!addTriggered)
               continue;

            if(EnableLogging)
               Print("[", addModeTag, "] ", (isBuy ? "BUY" : "SELL"), " add #", n + 1, " ", activeSym,
                     " ", (isBuy ? "high=" : "low="),
                     DoubleToString(isBuy ? g_seqMgr.m_sequences[seqIdx].highestPrice : g_seqMgr.m_sequences[seqIdx].lowestPrice, activeDigits),
                     " exec=", DoubleToString(execPrice, activeDigits),
                     " retest=", DoubleToString(logRetestLevel, activeDigits));
            bool openedTrendAdd = OpenOrderWithContext(seqIdx, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, activeSym, STRAT_TRENDING);
            if(openedTrendAdd && DecisionMode == decisionRankedDeterministic)
               addsExecutedThisBar++;
           }
         // === MR GRID ADDS (consolidated BUY/SELL flow) ===
         for(int sideRank = 0; sideRank < 2; sideRank++)
           {
            int dirIdx = (sideRank == 0 ? preferredDir : (1 - preferredDir));
            bool isBuy = (dirIdx == 0);
            int sideVal = isBuy ? SIDE_BUY : SIDE_SELL;
            int seqIdx = isBuy ? bIdx : sIdx;
            if(g_seqMgr.m_sequences[seqIdx].strategyType != STRAT_MEAN_REVERSION ||
               g_seqMgr.m_sequences[seqIdx].tradeCount <= 0 ||
               g_seqMgr.m_sequences[seqIdx].tradeCount >= MaxOrders)
               continue;
            if(DecisionMode == decisionRankedDeterministic &&
               StrategyTieBreak == stratTrendFirst &&
               MaxAddsPerBar > 0 && addsExecutedThisBar >= MaxAddsPerBar - 1)
               continue;
            if(DecisionMode == decisionRankedDeterministic && MaxAddsPerBar > 0 && addsExecutedThisBar >= MaxAddsPerBar)
              {
               if(EnableLogging)
                  Print("[Priority] Add budget hit. Blocking MR ", (isBuy ? "BUY" : "SELL"), " add on ", symA, "/", symB);
               continue;
              }

            if(!SequenceGridAddsAllowed(seqIdx))
              {
               if(EnableLogging)
                  Print("[GridFreeze] ", (isBuy ? "BUY" : "SELL"), " adds frozen due to hedge on magic=", g_seqMgr.m_sequences[seqIdx].magicNumber);
               continue;
              }

            int gridThrottleSec = GridAddThrottleSeconds < 0 ? 0 : GridAddThrottleSeconds;
            if(TimeCurrent() - g_seqMgr.m_sequences[seqIdx].lastOpenTime <= gridThrottleSec)
               continue;

            string activeSym = isBuy ? buySym : sellSym;
            double activeSpread = isBuy ? buySpread : sellSpread;
            double maxSpreadPts = isBuy ? maxSpreadPtsBuySym : maxSpreadPtsSellSym;
            double activeClose = isBuy ? buyClose : sellClose;
            double activeCross = isBuy ? buyDownCross : sellUpCross;
            int activeDigits = isBuy ? buyDigits : sellDigits;
            double execPrice = SymbolInfoDouble(activeSym, isBuy ? SYMBOL_ASK : SYMBOL_BID);
            if(execPrice <= 0)
               execPrice = activeClose;

            if(MaxSpreadPips > 0 && activeSpread > maxSpreadPts)
              {
               if(EnableLogging)
                  Print("[SpreadFilter] ", (isBuy ? "BUY" : "SELL"), " add blocked on ", activeSym,
                        " spread=", DoubleToString(activeSpread, 1));
               continue;
              }

            double baseInc = (activeSym == symB ? mrIncB : mrIncA);
            double frozenInc = g_seqMgr.m_sequences[seqIdx].entryMmIncrement > EPS ? g_seqMgr.m_sequences[seqIdx].entryMmIncrement : baseInc;
            double blockThr = ResolveMinIncrementForStrategy(MrMinIncrementBlock_Pips, activeSym, STRAT_MEAN_REVERSION);
            if(blockThr > 0 && frozenInc < blockThr)
              {
               if(EnableLogging)
                  Print("[GridFloor] ", (isBuy ? "BUY " : "SELL "), activeSym, " expanding grid step from ", DoubleToString(frozenInc, 5), " to ", DoubleToString(blockThr, 5));
               frozenInc = blockThr;
              }
            if(frozenInc <= 0)
              {
               if(EnableLogging)
                  Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] ", (isBuy ? "BUY" : "SELL"), " frozenInc<=0 on ", activeSym);
               continue;
              }

            double worst = 0;
            if(!GetWorstEntryByMagic(g_seqMgr.m_sequences[seqIdx].magicNumber, activeSym, sideVal, worst))
              {
               if(EnableLogging)
                  Print("[SEQ_STATE_MISMATCH_BLOCK_ADD] ", (isBuy ? "BUY" : "SELL"), " positions not found for tracked sequence on ", activeSym);
               continue;
              }

            double cumOff = GridCumulativeOffset(frozenInc, g_seqMgr.m_sequences[seqIdx].tradeCount);
            double stepOff = GridStepDistance(frozenInc, g_seqMgr.m_sequences[seqIdx].tradeCount);
            double nextLevel = 0;
            bool useSnapshotAnchor = isBuy ? (activePairs[p].entry_mm_08 > 0) : (activePairs[p].entry_mm_88 > 0);
            if(useSnapshotAnchor)
              {
               double anchor = isBuy ? activePairs[p].entry_mm_08 : activePairs[p].entry_mm_88;
               double observedSpan = isBuy ? (anchor - worst) : (worst - anchor);
               double tol = MathMax(stepOff * 3.0, SymbolPointValue(activeSym) * 20.0);
               if(observedSpan < -tol || observedSpan > (cumOff + tol * 3.0))
                 {
                  useSnapshotAnchor = false;
                  if(EnableLogging)
                     Print("[SEQ_SNAPSHOT_MISMATCH] ", (isBuy ? "BUY " : "SELL "), activeSym,
                           " anchor=", DoubleToString(anchor, activeDigits),
                           " worst=", DoubleToString(worst, activeDigits),
                           " observedSpan=", DoubleToString(observedSpan, activeDigits),
                           " expectedCum=", DoubleToString(cumOff, activeDigits),
                           " -> fallback to worst-entry grid");
                  if(isBuy)
                    {
                     activePairs[p].entry_mm_08 = 0;
                     activePairs[p].entry_mm_minus18 = 0;
                     activePairs[p].entry_mm_minus28 = 0;
                    }
                  else
                    {
                     activePairs[p].entry_mm_88 = 0;
                     activePairs[p].entry_mm_plus18 = 0;
                     activePairs[p].entry_mm_plus28 = 0;
                    }
                 }
              }

            if(useSnapshotAnchor)
               nextLevel = isBuy ? (activePairs[p].entry_mm_08 - cumOff) : (activePairs[p].entry_mm_88 + cumOff);
            else
               nextLevel = isBuy ? (worst - stepOff) : (worst + stepOff);

            bool invalidNext = isBuy ? (nextLevel >= worst - SymbolPointValue(activeSym) * 0.1)
                                     : (nextLevel <= worst + SymbolPointValue(activeSym) * 0.1);
            if(invalidNext)
              {
               if(EnableLogging)
                  Print("[SEQ_GRID_GUARD] ", (isBuy ? "BUY" : "SELL"), " blocked invalid nextLevel on ", activeSym,
                        " nextLevel=", DoubleToString(nextLevel, activeDigits),
                        " worst=", DoubleToString(worst, activeDigits));
               continue;
              }

            if(EnableLogging)
              {
               if(isBuy)
                  Print("[GRID_LEVEL] BUY ", activeSym,
                        " count=", g_seqMgr.m_sequences[seqIdx].tradeCount,
                        " nextLevel=", DoubleToString(nextLevel, activeDigits),
                        " ", downPriceLabel, "=", DoubleToString(activeCross, activeDigits),
                        " entry_mm08=", DoubleToString(activePairs[p].entry_mm_08, 5),
                        " frozenInc=", DoubleToString(frozenInc, 5),
                        " entryMmInc=", DoubleToString(g_seqMgr.m_sequences[seqIdx].entryMmIncrement, 5),
                        " buyBaseInc=", DoubleToString(baseInc, 5),
                        " cumOff=", DoubleToString(cumOff, 5));
               else
                  Print("[GRID_LEVEL] SELL ", activeSym,
                        " count=", g_seqMgr.m_sequences[seqIdx].tradeCount,
                        " nextLevel=", DoubleToString(nextLevel, activeDigits),
                        " ", upPriceLabel, "=", DoubleToString(activeCross, activeDigits));
              }

            bool trigger = isBuy ? (execPrice <= nextLevel) : (execPrice >= nextLevel);
            if(!trigger)
               continue;

            if(EnableLogging)
               Print("[Grid] ", (isBuy ? "BUY" : "SELL"), " add #", g_seqMgr.m_sequences[seqIdx].tradeCount + 1,
                     " ", activeSym,
                     " exec=", DoubleToString(execPrice, activeDigits),
                     " close=", DoubleToString(activeClose, activeDigits),
                     " NextLevel=", DoubleToString(nextLevel, activeDigits));
            bool openedMrAdd = OpenOrderWithContext(seqIdx, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, activeSym, g_seqMgr.m_sequences[seqIdx].strategyType);
            if(openedMrAdd && DecisionMode == decisionRankedDeterministic)
               addsExecutedThisBar++;
           }
            // === COOLDOWN: Track sequence close times ===
            if(g_seqMgr.m_sequences[bIdx].prevTradeCount > 0 && g_seqMgr.m_sequences[bIdx].tradeCount == 0)
              {
               if(CooldownBars > 0)
                  activePairs[p].lastBuySeqCloseTime = CurTime;
               activePairs[p].entry_mm_08 = 0;
               activePairs[p].entry_mm_minus18 = 0;
               activePairs[p].entry_mm_minus28 = 0;
               g_seqMgr.m_sequences[bIdx].tradeSymbol = "";
              }
            if(g_seqMgr.m_sequences[sIdx].prevTradeCount > 0 && g_seqMgr.m_sequences[sIdx].tradeCount == 0)
              {
               if(CooldownBars > 0)
                  activePairs[p].lastSellSeqCloseTime = CurTime;
               activePairs[p].entry_mm_88 = 0;
               activePairs[p].entry_mm_plus18 = 0;
               activePairs[p].entry_mm_plus28 = 0;
               g_seqMgr.m_sequences[sIdx].tradeSymbol = "";
              }
          } // end pair loop
         if(EnablePerfTiming)
            perfPairUsAcc += (PerfNowUs() - pairLogicUsStart);
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

      // Dashboard: refresh values every second, reusing existing objects (no full teardown).
      if(firstTickSinceInit || CurTime != lastDashboardRefresh)
        {
         MaybeDrawDashboard();
         lastDashboardRefresh = CurTime;
         firstTickSinceInit = false;
        }
      
      if(bNeedsRedraw)
        {
         ChartRedraw(0);
         bNeedsRedraw = false;
        }
      if(newBar && EnablePerfTiming)
        {
         perfBarsCount++;
         int cadence = (PerfLogEveryNBars <= 0 ? 50 : PerfLogEveryNBars);
         if(perfBarsCount >= cadence)
           {
            double bars = (double)perfBarsCount;
            Print("[Perf] avg_us/bar scan=", DoubleToString((double)perfScanUsAcc / bars, 0),
                  " pair=", DoubleToString((double)perfPairUsAcc / bars, 0),
                  " markov=", DoubleToString((double)perfMarkovUsAcc / bars, 0));
            perfBarsCount = 0;
            perfScanUsAcc = 0;
            perfPairUsAcc = 0;
            perfMarkovUsAcc = 0;
           }
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
         MaybeUpdateLockProfitChartLines();
        }
      MaybeDrawDashboard();
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   // Handle section toggles
   if(sparam == EAName + "_sectgl_sym")
     {
      showSymbols = !showSymbols;
      MaybeDrawDashboard();
      return;
     }
   if(sparam == EAName + "_sectgl_evt")
     {
      showEvents = !showEvents;
      MaybeDrawDashboard();
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
            MaybeUpdateLockProfitChartLines();
           }
         MaybeDrawDashboard();
         return;
        }
     }
   if(sparam == EAName + "_close_all")
     {
      ScanPositions();
      AsyncCloseAll("Dashboard Close All");
      MaybeDrawDashboard();
      return;
     }
   if(sparam == EAName + "_entry_mode")
     {
      dashboardButtonStrategy = (dashboardButtonStrategy == STRAT_MEAN_REVERSION) ? STRAT_TRENDING : STRAT_MEAN_REVERSION;
      MaybeDrawDashboard();
      return;
     }
   if(sparam == EAName + "_close_profit")
     {
      ScanPositions();
      CloseSequencesByNetSign(true);
      MaybeDrawDashboard();
      return;
     }
   if(sparam == EAName + "_close_loss")
     {
      ScanPositions();
      CloseSequencesByNetSign(false);
      MaybeDrawDashboard();
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
      MaybeDrawDashboard();
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
               if(g_seqMgr.m_sequences[s].tradeCount == 0 && !SequenceHasLiveManagedPositions(s))
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
            if(g_seqMgr.m_sequences[seqIdx].magicNumber <= 0)
              {
               g_seqMgr.m_sequences[seqIdx].magicNumber = AllocateUnusedSequenceMagic();
               MarkSequenceMagicCacheDirty();
              }
            g_seqMgr.m_sequences[seqIdx].side = side;  // ensure side matches button click
            dashboardManualOverrideOpenRisk = true;
            bool opened = OpenOrderWithContext(seqIdx, orderType, symbol, strat);
            dashboardManualOverrideOpenRisk = false;
            if(!opened && EnableLogging)
               Print("[DASH_BTN] Start failed on ", symbol, " side=", (side == SIDE_BUY ? "BUY" : "SELL"));
           }
        }

     MaybeDrawDashboard();
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
//| End-of-test per-symbol statistics                                |
//+------------------------------------------------------------------+
void PrintPerSymbolStats()
  {
   if(g_symEquityTrackerCount > 0)
     {
      Print(" ");
      Print("=== End of Test Per-Symbol Statistics ===");
     }
     
   double totalNetProfit = 0;
   double totalGrossProfit = 0;
   double totalGrossLoss = 0;
   double totalMaxDrawdown = 0;
   int totalTrades = 0;
   
   int handle = INVALID_HANDLE;
   if(MQLInfoInteger(MQL_OPTIMIZATION))
     {
      string fileName = "PerSymbolStats_Optimization.csv";
      handle = FileOpen(fileName, FILE_CSV|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON, ",");
      if(handle != INVALID_HANDLE)
        {
         // We only want to write a header once per file. If it's a new file, it will be at pos 0
         if(FileSize(handle) == 0)
           {
            FileWrite(handle, "Pass", "Symbol", "Trades", "NetProfit", "MaxDrawdown", "ProfitFactor", "RecoveryFactor", "R2");
           }
         FileSeek(handle, 0, SEEK_END);
        }
     }
     
   // Inside OnTester, the exact optimization Pass ID isn't directly exposed (it's only in OnTesterDeinit). 
   // Instead, we create a highly unique fingerprint using the final test outcomes (Total Trades + Profit) 
   // so that you can easily match the CSV row to the EXACT pass in the MT5 Optimization Results tab.
   string passStr = "Trds:" + IntegerToString((int)TesterStatistics(STAT_TRADES)) + "_Pl:" + DoubleToString(TesterStatistics(STAT_PROFIT), 2);
   for(int i=0; i<g_symEquityTrackerCount; i++)
     {
      double pf = (g_symEquityTracker[i].grossLoss > 0.0) ? (g_symEquityTracker[i].grossProfit / g_symEquityTracker[i].grossLoss) : (g_symEquityTracker[i].grossProfit > 0.0 ? 999.99 : 0.0);
      double rf = (g_symEquityTracker[i].maxDrawdown > 0.0) ? (g_symEquityTracker[i].closedProfit / g_symEquityTracker[i].maxDrawdown) : (g_symEquityTracker[i].closedProfit > 0.0 ? 999.99 : 0.0);
      
      int n = g_symEquityTracker[i].sampleCount;
      double r2 = 0.0;
      if(n >= 4)
        {
         double meanX = (double)(n - 1) * 0.5;
         double meanY = 0.0;
         for(int j=0; j<n; j++) meanY += g_symEquityTracker[i].equitySamples[j];
         meanY /= (double)n;
         
         double sXY = 0.0, sXX = 0.0;
         for(int j=0; j<n; j++)
           {
            double dx = (double)j - meanX;
            sXY += dx * (g_symEquityTracker[i].equitySamples[j] - meanY);
            sXX += dx * dx;
           }
         if(sXX > 1e-20)
           {
            double slope = sXY / sXX;
            // Only reward positive slope
            if(slope > 0.0)
              {
               double intercept = meanY - slope * meanX;
               double ssTot = 0.0, ssRes = 0.0;
               for(int j=0; j<n; j++)
                 {
                  double predY = intercept + slope * (double)j;
                  ssTot += MathPow(g_symEquityTracker[i].equitySamples[j] - meanY, 2.0);
                  ssRes += MathPow(g_symEquityTracker[i].equitySamples[j] - predY, 2.0);
                 }
               r2 = (ssTot > 1e-20) ? 1.0 - (ssRes / ssTot) : 0.0;
               if(r2 < 0.0) r2 = 0.0;
              }
           }
        }
        
      PrintFormat("Sym: %s | Trades: %d | Net: %.2f | DD: %.2f | PF: %.2f | RF: %.2f | R2: %.4f",
                  g_symEquityTracker[i].symbol, 
                  g_symEquityTracker[i].trades, 
                  g_symEquityTracker[i].closedProfit, 
                  g_symEquityTracker[i].maxDrawdown, 
                  pf, rf, r2);
                  
      totalNetProfit += g_symEquityTracker[i].closedProfit;
      totalTrades += g_symEquityTracker[i].trades;
      
      if(handle != INVALID_HANDLE)
        {
         FileWrite(handle, passStr, g_symEquityTracker[i].symbol, g_symEquityTracker[i].trades, g_symEquityTracker[i].closedProfit, g_symEquityTracker[i].maxDrawdown, pf, rf, r2);
        }
     }
     
   if(g_symEquityTrackerCount > 0)
     {
      // To get accurate True Total DD and Portfolio Equity Metrics, we do NOT use the sum. 
      // We pull them directly from the official TesterStatistics global data!
      double officialNetProfit = TesterStatistics(STAT_PROFIT);
      double officialGrossProfit = TesterStatistics(STAT_GROSS_PROFIT);
      double officialGrossLoss = TesterStatistics(STAT_GROSS_LOSS);
      double officialMaxDD = TesterStatistics(STAT_EQUITY_DD);
      
      double totalPf = (officialGrossLoss > 0.0) ? (officialGrossProfit / officialGrossLoss) : (officialGrossProfit > 0.0 ? 999.99 : 0.0);
      double totalRf = (officialMaxDD > 0.0) ? (officialNetProfit / officialMaxDD) : (officialNetProfit > 0.0 ? 999.99 : 0.0);
      
      // Calculate Global Equity R2 for Total Row
      double totalR2 = 0.0;
      int m = g_equityCount;
      if(m >= 4)
        {
         double meanX = (double)(m - 1) * 0.5;
         double meanY = 0.0;
         for(int j=0; j<m; j++) meanY += g_equitySeries[j];
         meanY /= (double)m;
         
         double sXY = 0.0, sXX = 0.0;
         for(int j=0; j<m; j++)
           {
            double dx = (double)j - meanX;
            sXY += dx * (g_equitySeries[j] - meanY);
            sXX += dx * dx;
           }
         if(sXX > 1e-20)
           {
            double slope = sXY / sXX;
            if(slope > 0.0)
              {
               double intercept = meanY - slope * meanX;
               double ssTot = 0.0, ssRes = 0.0;
               for(int j=0; j<m; j++)
                 {
                  double predY = intercept + slope * (double)j;
                  ssTot += MathPow(g_equitySeries[j] - meanY, 2.0);
                  ssRes += MathPow(g_equitySeries[j] - predY, 2.0);
                 }
               totalR2 = (ssTot > 1e-20) ? 1.0 - (ssRes / ssTot) : 0.0;
               if(totalR2 < 0.0) totalR2 = 0.0;
              }
           }
        }
      
      Print("-----------------------------------------");
      PrintFormat("Total: Trades: %d | Net: %.2f | Max DD: %.2f | PF: %.2f | RF: %.2f | R2: %.4f",
                  totalTrades, officialNetProfit, officialMaxDD, totalPf, totalRf, totalR2);
                  
      if(handle != INVALID_HANDLE)
        {
         FileWrite(handle, passStr, "TOTAL", totalTrades, officialNetProfit, officialMaxDD, totalPf, totalRf, totalR2);
         FileClose(handle);
         Print("Optimizer stats saved to common/tester/files/PerSymbolStats_Optimization.csv");
        }

      Print("=========================================");
      Print(" ");
     }
  }

//+------------------------------------------------------------------+
//|  Custom optimization score for MT5 tester                        |
//|  Zero score if profit<=0 or PF<1                                 |
//|  R²  equity-curve quality gates the score (slope<=0 = zero).    |
//|  Higher: profit, PF, recovery factor                             |
//|  Lower: average/max hold time                                    |
//|  Activity: reward more trades up to ~2/day, penalize <4/month    |
//+------------------------------------------------------------------+
double OnTester()
  {
   UpdateSymbolEquitySamples();
   PrintPerSymbolStats();
   
   double profit = TesterStatistics(STAT_PROFIT);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   if(profit <= 0.0 || pf < 1.0 || !MathIsValidNumber(profit) || !MathIsValidNumber(pf))
      return 0.0;

   double rf = TesterStatistics(STAT_RECOVERY_FACTOR);
   if(!MathIsValidNumber(rf) || rf < 0.0)
      rf = 0.0;

   // --- R² equity-curve quality (primary gating metric) ---
   // Measures how closely the equity series fits a rising straight line.
   //   R² = 1.0  → perfect smooth growth
   //   R² = 0.0  → random / flat
   //   slope <= 0 → score is zeroed (smooth downtrend is not rewarded)
   double r2Penalty = 0.0;
   int n = g_equityCount;
   if(n >= 4)
     {
      // Build x = 0..n-1, y = equity[i]
      double meanX = (double)(n - 1) * 0.5;
      double meanY = 0.0;
      for(int i = 0; i < n; i++)
         meanY += g_equitySeries[i];
      meanY /= (double)n;

      double sXY = 0.0, sXX = 0.0;
      for(int i = 0; i < n; i++)
        {
         double dx = (double)i - meanX;
         sXY += dx * (g_equitySeries[i] - meanY);
         sXX += dx * dx;
        }
      if(sXX > 1e-20)
        {
         double slope    = sXY / sXX;          // $/bar gradient
         double intercept = meanY - slope * meanX;

         // Zero out immediately if trend is flat or negative
         if(slope <= 0.0)
           {
            return 0.0;                        // downtrend → no score
           }

         double ssTot = 0.0, ssRes = 0.0;
         for(int i = 0; i < n; i++)
           {
            double predY = intercept + slope * (double)i;
            ssTot += MathPow(g_equitySeries[i] - meanY, 2);
            ssRes += MathPow(g_equitySeries[i] - predY,  2);
           }
         double r2 = (ssTot > 1e-20) ? 1.0 - ssRes / ssTot : 0.0;
         if(r2 < 0.0) r2 = 0.0;               // clamped: R² in [0, 1]

         // r2Penalty: apply same threshold logic as before
         // R²>=0.97 → full weight; R²<0.97 → crushed exponentially
         double r2Threshold = 0.9;
         if(r2 >= 1.0)
            r2Penalty = 1.0;
         else if(r2 >= r2Threshold)
           {
            double t = (r2 - r2Threshold) / (1.0 - r2Threshold);
            r2Penalty = t;
           }
         else
           {
            double t = MathMax(0.0, r2 / r2Threshold);
            r2Penalty = MathPow(t, 4.0) * 0.05; // max 5% survives below threshold
           }
        }
      else
         r2Penalty = 0.0;
     }
   else
     {
      // Not enough equity data → pass through without penalty (live optimisation
      // of very short tests; r2Penalty=1.0 allows other metrics to determine score)
      r2Penalty = 1.0;
     }
   if(r2Penalty < 0.0)
      r2Penalty = 0.0;

   double avgHoldSec = 0.0, maxHoldSec = 0.0;
   double daysSpan = 0.0, monthsSpan = 0.0, closedPerDay = 0.0, closedPerMonth = 0.0;
   int closedCount = ComputeHoldTimeStats(avgHoldSec, maxHoldSec, daysSpan, monthsSpan,
                                          closedPerDay, closedPerMonth);
   double avgHoldHours = avgHoldSec / 3600.0;
   double maxHoldHours = maxHoldSec / 3600.0;

   // Profit component: blend of log (stability) + direct linear (magnitude).
   double profitLog  = MathLog(1.0 + profit);
   double profitLin  = MathSqrt(profit);
   double profitTerm = 0.60 * profitLog + 0.40 * profitLin;

   double pfTerm = MathMin(5.0, pf);

   // Recovery factor: boosted cap and stronger multiplier.
   double rfTerm = MathMin(20.0, rf);

   // Penalize longer holding durations (both average and worst case).
   double holdPenalty = 1.0 / (1.0 + (avgHoldHours / 6.0) + (maxHoldHours / 24.0));
   if(holdPenalty < 0.0)
      holdPenalty = 0.0;

   // Activity component:
   double minMonthly = 4.0;
   double targetDaily = 2.0;
   double monthlyFactor = 1.0;
   if(closedPerMonth < minMonthly)
     {
      double ratio = closedPerMonth / minMonthly;
      if(ratio < 0.0) ratio = 0.0;
      monthlyFactor = ratio;
     }
   double dailyFactor = 0.0;
   if(closedPerDay <= targetDaily)
      dailyFactor = MathSqrt(MathMax(0.0, closedPerDay / targetDaily));
   else
     {
      double excessRatio = (closedPerDay - targetDaily) / targetDaily;
      dailyFactor = 1.0 + 0.10 * MathMin(1.0, MathLog(1.0 + excessRatio) / MathLog(3.0));
     }
   if(closedCount <= 0)
      dailyFactor = 0.0;

   // Composite: PF anchors quality; RF has 40% weight.
   double qualityTerm  = pfTerm * (1.0 + 0.40 * rfTerm);
   double activityTerm = monthlyFactor * dailyFactor;

   // r2Penalty gates everything: near-zero if equity curve is choppy/flat/declining.
   double score = r2Penalty * profitTerm * qualityTerm * holdPenalty * activityTerm;
   if(!MathIsValidNumber(score) || score < 0.0)
      return 0.0;
   return score;
  }

//+------------------------------------------------------------------+
