import 'package:flutter/material.dart';

class ChoresPage extends StatelessWidget {
  const ChoresPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _FeaturePlaceholder(
      message: 'Chores will be loaded from Calee Hub API.',
    );
  }
}

class _FeaturePlaceholder extends StatelessWidget {
  const _FeaturePlaceholder({
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
      ),
    );
  }
}
