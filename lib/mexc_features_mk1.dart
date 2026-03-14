import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:hyperliquid_dart_sdk/hyperliquid_dart_sdk.dart';
import 'package:scalpex2/candle.dart';
import 'package:scalpex2/mexc_client.dart';
import 'package:scalpex2/rsi_data.dart';
import 'package:scalpex2/shared/take_profit_price_calc.dart';
import 'package:scalpex2/telegram_signal_client.dart';
import 'package:scalpex2/wae_signal.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TapeTrade {
  final double price;
  final double size;
  final bool isBuyAggressor;
  final DateTime time;

  const TapeTrade({
    required this.price,
    required this.size,
    required this.isBuyAggressor,
    required this.time,
  });
}

class TapeStats {
  final double buyVolume;
  final double sellVolume;
  final int tradeCount;
  final double avgTradeSize;
  final double delta;
  final double deltaRatio;
  final bool hasLargeBuyBurst;
  final bool hasLargeSellBurst;

  const TapeStats({
    required this.buyVolume,
    required this.sellVolume,
    required this.tradeCount,
    required this.avgTradeSize,
    required this.delta,
    required this.deltaRatio,
    required this.hasLargeBuyBurst,
    required this.hasLargeSellBurst,
  });
}

class MexcFuturesMk1 {
  final String symbol;
  final String timeframe;
  final String restTimeframe;
  final String parentTimeframe;
  final HyperliquidInfoClient infoClient;
  final String user;

  final bool debugStrictConditions = true;

  late TelegramSignalClient telegramClient;

  WebSocketChannel? _channel;
  WebSocketChannel? _parentChannel;
  WebSocketChannel? _tradeChannel;

  final List<Candle> _candles = [];
  final List<Candle> _parentCandles = [];
  final List<TapeTrade> _recentTrades = [];
  final List<int> _recentSignalDirections = []; // 1 = long, -1 = short

  bool? _lastSignalWasLong;
  bool? parentLastSignalWasLong;

  final bool useTrade;
  final bool useParentFilter;
  final bool enableTradeConfirmation;

  final HyperliquidExchangeClient exchangeClient;
  final ResolvedPerpMarket resolvedPerpMarket;

  bool _tradeStreamStarted = false;
  bool _longArmed = true;
  bool _shortArmed = true;

  int _cooldownBarsRemaining = 0;
  int _noTradeBarsRemaining = 0;

  static const int _historyLimit = 250;
  static const int _minCandlesForSignal = 150;

  static const int _tradeWindowSeconds = 12;
  static const int _confirmWindowSeconds = 3;
  static const int _baselineWindowSeconds = 10;
  static const int _minTradesInConfirmWindow = 15;

  static const double _minLongDeltaRatio = 0.12;
  static const double _minShortDeltaRatio = -0.12;

  static const int _cooldownBars = 3;
  static const int _noTradeBars = 10;

  static const int _maxRecentSignalDirections = 20;
  static const int _maxAllowedFlips = 3;

  static const double _minWaeOverE1 = 1.15;
  static const double _minWaeOverDeadzone = 1.25;
  static const double _minExplosionOverDeadzone = 1.10;

  static const double _minLongRsi = 55.0;
  static const double _maxShortRsi = 45.0;
  static const double _minRsiSpread = 2.0;

  MexcFuturesMk1({
    required this.symbol,
    this.timeframe = 'Min1',
    required String botToken,
    required String chatId,
    required this.restTimeframe,
    this.useTrade = false,
    required this.parentTimeframe,
    required this.exchangeClient,
    required this.resolvedPerpMarket,
    this.parentLastSignalWasLong,
    this.useParentFilter = false,
    this.enableTradeConfirmation = true,
    required this.infoClient,
    required this.user,
  }) {
    telegramClient = TelegramSignalClient(botToken: botToken, chatId: chatId);
  }

  final MexcClient mexcClient = MexcClient();

  Future<void> connect() async {
    print('🔄 Подключение к основному WebSocket...');
    final uri = Uri.parse(
      'wss://fstream.binance.com/ws/${symbol.split('_').join('').toLowerCase()}@kline_$restTimeframe',
    );

    final historicalData = await mexcClient.fetchKlineData(
      symbol: symbol.split('_').join(),
      interval: restTimeframe,
      limit: _historyLimit,
    );

    _candles
      ..clear()
      ..addAll(historicalData);

    if (enableTradeConfirmation && !_tradeStreamStarted) {
      _tradeStreamStarted = true;
      unawaited(connectTrades());
    }

    await Future.delayed(const Duration(seconds: 1));
    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(
      (data) => _handleIncomingMessage(data, false),
      onError: (error) => print('❌ Ошибка WebSocket: $error'),
      onDone: () {
        print('📴 Основное соединение закрыто');
        connect();
      },
    );
  }

