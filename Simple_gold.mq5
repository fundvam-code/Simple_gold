//+------------------------------------------------------------------+
//|                                                  Simple_gold_v5.mq5 |
//|                                      Copyright 2026, Bondarev A.   |
//|  Версия с исправленным distLine (всегда положительный)           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bondarev A."
#property link      "https://www.mql5.com"
#property version   "5.05"
#property description "Торговля по BB с фильтрами и логикой WAIT (визуализация)."

#include <Trade\Trade.mqh>

//-------------------- Входные параметры -----------------------------+
input group "=== Базовые настройки ==="
input string            InpSymbol        = "";            // Символ (пусто = текущий)
input ENUM_TIMEFRAMES   InpMainTF        = PERIOD_M15;    // Основной ТФ
input long              InpMagic         = 230824;        // Magic number
input double            InpLots          = 0.05;          // Фиксированный лот
input double            InpRR            = 2.5;           // TP = RR * SL
input double            InpATRSLMult     = 1.0;           // SL = множитель * ATR

input group "=== Торговая логика ==="
input bool              InpAutoMode      = true;          // true = авто, false – только мониторинг
input double            InpBBOffsetPts   = 0.0;           // Смещение касания (пт)
input bool              InpAllowBuy      = true;          // Разрешить покупки
input bool              InpAllowSell     = true;          // Разрешить продажи

input group "=== Логика отката (WAIT) ==="
input double            InpWaitOffsetPts  = 50.0;         // Отход от линии (пт) для выхода из WAIT

input group "=== Трейлинг-стоп (фиксация прибыли) ==="
input bool              InpTrailEnable     = true;         // Включить трейлинг-стоп
input double            InpTrailActivateFrac = 0.5;       // Активация: прибыль = часть SL (0.5 = половина SL)
input int               InpTrailOffsetPts  = 0;            // SL ставится на N пунктов от текущей цены (0 = безубыток)

input group "=== Индикаторы ==="
input int               InpATRPeriod     = 14;
input int               InpBBPeriod      = 20;
input double            InpBBDev         = 2.0;
input ENUM_APPLIED_PRICE InpBBApplied    = PRICE_CLOSE;

input group "=== Фильтры (по умолчанию ВЫКЛЮЧЕНЫ) ==="
input bool              InpUseRSI        = false;
input int               InpRSIPeriod     = 14;
input double            InpRSIOversold   = 30.0;
input double            InpRSIOverbought = 70.0;

input bool              InpUseADX        = false;
input int               InpADXPeriod     = 14;
input double            InpADXMin        = 20.0;

input bool              InpUseTrendFilter= false;
input int               InpMATrendPeriod = 200;
input ENUM_MA_METHOD    InpMAMethod      = MODE_SMA;

input group "=== Алерты ==="
input bool              InpAlertEnable   = true;
input double            InpAlertTriggerPts = 50.0;
input bool              InpAlertLocal    = true;
input bool              InpAlertPush     = true;

input group "=== Отображение ==="
input bool              InpShowIndicators = true;   // Показывать BB на графике

//+------------------------------------------------------------------+
//| Глобальные переменные                                            |
//+------------------------------------------------------------------+
CTrade               m_trade;
string               m_symbol;
int                  m_bbHandle, m_atrHandle, m_rsiHandle, m_adxHandle;
int                  m_atrH1Handle;    // для отображения

ulong                g_autoPosTicket = 0;
int                  g_autoDir       = 0;       // +1 buy, -1 sell
bool                 g_waiting       = false;   // true – режим WAIT
bool                 g_manualWait    = false;   // true – ручная пауза (кнопка WAIT)
double               g_breakLevel    = 0.0;
double               g_chanWidth     = 0.0;
double               g_bbUp, g_bbMid, g_bbLow;  // текущие полосы
double               g_halfChanPts = 0;          // полуширина канала BB (пт) = (up-low)/2

bool                 g_alertArmed    = true;
bool                 g_alertWaiting  = false;
int                  g_alertSide     = 0;

//--- Для визуализации
datetime             g_lastM1Bar = 0;

