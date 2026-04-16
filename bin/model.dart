class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int index;

  Candle(this.time, this.open, this.high, this.low, this.close, this.volume, this.index,);

  @override
  String toString() =>
      '[${index}] ${time.toIso8601String()} O=${open.toStringAsFixed(2)} H=${high.toStringAsFixed(2)} L=${low.toStringAsFixed(2)} C=${close.toStringAsFixed(2)} V=${volume.toStringAsFixed(0)}';

  double get ohlc4 => (open + high + low + close) / 4;
}