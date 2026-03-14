class TapeTrade {
  final double price;
  final double size;
  final bool isBuyAggressor;
  final DateTime time;

  TapeTrade({
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
