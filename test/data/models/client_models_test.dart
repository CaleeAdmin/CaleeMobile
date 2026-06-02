import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_task.dart';

ClientEvent _event({
  required String id,
  bool recurring = false,
  String? seriesId,
}) =>
    ClientEvent(
      id: id,
      calendarId: '',
      serviceId: '',
      serviceName: '',
      title: '',
      startsAt: '',
      endsAt: '',
      allDay: false,
      source: '',
      recurring: recurring,
      seriesId: seriesId,
    );

ClientTask _task(String status) => ClientTask(
      id: '',
      calendarId: '',
      serviceId: '',
      serviceName: '',
      title: '',
      status: status,
      dueAt: null,
      completedAt: null,
      description: null,
      source: '',
    );

void main() {
  group('ClientEvent.writableEventId', () {
    test('returns seriesId for recurring event with seriesId', () {
      final event = _event(id: 'evt1', recurring: true, seriesId: 'series1');
      expect(event.writableEventId, 'series1');
    });

    test('returns id for non-recurring event', () {
      final event = _event(id: 'evt2', recurring: false, seriesId: 'series1');
      expect(event.writableEventId, 'evt2');
    });

    test('returns id for recurring event with null seriesId', () {
      final event = _event(id: 'evt3', recurring: true, seriesId: null);
      expect(event.writableEventId, 'evt3');
    });

    test('returns id for recurring event with blank seriesId', () {
      final event = _event(id: 'evt4', recurring: true, seriesId: '   ');
      expect(event.writableEventId, 'evt4');
    });
  });

  group('ClientTask.isCompleted', () {
    test('returns true for completed status', () {
      expect(_task('completed').isCompleted, isTrue);
    });

    test('returns false for needsaction status', () {
      expect(_task('needsaction').isCompleted, isFalse);
    });

    test('returns false for cancelled status', () {
      expect(_task('cancelled').isCompleted, isFalse);
    });

    test('returns false for inprocess status', () {
      expect(_task('inprocess').isCompleted, isFalse);
    });
  });

  group('ClientTask.statusLabel', () {
    test('needsaction maps to To do', () {
      expect(_task('needsaction').statusLabel, 'To do');
    });

    test('completed maps to Completed', () {
      expect(_task('completed').statusLabel, 'Completed');
    });

    test('cancelled maps to Cancelled', () {
      expect(_task('cancelled').statusLabel, 'Cancelled');
    });

    test('inprocess maps to In progress', () {
      expect(_task('inprocess').statusLabel, 'In progress');
    });

    test('unknown status returns the raw status value', () {
      expect(_task('someother').statusLabel, 'someother');
    });

    test('empty status returns Task', () {
      expect(_task('').statusLabel, 'Task');
    });
  });
}
