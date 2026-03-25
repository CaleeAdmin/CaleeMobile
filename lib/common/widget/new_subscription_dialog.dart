import 'package:flutter/material.dart';

Future<bool?> showNewSubscriptionDialog({
  required BuildContext context,
  required Future<bool> Function(String url) onSubmit,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final TextEditingController urlCtrl = TextEditingController();
      final ValueNotifier<bool> isSubmitting = ValueNotifier<bool>(false);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('New Subscription from Link', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  )
                ],
              ),
              const SizedBox(height: 8),
              const Text('Subscribe to a read-only calendar using a URL', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Calendar URL', style: TextStyle(fontSize: 13, color: Colors.black54)),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  isDense: true,
                  hintText: 'https://example.com/calendar.ics',
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ValueListenableBuilder<bool>(
                  valueListenable: isSubmitting,
                  builder: (context, submitting, _) {
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: submitting
                          ? null
                          : () async {
                              isSubmitting.value = true;
                              final url = urlCtrl.text.trim();
                              final ok = await onSubmit(url);
                              isSubmitting.value = false;
                              if (!dialogContext.mounted) return;
                              Navigator.of(dialogContext).pop(ok);
                            },
                      child: submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text('Confirm', style: TextStyle(color: Colors.white)),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Cancel', style: TextStyle(color: Colors.black)),
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
