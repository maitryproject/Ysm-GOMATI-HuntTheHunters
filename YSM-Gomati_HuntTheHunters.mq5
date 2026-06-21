//+------------------------------------------------------------------+
//|  YSM-Gomati_HuntTheHunters.mq5                                 |
//|  ARCHITECT : Yogeshwar Singh Maitry                             |
//|  SYSTEM    : YSM-GOMATI 6.03 / Hunt The Hunters — FINAL        |
//|                                                                  |
//|  CORE PHILOSOPHY                                                 |
//|  Institutions hunt retail stop orders clustered above swing     |
//|  highs and below swing lows (the "gate"). They push price       |
//|  through these gates, fill their orders, then reverse hard.     |
//|  This EA detects the sweep (hunt), confirms the reversal, and  |
//|  enters WITH institutions — hunting the hunters.                |
//|                                                                  |
//|  PREMIUM POOLS (highest probability targets)                    |
//|    • Asian Session High/Low — London sweeps Asian range daily   |
//|    • Previous Day High/Low — major institutional reference       |
//|    • Standard swing high/low — regular liquidity pools          |
//|                                                                  |
//|  SETUP QUALITY SCORING (only A+ setups trade)                  |
//|    Pool type bonus : Asian/PDH-PDL = +3,  Swing = +1           |
//|    Order Block avail: +1                                        |
//|    FVG avail        : +1                                        |
//|    Maximum score    : 5   Default minimum: 3                   |
//|    NOTE: HTF/PD/Session bonuses removed (B12 fix) — Gate1      |
//|    already enforces them; double-counting made score 1-4 dead  |
//|                                                                  |
//|  ENTRY MODES                                                    |
//|    CHoCH market order / OB limit / FVG limit / CHoCH fallback  |
//|                                                                  |
//|  CONFLUENCE FILTERS (each independently togglable)             |
//|    HTF EMA trend / Premium-Discount / Session-Killzone          |
//|    ATR volatility (skip ranging and news spikes)                |
//|    Max SL distance cap / Displacement body ratio                |
//|    Spread cap                                                   |
//|                                                                  |
//|  TRADE MANAGEMENT                                               |
//|    Risk% or fixed lot / Break-even / Partial close             |
//|    Trailing stop (pip-based, activates at configurable R)       |
//|    Daily drawdown and profit cap                                 |
//|                                                                  |
//|  ZERO DAMAGE — ALL 18 AUDIT BUGS FIXED                         |
//|  B01-B09: swing detection, FVG, OrderOpen, limit fill,         |
//|           HUD, OB/FVG fallback, SL validation, pool capacity,  |
//|           pool swept-marking (B09 = critical filter-reject bug) |
//|  B10: input clamping  B11: partial-done inference on restart   |
//|  BUG-A: lot sizing guard (tickVal/tickSize zero protection)     |
//|  BUG-B: Asian range per-bar GMT conversion on init seeding      |
//|  B-LIMIT: limit price validation uses correct ask/bid reference |
//|  B12: quality gate double-counted hard-gate filters (dead gate) |
//|  B13: Asian seed trigger hour==8 → >=8 (H2/H4 bar skip risk)  |
//|  B15: MaxPools unguarded → ArraySize-1=-1 crash on 0/neg input |
//|  B16: Asian reset keyed off GMT date not broker D1 rollover    |
//|  B17: init-seed didn't stamp GMT day-key → B16 reset wiped it  |
//|       on first OnBar() after restart past 08:00 GMT            |
//+------------------------------------------------------------------+
#property copyright "YSM-Gomati Architecture"
#property version   "6.03"
#property strict

#include <Trade\Trade.mqh>
CTrade g_Trade;

#define YSM_OWNER  "Yogeshwar Singh Maitry"
#define YSM_SIGN   "YSM Hunt The Hunters"
#define YSM_MAGIC  20261302

//=======================================================================
//  ENUMERATIONS
//=======================================================================
enum ENUM_ENTRY_MODE {
   ENTRY_CHOCH   = 0,  // Market order on CHoCH break
   ENTRY_OB      = 1,  // Limit at OB midpoint; CHoCH fallback if no OB
   ENTRY_FVG     = 2,  // Limit at FVG midpoint; CHoCH fallback if no FVG
   ENTRY_OB_FVG  = 3   // OB first, FVG second, CHoCH fallback
};

enum ENUM_RISK_MODE {
   RISK_FIXED_LOT = 0,
   RISK_PERCENT   = 1
};

enum ENUM_SESSION_MODE {
   SESSION_OFF       = 0,
   SESSION_KILLZONE  = 1,
   SESSION_LONDON    = 2,
   SESSION_NY        = 3,
   SESSION_LONDON_NY = 4
};

enum ENUM_POOL_TYPE {
   POOL_SWING    = 0, // Standard swing high/low
   POOL_ASIAN    = 1, // Asian session range extreme
   POOL_PDH_PDL  = 2  // Previous day high/low
};

//=======================================================================
//  INPUTS
//=======================================================================
input group "=== INSTITUTIONAL POOLS ==="
input bool   UseAsianRange   = true;  // Track Asian H/L as premium pools
input bool   UsePrevDayHL    = true;  // Track Previous Day H/L as premium pools
input int    SwingLookback   = 5;     // Bars each side to confirm a swing
input int    MaxPoolAge      = 100;   // Drop pools older than N bars
input int    MaxPools        = 30;    // Max tracked pools (increased for premium pools)

input group "=== SWEEP FILTER ==="
input double SweepMinPips    = 1.0;
input double SweepMaxPips    = 30.0;
input double MaxSpreadPips   = 3.0;

input group "=== SETUP QUALITY GATE ==="
input int    MinQualityScore = 3;     // Min score to enter (0=off). Max possible=5.
input double MaxSL_Pips      = 25.0;  // Skip if SL > N pips (0=off; protects vs wide SL)

input group "=== ENTRY MODE ==="
input ENUM_ENTRY_MODE EntryMode    = ENTRY_CHOCH;
input int    CHoCH_Lookback        = 20;
input int    OB_LookbackBars       = 12;
input int    OB_FVG_ExpiryBars     = 30;

input group "=== DISPLACEMENT CONFIRMATION ==="
input bool   RequireDisplacement   = true;
input double DispBodyRatio         = 0.50;

input group "=== HTF TREND ALIGNMENT ==="
input bool            HTF_Filter     = true;
input ENUM_TIMEFRAMES HTF_Period     = PERIOD_H4;
input int             HTF_EMA_Period = 50;

