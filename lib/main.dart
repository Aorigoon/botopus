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
  final terminalController = TerminalController();
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
      final rootfsDir = Directory('${docDir.path}/ubuntu');
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

        setState(() => statusText = 'Extracting Ubuntu rootfs...');
        final ubuntuData = await rootBundle.load('assets/ubuntu-rootfs.tar.gz');
        final archiveFile = File('${docDir.path}/ubuntu-rootfs.tar.gz');
        await archiveFile.writeAsBytes(ubuntuData.buffer.asUint8List(), flush: true);

        setState(() => statusText = "Unpacking File System (This may take a minute)...");
        
        // Use PRoot to extract rootfs so that hardlinks are automatically converted to symlinks 
        // (Android SELinux blocks hardlinks inside app data directories)
        final archivePath = archiveFile.path;
        final rootfsPath = rootfsDir.path;
        await rootfsDir.create(recursive: true);
        final result = await Process.run(
          prootFile.path, 
          ['--link2symlink', '-0', 'tar', '-xzf', archivePath, '-C', rootfsPath],
          environment: {
            'PROOT_LOADER': '${docDir.path}/loader',
            'PROOT_LOADER_32': '${docDir.path}/loader32',
          },
        );
        
        if (result.exitCode != 0) {
          throw Exception("Tar failed: ${result.stderr}");
        }
        
        // Fix DNS resolution for Alpine / Ubuntu
        final resolvConf = File('$rootfsPath/etc/resolv.conf');
        await resolvConf.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
        
        final hostsFile = File('$rootfsPath/etc/hosts');
        await hostsFile.writeAsString('127.0.0.1 localhost\n::1 localhost\n');
        
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
        '--link2symlink',
        '-0', // fake root
        '-r', rootfsPath, // rootfs path
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '-w', '/root',
        '/bin/bash'
      ],
      environment: {
        'TERM': 'xterm-256color',
        'PATH': '/bin:/usr/bin:/sbin:/usr/sbin',
        'HOME': '/root',
        'LANG': 'en_US.UTF-8',
        'PROOT_TMP_DIR': rootfsPath,
        'TMPDIR': '/tmp',
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

    terminal.write('\x1B[1;32mBotopus Linux (Ubuntu PRoot) Initialized!\x1B[0m\r\n');
    terminal.write('Try running: \x1B[1;36mapt update && apt install python3\x1B[0m\r\n\r\n');
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
              icon: const Icon(Icons.copy),
              onPressed: () async {
                final selection = terminalController.selection;
                final text = selection != null ? terminal.buffer.getText(selection) : terminal.buffer.getText();
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(selection != null ? 'Selected text copied!' : 'Terminal text copied!')),
                  );
                }
              },
            ),
          if (!isBootstrapping)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                pty?.kill();
                terminal.eraseDisplay();
                final docDir = await getApplicationDocumentsDirectory();
                _startPty('${docDir.path}/proot', '${docDir.path}/ubuntu');
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
                  Expanded(child: TerminalView(terminal, controller: terminalController)),
                  Container(
                    color: const Color(0xFF2E3440),
                    height: 40,
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _extraKey('ESC', () => pty?.write(Uint8List.fromList([27]))),
                          _extraKey('TAB', () => pty?.write(Uint8List.fromList([9]))),
                          _extraKey('CTRL+C', () => pty?.write(Uint8List.fromList([3]))),
                          _extraKey('-', () => pty?.write(Uint8List.fromList([45]))),
                          _extraKey('/', () => pty?.write(Uint8List.fromList([47]))),
                          _extraKey('|', () => pty?.write(Uint8List.fromList([124]))),
                          _extraKey('PG UP', () => pty?.write(Uint8List.fromList([27, 91, 53, 126]))),
                          _extraKey('PG DN', () => pty?.write(Uint8List.fromList([27, 91, 54, 126]))),
                          _extraKey('↑', () => pty?.write(Uint8List.fromList([27, 91, 65]))),
                          _extraKey('↓', () => pty?.write(Uint8List.fromList([27, 91, 66]))),
                          _extraKey('←', () => pty?.write(Uint8List.fromList([27, 91, 68]))),
                          _extraKey('→', () => pty?.write(Uint8List.fromList([27, 91, 67]))),
                          _extraKey('PASTE', () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text != null) {
                              terminal.paste(data!.text!);
                            }
                          }),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _extraKey(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          focusNode: FocusNode(canRequestFocus: false),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            alignment: Alignment.center,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
    );
  }
}

