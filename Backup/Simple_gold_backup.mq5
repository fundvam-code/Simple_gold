//+------------------------------------------------------------------+
//|                                                  Simple_gold.mq5 |
//|                                      Copyright 2026, Bondarev A. |
//|
//|  Мониторинг + торговля по золоту XAUUSD (ручная/авто):
//|   - Bollinger Bands на основном ТФ (M5/M15)
//|   - монитор-табло: BB, ATR, RSI, ADX, расстояние до полос
//|   - кнопки КУПИТЬ / ПРОДАТЬ с подтверждением вторым нажатием
//|   - режим АВТО: касание BB на M1 -> вход
//|   - SL и TP задаются только в пунктах (параметры)
//|   - фиксированный лот (по умолчанию 0.05)
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bondarev A."
#property link      "https://www.mql5.com"
#property version   "1.55"
#property description "Monitoring + manual/auto trading. Gold XAUUSD."

#include <Trade\Trade.mqh>
#include <ChartObjects\ChartObjectsTxtControls.mqh>

//-------------------- Inputs ---------------------------------------+
input group              "=== Базовые настройки ==="
input string            InpSymbol        = "";            // Символ (пусто = текущий)
input ENUM_TIMEFRAMES   InpMainTF        = PERIOD_M15;    // Основной ТФ (M5/M15)
input long              InpMagic         = 230824;        // Magic number
input double            InpLots          = 0.05;          // Лот (фиксированный) = 0.05
input double            InpRR            = 2.5;           // TP = RR x SL (2.5)
input double            InpATRSLMult     = 1.0;           // SL = множитель x ATR (1)

input group "=== Режим работы ==="
input bool              InpAutoMode      = false;         // Автоторговля: true = АВТО, false = РУЧНОЙ
input double            InpBBOffsetPts   = 0.0;           // Расст. до полосы BB (пт): +N раньше, -N за полосой
input bool              InpAllowBuy      = true;          // Разрешить покупки (авто)
input bool              InpAllowSell     = true;          // Разрешить продажи (авто)
input int               InpReentryMax    = 3;             // Ре-вход после убытка (0 = выкл)
input double            InpReentryPct    = 50.0;          // Порог отката после серии: мид ≤ лин×(1−%)

input group "=== Мониторинг: ATR ==="
input int               InpATRPeriod     = 14;            // Период ATR

input group "=== Мониторинг: Bollinger Bands ==="
input int               InpBBPeriod      = 20;            // Период полос
input double            InpBBDev         = 2.0;           // Отклонение (StdDev)
input ENUM_APPLIED_PRICE InpBBApplied    = PRICE_CLOSE;   // Цена применения

input group "=== Мониторинг: RSI ==="
input bool              InpUseRSI        = true;          // Использовать RSI
input int               InpRSIPeriod     = 14;            // Период RSI
input double            InpRSIOversold   = 30.0;          // Перепроданность (buy)
input double            InpRSIOverbought = 70.0;          // Перекупленность (sell)

input group "=== Мониторинг: ADX ==="
input bool              InpUseADX        = true;          // Использовать ADX
input int               InpADXPeriod     = 14;            // Период ADX
input double            InpADXMin        = 20.0;          // Мин. уровень ADX

input group "=== Алерт к границе ==="
input bool              InpAlertEnable     = true;   // Включить алерт подхода к границе
input double            InpAlertTriggerPts = 50.0;   // Порог срабатывания (пункты до границы)
input bool              InpAlertLocal      = true;   // Алерт в локальный терминал (Alert)
input bool              InpAlertPush       = true;   // Push на телефон (MetaQuotes ID 4C91730F в терминале)

input group "=== Отображение ==="
input bool              InpShowIndicators = true;         // Показывать BB на графике
input bool              InpShowPanel      = true;         // Показывать монитор-табло
input int               InpBtnX           = 830;          // Кнопка Buy: X от левого края
input int               InpBtnY           = 22;           // Кнопка Buy: Y от верха
//+------------------------------------------------------------------+

//-------------------- Global ---------------------------------------+
CTrade               m_trade;         // Торговый объект
string               m_symbol;        // Рабочий символ
int                  m_bbHandle;      // Bollinger Bands
int                  m_rsiHandle;     // RSI
int                  m_adxHandle;     // ADX
int                  m_atrHandle;     // ATR
int                  m_atrH1Handle;   // ATR (H1)

CChartObjectButton   m_btnBuy;
CChartObjectButton   m_btnSell;
CChartObjectButton   m_btnSig;
CChartObjectButton   m_btnMode;
string               m_btnBuyName  = "SG_BuyBtn";
string               m_btnSellName = "SG_SellBtn";
string               m_btnSigName  = "SG_SigBtn";
string               m_btnModeName = "SG_ModeBtn";
bool                 g_autoMode    = false;   // Режим: true = АВТО / false = РУЧНОЙ
bool                 g_armedBuy  = false;
bool                 g_armedSell = false;
bool                 g_signalOn  = true;    // Мастер-выключатель сигнала