input group "=== PREMIUM / DISCOUNT FILTER ==="
input bool   PD_Filter   = true;
input int    PD_Lookback = 50;
input double PD_ZonePct  = 30.0;

input group "=== ATR VOLATILITY FILTER ==="
input bool   ATR_Filter  = true;
input int    ATR_Period   = 14;
input double ATR_MinPips  = 3.0;   // Skip if ATR < this pips (too quiet / ranging)
input double ATR_MaxPips  = 60.0;  // Skip if ATR > this pips (news spike)

input group "=== SESSION / KILLZONE (GMT hours) ==="
input ENUM_SESSION_MODE SessionMode = SESSION_KILLZONE;
input int    London_Start   = 8;
input int    London_End     = 17;
input int    NY_Start       = 13;
input int    NY_End         = 22;
input int    LondonKZ_Start = 8;
input int    LondonKZ_End   = 10;
input int    NYKZ_Start     = 13;
input int    NYKZ_End       = 15;

input group "=== RISK MANAGEMENT ==="
input ENUM_RISK_MODE RiskMode      = RISK_PERCENT;
input double FixedLotSize          = 0.10;
input double RiskPercent           = 1.0;
input double SL_BufferPips         = 2.0;
input double TP_RR                 = 2.0;
input double BE_R                  = 1.0;   // Break-even R (0=off)
input double Partial_R             = 1.0;   // Partial close 50% at this R (0=off)
input double Trail_R               = 2.0;   // Trailing stop activates at this R (0=off)
input double Trail_Pips            = 8.0;   // Trail stop distance in pips
input int    MaxPositions          = 2;
input double MaxDailyLossUSD       = 150.0;
input double MaxDailyProfitUSD     = 400.0;

//=======================================================================
//  STRUCTURES
//=======================================================================
struct LiquidityPool {
   double         price;
   datetime       barTime;
   bool           isHigh;
   bool           swept;
   ENUM_POOL_TYPE type;       // SWING / ASIAN / PDH_PDL
};

struct OrderBlock {
   double   high, low, mid;
   datetime barTime;
   bool     isBull, valid;
};

struct FVG {
   double   top, bottom, mid;
   datetime barTime;
   bool     isBull, valid;
};

struct Setup {
   bool       active;
   bool       isBull;
   double     sweepExtreme;
   double     slPrice;
   double     chochLevel;
   OrderBlock ob;
   FVG        fvg;
   ulong      pendingTicket;
   int        barsSinceSweep;
   bool       limitModeFallback;
   int        poolIdx;
   int        qualityScore;
};

struct ManagedPos {
   ulong  ticket;
   double entryPrice;
   double slPrice;
   double tpPrice;
   bool   isBull;
   bool   beApplied;
   bool   partialDone;
   bool   trailActive;      // trailing stop ever fired
};

//=======================================================================
//  GLOBALS
//=======================================================================
LiquidityPool g_Pools[];
int           g_PoolCount     = 0;
Setup         g_Setup;
ManagedPos    g_Managed[20];
int           g_ManagedCount  = 0;

int           h_HTF_EMA       = INVALID_HANDLE;
int           h_ATR           = INVALID_HANDLE;
datetime      g_LastBarTime   = 0;
double        g_DayStartBalance = 0;
datetime      g_DayStartTime  = 0;

// Asian Range state (resets at 00:00 GMT)
datetime      g_AsianDate     = 0;
int           g_AsianGmtDayKey= -1;   // B16: GMT calendar date key (yyyymmdd), broker-offset-agnostic
double        g_AsianH        = 0.0;
double        g_AsianL        = DBL_MAX;
bool          g_AsianSeeded   = false; // premium pools added this day?

// Previous Day H/L
double        g_PrevDayH      = 0.0;
double        g_PrevDayL      = 0.0;
datetime      g_PrevDayDate   = 0;

// Validated inputs
int           v_SwingLookback;
int           v_CHoCH_Lookback;

//=======================================================================
//  UTILITIES
//=======================================================================
double PipFactor()              { return (_Digits==3||_Digits==5)?10.0:1.0; }
double PipsToPrice(double pips) { return pips*_Point*PipFactor(); }
double PriceInPips(double dist) { return dist/_Point/PipFactor(); }
double SpreadPips() {
   return (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))
          /_Point/PipFactor();
}

//=======================================================================
//  POSITION UTILITIES
//=======================================================================
int CountPositions() {
   int n=0;
   for(int i=0;i<PositionsTotal();i++){
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)
         && PositionGetString(POSITION_SYMBOL)==_Symbol
         && (long)PositionGetInteger(POSITION_MAGIC)==(long)YSM_MAGIC) n++;
   }
   return n;
}

void AddManaged(ulong ticket,double entry,double sl,double tp,
                bool bull,bool partialAlreadyDone=false) {
   if(g_ManagedCount>=20) return;
   for(int i=0;i<g_ManagedCount;i++) if(g_Managed[i].ticket==ticket) return;
   ManagedPos p;
   p.ticket=ticket; p.entryPrice=entry; p.slPrice=sl; p.tpPrice=tp;
   p.isBull=bull; p.beApplied=false; p.partialDone=partialAlreadyDone;
   p.trailActive=false;
   g_Managed[g_ManagedCount++]=p;
}

void RemoveManagedAt(int idx) {
   for(int i=idx;i<g_ManagedCount-1;i++) g_Managed[i]=g_Managed[i+1];
   g_ManagedCount--;
}

// B04+B11 FIX: auto-register limit-filled positions; infer partialDone on restart
void SyncManagedPositions() {
   for(int i=0;i<PositionsTotal();i++){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=(long)YSM_MAGIC) continue;
      bool found=false;
      for(int j=0;j<g_ManagedCount;j++) if(g_Managed[j].ticket==t){found=true;break;}
      if(found) continue;
      double ep  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      bool   bull= ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double expLot = CalcLot(ep,sl);
      double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      double minL   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      // B11 FIX: infer if partial was already done (volume noticeably reduced)
      bool   partDone=(expLot>minL+step)&&(vol<expLot*0.75);
      AddManaged(t,ep,sl,tp,bull,partDone);
      Print("Gate Hunter | SyncManaged ticket=",t," bull=",bull," partialDone inferred=",partDone);
   }
}