//+------------------------------------------------------------------+
//| Инициализация                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   m_symbol = (InpSymbol == "" ? _Symbol : InpSymbol);
   if(!SymbolSelect(m_symbol, true))
   {
      Print("Ошибка выбора символа ", m_symbol);
      return INIT_FAILED;
   }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetTypeFillingBySymbol(m_symbol);
   m_trade.SetDeviationInPoints(50);

   m_bbHandle  = iBands(m_symbol, InpMainTF, InpBBPeriod, 0, InpBBDev, InpBBApplied);
   m_atrHandle = iATR(m_symbol, InpMainTF, InpATRPeriod);
   m_atrH1Handle = iATR(m_symbol, PERIOD_H1, InpATRPeriod);
   m_rsiHandle = (InpUseRSI ? iRSI(m_symbol, InpMainTF, InpRSIPeriod, PRICE_CLOSE) : INVALID_HANDLE);
   m_adxHandle = (InpUseADX ? iADX(m_symbol, InpMainTF, InpADXPeriod) : INVALID_HANDLE);

   if(m_bbHandle == INVALID_HANDLE || m_atrHandle == INVALID_HANDLE ||
      (InpUseRSI && m_rsiHandle == INVALID_HANDLE) ||
      (InpUseADX && m_adxHandle == INVALID_HANDLE))
      return INIT_FAILED;

   // Сброс состояний
   g_autoPosTicket = 0;
   g_autoDir       = 0;
   g_waiting       = false;
   g_manualWait    = false;
   g_breakLevel    = 0.0;
   g_chanWidth     = 0.0;
   g_alertArmed    = true;
   g_alertWaiting  = false;
   g_alertSide     = 0;

   // Проверяем, есть ли уже открытая позиция с нашим магиком
   if(HasOpenPosition())
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagic)
         {
            g_autoPosTicket = ticket;
            g_autoDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
            break;
         }
      }
   }

   // Удаляем старые графические объекты (на случай перезапуска)
   DeleteBandObjects();
   ObjectDelete(0, "SG_bid");
   ObjectDelete(0, "SG_dUp");
   ObjectDelete(0, "SG_dDn");
   ObjectDelete(0, "SG_dist");
   ObjectDelete(0, "SG_dist_bg");
   ObjectDelete(0, "SG_rsi");

   // Панель управления
   CreateButtons();
   UpdateButtons();

   Print("Советник инициализирован. Режим: ", (InpAutoMode ? "АВТО" : "МОНИТОР"),
         ", Фильтры: RSI=", InpUseRSI, ", ADX=", InpUseADX, ", Trend=", InpUseTrendFilter);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Деинициализация                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(m_bbHandle  != INVALID_HANDLE) IndicatorRelease(m_bbHandle);
   if(m_atrHandle != INVALID_HANDLE) IndicatorRelease(m_atrHandle);
   if(m_rsiHandle != INVALID_HANDLE) IndicatorRelease(m_rsiHandle);
   if(m_adxHandle != INVALID_HANDLE) IndicatorRelease(m_adxHandle);
   if(m_atrH1Handle != INVALID_HANDLE) IndicatorRelease(m_atrH1Handle);
   DeleteBandObjects();
   ObjectDelete(0, "SG_bid");
   ObjectDelete(0, "SG_dUp");
   ObjectDelete(0, "SG_dDn");
   ObjectDelete(0, "SG_dist");
   ObjectDelete(0, "SG_dist_bg");
   ObjectDelete(0, "SG_rsi");
   DeleteButtons();
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Обновление данных и визуализации
   UpdatePanel();

   // Трейлинг-стоп (фиксация прибыли)
   CheckTrailingStop();

   // Обработка закрытия позиции (переход в WAIT при убытке)
   CheckPositionClose();

   // Если в WAIT – проверяем откат
   if(g_waiting)
      CheckWaitCondition();

   // Авто-торговля (если разрешена и нет WAIT)
   if(InpAutoMode && !g_waiting && !HasOpenPosition())
      CheckAutoTrade();
}

