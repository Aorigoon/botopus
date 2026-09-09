import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import 'package:pty/pty.dart';

void main() {
  runApp(const BotopusApp());
}

class BotopusApp extends StatelessWidget {
  const BotopusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Botopus Terminal',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const TerminalScreen(),
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final terminal = Terminal();
  late final Pty pty;

  @override
  void initState() {
    super.initState();
    _startPty();
  }

  void _startPty() {
    // Determine the shell. On Android, it's typically /system/bin/sh.
    final shell = Platform.isWindows ? 'cmd.exe' : (Platform.isAndroid ? '/system/bin/sh' : 'sh');

    pty = Pty.start(
      shell,
      arguments: [],
      environment: {'TERM': 'xterm-256color'},
      workingDirectory: Platform.isAndroid ? '/data/data/com.example.botopus/files' : '.',
    );

    // Pipe pty output to xterm terminal
    pty.output.cast<List<int>>().listen((data) {
      terminal.write(String.fromCharCodes(data));
    });

    // Pipe xterm input to pty
    terminal.onOutput = (data) {
      pty.write(data.codeUnits);
    };
    
    terminal.write('Welcome to Botopus Core (Android Shell)\r\n');
    terminal.write('To test Linux environment, try running commands like "ls" or "pwd".\r\n');
    terminal.write('PRoot integration for Alpine/Debian can be bootstrapped from this shell.\r\n\r\n');
  }

  @override
  void dispose() {
    pty.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Botopus Terminal'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              pty.kill();
              terminal.eraseDisplay();
              _startPty();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: TerminalView(terminal),
      ),
    );
  }
}
