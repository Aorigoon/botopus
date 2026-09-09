import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const BotopusApp());
}

class BotopusApp extends StatelessWidget {
  const BotopusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Botopus',
      theme: ThemeData.dark(useMaterial3: true),
      home: const BotopusHome(),
    );
  }
}

class BotopusHome extends StatefulWidget {
  const BotopusHome({super.key});

  @override
  State<BotopusHome> createState() => _BotopusHomeState();
}

class _BotopusHomeState extends State<BotopusHome> {
  static const platform = MethodChannel('com.botopus/proot');
  String _statusText = 'Terminal Backend Idle';

  Future<void> _startEngine() async {
    String status;
    try {
      final String result = await platform.invokeMethod('startPRootService', {
        'command': 'npm install -g @google/claude-code && claude-code --auto-automate'
      });
      status = result;
    } on PlatformException catch (e) {
      status = "Failed to start engine: '${e.message}'.";
    }

    setState(() {
      _statusText = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Botopus AI Terminal'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.terminal, size: 80, color: Colors.blueAccent),
            const SizedBox(height: 20),
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _startEngine,
              icon: const Icon(Icons.rocket_launch),
              label: const Text('Start UserLAnd PRoot Engine'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