datetime             g_lastM1Bar = 0;
ulong                g_autoPosTicket = 0;    // Тикет открытой авто-позиции (0 = нет)
int                  g_autoDir       = 0;    // Направление авто-позиции: +1 buy / -1 sell
int                  g_reentryCount  = 0;    // Сколько ре-входов подряд после убытка
double               g_bbUp=0, g_bbMid=0, g_bbLow=0;  // Текущие полосы BB
double               g_breakLevel    = 0;    // Уровень линии пробоя (для ре-входа)
double               g_chanWidth     = 0;    // Ширина канала BB при последней сделке
bool                 g_reentryPending= false;// Ждём откат цены для ре-входа
string               g_log[14];              // Лог событий на графике (внизу)
bool                 g_alertArmed   = true;   // Мониторинг подхода к границе активен
bool                 g_alertWaiting = false;  // Пауза: ждём возврата к средней
int                  g_alertSide    = 0;      // Сторона срабатывания: +1 верх / -1 низ
//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   m_symbol = (InpSymbol=="" ? _Symbol : InpSymbol);
   if(!SymbolSelect(m_symbol,true))
     {
      Print("Ошибка выбора символа ",m_symbol);
      return(INIT_FAILED);
     }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetTypeFillingBySymbol(m_symbol);
   m_trade.SetDeviationInPoints(50);

   m_bbHandle  = iBands(m_symbol,InpMainTF,InpBBPeriod,0,InpBBDev,InpBBApplied);
   m_atrHandle = iATR(m_symbol,InpMainTF,InpATRPeriod);
   m_atrH1Handle = iATR(m_symbol,PERIOD_H1,InpATRPeriod);
   m_rsiHandle = (InpUseRSI ? iRSI(m_symbol,InpMainTF,InpRSIPeriod,PRICE_CLOSE) : INVALID_HANDLE);
   m_adxHandle = (InpUseADX ? iADX(m_symbol,InpMainTF,InpADXPeriod)            : INVALID_HANDLE);

   if(m_bbHandle==INVALID_HANDLE || m_atrHandle==INVALID_HANDLE ||
      m_atrH1Handle==INVALID_HANDLE ||
      (InpUseRSI && m_rsiHandle==INVALID_HANDLE) ||
      (InpUseADX && m_adxHandle==INVALID_HANDLE))
      return(INIT_FAILED);

   g_autoMode = InpAutoMode;

   //--- Удаляем возможные старые объекты панели (от прошлых версий), чтобы не мешали
   ObjectDelete(0,"SG_Panel");
   ObjectDelete(0,"SG_PanelBg");
   ObjectDelete(0,"SG_Log");
   ObjectDelete(0,"SG_rsi");
   ObjectDelete(0,"SG_Info");

   if(!CreateTradeButtons())
      Print("Ошибка создания кнопок.");

   g_alertArmed   = true;
   g_alertWaiting = false;
   g_alertSide    = 0;

   //--- Если после перезапуска уже есть авто-позиция - запоминаем её
   g_autoPosTicket = 0;
   g_autoDir       = 0;
   g_reentryCount  = 0;
   g_breakLevel    = 0;
   g_chanWidth     = 0;
   g_reentryPending= false;
   g_bbUp=0; g_bbMid=0; g_bbLow=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==m_symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         StringFind(PositionGetString(POSITION_COMMENT),"SG Auto")>=0)
        {
         g_autoPosTicket = t;
         g_autoDir = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
         break;
        }
     }

   //--- Сразу рисуем надпись, чтобы текст был виден с момента запуска
   DrawInfoText(StringFormat("== %s %s ==\nЗагрузка...",m_symbol,EnumToString(InpMainTF)));
   AddLog("Советник запущен");

   Print("Инициализировано. ТФ:",EnumToString(InpMainTF),
         ", Лот:",InpLots,", SL:",InpATRSLMult,"xATR, RR:",InpRR);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0,"SG_Panel");
   ObjectDelete(0,"SG_rsi");
   ObjectDelete(0,"SG_Info");
   Comment("");   // очищаем встроенную надпись
   DeleteTradeButtons();
   DeleteBandObjects();
   if(m_bbHandle !=INVALID_HANDLE) IndicatorRelease(m_bbHandle);
   if(m_rsiHandle!=INVALID_HANDLE) IndicatorRelease(m_rsiHandle);
   if(m_adxHandle!=INVALID_HANDLE) IndicatorRelease(m_adxHandle);
   if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
   if(m_atrH1Handle!=INVALID_HANDLE) IndicatorRelease(m_atrH1Handle);
  }
//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdatePanel();          // чтение индикаторов + отрисовка + алерты
   //--- Торговая логика выполняется ВСЕГДА, даже если индикаторы временно не читаются
   CheckAutoPositionClose();   // обработка закрытия (убыток -> ожидание отката)
   CheckReentry();             // ре-вход по откату цены к середине
  }
//+------------------------------------------------------------------+
//| OnChartEvent                                                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == m_btnBuyName)
     {
      m_btnBuy.State(false);
      HandleTradeClick(true);
     }
   else if(sparam == m_btnSellName)
     {
      m_btnSell.State(false);
      HandleTradeClick(false);
     }
   else if(sparam == m_btnSigName)
     {
      m_btnSig.State(false);
      ToggleSignal();
     }
   else if(sparam == m_btnModeName)
     {
      m_btnMode.State(false);
      ToggleAutoMode();
     }
  }
