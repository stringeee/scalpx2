// main.dart
import 'dart:async';
import 'package:scalpex2/api/mexc_api.dart';
import 'package:scalpex2/balance_manager.dart';
import 'package:scalpex2/execution_manager.dart';
import 'package:scalpex2/hl_ws_source.dart';
import 'package:scalpex2/injector/injector.dart';
import 'package:scalpex2/mexc_features_signal_bot.dart';
import 'package:scalpex2/shared/config_loader.dart';
import 'package:scalpex2/shared/const.dart';
import 'package:scalpex2/shared/program.dart';

void main() async {
  configureDependencies();
  var config = await ConfigLoader.loadConfig('config.json');
  injector<Program>().setConfig(config);

  final api = MexcApi(baseUrl, apiKey, config.webKey, network);

  final hl = HyperliquidWsSource(config);
  final balanceManager = BalanceManager(api: api);
  final executionManager = ExecutionManager(
    api: api,
    minVolBySymbol: injector<Program>().minVolBySymbol,
    qtyStepBySymbol: injector<Program>().qtyStepBySymbol,
    balanceManager: balanceManager,
  );

  final bot1 = MexcFuturesSignalBot(
    symbol: 'BTC_USDT',
    timeframe: 'Hour2',
    restTimeframe: '2h',
    executionManager: executionManager,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    // chatId: '469171720',
    chatId: '-1003184799542',
  );
  final bot2 = MexcFuturesSignalBot(
    symbol: 'HYPE_USDT',
    timeframe: 'Hour1',
    executionManager: executionManager,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    chatId: '-1003184799542',
    restTimeframe: '1h',
  );
  final bot3 = MexcFuturesSignalBot(
    symbol: 'BNB_USDT',
    timeframe: 'Hour1',
    executionManager: executionManager,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    chatId: '-1003184799542',
    restTimeframe: '1h',
  );
  final bot4 = MexcFuturesSignalBot(
    symbol: 'ETH_USDT',
    timeframe: 'Min30',
    executionManager: executionManager,
    botToken: '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ',
    chatId: '-1003184799542',
    restTimeframe: '30m',
  );

  executionManager.wireOrderAndPositionUpdates(hl);
  hl.onAsset.listen((assetSnapshot) {
    balanceManager.updateFromWebSocket(assetSnapshot);
  });

  hl.onCurrency.listen((currencySnapshot) {});
  try {
    await bot1.connect();
    await bot2.connect();
    await bot3.connect();
    await bot4.connect();
    await hl.start();
    await balanceManager.loadInitialBalance(); // Загружаем начальный баланс

    Timer.periodic(Duration(seconds: 30), (timer) async {
      config = await ConfigLoader.reloadConfig('config.json');
    });
    // Запускаем бесконечный цикл для поддержания работы
    await Future.delayed(Duration(days: 365)); // Пример
  } catch (e) {
    bot1.dispose();
    bot2.dispose();
    bot3.dispose();
    bot4.dispose();
  }
}
