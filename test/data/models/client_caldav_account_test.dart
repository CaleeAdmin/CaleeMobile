import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/models/client_caldav_account.dart';

void main() {
  group('ClientCalDavAccount', () {
    test('maps backend password field to appPassword service credential', () {
      final account = ClientCalDavAccount.fromJson({
        'serviceId': 'portal',
        'serviceName': 'Calee Portal',
        'server': 'https://portal.calee.com.au',
        'username': 'user@example.com',
        'password': 'nextcloud-app-password',
        'description': 'Use this in Apple Calendar',
      });

      expect(account.serviceId, 'portal');
      expect(account.serviceName, 'Calee Portal');
      expect(account.server, 'https://portal.calee.com.au');
      expect(account.username, 'user@example.com');
      expect(account.appPassword, 'nextcloud-app-password');
      expect(account.description, 'Use this in Apple Calendar');
    });
  });
}
