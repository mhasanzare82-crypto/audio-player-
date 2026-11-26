import 'package:flutter/material.dart';

class VolumeAutomationScreen extends StatelessWidget {
  const VolumeAutomationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('نقشه تغییرات صدا'),
        centerTitle: true,
      ),
      body: const SizedBox.expand(),
    );
  }
}
