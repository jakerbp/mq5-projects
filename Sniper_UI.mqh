//+------------------------------------------------------------------+
//|                                                    Sniper_UI.mqh |
//|                     User Interface & Dashboard Drawing Functions |
//+------------------------------------------------------------------+
#property copyright "ZScoreMurreySniper"
#property strict

// GLOBAL REDRAW FLAG OPTIMIZATION
bool bNeedsRedraw = false;
const int UI_ROW_PX = 16;
const int UI_SYMBOL_ROW_BG_H = 14;
const int UI_SYMBOL_ROW_BG_YOFF = 1;
const int UI_SYMBOL_BTN_H = 14;
const int UI_SYMBOL_BTN_YOFF = 2;

//+------------------------------------------------------------------+
//|  THEME COLORS                                                    |
//+------------------------------------------------------------------+
color ThemePanelBackground()
  {
   return (VisualTheme == themeLight) ? C'248,250,252' : C'28,32,40';
  }

color ThemePanelBorder()
  {
   return (VisualTheme == themeLight) ? C'210,215,225' : C'60,65,75';
  }

color ThemeTextMain()
  {
   return (VisualTheme == themeLight) ? clrBlack : clrWhite;
  }

color ThemeTextMuted()
  {
   return (VisualTheme == themeLight) ? C'120,130,140' : C'140,150,160';
  }

//+------------------------------------------------------------------+
//|  CHART LINES                                                     |
//+------------------------------------------------------------------+
void UpsertLockLine(string objName, double price, color clr, ENUM_LINE_STYLE style)
  {
   if(price <= 0)
     {
      if(ObjectFind(0, objName) >= 0)
        {
         ObjectDelete(0, objName);
         bNeedsRedraw = true;
        }
      return;
     }

   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_HLINE, 0, 0, price);
      bNeedsRedraw = true;
     }

   double currentPrice = ObjectGetDouble(0, objName, OBJPROP_PRICE);
   if(currentPrice != price)
     {
      ObjectSetDouble(0, objName, OBJPROP_PRICE, price);
      bNeedsRedraw = true;
     }
     
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_STYLE, style);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//|  DASHBOARD LABELS                                                |
//+------------------------------------------------------------------+
void DrawPanelFrame(int lines, int maxChars)
  {
   if(!ShowDashboard) return;

   string bgName = EAName + "_panel_bg";
   if(ObjectFind(0, bgName) < 0)
     {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }

   int pad = 8;
   int rowHeight = UI_ROW_PX;
   int widthPx = DashboardWidthPx > 0 ? DashboardWidthPx : MathMax(560, maxChars * 7 + pad * 2 + panelExtraWidthPx);
   int contentHeight = MathMax(80, lines * rowHeight + pad * 2);
   int heightPx = contentHeight;
   if(DashboardAutoHeight)
     {
      int minH = DashboardMinHeightPx > 0 ? DashboardMinHeightPx : 80;
      heightPx = MathMax(minH, contentHeight);
     }
   else
     {
      heightPx = DashboardHeightPx > 0 ? DashboardHeightPx : contentHeight;
     }

   ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, X_Axis - pad);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, Y_Axis - pad);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, widthPx);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, heightPx);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_WIDTH, 4);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, ThemePanelBackground());
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   ObjectSetInteger(0, bgName, OBJPROP_ZORDER, 0);
  }

void PanelLabel(string name, string text, color clr = clrWhite)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_" + name;
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }
     
   string currentText = ObjectGetString(0, objName, OBJPROP_TEXT);
   if(currentText != text)
     {
      ObjectSetString(0, objName, OBJPROP_TEXT, text);
      bNeedsRedraw = true;
     }

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x_Axis);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + panelLineNo * UI_ROW_PX);
   ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   
   int txtLen = StringLen(text);
   if(txtLen > panelMaxChars) panelMaxChars = txtLen;
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 2);
   panelLineNo++;
  }

void PanelHeaderLabel(string name, string text, color clr = clrWhite)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_" + name;
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }
     
   string currentText = ObjectGetString(0, objName, OBJPROP_TEXT);
   if(currentText != text)
     {
      ObjectSetString(0, objName, OBJPROP_TEXT, text);
      bNeedsRedraw = true;
     }

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x_Axis);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + panelLineNo * UI_ROW_PX);
   ObjectSetString(0, objName, OBJPROP_FONT, "Consolas Bold");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   
   int txtLen = StringLen(text);
   if(txtLen > panelMaxChars) panelMaxChars = txtLen;
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 2);
   panelLineNo++;
  }

