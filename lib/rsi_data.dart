class RsiData {
  final List<double> rsiValues; // история RSI
  final List<double> rsiMaValues; // история RSI MA
  final int length;

  RsiData(this.rsiValues, this.rsiMaValues, this.length);
}
