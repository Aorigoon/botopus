import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';

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
        
        // Make proot executable
        await Process.run('chmod', ['+x', prootFile.path]);

        // Copy shared libraries needed by proot
        try {
          final tallocData = await rootBundle.load('assets/libtalloc.so.2');
          await File('${docDir.path}/libtalloc.so.2').writeAsBytes(tallocData.buffer.asUint8List(), flush: true);
        } catch (e) {
          print("Failed to copy libtalloc: $e");
        }
        try {
          final shmemData = await rootBundle.load('assets/libandroid-shmem.so');
          await File('${docDir.path}/libandroid-shmem.so').writeAsBytes(shmemData.buffer.asUint8List(), flush: true);
        } catch (e) {
          print("Failed to copy libandroid-shmem: $e");
        }
        
        // Copy loaders needed by PRoot for Android
        try {
          final loaderData = await rootBundle.load('assets/loader');
          final loaderFile = File('${docDir.path}/loader');
          await loaderFile.writeAsBytes(loaderData.buffer.asUint8List(), flush: true);
          await Process.run('chmod', ['+x', loaderFile.path]);
          
          final loader32Data = await rootBundle.load('assets/loader32');
          final loader32File = File('${docDir.path}/loader32');
          await loader32File.writeAsBytes(loader32Data.buffer.asUint8List(), flush: true);
          await Process.run('chmod', ['+x', loader32File.path]);
        } catch (e) {
          print("Failed to copy loaders: $e");
        }

        // Extract rootfs
        final alpineData = await rootBundle.load('assets/alpine-rootfs.tar.gz');
        final archiveFile = File('${docDir.path}/alpine-rootfs.tar.gz');
        await archiveFile.writeAsBytes(alpineData.buffer.asUint8List(), flush: true);

        setState(() => statusText = "Unpacking File System (This may take a minute)...");
        
        // Use native tar to extract rootfs correctly (handles symlinks and avoids memory issues)
        final archivePath = archiveFile.path;
        final rootfsPath = rootfsDir.path;
        await rootfsDir.create(recursive: true);
        final result = await Process.run('tar', ['-xzf', archivePath, '-C', rootfsPath]);
        
        if (result.exitCode != 0) {
          throw Exception("Tar failed: ${result.stderr}");
        }
        
        // Fix DNS resolution for Alpine
        final resolvConf = File('$rootfsPath/etc/resolv.conf');
        await resolvConf.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
        
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
    final docDirPath = File(prootPath).parent.path;
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
        'HOME': '/root',
        'PROOT_TMP_DIR': rootfsPath,
        'PROOT_NO_SECCOMP': '1',
        'PROOT_LOADER': '$docDirPath/loader',
        'PROOT_LOADER_32': '$docDirPath/loader32',
      },
      workingDirectory: rootfsPath,
    );

    pty!.output.cast<List<int>>().listen((data) {
      terminal.write(String.fromCharCodes(data));
    });

    terminal.onOutput = (data) {
      pty!.write(Uint8List.fromList(data.codeUnits));
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
            : Column(
                children: [
                  Expanded(child: TerminalView(terminal)),
                  Container(
                    color: Colors.grey[900],
                    height: 45,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _extraKey('ESC', () => pty?.write(Uint8List.fromList([27]))),
                        _extraKey('CTRL+C', () => pty?.write(Uint8List.fromList([3]))),
                        _extraKey('COPY', () async {
                          final text = terminal.buffer.getText();
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Terminal text copied!')),
                            );
                          }
                        }),
                        _extraKey('PASTE', () async {
                          final data = await Clipboard.getData('text/plain');
                          if (data?.text != null) {
                            // Remove newlines and extra spaces caused by chat wrapping
                            String cleanText = data!.text!.replaceAll('\r\n', '').replaceAll('\n', '');
                            // Also remove accidental spaces that get inserted when copying wrapped URLs
                            cleanText = cleanText.replaceAll(RegExp(r'\s+google/cli'), 'google/cli');
                            terminal.paste(cleanText);
                          }
                        }),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _extraKey(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(60, 35),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}