//+------------------------------------------------------------------+
//| Обновление панели (индикаторы + отрисовка)                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   double up, mid, low, atr, rsi=50, adx=0;
   int touch;
   double distUp, distLow;

   if(ReadIndicators(up, mid, low, atr, rsi, adx, touch, distUp, distLow) != 0)
      return;

   g_bbUp = up; g_bbMid = mid; g_bbLow = low;

   // --- Визуализация ---
   if(InpShowIndicators)
   {
      DrawBands(120);
      DrawDistance(SymbolInfoDouble(m_symbol, SYMBOL_BID), up, low);
      DrawRSIValue(rsi);
   }

   // --- Вывод текстовой информации ---
   string status = g_waiting ? (g_manualWait ? "WAIT (ручная пауза)" : "WAIT (откат)") : "МОНИТОРИНГ";
   string filters = StringFormat("RSI:%.1f ADX:%.1f", rsi, adx);
   string posInfo = (HasOpenPosition() ? StringFormat("ОТКРЫТА (dir=%d)", g_autoDir) : "НЕТ");

   // Для отображения параметров WAIT (distLine теперь всегда положительный)
   double distLine = 0, waitLevel = 0, waitDistance = 0;
   double pointNow = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double distMid  = MathAbs(SymbolInfoDouble(m_symbol, SYMBOL_BID) - mid) / pointNow;
   g_halfChanPts   = (up - low) / 2.0 / pointNow;   // полуширина канала BB (пт)
   if(g_waiting && g_breakLevel != 0)
   {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      distLine = MathAbs(bid - g_breakLevel) / point;   // всегда >= 0
      
      waitLevel = (g_autoDir == 1) ? g_breakLevel + MathMin(InpWaitOffsetPts, (g_bbMid != 0 ? MathAbs(g_bbMid - g_breakLevel)/point : InpWaitOffsetPts)) * point : g_breakLevel - MathMin(InpWaitOffsetPts, (g_bbMid != 0 ? MathAbs(g_bbMid - g_breakLevel)/point : InpWaitOffsetPts)) * point;
      distMid = MathAbs(bid - mid) / point;
      waitDistance = MathAbs(bid - waitLevel) / point;   // расстояние до целевого уровня
   }

   string s = StringFormat("=== %s %s ===\n"
                           "Цена: %.2f\n"
                           "BB: %.2f / %.2f / %.2f\n"
                           "Расст. до верх.: %.0f пт, до ниж.: %.0f пт, до сред.: %.0f пт\n"
                           "Касание: %s\n"
                           "Состояние: %s\n"
                           "Фильтры: %s\n"
                           "ATR: %.2f, SL: %.1f пт, TP: %.1f пт\n"
                           "Позиция: %s\n"
                           "WAIT: цель=%.2f, расстояние до цели=%.0f пт (отход %.0f пт)",
                           m_symbol, EnumToString(InpMainTF),
                           SymbolInfoDouble(m_symbol, SYMBOL_BID),
                           up, mid, low,
                           distUp, distLow, distMid,
                           (touch==1?"НИЖНЯЯ":(touch==-1?"ВЕРХНЯЯ":"нет")),
                           status,
                           filters,
                           atr, atr*InpATRSLMult/Point(), atr*InpATRSLMult*InpRR/Point(),
                           posInfo,
                           waitLevel, waitDistance, InpWaitOffsetPts);
   Comment(s);

   // Алерты
   CheckBoundaryAlert(up, mid, low, SymbolInfoDouble(m_symbol, SYMBOL_BID), Point());
}

//+------------------------------------------------------------------+
//| Чтение индикаторов                                               |
//+------------------------------------------------------------------+
int ReadIndicators(double &up, double &mid, double &low, double &atr,
                   double &rsi, double &adx, int &touch,
                   double &distUp, double &distLow)
{
   double upA[], midA[], lowA[];
   if(!ComputeBands(0, 1, upA, midA, lowA))
      return -1;
   up = upA[0]; mid = midA[0]; low = lowA[0];

   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   distUp  = (up - bid) / point;
   distLow = (bid - low) / point;

   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(m_atrHandle, 0, 1, 1, a) == 1) atr = a[0]; else atr = 0;

   if(InpUseRSI)
   {
      double r[];
      ArraySetAsSeries(r, true);
      if(CopyBuffer(m_rsiHandle, 0, 1, 1, r) == 1) rsi = r[0];
   }
   if(InpUseADX)
   {
      double b[];
      ArraySetAsSeries(b, true);
      if(CopyBuffer(m_adxHandle, 0, 1, 1, b) == 1) adx = b[0];
   }

   // Касание на M1 (предпоследний закрытый бар)
   double m1Hi[], m1Lo[];
   ArraySetAsSeries(m1Hi, true); ArraySetAsSeries(m1Lo, true);
   if(CopyHigh(m_symbol, PERIOD_M1, 1, 2, m1Hi) != 2) return -1;
   if(CopyLow(m_symbol, PERIOD_M1, 1, 2, m1Lo) != 2)  return -1;

   double touchOff = InpBBOffsetPts * point;
   bool tLow  = (m1Lo[1] <= low + touchOff);
   bool tHigh = (m1Hi[1] >= up - touchOff);
   touch = 0;
   if(tLow)  touch = 1;
   if(tHigh) touch = -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Расчёт полос (ручной)                                            |
