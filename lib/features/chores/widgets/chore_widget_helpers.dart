import '../../../data/api/calee_hub_client.dart';

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

String? choreRecurrenceToRrule(String? value) {
  switch (value) {
    case 'daily':
      return 'FREQ=DAILY';
    case 'weekly':
      return 'FREQ=WEEKLY';
    case 'monthly':
      return 'FREQ=MONTHLY';
    default:
      return null;
  }
}

String? choreRruleToRecurrence(String? value) {
  final rrule = value?.trim().toUpperCase();
  if (rrule == 'FREQ=DAILY') return 'daily';
  if (rrule == 'FREQ=WEEKLY') return 'weekly';
  if (rrule == 'FREQ=MONTHLY') return 'monthly';
  return null;
}

String choreErrorMessage(Object error, String fallback) {
  if (error is CaleeHubException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return fallback;
}

bool isValidChorePoints(int? points) =>
    points != null && points >= 1 && points <= 100;