//+------------------------------------------------------------------+
//| Переключение мастер-выключателя сигнала                          |
//+------------------------------------------------------------------+
void ToggleSignal()
  {
   g_signalOn = !g_signalOn;
   UpdateSignalButton();
   if(g_signalOn)
     {
      Print("Сигнал ВКЛЮЧЁН.");
      AddLog("СИГНАЛ: ВКЛ");
     }
   else
     {
      Print("Сигнал ВЫКЛЮЧЕН.");
      AddLog("СИГНАЛ: ВЫКЛ");
      ResetArmed();   // сбрасываем подтверждение покупки/продажи
     }
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Обновление внешнего вида кнопки сигнала                          |
//+------------------------------------------------------------------+
void UpdateSignalButton()
  {
   if(g_signalOn)
     {
      m_btnSig.Description("СИГНАЛ: ВКЛ");
      m_btnSig.BackColor(clrGreen);
      m_btnSig.BorderColor(clrDarkGreen);
     }
   else
     {
      m_btnSig.Description("СИГНАЛ: ВЫКЛ");
      m_btnSig.BackColor(clrRed);
      m_btnSig.BorderColor(clrDarkRed);
     }
  }
//+------------------------------------------------------------------+
//| Переключение режима: ручной / авто                               |
//+------------------------------------------------------------------+
void ToggleAutoMode()
  {
   g_autoMode = !g_autoMode;
   ResetArmed();
   UpdateModeButton();
   if(g_autoMode)
     {
      Print("Режим АВТО: торговля автоматическая, кнопки отключены.");
      AddLog("РЕЖИМ: АВТО");
     }
   else
     {
      Print("Режим РУЧНОЙ: торговля кнопками.");
      AddLog("РЕЖИМ: РУЧНОЙ");
     }
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Обновление внешнего вида кнопки режима                           |
//+------------------------------------------------------------------+
void UpdateModeButton()
  {
   if(g_autoMode)
     {
      m_btnMode.Description("РЕЖИМ: АВТО");
      m_btnMode.BackColor(clrBlue);
      m_btnMode.BorderColor(clrDarkBlue);
     }
   else
     {
      m_btnMode.Description("РЕЖИМ: РУЧНОЙ");
      m_btnMode.BackColor(clrGray);
      m_btnMode.BorderColor(clrDarkGray);
     }
  }
//+------------------------------------------------------------------+
//| Клик кнопок (2 клика = подтверждение)                            |
//+------------------------------------------------------------------+
void HandleTradeClick(const bool isBuy)
  {
   if(!g_signalOn)
     {
      Print("Сигнал выключен - сделка не открыта. Включите сигнал кнопкой СИГНАЛ.");
      ResetArmed();
      return;
     }
   if(g_autoMode)
     {
      Print("Режим АВТО - ручные кнопки отключены. Переключите режим на РУЧНОЙ.");
      ResetArmed();
      return;
     }
   if(isBuy)
     {
      if(!g_armedBuy)
        {
         ResetArmed();
         g_armedBuy = true;
         m_btnBuy.Description("ПОДТВЕРДИТЬ ПОКУПКУ");
         m_btnBuy.BackColor(clrOrange);
         m_btnBuy.BorderColor(clrDarkOrange);
         ChartRedraw();
         return;
        }
      OpenManualTrade(ORDER_TYPE_BUY);
     }
   else
     {
      if(!g_armedSell)
        {
         ResetArmed();
         g_armedSell = true;
         m_btnSell.Description("ПОДТВЕРДИТЬ ПРОДАЖУ");
         m_btnSell.BackColor(clrOrange);
         m_btnSell.BorderColor(clrDarkOrange);
         ChartRedraw();
         return;
        }
      OpenManualTrade(ORDER_TYPE_SELL);
     }
  }
//+------------------------------------------------------------------+
//| Сброс подтверждения                                              |
//+------------------------------------------------------------------+
void ResetArmed()
  {
   if(g_armedBuy)
     {
      m_btnBuy.Description("КУПИТЬ");
      m_btnBuy.BackColor(clrGreen);
      m_btnBuy.BorderColor(clrDarkGreen);
     }
   if(g_armedSell)
     {
      m_btnSell.Description("ПРОДАТЬ");
      m_btnSell.BackColor(clrRed);
      m_btnSell.BorderColor(clrDarkRed);
     }
   g_armedBuy  = false;
   g_armedSell = false;
  }
//+------------------------------------------------------------------+
//| Создание кнопок                                                  |
//+------------------------------------------------------------------+
bool CreateTradeButtons()
  {
   if(!m_btnBuy.Create(0,m_btnBuyName,0,InpBtnX,InpBtnY,130,28))
      return(false);
   m_btnBuy.Description("КУПИТЬ");
   m_btnBuy.Font("Arial"); m_btnBuy.FontSize(11); m_btnBuy.Color(clrWhite);
   m_btnBuy.BackColor(clrGreen); m_btnBuy.BorderColor(clrDarkGreen);
   m_btnBuy.Corner(CORNER_LEFT_UPPER);
   m_btnBuy.Selectable(false); m_btnBuy.Z_Order(0); m_btnBuy.State(false);

   if(!m_btnSell.Create(0,m_btnSellName,0,InpBtnX+140,InpBtnY,130,28))
      return(false);
   m_btnSell.Description("ПРОДАТЬ");
   m_btnSell.Font("Arial"); m_btnSell.FontSize(11); m_btnSell.Color(clrWhite);
   m_btnSell.BackColor(clrRed); m_btnSell.BorderColor(clrDarkRed);
   m_btnSell.Corner(CORNER_LEFT_UPPER);
   m_btnSell.Selectable(false); m_btnSell.Z_Order(0); m_btnSell.State(false);

   //--- Кнопка мастер-выключателя сигнала (под кнопками Buy/Sell)
   const int sigY = InpBtnY + 34;
   if(!m_btnSig.Create(0,m_btnSigName,0,InpBtnX,sigY,270,28))
      return(false);
   m_btnSig.Font("Arial"); m_btnSig.FontSize(11); m_btnSig.Color(clrWhite);
   m_btnSig.Corner(CORNER_LEFT_UPPER);
   m_btnSig.Selectable(false); m_btnSig.Z_Order(0); m_btnSig.State(false);
   UpdateSignalButton();   // задаёт надпись и цвет по текущему состоянию

   //--- Кнопка переключения режима (под кнопкой сигнала)
   const int modeY = sigY + 34;
   if(!m_btnMode.Create(0,m_btnModeName,0,InpBtnX,modeY,270,28))
      return(false);
   m_btnMode.Font("Arial"); m_btnMode.FontSize(11); m_btnMode.Color(clrWhite);
   m_btnMode.Corner(CORNER_LEFT_UPPER);
   m_btnMode.Selectable(false); m_btnMode.Z_Order(0); m_btnMode.State(false);
   UpdateModeButton();   // надпись/цвет по текущему режиму

   ChartRedraw();
   return(true);
  }
void DeleteTradeButtons()
  {
   m_btnBuy.Delete();
   m_btnSell.Delete();
   m_btnSig.Delete();
   m_btnMode.Delete();
  }
//+------------------------------------------------------------------+
//| Ручное открытие сделки: SL = ATR*mult, TP = RR*SL                |
//+------------------------------------------------------------------+
bool OpenManualTrade(const ENUM_ORDER_TYPE type,const bool isAuto=false)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      Print("Торговля запрещена в терминале");
      ResetArmed();
      return(false);
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Print("Торговля запрещена в советнике");
      ResetArmed();
      return(false);
     }

   const double ask    = SymbolInfoDouble(m_symbol,SYMBOL_ASK);
   const double bid    = SymbolInfoDouble(m_symbol,SYMBOL_BID);
   const int    digits = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);

   double atrArr[];
   ArraySetAsSeries(atrArr,true);
   if(CopyBuffer(m_atrHandle,0,1,1,atrArr)!=1)
     {
      Print("Ошибка чтения ATR");
      ResetArmed();
      return(false);
     }
   const double atrVal = atrArr[0];
   if(atrVal <= 0)
     {
      Print("ATR<=0");
      ResetArmed();
      return(false);
     }

   const double slDist = atrVal * InpATRSLMult;
   const double tpDist = slDist * InpRR;

   double sl=0,tp=0;
   if(type==ORDER_TYPE_BUY)
     { sl = NormalizeDouble(bid-slDist,digits); tp = NormalizeDouble(bid+tpDist,digits); }
   else
     { sl = NormalizeDouble(bid+slDist,digits); tp = NormalizeDouble(bid-tpDist,digits); }

   const double stopLv = (double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   if(MathAbs(sl-bid)<stopLv || MathAbs(tp-bid)<stopLv)
     {
      Print("SL/TP слишком близко к цене");
      ResetArmed();
      return(false);
     }

   const double lot = NormalizeLot(InpLots);
   if(lot<=0)
     {
      Print("Некорректный лот ",InpLots);
      ResetArmed();
      return(false);
     }

   bool done;
   string comment;
   if(isAuto)
      comment = (type==ORDER_TYPE_BUY ? "SG Auto BUY" : "SG Auto SELL");
   else
      comment = (type==ORDER_TYPE_BUY ? "SG Manual BUY":"SG Manual SELL");
   if(type==ORDER_TYPE_BUY)
      done = m_trade.Buy(lot,m_symbol,ask,sl,tp,comment);
   else
      done = m_trade.Sell(lot,m_symbol,bid,sl,tp,comment);

   if(done)
     {
      if(isAuto)
        {
         g_autoPosTicket = m_trade.ResultOrder();
         g_autoDir = (type==ORDER_TYPE_BUY ? 1 : -1);
        }
      Print("Открыта сделка ",EnumToString(type),
            " лот=",lot," SL=",DoubleToString(sl,digits)," TP=",DoubleToString(tp,digits));
      AddLog(StringFormat("Открыта %s лот=%.2f SL=%s TP=%s",
             (type==ORDER_TYPE_BUY ? "BUY":"SELL"),lot,
             DoubleToString(sl,digits),DoubleToString(tp,digits)));
     }
   else
     {
      Print("Ошибка открытия: ",m_trade.ResultRetcode()," ",m_trade.ResultRetcodeDescription());
      AddLog(StringFormat("Ошибка открытия: %s",m_trade.ResultRetcodeDescription()));
     }

   ResetArmed();
   return(done);
  }