void UpsertInlineLabel(string name, string text, int xOffsetPx, int rowLine, color clr, bool bold=false)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_" + name;
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }
     
   string currentText = ObjectGetString(0, objName, OBJPROP_TEXT);
   if(currentText != text)
     {
      ObjectSetString(0, objName, OBJPROP_TEXT, text);
      bNeedsRedraw = true;
     }

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x_Axis + xOffsetPx);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + rowLine * UI_ROW_PX);
   ObjectSetString(0, objName, OBJPROP_FONT, bold ? "Consolas Bold" : "Consolas");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, bold ? 10 : 9);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 2);
  }

//+------------------------------------------------------------------+
//|  DASHBOARD TABLES / BACKGROUNDS                                  |
//+------------------------------------------------------------------+
int GetTableAreaWidth()
  {
   int panelW = DashboardWidthPx > 0 ? DashboardWidthPx : 820;
   int tableW = panelW - 12;
   if(tableW < 700) tableW = 700;
   return tableW;
  }

void DrawSymbolRowBackground(int rowIdx, int rowLine)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_rowbg_" + IntegerToString(rowIdx);
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }

   color rowA = (VisualTheme == themeLight) ? C'255,255,255' : clrBlack;
   color rowB = (VisualTheme == themeLight) ? C'235,238,245' : C'32,36,44';
   color bg = (rowIdx % 2 == 0) ? rowA : rowB;

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, X_Axis - 2);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + rowLine * UI_ROW_PX + UI_SYMBOL_ROW_BG_YOFF);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, GetTableAreaWidth());
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, UI_SYMBOL_ROW_BG_H);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 0);
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 1);
  }

void DrawSectionBand(string key, int rowLine, int widthPx, bool altTone)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_secbg_" + key;
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }

   color bg = ThemePanelBorder();
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, X_Axis - 2);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + rowLine * UI_ROW_PX - 3);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, widthPx);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 0);
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 1);
  }

void DrawHeaderDivider(string key, int rowLine, int widthPx)
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_hdrdiv_" + key;
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      bNeedsRedraw = true;
     }

   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, X_Axis - 2);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, panelPosY + rowLine * UI_ROW_PX - 1);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, widthPx);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, 2);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, ThemePanelBorder());
   ObjectSetInteger(0, objName, OBJPROP_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 0);
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 2);
  }

//+------------------------------------------------------------------+
//|  BUTTONS                                                         |
//+------------------------------------------------------------------+
void UpsertSymbolActionButton(int symbolIdx, int side, int rowLine, bool hasOpenSeq)
  {
   if(!ShowDashboard || symbolIdx < 0 || symbolIdx >= numSymbols) return;
   string sideStr = (side == SIDE_BUY) ? "buy" : "sell";
   string btnName = EAName + "_btn_" + IntegerToString(symbolIdx) + "_" + sideStr;
   if(ObjectFind(0, btnName) < 0)
     {
      ObjectCreate(0, btnName, OBJ_BUTTON, 0, 0, 0);
      bNeedsRedraw = true;
     }

   int btnW = 50;
   int rowOffset = GetTableAreaWidth() - (btnW * 2) - 10;
   int x = X_Axis - 2 + rowOffset + (side == SIDE_BUY ? 0 : btnW + 4);
   int y = panelPosY + rowLine * UI_ROW_PX + UI_SYMBOL_BTN_YOFF;

   string label = (side == SIDE_BUY) ? "BUY" : "SELL";
   if(hasOpenSeq) label = "CLS " + label;
   
   color txtClr = ThemeTextMain();
   color bgClr = hasOpenSeq ? ((VisualTheme == themeLight) ? C'232,235,241' : C'54,58,66') : ((VisualTheme == themeLight) ? C'240,243,248' : C'44,50,62');

   ObjectSetInteger(0, btnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, btnName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, btnName, OBJPROP_XSIZE, btnW);
   ObjectSetInteger(0, btnName, OBJPROP_YSIZE, UI_SYMBOL_BTN_H);
   ObjectSetString(0, btnName, OBJPROP_TEXT, label);
   ObjectSetString(0, btnName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, btnName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, btnName, OBJPROP_COLOR, txtClr);
   ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, btnName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, btnName, OBJPROP_ZORDER, 3);
   ObjectSetInteger(0, btnName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnName, OBJPROP_HIDDEN, false);
  }

