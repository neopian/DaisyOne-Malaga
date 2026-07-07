import 'package:intl/intl.dart';

final _dateFormatter = DateFormat('M월 d일 HH:mm');
final _pointFormatter = NumberFormat.decimalPattern();

String formatDate(DateTime? value) {
  if (value == null) return '-';
  return _dateFormatter.format(value.toLocal());
}

String formatPoints(int value) {
  return '${_pointFormatter.format(value)}P';
}