//+------------------------------------------------------------------+
//| Проверка наличия открытой позиции по символу и магии             |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==m_symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
         return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Проверка наличия открытой АВТО-позиции (комментарий SG Auto)     |
//+------------------------------------------------------------------+
bool HasAutoPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==m_symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         StringFind(PositionGetString(POSITION_COMMENT),"SG Auto")>=0)
         return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Отслеживание закрытия авто-позиции: убыток -> ре-вход            |
//+------------------------------------------------------------------+
void CheckAutoPositionClose()
  {
   if(g_autoPosTicket==0) return;

   //--- Позиция ещё открыта?
   if(PositionSelectByTicket(g_autoPosTicket))
      return;

   //--- Закрылась: считаем результат по истории (профит + своп)
   double total=0;
   bool   gotResult=false;
   if(HistorySelectByPosition((long)g_autoPosTicket))
     {
      const int n = HistoryDealsTotal();
      if(n>0) gotResult=true;
      for(int i=0;i<n;i++)
        {
         const ulong dt = HistoryDealGetTicket(i);
         if(dt==0) continue;
         total += HistoryDealGetDouble(dt,DEAL_PROFIT);
         total += HistoryDealGetDouble(dt,DEAL_SWAP);
        }
     }

   if(!gotResult)
     {
      // Не удалось получить результат - просто сбрасываем отслеживание
      g_autoPosTicket = 0;
      g_autoDir       = 0;
      g_reentryCount  = 0;
      g_breakLevel    = 0;
      g_chanWidth     = 0;
      g_reentryPending= false;
      return;
     }

   const bool loss = (total < 0);
   g_autoPosTicket = 0;   // позиция закрыта, тикет больше не отслеживаем

   if(!loss)
     {
      // Прибыль - серия завершена
      Print("Авто: сделка в прибыль (",DoubleToString(total,2),"), серия ре-входов сброшена");
      AddLog(StringFormat("Прибыль %s, серия сброшена",DoubleToString(total,2)));
      g_autoDir        = 0;
      g_reentryCount   = 0;
      g_breakLevel     = 0;
      g_chanWidth      = 0;
      g_reentryPending = false;
      return;
     }

   //--- Убыток
   if(InpReentryMax<=0)
     {
      Print("Авто: убыток (",DoubleToString(total,2),"), ре-входы выключены");
      AddLog(StringFormat("Убыток %s, ре-входы выкл",DoubleToString(total,2)));
      g_autoDir        = 0;
      g_reentryCount   = 0;
      g_breakLevel     = 0;
      g_chanWidth      = 0;
      g_reentryPending = false;
      return;
     }

   //--- Серия не исчерпана -> сразу ре-вход в том же направлении
   if(g_reentryCount < InpReentryMax)
     {
      g_reentryCount++;
      Print("Авто: убыток (",DoubleToString(total,2),"), ре-вход #",g_reentryCount,
            " из ",InpReentryMax," в том же направлении");
      AddLog(StringFormat("Убыток %s -> ре-вход #%d/%d",
             DoubleToString(total,2),g_reentryCount,InpReentryMax));

      const bool opened = (g_autoDir==1 ? OpenManualTrade(ORDER_TYPE_BUY,true)
                                        : OpenManualTrade(ORDER_TYPE_SELL,true));
      if(opened)
         return;   // тикет обновится в OpenManualTrade, продолжаем отслеживать
      // не удалось открыть - сбрасываем серию
      g_autoDir        = 0;
      g_reentryCount   = 0;
      g_breakLevel     = 0;
      g_chanWidth      = 0;
      return;
     }

   //--- Серия исчерпана: ждём откат, пока разница мид/лин не достигнет порога
   Print("Авто: убыток (",DoubleToString(total,2),"), серия из ",g_reentryCount,
         " исчерпана, ждём откат");
   AddLog("Серия исчерпана, ждём откат");
   g_reentryPending = true;
  }
