import '../../../data/api/calee_hub_client.dart';
import '../../../shared/recurrence/calee_repeat_rule.dart';

export '../../../shared/recurrence/calee_repeat_rule.dart';

String formatChoreDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

DateTime? parseChoreDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.toLocal();
}

String choreRepeatValue(CaleeRepeatRule rule, {DateTime? anchorDate}) =>
    rule.label(anchorDate: anchorDate);

String? choreRecurrenceToRrule(CaleeRepeatRule rule, {DateTime? anchorDate}) =>
    rule.toRrule(anchorDate: anchorDate);

CaleeRepeatRule choreRruleToRecurrence(String? value, {DateTime? anchorDate}) =>
    CaleeRepeatRule.fromRrule(value, anchorDate: anchorDate);

String choreErrorMessage(Object error, String fallback) {
  if (error is CaleeHubException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return fallback;
}

bool isValidChorePoints(int? points) =>
    points != null && points >= 1 && points <= 100;
