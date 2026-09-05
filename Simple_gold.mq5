//+------------------------------------------------------------------+
//|                                                  Simple_gold_v5.mq5 |
//|                                      Copyright 2026, Bondarev A.   |
//|  v5.09: вход после бычьей свечи M1 + таймаут WAIT по свечам       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bondarev A."
#property link      "https://www.mql5.com"
#property version   "5.09"
#property description "Торговля по BB: вход после первой бычьей свечи M1, таймаут WAIT, фильтры, логика WAIT."

#include <Trade\Trade.mqh>

//-------------------- Режим фильтра BB по RSI -----------------------+
enum ENUM_RSIBB_MODE
{
   RSIBB_MODE_EXTREME = 0,  // Экстремум: BUY при RSI<нижняя полоса, SELL при RSI>верхняя
   RSIBB_MODE_INSIDE  = 1   // Запрет экстремума: BUY пока RSI<верхняя, SELL пока RSI>нижняя
};

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
input int               InpConfirmMaxBars = 10;           // Окно ожидания подтверждения: макс. свечей M1 (0 = без лимита)

input group "=== Логика отката (WAIT) ==="
input double            InpWaitOffsetPts  = 50.0;         // Отход от линии (пт) для выхода из WAIT
input int               InpWaitMaxBars    = 0;            // Сброс WAIT: нет отката за N свечей M1 (0 = без лимита)

input group "=== Реверс после убытка ==="
input bool              InpReverseOnLoss  = false;        // Один раз открыть встречную позицию после убытка

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

input group "=== Фильтр BB по RSI (динамические уровни) ==="
input bool               InpUseRSIBB          = false;        // Включить фильтр BB по RSI
input ENUM_TIMEFRAMES    InpRSIBB_RSITF       = PERIOD_H1;    // Таймфрейм для расчёта RSI
input int                InpRSIBB_RSIPeriod   = 14;           // Период RSI
input ENUM_APPLIED_PRICE InpRSIBB_RsiApplied  = PRICE_CLOSE;  // Применяемая цена для RSI
input int                InpRSIBB_BBPeriod    = 20;           // Период BB (по RSI)
input double             InpRSIBB_BBDev       = 2.0;          // Отклонение BB
input ENUM_RSIBB_MODE    InpRSIBB_Mode        = RSIBB_MODE_EXTREME; // Режим фильтра
input double             InpRSIBB_Tolerance   = 0.0;          // Допуск от полосы (ед. RSI)

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
int                  m_maHandle;       // трендовый фильтр (MA)
int                  m_atrH1Handle;    // для отображения
int                  m_rsiBBHandle;    // индикатор SG_RSI_BB (только график)
int                  m_rsi2Handle;     // RSI на своём ТФ (для фильтра BB по RSI, напрямую)

ulong                g_autoPosTicket = 0;
int                  g_autoDir       = 0;       // +1 buy, -1 sell
bool                 g_waiting       = false;   // true – режим WAIT
bool                 g_manualWait    = false;   // true – ручная пауза (кнопка WAIT)
bool                 g_reverseDone   = false;   // реверс для текущей убыточной серии уже выполнен
double               g_breakLevel    = 0.0;
double               g_chanWidth     = 0.0;
double               g_bbUp, g_bbMid, g_bbLow;  // текущие полосы
double               g_halfChanPts = 0;          // полуширина канала BB (пт) = (up-low)/2

