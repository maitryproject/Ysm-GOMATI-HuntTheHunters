YSM-GOMATI — Hunt The Hunters
Institutional-Grade Governance Engine for Liquidity Pool Hunting Architect: Yogeshwar Singh Maitry

What This Is
YSM-GOMATI is not a trading bot. It is a Quality Management system for trade execution.

Standard bots chase price. This system asks: who is already in the market, where did they place their stops, and how can we enter alongside them when they flush retail out?

Every trade signal undergoes a multi-gate validation process before any order touches the market. The engine scores each setup on a 0–9 confluence scale and only executes A+ setups that meet the minimum threshold.

Core Philosophy
Institutions accumulate and distribute positions at specific price levels called Liquidity Pools — clusters of retail stop orders sitting above swing highs and below swing lows. They push price through these levels (the sweep), fill their own orders, then reverse sharply.

YSM-GOMATI detects the sweep, confirms the reversal structure, and enters with the institutions — hunting the hunters.

Premium Liquidity Pools
Pool Type	Description	Quality Bonus
Asian High / Low	London open sweeps the Asian consolidation range daily — highest probability	+3
Previous Day High / Low	Major institutional reference levels	+3
Standard Swing High / Low	Regular retail stop clusters	+1
Setup Quality Scoring (0–9 Scale)
Each potential setup is rated before execution. Only setups meeting MinQualityScore are traded.

Factor	Points
Pool type bonus (Asian / PDH-PDL)	+3
Pool type bonus (Swing)	+1
HTF EMA aligned with trade direction	+2
Price in Premium / Discount zone	+1
Session killzone timing	+1
Order Block available	+1
Fair Value Gap available	+1
Maximum possible	9
Default minimum: 3/9 — configurable via MinQualityScore.

Entry Modes
Mode	Description
ENTRY_CHOCH	Market order on Change of Character (CHoCH) break
ENTRY_OB	Limit at Order Block midpoint; CHoCH fallback if no OB
ENTRY_FVG	Limit at Fair Value Gap midpoint; CHoCH fallback if no FVG
ENTRY_OB_FVG	OB first, FVG second, CHoCH fallback
Confluence Filters (each independently togglable)
HTF EMA Trend — Higher timeframe trend alignment (default H4/EMA50)
Premium / Discount Zone — Price must be in an extreme of the recent range
Session / Killzone — London (08:00–10:00 GMT) and NY (13:00–15:00 GMT) killzones, or full session windows
ATR Volatility — Skips both ranging markets and news spikes
Max SL Distance Cap — Rejects over-extended sweeps with wide stops
Displacement Body Ratio — Requires impulsive CHoCH candles (body ≥ 50% of range)
Spread Cap — Skips during high-spread conditions
Trade Management
Risk sizing — Fixed lot or account risk % per trade
Break-even — Moves SL to entry + buffer at configurable R-multiple
Partial close — Closes 50% of position at configurable R-multiple
Trailing stop — Pip-based trail, activates at configurable R-multiple
Daily drawdown cap — Halts trading after max USD loss for the day
Daily profit cap — Locks in gains after max USD profit for the day
Max open positions — Hard limit on concurrent trades
Input Parameters Reference
Institutional Pools
Parameter	Default	Description
UseAsianRange	true	Track Asian H/L as premium pools
UsePrevDayHL	true	Track Previous Day H/L as premium pools
SwingLookback	5	Bars each side to confirm a swing
MaxPoolAge	100	Drop swing pools older than N bars
MaxPools	30	Maximum tracked pools
Sweep Filter
Parameter	Default	Description
SweepMinPips	1.0	Minimum sweep extension in pips
SweepMaxPips	30.0	Maximum sweep extension in pips
MaxSpreadPips	3.0	Skip entry if spread exceeds this
Setup Quality Gate
Parameter	Default	Description
MinQualityScore	3	Minimum score to allow entry (0 = off)
MaxSL_Pips	25.0	Skip if SL distance exceeds this (0 = off)
Entry
Parameter	Default	Description
EntryMode	ENTRY_CHOCH	Order type for entry
CHoCH_Lookback	20	Bars to search for CHoCH structure level
OB_LookbackBars	12	Bars to search for Order Block
OB_FVG_ExpiryBars	30	Cancel pending limit after N bars
Risk Management
Parameter	Default	Description
RiskMode	RISK_PERCENT	Fixed lot or percentage of balance
FixedLotSize	0.10	Lot size when using fixed mode
RiskPercent	1.0	Account % risked per trade
SL_BufferPips	2.0	Extra buffer added beyond sweep extreme
TP_RR	2.0	Take profit at this R-multiple
BE_R	1.0	Move to break-even at this R (0 = off)
Partial_R	1.0	Close 50% at this R (0 = off)
Trail_R	2.0	Activate trailing at this R (0 = off)
Trail_Pips	8.0	Trailing stop distance in pips
MaxPositions	2	Maximum concurrent open positions
MaxDailyLossUSD	150.0	Daily loss cap in USD
MaxDailyProfitUSD	400.0	Daily profit cap in USD
Technical Foundation
Engine Type: MQL5 Expert Advisor
Execution Model: Bar-close logic (OnBar) + every-tick position management (OnTick)
Library: Trade\Trade.mqh (CTrade)
Magic Number: 20261302
Zero Damage — Audit Fix Log
All 13 known defects resolved in version 6.00:

