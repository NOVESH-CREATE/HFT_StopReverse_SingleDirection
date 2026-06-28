//+------------------------------------------------------------------+
//|                         HFT_StopReverse_SingleDirection.mq5       |
//|  Stop-and-reverse trailing stop-order EA for MT5                  |
//|                                                                  |
//|  Logic requested:                                                 |
//|  - Pending BUY STOP and SELL STOP trail in one direction only.    |
//|  - BUY STOP moves DOWN only. SELL STOP moves UP only.             |
//|  - When BUY is active:                                            |
//|       SELL STOP trails below market by ReverseDistance, UP only.  |
//|       BUY SL = SELL STOP - StopLossGap, UP only.                  |
//|  - When SELL is active:                                           |
//|       BUY STOP trails above market by ReverseDistance, DOWN only. |
//|       SELL SL = BUY STOP + StopLossGap, DOWN only.                |
//|  - If opposite stop triggers and both positions exist, EA keeps    |
//|    the newest position and closes the older one immediately.       |
//|                                                                  |
//|  Attach to XAUUSD M1 chart. Distances are PRICE units, not pips:  |
//|    0.60 means $0.60 on gold, 1.90 means $1.90 on gold.            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Single-direction stop-and-reverse trailing pending-order EA"

#include <Trade/Trade.mqh>

CTrade trade;

input double InpLots                 = 0.01;      // Lot size
input double InpReverseDistance      = 0.60;      // Pending stop distance from market price, in price units
input double InpStopLossGap          = 1.90;      // SL gap from opposite stop, in price units
input double InpMinModifyStep        = 0.01;      // Minimum price change before modifying orders/SL
input ulong  InpMagicNumber          = 190060;    // Magic number
input uint   InpDeviationPoints      = 50;        // Deviation/slippage in points
input bool   InpPlaceInitialBothStops= true;      // If no position, maintain both initial stops
input bool   InpCloseOlderOnReverse  = true;      // If both directions exist, close older position
input bool   InpPrintDebug           = true;      // Print management messages

struct PositionInfo
{
   ulong              ticket;
   ENUM_POSITION_TYPE type;
   double             volume;
   double             sl;
   double             tp;
   long               time_msc;
};

//+------------------------------------------------------------------+
//| Basic helpers                                                     |
//+------------------------------------------------------------------+
double TickSize()
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   return tick;
}

double NormalizePrice(const double price)
{
   double tick = TickSize();
   double p = MathRound(price / tick) * tick;
   return NormalizeDouble(p, _Digits);
}

int VolumeDigitsFromStep(const double step)
{
   int digits = 0;
   double s = step;
   while(s > 0.0 && s < 1.0 && digits < 8)
   {
      s *= 10.0;
      digits++;
   }
   return digits;
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathFloor((volume - minLot) / step + 0.5) * step + minLot;
   return NormalizeDouble(volume, VolumeDigitsFromStep(step));
}

double MinStopDistance()
{
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops < 0)
      stops = 0;
   return (double)stops * _Point;
}

bool IsMyOrderSelected()
{
   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;
   if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
      return false;
   return true;
}

bool IsPendingStopType(const ENUM_ORDER_TYPE type)
{
   return (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP);
}

void Debug(const string text)
{
   if(InpPrintDebug)
      Print(text);
}

//+------------------------------------------------------------------+
//| Price validation                                                  |
//+------------------------------------------------------------------+
double ValidBuyStopPrice(double desired)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = MinStopDistance();
   desired = MathMax(desired, ask + minDist);
   return NormalizePrice(desired);
}

double ValidSellStopPrice(double desired)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();
   desired = MathMin(desired, bid - minDist);
   return NormalizePrice(desired);
}

double ValidBuySL(double desired)
{
   // SL for a BUY position or BUY STOP must be below current Bid / entry.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();
   desired = MathMin(desired, bid - minDist);
   return NormalizePrice(desired);
}

double ValidSellSL(double desired)
{
   // SL for a SELL position or SELL STOP must be above current Ask / entry.
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = MinStopDistance();
   desired = MathMax(desired, ask + minDist);
   return NormalizePrice(desired);
}

//+------------------------------------------------------------------+
//| Position helpers                                                  |
//+------------------------------------------------------------------+
bool FindNewestPosition(PositionInfo &newest, int &count)
{
   count = 0;
   newest.ticket = 0;
   newest.time_msc = -1;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      count++;
      long tmsc = (long)PositionGetInteger(POSITION_TIME_MSC);
      if(newest.ticket == 0 || tmsc > newest.time_msc)
      {
         newest.ticket   = ticket;
         newest.type     = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         newest.volume   = PositionGetDouble(POSITION_VOLUME);
         newest.sl       = PositionGetDouble(POSITION_SL);
         newest.tp       = PositionGetDouble(POSITION_TP);
         newest.time_msc = tmsc;
      }
   }
   return (newest.ticket != 0);
}