bool                 g_alertArmed    = true;
bool                 g_alertWaiting  = false;
int                  g_alertSide     = 0;
bool                 g_signalArmed   = false;   // true - касание получено, ждём подтверждающую свечу
int                  g_signalDir     = 0;       // направление ожидающего сигнала: +1 buy, -1 sell
datetime             g_signalBarTime = 0;       // время бара M1, на котором получено касание
datetime             g_waitStartTime = 0;       // время старта WAIT (для таймаута отката)

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
   m_rsiHandle = iRSI(m_symbol, InpMainTF, InpRSIPeriod, PRICE_CLOSE);
   m_adxHandle = iADX(m_symbol, InpMainTF, InpADXPeriod);
   m_maHandle  = iMA(m_symbol, InpMainTF, InpMATrendPeriod, 0, InpMAMethod, PRICE_CLOSE);

   // Фильтр BB по RSI: всё создаётся ТОЛЬКО при включённом фильтре.
   // При InpUseRSIBB=false советник работает как раньше - без лишних
   // хэндлов, без iCustom и без добавления субокна SG_RSI_BB на график.
   if(InpUseRSIBB)
   {
      // RSI на выбранном ТФ для фильтра BB по RSI (прямой расчёт, надёжно)
      m_rsi2Handle = iRSI(m_symbol, InpRSIBB_RSITF, InpRSIBB_RSIPeriod, InpRSIBB_RsiApplied);
      if(m_rsi2Handle == INVALID_HANDLE)
      {
         Print("Ошибка создания iRSI(", EnumToString(InpRSIBB_RSITF), ") - фильтр недоступен");
         return INIT_FAILED;
      }

      // Индикатор SG_RSI_BB - только визуализация (не критично),
      // iCustom БЕЗ параметров (передача параметров съезжает в этой сборке)
      m_rsiBBHandle = iCustom(m_symbol, InpMainTF, "SG_RSI_BB");
      if(m_rsiBBHandle != INVALID_HANDLE)
      {
         if(!ChartIndicatorAdd(0, 0, m_rsiBBHandle))
            Print("Не удалось добавить SG_RSI_BB на график");
      }
      else
         Print("Предупреждение: SG_RSI_BB не создан (график недоступен)");
   }
   else
   {
      m_rsiBBHandle = INVALID_HANDLE;
      m_rsi2Handle  = INVALID_HANDLE;
   }

   if(m_bbHandle == INVALID_HANDLE || m_atrHandle == INVALID_HANDLE ||
      m_rsiHandle == INVALID_HANDLE || m_adxHandle == INVALID_HANDLE ||
      m_maHandle == INVALID_HANDLE || m_atrH1Handle == INVALID_HANDLE)
      return INIT_FAILED;

   // --- продолжение инициализации ---

   // Сброс состояний
   g_autoPosTicket = 0;
   g_autoDir       = 0;
   g_waiting       = false;
   g_manualWait    = false;
   g_breakLevel    = 0.0;
   g_chanWidth     = 0.0;
   g_reverseDone   = false;
   g_alertArmed    = true;
   g_alertWaiting  = false;
   g_alertSide     = 0;
   g_signalArmed   = false;
   g_signalDir     = 0;
   g_signalBarTime = 0;
   g_waitStartTime = 0;

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
   DeleteFilterPanelObjects();

   // Панель управления
   CreateButtons();
   UpdateButtons();

   Print("Советник инициализирован. Режим: ", (InpAutoMode ? "АВТО" : "МОНИТОР"),
         ", Фильтры: RSI=", InpUseRSI, ", ADX=", InpUseADX, ", Trend=", InpUseTrendFilter,
         ", RSI-BB=", InpUseRSIBB, " (TF=", EnumToString(InpRSIBB_RSITF), ")");
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
   if(m_maHandle != INVALID_HANDLE) IndicatorRelease(m_maHandle);
   if(m_atrH1Handle != INVALID_HANDLE) IndicatorRelease(m_atrH1Handle);
   if(m_rsi2Handle != INVALID_HANDLE) IndicatorRelease(m_rsi2Handle);
   if(m_rsiBBHandle != INVALID_HANDLE)
   {
      long chartId = ChartID();
      int wins = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
      for(int w = 0; w < wins; w++)
         ChartIndicatorDelete(chartId, (int)w, "SG_RSI_BB");
      IndicatorRelease(m_rsiBBHandle);
      m_rsiBBHandle = INVALID_HANDLE;
   }
   DeleteBandObjects();
   ObjectDelete(0, "SG_bid");
   ObjectDelete(0, "SG_dUp");
   ObjectDelete(0, "SG_dDn");
   ObjectDelete(0, "SG_dist");
   ObjectDelete(0, "SG_dist_bg");
   ObjectDelete(0, "SG_rsi");
   DeleteFilterPanelObjects();
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

   // Панель состояния фильтров (справа снизу)
   DrawFilterPanel();

   // --- Вывод текстовой информации ---
   string status = g_waiting ? (g_manualWait ? "WAIT (ручная пауза)" : "WAIT (откат)") : "МОНИТОРИНГ";
   string filters = StringFormat("RSI:%.1f ADX:%.1f RSI-BB:%s", rsi, adx, (InpUseRSIBB ? "ВКЛ" : "ВЫКЛ"));
   string posInfo = (HasOpenPosition() ? StringFormat("ОТКРЫТА (dir=%d)", g_autoDir) : "НЕТ");
   string sigInfo = "";
   if(g_signalArmed && !HasOpenPosition())
      sigInfo = (g_signalDir == 1 ? "ОЖИДАНИЕ BUY (первая бычья свеча M1)" :
                                    "ОЖИДАНИЕ SELL (первая бычья свеча M1)");

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
                           "Сигнал: %s\n"
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
                           (sigInfo == "" ? "—" : sigInfo),
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

   double r[];
   ArraySetAsSeries(r, true);
   if(CopyBuffer(m_rsiHandle, 0, 1, 1, r) == 1) rsi = r[0];

   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(m_adxHandle, 0, 1, 1, b) == 1) adx = b[0];

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
bool OpenAutoTrade(const ENUM_ORDER_TYPE type, const bool bypassFilters = false)
{
   if(!InpAutoMode) return false;
   if(HasOpenPosition())
   {
      Print("Уже есть открытая позиция, новую не открываем");
      return false;
   }

   // Проверка фильтров (реверс после убытка их игнорирует)
   if(!bypassFilters && (!PassFilters(type) || !PassRSIBBFilter(type)))
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
      if(CopyBuffer(m_maHandle, 0, 1, 1, ma) != 1) return false;
      double price = (type == ORDER_TYPE_BUY ? SymbolInfoDouble(m_symbol, SYMBOL_ASK) :
                                               SymbolInfoDouble(m_symbol, SYMBOL_BID));
      if(price > ma[0] && type == ORDER_TYPE_SELL) return false;  // выше MA – не продаём
      if(price < ma[0] && type == ORDER_TYPE_BUY)  return false;  // ниже MA – не покупаем
   }

   return true;
}