  Future<void> connectParent() async {
    print('🔄 Подключение к parent WebSocket...');
    final uri = Uri.parse(
      'wss://stream.binance.com:9443/ws/${symbol.split('_').join('').toLowerCase()}@kline_$parentTimeframe',
    );

    final historicalData = await mexcClient.fetchKlineData(
      symbol: symbol.split('_').join(),
      interval: parentTimeframe,
      limit: _historyLimit,
    );

    _parentCandles
      ..clear()
      ..addAll(historicalData);

    await Future.delayed(const Duration(seconds: 1));
    _parentChannel = WebSocketChannel.connect(uri);
    _parentChannel!.stream.listen(
      (data) => _handleIncomingMessage(data, true),
      onError: (error) => print('❌ Ошибка Parent WebSocket: $error'),
      onDone: () {
        print('📴 Parent соединение закрыто');
        connectParent();
      },
    );
  }

  Future<void> connectTrades() async {
    final uri = Uri.parse(
      'wss://fstream.binance.com/ws/${symbol.split('_').join('').toLowerCase()}@trade',
    );

    print('🔄 Подключение к trade WebSocket...');
    _tradeChannel = WebSocketChannel.connect(uri);
    _tradeChannel!.stream.listen(
      _handleTradeMessage,
      onError: (error) => print('❌ Ошибка Trade WebSocket: $error'),
      onDone: () {
        print('📴 Trade соединение закрыто');
        connectTrades();
      },
    );
  }

  void _handleIncomingMessage(dynamic message, bool isParent) {
    try {
      if (message is String) {
        final jsonMsg = jsonDecode(message);
        if (jsonMsg['channel'] == 'pong') return;
        if (jsonMsg['e'] == 'kline') {
          _processKlineData(jsonMsg, isParent);
        }
      } else if (message is List<int>) {
        print('⚠️ Получены бинарные данные. Проверь десериализацию.');
      }
    } catch (e) {
      print('Ошибка обработки сообщения: $e');
    }
  }

  void _handleTradeMessage(dynamic message) {
    try {
      if (message is! String) return;

      final jsonMsg = jsonDecode(message);
      if (jsonMsg['e'] != 'trade') return;

      final trade = TapeTrade(
        price: double.parse(jsonMsg['p'].toString()),
        size: double.parse(jsonMsg['q'].toString()),
        isBuyAggressor: _resolveAggressorSide(jsonMsg),
        time: DateTime.fromMillisecondsSinceEpoch(
          int.parse(jsonMsg['T'].toString()),
        ),
      );

      _recentTrades.add(trade);
      _trimOldTrades();
    } catch (e) {
      print('Ошибка обработки trade message: $e');
    }
  }

  bool _resolveAggressorSide(Map<String, dynamic> tradeMsg) {
    final bool buyerIsMarketMaker = tradeMsg['m'] == true;
    return !buyerIsMarketMaker;
  }

  void _processKlineData(dynamic klineData, bool isParent) {
    final candle = Candle(
      open: double.parse(klineData['k']['o'].toString()),
      high: double.parse(klineData['k']['h'].toString()),
      low: double.parse(klineData['k']['l'].toString()),
      close: double.parse(klineData['k']['c'].toString()),
      volume: double.parse(klineData['k']['q'].toString()),
      time: DateTime.fromMillisecondsSinceEpoch(klineData['k']['t']),
    );

    _addToBuffer(candle, isParent);

    final bool isClosed = klineData['k']['x'] == true;
    if (!isClosed) return;

    if (isParent) {
      if (_parentCandles.length > _historyLimit) {
        _parentCandles.removeAt(0);
      }

      if (_parentCandles.length >= _minCandlesForSignal) {
        _checkParentSignals();
      }
    } else {
      _onClosedBar();

      if (_candles.length > _historyLimit) {
        _candles.removeAt(0);
      }

      if (_candles.length >= _minCandlesForSignal) {
        _checkForSignals();
      }
    }
  }

  void _addToBuffer(Candle marketData, bool isParent) {
    if (isParent) {
      final existingIndex = _parentCandles.indexWhere(
        (d) => d.time.isAtSameMomentAs(marketData.time),
      );

      if (existingIndex >= 0) {
        _parentCandles[existingIndex] = marketData;
      } else {
        _parentCandles.add(marketData);

        if (_parentCandles.length > _historyLimit) {
          _parentCandles.removeAt(0);
        }

        _parentCandles.sort((a, b) => a.time.compareTo(b.time));
      }
    } else {
      final existingIndex = _candles.indexWhere(
        (d) => d.time.isAtSameMomentAs(marketData.time),
      );

      if (existingIndex >= 0) {
        _candles[existingIndex] = marketData;
      } else {
        _candles.add(marketData);

        if (_candles.length > _historyLimit) {
          _candles.removeAt(0);
        }

        _candles.sort((a, b) => a.time.compareTo(b.time));
      }
    }
  }

  void _onClosedBar() {
    if (_cooldownBarsRemaining > 0) _cooldownBarsRemaining--;
    if (_noTradeBarsRemaining > 0) _noTradeBarsRemaining--;
  }

  bool _inCooldown() => _cooldownBarsRemaining > 0;

  bool _inNoTradeMode() => _noTradeBarsRemaining > 0;

