import 'package:caleesync/models/ios_import_provider.dart';
import 'package:caleesync/services/ios_import_calendar_guide_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = IosImportCalendarGuideService();

  test('each provider has non-empty guide steps', () {
    for (final provider in IosImportProvider.values) {
      final steps = service.stepsFor(provider);
      expect(steps, isNotEmpty);
      expect(steps.every((step) => step.trim().isNotEmpty), isTrue);
    }
  });

  test('each provider has helper and warning text', () {
    for (final provider in IosImportProvider.values) {
      expect(service.helperTextFor(provider).trim(), isNotEmpty);
      expect(service.warningTextFor(provider).trim(), isNotEmpty);
    }
  });
}
