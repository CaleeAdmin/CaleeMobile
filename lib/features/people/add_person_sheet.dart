import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../ui/calee_theme.dart';

String _errorMessage(Object error, String fallback) {
  if (error is CaleeHubException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return fallback;
}

class AddPersonSheet extends StatefulWidget {
  const AddPersonSheet({
    super.key,
    required this.onAdd,
  });

  final Future<void> Function(String name) onAdd;

  @override
  State<AddPersonSheet> createState() => _AddPersonSheetState();
}

class _AddPersonSheetState extends State<AddPersonSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onAdd(_nameController.text.trim());
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage(error, 'Unable to add person.')),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _nameController,
            enabled: !_isSubmitting,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            validator: (value) {
              if ((value ?? '').trim().isEmpty) {
                return 'Enter a name';
              }
              return null;
            },
          ),
          const SizedBox(height: CaleeSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _isSubmitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: CaleeSpacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Add'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
