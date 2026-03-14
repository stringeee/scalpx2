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

  final bot2 = MexcFuturesMk1(
    symbol: '${coin}_USDT',
    timeframe: 'Min1',
    restTimeframe: '1m',
    exchangeClient: client,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    useTrade: true,
    useParentFilter: false,
    chatId: '469171720',
    parentTimeframe: '1h',
    resolvedPerpMarket: market,
    infoClient: info,
    user: user,
    // parentLastSignalWasLong: false,
  );

  try {
    await bot2.connect();
    await bot2.connectParent();

    Timer.periodic(Duration(seconds: 30), (timer) async {
      config = await ConfigLoader.reloadConfig('config.json');
    });
    await Future.delayed(Duration(days: 365)); // Пример
  } catch (e) {
    bot2.dispose();
  }
}