//=======================================================================
//  RISK / LOT SIZING
//=======================================================================
double CalcLot(double entry,double sl) {
   if(RiskMode==RISK_FIXED_LOT) return FixedLotSize;
   double riskUSD  = AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
   double slDist   = MathAbs(entry-sl);
   double tickVal  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   // BUG-A FIX: guard tickVal<=0 — broker data error would otherwise produce lot=inf
   // which MathMin(maxL, inf) clamps to maxL causing a massively over-leveraged entry.
   if(tickSize<=0||tickVal<=0||slDist<=0) return FixedLotSize;
   double lot  = riskUSD/(slDist/tickSize*tickVal);
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lot=MathFloor(lot/step)*step;
   return MathMax(minL,MathMin(maxL,lot));
}

//=======================================================================
//  FILTERS
//=======================================================================
bool PassesSessionFilter() {
   if(SessionMode==SESSION_OFF) return true;
   MqlDateTime t; TimeGMT(t); int h=t.hour;
   switch(SessionMode){
      case SESSION_LONDON:    return (h>=London_Start&&h<London_End);
      case SESSION_NY:        return (h>=NY_Start&&h<NY_End);
      case SESSION_LONDON_NY: return (h>=London_Start&&h<London_End)||(h>=NY_Start&&h<NY_End);
      case SESSION_KILLZONE:  return (h>=LondonKZ_Start&&h<LondonKZ_End)||(h>=NYKZ_Start&&h<NYKZ_End);
      default: return true;
   }
}

bool PassesHTFFilter(bool isBull) {
   if(!HTF_Filter||h_HTF_EMA==INVALID_HANDLE) return true;
   double ema[1];
   if(CopyBuffer(h_HTF_EMA,0,0,1,ema)<1) return true;
   return isBull?(iClose(_Symbol,_Period,1)>ema[0]):(iClose(_Symbol,_Period,1)<ema[0]);
}

bool PassesPDFilter(bool isBull) {
   if(!PD_Filter) return true;
   int hi=iHighest(_Symbol,_Period,MODE_HIGH,PD_Lookback,1);
   int lo=iLowest (_Symbol,_Period,MODE_LOW, PD_Lookback,1);
   if(hi<0||lo<0) return true;
   double rangeH=iHigh(_Symbol,_Period,hi), rangeL=iLow(_Symbol,_Period,lo);
   double range=rangeH-rangeL;
   if(range<=0) return true;
   double price=iClose(_Symbol,_Period,1);
   return isBull?(price<rangeL+range*PD_ZonePct/100.0):(price>rangeH-range*PD_ZonePct/100.0);
}

bool PassesATRFilter() {
   if(!ATR_Filter||h_ATR==INVALID_HANDLE) return true;
   double atr[1];
   if(CopyBuffer(h_ATR,0,1,1,atr)<1) return true;
   double atrPips=PriceInPips(atr[0]);
   if(atrPips<ATR_MinPips){ Print("Gate Hunter | ATR filter: too quiet (",DoubleToString(atrPips,1),"pip)"); return false; }
   if(atrPips>ATR_MaxPips){ Print("Gate Hunter | ATR filter: spike (",DoubleToString(atrPips,1),"pip)"); return false; }
   return true;
}

bool PassesAllFilters(bool isBull) {
   if(!PassesSessionFilter()){ Print("Gate Hunter | REJECT: session"); return false; }
   if(!PassesHTFFilter(isBull)){ Print("Gate Hunter | REJECT: HTF EMA"); return false; }
   if(!PassesPDFilter(isBull)){ Print("Gate Hunter | REJECT: P/D zone"); return false; }
   if(!PassesATRFilter()){ Print("Gate Hunter | REJECT: ATR"); return false; }
   return true;
}

//=======================================================================
//  POOL HELPERS
//=======================================================================
void AddPool(double price, bool isHigh, ENUM_POOL_TYPE type, datetime barTime) {
   int poolMax=ArraySize(g_Pools)-1;
   // No duplicates (same type + direction + approx price)
   for(int i=0;i<g_PoolCount;i++){
      if(g_Pools[i].type==type && g_Pools[i].isHigh==isHigh
         && MathAbs(g_Pools[i].price-price)<PipsToPrice(1.0)) return;
   }
   if(g_PoolCount>=poolMax){
      // Drop oldest non-premium pool first; if none, drop oldest
      int dropIdx=0;
      for(int i=0;i<g_PoolCount;i++) if(g_Pools[i].type==POOL_SWING&&!g_Pools[i].swept){dropIdx=i;break;}
      for(int i=dropIdx;i<g_PoolCount-1;i++) g_Pools[i]=g_Pools[i+1];
      g_PoolCount--;
   }
   LiquidityPool p; p.price=price; p.isHigh=isHigh; p.type=type;
   p.barTime=barTime; p.swept=false;
   g_Pools[g_PoolCount++]=p;
}

//=======================================================================
//  ASIAN RANGE TRACKING
//  Asian session 00:00–08:00 GMT builds a consolidation range.
//  London open (08:00) frequently sweeps the Asian high OR low.
//  These sweeps = highest probability institutional gate hunts.
//=======================================================================
void UpdateAsianRange() {
   MqlDateTime t; TimeGMT(t);
   datetime today=iTime(_Symbol,PERIOD_D1,0);

   // B16 FIX: reset keyed off true GMT calendar date, not broker D1 rollover.
   // Broker D1 rolls over at broker midnight (e.g. GMT-4 broker = 04:00 GMT).
   // That fires mid-Asian-session, wiping 4h of accumulated H/L — range truncated.
   // GMT day key (yyyymmdd from TimeGMT) always resets at 00:00 GMT exactly.
   int gmtDayKey=t.year*10000+t.mon*100+t.day;
   if(gmtDayKey!=g_AsianGmtDayKey){
      g_AsianGmtDayKey = gmtDayKey;
      g_AsianDate  = today;
      g_AsianH     = 0.0;
      g_AsianL     = DBL_MAX;
      g_AsianSeeded= false;
   }

   if(t.hour>=0 && t.hour<8 && UseAsianRange){
      double bH=iHigh(_Symbol,_Period,1), bL=iLow(_Symbol,_Period,1);
      if(bH>g_AsianH) g_AsianH=bH;
      if(bL<g_AsianL) g_AsianL=bL;
   }

   // At London open (>=08:00 GMT) add Asian H/L as premium pools
   // B13 FIX: was t.hour==8 — on H2/H3/H4 charts no bar opens at exactly
   // 08:00 GMT so the window was silently skipped for the whole day.
   // g_AsianSeeded flag already prevents any double-seeding on >= check.
   if(UseAsianRange && !g_AsianSeeded && t.hour>=8
      && g_AsianH>0 && g_AsianL<DBL_MAX){
      AddPool(g_AsianH, true,  POOL_ASIAN, today);
      AddPool(g_AsianL, false, POOL_ASIAN, today);
      g_AsianSeeded=true;
      Print("Gate Hunter | ASIAN pools seeded  H=",DoubleToString(g_AsianH,_Digits),
            " L=",DoubleToString(g_AsianL,_Digits));
   }
}