//+------------------------------------------------------------------+
//| Ре-вход: ждём откат цены от линии пробоя к середине BB           |
//+------------------------------------------------------------------+
void CheckReentry()
  {
   if(!g_reentryPending || g_autoDir==0) return;
   if(!g_signalOn || !g_autoMode)        return;
   if(HasAutoPosition())                  return;
   if(g_breakLevel==0 || g_bbMid<=0)      return;   // нет базы

   const double bid   = SymbolInfoDouble(m_symbol,SYMBOL_BID);
   const double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);

   //--- Расстояние до линии пробоя и до середины (в пунктах)
   double distLine, distMid;
   if(g_autoDir== 1)
      distLine = (bid - g_breakLevel)/point;    // от нижней полосы вверх
   else
      distLine = (g_breakLevel - bid)/point;    // от верхней полосы вниз
   distMid = MathAbs(bid - g_bbMid)/point;
   if(distLine<=0) return;

   //--- Порог: когда разница между мид и лин достигнет заданного %
   const double pct   = InpReentryPct/100.0;
   const double limit = distLine*(1.0-pct);
   if(distMid > limit) return;   // ещё не достигнут порог

   Print("Авто: откат достигнут, сбрасываем ожидание, ждём сигнал");
   AddLog("Откат достигнут, ждём сигнал");

   //--- Сброс: серия завершена, авто снова ждёт касание BB
   g_reentryPending = false;
   g_reentryCount   = 0;
   g_breakLevel     = 0;
   g_chanWidth      = 0;
  }
//+------------------------------------------------------------------+
//| Автоторговля: касание BB + подтверждение M1                     |
//+------------------------------------------------------------------+
void CheckAutoTrade(const int touch)
  {
   if(!g_signalOn || !g_autoMode) return;
   if(g_reentryPending) return;    // ждём откат после исчерпания серии - новые сигналы не открываем
   if(HasAutoPosition()) return;   // только одна авто-сделка за раз

   //--- Касание нижней полосы M1 -> BUY, верхней -> SELL
   if(touch== 1 && InpAllowBuy)
     {
      g_breakLevel = g_bbLow;                              // линия пробоя (нижняя)
      g_chanWidth  = g_bbUp - g_bbLow;                     // ширина канала при входе
      OpenManualTrade(ORDER_TYPE_BUY,true);
     }
   else if(touch==-1 && InpAllowSell)
     {
      g_breakLevel = g_bbUp;                               // линия пробоя (верхняя)
      g_chanWidth  = g_bbUp - g_bbLow;                     // ширина канала при входе
      OpenManualTrade(ORDER_TYPE_SELL,true);
     }
  }
//+------------------------------------------------------------------+
//| Нормализация лота                                                |
//+------------------------------------------------------------------+
double NormalizeLot(const double lots)
  {
   const double step   = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
   const double minvol = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
   double lot = MathFloor(lots/step)*step;
   if(lot<minvol) lot=minvol;
   const int ld = (int)MathCeil(-MathLog10(step)-0.001);
   return(NormalizeDouble(lot,ld));
  }
