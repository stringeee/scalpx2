import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:scalpex2/config.dart';
import 'package:scalpex2/entities/asset_snapshot.dart';
import 'package:scalpex2/entities/config_model.dart';
import 'package:scalpex2/entities/currency_snapshot.dart';
import 'package:scalpex2/entities/order_snapshot.dart';
import 'package:scalpex2/entities/position_snapshot.dart';
import 'package:scalpex2/injector/injector.dart';
import 'package:scalpex2/shared/program.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'interface/iorder_book_source.dart';
import 'package:crypto/crypto.dart';

class HyperliquidWsSource implements IOrderBookSource {
  WebSocketChannel? _channel;
  WebSocketChannel? _mexcChannel;
  IOWebSocketChannel? _binanceChannel; // НОВОЕ: Binance канал
  bool _disposed = false;
  bool _isConnecting = false;
  bool _isMexcConnecting = false;
  bool _isBinanceConnecting = false; // НОВОЕ: флаг подключения Binance
  int _mexcReconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _mexcReconnectTimer;
  Timer? _binanceReconnectTimer; // НОВОЕ: таймер переподключения Binance
  final int _maxReconnectAttempts = 10;
  final Duration _initialReconnectDelay = Duration(seconds: 1);

  final ProfileConfig _config;

  final StreamController<CurrencySnapshot> _currencyController =
      StreamController<CurrencySnapshot>.broadcast();

  final StreamController<OrderSnapshot> _orderController =
      StreamController<OrderSnapshot>.broadcast();

  final StreamController<PositionSnapshot> _positionController =
      StreamController<PositionSnapshot>.broadcast();

  final StreamController<AssetSnapshot> _assetController =
      StreamController<AssetSnapshot>.broadcast();

  @override
  Stream<AssetSnapshot> get onAsset => _assetController.stream;

  @override
  Stream<CurrencySnapshot> get onCurrency => _currencyController.stream;

  @override
  Stream<OrderSnapshot> get onOrder => _orderController.stream;

  @override
  Stream<PositionSnapshot> get onPosition => _positionController.stream;

  HyperliquidWsSource(ProfileConfig config, {int topN = 20}) : _config = config;

  @override
  Future<void> start() async {
    if (_disposed) return;

    await Future.wait([_connectMexc()], eagerError: false);
  }

  Future<void> _connectMexc() async {
    if (_disposed || _isMexcConnecting) return;

    _isMexcConnecting = true;

    try {
      print('[WS-MEXC] Connecting to MEXC...');

      _mexcChannel = WebSocketChannel.connect(
        Uri.parse('wss://contract.mexc.com/edge'),
      );

      _mexcChannel!.stream.listen(
        (data) {
          _handleCurrency(data);
          _handlePositionsAndOrder(data);
        },
        onError: _handleMexcError,
        onDone: _handleMexcDone,
      );

      final currencySub = {
        "method": "sub.deal",
        "param": {
          "symbol": injector<Program>().mapToMexcSymbol(Config.mexcSymbol),
        },
      };
      _mexcChannel!.sink.add(json.encode(currencySub));

      // Сбрасываем счетчик переподключений при успешном соединении
      _mexcReconnectAttempts = 0;
      _isMexcConnecting = false;

      int timeStamp = DateTime.now().millisecondsSinceEpoch;
      var hmacSha256 = Hmac(sha256, utf8.encode(_config.secretKey));
      var digest = hmacSha256.convert(
        utf8.encode('${_config.nativeMexcApiKey}$timeStamp'),
      );

      Map x = {
        "method": "login",
        "param": {
          "apiKey": _config.nativeMexcApiKey,
          "reqTime": timeStamp,
          "signature": digest.toString(),
        },
      };

      _mexcChannel!.sink.add(jsonEncode(x));
      print('[WS-MEXC] Connected successfully to MEXC');

      _startKeepAlive();

      // Listen for messages
    } catch (e) {
      print('[WS-MEXC] Connection error: $e');
      _isMexcConnecting = false;
      _scheduleMexcReconnect();
    }
  }

  void _handlePositionsAndOrder(dynamic message) {
    final data = json.decode(message.toString());
    final channel = data['channel'];

    if (channel == 'rs.login') {
      if (data['data'] == 'success') {
        Map x = {
          "method": "personal.filter",
          "param": {
            "filters": [
              {"filter": "order"},
              {"filter": "position"},
              {"filter": "asset"},
            ],
          },
        };
        _mexcChannel!.sink.add(jsonEncode(x));
      }
    }

    if (channel == 'push.personal.asset') {
      try {
        AssetSnapshot assetSnapshot = AssetSnapshot.fromJson(data['data']);
        _assetController.add(assetSnapshot);
        print('[ASSET_UPDATE] ${assetSnapshot.toFormattedString()}');
      } catch (e) {
        print('Failed to parse asset: $e');
        print('Raw asset data: ${data['data']}');
      }
    }
    if (channel == 'push.personal.order') {
      try {
        OrderSnapshot orderSnapshot = OrderSnapshot.fromJson(data['data']);
        _orderController.add(orderSnapshot);
      } catch (e) {
        print('Failed to parse order: $e');
      }
    }

    if (channel == 'push.personal.position') {
      try {
        PositionSnapshot positionSnapshot = PositionSnapshot.fromJson(
          data['data'],
        );
        _positionController.add(positionSnapshot);
      } catch (e) {
        print('Failed to parse position: $e');
      }
    }
  }

