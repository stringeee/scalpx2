// main.dart
import 'package:hyperliquid_dart_sdk/hyperliquid_dart_sdk.dart';
import 'package:scalpex2/injector/injector.dart';
import 'package:scalpex2/shared/config_loader.dart';
import 'package:scalpex2/shared/program.dart';
import 'package:scalpex2/shared/take_profit_price_calc.dart';

void main() async {
  configureDependencies();
  var config = await ConfigLoader.loadConfig('config.json');
  injector<Program>().setConfig(config);

  const coin = 'SOL';
  final info = HyperliquidInfoClient(network: HlNetworkConfig.mainnet);

  final HyperliquidExchangeClient exchangeClient = HyperliquidExchangeClient.ws(
    privateKeyHex:
        '0x5c61daff394358fd0c45d716a9b93c26511ba53284bd527e0e8e4c7d22882a44',
    network: HlNetworkConfig.mainnet,
  );

  var market = await info.resolvePerpMarket(coin);
  var tick = market.markPx.toString().split('.').last.length;

  print('$market');
  print('$tick');
  var currentPrice = 96.6;

  final sizing = PositionSizer.fromMarginUsd(
    marginUsd: 20,
    leverage: 10,
    entryPrice: currentPrice,
    szDecimals: market.szDecimals,
  );

  var resp = await exchangeClient.placeEntryWithTpSl(
    asset: market.asset,
    isCross: false,
    isBuy: true,
    // entryPx: double.parse(currentPrice.toStringAsFixed(tick)),
    entryPx: 56.600,
    size: sizing.finalSize,
    takeProfitTriggerPx: double.parse(
      takeProfitPriceCalc(
        isBinance: false,
        leverage: 10,
        price: currentPrice,
        isBid: true,
      ).toStringAsFixed(2),
    ),
    stopLossTriggerPx: double.parse(
      calculateStopLossPrice(
        isBid: true,
        price: currentPrice,
        leverage: 10,
        lossPercent: 10,
      ).toStringAsFixed(2),
    ),
    groupAsNormalTpsl: true,
    entryOrderType: ActionBuilders.limitOrderType(tif: 'Gtc'),
    leverage: 10,
  );

  print(resp);
}
