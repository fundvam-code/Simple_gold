//+------------------------------------------------------------------+
//|                                                  Simple_gold_v5.mq5 |
//|                                      Copyright 2026, Bondarev A.   |
//|  v5.13: WAIT + pin-bar + RR + сессии GMT (ASIA/LONDON/NY/OVERLAP)    |
//+------------------------------------------------------------------+
//| ОСНОВНЫЕ УЛУЧШЕНИЯ v5.13 (временные сессии GMT):                                          |
//|                                                                    |
//|  1. ФИКСАЦИЯ WAIT ЦИКЛА:                                           |
//|     - ValidateWaitState() проверяет консистентность каждый тик    |
//|     - Разделение ручного (manual) и автоматического WAIT          |
//|     - 24-часовой таймаут безопасности для выхода из зависания     |
//|                                                                    |
//|  2. УЛУЧШЕНИЕ ВХОДА (Entry Confirmation):                         |
//|     - CheckPinBarConfirm() - детекция pin-bar вместо просто свечи  |
//|       BUY: длинный нижний хвост + close>open                     |
//|       SELL: длинный верхний хвост + close<open                   |
//|     - InpPinBarTailRatio - настраиваемое соотношение хвоста/тела   |
//|       (по умолчанию 2.0 = хвост в 2 раза больше тела)             |
//|     - CheckVolatilityFilter() - фильтр волатильности (ATR H1)      |
//|       Принимает: 10-100 пункты                                    |
//|       Отклоняет: <10 (слишком тихо) или >100 (хаос)               |
//|                                                                    |
//|  3. ДИНАМИЧЕСКИЙ RR:                                               |
//|     - CalculateDynamicRR() адаптирует коэффициент к волатильности |
//|     - Формула: RR = 2.0 + (ATR_H1 - 10) / 90 × 1.5                |
//|     - Диапазон RR: 2.0 (низ) до 3.5 (высокая волатильность)       |
//|     - MinRR=1.5 проверка отклоняет невыгодные входы              |
//|                                                                    |
//|  4. ВКЛЮЧЁННЫЕ ФИЛЬТРЫ (4 уровня защиты):                          |
//|     - Уровень 1: RSI фильтр (BUY: RSI<40, SELL: RSI>60)           |
//|     - Уровень 2: ADX (требует тренд ADX>20)                       |
//|     - Уровень 3: MA(200) (BUY: выше MA, SELL: ниже MA)            |
//|     - Уровень 4: Волатильность (10-100 пункты ATR H1)             |
//|                                                                    |
//|  5. НЕЗАВИСИМЫЕ ЛИНИИ БОЛЛИНДЖЕРА:                                 |
//|     - Используют ТОЛЬКО InpMainTF (основной ТФ советника)         |
//|     - НЕ зависят от ТФ графика при открытии или тестировании      |
//|     - Pin-bar проверяется ТОЛЬКО на M1 (жёсткое ограничение)      |
//|     - Касание BB: считается на InpMainTF                          |
//|     - Отрисовка линий: по InpMainTF (независимо от графика)       |
//|                                                                    |
//|  6. ВРЕМЕННЫЕ СЕССИИ (GMT) - гибкий фильтр для тестирования:     |
//|     - ASIA: 00:00-08:00 (ночная сессия)                           |
//|     - LONDON: 08:00-16:00 (европейская сессия)                    |
//|     - NEWYORK: 13:00-21:00 (американская сессия)                  |
//|     - OVERLAP: 13:00-16:00 (пересечение Лондона и НИ)            |
//|     - Каждую сессию можно вкл/выкл отдельно для тестирования      |
//|     - Вне сессии: блокируются новые входы, WAIT отменяется (опц.) |
//|     - Главный выключатель: InpUseSessionFilter (вкл/выкл все)      |
//|                                                                    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bondarev A."
#property link      "https://www.mql5.com"
#property version   "5.13"
#property description "XAUUSD: WAIT валидация + pin-bar (M1) + динамический RR + 4 фильтра + временные сессии GMT (ASIA/LONDON/NEWYORK/OVERLAP)"

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
input double            InpBBOffsetPts   = 0.0;           // Смещение касания BB (пт)
input bool              InpAllowBuy      = true;          // Разрешить BUY вход
input bool              InpAllowSell     = true;          // Разрешить SELL вход