  void _handleCurrency(dynamic message) {
    try {
      final data = json.decode(message.toString());
      final channel = data['channel'];

      if (channel == 'push.deal') {
        List prices = (data['data'] as List).map((s) => s['p']).toList();

        double price = (prices.reduce((v, s) => v + s) / prices.length) + 0.0;

        _currencyController.add(
          CurrencySnapshot(symbol: data['symbol'], price: price),
        );
      }
    } catch (e) {
      print('[MX] Parse error: $e');
    }
  }

  void _handleMexcError(dynamic error) {
    print('[WS-MEXC] WebSocket error: $error');
    _scheduleMexcReconnect();
  }

  void _handleMexcDone() {
    print('[WS-MEXC] WebSocket connection closed');
    if (!_disposed) {
      _scheduleMexcReconnect();
    }
  }

  void _scheduleMexcReconnect() {
    if (_disposed || _isMexcConnecting) return;

    _mexcReconnectAttempts++;

    if (_mexcReconnectAttempts > _maxReconnectAttempts) {
      print('[WS-MEXC] Max reconnection attempts reached. Giving up.');
      return;
    }

    final delay =
        _initialReconnectDelay *
        math.pow(2, _mexcReconnectAttempts - 1).toInt();
    final maxDelay = Duration(seconds: 60);
    final actualDelay = delay.inSeconds > maxDelay.inSeconds ? maxDelay : delay;

    print(
      '[WS-MEXC] Scheduling reconnection in ${actualDelay.inSeconds}s (attempt $_mexcReconnectAttempts/$_maxReconnectAttempts)',
    );

    _mexcReconnectTimer = Timer(actualDelay, () {
      if (!_disposed) {
        _connectMexc();
      }
    });
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();

    _keepAliveTimer = Timer.periodic(Duration(seconds: 29), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      try {
        if (_channel != null) {
          _channel!.sink.add(json.encode({'method': 'ping'}));
        }
        if (_mexcChannel != null) {
          _mexcChannel!.sink.add(json.encode({'method': 'ping'}));
        }
        // if (_binanceChannel != null) {
        //   // Binance не требует ping, но можно отправлять для поддержания соединения
        //   _binanceChannel!.sink.add(
        //     json.encode({"id": const Uuid().v1(), "method": "ping"}),
        //   );
        // }
      } catch (e) {
        print('[WS] Keepalive error: $e');
        // При ошибке keepalive запускаем переподключение
        if (_mexcChannel != null) _scheduleMexcReconnect();
      }
    });

    print('[WS] Keepalive timer started (HL, MEXC, BINANCE)');
  }

  Timer? _keepAliveTimer;

  @override
  void dispose() {
    _disposed = true;
    _isConnecting = false;
    _isMexcConnecting = false;
    _isBinanceConnecting = false; // НОВОЕ

    // Останавливаем все таймеры
    _reconnectTimer?.cancel();
    _mexcReconnectTimer?.cancel();
    _binanceReconnectTimer?.cancel(); // НОВОЕ

    _reconnectTimer = null;
    _mexcReconnectTimer = null;
    _binanceReconnectTimer = null; // НОВОЕ
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    try {
      _channel?.sink.close();
      _mexcChannel?.sink.close();
      _binanceChannel?.sink.close(); // НОВОЕ
    } catch (e) {
      print('[WS] Dispose error: $e');
    }

    _currencyController.close();
    _orderController.close();
    _positionController.close();

    print('[WS] Disposed all connections (HL, MEXC, BINANCE)');
  }

  // Методы для проверки состояния соединений

  bool get isConnecting => _isConnecting || _isMexcConnecting;
  int get mexcReconnectAttempts => _mexcReconnectAttempts;

  Future<void> reconnectMexc() async {
    print('[WS-MEXC] Manual reconnection requested');
    _mexcReconnectTimer?.cancel();
    await _connectMexc();
  }

  @override
  bool get isBinanceConnected =>
      _binanceChannel != null && !_disposed && !_isBinanceConnecting;

  @override
  bool get isHyperliquidConnected =>
      _channel != null && !_disposed && !_isConnecting;
  @override
  bool get isMexcConnected =>
      _mexcChannel != null && !_disposed && !_isMexcConnecting;
}
