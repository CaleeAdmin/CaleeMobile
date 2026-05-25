import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';

class ConnectServicePage extends StatefulWidget {
  const ConnectServicePage({
    required this.hubClient,
    required this.accessToken,
    required this.service,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientService service;

  @override
  State<ConnectServicePage> createState() => _ConnectServicePageState();
}

class _ConnectServicePageState extends State<ConnectServicePage> {
  final _formKey = GlobalKey<FormState>();
  final _loginNameController = TextEditingController();
  final _appPasswordController = TextEditingController();

  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _loginNameController.dispose();
    _appPasswordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await widget.hubClient.storeServiceCredentials(
        accessToken: widget.accessToken,
        serviceId: widget.service.id,
        loginName: _loginNameController.text.trim(),
        appPassword: _appPasswordController.text,
      );

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(true);
    } on CaleeHubException catch (e) {
      setState(() {
        _error = e.message;
        _isSaving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not connect service. Please try again.';
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect service'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(service.displayName),
                subtitle: Text(service.baseUrl),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Enter the service username and app password for this Calee service.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _loginNameController,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'Service username',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Username is required';
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _appPasswordController,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'App password',
                      hintText: 'Service app password',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'App password is required';
                      }

                      return null;
                    },
                    onFieldSubmitted: (_) {
                      if (!_isSaving) {
                        _save();
                      }
                    },
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? 'Connecting...' : 'Save and connect'),
            ),
          ],
        ),
      ),
    );
  }
}