//+------------------------------------------------------------------+
//| Авто-торговля: касание BB = сигнал, вход после первой свечи      |
//+------------------------------------------------------------------+
void CheckAutoTrade()
{
   double up, mid, low, atr, rsi, adx;
   int touch;
   double distUp, distLow;
   if(ReadIndicators(up, mid, low, atr, rsi, adx, touch, distUp, distLow) != 0)
      return;

   // Последний закрытый бар M1 – свеча подтверждения
   datetime t1 = iTime(m_symbol, PERIOD_M1, 1);
   double o1[], c1[];
   ArraySetAsSeries(o1, true);
   ArraySetAsSeries(c1, true);
   if(CopyOpen(m_symbol, PERIOD_M1, 1, 1, o1) != 1 ||
      CopyClose(m_symbol, PERIOD_M1, 1, 1, c1) != 1)
      return;
   bool bullBar = (c1[0] > o1[0]);   // бычья свеча (close > open)
   // Подтверждение в любом случае – ПЕРВАЯ БЫЧЬЯ свеча M1 (close > open)

   // 1) Касание полосы BB – только фиксируем ожидающий сигнал
   if(touch == 1 && InpAllowBuy && !g_signalArmed)
   {
      g_signalArmed   = true;
      g_signalDir     = 1;
      g_signalBarTime = t1;
      Print("Сигнал BUY: касание нижней полосы, ждём первую бычью свечу M1");
   }
   else if(touch == -1 && InpAllowSell && !g_signalArmed)
   {
      g_signalArmed   = true;
      g_signalDir     = -1;
      g_signalBarTime = t1;
      Print("Сигнал SELL: касание верхней полосы, ждём первую бычью свечу M1");
   }

   if(!g_signalArmed || g_signalDir == 0)
      return;

   // 2) Вход ПОСЛЕ первой подтверждающей свечи M1:
   //    BUY  – касание нижней полосы
   //    SELL – касание верхней полосы
   if(g_signalDir == 1 && bullBar)
   {
      if(OpenAutoTrade(ORDER_TYPE_BUY))
         Print("Авто-вход BUY после первой бычьей свечи M1");
      ClearSignal();
   }
   else if(g_signalDir == -1 && bullBar)
   {
      if(OpenAutoTrade(ORDER_TYPE_SELL))
         Print("Авто-вход SELL после первой бычьей свечи M1");
      ClearSignal();
   }
   // Подтверждения нет – проверяем окно ожидания
   if(InpConfirmMaxBars > 0 && g_signalBarTime != 0 &&
      t1 - g_signalBarTime >= InpConfirmMaxBars * 60)
   {
      Print("Сигнал отменён: подтверждающая свеча не появилась за ",
            InpConfirmMaxBars, " бар(ов) M1");
      ClearSignal();
   }
   // Окно не истекло – сигнал остаётся ждать следующую свечу
}