//=======================================================================
//  PREVIOUS DAY HIGH / LOW
//=======================================================================
void UpdatePrevDayHL() {
   if(!UsePrevDayHL) return;
   datetime today=iTime(_Symbol,PERIOD_D1,0);
   if(today==g_PrevDayDate) return;
   g_PrevDayDate=today;
   // Yesterday's D1 bar = shift=1 on D1
   double newH=iHigh(_Symbol,PERIOD_D1,1);
   double newL=iLow (_Symbol,PERIOD_D1,1);
   if(newH>0 && newL>0 && newH>newL){
      g_PrevDayH=newH; g_PrevDayL=newL;
      AddPool(g_PrevDayH, true,  POOL_PDH_PDL, today);
      AddPool(g_PrevDayL, false, POOL_PDH_PDL, today);
      Print("Gate Hunter | PDH/PDL pools seeded  H=",DoubleToString(g_PrevDayH,_Digits),
            " L=",DoubleToString(g_PrevDayL,_Digits));
   }
}

//=======================================================================
//  SETUP QUALITY SCORE
//  Rates the setup on a 0–5 scale. Higher = institutional alignment.
//  B12 FIX: max was 9 but HTF/PD/Session bonuses were guaranteed-true after Gate1.
//=======================================================================
int CalcQuality(int poolIdx, bool isBull) {
   int q=0;
   // Pool type bonus (1–3)
   switch(g_Pools[poolIdx].type){
      case POOL_ASIAN:   q+=3; break;
      case POOL_PDH_PDL: q+=3; break;
      default:           q+=1; break;
   }
   // B12 FIX: HTF/PD/Session bonuses removed.
   // Gate1 (PassesAllFilters) already hard-rejects if those are enabled+failing.
   // Re-awarding them here double-counted guaranteed-true conditions and made
   // MinQualityScore values 1-4 functionally dead when filters were enabled.
   // OB or FVG available (+1 each) — max score now 5
   OrderBlock ob=FindOrderBlock(isBull,1);
   FVG        fvg=FindFVG(isBull,1);
   if(ob.valid)  q+=1;
   if(fvg.valid) q+=1;
   return q; // max = 5 (premium pool + OB + FVG)
}

//=======================================================================
//  SWING DETECTION  (B01 FIX: s=v_SwingLookback+1, never touches shift=0)
//=======================================================================
void DetectNewSwing() {
   int s=v_SwingLookback+1;
   if(iBars(_Symbol,_Period)<s+v_SwingLookback+2) return;
   double cH=iHigh(_Symbol,_Period,s), cL=iLow(_Symbol,_Period,s);
   bool isH=true, isL=true;
   for(int k=1;k<=v_SwingLookback;k++){
      if(iHigh(_Symbol,_Period,s-k)>=cH||iHigh(_Symbol,_Period,s+k)>=cH) isH=false;
      if(iLow (_Symbol,_Period,s-k)<=cL||iLow (_Symbol,_Period,s+k)<=cL) isL=false;
   }
   if(!isH&&!isL) return;
   datetime ct=iTime(_Symbol,_Period,s);
   for(int i=0;i<g_PoolCount;i++) if(g_Pools[i].barTime==ct&&g_Pools[i].type==POOL_SWING) return;
   // B08 FIX: guard each addition independently
   if(isH) AddPool(iHigh(_Symbol,_Period,s), true,  POOL_SWING, ct);
   if(isL) AddPool(iLow (_Symbol,_Period,s), false, POOL_SWING, ct);
}

void AgePools() {
   int out=0;
   for(int i=0;i<g_PoolCount;i++){
      // Premium pools (Asian / PDH-PDL) last only one trading day
      if(g_Pools[i].type!=POOL_SWING){
         datetime poolDay=iTime(_Symbol,PERIOD_D1,0);
         if(g_Pools[i].barTime==poolDay){ g_Pools[out++]=g_Pools[i]; continue; }
         // expired — drop
         continue;
      }
      int age=iBarShift(_Symbol,_Period,g_Pools[i].barTime,false);
      if(age>=0&&age<=MaxPoolAge) g_Pools[out++]=g_Pools[i];
   }
   g_PoolCount=out;
}

//=======================================================================
//  SWEEP DETECTION  (B09 FIX: does NOT mark swept here)
//=======================================================================
bool CheckSweep(int &outIdx) {
   double barH=iHigh(_Symbol,_Period,1), barL=iLow(_Symbol,_Period,1);
   double barC=iClose(_Symbol,_Period,1);
   double minE=PipsToPrice(SweepMinPips), maxE=PipsToPrice(SweepMaxPips);
   // Scan premium pools first (Asian, PDH/PDL), then swing pools
   for(int pass=0;pass<=1;pass++){
      for(int i=g_PoolCount-1;i>=0;i--){
         if(g_Pools[i].swept) continue;
         bool isPremium=(g_Pools[i].type!=POOL_SWING);
         if(pass==0&&!isPremium) continue;
         if(pass==1&&isPremium)  continue;
         double pool=g_Pools[i].price;
         if(g_Pools[i].isHigh){
            double ext=barH-pool;
            if(ext>=minE&&ext<=maxE&&barC<pool){ outIdx=i; return true; }
         } else {
            double ext=pool-barL;
            if(ext>=minE&&ext<=maxE&&barC>pool){ outIdx=i; return true; }
         }
      }
   }
   return false;
}

//=======================================================================
//  ORDER BLOCK FINDER
//=======================================================================
OrderBlock FindOrderBlock(bool isBull,int sweepShift) {
   OrderBlock ob; ob.valid=false; ob.high=0; ob.low=0; ob.mid=0; ob.barTime=0; ob.isBull=isBull;
   int limit=MathMin(sweepShift+OB_LookbackBars,iBars(_Symbol,_Period)-1);
   for(int s=sweepShift+1;s<=limit;s++){
      double o=iOpen(_Symbol,_Period,s),c=iClose(_Symbol,_Period,s);
      if((isBull&&c<o)||(!isBull&&c>o)){
         ob.high=iHigh(_Symbol,_Period,s); ob.low=iLow(_Symbol,_Period,s);
         ob.mid=(ob.high+ob.low)/2.0; ob.barTime=iTime(_Symbol,_Period,s);
         ob.isBull=isBull; ob.valid=true; break;
      }
   }
   return ob;
}