//+------------------------------------------------------------------+
//| Чтение индикаторов для табло                                    |
//+------------------------------------------------------------------+
int ReadIndicators(double &up,double &mid,double &low,double &atr,
                   double &rsi,double &adx,double &pdi,double &mdi,
                   int &touch,double &distUp,double &distLow)
  {
   double upA[],midA[],lowA[];
   if(!ComputeBands(0,3,upA,midA,lowA))
      return(-1);
   up=upA[0]; mid=midA[0]; low=lowA[0];

   const double bid   = SymbolInfoDouble(m_symbol,SYMBOL_BID);
   const double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   distUp  = (up-bid)/point;
   distLow = (bid-low)/point;

   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(m_atrHandle,0,1,1,a)==1) atr=a[0]; else atr=0;

   if(InpUseRSI){ double r[]; ArraySetAsSeries(r,true);
      if(CopyBuffer(m_rsiHandle,0,1,1,r)==1) rsi=r[0]; }
   if(InpUseADX){ double b[]; ArraySetAsSeries(b,true);
      if(CopyBuffer(m_adxHandle,0,1,1,b)==1) adx=b[0];
      if(CopyBuffer(m_adxHandle,1,1,1,b)==1) pdi=b[0];
      if(CopyBuffer(m_adxHandle,2,1,1,b)==1) mdi=b[0]; }

   double m1Hi[],m1Lo[];
   ArraySetAsSeries(m1Hi,true); ArraySetAsSeries(m1Lo,true);
   if(CopyHigh(m_symbol,PERIOD_M1,1,2,m1Hi)!=2) return(-1);   // 2 закрытых M1-бара
   if(CopyLow(m_symbol,PERIOD_M1,1,2,m1Lo)!=2)  return(-1);

   const double touchOff = InpBBOffsetPts*point;   // +N: раньше полосы, -N: за полосой
   const bool tLow  = (m1Lo[1] <= lowA[0]+touchOff);
   const bool tHigh = (m1Hi[1] >= upA[0]-touchOff);
   touch = 0;
   if(tLow)  touch =  1;
   if(tHigh) touch = -1;
   return(0);
  }
//+------------------------------------------------------------------+
//| Обновление табло                                                 |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   const double  bid   = SymbolInfoDouble(m_symbol,SYMBOL_BID);
   const double  point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   const datetime m1Now = iTime(m_symbol,PERIOD_M1,0);

   double up=0,mid=0,low=0,atr=0,rsi=50,adx=0,pdi=0,mdi=0,distUp=0,distLow=0;
   int touch=0;
   if(ReadIndicators(up,mid,low,atr,rsi,adx,pdi,mdi,touch,distUp,distLow)!=0)
      return;

   g_bbUp=up; g_bbMid=mid; g_bbLow=low;   // для ре-входа по откату

   const bool newM = (m1Now != g_lastM1Bar);
   if(newM)
      g_lastM1Bar = m1Now;

   string posStr = "внутри";
   if(bid<=low) posStr = "ниже нижней";
   if(bid>=up)  posStr = "выше верхней";

   string touchStr = "нет";
   if(touch== 1) touchStr="касание НИЖНЕЙ";
   if(touch==-1) touchStr="касание ВЕРХНЕЙ";

   const double slVal = atr*InpATRSLMult;
   const double tpVal = slVal*InpRR;

   const string sigState = (g_signalOn ? "ВКЛ" : "ВЫКЛ");
   const string modeState = (g_autoMode ? "АВТО" : "РУЧНОЙ");
   string statStr = "ждем сигнал";
   if(g_reentryPending)
      statStr = "блок: откат после серии";
   //--- Информация об откате: расстояние до ближайшей линии и до середины
   string retraceInfo = "-";
   if(g_reentryPending && g_bbMid>0 && g_bbUp>0 && g_bbLow>0)
     {
      const double distUp   = MathAbs(bid-g_bbUp)/point;    // до верхней линии
      const double distLow  = MathAbs(bid-g_bbLow)/point;   // до нижней линии
      const double distNear = MathMin(distUp,distLow);      // до ближайшей линии
      const double distMid  = MathAbs(bid-g_bbMid)/point;   // до середины
      retraceInfo = StringFormat("%s (лин %.0f / мид %.0f пт)",
                     (g_autoDir==1 ? "BUY":"SELL"),distNear,distMid);
     }
   const string s = StringFormat("== %s %s ==\n"
              "СИГНАЛ  : %s\n"
              "РЕЖИМ   : %s\n"
              "Цена    : %.2f\n"
              "BB верх : %.2f   (до %.1f пт)\n"
              "BB сред : %.2f\n"
              "BB низ  : %.2f   (до %.1f пт)\n"
              "Позиция : %s\n"
              "ATR  : %.2f   RSI: %.1f\n"
              "ADX  : %.1f   +DI: %.1f -DI: %.1f\n"
              "SL    : %.1f пт (%.2f)\n"
              "TP    : %.1f пт (%.2f)\n"
              "Вход BB: %+.0f пт\n"
              "Статус  : %s\n"
              "Ре-вход: %d/%d\n"
              "Откат  : %s\n"
              "Касание : %s\n",
              m_symbol,EnumToString(InpMainTF),
              sigState,
              modeState,
              bid,
              up,  distUp,
              mid,
              low, distLow,
              posStr,
              atr, rsi,
              adx, pdi, mdi,
              slVal/point, slVal,
              tpVal/point, tpVal,
              InpBBOffsetPts,
              statStr,
              g_reentryCount, InpReentryMax,
              retraceInfo,
              touchStr);

   const bool isTest = (bool)MQLInfoInteger(MQL_TESTER);
   const bool isVis  = (bool)MQLInfoInteger(MQL_VISUAL_MODE);
   if(InpShowPanel && (!isTest || isVis))
     {
      DrawInfoText(s);        // вся информация (статус + лог) - надпись на графике
      DrawDistance(bid,up,low);
      if(InpShowIndicators)
         DrawBands(120);
     }

   CheckBoundaryAlert(up,mid,low,bid,point);
   CheckAutoTrade(touch);      // вход по касанию BB
   if(newM)
      Print(" | ",TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES));
  }
