import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:scalpex2/candle.dart';
import 'package:scalpex2/execution_manager.dart';
import 'package:scalpex2/mexc_client.dart';
import 'package:scalpex2/rsi_data.dart';
import 'package:scalpex2/telegram_signal_client.dart';
import 'package:scalpex2/wae_signal.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MexcFuturesSignalBot {
  final String symbol;
  final String timeframe;
  late TelegramSignalClient telegramClient;
  late WebSocketChannel _channel;
  final List<Candle> _candles = [];
  bool? _lastSignalWasLong;
  final ExecutionManager executionManager;

  MexcFuturesSignalBot({
    required this.symbol,
    this.timeframe = 'Min1',
    required String botToken,
    required String chatId,
    required this.executionManager,
  }) {
    telegramClient = TelegramSignalClient(botToken: botToken, chatId: chatId);
  }

  MexcClient mexcClient = MexcClient();

  // Структура для хранения свечи

  Future<void> connect() async {
    print('🔄 Подключение к фьючерсному WebSocket MEXC...');
    // Важно: используем фьючерсный эндпойнт[citation:1]
    final uri = Uri.parse('wss://contract.mexc.com/edge');
    _channel = WebSocketChannel.connect(uri);

    // Отправляем ping каждые 15 секунд для поддержания соединения[citation:1]
    Timer.periodic(Duration(seconds: 15), (_) {
      _channel.sink.add(jsonEncode({'method': 'ping'}));
    });

    _channel.stream.listen(
      _handleIncomingMessage,
      onError: (error) => print('❌ Ошибка WebSocket: $error'),
      onDone: () => print('📴 Соединение закрыто'),
    );

    final historicalData = await mexcClient.fetchKlineData(
      symbol: symbol.split('_').join(),
      interval: '15m',
      limit: 150,
    );

    _candles.addAll(historicalData);

    // Небольшая задержка перед подпиской
    await Future.delayed(Duration(seconds: 1));
    _subscribeToKline();
  }

  void _subscribeToKline() {
    // Формат подписки на K-line для фьючерсов[citation:1]
    final subscribeMsg = {
      'method': 'sub.kline',
      'param': {
        'symbol': symbol, // например, 'BTC_USDT'
        'interval': timeframe, // например, 'Min15'
      },
    };
    print('📡 Подписка на данные: $symbol ($timeframe)');
    _channel.sink.add(jsonEncode(subscribeMsg));
  }

  void _handleIncomingMessage(dynamic message) {
    // print(message);
    try {
      // 1. Проверяем, является ли сообщение строкой JSON (например, ping/pong)
      if (message is String) {
        final jsonMsg = jsonDecode(message);
        if (jsonMsg['channel'] == 'pong') {
          return; // Игнорируем ответы на ping
        }
        // Обрабатываем сообщения с данными (например, push.kline)
        if (jsonMsg['channel'] == 'push.kline') {
          _processKlineData(jsonMsg);
        }
      }
      // 2. Если сообщение бинарное (Protobuf) - десериализуем
      else if (message is List<int>) {
        print(
          '⚠️ Получены бинарные данные. Убедитесь в правильной десериализации Protobuf[citation:2][citation:6].',
        );
      }
    } catch (e) {
      print('Ошибка обработки сообщения: $e');
    }
  }

  void _processKlineData(dynamic klineData) {
    // Пример обработки JSON-данных свечи[citation:1]
    final candle = Candle(
      open: double.parse(klineData['data']['o'].toString()),
      high: double.parse(klineData['data']['h'].toString()),
      low: double.parse(klineData['data']['l'].toString()),
      close: double.parse(klineData['data']['c'].toString()),
      volume: double.parse(klineData['data']['q'].toString()),
      time: DateTime.fromMillisecondsSinceEpoch(klineData['data']['t'] * 1000),
    );

    // _candles.add(candle);
    // Храним ограниченное количество свечей для расчетов
    _addToBuffer(candle);

    if (_candles.length > 200) _candles.removeAt(0);

    if (_candles.length > 50) {
      // Ждем накопления данных
      _checkForSignals();
    }
  }

  void _addToBuffer(Candle marketData) {
    // Ищем, есть ли уже свеча с таким временем
    final existingIndex = _candles.indexWhere(
      (d) => d.time.isAtSameMomentAs(marketData.time),
    );

    if (existingIndex >= 0) {
      // Обновляем существующую свечу (текущая еще формируется)
      _candles[existingIndex] = marketData;
    } else {
      // Добавляем новую свечу
      _candles.add(marketData);

      // Поддерживаем размер буфера
      if (_candles.length > 200) {
        _candles.removeAt(0);
      }

      // Сортируем по времени (старые -> новые)
      _candles.sort((a, b) => a.time.compareTo(b.time));
    }
  }

  void _checkForSignals() {
    if (_candles.length < 150) return;

    List<double> closes = _candles.map((c) => c.close).toList();
    List<double> highs = _candles.map((c) => c.high).toList();
    List<double> lows = _candles.map((c) => c.low).toList();

    // 1. Получаем оба сигнала WAE
    WAESignal waeSignal = _calculateWAE(closes, highs, lows);

    // 2. Получаем ОБА сигнала RSI отдельно
    bool rsiBullish = _calculateRsiMaBullish(closes); // RSI > MA
    bool rsiBearish = _calculateRsiMaBearish(closes); // RSI < MA

    double currentPrice = closes.isNotEmpty ? closes.last : 0.0;

    // 3. Логика комбинированных сигналов
    if (waeSignal.isLong && rsiBullish) {
      if (_lastSignalWasLong == false || _lastSignalWasLong == null) {
        executionManager.placeOrderOnWall(
          symbol.split('_').first,
          'BID',
          currentPrice,
        );
        telegramClient.sendSignal(
          symbol: symbol,
          direction: 'LONG',
          waeDetails:
              'БЫЧИЙ (trendUp: ${waeSignal.trendUp.toStringAsFixed(2)})',
          rsiDetails: 'БЫЧИЙ (RSI > MA)',
          currentPrice: currentPrice,
          timeframe: timeframe,
        );
        print('\n${'=' * 60}');
        print(
          '✅ [${DateTime.now().toString().substring(11, 19)}] СИГНАЛ LONG для $symbol',
        );
        print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
        print(
          '   WAE: БЫЧИЙ (trendUp: ${waeSignal.trendUp.toStringAsFixed(2)})',
        );
        print('   RSI MA Cross: БЫЧИЙ (RSI > MA)');
        print('=' * 60);
        _lastSignalWasLong = true;
      }
    } else if (waeSignal.isShort && rsiBearish) {
      if (_lastSignalWasLong == true || _lastSignalWasLong == null) {
        executionManager.placeOrderOnWall(
          symbol.split('_').first,
          'ASK',
          currentPrice,
        );
        telegramClient.sendSignal(
          symbol: symbol,
          direction: 'SHORT',
          waeDetails:
              'МЕДВЕЖИЙ (trendDown: ${waeSignal.trendDown.toStringAsFixed(2)})',
          rsiDetails: 'МЕДВЕЖИЙ (RSI < MA)',
          currentPrice: currentPrice,
          timeframe: timeframe,
        );
        print('\n${'=' * 60}');
        print(
          '🛑 [${DateTime.now().toString().substring(11, 19)}] СИГНАЛ SHORT для $symbol',
        );
        print('   Текущая цена: \$${currentPrice.toStringAsFixed(2)}');
        print(
          '   WAE: МЕДВЕЖИЙ (trendDown: ${waeSignal.trendDown.toStringAsFixed(2)})',
        );
        print('   RSI MA Cross: МЕДВЕЖИЙ (RSI < MA)');
        print('=' * 60);
        _lastSignalWasLong = false;
      }
    }

    // 4. Отладка: вывод текущего состояния
    _printCurrentState(waeSignal, rsiBullish, rsiBearish);
  }

  // === РЕАЛИЗАЦИЯ ИНДИКАТОРОВ ===

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

    // --- РАСЧЕТ КОМПОНЕНТОВ ---
    int lastIdx = closes.length - 1;
    double emaFastCurrent = _calculateEMA(closes, waeFastlength);
    double emaSlowCurrent = _calculateEMA(closes, waeSlowlength);
    double macdCurrent = emaFastCurrent - emaSlowCurrent;

    List<double> prevCloses = closes.sublist(0, closes.length - 1);
    double emaFastPrev = _calculateEMA(prevCloses, waeFastlength);
    double emaSlowPrev = _calculateEMA(prevCloses, waeSlowlength);
    double macdPrev = emaFastPrev - emaSlowPrev;

    double t1 = (macdCurrent - macdPrev) * waeSensitivity;

    // Расчет e1 (ширина полос Боллинджера)
    int bbStartIdx = closes.length - channelLength;
    List<double> bbCloses = closes.sublist(bbStartIdx);

    double basis = bbCloses.reduce((a, b) => a + b) / channelLength;
    num sumSquares = bbCloses
        .map((c) => pow(c - basis, 2))
        .reduce((a, b) => a + b);
    double dev = waeMult * sqrt(sumSquares / channelLength);
    double e1 = 2 * dev; // (basis + dev) - (basis - dev)

    // Расчет deadzone (мертвая зона)
    double deadzone = _calculateRMAofTR(highs, lows, closes, 100) * 3.7;

    // --- ЛОГИКА СИГНАЛОВ ---
    double trendUp = (t1 >= 0) ? t1 : 0;
    double trendDown = (t1 < 0) ? (-1 * t1) : 0;

    bool waeLong =
        (trendUp > 0) &&
        (trendUp > e1) &&
        (e1 > deadzone) &&
        (trendUp > deadzone);
    bool waeShort =
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

    // 1. Расчет True Range (TR) для каждой свечи
    List<double> trueRanges = [];
    for (int i = 1; i < highs.length; i++) {
      double hl = highs[i] - lows[i];
      double hc = (highs[i] - closes[i - 1]).abs();
      double lc = (lows[i] - closes[i - 1]).abs();
      trueRanges.add([hl, hc, lc].reduce((a, b) => a > b ? a : b));
    }

    // 2. Расчет RMA (Wilder's Moving Average) = EMA с α = 1/period
    // Первое значение RMA - простое среднее
    if (trueRanges.length < period) return 0.0;

    double alpha = 1.0 / period;
    double rma = trueRanges.sublist(0, period).reduce((a, b) => a + b) / period;

    // Последующие значения: RMA = α * TR + (1 - α) * предыдущий RMA
    for (int i = period; i < trueRanges.length; i++) {
      rma = alpha * trueRanges[i] + (1 - alpha) * rma;
    }

    return rma;
  }

  double _calculateRMA(List<double> data, int period, int index) {
    double alpha = 1.0 / period;
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

    // Расчет изменений
    List<double> changes = [];
    for (int i = 1; i < closes.length; i++) {
      changes.add(closes[i] - closes[i - 1]);
    }

    // Gain/Loss
    List<double> gain = changes.map((c) => c > 0 ? c : 0.0).toList();
    List<double> loss = changes.map((c) => c < 0 ? -c : 0.0).toList();

    // RSI с RMA (как в Pine Script)
    List<double> rsiValues = [];
    for (int i = rsiLength - 1; i < gain.length; i++) {
      double avgGain = _calculateRMA(gain, rsiLength, i);
      double avgLoss = _calculateRMA(loss, rsiLength, i);

      if (avgLoss == 0) {
        rsiValues.add(100.0);
      } else {
        double rs = avgGain / avgLoss;
        rsiValues.add(100.0 - (100.0 / (1.0 + rs)));
      }
    }

    // SMA от RSI
    List<double> rsiMaValues = [];
    for (int i = maLength - 1; i < rsiValues.length; i++) {
      double sum = 0.0;
      for (int j = 0; j < maLength; j++) {
        sum += rsiValues[i - j];
      }
      rsiMaValues.add(sum / maLength);
    }

    return RsiData(rsiValues, rsiMaValues, rsiMaValues.length);
  }

  // 3. Бычий сигнал: RSI > MA (точная реализация из Pine Script)
  bool _calculateRsiMaBullish(List<double> closes) {
    RsiData data = _calculateRsiComponents(closes);

    if (data.length == 0) return false;

    // Последние значения
    double currentRsi = data.rsiValues.last;
    double currentRsiMa = data.rsiMaValues.last;

    // Бычий сигнал: RSI выше своей MA
    return currentRsi > currentRsiMa;
  }

  // 4. Медвежий сигнал: RSI < MA (отдельная функция для точности)
  bool _calculateRsiMaBearish(List<double> closes) {
    RsiData data = _calculateRsiComponents(closes);

    if (data.length == 0) return false;

    // Последние значения
    double currentRsi = data.rsiValues.last;
    double currentRsiMa = data.rsiMaValues.last;

    // Медвежий сигнал: RSI ниже своей MA
    return currentRsi < currentRsiMa;
  }

  // 5. Вспомогательная функция RMA (остается без изменений)

  double _calculateEMA(List<double> prices, int period) {
    if (prices.length < period) return 0.0;

    // Берем только последние period * 2 значений для расчета (достаточно для точности)
    int startIdx = prices.length - period * 2;
    if (startIdx < 0) startIdx = 0;
    List<double> relevantPrices = prices.sublist(startIdx);

    double multiplier = 2.0 / (period + 1);
    double ema =
        relevantPrices.sublist(0, period).reduce((a, b) => a + b) / period;

    for (int i = period; i < relevantPrices.length; i++) {
      ema = (relevantPrices[i] * multiplier) + (ema * (1 - multiplier));
    }

    return ema;
  }

  void _printCurrentState(WAESignal wae, bool rsiBull, bool rsiBear) {
    // Только если есть хотя бы один активный компонент
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
    _channel.sink.close();
    print('Бот остановлен.');
  }
}
