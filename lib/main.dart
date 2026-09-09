import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';

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
  Pty? pty;
  bool isBootstrapping = true;
  String statusText = "Initializing UserLAnd Environment...";

  @override
  void initState() {
    super.initState();
    _bootstrapEnvironment();
  }

  Future<void> _bootstrapEnvironment() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final rootfsDir = Directory('${docDir.path}/alpine');
      final prootFile = File('${docDir.path}/proot');

      if (!await rootfsDir.exists() || !await prootFile.exists()) {
        setState(() => statusText = "Extracting PRoot Engine & Alpine Linux...");
        
        // Copy proot binary
        final prootData = await rootBundle.load('assets/proot');
        await prootFile.writeAsBytes(prootData.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['+x', prootFile.path]);

        // Extract rootfs
        final alpineData = await rootBundle.load('assets/alpine-rootfs.tar.gz');
        final archiveFile = File('${docDir.path}/alpine-rootfs.tar.gz');
        await archiveFile.writeAsBytes(alpineData.buffer.asUint8List(), flush: true);

        setState(() => statusText = "Unpacking File System (This may take a minute)...");
        await extractFileToDisk(archiveFile.path, rootfsDir.path);
        
        // Cleanup archive
        await archiveFile.delete();
      }

      setState(() {
        isBootstrapping = false;
      });
      _startPty(prootFile.path, rootfsDir.path);
    } catch (e) {
      setState(() {
        statusText = "Failed to bootstrap: $e";
      });
    }
  }

  void _startPty(String prootPath, String rootfsPath) {
    pty = Pty.start(
      prootPath,
      arguments: [
        '-0', // fake root
        '-r', rootfsPath, // rootfs path
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '-w', '/root',
        '/bin/sh'
      ],
      environment: {
        'TERM': 'xterm-256color',
        'PATH': '/bin:/usr/bin:/sbin:/usr/sbin',
        'HOME': '/root'
      },
      workingDirectory: rootfsPath,
    );

    pty!.output.cast<List<int>>().listen((data) {
      terminal.write(String.fromCharCodes(data));
    });

    terminal.onOutput = (data) {
      pty!.write(data.codeUnits);
    };

    terminal.write('Botopus Linux (Alpine PRoot) Initialized!\r\n');
    terminal.write('Try running: apk add python3 nodejs\r\n\r\n');
  }

  @override
  void dispose() {
    pty?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Botopus Linux'),
        backgroundColor: Colors.black87,
        actions: [
          if (!isBootstrapping)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                pty?.kill();
                terminal.eraseDisplay();
                final docDir = await getApplicationDocumentsDirectory();
                _startPty('${docDir.path}/proot', '${docDir.path}/alpine');
              },
            ),
        ],
      ),
      body: SafeArea(
        child: isBootstrapping
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(statusText, style: const TextStyle(color: Colors.white)),
                  ],
                ),
              )
            : TerminalView(terminal),
      ),
    );
  }
}
