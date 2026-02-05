import 'dart:io';

class Config {
  // Telegram настройки
  static String get telegramBotToken =>
      Platform.environment['TELEGRAM_BOT_TOKEN'] ??
      '8412594629:AAFSyVob1sIG4szV0XupcA0oVa6yhDFPmZQ';

  static String get telegramChatId =>
      Platform.environment['TELEGRAM_CHAT_ID'] ?? '469171720';

  // Trading настройки
  static const String symbol = 'ZECUSDT';
  static const String mexcSymbol = 'ZEC';
  static const double tickSize = 0.01;
  static const int tickThreshold = 15;

  // WebSocket URLs
  static const String wsBaseUrl = 'wss://stream.binance.com:9443/ws';

  static String get orderBookWsUrl =>
      '$wsBaseUrl/${symbol.toLowerCase()}@depth20@100ms';

  static String get tradeWsUrl => '$wsBaseUrl/${symbol.toLowerCase()}@trade';

  // Risk management
  static const double positionSizePercent = 1.0; // % от капитала
  static const double stopLossMultiplier = 1.5;
  static const double takeProfitMultiplier = 3.0;

  // Signal engine
  static const Duration candleInterval = Duration(milliseconds: 500);
  static const double volumeMultiplierThreshold = 1.5;
  static const double imbalanceThreshold = 0.3;
  static const double strongImbalanceThreshold = 0.7;
}