input group "=== Определение Pin-Bar (подтверждение входа) ==="
input double            InpPinBarTailRatio = 2.0;         // Коэффициент хвоста: хвост > тело × этот коэф. (2.0 = хвост в 2 раза больше тела)
input int               InpConfirmMaxBars = 10;           // Окно подтверждения pin-bar: макс. свечей M1 (0 = без лимита)

input group "=== Логика отката (WAIT) с валидацией ==="
input double            InpWaitOffsetPts  = 50.0;         // Отход от g_breakLevel (пт) для выхода из WAIT
input int               InpWaitMaxBars    = 0;            // Сброс WAIT: нет отката за N свечей M1 (0 = без лимита, есть 24ч таймаут)

input group "=== Реверс после убытка ==="
input bool              InpReverseOnLoss  = false;        // Встречная позиция после убытка (обходит фильтры)

input group "=== Трейлинг-стоп (защита прибыли) ==="
input bool              InpTrailEnable     = true;         // Включить трейлинг-стоп после достижения целевой прибыли
input double            InpTrailActivateFrac = 0.5;       // Активация: прибыль > SL × этот коэффициент (0.5 = половина SL)
input int               InpTrailOffsetPts  = 0;            // SL ставится на N пт от текущей цены (0 = безубыток)

input group "=== Индикаторы основной ТФ ==="
input int               InpATRPeriod     = 14;            // Период ATR (для расчёта SL/TP)
input int               InpBBPeriod      = 20;            // Период Bollinger Bands
input double            InpBBDev         = 2.0;           // Стандартные отклонения BB
input ENUM_APPLIED_PRICE InpBBApplied    = PRICE_CLOSE;   // Применяемая цена для BB

input group "=== Фильтры входа (ВКЛЮЧЕНЫ - 4 уровня защиты) ==="
input bool              InpUseRSI        = true;          // Уровень 1: RSI - отклоняет перекупленность/перепроданность
input int               InpRSIPeriod     = 14;            // Период RSI
input double            InpRSIOversold   = 40.0;          // BUY: RSI < 40 (консервативные уровни для XAUUSD)
input double            InpRSIOverbought = 60.0;          // SELL: RSI > 60

input bool              InpUseADX        = true;          // Уровень 2: ADX - отклоняет боковое движение (требует тренда)
input int               InpADXPeriod     = 14;            // Период ADX
input double            InpADXMin        = 20.0;          // Минимум ADX для входа

input bool              InpUseTrendFilter= true;          // Уровень 3: MA(200) - фильтр направления (BUY выше, SELL ниже)
input int               InpMATrendPeriod = 200;           // Период MA для фильтра тренда
input ENUM_MA_METHOD    InpMAMethod      = MODE_SMA;      // Метод MA

input group "=== Фильтр BB по RSI (динамические уровни) ==="
input bool               InpUseRSIBB          = false;        // Дополнительный фильтр: BB по RSI вместо цены
input ENUM_TIMEFRAMES    InpRSIBB_RSITF       = PERIOD_H1;    // Таймфрейм для расчёта RSI
input int                InpRSIBB_RSIPeriod   = 14;           // Период RSI
input ENUM_APPLIED_PRICE InpRSIBB_RsiApplied  = PRICE_CLOSE;  // Применяемая цена для RSI
input int                InpRSIBB_BBPeriod    = 20;           // Период BB (по RSI)
input double             InpRSIBB_BBDev       = 2.0;          // Отклонение BB
input ENUM_RSIBB_MODE    InpRSIBB_Mode        = RSIBB_MODE_EXTREME; // Режим фильтра
input double             InpRSIBB_Tolerance   = 0.0;          // Допуск от полосы (ед. RSI)

input group "=== ВРЕМЕННЫЕ СЕССИИ (GMT) ==="
input bool              InpUseSessionFilter   = true;         // ГЛАВНЫЙ ВЫКЛЮЧАТЕЛЬ: фильтр временных сессий
input bool              InpEnableASIA         = true;         // Включить ASIATIC (00:00-08:00 GMT)
input bool              InpEnableLONDON       = true;         // Включить LONDON (08:00-16:00 GMT)
input bool              InpEnableNEWYORK      = true;         // Включить NEWYORK (13:00-21:00 GMT)
input bool              InpEnableOVERLAP      = true;         // Включить OVERLAP (13:00-16:00 GMT пересечение)
input bool              InpCancelWaitOutSession = true;       // Отменять WAIT при выходе из сессии

