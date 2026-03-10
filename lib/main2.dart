// main.dart
import 'dart:async';
import 'package:hyperliquid_dart_sdk/hyperliquid_dart_sdk.dart';
import 'package:scalpex2/injector/injector.dart';
import 'package:scalpex2/mexc_features_mk1.dart';
import 'package:scalpex2/shared/config_loader.dart';
import 'package:scalpex2/shared/program.dart';

void main() async {
  configureDependencies();
  var config = await ConfigLoader.loadConfig('config.json');
  injector<Program>().setConfig(config);

  const coin = 'SOL';
  const user = '0xaF968AD4dEd405C5DFa59b07c2E11716506f4697';
  final info = HyperliquidInfoClient(network: HlNetworkConfig.mainnet);
  final HyperliquidExchangeClient client = HyperliquidExchangeClient.ws(
    privateKeyHex:
        '0x5c61daff394358fd0c45d716a9b93c26511ba53284bd527e0e8e4c7d22882a44',
    network: HlNetworkConfig.mainnet,
  );
  final mon = HyperliquidPortfolioMonitor(
    userAddress: user,
    dex: null, // можно null, чтобы поле dex не отправлялось
    verbose: false,
    network: HlNetworkConfig.mainnet,
  );

  await mon.start();
  ResolvedPerpMarket market = await info.resolvePerpMarket(coin);
  print(market);

  // final balanceManager = BalanceManager(api: api);
  // final executionManager = ExecutionManager(
  //   api: api,
  //   minVolBySymbol: injector<Program>().minVolBySymbol,
  //   qtyStepBySymbol: injector<Program>().qtyStepBySymbol,
  //   balanceManager: balanceManager,
  // );

  // final bot1 = MexcFuturesSignalBot(
  //   symbol: 'SUI_USDT',
  //   timeframe: 'Min1',
  //   restTimeframe: '1m',
  //   executionManager: executionManager,
  //   botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
  //   // chatId: '469171720',
  //   useTrade: true,
  //   chatId: '469171720',
  // );

  final bot2 = MexcFuturesMk1(
    symbol: '${coin}_USDT',
    timeframe: 'Min1',
    restTimeframe: '1m',
    exchangeClient: client,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    useTrade: true,
    chatId: '469171720',
    parentTimeframe: '1h',
    resolvedPerpMarket: market,
    parentLastSignalWasLong: false,
  );

  // executionManager.wireOrderAndPositionUpdates(hl);
  // hl.onAsset.listen((assetSnapshot) {
  //   balanceManager.updateFromWebSocket(assetSnapshot);
  // });

  // hl.onCurrency.listen((currencySnapshot) {});
  try {
    await bot2.connect();
    await bot2.connectParent();
    // await hl.start();
    // await balanceManager.loadInitialBalance(); // Загружаем начальный баланс

    Timer.periodic(Duration(seconds: 30), (timer) async {
      config = await ConfigLoader.reloadConfig('config.json');
    });
    await Future.delayed(Duration(days: 365)); // Пример
  } catch (e) {
    bot2.dispose();
  }
}