  void _recordSignalDirection(int direction) {
    _recentSignalDirections.add(direction);

    if (_recentSignalDirections.length > _maxRecentSignalDirections) {
      _recentSignalDirections.removeAt(0);
    }

    final flips = _countRecentSignalFlips();
    if (flips > _maxAllowedFlips) {
      _noTradeBarsRemaining = _noTradeBars;
      print('🟡 NO-TRADE MODE включен на $_noTradeBars свечей | flips=$flips');
    }
  }

  int _countRecentSignalFlips() {
    if (_recentSignalDirections.length < 2) return 0;

    int flips = 0;
    for (int i = 1; i < _recentSignalDirections.length; i++) {
      if (_recentSignalDirections[i] != _recentSignalDirections[i - 1]) {
        flips++;
      }
    }
    return flips;
  }

  void _updateRearm(WAESignal waeSignal) {
    if (!_longArmed && waeSignal.trendUp < waeSignal.deadzone) {
      _longArmed = true;
    }

    if (!_shortArmed && waeSignal.trendDown < waeSignal.deadzone) {
      _shortArmed = true;
    }
  }

  bool _passesRegimeFilter(List<double> closes, bool isLong) {
    if (closes.length < 100) return false;

    final ema50 = _calculateEMA(closes, 50);
    final ema100 = _calculateEMA(closes, 100);
    final currentPrice = closes.last;

    if (isLong) {
      return ema50 > ema100;
    } else {
      return ema50 < ema100;
    }
  }

  bool _passesStrictWaeLong(WAESignal current, WAESignal previous) {
    if (!current.isLong || !previous.isLong) return false;
    if (current.trendUp <= previous.trendUp) return false;
    if (current.trendUp <= current.e1 * _minWaeOverE1) return false;
    if (current.trendUp <= current.deadzone * _minWaeOverDeadzone) return false;
    if (current.e1 <= current.deadzone * _minExplosionOverDeadzone) {
      return false;
    }
    return true;
  }

  bool _passesStrictWaeShort(WAESignal current, WAESignal previous) {
    if (!current.isShort || !previous.isShort) return false;
    if (current.trendDown <= previous.trendDown) return false;
    if (current.trendDown <= current.e1 * _minWaeOverE1) return false;
    if (current.trendDown <= current.deadzone * _minWaeOverDeadzone) {
      return false;
    }
    if (current.e1 <= current.deadzone * _minExplosionOverDeadzone) {
      return false;
    }
    return true;
  }

  bool _passesStrictRsiLong(RsiData data) {
    if (data.rsiValues.length < 2 || data.rsiMaValues.length < 2) return false;

    final currentRsi = data.rsiValues.last;
    final previousRsi = data.rsiValues[data.rsiValues.length - 2];

    final currentRsiMa = data.rsiMaValues.last;
    final previousRsiMa = data.rsiMaValues[data.rsiMaValues.length - 2];

    final spread = currentRsi - currentRsiMa;

    return currentRsi > currentRsiMa &&
        previousRsi > previousRsiMa &&
        currentRsi > _minLongRsi &&
        spread > _minRsiSpread;
  }

  bool _passesStrictRsiShort(RsiData data) {
    if (data.rsiValues.length < 2 || data.rsiMaValues.length < 2) return false;

    final currentRsi = data.rsiValues.last;
    final previousRsi = data.rsiValues[data.rsiValues.length - 2];

    final currentRsiMa = data.rsiMaValues.last;
    final previousRsiMa = data.rsiMaValues[data.rsiMaValues.length - 2];

    final spread = currentRsiMa - currentRsi;

    return currentRsi < currentRsiMa &&
        previousRsi < previousRsiMa &&
        currentRsi < _maxShortRsi &&
        spread > _minRsiSpread;
  }

  void _trimOldTrades() {
    final cutoff = DateTime.now().subtract(
      const Duration(seconds: _tradeWindowSeconds),
    );
    _recentTrades.removeWhere((t) => t.time.isBefore(cutoff));
  }

  TapeStats _buildTapeStats({int seconds = _confirmWindowSeconds}) {
    _trimOldTrades();

    final cutoff = DateTime.now().subtract(Duration(seconds: seconds));
    final trades = _recentTrades.where((t) => t.time.isAfter(cutoff)).toList();

    if (trades.isEmpty) {
      return const TapeStats(
        buyVolume: 0,
        sellVolume: 0,
        tradeCount: 0,
        avgTradeSize: 0,
        delta: 0,
        deltaRatio: 0,
        hasLargeBuyBurst: false,
        hasLargeSellBurst: false,
      );
    }

    double buyVolume = 0;
    double sellVolume = 0;
    double totalSize = 0;

    final sortedSizes = trades.map((t) => t.size).toList()..sort();
    final thresholdIndex = (sortedSizes.length * 0.9).floor().clamp(
      0,
      sortedSizes.length - 1,
    );
    final largeThreshold = sortedSizes[thresholdIndex];

    int largeBuyCount = 0;
    int largeSellCount = 0;

    for (final trade in trades) {
      totalSize += trade.size;

      if (trade.isBuyAggressor) {
        buyVolume += trade.size;
        if (trade.size >= largeThreshold) largeBuyCount++;
      } else {
        sellVolume += trade.size;
        if (trade.size >= largeThreshold) largeSellCount++;
      }
    }

    final delta = buyVolume - sellVolume;
    final totalVolume = buyVolume + sellVolume;
    final deltaRatio = totalVolume == 0 ? 0.0 : delta / totalVolume;

    return TapeStats(
      buyVolume: buyVolume,
      sellVolume: sellVolume,
      tradeCount: trades.length,
      avgTradeSize: totalSize / trades.length,
      delta: delta,
      deltaRatio: deltaRatio,
      hasLargeBuyBurst: largeBuyCount >= 3,
      hasLargeSellBurst: largeSellCount >= 3,
    );
  }