void UpsertSectionToggleButton(string name, int x, int rowLine, bool isExpanded)
  {
   if(!ShowDashboard) return;
   string btnName = EAName + "_sectgl_" + name;
   if(ObjectFind(0, btnName) < 0)
     {
      ObjectCreate(0, btnName, OBJ_BUTTON, 0, 0, 0);
      bNeedsRedraw = true;
     }

   int y = panelPosY + rowLine * UI_ROW_PX - 3;
   int w = 18;
   int h = 18;
   string label = isExpanded ? "-" : "+";
   color txtClr = ThemeTextMain();
   color bgClr = ThemePanelBackground();

   ObjectSetInteger(0, btnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, btnName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, btnName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, btnName, OBJPROP_YSIZE, h);
   ObjectSetString(0, btnName, OBJPROP_TEXT, label);
   ObjectSetString(0, btnName, OBJPROP_FONT, "Consolas Bold");
   ObjectSetInteger(0, btnName, OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, btnName, OBJPROP_COLOR, txtClr);
   ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, btnName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, btnName, OBJPROP_ZORDER, 3);
   ObjectSetInteger(0, btnName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnName, OBJPROP_HIDDEN, false);
  }

void UpsertSymbolJumpButton(int symbolIdx, int rowLine, string symbol)
  {
   if(!ShowDashboard || symbolIdx < 0 || symbolIdx >= numSymbols) return;
   string btnName = EAName + "_symgoto_" + IntegerToString(symbolIdx);
   if(ObjectFind(0, btnName) < 0)
     {
      ObjectCreate(0, btnName, OBJ_BUTTON, 0, 0, 0);
      bNeedsRedraw = true;
     }

   int x = X_Axis - 2;
   int y = panelPosY + rowLine * UI_ROW_PX + UI_SYMBOL_BTN_YOFF;
   int w = 74;
   int h = UI_SYMBOL_BTN_H;
   color bg = (VisualTheme == themeLight) ? C'232,235,241' : C'44,50,62';

   ObjectSetInteger(0, btnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, btnName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, btnName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, btnName, OBJPROP_YSIZE, h);
   ObjectSetString(0, btnName, OBJPROP_TEXT, symbol);
   ObjectSetString(0, btnName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, btnName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, btnName, OBJPROP_COLOR, ThemeTextMain());
   ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, btnName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, btnName, OBJPROP_ZORDER, 2);
   ObjectSetInteger(0, btnName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnName, OBJPROP_HIDDEN, false);
  }

void UpsertRestartNowButton()
  {
   if(!ShowDashboard) return;
   string objName = EAName + "_restart_now";
   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);
      bNeedsRedraw = true;
     }

   int panelW = DashboardWidthPx > 0 ? DashboardWidthPx : 820;
   int btnW = 104;
   int btnH = 18;
   int x = X_Axis - 8 + panelW - btnW - 10;
   int y = Y_Axis - 8 + 8;

   color bg = (VisualTheme == themeLight) ? C'235,240,248' : C'48,56,70';
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, btnW);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, btnH);
   ObjectSetString(0, objName, OBJPROP_TEXT, "RESTART NOW");
   ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, ThemeTextMain());
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, ThemePanelBorder());
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER, 3);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, objName, OBJPROP_STATE, false);
  }

//+------------------------------------------------------------------+
//|  CHART CLEANUP                                                   |
//+------------------------------------------------------------------+
void ClearChartIndicatorsAndGrid()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, EAName + "_lock_") >= 0 ||
         StringFind(name, EAName + "_panel_") >= 0 ||
         StringFind(name, EAName + "_rowbg_") >= 0 ||
         StringFind(name, EAName + "_secbg_") >= 0 ||
         StringFind(name, EAName + "_hdrdiv_") >= 0 ||
         StringFind(name, EAName + "_symbtn_") >= 0 ||
         StringFind(name, EAName + "_symgoto_") >= 0 ||
         StringFind(name, EAName + "_restart_now") >= 0 ||
         StringFind(name, EAName + "_") >= 0)
        {
         ObjectDelete(0, name);
        }
     }
   ChartRedraw(0);
   bNeedsRedraw = false;
  }