//+------------------------------------------------------------------+
//| Ручной расчёт полос Боллинджера                                 |
//+------------------------------------------------------------------+
bool ComputeBands(const int shift,const int count,double &up[],double &midB[],double &lowB[])
  {
   const int need = shift+count+InpBBPeriod+2;
   double cl[];
   ArraySetAsSeries(cl,true);
   if(CopyClose(m_symbol,InpMainTF,0,need,cl) < need)
      return(false);
   ArrayResize(up,count); ArrayResize(midB,count); ArrayResize(lowB,count);
   for(int i=shift;i<shift+count;i++)
     {
      double sum=0;
      for(int j=i;j<i+InpBBPeriod;j++) sum+=cl[j];
      const double ma = sum/InpBBPeriod;
      double var=0;
      for(int j=i;j<i+InpBBPeriod;j++)
        {
         const double d = cl[j]-ma;
         var += d*d;
        }
      const double sd = MathSqrt(var/InpBBPeriod);
      const int k = i-shift;
      midB[k]=ma; up[k]=ma+InpBBDev*sd; lowB[k]=ma-InpBBDev*sd;
     }
   return(true);
  }
//+------------------------------------------------------------------+
//| Отрисовка полос и расстояний                                     |
//+------------------------------------------------------------------+
void DrawSegment(const string name,const color clr,const datetime &tm[],const double &v[],const int n)
  {
   const int seg=24;
   for(int a=0;a<seg;a++)
     {
      const int i0=(int)((double)a    /seg*(n-1.0));
      const int i1=(int)((double)(a+1)/seg*(n-1.0));
      const string on = StringFormat("%s_%d",name,a);
      if(ObjectFind(0,on)<0)
        {
         ObjectCreate(0,on,OBJ_TREND,0,tm[i0],v[i0],tm[i1],v[i1]);
         ObjectSetInteger(0,on,OBJPROP_RAY_RIGHT,false);
         ObjectSetInteger(0,on,OBJPROP_WIDTH,1);
         ObjectSetInteger(0,on,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,on,OBJPROP_HIDDEN,true);
        }
      else
        {
         ObjectMove(0,on,0,tm[i0],v[i0]);
         ObjectMove(0,on,1,tm[i1],v[i1]);
        }
      ObjectSetInteger(0,on,OBJPROP_COLOR,clr);
     }
  }
void DrawBands(const int n)
  {
   double upA[],midA[],lowA[];
   if(!ComputeBands(0,n,upA,midA,lowA)) return;
   datetime tm[];
   ArraySetAsSeries(tm,true);
   if(CopyTime(m_symbol,InpMainTF,0,n,tm)<n) return;
   DrawSegment("SG_bUp", clrDodgerBlue,tm,upA,  n);
   DrawSegment("SG_bMid",clrYellow,    tm,midA, n);
   DrawSegment("SG_bLow",clrOrange,    tm,lowA, n);
  }
void DrawDistance(const double bid,const double upB,const double lowB)
  {
   const datetime t0 = iTime(m_symbol,InpMainTF,0);
   const double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   if(t0==0) return;

   if(ObjectFind(0,"SG_bid")<0)
      ObjectCreate(0,"SG_bid",OBJ_HLINE,0,0,bid);
   ObjectSetDouble(0,"SG_bid",OBJPROP_PRICE,bid);
   ObjectSetInteger(0,"SG_bid",OBJPROP_COLOR,clrYellow);
   ObjectSetInteger(0,"SG_bid",OBJPROP_WIDTH,1);

   HelperTrend("SG_dUp",t0,upB,  t0,bid,clrLime,STYLE_DASH);
   HelperTrend("SG_dDn",t0,bid,  t0,lowB,clrRed,STYLE_DASH);

   //--- Подпись с расстояниями возле текущей цены (2 строки)
   const double dUp  = (upB - bid)/point;
   const double dDn  = (bid - lowB)/point;
   double atrH1 = 0;
   double h1a[];
   ArraySetAsSeries(h1a,true);
   if(CopyBuffer(m_atrH1Handle,0,1,1,h1a)==1) atrH1 = h1a[0];
   const int digits = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   const string lbl  = StringFormat("UP: %.0f пт\nDN: %.0f пт\nСигнал: %.0f пт\nATR H1: %s", dUp, dDn, InpAlertTriggerPts, DoubleToString(atrH1,digits));

   if(ObjectFind(0,"SG_dist")<0)
     {
      ObjectCreate(0,"SG_dist_bg",OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_XSIZE,165);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_YSIZE,68);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_BGCOLOR,clrDimGray);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,"SG_dist_bg",OBJPROP_SELECTABLE,false);
      ObjectCreate(0,"SG_dist",OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,"SG_dist",OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,"SG_dist",OBJPROP_XDISTANCE,10);
      ObjectSetInteger(0,"SG_dist",OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,"SG_dist",OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,"SG_dist",OBJPROP_FONTSIZE,10);
      ObjectSetString(0, "SG_dist",OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,"SG_dist",OBJPROP_COLOR,clrWhite);
     }

   ObjectSetInteger(0,"SG_dist",OBJPROP_YDISTANCE,(int)(ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS)*0.10));
   ObjectSetInteger(0,"SG_dist_bg",OBJPROP_XDISTANCE,8);
   ObjectSetInteger(0,"SG_dist_bg",OBJPROP_YDISTANCE,(int)(ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS)*0.10)-6);
   ObjectSetInteger(0,"SG_dist_bg",OBJPROP_XSIZE,165);
   ObjectSetInteger(0,"SG_dist_bg",OBJPROP_YSIZE,68);
   ObjectSetString(0,"SG_dist",OBJPROP_TEXT,lbl);
   ObjectSetInteger(0,"SG_dist",OBJPROP_COLOR,clrWhite);
  }