//+------------------------------------------------------------------+
bool ComputeBands(const int shift, const int count, double &up[], double &midB[], double &lowB[])
{
   int need = shift + count + InpBBPeriod + 2;
   double cl[];
   ArraySetAsSeries(cl, true);
   if(CopyClose(m_symbol, InpMainTF, 0, need, cl) < need)
      return false;
   ArrayResize(up, count); ArrayResize(midB, count); ArrayResize(lowB, count);
   for(int i = shift; i < shift + count; i++)
   {
      double sum = 0;
      for(int j = i; j < i + InpBBPeriod; j++) sum += cl[j];
      double ma = sum / InpBBPeriod;
      double var = 0;
      for(int j = i; j < i + InpBBPeriod; j++)
      {
         double d = cl[j] - ma;
         var += d * d;
      }
      double sd = MathSqrt(var / InpBBPeriod);
      int k = i - shift;
      midB[k] = ma;
      up[k] = ma + InpBBDev * sd;
      lowB[k] = ma - InpBBDev * sd;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Проверка наличия открытой позиции                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Открытие сделки (только авто)                                   |
//+------------------------------------------------------------------+
bool OpenAutoTrade(const ENUM_ORDER_TYPE type)
{
   if(!InpAutoMode) return false;
   if(HasOpenPosition())
   {
      Print("Уже есть открытая позиция, новую не открываем");
      return false;
   }

   // Проверка фильтров
   if(!PassFilters(type))
   {
      Print("Фильтры не пропускают сигнал ", EnumToString(type));
      return false;
   }

   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(m_atrHandle, 0, 1, 1, atrArr) != 1)
   {
      Print("Ошибка чтения ATR");
      return false;
   }
   double atrVal = atrArr[0];
   if(atrVal <= 0) return false;

   double slDist = atrVal * InpATRSLMult;
   double tpDist = slDist * InpRR;
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(bid - slDist, digits);
      tp = NormalizeDouble(bid + tpDist, digits);
   }
   else
   {
      sl = NormalizeDouble(bid + slDist, digits);
      tp = NormalizeDouble(bid - tpDist, digits);
   }

   double stopLv = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(MathAbs(sl - bid) < stopLv || MathAbs(tp - bid) < stopLv)
   {
      Print("SL/TP слишком близко к цене");
      return false;
   }

   double lot = NormalizeLot(InpLots);
   if(lot <= 0) return false;

   bool done;
   string comment = (type == ORDER_TYPE_BUY ? "SG Auto BUY" : "SG Auto SELL");
   if(type == ORDER_TYPE_BUY)
      done = m_trade.Buy(lot, m_symbol, ask, sl, tp, comment);
   else
      done = m_trade.Sell(lot, m_symbol, bid, sl, tp, comment);

   if(done)
   {
      g_autoPosTicket = m_trade.ResultOrder();
      g_autoDir = (type == ORDER_TYPE_BUY ? 1 : -1);
      // Запоминаем линию пробоя для WAIT
      if(type == ORDER_TYPE_BUY)
         g_breakLevel = g_bbLow;
      else
         g_breakLevel = g_bbUp;
      g_chanWidth = g_bbUp - g_bbLow;  // не используется, но оставим

      Print("Открыта авто-сделка ", EnumToString(type), " лот=", lot,
            " SL=", DoubleToString(sl, digits), " TP=", DoubleToString(tp, digits));
      return true;
   }
   else
   {
      Print("Ошибка открытия: ", m_trade.ResultRetcode(), " ", m_trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Проверка фильтров                                                |
//+------------------------------------------------------------------+
bool PassFilters(const ENUM_ORDER_TYPE type)
{
   // RSI фильтр
   if(InpUseRSI)
   {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(m_rsiHandle, 0, 1, 1, rsi) != 1) return false;
      double val = rsi[0];
      if(type == ORDER_TYPE_BUY && val > InpRSIOverbought)  // перекуплен – не покупать
         return false;
      if(type == ORDER_TYPE_SELL && val < InpRSIOversold)   // перепродан – не продавать
         return false;
   }

   // ADX фильтр
   if(InpUseADX)
   {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(m_adxHandle, 0, 1, 1, adx) != 1) return false;
      if(adx[0] < InpADXMin) return false;
   }

   // Трендовый фильтр (MA)
   if(InpUseTrendFilter)
   {
      double ma[];
      ArraySetAsSeries(ma, true);
      int maHandle = iMA(m_symbol, InpMainTF, InpMATrendPeriod, 0, InpMAMethod, PRICE_CLOSE);
      if(maHandle == INVALID_HANDLE) return false;
      if(CopyBuffer(maHandle, 0, 1, 1, ma) != 1)
      {
         IndicatorRelease(maHandle);
         return false;
      }
      IndicatorRelease(maHandle);
      double price = (type == ORDER_TYPE_BUY ? SymbolInfoDouble(m_symbol, SYMBOL_ASK) :
                                               SymbolInfoDouble(m_symbol, SYMBOL_BID));
      if(price > ma[0] && type == ORDER_TYPE_SELL) return false;  // выше MA – не продаём
      if(price < ma[0] && type == ORDER_TYPE_BUY)  return false;  // ниже MA – не покупаем
   }

   return true;
}

//+------------------------------------------------------------------+
//| Авто-торговля: проверка касания и вход                          |
//+------------------------------------------------------------------+
void CheckAutoTrade()
{
   double up, mid, low, atr, rsi, adx;
   int touch;
   double distUp, distLow;
   if(ReadIndicators(up, mid, low, atr, rsi, adx, touch, distUp, distLow) != 0)
      return;

   if(touch == 1 && InpAllowBuy)
   {
      if(OpenAutoTrade(ORDER_TYPE_BUY))
         Print("Авто-вход BUY по касанию нижней полосы");
   }
   else if(touch == -1 && InpAllowSell)
   {
      if(OpenAutoTrade(ORDER_TYPE_SELL))
         Print("Авто-вход SELL по касанию верхней полосы");
   }
}

//+------------------------------------------------------------------+
//| Трейлинг-стоп: фиксация прибыли                                 |
//+------------------------------------------------------------------+
void CheckTrailingStop()
{
   if(!InpTrailEnable) return;
   if(g_autoPosTicket == 0) return;
   if(!PositionSelectByTicket(g_autoPosTicket)) return;

   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   int digits  = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   double bid  = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double curSL = PositionGetDouble(POSITION_SL);

   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(m_atrHandle, 0, 1, 1, atrArr) != 1) return;
   double atrVal = atrArr[0];
   if(atrVal <= 0) return;

   double slDist = atrVal * InpATRSLMult;
   long type = PositionGetInteger(POSITION_TYPE);

   double profitPts = 0;
   if(type == POSITION_TYPE_BUY)
      profitPts = (bid - PositionGetDouble(POSITION_PRICE_OPEN)) / point;
   else
      profitPts = (PositionGetDouble(POSITION_PRICE_OPEN) - bid) / point;

   // Активация: прибыль >= часть SL
   if(profitPts < slDist / point * InpTrailActivateFrac) return;

   // Новый SL: на InpTrailOffsetPts от текущей цены (0 = безубыток)
   double newSL;
   if(type == POSITION_TYPE_BUY)
      newSL = bid - InpTrailOffsetPts * point;
   else
      newSL = bid + InpTrailOffsetPts * point;

   // Не ухудшаем SL (двигаем только в сторону защиты прибыли)
   if(type == POSITION_TYPE_BUY && newSL <= curSL) return;
   if(type == POSITION_TYPE_SELL && newSL >= curSL) return;

   newSL = NormalizeDouble(newSL, digits);
   m_trade.PositionModify(g_autoPosTicket, newSL, PositionGetDouble(POSITION_TP));
   if(m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      Print("Трейлинг: SL перенесён на ", DoubleToString(newSL, digits),
            " (прибыль ", DoubleToString(profitPts, 1), " пт)");
}

//+------------------------------------------------------------------+
//| Обработка закрытия позиции – переход в WAIT при убытке          |
//+------------------------------------------------------------------+
void CheckPositionClose()
{
   if(g_autoPosTicket == 0) return;

   // Если позиция ещё открыта – ничего не делаем
   if(PositionSelectByTicket(g_autoPosTicket))
      return;

   // Позиция закрылась – вычисляем результат
   double totalProfit = 0;
   bool gotResult = false;
   if(HistorySelectByPosition((long)g_autoPosTicket))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            totalProfit += HistoryDealGetDouble(dt, DEAL_PROFIT);
            totalProfit += HistoryDealGetDouble(dt, DEAL_SWAP);
            gotResult = true;
         }
      }
   }

   g_autoPosTicket = 0; // сбрасываем тикет

   if(!gotResult)
   {
      Print("Не удалось получить результат закрытой позиции, сбрасываем состояние");
      g_autoDir = 0;
      g_waiting = false;
      g_breakLevel = 0;
      return;
   }

   if(totalProfit >= 0)
   {
      Print("Авто-сделка закрыта с прибылью: ", DoubleToString(totalProfit, 2), ". Остаёмся в режиме MONITOR.");
      g_autoDir = 0;
      g_breakLevel = 0;
      if(!g_manualWait)          // ручная пауза не сбрасывается автоматически
         g_waiting = false;
   }
   else
   {
      Print("Авто-сделка закрыта с убытком: ", DoubleToString(totalProfit, 2),
            ". Переходим в режим WAIT, ждём откат к средней.");
      g_waiting = true;
      // g_breakLevel уже запомнен при открытии
   }
}