//+------------------------------------------------------------------+
//| Сброс ожидающего сигнала входа                                   |
//+------------------------------------------------------------------+
void ClearSignal()
{
   g_signalArmed   = false;
   g_signalDir     = 0;
   g_signalBarTime = 0;
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
   ClearSignal();       // ожидающий сигнал входа сбрасываем

   if(!gotResult)
   {
      Print("Не удалось получить результат закрытой позиции, сбрасываем состояние");
      g_autoDir = 0;
      g_waiting = false;
      g_breakLevel = 0;
      g_waitStartTime = 0;
      return;
   }

   if(totalProfit >= 0)
   {
      Print("Авто-сделка закрыта с прибылью: ", DoubleToString(totalProfit, 2), ". Остаёмся в режиме MONITOR.");
      g_autoDir = 0;
      g_breakLevel = 0;
      g_reverseDone = false;     // новая серия - реверс снова доступен
      g_waitStartTime = 0;
      if(!g_manualWait)          // ручная пауза не сбрасывается автоматически
         g_waiting = false;
   }
   else
   {
      Print("Авто-сделка закрыта с убытком: ", DoubleToString(totalProfit, 2), ".");

      if(InpReverseOnLoss && !g_reverseDone)
      {
         ENUM_ORDER_TYPE revType = (g_autoDir == 1 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         g_reverseDone = true;   // реверс расходуется независимо от результата открытия
         if(OpenAutoTrade(revType, true))
         {
            Print("Реверс: открыта встречная позиция ", EnumToString(revType));
            return;
         }
         Print("Реверс не удался, переходим в WAIT");
      }

      Print("Переходим в режим WAIT, ждём откат к средней.");
      g_waiting = true;
      g_waitStartTime = iTime(m_symbol, PERIOD_M1, 0);   // старт таймаута WAIT
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
      g_waitStartTime = 0;
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
      g_reverseDone = false;   // новая серия ожидания сигналов - реверс снова доступен
      g_waitStartTime = 0;
      ClearSignal();           // сбрасываем ожидающий сигнал входа
      return;
   }

   // Таймаут: откат не произошёл за N свечей M1 – сбрасываем WAIT в MONITOR
   if(InpWaitMaxBars > 0 && g_waitStartTime != 0)
   {
      datetime waitBar = iTime(m_symbol, PERIOD_M1, 0);
      if(waitBar - g_waitStartTime >= (datetime)InpWaitMaxBars * 60)
      {
         Print("WAIT сброшен: откат не произошёл за ", InpWaitMaxBars,
               " свечей M1, возвращаемся в MONITOR.");
         g_waiting = false;
         g_breakLevel = 0;
         g_autoDir = 0;
         g_reverseDone = false;   // новая серия сигналов - реверс снова доступен
         g_waitStartTime = 0;
         ClearSignal();
      }
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
//| Панель состояния фильтров (справа снизу, со смещением влево)    |
//+------------------------------------------------------------------+
// Смещение панели влево от правого края (% ширины графика)
#define FLT_PANEL_XOFFSET_PERCENT 0.15

int FilterPanelXOffset()
{
   return (int)(ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) * FLT_PANEL_XOFFSET_PERCENT);
}

void SetFilterLabel(const string name, const int y, const string text,
                    const color clr, const int fontSize = 10)
{
   const int corner = CORNER_RIGHT_LOWER;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   // Обновляем позицию каждый раз (учитываем изменения ширины окна)
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, FilterPanelXOffset() + 12);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void DrawFilterPanel()
{
   const int corner = CORNER_RIGHT_LOWER;

   // Фон панели
   if(ObjectFind(0, "SG_flt_bg") < 0)
   {
      ObjectCreate(0, "SG_flt_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_CORNER, corner);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_YDISTANCE, 8);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_XSIZE, 270);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_YSIZE, 142);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_BGCOLOR, C'45,45,50');
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_BORDER_COLOR, C'90,90,90');
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SG_flt_bg", OBJPROP_HIDDEN, true);
   }
   // Обновляем позицию каждый раз (учитываем изменения ширины окна)
   ObjectSetInteger(0, "SG_flt_bg", OBJPROP_XDISTANCE, FilterPanelXOffset() + 8);

   // Текущие значения индикаторов
   double rsi = 50, adx = 0, ma = 0;
   double rArr[], aArr[], mArr[];
   ArraySetAsSeries(rArr, true);
   ArraySetAsSeries(aArr, true);
   ArraySetAsSeries(mArr, true);
   if(CopyBuffer(m_rsiHandle, 0, 1, 1, rArr) == 1) rsi = rArr[0];
   if(CopyBuffer(m_adxHandle, 0, 1, 1, aArr) == 1) adx = aArr[0];
   if(CopyBuffer(m_maHandle,  0, 1, 1, mArr) == 1) ma  = mArr[0];
   double price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

   // Заголовок
   SetFilterLabel("SG_flt_hdr", 116, "=== ФИЛЬТРЫ ===", clrWhite, 10);

   // --- RSI ---
   string rsiTxt = StringFormat("RSI(%d) [%s]  %.1f  (OS %.0f / OB %.0f)",
                                InpRSIPeriod, (InpUseRSI ? "ВКЛ" : "ВЫКЛ"), rsi,
                                InpRSIOversold, InpRSIOverbought);
   color rsiClr = clrGray;
   if(InpUseRSI)
      rsiClr = (rsi < InpRSIOversold || rsi > InpRSIOverbought) ? clrRed : clrLime;
   SetFilterLabel("SG_flt_rsi", 70, rsiTxt, rsiClr);

   // --- ADX ---
   string adxTxt = StringFormat("ADX(%d) [%s]  %.1f  (>= %.0f)",
                                InpADXPeriod, (InpUseADX ? "ВКЛ" : "ВЫКЛ"), adx, InpADXMin);
   color adxClr = clrGray;
   if(InpUseADX)
      adxClr = (adx >= InpADXMin) ? clrLime : clrRed;
   SetFilterLabel("SG_flt_adx", 46, adxTxt, adxClr);

   // --- Трендовый фильтр (MA) ---
   string maTxt = StringFormat("TREND(%d) [%s]  %s %s MA %s",
                               InpMATrendPeriod, (InpUseTrendFilter ? "ВКЛ" : "ВЫКЛ"),
                               DoubleToString(price, digits),
                               (price > ma ? ">" : "<"),
                               DoubleToString(ma, digits));
   color maClr = clrGray;
   if(InpUseTrendFilter)
      maClr = (price > ma) ? clrLime : clrOrange;
   SetFilterLabel("SG_flt_tr", 22, maTxt, maClr);

   // --- Фильтр BB по RSI (прямой расчёт через свой RSI) ---
   string rbbTxt = "RSI-BB: ВЫКЛ";
   color rbbClr = clrGray;
   if(InpUseRSIBB)
   {
      int    n2 = InpRSIBB_BBPeriod + 3;
      double rb2[];
      ArraySetAsSeries(rb2, true);
      if(m_rsi2Handle != INVALID_HANDLE &&
         CopyBuffer(m_rsi2Handle, 0, 1, n2, rb2) >= n2)
      {
         double s2 = 0;
         for(int i = 0; i < InpRSIBB_BBPeriod; i++) s2 += rb2[i];
         double ma2 = s2 / InpRSIBB_BBPeriod;
         double v2 = 0;
         for(int i = 0; i < InpRSIBB_BBPeriod; i++)
         {
            double d2 = rb2[i] - ma2;
            v2 += d2 * d2;
         }
         double sd2 = MathSqrt(v2 / InpRSIBB_BBPeriod);
         double lo2 = ma2 - InpRSIBB_BBDev * sd2;
         double up2 = ma2 + InpRSIBB_BBDev * sd2;
         bool okBuy  = (InpRSIBB_Mode == RSIBB_MODE_EXTREME) ?
                       (rb2[0] < lo2 + InpRSIBB_Tolerance) :
                       (rb2[0] < up2 - InpRSIBB_Tolerance);
         bool okSell = (InpRSIBB_Mode == RSIBB_MODE_EXTREME) ?
                       (rb2[0] > up2 - InpRSIBB_Tolerance) :
                       (rb2[0] > lo2 + InpRSIBB_Tolerance);
         rbbTxt = StringFormat("RSI-BB [%s] RSI %.1f | BB %.1f/%.1f",
                               EnumToString(InpRSIBB_RSITF), rb2[0], lo2, up2);
         rbbClr = (okBuy || okSell) ? clrLime : clrOrange;
      }
      else
         rbbTxt = "RSI-BB: нет данных";
   }
   SetFilterLabel("SG_flt_rbb", 92, rbbTxt, rbbClr);
}

//+------------------------------------------------------------------+
//| Удаление объектов панели фильтров                                |
//+------------------------------------------------------------------+
void DeleteFilterPanelObjects()
{
   ObjectDelete(0, "SG_flt_bg");
   ObjectDelete(0, "SG_flt_hdr");
   ObjectDelete(0, "SG_flt_rsi");
   ObjectDelete(0, "SG_flt_adx");
   ObjectDelete(0, "SG_flt_tr");
   ObjectDelete(0, "SG_flt_rbb");
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
   g_waitStartTime = 0;            // таймаут WAIT работает только для авто-режима
   if(!state)
   {
      g_breakLevel = 0;
      g_autoDir    = 0;
      ClearSignal();
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
//| Фильтр BB по RSI (динамические уровни)                           |
//+------------------------------------------------------------------+
bool PassRSIBBFilter(const ENUM_ORDER_TYPE type)
{
   if(!InpUseRSIBB) return true;
   if(m_rsi2Handle == INVALID_HANDLE) return false;

   // Читаем RSI со своего ТФ и считаем полосы BB по нему напрямую
   int    n   = InpRSIBB_BBPeriod + 3;
   double rr[];
   ArraySetAsSeries(rr, true);
   if(CopyBuffer(m_rsi2Handle, 0, 1, n, rr) < n) return false;

   double sum = 0;
   for(int i = 0; i < InpRSIBB_BBPeriod; i++) sum += rr[i];
   double ma = sum / InpRSIBB_BBPeriod;
   double var = 0;
   for(int i = 0; i < InpRSIBB_BBPeriod; i++)
   {
      double d = rr[i] - ma;
      var += d * d;
   }
   double sd = MathSqrt(var / InpRSIBB_BBPeriod);
   double up = ma + InpRSIBB_BBDev * sd;
   double lo = ma - InpRSIBB_BBDev * sd;
   double r  = rr[0];
   double tol = InpRSIBB_Tolerance;

   if(type == ORDER_TYPE_BUY)
   {
      if(InpRSIBB_Mode == RSIBB_MODE_EXTREME)
         return (r < lo + tol);   // покупка при перепроданности RSI
      return (r < up - tol);      // запрет покупки при перекупленности RSI
   }
   else
   {
      if(InpRSIBB_Mode == RSIBB_MODE_EXTREME)
         return (r > up - tol);   // продажа при перекупленности RSI
      return (r > lo + tol);      // запрет продажи при перепроданности RSI
   }

}
//+------------------------------------------------------------------+