void CloseAllPositionsExcept(const ulong keepTicket)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(ticket == keepTicket)
         continue;

      trade.SetDeviationInPoints(InpDeviationPoints);
      if(!trade.PositionClose(ticket, InpDeviationPoints))
         Print("Failed to close older position #", ticket, ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      else
         Debug("Closed older position #" + (string)ticket + " after reverse trigger.");
   }
}

bool ModifyPositionSL_OneWay(const PositionInfo &pos, const double desiredSL)
{
   double newSL = NormalizePrice(desiredSL);
   double oldSL = pos.sl;
   bool shouldModify = false;

   if(pos.type == POSITION_TYPE_BUY)
   {
      newSL = ValidBuySL(newSL);
      // BUY SL moves UP only. If no SL, set it.
      if(oldSL <= 0.0 || newSL > oldSL + InpMinModifyStep)
         shouldModify = true;
   }
   else if(pos.type == POSITION_TYPE_SELL)
   {
      newSL = ValidSellSL(newSL);
      // SELL SL moves DOWN only. If no SL, set it.
      if(oldSL <= 0.0 || newSL < oldSL - InpMinModifyStep)
         shouldModify = true;
   }

   if(!shouldModify)
      return true;

   if(!trade.PositionModify(pos.ticket, newSL, pos.tp))
   {
      Print("Failed to modify position SL #", pos.ticket, " to ", DoubleToString(newSL, _Digits),
            ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }

   Debug("Modified position #" + (string)pos.ticket + " SL to " + DoubleToString(newSL, _Digits));
   return true;
}

//+------------------------------------------------------------------+
//| Pending order helpers                                             |
//+------------------------------------------------------------------+
bool FindPendingByType(const ENUM_ORDER_TYPE type, ulong &ticket, double &price, double &sl, double &tp)
{
   ticket = 0;
   price = 0.0;
   sl = 0.0;
   tp = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(!IsMyOrderSelected())
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
         continue;

      ticket = tk;
      price  = OrderGetDouble(ORDER_PRICE_OPEN);
      sl     = OrderGetDouble(ORDER_SL);
      tp     = OrderGetDouble(ORDER_TP);
      return true;
   }
   return false;
}

void DeletePendingTicket(const ulong ticket)
{
   if(ticket == 0)
      return;
   if(!trade.OrderDelete(ticket))
      Print("Failed to delete pending order #", ticket, ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
      Debug("Deleted pending order #" + (string)ticket);
}

void DeletePendingByType(const ENUM_ORDER_TYPE type)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(!IsMyOrderSelected())
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
         continue;
      DeletePendingTicket(tk);
   }
}

void DeleteAllPendingExcept(const ENUM_ORDER_TYPE keepType, const ulong keepTicket)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(!IsMyOrderSelected())
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPendingStopType(type))
         continue;

      if(type == keepType && tk == keepTicket)
         continue;

      DeletePendingTicket(tk);
   }
}