ID	Area	Description
B01	Swing detection	Seed loop starts at SwingLookback+1 — never touches live bar (shift=0)
B02	FVG finder	Loop starts at sweepShift+1 — never reads incomplete bar
B03	Limit order	stoplimit parameter correctly set to 0.0
B04	Limit fill	Filled limit orders auto-synced to managed list
B05	HUD	Status correctly shows "FILLED" after limit execution
B06	OB/FVG fallback	CHoCH entry fires when no OB/FVG level was placeable
B07	SL validation	SL direction validated before every order placement
B08	Pool capacity	High and low swing pools added independently, not coupled
B09	Pool swept-marking	Pool marked swept only after all gates pass, never prematurely
B10	Input clamping	SwingLookback and CHoCH_Lookback clamped to safe minimums
B11	Partial inference	On EA restart, partial-close state correctly inferred from position volume
BUG-A	Lot sizing	Guard against tickVal=0 / tickSize=0 broker data errors
BUG-B	Asian range seeding	Per-bar GMT conversion used during OnInit — prevents Asian range spanning London+NY session
B-LIMIT	Limit validation	Fixed bid/ask reference in PlaceLimitOrder — buy limits compared against ask, sell limits against bid
Requirements
MetaTrader 5 (build 3000+)
Any Forex pair or CFD
Recommended timeframes: M15, M30, H1
VPS with stable connection recommended for killzone-based trading
Installation
Copy YSM-Gomati_HuntTheHunters.mq5 to your MT5 Experts folder
Compile in MetaEditor (F7)
Attach to chart on your preferred timeframe
Set RiskPercent to match your account risk tolerance
Verify SessionMode matches your GMT offset setup
Enable AutoTrading in MT5
Architecture Overview
OnTick()
  │
  ├─ [new bar] ──► OnBar()
  │                  │
  │                  ├─ UpdateAsianRange()     ← build Asian H/L
  │                  ├─ UpdatePrevDayHL()      ← seed PDH/PDL pools
  │                  ├─ SyncManagedPositions() ← catch limit fills on restart
  │                  ├─ AgePools()             ← expire old pools
  │                  ├─ DetectNewSwing()       ← add new swing pools
  │                  │
  │                  ├─ [setup active] ──► CheckInvalidation
  │                  │                    CheckExpiry
  │                  │                    TryChochEntry (if CHoCH mode or fallback)
  │                  │
  │                  └─ [no setup] ──► CheckSweep → BuildSetup
  │                                      │
  │                                      ├─ PassesAllFilters  (session/HTF/PD/ATR)
  │                                      ├─ CalcQuality       (0–9 score gate)
  │                                      ├─ MaxSL cap check
  │                                      └─ PlaceLimitOrder / arm CHoCH fallback
  │
  └─ [every tick] ──► ManagePositions()
                         ├─ Partial close at Partial_R
                         ├─ Break-even at BE_R
                         └─ Trailing stop at Trail_R

Author
Yogeshwar Singh Maitry YSM-GOMATI Architecture — Version 6.00
