import 'package:scalpex2/entities/asset_snapshot.dart';
import 'package:scalpex2/entities/currency_snapshot.dart';
import 'package:scalpex2/entities/order_snapshot.dart';
import 'package:scalpex2/entities/position_snapshot.dart';

abstract class IOrderBookSource {
  Stream<CurrencySnapshot> get onCurrency;
  Stream<OrderSnapshot> get onOrder;
  Stream<PositionSnapshot> get onPosition;
  Stream<AssetSnapshot> get onAsset;

  bool get isHyperliquidConnected;
  bool get isMexcConnected;
  bool get isBinanceConnected;

  Future<void> start();
  void dispose();
}