  bool _passesLongTradeFilter() {
    if (!enableTradeConfirmation) return true;

    final confirmStats = _buildTapeStats(seconds: _confirmWindowSeconds);
    final baselineStats = _buildTapeStats(seconds: _baselineWindowSeconds);

    if (confirmStats.tradeCount < _minTradesInConfirmWindow) return false;
    if (confirmStats.deltaRatio <= _minLongDeltaRatio) return false;
    if (confirmStats.avgTradeSize < baselineStats.avgTradeSize) return false;
    if (confirmStats.hasLargeSellBurst && !confirmStats.hasLargeBuyBurst) {
      return false;
    }

    return true;
  }

  bool _passesShortTradeFilter() {
    if (!enableTradeConfirmation) return true;

    final confirmStats = _buildTapeStats(seconds: _confirmWindowSeconds);
    final baselineStats = _buildTapeStats(seconds: _baselineWindowSeconds);

    if (confirmStats.tradeCount < _minTradesInConfirmWindow) return false;
    if (confirmStats.deltaRatio >= _minShortDeltaRatio) return false;
    if (confirmStats.avgTradeSize < baselineStats.avgTradeSize) return false;
    if (confirmStats.hasLargeBuyBurst && !confirmStats.hasLargeSellBurst) {
      return false;
    }

    return true;
  }

  void _printTapeStats(String side, TapeStats stats) {
    print(
      '   Tape $side: '
      'delta=${stats.delta.toStringAsFixed(4)} | '
      'deltaRatio=${stats.deltaRatio.toStringAsFixed(3)} | '
      'count=${stats.tradeCount} | '
      'avgSize=${stats.avgTradeSize.toStringAsFixed(4)} | '
      'buyBurst=${stats.hasLargeBuyBurst} | '
      'sellBurst=${stats.hasLargeSellBurst}',
    );
  }

