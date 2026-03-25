import 'package:caleesync/models/ios_import_provider.dart';

class IosImportCalendarGuideService {
  List<String> stepsFor(IosImportProvider provider) {
    switch (provider) {
      case IosImportProvider.iCloud:
        return const [
          'On iPhone, open Calendar and tap Calendars.',
          'Tap the info button next to the calendar you want to share.',
          'Enable Public Calendar, then tap Share Link.',
          'Copy the link and paste it here in Calee.',
        ];
      case IosImportProvider.google:
        return const [
          'Open Google Calendar on the web.',
          'Open Settings for the target calendar.',
          'Find Secret address in iCal format and copy it.',
          'Paste that iCal URL here in Calee.',
        ];
      case IosImportProvider.outlook:
        return const [
          'Open Outlook on the web.',
          'Go to Settings, then Shared calendars or Publish calendar.',
          'Publish the calendar and copy the ICS link.',
          'Paste that ICS URL here in Calee.',
        ];
    }
  }

  String helperTextFor(IosImportProvider provider) {
    switch (provider) {
      case IosImportProvider.iCloud:
        return 'Use Apple\'s public calendar link flow to import iCloud events as a read-only subscription in Calee.';
      case IosImportProvider.google:
        return 'Use the calendar\'s Secret address in iCal format to import it into Calee as read-only.';
      case IosImportProvider.outlook:
        return 'Use Outlook\'s published ICS link to add the calendar into Calee as a read-only subscription.';
    }
  }

  String warningTextFor(IosImportProvider provider) {
    switch (provider) {
      case IosImportProvider.iCloud:
        return 'iCloud public links are readable by anyone with the URL. Keep the link private. Imported calendars are read-only.';
      case IosImportProvider.google:
        return 'Google secret iCal addresses should be treated like passwords. Imported calendars are read-only.';
      case IosImportProvider.outlook:
        return 'Outlook published links are read-only feeds. Anyone with the link may view events.';
    }
  }

  String? exampleUrlFor(IosImportProvider provider) {
    switch (provider) {
      case IosImportProvider.iCloud:
        return 'https://pXX-caldav.icloud.com/published/2/example-token';
      case IosImportProvider.google:
        return 'https://calendar.google.com/calendar/ical/example%40group.calendar.google.com/private-abc/basic.ics';
      case IosImportProvider.outlook:
        return 'https://outlook.office365.com/owa/calendar/example/calendar.ics';
    }
  }
}