//=======================================================================
//  FVG FINDER  (B02 FIX: loop starts sweepShift+1, never reads shift=0)
//=======================================================================
FVG FindFVG(bool isBull,int sweepShift) {
   FVG f; f.valid=false; f.top=0; f.bottom=0; f.mid=0; f.barTime=0; f.isBull=isBull;
   int startS=sweepShift+1;
   int limit=MathMin(startS+OB_LookbackBars,iBars(_Symbol,_Period)-2);
   for(int s=startS;s<=limit;s++){
      if(isBull){
         double lH=iHigh(_Symbol,_Period,s+1), rL=iLow(_Symbol,_Period,s-1);
         if(rL>lH){ f.bottom=lH; f.top=rL; f.mid=(f.top+f.bottom)/2.0; f.barTime=iTime(_Symbol,_Period,s); f.isBull=true; f.valid=true; break; }
      } else {
         double lL=iLow(_Symbol,_Period,s+1), rH=iHigh(_Symbol,_Period,s-1);
         if(rH<lL){ f.top=lL; f.bottom=rH; f.mid=(f.top+f.bottom)/2.0; f.barTime=iTime(_Symbol,_Period,s); f.isBull=false; f.valid=true; break; }
      }
   }
   return f;
}

//=======================================================================
//  CHOCH STRUCTURE LEVEL
//=======================================================================
double FindCHoCHLevel(bool isBull,int sweepShift) {
   int startS=sweepShift+1;
   int limit=MathMin(sweepShift+v_CHoCH_Lookback,iBars(_Symbol,_Period)-1);
   if(startS>limit) return 0.0;
   if(isBull){
      double hh=iHigh(_Symbol,_Period,startS);
      for(int s=startS+1;s<=limit;s++) hh=MathMax(hh,iHigh(_Symbol,_Period,s));
      return hh;
   } else {
      double ll=iLow(_Symbol,_Period,startS);
      for(int s=startS+1;s<=limit;s++) ll=MathMin(ll,iLow(_Symbol,_Period,s));
      return ll;
   }
}

//=======================================================================
//  DISPLACEMENT CHECK
//=======================================================================
bool IsImpulsive(int shift) {
   if(!RequireDisplacement) return true;
   double o=iOpen(_Symbol,_Period,shift),c=iClose(_Symbol,_Period,shift);
   double h=iHigh(_Symbol,_Period,shift),l=iLow(_Symbol,_Period,shift);
   double range=h-l;
   return (range>0)&&(MathAbs(c-o)/range>=DispBodyRatio);
}