  Future<void> _checkForSignals() async {
    if (_candles.length < _minCandlesForSignal) return;

    final closes = _candles.map((c) => c.close).toList();
    final highs = _candles.map((c) => c.high).toList();
    final lows = _candles.map((c) => c.low).toList();

    if (closes.length < _minCandlesForSignal + 1) return;

    final currentWae = _calculateWAE(closes, highs, lows);
    final prevWae = _calculateWAE(
      closes.sublist(0, closes.length - 1),
      highs.sublist(0, highs.length - 1),
      lows.sublist(0, lows.length - 1),
    );

    final rsiData = _calculateRsiComponents(closes);
    final currentPrice = closes.last;

    _updateRearm(currentWae);

    final inCooldown = _inCooldown();
    final inNoTrade = _inNoTradeMode();

    final canLongByDirection =
        _lastSignalWasLong == false || _lastSignalWasLong == null;
    final canShortByDirection =
        _lastSignalWasLong == true || _lastSignalWasLong == null;

    final parentLongOk = !useParentFilter || parentLastSignalWasLong == true;
    final parentShortOk = !useParentFilter || parentLastSignalWasLong == false;

    final regimeLongOk = _passesRegimeFilter(closes, true);
    final regimeShortOk = _passesRegimeFilter(closes, false);

    final strictWaeLongOk = _passesStrictWaeLong(currentWae, prevWae);
    final strictWaeShortOk = _passesStrictWaeShort(currentWae, prevWae);

    final strictRsiLongOk = _passesStrictRsiLong(rsiData);
    final strictRsiShortOk = _passesStrictRsiShort(rsiData);

    final confirmStats = _buildTapeStats(seconds: _confirmWindowSeconds);
    final baselineStats = _buildTapeStats(seconds: _baselineWindowSeconds);

    final tradeCountOk = confirmStats.tradeCount >= _minTradesInConfirmWindow;
    final avgSizeOk =
        confirmStats.avgTradeSize >= baselineStats.avgTradeSize * 0.70;

    final tradeLongDeltaOk = confirmStats.deltaRatio > _minLongDeltaRatio;
    final tradeShortDeltaOk = confirmStats.deltaRatio < _minShortDeltaRatio;

    final tradeLongBurstOk =
        !(confirmStats.hasLargeSellBurst && !confirmStats.hasLargeBuyBurst);
    final tradeShortBurstOk =
        !(confirmStats.hasLargeBuyBurst && !confirmStats.hasLargeSellBurst);

    final tradeLongOk =
        !enableTradeConfirmation ||
        (tradeCountOk && avgSizeOk && tradeLongDeltaOk && tradeLongBurstOk);

    final tradeShortOk =
        !enableTradeConfirmation ||
        (tradeCountOk && avgSizeOk && tradeShortDeltaOk && tradeShortBurstOk);

    final longSetup =
        _longArmed &&
        !inCooldown &&
        !inNoTrade &&
        canLongByDirection &&
        regimeLongOk &&
        strictWaeLongOk &&
        strictRsiLongOk &&
        parentLongOk &&
        tradeLongOk;

    final shortSetup =
        _shortArmed &&
        !inCooldown &&
        !inNoTrade &&
        canShortByDirection &&
        regimeShortOk &&
        strictWaeShortOk &&
        strictRsiShortOk &&
        parentShortOk &&
        tradeShortOk;

    _printStrictDebug(
      currentPrice: currentPrice,
      currentWae: currentWae,
      prevWae: prevWae,
      inCooldown: inCooldown,
      inNoTrade: inNoTrade,
      canLongByDirection: canLongByDirection,
      canShortByDirection: canShortByDirection,
      regimeLongOk: regimeLongOk,
      regimeShortOk: regimeShortOk,
      strictWaeLongOk: strictWaeLongOk,
      strictWaeShortOk: strictWaeShortOk,
      strictRsiLongOk: strictRsiLongOk,
      strictRsiShortOk: strictRsiShortOk,
      parentLongOk: parentLongOk,
      parentShortOk: parentShortOk,
      tradeCountOk: tradeCountOk,
      avgSizeOk: avgSizeOk,
      tradeLongDeltaOk: tradeLongDeltaOk,
      tradeShortDeltaOk: tradeShortDeltaOk,
      tradeLongBurstOk: tradeLongBurstOk,
      tradeShortBurstOk: tradeShortBurstOk,
      tradeLongOk: tradeLongOk,
      tradeShortOk: tradeShortOk,
      confirmStats: confirmStats,
      baselineStats: baselineStats,
      longSetup: longSetup,
      shortSetup: shortSetup,
    );

    if (longSetup) {
      if (useTrade) {
        placeOrder(isLong: true, currentPrice: currentPrice);
      }

      telegramClient.sendSignal(
        symbol: symbol,
        direction: 'LONG',
        waeDetails:
            'STRICT LONG (trendUp: ${currentWae.trendUp.toStringAsFixed(2)}, e1: ${currentWae.e1.toStringAsFixed(2)}, dz: ${currentWae.deadzone.toStringAsFixed(2)})',
        rsiDetails: 'STRICT BULLISH RSI',
        currentPrice: currentPrice,
        timeframe: timeframe,
      );

      print('\n${'=' * 60}');
      print(
        '✅ [${DateTime.now().toString().substring(11, 19)}] STRICT LONG для $symbol',
      );
      print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
      print(
        '   WAE: trendUp=${currentWae.trendUp.toStringAsFixed(2)} | e1=${currentWae.e1.toStringAsFixed(2)} | dz=${currentWae.deadzone.toStringAsFixed(2)}',
      );
      _printTapeStats('LONG', confirmStats);
      print('=' * 60);

      _lastSignalWasLong = true;
      _longArmed = false;
      _cooldownBarsRemaining = _cooldownBars;
      _recordSignalDirection(1);
      return;
    }

    if (shortSetup) {
      if (useTrade) {
        placeOrder(isLong: false, currentPrice: currentPrice);
      }

      telegramClient.sendSignal(
        symbol: symbol,
        direction: 'SHORT',
        waeDetails:
            'STRICT SHORT (trendDown: ${currentWae.trendDown.toStringAsFixed(2)}, e1: ${currentWae.e1.toStringAsFixed(2)}, dz: ${currentWae.deadzone.toStringAsFixed(2)})',
        rsiDetails: 'STRICT BEARISH RSI',
        currentPrice: currentPrice,
        timeframe: timeframe,
      );

      print('\n${'=' * 60}');
      print(
        '🛑 [${DateTime.now().toString().substring(11, 19)}] STRICT SHORT для $symbol',
      );
      print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
      print(
        '   WAE: trendDown=${currentWae.trendDown.toStringAsFixed(2)} | e1=${currentWae.e1.toStringAsFixed(2)} | dz=${currentWae.deadzone.toStringAsFixed(2)}',
      );
      _printTapeStats('SHORT', confirmStats);
      print('=' * 60);

      _lastSignalWasLong = false;
      _shortArmed = false;
      _cooldownBarsRemaining = _cooldownBars;
      _recordSignalDirection(-1);
      return;
    }
  }