bool ModifyPending(const ulong ticket, const double newPrice, const double newSL, const double oldTP)
{
   if(ticket == 0)
      return false;

   double price = NormalizePrice(newPrice);
   double sl    = NormalizePrice(newSL);

   if(!trade.OrderModify(ticket, price, sl, oldTP, ORDER_TIME_GTC, 0))
   {
      Print("Failed to modify pending #", ticket, " price=", DoubleToString(price, _Digits),
            " sl=", DoubleToString(sl, _Digits), ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }

   Debug("Modified pending #" + (string)ticket + " price=" + DoubleToString(price, _Digits) + " SL=" + DoubleToString(sl, _Digits));
   return true;
}

bool PlaceBuyStop(const double price, const double sl, const string comment)
{
   double lots = NormalizeVolume(InpLots);
   double p = ValidBuyStopPrice(price);
   double s = NormalizePrice(sl);

   // Ensure buy stop SL is below order price by at least the broker stop level.
   double minDist = MinStopDistance();
   s = MathMin(s, p - minDist);
   s = NormalizePrice(s);

   if(!trade.BuyStop(lots, p, _Symbol, s, 0.0, ORDER_TIME_GTC, 0, comment))
   {
      Print("Failed to place BUY STOP at ", DoubleToString(p, _Digits), " SL=", DoubleToString(s, _Digits),
            ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }

   Debug("Placed BUY STOP price=" + DoubleToString(p, _Digits) + " SL=" + DoubleToString(s, _Digits));
   return true;
}

bool PlaceSellStop(const double price, const double sl, const string comment)
{
   double lots = NormalizeVolume(InpLots);
   double p = ValidSellStopPrice(price);
   double s = NormalizePrice(sl);

   // Ensure sell stop SL is above order price by at least the broker stop level.
   double minDist = MinStopDistance();
   s = MathMax(s, p + minDist);
   s = NormalizePrice(s);

   if(!trade.SellStop(lots, p, _Symbol, s, 0.0, ORDER_TIME_GTC, 0, comment))
   {
      Print("Failed to place SELL STOP at ", DoubleToString(p, _Digits), " SL=", DoubleToString(s, _Digits),
            ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }

   Debug("Placed SELL STOP price=" + DoubleToString(p, _Digits) + " SL=" + DoubleToString(s, _Digits));
   return true;
}

//+------------------------------------------------------------------+
//| Initial bracket management                                        |
//+------------------------------------------------------------------+
void EnsureInitialBothStops()
{
   if(!InpPlaceInitialBothStops)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double desiredBuy  = ValidBuyStopPrice(ask + InpReverseDistance);
   double desiredSell = ValidSellStopPrice(bid - InpReverseDistance);

   ulong buyTicket, sellTicket;
   double buyPrice, buySL, buyTP, sellPrice, sellSL, sellTP;
   bool hasBuy  = FindPendingByType(ORDER_TYPE_BUY_STOP,  buyTicket,  buyPrice,  buySL,  buyTP);
   bool hasSell = FindPendingByType(ORDER_TYPE_SELL_STOP, sellTicket, sellPrice, sellSL, sellTP);

   if(!hasBuy && !hasSell)
   {
      // First placement. Pending SLs are based on the opposite stop level.
      PlaceBuyStop(desiredBuy,  desiredSell - InpStopLossGap, "Initial BUY STOP");
      PlaceSellStop(desiredSell, desiredBuy  + InpStopLossGap, "Initial SELL STOP");
      return;
   }

   if(!hasBuy)
      PlaceBuyStop(desiredBuy, (hasSell ? sellPrice : desiredSell) - InpStopLossGap, "Initial BUY STOP");

   if(!hasSell)
      PlaceSellStop(desiredSell, (hasBuy ? buyPrice : desiredBuy) + InpStopLossGap, "Initial SELL STOP");

   // Re-read after possible placements.
   hasBuy  = FindPendingByType(ORDER_TYPE_BUY_STOP,  buyTicket,  buyPrice,  buySL,  buyTP);
   hasSell = FindPendingByType(ORDER_TYPE_SELL_STOP, sellTicket, sellPrice, sellSL, sellTP);

   if(!hasBuy || !hasSell)
      return;

   // No-position bracket: BUY STOP moves DOWN only; SELL STOP moves UP only.
   double newBuyPrice  = buyPrice;
   double newSellPrice = sellPrice;

   if(desiredBuy < buyPrice - InpMinModifyStep)
      newBuyPrice = desiredBuy;

   if(desiredSell > sellPrice + InpMinModifyStep)
      newSellPrice = desiredSell;

   // Pending SLs keep the 1.90 gap beyond the opposite stop.
   double newBuySL  = NormalizePrice(newSellPrice - InpStopLossGap); // BUY SL moves UP only
   double newSellSL = NormalizePrice(newBuyPrice  + InpStopLossGap); // SELL SL moves DOWN only

   bool needBuyModify = false;
   if(MathAbs(newBuyPrice - buyPrice) >= InpMinModifyStep)
      needBuyModify = true;
   if(buySL <= 0.0 || newBuySL > buySL + InpMinModifyStep)
      needBuyModify = true;

   bool needSellModify = false;
   if(MathAbs(newSellPrice - sellPrice) >= InpMinModifyStep)
      needSellModify = true;
   if(sellSL <= 0.0 || newSellSL < sellSL - InpMinModifyStep)
      needSellModify = true;

   if(needBuyModify)
      ModifyPending(buyTicket, ValidBuyStopPrice(newBuyPrice), newBuySL, buyTP);

   if(needSellModify)
      ModifyPending(sellTicket, ValidSellStopPrice(newSellPrice), newSellSL, sellTP);
}

//+------------------------------------------------------------------+
//| Active position management                                        |
//+------------------------------------------------------------------+
void ManageActiveBuy(const PositionInfo &pos)
{
   // In BUY mode, only opposite SELL STOP is needed.
   DeletePendingByType(ORDER_TYPE_BUY_STOP);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double desiredSell = ValidSellStopPrice(bid - InpReverseDistance);

   ulong sellTicket;
   double sellPrice, sellSL, sellTP;
   bool hasSell = FindPendingByType(ORDER_TYPE_SELL_STOP, sellTicket, sellPrice, sellSL, sellTP);

   if(!hasSell)
   {
      // Fallback SL for the future SELL is entry + gap. It will be adjusted after reverse.
      if(!PlaceSellStop(desiredSell, desiredSell + InpStopLossGap, "Reverse SELL STOP"))
         return;
      hasSell = FindPendingByType(ORDER_TYPE_SELL_STOP, sellTicket, sellPrice, sellSL, sellTP);
   }
   else
   {
      DeleteAllPendingExcept(ORDER_TYPE_SELL_STOP, sellTicket);

      // SELL STOP moves UP only. Never move it down with market pullback.
      if(desiredSell > sellPrice + InpMinModifyStep)
      {
         double newSL = desiredSell + InpStopLossGap; // fallback SL if this pending becomes a sell
         if(ModifyPending(sellTicket, desiredSell, newSL, sellTP))
         {
            // Re-read modified price.
            FindPendingByType(ORDER_TYPE_SELL_STOP, sellTicket, sellPrice, sellSL, sellTP);
         }
      }
   }

   if(hasSell)
   {
      // Active BUY SL stays 1.90 below the trailing SELL STOP, and moves UP only.
      double desiredBuySL = sellPrice - InpStopLossGap;
      ModifyPositionSL_OneWay(pos, desiredBuySL);
   }
}

void ManageActiveSell(const PositionInfo &pos)
{
   // In SELL mode, only opposite BUY STOP is needed.
   DeletePendingByType(ORDER_TYPE_SELL_STOP);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double desiredBuy = ValidBuyStopPrice(ask + InpReverseDistance);

   ulong buyTicket;
   double buyPrice, buySL, buyTP;
   bool hasBuy = FindPendingByType(ORDER_TYPE_BUY_STOP, buyTicket, buyPrice, buySL, buyTP);

   if(!hasBuy)
   {
      // Fallback SL for the future BUY is entry - gap. It will be adjusted after reverse.
      if(!PlaceBuyStop(desiredBuy, desiredBuy - InpStopLossGap, "Reverse BUY STOP"))
         return;
      hasBuy = FindPendingByType(ORDER_TYPE_BUY_STOP, buyTicket, buyPrice, buySL, buyTP);
   }
   else
   {
      DeleteAllPendingExcept(ORDER_TYPE_BUY_STOP, buyTicket);

      // BUY STOP moves DOWN only. Never move it up with market pullback.
      if(desiredBuy < buyPrice - InpMinModifyStep)
      {
         double newSL = desiredBuy - InpStopLossGap; // fallback SL if this pending becomes a buy
         if(ModifyPending(buyTicket, desiredBuy, newSL, buyTP))
         {
            // Re-read modified price.
            FindPendingByType(ORDER_TYPE_BUY_STOP, buyTicket, buyPrice, buySL, buyTP);
         }
      }
   }

   if(hasBuy)
   {
      // Active SELL SL stays 1.90 above the trailing BUY STOP, and moves DOWN only.
      double desiredSellSL = buyPrice + InpStopLossGap;
      ModifyPositionSL_OneWay(pos, desiredSellSL);
   }
}

//+------------------------------------------------------------------+
//| Main EA events                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpReverseDistance <= 0.0 || InpStopLossGap <= 0.0 || InpLots <= 0.0)
   {
      Print("Invalid inputs. Lots, ReverseDistance, and StopLossGap must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Debug("EA initialized on " + _Symbol + ". ReverseDistance=" + DoubleToString(InpReverseDistance, 2) +
         " StopLossGap=" + DoubleToString(InpStopLossGap, 2));
   return INIT_SUCCEEDED;
}

void OnTick()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   PositionInfo newest;
   int posCount = 0;
   bool hasPosition = FindNewestPosition(newest, posCount);

   if(hasPosition && posCount > 1 && InpCloseOlderOnReverse)
   {
      CloseAllPositionsExcept(newest.ticket);
      // Re-read after close.
      FindNewestPosition(newest, posCount);
   }

   if(!hasPosition || newest.ticket == 0)
   {
      EnsureInitialBothStops();
      return;
   }

   if(newest.type == POSITION_TYPE_BUY)
      ManageActiveBuy(newest);
   else if(newest.type == POSITION_TYPE_SELL)
      ManageActiveSell(newest);
}

void OnDeinit(const int reason)
{
   Debug("EA deinitialized. Reason=" + (string)reason);
}
//+------------------------------------------------------------------+
