class WAESignal {
  final bool isLong;
  final bool isShort;
  final double e1; // ширина полос Боллинджера
  final double deadzone; // мертвая зона
  final double trendUp; // бычья компонента
  final double trendDown; // медвежья компонента

  WAESignal(
    this.isLong,
    this.isShort,
    this.e1,
    this.deadzone,
    this.trendUp,
    this.trendDown,
  );
}