  void _checkParentSignals() {
    if (_parentCandles.length < _minCandlesForSignal) return;

    final closes = _parentCandles.map((c) => c.close).toList();
    final highs = _parentCandles.map((c) => c.high).toList();
    final lows = _parentCandles.map((c) => c.low).toList();

    final waeSignal = _calculateWAE(closes, highs, lows);
    final rsiBullish = _calculateRsiMaBullish(closes);
    final rsiBearish = _calculateRsiMaBearish(closes);
    final currentPrice = closes.isNotEmpty ? closes.last : 0.0;

    if (waeSignal.isLong && rsiBullish) {
      if (parentLastSignalWasLong == false || parentLastSignalWasLong == null) {
        print('\n${'=' * 60}');
        print(
          '✅ [${DateTime.now().toString().substring(11, 19)}] РОДИТЕЛЬСКИЙ СИГНАЛ LONG для $symbol',
        );
        print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
        print(
          '   WAE: БЫЧИЙ (trendUp: ${waeSignal.trendUp.toStringAsFixed(2)})',
        );
        print('   RSI MA Cross: БЫЧИЙ (RSI > MA)');
        print('=' * 60);
        parentLastSignalWasLong = true;
      }
    } else if (waeSignal.isShort && rsiBearish) {
      if (parentLastSignalWasLong == true || parentLastSignalWasLong == null) {
        print('\n${'=' * 60}');
        print(
          '🛑 [${DateTime.now().toString().substring(11, 19)}] РОДИТЕЛЬСКИЙ СИГНАЛ SHORT для $symbol',
        );
        print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
        print(
          '   WAE: МЕДВЕЖИЙ (trendDown: ${waeSignal.trendDown.toStringAsFixed(2)})',
        );
        print('   RSI MA Cross: МЕДВЕЖИЙ (RSI < MA)');
        print('=' * 60);
        parentLastSignalWasLong = false;
      }
    }
  }

  void placeOrder({required bool isLong, required double currentPrice}) async {
    print(currentPrice);
    final sizing = PositionSizer.fromMarginUsd(
      marginUsd: 20,
      leverage: 10,
      entryPrice: currentPrice,
      szDecimals: resolvedPerpMarket.szDecimals,
    );

    // var tick = resolvedPerpMarket.markPx.toString().split('.').last.length;
    var tick = 2;

    if (isLong) {
      print(
        await exchangeClient.placeEntryWithTpSl(
          asset: resolvedPerpMarket.asset,
          isCross: false,
          isBuy: true,
          entryPx: double.parse(currentPrice.toStringAsFixed(tick)),
          size: sizing.finalSize,
          takeProfitTriggerPx: double.parse(
            takeProfitPriceCalc(
              isBinance: false,
              leverage: 10,
              price: currentPrice,
              isBid: true,
            ).toStringAsFixed(tick),
          ),
          stopLossTriggerPx: double.parse(
            calculateStopLossPrice(
              isBid: true,
              price: currentPrice,
              leverage: 10,
              lossPercent: 10,
            ).toStringAsFixed(tick),
          ),
          groupAsNormalTpsl: true,
          entryOrderType: ActionBuilders.limitOrderType(tif: 'Gtc'),
          leverage: 10,
        ),
      );
    } else {
      print(
        await exchangeClient.placeEntryWithTpSl(
          isCross: false,
          asset: resolvedPerpMarket.asset,
          isBuy: false,
          entryPx: double.parse(currentPrice.toStringAsFixed(tick)),
          size: sizing.finalSize,
          takeProfitTriggerPx: double.parse(
            takeProfitPriceCalc(
              isBinance: false,
              leverage: 10,
              price: currentPrice,
              isBid: false,
            ).toStringAsFixed(tick),
          ),
          stopLossTriggerPx: double.parse(
            calculateStopLossPrice(
              isBid: false,
              price: currentPrice,
              leverage: 10,
              lossPercent: 10,
            ).toStringAsFixed(tick),
          ),
          groupAsNormalTpsl: true,
          entryOrderType: ActionBuilders.limitOrderType(tif: 'Gtc'),
          leverage: 10,
        ),
      );
    }
  }

  WAESignal _calculateWAE(
    List<double> closes,
    List<double> highs,
    List<double> lows,
  ) {
    const int waeSensitivity = 150;
    const int waeFastlength = 20;
    const int waeSlowlength = 40;
    const int channelLength = 20;
    const double waeMult = 2.0;

    if (closes.length < waeSlowlength + 1 || closes.length < channelLength) {
      return WAESignal(false, false, 0.0, 0.0, 0.0, 0.0);
    }

    final double emaFastCurrent = _calculateEMA(closes, waeFastlength);
    final double emaSlowCurrent = _calculateEMA(closes, waeSlowlength);
    final double macdCurrent = emaFastCurrent - emaSlowCurrent;

    final List<double> prevCloses = closes.sublist(0, closes.length - 1);
    final double emaFastPrev = _calculateEMA(prevCloses, waeFastlength);
    final double emaSlowPrev = _calculateEMA(prevCloses, waeSlowlength);
    final double macdPrev = emaFastPrev - emaSlowPrev;

    final double t1 = (macdCurrent - macdPrev) * waeSensitivity;

    final int bbStartIdx = closes.length - channelLength;
    final List<double> bbCloses = closes.sublist(bbStartIdx);

    final double basis = bbCloses.reduce((a, b) => a + b) / channelLength;
    final num sumSquares = bbCloses
        .map((c) => pow(c - basis, 2))
        .reduce((a, b) => a + b);
    final double dev = waeMult * sqrt(sumSquares / channelLength);
    final double e1 = 2 * dev;

    final double deadzone = _calculateRMAofTR(highs, lows, closes, 100) * 3.7;

    final double trendUp = (t1 >= 0) ? t1 : 0;
    final double trendDown = (t1 < 0) ? (-1 * t1) : 0;

    final bool waeLong =
        (trendUp > 0) &&
        (trendUp > e1) &&
        (e1 > deadzone) &&
        (trendUp > deadzone);

    final bool waeShort =
        (trendDown > 0) &&
        (trendDown > e1) &&
        (e1 > deadzone) &&
        (trendDown > deadzone);

    return WAESignal(waeLong, waeShort, e1, deadzone, trendUp, trendDown);
  }