//=======================================================================
//  LIMIT ORDER PLACEMENT
//  B03 FIX: stoplimit = 0.0
//  B07 FIX: SL direction validated
//  B-LIMIT FIX: buy limit compared against ask; sell limit against bid
//=======================================================================
bool PlaceLimitOrder(bool isBull,double limitEP,double sl,string comment) {
   if( isBull&&sl>=limitEP){ Print("Gate Hunter | LIMIT skip: SL not below entry"); return false; }
   if(!isBull&&sl<=limitEP){ Print("Gate Hunter | LIMIT skip: SL not above entry"); return false; }
   double risk=MathAbs(limitEP-sl);
   if(risk<PipsToPrice(1.0)){ Print("Gate Hunter | LIMIT skip: risk < 1 pip"); return false; }
   limitEP=NormalizeDouble(limitEP,_Digits); sl=NormalizeDouble(sl,_Digits);
   double tp=NormalizeDouble(isBull?(limitEP+risk*TP_RR):(limitEP-risk*TP_RR),_Digits);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   // B-LIMIT FIX: buy limit must be below ask; sell limit must be above bid
   if( isBull&&limitEP>=ask){ Print("Gate Hunter | LIMIT skip: buy limit >= ask"); return false; }
   if(!isBull&&limitEP<=bid){ Print("Gate Hunter | LIMIT skip: sell limit <= bid"); return false; }
   double lot=CalcLot(limitEP,sl);
   g_Trade.SetExpertMagicNumber(YSM_MAGIC);
   g_Trade.SetTypeFillingBySymbol(_Symbol);
   ENUM_ORDER_TYPE ot=isBull?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT;
   if(g_Trade.OrderOpen(_Symbol,ot,lot,limitEP,0.0,sl,tp,ORDER_TIME_GTC,0,comment)){
      g_Setup.pendingTicket=g_Trade.ResultOrder();
      Print("Gate Hunter | LIMIT @ ",DoubleToString(limitEP,_Digits),
            " SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits)," lot=",DoubleToString(lot,2));
      return true;
   }
   Print("Gate Hunter | LIMIT FAILED: ",g_Trade.ResultRetcodeDescription());
   return false;
}

//=======================================================================
//  SETUP BUILDER
//  B09 FIX: pool marked swept ONLY here after all gates pass.
//  NEW: quality gate, max SL cap.
//=======================================================================
bool BuildSetup(int poolIdx) {
   bool isBull=!g_Pools[poolIdx].isHigh;

   // Gate 1 — confluence filters
   if(!PassesAllFilters(isBull)) return false;

   // Gate 2 — quality score
   int quality=CalcQuality(poolIdx,isBull);
   if(MinQualityScore>0 && quality<MinQualityScore){
      Print("Gate Hunter | REJECT quality=",quality," < min=",MinQualityScore,
            " pool=",EnumToString(g_Pools[poolIdx].type));
      return false;
   }

   double sweepH=iHigh(_Symbol,_Period,1), sweepL=iLow(_Symbol,_Period,1);
   double extreme=isBull?sweepL:sweepH;
   double sl=NormalizeDouble(isBull?(extreme-PipsToPrice(SL_BufferPips))
                                   :(extreme+PipsToPrice(SL_BufferPips)),_Digits);

   // Gate 3 — max SL distance cap (protects against over-extended sweeps)
   if(MaxSL_Pips>0){
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double approxEntry=isBull?ask:bid;
      double slPips=PriceInPips(MathAbs(approxEntry-sl));
      if(slPips>MaxSL_Pips){
         Print("Gate Hunter | REJECT SL=",DoubleToString(slPips,1)," pip > max=",MaxSL_Pips);
         return false;
      }
   }

   double choch=FindCHoCHLevel(isBull,1);
   if(choch<=0){ Print("Gate Hunter | Setup abort: CHoCH level invalid"); return false; }

   // All gates passed — mark pool swept now (B09 FIX)
   g_Pools[poolIdx].swept=true;

   g_Setup.active          = true;
   g_Setup.isBull          = isBull;
   g_Setup.sweepExtreme    = extreme;
   g_Setup.slPrice         = sl;
   g_Setup.chochLevel      = choch;
   g_Setup.ob              = FindOrderBlock(isBull,1);
   g_Setup.fvg             = FindFVG(isBull,1);
   g_Setup.pendingTicket   = 0;
   g_Setup.barsSinceSweep  = 0;
   g_Setup.limitModeFallback = false;
   g_Setup.poolIdx         = poolIdx;
   g_Setup.qualityScore    = quality;

   Print("Gate Hunter | ▶ SETUP  bull=",isBull,
         " quality=",quality,"/5",
         " pool=",EnumToString(g_Pools[poolIdx].type),
         " SL=",DoubleToString(sl,_Digits),
         " CHoCH=",DoubleToString(choch,_Digits),
         " OB=",g_Setup.ob.valid," FVG=",g_Setup.fvg.valid);

   // Place limit if OB/FVG mode
   if(EntryMode!=ENTRY_CHOCH){
      bool placed=false;
      if(!placed&&(EntryMode==ENTRY_OB||EntryMode==ENTRY_OB_FVG)&&g_Setup.ob.valid)
         placed=PlaceLimitOrder(isBull,g_Setup.ob.mid,sl,"OB|"+YSM_SIGN);
      if(!placed&&(EntryMode==ENTRY_FVG||EntryMode==ENTRY_OB_FVG)&&g_Setup.fvg.valid)
         placed=PlaceLimitOrder(isBull,g_Setup.fvg.mid,sl,"FVG|"+YSM_SIGN);
      if(!placed){
         Print("Gate Hunter | No OB/FVG limit placed → CHoCH fallback (B06 fix)");
         g_Setup.limitModeFallback=true;
      }
   }
   return true;
}

//=======================================================================
//  CHOCH MARKET ENTRY
//=======================================================================
bool TryChochEntry() {
   double prevC=iClose(_Symbol,_Period,1);
   bool   bull =g_Setup.isBull;
   if(bull?(prevC<=g_Setup.chochLevel):(prevC>=g_Setup.chochLevel)) return false;
   if(!IsImpulsive(1)){  Print("Gate Hunter | CHoCH: not impulsive"); return false; }
   if(SpreadPips()>MaxSpreadPips){ Print("Gate Hunter | CHoCH: spread too wide"); return false; }

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=bull?ask:bid, sl=g_Setup.slPrice;
   double risk=MathAbs(entry-sl);
   if(risk<PipsToPrice(0.5)){ Print("Gate Hunter | CHoCH: risk < 0.5 pip"); return false; }
   if( bull&&sl>=entry){ Print("Gate Hunter | CHoCH: SL sanity fail (bull)"); return false; }
   if(!bull&&sl<=entry){ Print("Gate Hunter | CHoCH: SL sanity fail (bear)"); return false; }

   sl=NormalizeDouble(sl,_Digits);
   double tp=NormalizeDouble(bull?(entry+risk*TP_RR):(entry-risk*TP_RR),_Digits);
   double lot=CalcLot(entry,sl);

   g_Trade.SetExpertMagicNumber(YSM_MAGIC);
   g_Trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=bull?g_Trade.Buy(lot,_Symbol,ask,sl,tp,YSM_SIGN)
               :g_Trade.Sell(lot,_Symbol,bid,sl,tp,YSM_SIGN);
   if(ok){
      ulong ticket=g_Trade.ResultOrder();
      AddManaged(ticket,entry,sl,tp,bull);
      Print("Gate Hunter | ▶ CHOCH ENTRY  ticket=",ticket," bull=",bull,
            " lot=",DoubleToString(lot,2)," SL=",DoubleToString(sl,_Digits),
            " TP=",DoubleToString(tp,_Digits)," quality=",g_Setup.qualityScore);
      return true;
   }
   Print("Gate Hunter | CHoCH FAILED: ",g_Trade.ResultRetcodeDescription());
   return false;
}

//=======================================================================
//  SETUP INVALIDATION
//=======================================================================
bool SetupInvalidated() {
   double c=iClose(_Symbol,_Period,1);
   return g_Setup.isBull?(c<g_Setup.sweepExtreme):(c>g_Setup.sweepExtreme);
}

//=======================================================================
//  POSITION MANAGEMENT — Break-Even, Partial Close, Trailing Stop
//=======================================================================
void ManagePositions() {
   for(int i=g_ManagedCount-1;i>=0;i--){
      ManagedPos &mp=g_Managed[i];
      if(!PositionSelectByTicket(mp.ticket)){ RemoveManagedAt(i); continue; }

      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double cur=mp.isBull?bid:ask;
      double risk=MathAbs(mp.entryPrice-mp.slPrice);
      if(risk<=0) continue;
      double R=(cur-mp.entryPrice)/risk*(mp.isBull?1.0:-1.0);

      // 1 — Partial close at Partial_R
      if(Partial_R>0&&!mp.partialDone&&R>=Partial_R){
         double vol=PositionGetDouble(POSITION_VOLUME);
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double cVol=MathMax(minL,MathFloor(vol*0.5/step)*step);
         if(cVol<vol&&g_Trade.PositionClosePartial(mp.ticket,cVol)){
            mp.partialDone=true;
            Print("Gate Hunter | PARTIAL  ticket=",mp.ticket," vol=",DoubleToString(cVol,2)," R=",DoubleToString(R,2));
         }
      }

      // 2 — Break-even at BE_R
      if(BE_R>0&&!mp.beApplied&&R>=BE_R){
         double newSL=NormalizeDouble(mp.entryPrice+(mp.isBull?1:-1)*PipsToPrice(0.5),_Digits);
         double curSL=PositionGetDouble(POSITION_SL);
         bool better=mp.isBull?(newSL>curSL):(newSL<curSL);
         if(better&&g_Trade.PositionModify(mp.ticket,newSL,PositionGetDouble(POSITION_TP))){
            mp.beApplied=true;
            Print("Gate Hunter | BE  ticket=",mp.ticket," SL→",DoubleToString(newSL,_Digits));
         }
      }

      // 3 — Trailing stop at Trail_R (pip-based trail from current price)
      if(Trail_R>0&&R>=Trail_R){
         double trailSL;
         if(mp.isBull) trailSL=NormalizeDouble(bid-PipsToPrice(Trail_Pips),_Digits);
         else          trailSL=NormalizeDouble(ask+PipsToPrice(Trail_Pips),_Digits);
         double curSL=PositionGetDouble(POSITION_SL);
         bool betterT=mp.isBull?(trailSL>curSL):(trailSL<curSL);
         if(betterT&&g_Trade.PositionModify(mp.ticket,trailSL,PositionGetDouble(POSITION_TP))){
            if(!mp.trailActive){
               mp.trailActive=true;
               Print("Gate Hunter | TRAIL activated  ticket=",mp.ticket," trail=",DoubleToString(Trail_Pips,1),"pip");
            }
         }
      }
   }
}

//=======================================================================
//  DAILY CAP
//=======================================================================
bool IsDayBlocked() {
   double pnl=AccountInfoDouble(ACCOUNT_EQUITY)-g_DayStartBalance;
   return (pnl<=-MaxDailyLossUSD||pnl>=MaxDailyProfitUSD);
}

//=======================================================================
//  HUD
//=======================================================================
void UpdateHUD(const string status) {
   double pnl=AccountInfoDouble(ACCOUNT_EQUITY)-g_DayStartBalance;
   double atrPips=0;
   if(h_ATR!=INVALID_HANDLE){ double a[1]; if(CopyBuffer(h_ATR,0,1,1,a)>0) atrPips=PriceInPips(a[0]); }

   string poolStr="";
   int sw=0,as=0,pd=0;
   for(int i=0;i<g_PoolCount;i++){
      if(g_Pools[i].swept) continue;
      switch(g_Pools[i].type){ case POOL_SWING:sw++; break; case POOL_ASIAN:as++; break; case POOL_PDH_PDL:pd++; break; }
   }
   poolStr=StringFormat("Pools: Swing=%d  Asian=%d  PDH/PDL=%d",sw,as,pd);

   string dir="", chStr="";
   if(g_Setup.active){
      dir  =g_Setup.isBull?"BULL (expecting UP)":"BEAR (expecting DOWN)";
      chStr=StringFormat("CHoCH gate: %s   Quality: %d/5",
            DoubleToString(g_Setup.chochLevel,_Digits),g_Setup.qualityScore)
           +(g_Setup.limitModeFallback?" [CHoCH fallback]":"");
   }

   bool sesOk=PassesSessionFilter(), htfOk=true, pdOk=true, atrOk=PassesATRFilter();
   if(g_Setup.active){ htfOk=PassesHTFFilter(g_Setup.isBull); pdOk=PassesPDFilter(g_Setup.isBull); }

   string aR="";
   if(UseAsianRange&&g_AsianH>0&&g_AsianL<DBL_MAX)
      aR=StringFormat("Asian: H=%s L=%s",DoubleToString(g_AsianH,_Digits),DoubleToString(g_AsianL,_Digits));

   Comment(StringFormat(
      "%s  |  %s\n"
      "══════════════════════════════\n"
      " Status      : %s\n"
      " Direction   : %s\n"
      " %s\n"
      "──────────────────────────────\n"
      " Filters : Ses:%s HTF:%s PD:%s ATR:%s\n"
      " ATR     : %.1f pip\n"
      " Spread  : %.2f pip\n"
      " %s\n"
      " %s\n"
      " OB:%s  FVG:%s  Bars/sweep:%d/%d\n"
      "──────────────────────────────\n"
      " Open trades : %d / %d\n"
      " Daily P&L   : %+.2f USD\n"
      " Cap         : -$%.0f / +$%.0f",
      YSM_SIGN, YSM_OWNER,
      status, dir, chStr,
      sesOk?"OK":"X", htfOk?"OK":"X", pdOk?"OK":"X", atrOk?"OK":"X",
      atrPips, SpreadPips(),
      poolStr, aR,
      (g_Setup.active&&g_Setup.ob.valid)?"YES":"NO",
      (g_Setup.active&&g_Setup.fvg.valid)?"YES":"NO",
      g_Setup.active?g_Setup.barsSinceSweep:0, OB_FVG_ExpiryBars,
      CountPositions(), MaxPositions,
      pnl, MaxDailyLossUSD, MaxDailyProfitUSD));
}

//=======================================================================
//  CORE BAR LOGIC
//=======================================================================
void OnBar() {
   datetime today=iTime(_Symbol,PERIOD_D1,0);
   if(today!=g_DayStartTime){
      g_DayStartTime   =today;
      g_DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   }
   if(IsDayBlocked()){ UpdateHUD("DAY BLOCKED"); return; }

   UpdateAsianRange();
   UpdatePrevDayHL();
   SyncManagedPositions();
   AgePools();
   DetectNewSwing();
   // NOTE: ManagePositions() is intentionally omitted here.
   // It is called on every tick in OnTick() for tighter intra-bar management.

   if(g_Setup.active){
      g_Setup.barsSinceSweep++;

      if(SetupInvalidated()){
         Print("Gate Hunter | SETUP INVALIDATED");
         if(g_Setup.pendingTicket>0) g_Trade.OrderDelete(g_Setup.pendingTicket);
         g_Setup.active=false; UpdateHUD("INVALIDATED"); return;
      }
      if(g_Setup.barsSinceSweep>OB_FVG_ExpiryBars){
         if(g_Setup.pendingTicket>0){
            g_Trade.OrderDelete(g_Setup.pendingTicket);
            Print("Gate Hunter | LIMIT EXPIRED");
         }
         g_Setup.active=false; UpdateHUD("scanning"); return;
      }
      if(g_Setup.pendingTicket>0){
         if(!OrderSelect(g_Setup.pendingTicket)){
            // B04+B05 FIX: limit filled → sync and show FILLED
            g_Setup.pendingTicket=0; g_Setup.active=false;
            SyncManagedPositions(); UpdateHUD("FILLED"); return;
         }
         UpdateHUD("LIMIT LIVE"); return;
      }
      // B06 FIX: CHoCH fires for CHOCH mode OR when OB/FVG had no valid level
      bool tryChoch=(EntryMode==ENTRY_CHOCH)||(g_Setup.limitModeFallback);
      if(tryChoch&&CountPositions()<MaxPositions){
         if(TryChochEntry()){ g_Setup.active=false; UpdateHUD("ENTERED"); return; }
      }
      UpdateHUD("SETUP ACTIVE");
   } else {
      if(CountPositions()<MaxPositions){
         int idx=-1;
         if(CheckSweep(idx)) BuildSetup(idx);
      }
      UpdateHUD("scanning");
   }
}

//=======================================================================
//  TICK
//=======================================================================
void OnTick() {
   datetime bt=iTime(_Symbol,_Period,0);
   if(bt!=g_LastBarTime){ g_LastBarTime=bt; OnBar(); }
   ManagePositions();
}

//=======================================================================
//  INIT
//=======================================================================
int OnInit() {
   // B10 FIX: clamp inputs
   v_SwingLookback =(int)MathMax(1,SwingLookback);
   v_CHoCH_Lookback=(int)MathMax(2,CHoCH_Lookback);

   g_Trade.SetExpertMagicNumber(YSM_MAGIC);
   g_Trade.SetTypeFillingBySymbol(_Symbol);

   // B15 FIX: clamp MaxPools — unguarded 0/negative input caused
   // ArraySize(g_Pools)-1 = -1 in AddPool() → negative index write → crash.
   int v_MaxPools=(int)MathMax(5,MaxPools);
   ArrayResize(g_Pools,v_MaxPools*2);
   g_PoolCount=0; g_ManagedCount=0;
   ZeroMemory(g_Setup);
   g_Setup.active=false;
   g_LastBarTime=0;
   g_AsianDate=0; g_AsianH=0; g_AsianL=DBL_MAX; g_AsianSeeded=false;
   g_PrevDayDate=0; g_PrevDayH=0; g_PrevDayL=0;
   g_DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayStartTime=iTime(_Symbol,PERIOD_D1,0);

   if(HTF_Filter){
      h_HTF_EMA=iMA(_Symbol,HTF_Period,HTF_EMA_Period,0,MODE_EMA,PRICE_CLOSE);
      if(h_HTF_EMA==INVALID_HANDLE) Print("WARNING: HTF EMA handle failed");
   }
   if(ATR_Filter){
      h_ATR=iATR(_Symbol,_Period,ATR_Period);
      if(h_ATR==INVALID_HANDLE) Print("WARNING: ATR handle failed");
   }

   Print("══ YSM HUNT THE HUNTERS v6.03 ══  Architect: ",YSM_OWNER);
   Print("Entry:",EnumToString(EntryMode),
         " Sess:",EnumToString(SessionMode),
         " HTF:",HTF_Filter?"ON":"OFF",
         " PD:",PD_Filter?"ON":"OFF",
         " ATR:",ATR_Filter?"ON":"OFF",
         " MinQ:",MinQualityScore,
         " MaxSL:",DoubleToString(MaxSL_Pips,0),"pip",
         " Trail:",Trail_R>0?"ON":"OFF");

   // Seed historical SWING pools (B01 FIX: seedStart=v_SwingLookback+1)
   int totalBars=iBars(_Symbol,_Period);
   int seedStart=v_SwingLookback+1;
   int seedEnd  =MathMin(totalBars-v_SwingLookback-2, MaxPoolAge+v_SwingLookback+1);
   for(int s=seedStart; s<=seedEnd && g_PoolCount<ArraySize(g_Pools)-2; s++){
      double cH=iHigh(_Symbol,_Period,s), cL=iLow(_Symbol,_Period,s);
      bool isH=true, isL=true;
      for(int k=1;k<=v_SwingLookback;k++){
         if(iHigh(_Symbol,_Period,s-k)>=cH||iHigh(_Symbol,_Period,s+k)>=cH) isH=false;
         if(iLow (_Symbol,_Period,s-k)<=cL||iLow (_Symbol,_Period,s+k)<=cL) isL=false;
      }
      datetime t=iTime(_Symbol,_Period,s);
      if(isH) AddPool(cH,true, POOL_SWING,t);
      if(isL) AddPool(cL,false,POOL_SWING,t);
   }

   // Seed PDH/PDL from yesterday
   UpdatePrevDayHL();

   // Seed Asian range if already past 08:00 GMT today
   // BUG-B FIX: convert each H1 bar's broker time to GMT before checking session hour.
   // Previous code called TimeGMT() once for current time (not per-bar) — all today's
   // bars were included, making the Asian range cover London+NY too (far too wide).
   MqlDateTime now; TimeGMT(now);
   // B17 FIX: stamp GMT day-key here unconditionally so the first OnBar()
   // call to UpdateAsianRange() sees a matching key and does NOT fire the
   // B16 reset block — which would wipe whatever this init block seeds below.
   // Without this, any restart after 08:00 GMT silently loses Asian pools
   // for the rest of the day (accumulation window already passed, re-seed fails).
   g_AsianGmtDayKey = now.year*10000+now.mon*100+now.day;
   if(now.hour>=8 && UseAsianRange){
      datetime todayBase=iTime(_Symbol,PERIOD_D1,0);
      // GMT offset: broker server time vs true GMT
      datetime gmtOffset = TimeGMT()-TimeCurrent();
      double aH=0, aL=DBL_MAX;
      for(int s=0;s<50;s++){
         datetime barServerTime=iTime(_Symbol,PERIOD_H1,s);
         if(barServerTime==0) break;
         datetime barGMT=barServerTime+gmtOffset;
         if(barGMT<todayBase) break; // reached yesterday
         MqlDateTime bg; TimeToStruct(barGMT,bg);
         if(bg.hour>=8) continue;    // only Asian session (00:00–07:59 GMT)
         double bh=iHigh(_Symbol,PERIOD_H1,s), bl=iLow(_Symbol,PERIOD_H1,s);
         aH=MathMax(aH,bh); aL=MathMin(aL,bl);
      }
      if(aH>0&&aL<DBL_MAX&&!g_AsianSeeded){
         g_AsianH=aH; g_AsianL=aL;
         AddPool(g_AsianH,true, POOL_ASIAN,todayBase);
         AddPool(g_AsianL,false,POOL_ASIAN,todayBase);
         g_AsianSeeded=true; g_AsianDate=todayBase;
         Print("Gate Hunter | Asian range seeded at init  H=",DoubleToString(g_AsianH,_Digits),
               " L=",DoubleToString(g_AsianL,_Digits)," (GMT offset=",gmtOffset,"s)");
      }
   }

   Print("Gate Hunter | Pools seeded: ",g_PoolCount," (swing+premium)");
   SyncManagedPositions();
   return INIT_SUCCEEDED;
}

//=======================================================================
//  DEINIT
//=======================================================================
void OnDeinit(const int reason) {
   if(g_Setup.active&&g_Setup.pendingTicket>0)
      g_Trade.OrderDelete(g_Setup.pendingTicket);
   if(h_HTF_EMA!=INVALID_HANDLE) IndicatorRelease(h_HTF_EMA);
   if(h_ATR!=INVALID_HANDLE)     IndicatorRelease(h_ATR);
   Comment("");
}