input group "=== Нотификации ==="
input bool              InpAlertEnable   = true;          // Показывать нотификации при касании полос

input double            InpAlertTriggerPts = 50.0;         // Расстояние до алерта (пт) - воспминание

input bool              InpAlertLocal    = true;          // Локальные алерты
input bool              InpAlertPush     = true;          // Push-нотификации

input group "=== Визуализация и дебуг ==="
input bool              InpShowIndicators = true;         // Показывать BB, ATR и другие индикаторы на графике

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

   Print("\n========== ПРОСТОЙ ЗОЛОТО v5.10 ==========");
   Print("Режим: ", (InpAutoMode ? "АВТО" : "МОНИТОР"));
   Print("Версия: 5.10 - WAIT валидация + pin-bar вход + динамический RR + 4 фильтра");
   Print("Фильтры входа:");
   Print("  1. RSI: ", (InpUseRSI ? "ВКЛ (BUY<40, SELL>60)" : "ВЫКЛ"));
   Print("  2. ADX: ", (InpUseADX ? "ВКЛ (>20)" : "ВЫКЛ"));
   Print("  3. MA200: ", (InpUseTrendFilter ? "ВКЛ (фильтр тренда)" : "ВЫКЛ"));
   Print("  4. Волатильность: ВКЛ (10-100 пт ATR H1)");
   Print("Дополнительно: RSI-BB=", (InpUseRSIBB ? "ВКЛ" : "ВЫКЛ"), " (TF=", EnumToString(InpRSIBB_RSITF), ")");
   Print("Вход: pin-bar подтверждение + динамический RR (2.0-3.5)");
   Print("\n========== ВРЕМЕННЫЕ СЕССИИ (GMT) ==========");
   Print("Фильтр сессий: ", (InpUseSessionFilter ? "ВКЛ" : "ВЫКЛ"));
   if(InpUseSessionFilter)
   {
      Print("  ASIA (00:00-08:00): ", (InpEnableASIA ? "ВКЛ" : "ВЫКЛ"));
      Print("  LONDON (08:00-16:00): ", (InpEnableLONDON ? "ВКЛ" : "ВЫКЛ"));
      Print("  NEWYORK (13:00-21:00): ", (InpEnableNEWYORK ? "ВКЛ" : "ВЫКЛ"));
      Print("  OVERLAP (13:00-16:00): ", (InpEnableOVERLAP ? "ВКЛ" : "ВЫКЛ"));
      Print("  Отмена WAIT при выходе из сессии: ", (InpCancelWaitOutSession ? "ВКЛ" : "ВЫКЛ"));
   }
   Print("========================================\n");
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
//+------------------------------------------------------------------+
//| Основной цикл советника - логика обработки каждого тика           |
//| Порядок: 1. Валидация WAIT  2. Трейлинг-стоп  3. Закрытие позиции |
//|          4. Проверка отката (если в WAIT)  5. Новые входы        |
//+------------------------------------------------------------------+
void OnTick()
{
   // Обновление данных и визуализации
   UpdatePanel();

   // [TRAILING_STOP] Трейлинг-стоп (фиксация прибыли)
   CheckTrailingStop();

   // [POSITION_CLOSE] Обработка закрытия позиции (переход в WAIT при убытке)
   CheckPositionClose();

   // [WAIT_VALIDATION] Валидация состояния WAIT (проверка консистентности каждый тик)
   ValidateWaitState();

   // [WAIT_CHECK] Если в WAIT – проверяем откат к средней для выхода
   if(g_waiting)
      CheckWaitCondition();

   // [NEW_ENTRY] Авто-торговля (если разрешена и нет WAIT и нет открытой позиции)
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

   // Касание на InpMainTF (предпоследний закрытый бар, независимо от графика)
   double m1Hi[], m1Lo[];
   ArraySetAsSeries(m1Hi, true); ArraySetAsSeries(m1Lo, true);
   if(CopyHigh(m_symbol, InpMainTF, 1, 2, m1Hi) != 2) return -1;
   if(CopyLow(m_symbol, InpMainTF, 1, 2, m1Lo) != 2)  return -1;

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
//| Расчет динамического RR адаптивно к волатильности (ATR H1)       |
//| Формула: RR = 2.0 + (ATR_H1 - 10) / (100 - 10) × 1.5              |
//| Результат: RR от 2.0 (низкая волатильность) до 3.5 (высокая)     |
//| MinRR=1.5: если RR<1.5 - вход отклоняется как невыгодный        |
//+------------------------------------------------------------------+
double CalculateDynamicRR()
{
   double atrH1[];
   ArraySetAsSeries(atrH1, true);
   if(CopyBuffer(m_atrH1Handle, 0, 1, 1, atrH1) != 1)
      return InpRR;  // Если ошибка, используем фиксированный RR

   double atr = atrH1[0];
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double atrPts = atr / point;

   // Диапазон волатильности (в пунктах)
   const double MIN_VOLATILITY_PTS = 10.0;
   const double MAX_VOLATILITY_PTS = 100.0;

   // Динамический RR: базовый 2.0 + волатильность фактор (от 0 до 1.5)
   // Когда ATR низкий: RR = 2.0
   // Когда ATR высокий: RR = 3.5
   double volFactor = 0.0;
   if(atrPts >= MAX_VOLATILITY_PTS)
      volFactor = 1.5;  // Максимум
   else if(atrPts <= MIN_VOLATILITY_PTS)
      volFactor = 0.0;  // Минимум
   else
      volFactor = (atrPts - MIN_VOLATILITY_PTS) / (MAX_VOLATILITY_PTS - MIN_VOLATILITY_PTS) * 1.5;

   double dynamicRR = 2.0 + volFactor;  // RR от 2.0 до 3.5

   Print("[DYNAMIC_RR] ATR H1=", atrPts, " пт, RR=", DoubleToString(dynamicRR, 2));
   return dynamicRR;
}

//+------------------------------------------------------------------+
//| Открытие сделки (только авто) с динамическим RR                   |
//| SL = ATR × InpATRSLMult                                           |
//| TP = SL × CalculateDynamicRR() (адаптивно к волатильности)           |
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
   // Используем динамический RR вместо фиксированного InpRR
   double dynamicRR = CalculateDynamicRR();
   double tpDist = slDist * dynamicRR;
   
   // Проверка MinRR = 1.5 (минимальное соотношение профита к убытку)
   const double MIN_RR = 1.5;
   if(dynamicRR < MIN_RR)
   {
      Print("[ENTRY_REJECT] RR =", DoubleToString(dynamicRR, 2), " < MinRR=", DoubleToString(MIN_RR, 2), ". Входит невыгоден.");
      return false;
   }
   
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
//| Проверка фильтров входа (УРОВНИ 2-3): RSI, ADX, MA(200)           |
//| BUY: RSI<40, ADX>20, цена выше MA200                             |
//| SELL: RSI>60, ADX>20, цена ниже MA200                            |
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
//| Проверка пин-бара для подтверждения (на M1)                     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Детекция pin-bar (хвост > 2x тела) для подтверждения входа        |
//| BUY: длинный нижний хвост (ниже open) + close>open (быч. свеча)   |
//| SELL: длинный верхний хвост (выше open) + close<open (медв. свеча)|
//+------------------------------------------------------------------+
bool CheckPinBarConfirm(const int direction)  // direction: +1 = BUY, -1 = SELL
{
   // Получаем последнюю свечу M1 (закрытую)
   double o[], c[], h[], l[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);

   if(CopyOpen(m_symbol, PERIOD_M1, 1, 1, o) != 1 ||
      CopyClose(m_symbol, PERIOD_M1, 1, 1, c) != 1 ||
      CopyHigh(m_symbol, PERIOD_M1, 1, 1, h) != 1 ||
      CopyLow(m_symbol, PERIOD_M1, 1, 1, l) != 1)
      return false;

   // Чтобы был пин-бар (пустотель) и правильное направление закрытия:
   bool pinBarBody = false;
   bool correctClose = false;

   if(direction == 1)  // BUY: Нижняя тень длинная, Close > Open
   {
      double bodySize = MathAbs(c[0] - o[0]);
      double tailSize = MathAbs(o[0] - l[0]);
      double topSize  = MathAbs(h[0] - c[0]);

      // Нижняя тень > тела * InpPinBarTailRatio (пин-бар)
      pinBarBody = (tailSize > bodySize * InpPinBarTailRatio);
      // Close > Open (верное направление)
      correctClose = (c[0] > o[0]);
   }
   else if(direction == -1)  // SELL: Верхняя тень длинная, Close < Open
   {
      double bodySize = MathAbs(c[0] - o[0]);
      double tailSize = MathAbs(h[0] - o[0]);
      double botSize  = MathAbs(c[0] - l[0]);

      // Верхняя тень > тела * InpPinBarTailRatio (пин-бар)
      pinBarBody = (tailSize > bodySize * InpPinBarTailRatio);
      // Close < Open (верное направление)
      correctClose = (c[0] < o[0]);
   }

   return (pinBarBody && correctClose);
}

//+------------------------------------------------------------------+
//| Проверка текущего времени в GMT сессиях                          |
//| Возвращает: 1=ASIA, 2=LONDON, 3=NEWYORK, 4=OVERLAP, -1=вне сессий|
//+------------------------------------------------------------------+
int GetCurrentSession()
{
   // Если фильтр отключен - все сессии включены
   if(!InpUseSessionFilter)
      return 1;  // Вернуть любую активную сессию

   datetime now = TimeCurrent();
   int hour = Hour(now);

   // OVERLAP: 13:00-16:00 (приоритет выше)
   if(InpEnableOVERLAP && hour >= 13 && hour < 16)
      return 4;

   // ASIA: 00:00-08:00
   if(InpEnableASIA && hour >= 0 && hour < 8)
      return 1;

   // LONDON: 08:00-16:00
   if(InpEnableLONDON && hour >= 8 && hour < 16)
      return 2;

   // NEWYORK: 13:00-21:00
   if(InpEnableNEWYORK && hour >= 13 && hour < 21)
      return 3;

   return -1;  // Вне всех сессий
}

//+------------------------------------------------------------------+
//| Получить название сессии (для логирования и вывода)              |
//+------------------------------------------------------------------+
string GetSessionName(int sessionID)
{
   switch(sessionID)
   {
      case 1:  return "ASIA (00:00-08:00)";
      case 2:  return "LONDON (08:00-16:00)";
      case 3:  return "NEWYORK (13:00-21:00)";
      case 4:  return "OVERLAP (13:00-16:00)";
      default: return "OUT OF SESSION";
   }
}

//+------------------------------------------------------------------+
//| Проверка: находимся ли мы в активной сессии (GMT)               |
//+------------------------------------------------------------------+
bool IsTimeInSession()
{
   return GetCurrentSession() != -1;
}

//+------------------------------------------------------------------+
//| Фильтр волатильности (колебание ATR H1)                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Фильтр волатильности: отклоняет входы при слишком тихом или       |
//| слишком хаотичном рынке (проверяет ATR на H1)                     |
//| Диапазон: 10-100 пункты. <10 = мало движения, >100 = хаос/слипы   |
//+------------------------------------------------------------------+
bool CheckVolatilityFilter()
{
   double atrH1[];
   ArraySetAsSeries(atrH1, true);
   if(CopyBuffer(m_atrH1Handle, 0, 1, 1, atrH1) != 1)
      return false;  // Нет данных, разрешаем вход

   double atr = atrH1[0];
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double atrPts = atr / point;

   // Волатильность средняя: ATR в диапазоне 10-100 пт (оптимально для торговли)
   const double MIN_VOLATILITY_PTS = 10.0;
   const double MAX_VOLATILITY_PTS = 100.0;

   if(atrPts < MIN_VOLATILITY_PTS)
   {
      Print("[VOLATILITY] Слишком низкая волатильность (ATR H1 = ", atrPts, " пт < ", MIN_VOLATILITY_PTS, "). Пропускаем.");
      return false;
   }
   if(atrPts > MAX_VOLATILITY_PTS)
   {
      Print("[VOLATILITY] Слишком высокая волатильность (ATR H1 = ", atrPts, " пт > ", MAX_VOLATILITY_PTS, "). Пропускаем.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Авто-торговля: касание BB = сигнал, вход афтер пин-бар      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Автоматическая проверка на вход с pin-bar подтверждением         |
//| Логика: 1) Касание BB -> вооружение сигнала                        |
//|         2) Проверка фильтров (RSI, ADX, MA200, волатильность)      |
//|         3) Ожидание pin-bar подтверждения на M1                    |
//|         4) Открытие с динамическим RR (2.0-3.5)                   |
//+------------------------------------------------------------------+
void CheckAutoTrade()
{
   double up, mid, low, atr, rsi, adx;
   int touch;
   double distUp, distLow;
   if(ReadIndicators(up, mid, low, atr, rsi, adx, touch, distUp, distLow) != 0)
      return;

   // [ENTRY_FILTER_1] Проверяем фильтр волатильности (ATR H1: 10-100 пт)
   if(!CheckVolatilityFilter())
      return;

   // [ENTRY_FILTER_2] Проверяем фильтр временных сессий (GMT)
   if(InpUseSessionFilter && !IsTimeInSession())
      return;

   // Получаем последнюю свечу M1 (закрытую)
   datetime t1 = iTime(m_symbol, PERIOD_M1, 1);
   double o1[], c1[];
   ArraySetAsSeries(o1, true);
   ArraySetAsSeries(c1, true);
   if(CopyOpen(m_symbol, PERIOD_M1, 1, 1, o1) != 1 ||
      CopyClose(m_symbol, PERIOD_M1, 1, 1, c1) != 1)
      return;

   // 1) Касание полосы BB – только фиксируем ожидающий сигнал
   if(touch == 1 && InpAllowBuy && !g_signalArmed)
   {
      g_signalArmed   = true;
      g_signalDir     = 1;
      g_signalBarTime = t1;
      Print("[SIGNAL] BUY: касание нижней полосы BB, ждём пин-бар на M1");
   }
   else if(touch == -1 && InpAllowSell && !g_signalArmed)
   {
      g_signalArmed   = true;
      g_signalDir     = -1;
      g_signalBarTime = t1;
      Print("[SIGNAL] SELL: касание верхней полосы BB, ждём пин-бар на M1");
   }

   if(!g_signalArmed || g_signalDir == 0)
      return;

   // 2) Выздывать до пин-бара на M1:
   if(g_signalDir == 1 && CheckPinBarConfirm(1))  // BUY и пин-бар сформировался
   {
      if(OpenAutoTrade(ORDER_TYPE_BUY))
         Print("[ENTRY] Авто-вход BUY афтер пин-бар M1");
      ClearSignal();
   }
   else if(g_signalDir == -1 && CheckPinBarConfirm(-1))  // SELL и пин-бар сформировался
   {
      if(OpenAutoTrade(ORDER_TYPE_SELL))
         Print("[ENTRY] Авто-вход SELL афтер пин-бар M1");
      ClearSignal();
   }

   // Проверяем окно ожидания
   if(InpConfirmMaxBars > 0 && g_signalBarTime != 0 &&
      t1 - g_signalBarTime >= InpConfirmMaxBars * 60)
   {
      Print("[SIGNAL] Отмена: пин-бар не появился за ", InpConfirmMaxBars, " бар(ов) M1");
      ClearSignal();
   }
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
//| Валидация состояния WAIT - проверка консистентности каждый тик    |
//+------------------------------------------------------------------+
void ValidateWaitState()
{
   // Если нет открытой позиции и WAIT активен, это ошибка
   if(g_waiting && HasOpenPosition())
   {
      // Позиция открыта но мы в WAIT - это ошибка, выходим
      Print("[WARN] Позиция открыта но g_waiting=true. Сбрасываем WAIT.");
      g_waiting = false;
      g_waitStartTime = 0;
      return;
   }

   // Если в авто-WAIT проверяем, не развалилось ли состояние
   if(g_waiting && !g_manualWait)
   {
      // Если g_autoDir невалиден, выходим из WAIT
      if(g_autoDir != 1 && g_autoDir != -1)
      {
         Print("[WARN] g_autoDir невалиден (", g_autoDir, "). Сбрасываем WAIT.");
         g_waiting = false;
         g_breakLevel = 0;
         g_waitStartTime = 0;
         ClearSignal();
         return;
      }

      // Если g_breakLevel == 0, выходим из WAIT
      if(g_breakLevel == 0)
      {
         Print("[WARN] g_breakLevel == 0 в авто-WAIT. Сбрасываем WAIT.");
         g_waiting = false;
         g_autoDir = 0;
         g_waitStartTime = 0;
         ClearSignal();
         return;
      }

      // Если WAIT продолжается более 24 часов без движения - принудительный выход
      if(g_waitStartTime != 0)
      {
         datetime nowBar = iTime(m_symbol, PERIOD_M1, 0);
         if(nowBar - g_waitStartTime >= 86400)  // 24 часа = 86400 секунд
         {
            Print("[WARN] WAIT длится > 24 часов. Принудительный выход в MONITOR.");
            g_waiting = false;
            g_breakLevel = 0;
            g_autoDir = 0;
            g_reverseDone = false;
            g_waitStartTime = 0;
            ClearSignal();
            return;
         }
      }
   }

   // Если в ручном режиме но открыта позиция - выходим из ручного WAIT
   if(g_waiting && g_manualWait && HasOpenPosition())
   {
      Print("[WARN] В ручном WAIT открыта позиция. Сбрасываем режим паузы.");
      g_manualWait = false;
      g_waiting = false;
      ClearSignal();
   }
}

//+------------------------------------------------------------------+
//| Проверка условия отката (откат к средней полосе BB)              |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Проверка условия отката WAIT: откат от g_breakLevel на offset    |
//| Ручной WAIT: игнорирует условия, только выход по кнопке         |
//| Автоматический WAIT: требует откат + таймаут (24ч или N свечей)  |
//+------------------------------------------------------------------+
void CheckWaitCondition()
{
   if(!g_waiting) return;

   // Если ручной WAIT - просто ждём нажатия кнопки, без проверки условий
   if(g_manualWait)
      return;

   // [SESSION] Проверяем выход из активной сессии - отмена WAIT
   if(InpCancelWaitOutSession && InpUseSessionFilter && !IsTimeInSession())
   {
      Print("[SESSION] Выход из активной сессии. Отмена WAIT режима.");
      g_waiting = false;
      g_breakLevel = 0;
      g_autoDir = 0;
      g_reverseDone = false;
      g_waitStartTime = 0;
      ClearSignal();
      return;
   }

   // Авто-WAIT: проверяем откат и таймаут
   if(g_breakLevel == 0 || (g_autoDir != 1 && g_autoDir != -1))
   {
      Print("[DEBUG] Exit WAIT: invalid state (breakLevel=" , g_breakLevel, ", autoDir=", g_autoDir, ")");
      g_waiting = false;
      g_breakLevel = 0;
      g_autoDir = 0;
      g_reverseDone = false;
      g_waitStartTime = 0;
      ClearSignal();
      return;
   }

   double bid   = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

   // Отход от линии пробоя, ограниченный средней полосой BB (в пунктах)
   double offsetPts = MathMin(InpWaitOffsetPts,
                              (g_bbMid != 0 ? MathAbs(g_bbMid - g_breakLevel) / point : InpWaitOffsetPts));
   double waitLevel = (g_autoDir == 1) ? g_breakLevel + offsetPts * point
                                       : g_breakLevel - offsetPts * point;

   // Проверка условия отката: цена вернулась на уровень?
   // BUY: цена поднялась до уровня / SELL: цена опустилась до уровня
   bool waitComplete = (g_autoDir == 1) ? (bid >= waitLevel) : (bid <= waitLevel);

   if(waitComplete)
   {
      Print("[INFO] Откат достигнут: bid=", DoubleToString(bid, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
            ", waitLevel=", DoubleToString(waitLevel, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
            ". Выходим из WAIT в MONITOR.");
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
      datetime nowBar = iTime(m_symbol, PERIOD_M1, 0);
      // Проверяем в секундах (не bar-bar)
      if(nowBar - g_waitStartTime >= (datetime)InpWaitMaxBars * 60)
      {
         Print("[INFO] WAIT сброшен по таймауту: откат не произошёл за ", InpWaitMaxBars,
               " свечей M1. Возвращаемся в MONITOR.");
         g_waiting = false;
         g_breakLevel = 0;
         g_autoDir = 0;
         g_reverseDone = false;   // новая серия сигналов - реверс снова доступен
         g_waitStartTime = 0;
         ClearSignal();
         return;
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
//+------------------------------------------------------------------+
//| Управление WAIT состоянием: вход/выход с явным сбросом переменных |
//| true = вход в WAIT, false = выход из WAIT с полной очисткой       |
//+------------------------------------------------------------------+
void SetManualWait(const bool state)
{
   if(state)
   {
      // Вход в ручной WAIT
      g_manualWait = true;
      g_waiting = true;
      g_waitStartTime = 0;   // ручной режим не использует таймаут
      Print("[INFO] Ручной WAIT: режим паузы активирован. Нажмите MONITORING для выхода.");
   }
   else
   {
      // Выход из ручного WAIT в режим MONITORING
      if(g_manualWait)
      {
         Print("[INFO] Выход из ручного WAIT в режим MONITORING.");
      }
      g_manualWait = false;
      g_waiting = false;
      g_breakLevel = 0;
      g_autoDir = 0;
      g_waitStartTime = 0;
      ClearSignal();
   }
   UpdateButtons();
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