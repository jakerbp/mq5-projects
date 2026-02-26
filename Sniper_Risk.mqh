//+------------------------------------------------------------------+
//|                                                  Sniper_Risk.mqh |
//|                   Risk Management & Capital Protection Functions |
//+------------------------------------------------------------------+
#property copyright "ZScoreMurreySniper"
#property strict

//+------------------------------------------------------------------+
//|  DATE MATH HELPERS                                               |
//+------------------------------------------------------------------+
// Safely add days while avoiding landing on a weekend (Saturday/Sunday).
void SafeAddDaysToTime(datetime baseTime, int extraDays, string timeStr, datetime &outTime)
  {
   datetime candidate = baseTime + extraDays * 86400;
   MqlDateTime dt;
   TimeToStruct(candidate, dt);
   // Skip Saturday (6) and Sunday (0)
   while(dt.day_of_week == 0 || dt.day_of_week == 6)
     {
      candidate += 86400;
      TimeToStruct(candidate, dt);
     }
   outTime = StringToTime(TimeToString(candidate, TIME_DATE) + " " + timeStr);
  }

//+------------------------------------------------------------------+
//|  RESTART SCHEDULER                                               |
//+------------------------------------------------------------------+
void ScheduleRestartAfterLoss()
  {
   if(RestartEaAfterLoss == restartOff)
     {
      restartTime = 0;
      time_wait_restart = false;
      return;
     }

   if(RestartEaAfterLoss == restartInHours)
     {
      int hrs = RestartInHours > 0 ? RestartInHours : 1;
      restartTime = TimeCurrent() + hrs * 3600;
      time_wait_restart = true;
      return;
     }

   // restartNextDay (Fixed to jump over weekends safely)
   SafeAddDaysToTime(TimeCurrent(), 1, TimeOfRestart_Equity, restartTime);
   time_wait_restart = true;
   if(EnableLogging) Print("[Restart] EA scheduled to restart at ", TimeToString(restartTime));
  }

//+------------------------------------------------------------------+
//|  HARD STOP / RECOVERY STATUS                                     |
//+------------------------------------------------------------------+
bool CheckStopOfEA()
  {
   if(hard_stop)
     {
      if(restartTime > 0 && TimeCurrent() >= restartTime)
        {
         hard_stop = false;
         stopReason = "";
         restartTime = 0;
         time_wait_restart = false;
         if(EnableLogging) Print("[Restart] Hard stop lifted, resuming operations.");
         return false;
        }
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  WEEKEND CLOSURE                                                 |
//+------------------------------------------------------------------+
// To be called from OnTick. Returns true if EA triggered closure.
bool CheckWeekendClosure()
  {
   if(!CloseAllTradesDisableEA) return false;
   
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   if(dtNow.day_of_week == DayToClose)
     {
      datetime closeTime = StringToTime(TimeToClose);
      if(TimeCurrent() >= closeTime)
        {
         CloseAll("Weekend Close");
         if(!RestartEA_AfterFridayClose)
           {
            hard_stop = true;
            stopReason = "Weekend Closed";
           }
         else
           {
            int daysToRestart = DayToRestart - dtNow.day_of_week;
            if(daysToRestart <= 0) daysToRestart += 7;
            // Fixed weekend calc
            SafeAddDaysToTime(TimeCurrent(), daysToRestart, TimeToRestart, restartTime);
            hard_stop = true;
            stopReason = "Weekend-Restart";
           }
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  EQUITY DRAWDOWN / PROFIT CHECKS                                 |
//+------------------------------------------------------------------+
// Wraps lines 5350-5450 from the original file.
// To be called from OnTick. Returns true if EA triggered hard stop.
bool CheckEquityProtectionAndStops()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

// Per-sequence max loss (close individual sequences, not all)
   if(MaxLossPerSequence > 0)
     {
      for(int sq = 0; sq < MAX_PAIRS * 2; sq++)
        {
         if(sequences[sq].tradeCount > 0 && sequences[sq].plOpen <= -MaxLossPerSequence)
           {
            CloseSequence(sq, "Max Seq Loss (" + DoubleToString(sequences[sq].plOpen, 2) + ")");
           }
        }
     }

// Global equity stop
   if(GlobalEquityStop > 0)
     {
      double eqThreshold = GlobalEquityStop;
      if(GlobalEpType == globalEpAmount)
         eqThreshold = balance - GlobalEquityStop;
      else if(GlobalEpType == globalEpPercent)
         eqThreshold = balance * (1.0 - GlobalEquityStop / 100.0);
      
      if(equity <= eqThreshold)
        {
         CloseAll("Global Equity Stop");
         hard_stop = true;
         stopReason = "Global EQ Stop";
         ScheduleRestartAfterLoss();
         return true;
        }
     }

// Ultimate target
   if(UltimateTargetBalance > 0 && balance >= UltimateTargetBalance)
     {
      CloseAll("Ultimate Target");
      hard_stop = true;
      stopReason = "Target Balance Hit";
      ScheduleRestartAfterLoss();
      return true;
     }

// Daily profit target
   if(ProfitCloseEquityAmount > 0)
     {
      double dayPl = getPlClosedToday() + TotalPlOpenLive();
      if(dayPl >= ProfitCloseEquityAmount)
        {
         CloseAll("Daily Profit Target");
         hard_stop = true;
         stopReason = "Daily Target Hit";
         ScheduleRestartAfterLoss();
         return true;
        }
     }

// Global Rescue Logic
   if(RescueCloseInDrawdown && RescueDrawdownThreshold > 0)
     {
      double totalOpenPL = TotalPlOpenLive();
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
            CloseAll("Rescue Close: Net PL " + DoubleToString(totalOpenPL, 2) + " covers worst draw " + DoubleToString(worstPL, 2));
            return true;
           }
        }
     }
     
   return false; // Did not hit hard stop
  }
