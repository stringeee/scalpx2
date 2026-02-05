// telegram_client.dart
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class TelegramSignalClient {
  final String botToken;
  final String chatId;
  final String baseUrl = 'https://api.telegram.org/bot';

  // Для отслеживания, чтобы не спамить повторными сигналами
  DateTime? _lastLongSignalTime;
  DateTime? _lastShortSignalTime;
  final Duration _signalCooldown = Duration(minutes: 5); // Защита от спама

  // Статистика
  int _signalsSent = 0;

  TelegramSignalClient({required this.botToken, required this.chatId});

  // 1. Основной метод отправки сигнала
  Future<bool> sendSignal({
    required String symbol,
    required String direction, // 'LONG' или 'SHORT'
    required String waeDetails,
    required String rsiDetails,
    double? currentPrice,
    String? timeframe,
  }) async {
    // Проверка кулдауна
    if (!_canSendSignal(direction)) {
      print('⏸️  Сигнал $direction пропущен (кулдаун)');
      return false;
    }

    // Форматирование сообщения
    final message = _formatSignalMessage(
      symbol: symbol,
      direction: direction,
      waeDetails: waeDetails,
      rsiDetails: rsiDetails,
      currentPrice: currentPrice,
      timeframe: timeframe,
    );

    // Отправка в Telegram
    final success = await _sendToTelegram(message);

    if (success) {
      _signalsSent++;
      _updateLastSignalTime(direction);
      print('📤 Сигнал $direction отправлен в Telegram (#$_signalsSent)');
    }

    return success;
  }

  // 2. Отправка тестового сообщения
  Future<bool> sendTestMessage() async {
    final testMessage =
        '''
🚀 Бот запущен и готов к работе!
Время: ${DateTime.now()}
Статус: Ожидание сигналов...
    ''';

    return await _sendToTelegram(testMessage);
  }

  // 3. Отправка сообщения об ошибке
  Future<bool> sendError(String error) async {
    final errorMessage =
        '''
⚠️ ОШИБКА В БОТЕ
Время: ${DateTime.now()}
Ошибка: $error
    ''';

    return await _sendToTelegram(errorMessage);
  }

  // 4. Отправка статистики
  Future<bool> sendStats({
    required int uptimeHours,
    required int candlesProcessed,
  }) async {
    final statsMessage =
        '''
📊 СТАТИСТИКА БОТА
Время работы: $uptimeHours ч
Обработано свечей: $candlesProcessed
Отправлено сигналов: $_signalsSent
Последнее обновление: ${DateTime.now()}
    ''';

    return await _sendToTelegram(statsMessage);
  }

  // --- ПРИВАТНЫЕ МЕТОДЫ ---

  Future<bool> _sendToTelegram(String text) async {
    try {
      final url = Uri.parse('$baseUrl$botToken/sendMessage');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': chatId,
          'text': text,
          // 'parse_mode': 'HTML',
          'disable_notification': false,
        }),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        print('❌ Ошибка Telegram API: ${response.statusCode}');
        print('Ответ: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Ошибка отправки в Telegram: $e');
      return false;
    }
  }

  String _formatSignalMessage({
    required String symbol,
    required String direction,
    required String waeDetails,
    required String rsiDetails,
    double? currentPrice,
    String? timeframe,
  }) {
    final emoji = direction == 'LONG' ? '✅' : '🛑';
    final time = DateTime.now().toString().substring(11, 19);

    return '''
$emoji СИГНАЛ $direction
┌─────────────
├ Пара: $symbol
├ Таймфрейм: ${timeframe ?? '15M'}
├ Время: $time
├ Цена: ${currentPrice?.toStringAsFixed(2) ?? 'N/A'}
├─────────────
├ WAE: $waeDetails
├ RSI MA Cross: $rsiDetails
└─────────────

#${symbol.replaceAll('_', '')} #${direction.toLowerCase()}
    ''';
  }

  bool _canSendSignal(String direction) {
    final now = DateTime.now();

    if (direction == 'LONG') {
      if (_lastLongSignalTime != null) {
        final difference = now.difference(_lastLongSignalTime!);
        return difference > _signalCooldown;
      }
    } else if (direction == 'SHORT') {
      if (_lastShortSignalTime != null) {
        final difference = now.difference(_lastShortSignalTime!);
        return difference > _signalCooldown;
      }
    }

    return true;
  }

  void _updateLastSignalTime(String direction) {
    final now = DateTime.now();
    if (direction == 'LONG') {
      _lastLongSignalTime = now;
    } else if (direction == 'SHORT') {
      _lastShortSignalTime = now;
    }
  }

  // Геттер для статистики
  int get signalsSent => _signalsSent;
}