void CheckBoundaryAlert(const double upB,const double midB,const double lowB,
                        const double bid,const double point)
  {
   if(!InpAlertEnable)
      return;

   const double distUp  = (upB - bid)/point;
   const double distLow = (bid - lowB)/point;
   const double distMid = MathAbs(bid - midB)/point;

   //--- Вооружён: ждём подхода цены к границе
   if(g_alertArmed)
     {
      int side = 0;
      double dist = 0;
      if(distUp  <= InpAlertTriggerPts){ side =  1; dist = distUp;  }
      if(distLow <= InpAlertTriggerPts){ side = -1; dist = distLow; }
      if(side != 0)
        {
         g_alertArmed   = false;
         g_alertWaiting = true;
         g_alertSide    = side;
         SendBoundAlert(side, dist);
        }
      return;
     }

   //--- Пауза: ждём возврата цены к средней
   if(g_alertWaiting)
     {
      bool backToMid = false;
      if(g_alertSide ==  1 && bid <= midB) backToMid = true;
      if(g_alertSide == -1 && bid >= midB) backToMid = true;
      if(backToMid)
        {
         g_alertWaiting = false;
         g_alertArmed   = true;
         g_alertSide    = 0;
         SendBoundAlert(0, distMid);
        }
     }
  }
void SendBoundAlert(const int side,const double distPts)
  {
   string msg;
   if(side ==  1) msg = StringFormat("%s: цена подошла к ВЕРХНЕЙ границе BB, расстояние %.0f пт",m_symbol,distPts);
   else if(side== -1) msg = StringFormat("%s: цена подошла к НИЖНЕЙ границе BB, расстояние %.0f пт",m_symbol,distPts);
   else msg = StringFormat("%s: цена вернулась к средней BB (дист. %.0f пт), снова мониторим",m_symbol,distPts);

   Print(msg);
   if(InpAlertLocal)
      Alert(msg);
   if(InpAlertPush)
     {
      if(!SendNotification(msg))
         Print("Push не отправлен: настройте MetaQuotes ID (4C91730F) в терминале");
     }
  }
void HelperTrend(const string name,const datetime t1,const double p1,
                 const datetime t2,const double p2,const color clr,const int st)
  {
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_TREND,0,t1,p1,t2,p2);
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }
   ObjectMove(0,name,0,t1,p1);
   ObjectMove(0,name,1,t2,p2);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,st);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
  }
void DeleteBandObjects()
  {
   for(int a=0;a<24;a++)
     {
      ObjectDelete(0,StringFormat("SG_bUp_%d",a));
      ObjectDelete(0,StringFormat("SG_bMid_%d",a));
      ObjectDelete(0,StringFormat("SG_bLow_%d",a));
     }
   ObjectDelete(0,"SG_bid");
   ObjectDelete(0,"SG_dUp");
   ObjectDelete(0,"SG_dDn");
   ObjectDelete(0,"SG_dist");
   ObjectDelete(0,"SG_dist_bg");
  }
//+------------------------------------------------------------------+
//| Отрисовка значения RSI в левом нижнем углу                      |
//+------------------------------------------------------------------+
void DrawRSIValue(const double rsi)
  {
   //--- Цвет: ниже oversold - зелёный, выше overbought - красный, иначе синий
   color clr = clrDodgerBlue;
   if(rsi < InpRSIOversold)   clr = clrLime;
   else if(rsi > InpRSIOverbought) clr = clrRed;

   const string txt = StringFormat("RSI: %.1f", rsi);

   if(ObjectFind(0,"SG_rsi")<0)
     {
      ObjectCreate(0,"SG_rsi",OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_XDISTANCE,8);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_YDISTANCE,4);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_FONTSIZE,14);
      ObjectSetString(0, "SG_rsi",OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,"SG_rsi",OBJPROP_BACK,false);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,"SG_rsi",OBJPROP_HIDDEN,true);
     }
   ObjectSetString(0,"SG_rsi",OBJPROP_TEXT,txt);
   ObjectSetInteger(0,"SG_rsi",OBJPROP_COLOR,clr);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Простая надпись на графике (как остальные)                       |
//+------------------------------------------------------------------+
void DrawInfoText(const string txt)
  {
   string full = txt;
   for(int i=0;i<14;i++)
     {
      if(g_log[i]=="") break;
      full += "\n" + g_log[i];
     }
   Comment(full);   // встроенная надпись графика - всегда видна в левом верхнем углу
  }
//+------------------------------------------------------------------+
//| Добавить запись в лог (выводится в панели на графике)            |
//+------------------------------------------------------------------+
void AddLog(const string msg)
  {
   for(int i=13;i>0;i--)
      g_log[i]=g_log[i-1];
   g_log[0]=StringFormat("[%s] %s",
                         TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                         msg);
   ChartRedraw();   // текст панели обновится в следующем UpdatePanel
  }
//+------------------------------------------------------------------+