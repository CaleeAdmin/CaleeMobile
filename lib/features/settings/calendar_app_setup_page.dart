import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

class CalendarAppSetupPage extends StatefulWidget {
  const CalendarAppSetupPage({
    required this.hubClient,
    required this.accessToken,
    required this.service,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientService service;

  @override
  State<CalendarAppSetupPage> createState() => _CalendarAppSetupPageState();
}

class _CalendarAppSetupPageState extends State<CalendarAppSetupPage> {
  late Future<_CalDavAccount> _future;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_CalDavAccount> _load() async {
    final path = '/client/v1/services/${Uri.encodeComponent(widget.service.id)}/caldav-account';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 25)
      ..idleTimeout = const Duration(seconds: 30);

    try {
      final request = await client.getUrl(widget.hubClient.baseUri.resolve(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${widget.accessToken}',
      );

      final response = await request.close().timeout(const Duration(seconds: 25));
      final body = await response.transform(utf8.decoder).join();
      final decoded = body.isEmpty ? null : jsonDecode(body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map<String, dynamic>
            ? decoded['error'] is Map<String, dynamic>
                ? (decoded['error'] as Map<String, dynamic>)['message']
                : decoded['message']
            : null;
        throw _SetupException(
          message is String && message.trim().isNotEmpty
              ? message.trim()
              : 'Could not load Calendar App Setup.',
        );
      }

      if (decoded is! Map<String, dynamic> || decoded['data'] is! Map<String, dynamic>) {
        throw const _SetupException('Invalid Calendar App Setup response.');
      }

      return _CalDavAccount.fromJson(decoded['data'] as Map<String, dynamic>);
    } on _SetupException {
      rethrow;
    } on TimeoutException {
      throw const _SetupException('Check your connection and try again.');
    } on SocketException {
      throw const _SetupException('Check your connection and try again.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar App Setup')),
      body: FutureBuilder<_CalDavAccount>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final message = snapshot.error is _SetupException
                ? (snapshot.error as _SetupException).message
                : 'Could not load Calendar App Setup.';
            return ListView(
              padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
              children: [
                CaleeSection(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(CaleeSpacing.md),
                      child: Text(
                        message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: CaleeColors.destructive,
                            ),
                      ),
                    ),
                    CaleeListRow(
                      title: 'Retry',
                      leading: const Icon(Icons.refresh, color: CaleeColors.primary),
                      onTap: () => setState(() => _future = _load()),
                    ),
                  ],
                ),
              ],
            );
          }

          final account = snapshot.requireData;
          return ListView(
            padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
            children: [
              Text(
                'Use these details to add this Calee calendar service to Apple Calendar or another app that supports CalDAV.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),
              CaleeSection(
                title: account.serviceName,
                children: [
                  _SetupField(
                    label: 'Server',
                    value: account.server,
                    onCopy: () => _copy(context, 'Server', account.server),
                  ),
                  _SetupField(
                    label: 'Username',
                    value: account.username,
                    onCopy: () => _copy(context, 'Username', account.username),
                  ),
                  _SetupField(
                    label: 'Password',
                    value: _showPassword ? account.password : '••••••••',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _showPassword ? 'Hide password' : 'Show password',
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                        ),
                        IconButton(
                          tooltip: 'Copy Password',
                          onPressed: () => _copy(context, 'Password', account.password),
                          icon: const Icon(Icons.copy),
                        ),
                      ],
                    ),
                  ),
                  _SetupField(
                    label: 'Description',
                    value: account.description,
                    onCopy: () => _copy(context, 'Description', account.description),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SetupField extends StatelessWidget {
  const _SetupField({
    required this.label,
    required this.value,
    this.onCopy,
    this.trailing,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return CaleeListRow(
      title: label,
      subtitle: value,
      trailing: trailing ??
          IconButton(
            tooltip: 'Copy $label',
            onPressed: onCopy,
            icon: const Icon(Icons.copy),
          ),
    );
  }
}

class _CalDavAccount {
  const _CalDavAccount({
    required this.serviceName,
    required this.server,
    required this.username,
    required this.password,
    required this.description,
  });

  factory _CalDavAccount.fromJson(Map<String, dynamic> json) {
    return _CalDavAccount(
      serviceName: json['serviceName'] as String? ?? 'Calee',
      server: json['server'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      description: json['description'] as String? ?? 'Calee',
    );
  }

  final String serviceName;
  final String server;
  final String username;
  final String password;
  final String description;
}

class _SetupException implements Exception {
  const _SetupException(this.message);

  final String message;

  @override
  String toString() => message;
}
