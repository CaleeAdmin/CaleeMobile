import 'package:caleesync/controllers/CalendarPageController.dart';
import 'package:caleesync/models/ios_import_provider.dart';
import 'package:caleesync/services/ios_import_calendar_guide_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class IosExternalCalendarImportPage extends StatefulWidget {
  const IosExternalCalendarImportPage({super.key});

  @override
  State<IosExternalCalendarImportPage> createState() => _IosExternalCalendarImportPageState();
}

class _IosExternalCalendarImportPageState extends State<IosExternalCalendarImportPage> {
  final IosImportCalendarGuideService _guideService = IosImportCalendarGuideService();
  final TextEditingController _urlController = TextEditingController();

  IosImportProvider _selectedProvider = IosImportProvider.iCloud;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String _normalizeInput(String raw) {
    return raw.trim();
  }

  String? _validateUrl(String raw) {
    final String normalized = _normalizeInput(raw);
    if (normalized.isEmpty) {
      return 'Subscription URL is required.';
    }

    final Uri? parsed = Uri.tryParse(normalized);
    if (parsed == null || parsed.host.isEmpty) {
      return 'Enter a valid URL.';
    }

    if (parsed.scheme != 'http' && parsed.scheme != 'https' && parsed.scheme != 'webcal') {
      return 'Only http, https, or webcal URLs are supported.';
    }

    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _errorText = null;
    });

    final rawUrl = _normalizeInput(_urlController.text);
    final invalidReason = _validateUrl(rawUrl);
    if (invalidReason != null) {
      setState(() {
        _errorText = invalidReason;
      });
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final ok = await Get.find<CalendarPageController>().subscribePublicIcs(rawUrl);
      if (!mounted) {
        return;
      }
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Imported calendar added')),
        );
        Get.back(result: true);
      } else {
        setState(() {
          _errorText = 'Unable to import this calendar link. Please verify the URL and try again.';
        });
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to import this calendar link right now. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildProviderPicker() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: IosImportProvider.values
              .map(
                (provider) => ChoiceChip(
                  avatar: Icon(provider.icon, size: 18),
                  label: Text(provider.title),
                  selected: provider == _selectedProvider,
                  onSelected: (_) {
                    setState(() {
                      _selectedProvider = provider;
                      _errorText = null;
                    });
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildIntroCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_selectedProvider.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(_selectedProvider.subtitle, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            Text(_guideService.helperTextFor(_selectedProvider)),
          ],
        ),
      ),
    );
  }

  Widget _buildStepsCard() {
    final steps = _guideService.stepsFor(_selectedProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('How to get your link', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${i + 1}. ${steps[i]}'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasteCard() {
    final example = _guideService.exampleUrlFor(_selectedProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_selectedProvider.urlLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: example ?? 'https://example.com/calendar.ics',
                errorText: _errorText,
                suffixIcon: _urlController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: () {
                          setState(() {
                            _urlController.clear();
                            _errorText = null;
                          });
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) {
                if (_errorText != null) {
                  setState(() => _errorText = null);
                } else {
                  setState(() {});
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              _guideService.warningTextFor(_selectedProvider),
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Imported calendars are read-only', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('This creates a read-only imported calendar in Calee.'),
            SizedBox(height: 6),
            Text('It does not add a two-way Apple Calendar account.'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import Calendar into Calee')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildProviderPicker(),
              const SizedBox(height: 12),
              _buildIntroCard(),
              const SizedBox(height: 12),
              _buildStepsCard(),
              const SizedBox(height: 12),
              _buildPasteCard(),
              const SizedBox(height: 12),
              _buildReadOnlyCard(),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                        )
                      : Text(_selectedProvider.submitLabel, style: const TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