  double _calculateRMAofTR(
    List<double> highs,
    List<double> lows,
    List<double> closes,
    int period,
  ) {
    if (highs.length < period + 1 ||
        lows.length < period + 1 ||
        closes.length < period + 1) {
      return 0.0;
    }

    final List<double> trueRanges = [];
    for (int i = 1; i < highs.length; i++) {
      final double hl = highs[i] - lows[i];
      final double hc = (highs[i] - closes[i - 1]).abs();
      final double lc = (lows[i] - closes[i - 1]).abs();
      trueRanges.add([hl, hc, lc].reduce((a, b) => a > b ? a : b));
    }

    if (trueRanges.length < period) return 0.0;

    final double alpha = 1.0 / period;
    double rma = trueRanges.sublist(0, period).reduce((a, b) => a + b) / period;

    for (int i = period; i < trueRanges.length; i++) {
      rma = alpha * trueRanges[i] + (1 - alpha) * rma;
    }

    return rma;
  }

  double _calculateRMA(List<double> data, int period, int index) {
    final double alpha = 1.0 / period;
    double rma =
        data.sublist(index - period + 1, index + 1).reduce((a, b) => a + b) /
        period;

    for (int i = index - period + 1; i <= index; i++) {
      rma = alpha * data[i] + (1 - alpha) * rma;
    }

    return rma;
  }

  RsiData _calculateRsiComponents(List<double> closes) {
    const int rsiLength = 14;
    const int maLength = 14;

    if (closes.length < rsiLength + maLength) {
      return RsiData([], [], 0);
    }

    final List<double> changes = [];
    for (int i = 1; i < closes.length; i++) {
      changes.add(closes[i] - closes[i - 1]);
    }

    final List<double> gain = changes.map((c) => c > 0 ? c : 0.0).toList();
    final List<double> loss = changes.map((c) => c < 0 ? -c : 0.0).toList();

    final List<double> rsiValues = [];
    for (int i = rsiLength - 1; i < gain.length; i++) {
      final double avgGain = _calculateRMA(gain, rsiLength, i);
      final double avgLoss = _calculateRMA(loss, rsiLength, i);

      if (avgLoss == 0) {
        rsiValues.add(100.0);
      } else {
        final double rs = avgGain / avgLoss;
        rsiValues.add(100.0 - (100.0 / (1.0 + rs)));
      }
    }

    final List<double> rsiMaValues = [];
    for (int i = maLength - 1; i < rsiValues.length; i++) {
      double sum = 0.0;
      for (int j = 0; j < maLength; j++) {
        sum += rsiValues[i - j];
      }
      rsiMaValues.add(sum / maLength);
    }

    return RsiData(rsiValues, rsiMaValues, rsiMaValues.length);
  }

  bool _calculateRsiMaBullish(List<double> closes) {
    final RsiData data = _calculateRsiComponents(closes);
    if (data.length == 0) return false;

    final double currentRsi = data.rsiValues.last;
    final double currentRsiMa = data.rsiMaValues.last;
    return currentRsi > currentRsiMa;
  }

  bool _calculateRsiMaBearish(List<double> closes) {
    final RsiData data = _calculateRsiComponents(closes);
    if (data.length == 0) return false;

    final double currentRsi = data.rsiValues.last;
    final double currentRsiMa = data.rsiMaValues.last;
    return currentRsi < currentRsiMa;
  }

  double _calculateEMA(List<double> prices, int period) {
    if (prices.length < period) return 0.0;

    int startIdx = prices.length - period * 2;
    if (startIdx < 0) startIdx = 0;
    final List<double> relevantPrices = prices.sublist(startIdx);

    final double multiplier = 2.0 / (period + 1);
    double ema =
        relevantPrices.sublist(0, period).reduce((a, b) => a + b) / period;

    for (int i = period; i < relevantPrices.length; i++) {
      ema = (relevantPrices[i] * multiplier) + (ema * (1 - multiplier));
    }

    return ema;
  }

  String _mark(bool value) => value ? '✅' : '❌';