//+------------------------------------------------------------------+
//| Проверка условия отката (distLine теперь всегда положительный)   |
//+------------------------------------------------------------------+
void CheckWaitCondition()
{
   if(!g_waiting) return;
   if(g_manualWait) return;   // ручная пауза – ждём нажатия кнопки MONITORING
   if(g_breakLevel == 0 || (g_autoDir != 1 && g_autoDir != -1))
   {
      g_waiting = false;
      g_breakLevel = 0;
      g_autoDir = 0;
      return;
   }

   double bid   = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   // Отход от линии пробоя, ограниченный средней полосой BB (в пунктах)
   double offsetPts = MathMin(InpWaitOffsetPts,
                              (g_bbMid != 0 ? MathAbs(g_bbMid - g_breakLevel) / point : InpWaitOffsetPts));
   double waitLevel = (g_autoDir == 1) ? g_breakLevel + offsetPts * point
                                       : g_breakLevel - offsetPts * point;
   // BUY: цена поднялась до уровня / SELL: цена опустилась до уровня
   bool waitComplete = (g_autoDir == 1) ? (bid >= waitLevel) : (bid <= waitLevel);
   if(waitComplete)   // откат достиг уровня (bid >= waitLevel для BUY / bid <= waitLevel для SELL)
   {
      Print("Откат достигнут: bid=", DoubleToString(bid, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
            ", уровень=", DoubleToString(waitLevel, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
            "). Выходим из WAIT в MONITOR.");
      g_waiting = false;
      g_breakLevel = 0;
      g_autoDir = 0;
   }
}

//+------------------------------------------------------------------+
//| Нормализация лота                                                |
//+------------------------------------------------------------------+
double NormalizeLot(const double lots)
{
   double step   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
   double minvol = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double lot = MathFloor(lots / step) * step;
   if(lot < minvol) lot = minvol;
   int ld = (int)MathCeil(-MathLog10(step) - 0.001);
   return NormalizeDouble(lot, ld);
}

//+------------------------------------------------------------------+
//| Алерты при приближении к границе                                 |
//+------------------------------------------------------------------+
void CheckBoundaryAlert(const double up, const double mid, const double low,
                        const double bid, const double point)
{
   if(!InpAlertEnable) return;

   double distUp  = (up - bid) / point;
   double distLow = (bid - low) / point;

   static bool alertedUp = false, alertedLow = false;

   if(distUp <= InpAlertTriggerPts && !alertedUp)
   {
      string msg = StringFormat("%s: цена подошла к ВЕРХНЕЙ границе BB (%.0f пт)", m_symbol, distUp);
      Print(msg);
      if(InpAlertLocal) Alert(msg);
      if(InpAlertPush) SendNotification(msg);
      alertedUp = true;
   }
   if(distLow <= InpAlertTriggerPts && !alertedLow)
   {
      string msg = StringFormat("%s: цена подошла к НИЖНЕЙ границе BB (%.0f пт)", m_symbol, distLow);
      Print(msg);
      if(InpAlertLocal) Alert(msg);
      if(InpAlertPush) SendNotification(msg);
      alertedLow = true;
   }

   // Сброс флагов, когда цена отходит от границы
   if(distUp > InpAlertTriggerPts * 1.5) alertedUp = false;
   if(distLow > InpAlertTriggerPts * 1.5) alertedLow = false;
}

//====================================================================
//  ВИЗУАЛИЗАЦИЯ (скопировано из первого варианта)
//====================================================================

//+------------------------------------------------------------------+
//| Отрисовка полос Боллинджера (сегментами)                        |
//+------------------------------------------------------------------+
void DrawSegment(const string name, const color clr, const datetime &tm[], const double &v[], const int n)
{
   const int seg = 24;
   for(int a = 0; a < seg; a++)
   {
      int i0 = (int)((double)a    / seg * (n - 1.0));
      int i1 = (int)((double)(a+1) / seg * (n - 1.0));
      string on = StringFormat("%s_%d", name, a);
      if(ObjectFind(0, on) < 0)
      {
         ObjectCreate(0, on, OBJ_TREND, 0, tm[i0], v[i0], tm[i1], v[i1]);
         ObjectSetInteger(0, on, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, on, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, on, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, on, OBJPROP_HIDDEN, true);
      }
      else
      {
         ObjectMove(0, on, 0, tm[i0], v[i0]);
         ObjectMove(0, on, 1, tm[i1], v[i1]);
      }
      ObjectSetInteger(0, on, OBJPROP_COLOR, clr);
   }
}

void DrawBands(const int n)
{
   double upA[], midA[], lowA[];
   if(!ComputeBands(0, n, upA, midA, lowA)) return;
   datetime tm[];
   ArraySetAsSeries(tm, true);
   if(CopyTime(m_symbol, InpMainTF, 0, n, tm) < n) return;
   DrawSegment("SG_bUp",  clrDodgerBlue, tm, upA,  n);
   DrawSegment("SG_bMid", clrYellow,      tm, midA, n);
   DrawSegment("SG_bLow", clrOrange,      tm, lowA, n);
}

//+------------------------------------------------------------------+
//| Линия текущей цены и расстояния                                  |
//+------------------------------------------------------------------+
void HelperTrend(const string name, const datetime t1, const double p1,
                 const datetime t2, const double p2, const color clr, const int st)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectMove(0, name, 0, t1, p1);
   ObjectMove(0, name, 1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, st);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

void DrawDistance(const double bid, const double upB, const double lowB)
{
   datetime t0 = iTime(m_symbol, InpMainTF, 0);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(t0 == 0) return;

   if(ObjectFind(0, "SG_bid") < 0)
      ObjectCreate(0, "SG_bid", OBJ_HLINE, 0, 0, bid);
   ObjectSetDouble(0, "SG_bid", OBJPROP_PRICE, bid);
   ObjectSetInteger(0, "SG_bid", OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, "SG_bid", OBJPROP_WIDTH, 1);

   HelperTrend("SG_dUp", t0, upB,  t0, bid, clrLime, STYLE_DASH);
   HelperTrend("SG_dDn", t0, bid,  t0, lowB, clrRed, STYLE_DASH);

   //--- Подпись с расстояниями
   double dUp  = (upB - bid) / point;
   double dDn  = (bid - lowB) / point;
   double atrH1 = 0;
   double h1a[];
   ArraySetAsSeries(h1a, true);
   if(CopyBuffer(m_atrH1Handle, 0, 1, 1, h1a) == 1) atrH1 = h1a[0];
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   string lbl = StringFormat("UP: %.0f пт\nDN: %.0f пт\nСигнал: %.0f пт\nATR H1: %s",
                             dUp, dDn, InpAlertTriggerPts, DoubleToString(atrH1, digits));

   if(ObjectFind(0, "SG_dist_bg") < 0)
   {
      ObjectCreate(0, "SG_dist_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_XSIZE, 165);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_YSIZE, 68);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_BGCOLOR, clrDimGray);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "SG_dist_bg", OBJPROP_SELECTABLE, false);
      ObjectCreate(0, "SG_dist", OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "SG_dist", OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, "SG_dist", OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, "SG_dist", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, "SG_dist", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SG_dist", OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, "SG_dist", OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, "SG_dist", OBJPROP_COLOR, clrWhite);
   }

   int yOff = 150 + (int)(ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS) * 0.10);
   ObjectSetInteger(0, "SG_dist", OBJPROP_YDISTANCE, yOff);
   ObjectSetInteger(0, "SG_dist_bg", OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(0, "SG_dist_bg", OBJPROP_YDISTANCE, yOff - 6);
   ObjectSetInteger(0, "SG_dist_bg", OBJPROP_XSIZE, 165);
   ObjectSetInteger(0, "SG_dist_bg", OBJPROP_YSIZE, 68);
   ObjectSetString(0, "SG_dist", OBJPROP_TEXT, lbl);
   ObjectSetInteger(0, "SG_dist", OBJPROP_COLOR, clrWhite);
}

//+------------------------------------------------------------------+
//| RSI в левом нижнем углу                                          |
//+------------------------------------------------------------------+
void DrawRSIValue(const double rsi)
{
   color clr = clrDodgerBlue;
   if(rsi < InpRSIOversold)   clr = clrLime;
   else if(rsi > InpRSIOverbought) clr = clrRed;

   string txt = StringFormat("RSI: %.1f", rsi);
   if(ObjectFind(0, "SG_rsi") < 0)
   {
      ObjectCreate(0, "SG_rsi", OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_YDISTANCE, 140);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_FONTSIZE, 14);
      ObjectSetString(0, "SG_rsi", OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, "SG_rsi", OBJPROP_BACK, false);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SG_rsi", OBJPROP_HIDDEN, true);
   }
   ObjectSetString(0, "SG_rsi", OBJPROP_TEXT, txt);
   ObjectSetInteger(0, "SG_rsi", OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Удаление всех графических объектов                               |
//+------------------------------------------------------------------+
void DeleteBandObjects()
{
   for(int a = 0; a < 24; a++)
   {
      ObjectDelete(0, StringFormat("SG_bUp_%d", a));
      ObjectDelete(0, StringFormat("SG_bMid_%d", a));
      ObjectDelete(0, StringFormat("SG_bLow_%d", a));
   }
}

//+------------------------------------------------------------------+
//| ПАНЕЛЬ УПРАВЛЕНИЯ: кнопки WAIT / MONITORING                     |
//+------------------------------------------------------------------+
bool CreateButton(const string name, const string text,
                  const int corner, const int x, const int y,
                  const int xs, const int ys)
{
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return false;

   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,   xs);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,   ys);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
   ObjectSetString(0,  name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'70,70,70');
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   return true;
}

void CreateButtons()
{
   const int corner = CORNER_LEFT_LOWER;
   CreateButton("SG_btn_wait",    "WAIT",       corner, 10, 70, 120, 28);
   CreateButton("SG_btn_monitor", "MONITORING", corner, 10, 102, 120, 28);
}

void UpdateButtons()
{
   const bool active = g_waiting;
   ObjectSetInteger(0, "SG_btn_wait",    OBJPROP_STATE, active);
   ObjectSetInteger(0, "SG_btn_monitor", OBJPROP_STATE, !active);
   ObjectSetInteger(0, "SG_btn_wait",    OBJPROP_BGCOLOR, active ? C'200,60,60'   : C'90,90,90');
   ObjectSetInteger(0, "SG_btn_monitor", OBJPROP_BGCOLOR, active ? C'90,90,90'    : C'60,160,60');
}

void DeleteButtons()
{
   ObjectDelete(0, "SG_btn_wait");
   ObjectDelete(0, "SG_btn_monitor");
}

//+------------------------------------------------------------------+
//| Ручное переключение режима (кнопки)                              |
//+------------------------------------------------------------------+
void SetManualWait(const bool state)
{
   g_manualWait = state;
   g_waiting    = state;
   if(!state)
   {
      g_breakLevel = 0;
      g_autoDir    = 0;
   }
   UpdateButtons();
   Print("Режим изменён вручную: ", (state ? "WAIT (пауза)" : "MONITORING"));
}

//+------------------------------------------------------------------+
//| Обработка кликов по кнопкам                                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "SG_btn_wait")
         SetManualWait(true);
      else if(sparam == "SG_btn_monitor")
         SetManualWait(false);
   }
}
//+------------------------------------------------------------------+
