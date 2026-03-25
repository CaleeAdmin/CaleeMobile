import 'package:flutter/material.dart';

enum IosImportProvider { iCloud, google, outlook }

extension IosImportProviderX on IosImportProvider {
  String get title {
    switch (this) {
      case IosImportProvider.iCloud:
        return 'iCloud';
      case IosImportProvider.google:
        return 'Google';
      case IosImportProvider.outlook:
        return 'Outlook / Exchange';
    }
  }

  String get subtitle {
    switch (this) {
      case IosImportProvider.iCloud:
        return 'Import an Apple public calendar link.';
      case IosImportProvider.google:
        return 'Import a Google secret iCal address.';
      case IosImportProvider.outlook:
        return 'Import a published Outlook ICS link.';
    }
  }

  IconData get icon {
    switch (this) {
      case IosImportProvider.iCloud:
        return Icons.cloud_outlined;
      case IosImportProvider.google:
        return Icons.g_mobiledata;
      case IosImportProvider.outlook:
        return Icons.email_outlined;
    }
  }

  String get submitLabel {
    switch (this) {
      case IosImportProvider.iCloud:
        return 'Import iCloud Calendar';
      case IosImportProvider.google:
        return 'Import Google Calendar';
      case IosImportProvider.outlook:
        return 'Import Outlook Calendar';
    }
  }

  String get urlLabel {
    switch (this) {
      case IosImportProvider.iCloud:
        return 'Public calendar URL';
      case IosImportProvider.google:
        return 'Secret iCal URL';
      case IosImportProvider.outlook:
        return 'Published ICS URL';
    }
  }
}