  void _printStrictDebug({
    required double currentPrice,
    required WAESignal currentWae,
    required WAESignal prevWae,

    required bool inCooldown,
    required bool inNoTrade,

    required bool canLongByDirection,
    required bool canShortByDirection,

    required bool regimeLongOk,
    required bool regimeShortOk,

    required bool strictWaeLongOk,
    required bool strictWaeShortOk,

    required bool strictRsiLongOk,
    required bool strictRsiShortOk,

    required bool parentLongOk,
    required bool parentShortOk,

    required bool tradeCountOk,
    required bool avgSizeOk,
    required bool tradeLongDeltaOk,
    required bool tradeShortDeltaOk,
    required bool tradeLongBurstOk,
    required bool tradeShortBurstOk,
    required bool tradeLongOk,
    required bool tradeShortOk,

    required TapeStats confirmStats,
    required TapeStats baselineStats,

    required bool longSetup,
    required bool shortSetup,
  }) {
    if (!debugStrictConditions) return;

    print('\n${'-' * 74}');
    print('DEBUG $symbol | ${DateTime.now().toString().substring(11, 19)}');
    print('price=${currentPrice.toStringAsFixed(2)}');

    print(
      'WAE current: long=${currentWae.isLong} short=${currentWae.isShort} '
      'trendUp=${currentWae.trendUp.toStringAsFixed(2)} '
      'trendDown=${currentWae.trendDown.toStringAsFixed(2)} '
      'e1=${currentWae.e1.toStringAsFixed(2)} '
      'deadzone=${currentWae.deadzone.toStringAsFixed(2)}',
    );

    print(
      'WAE prev: trendUp=${prevWae.trendUp.toStringAsFixed(2)} '
      'trendDown=${prevWae.trendDown.toStringAsFixed(2)} '
      'e1=${prevWae.e1.toStringAsFixed(2)} '
      'deadzone=${prevWae.deadzone.toStringAsFixed(2)}',
    );

    print(
      'State: '
      'longArmed=${_mark(_longArmed)} '
      'shortArmed=${_mark(_shortArmed)} '
      'cooldownClear=${_mark(!inCooldown)} '
      'noTradeClear=${_mark(!inNoTrade)}',
    );

    print(
      'Direction gate: '
      'canLong=${_mark(canLongByDirection)} '
      'canShort=${_mark(canShortByDirection)} '
      'lastSignal=$_lastSignalWasLong',
    );

    print(
      'Regime filter: '
      'long=${_mark(regimeLongOk)} '
      'short=${_mark(regimeShortOk)}',
    );

    print(
      'Strict WAE: '
      'long=${_mark(strictWaeLongOk)} '
      'short=${_mark(strictWaeShortOk)}',
    );

    print(
      'Strict RSI: '
      'long=${_mark(strictRsiLongOk)} '
      'short=${_mark(strictRsiShortOk)}',
    );

    print(
      'Parent gate: '
      'long=${_mark(parentLongOk)} '
      'short=${_mark(parentShortOk)} '
      'parentLast=$parentLastSignalWasLong '
      'useParentFilter=$useParentFilter',
    );

    print(
      'Tape confirm(${_confirmWindowSeconds}s): '
      'count=${confirmStats.tradeCount} '
      'delta=${confirmStats.delta.toStringAsFixed(4)} '
      'deltaRatio=${confirmStats.deltaRatio.toStringAsFixed(3)} '
      'avgSize=${confirmStats.avgTradeSize.toStringAsFixed(4)} '
      'buyBurst=${confirmStats.hasLargeBuyBurst} '
      'sellBurst=${confirmStats.hasLargeSellBurst}',
    );

    print(
      'Tape baseline(${_baselineWindowSeconds}s): '
      'count=${baselineStats.tradeCount} '
      'avgSize=${baselineStats.avgTradeSize.toStringAsFixed(4)}',
    );

    print(
      'Tape gates common: '
      'tradeCountOk=${_mark(tradeCountOk)} '
      'avgSizeOk=${_mark(avgSizeOk)}',
    );

    print(
      'Tape gates long: '
      'deltaOk=${_mark(tradeLongDeltaOk)} '
      'burstOk=${_mark(tradeLongBurstOk)} '
      'final=${_mark(tradeLongOk)}',
    );

    print(
      'Tape gates short: '
      'deltaOk=${_mark(tradeShortDeltaOk)} '
      'burstOk=${_mark(tradeShortBurstOk)} '
      'final=${_mark(tradeShortOk)}',
    );

    print(
      'FINAL: '
      'longSetup=${_mark(longSetup)} '
      'shortSetup=${_mark(shortSetup)}',
    );
    print('${'-' * 74}');
  }

  void _printCurrentState(WAESignal wae, bool rsiBull, bool rsiBear) {
    if (wae.isLong || wae.isShort || rsiBull || rsiBear) {
      print(
        'Состояние: '
        'WAE-L=${wae.isLong ? "✓" : "✗"} '
        'WAE-S=${wae.isShort ? "✓" : "✗"} | '
        'RSI>MA=${rsiBull ? "✓" : "✗"} '
        'RSI<MA=${rsiBear ? "✓" : "✗"} | '
        'e1=${wae.e1.toStringAsFixed(2)} '
        'dz=${wae.deadzone.toStringAsFixed(2)}',
      );
    }
  }

  void dispose() {
    _channel?.sink.close();
    _parentChannel?.sink.close();
    _tradeChannel?.sink.close();
    print('Бот остановлен.');
  }
}
