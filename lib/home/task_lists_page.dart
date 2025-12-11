import 'package:flutter/material.dart';

class TaskListsPage extends StatelessWidget {
  const TaskListsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Task Lists',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
    );
  }
}

