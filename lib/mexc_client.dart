import 'package:dio/dio.dart';
import 'package:scalpex2/candle.dart';

class MexcClient {
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://fapi.binance.com',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  Future<List<Candle>> fetchKlineData({
    required String symbol,
    required String interval,
    int limit = 100,
  }) async {
    try {
      print(
        '📡 Запрос данных MEXC: $symbol, интервал: $interval, лимит: $limit',
      );

      final response = await _dio.get(
        '/fapi/v1/klines',
        queryParameters: {
          'symbol': symbol,
          'interval': interval,
          'limit': limit,
        },
      );

      if (response.statusCode != 200) {
        throw Exception('MEXC API ошибка: ${response.statusCode}');
      }

      final List<dynamic> klines = response.data;
      if (klines.isEmpty) {
        throw Exception('Нет данных от MEXC API');
      }

      final List<Candle> marketData = [];

      for (final kline in klines) {
        try {
          final marketDataPoint = Candle(
            open: double.parse(kline[1].toString()),
            high: double.parse(kline[2].toString()),
            low: double.parse(kline[3].toString()),
            close: double.parse(kline[4].toString()),
            volume: double.parse(kline[5].toString()),
            time: DateTime.fromMillisecondsSinceEpoch(kline[0]),
          );
          marketData.add(marketDataPoint);
        } catch (e) {
          print('⚠️ Ошибка парсинга свечи: $e');
          continue;
        }
      }

      // Сортируем по времени (старые -> новые)
      marketData.sort((a, b) => a.time.compareTo(b.time));

      print('✅ Получено ${marketData.length} свечей с MEXC');
      print('   Первая свеча: ${marketData.first.time}');
      print('   Последняя свеча: ${marketData.last.time}');

      return marketData;
    } on DioException catch (e) {
      if (e.response != null) {
        print(
          '❌ MEXC API ошибка: ${e.response?.statusCode} - ${e.response?.data}',
        );
        throw Exception(
          'MEXC API: ${e.response?.statusCode} - ${e.response?.data}',
        );
      } else {
        print('❌ Сетевая ошибка: ${e.message}');
        throw Exception('Сетевая ошибка: ${e.message}');
      }
    } catch (e) {
      print('❌ Неизвестная ошибка: $e');
      throw Exception('Ошибка получения данных: $e');
    }
  }

  Future<Map<String, dynamic>> getExchangeInfo(String symbol) async {
    try {
      final response = await _dio.get(
        '/api/v3/exchangeInfo',
        queryParameters: {'symbol': symbol.toUpperCase()},
      );

      return response.data;
    } catch (e) {
      print('Ошибка получения информации о бирже: $e');
      return {};
    }
  }

  Future<Map<String, dynamic>> getTicker(String symbol) async {
    try {
      final response = await _dio.get(
        '/api/v3/ticker/24hr',
        queryParameters: {'symbol': symbol.toUpperCase()},
      );

      return response.data is Map ? response.data : {};
    } catch (e) {
      print('Ошибка получения тикера: $e');
      return {};
    }
  }
}
