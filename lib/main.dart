import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'chat_screen.dart';

void main() {
  runApp(const BotopusApp());
}

class BotopusApp extends StatelessWidget {
  const BotopusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Botopus Linux',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212), // Deep gray Manus theme
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF4F46E5), // Indigo accent
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4F46E5),
          surface: Color(0xFF1E1E1E),
        ),
      ),
      home: const BotopusHomePage(),
    );
  }
}

class BotopusHomePage extends StatefulWidget {
  const BotopusHomePage({super.key});

  @override
  State<BotopusHomePage> createState() => _BotopusHomePageState();
}

class _BotopusHomePageState extends State<BotopusHomePage> with SingleTickerProviderStateMixin {
  final terminal = Terminal(maxLines: 10000
  );
  
  final terminalController = TerminalController();
  Pty? pty;
  bool isBootstrapping = true;
  String statusText = "Initializing Botopus Linux...";
  late TabController _tabController;
  
  // Chat state
  List<Map<String, String>> chatSessions = [];
  String apiKey = "";
  Stream<String>? ptyOutputStream;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() {});
    });
    WakelockPlus.enable();
    _bootstrapEnvironment();
  }

  // --- PRoot Bootstrap Logic (Preserved) ---
  Future<void> _bootstrapEnvironment() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final prootFile = File('${docDir.path}/proot');
      final loaderFile = File('${docDir.path}/loader');
      final loader32File = File('${docDir.path}/loader32');
      final rootfsDir = Directory('${docDir.path}/ubuntu');

      setState(() => statusText = "Copying binaries...");
      
      if (!await prootFile.exists()) {
        final byteData = await rootBundle.load('assets/proot');
        await prootFile.writeAsBytes(byteData.buffer.asUint8List());
        await Process.run('chmod', ['+x', prootFile.path]);
      }
      if (!await loaderFile.exists()) {
        final byteData = await rootBundle.load('assets/loader');
        await loaderFile.writeAsBytes(byteData.buffer.asUint8List());
        await Process.run('chmod', ['+x', loaderFile.path]);
      }
      if (!await loader32File.exists()) {
        final byteData = await rootBundle.load('assets/loader32');
        await loader32File.writeAsBytes(byteData.buffer.asUint8List());
        await Process.run('chmod', ['+x', loader32File.path]);
      }

      final soFile = File('${docDir.path}/libandroid-shmem.so');
      if (!await soFile.exists()) {
        final byteData = await rootBundle.load('assets/libandroid-shmem.so');
        await soFile.writeAsBytes(byteData.buffer.asUint8List());
      }

      final tallocFile = File('${docDir.path}/libtalloc.so.2');
      if (!await tallocFile.exists()) {
        final byteData = await rootBundle.load('assets/libtalloc.so.2');
        await tallocFile.writeAsBytes(byteData.buffer.asUint8List());
      }

      if (!await rootfsDir.exists()) {
        setState(() => statusText = "Extracting RootFS (This will take a while)...");
        final archiveData = await rootBundle.load('assets/ubuntu-rootfs.tar.gz');
        final archiveFile = File('${docDir.path}/ubuntu-rootfs.tar.gz');
        await archiveFile.writeAsBytes(archiveData.buffer.asUint8List());
        
        await rootfsDir.create();
        final rootfsPath = rootfsDir.path;
        
        final result = await Process.run(
          prootFile.path,
          [
            '--link2symlink',
            '-0',
            '/system/bin/tar', '-xf', archiveFile.path, '-C', rootfsPath
          ],
          environment: {
            'PROOT_LOADER': '${docDir.path}/loader',
            'PROOT_LOADER_32': '${docDir.path}/loader32',
            'LD_LIBRARY_PATH': docDir.path,
            'PROOT_TMP_DIR': docDir.path,
            'PATH': '/bin:/usr/bin:/sbin:/usr/sbin',
          },
        );
        
        if (result.exitCode != 0) {
          throw Exception("Tar failed: ${result.stderr}");
        }
        
        final resolvConf = File('$rootfsPath/etc/resolv.conf');
        await resolvConf.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
        final hostsFile = File('$rootfsPath/etc/hosts');
        await hostsFile.writeAsString('127.0.0.1 localhost\n::1 localhost\n');
        
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
        'PAGER': 'cat',
        'PROOT_TMP_DIR': rootfsPath,
        'TMPDIR': '/tmp',
        'PROOT_NO_SECCOMP': '1',
        'PROOT_LOADER': '$docDirPath/loader',
        'PROOT_LOADER_32': '$docDirPath/loader32',
        'LD_LIBRARY_PATH': docDirPath,
      },
      workingDirectory: rootfsPath,
    );

    final broadcastStream = pty!.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).asBroadcastStream();
    
    broadcastStream.listen((text) {
      terminal.write(text);
    });

    terminal.onOutput = (text) {
      pty!.write(Uint8List.fromList(utf8.encode(text)));
    };
    
    // Store broadcast stream so we can pass it to chat screen
    ptyOutputStream = broadcastStream;

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      pty?.resize(height, width); // Correct rows, cols map
    };

    terminal.write('\x1B[1;32mBotopus Linux (Ubuntu PRoot) Initialized!\x1B[0m\r\n');
  }

  @override
  void dispose() {
    pty?.kill();
    _tabController.dispose();
    super.dispose();
  }

  void _showApiKeyDialog() {
    TextEditingController _keyController = TextEditingController(text: apiKey);
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('Enter API Key (Gemini/Anthropic)'),
      content: TextField(
        controller: _keyController,
        decoration: const InputDecoration(hintText: 'AIzaSy...'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            setState(() {
              apiKey = _keyController.text;
            });
            Navigator.pop(context);
          }, 
          child: const Text('Save')
        )
      ],
    ));
  }

  void _openNewChat() {
    if (apiKey.isEmpty) {
      _showApiKeyDialog();
      return;
    }
    // TODO: Create new chat session logic
    setState(() {
      chatSessions.add({"id": DateTime.now().toString(), "title": "New Session ${chatSessions.length + 1}"});
    });
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: const Text('Botopus AI IDE'),
        actions: [
          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'API Keys',
            onPressed: _showApiKeyDialog,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF4F46E5),
          tabs: const [
            Tab(text: 'Tasks (Chat)', icon: Icon(Icons.chat_bubble_outline)),
            Tab(text: 'Terminal (PRoot)', icon: Icon(Icons.terminal)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: Tasks / Chat Sessions
          _buildTasksTab(),
          
          // TAB 2: Terminal
          _buildTerminalTab(),
        ],
      ),
    );
  }

  Widget _buildTasksTab() {
    if (chatSessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.forum, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('No active tasks.', style: TextStyle(color: Colors.white54, fontSize: 16)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _openNewChat, 
              child: const Text('Start New Task')
            )
          ],
        )
      );
    }

    return ChatScreen(
      pty: pty,
      apiKey: apiKey,
      ptyOutputStream: ptyOutputStream,
    );
  }

  Widget _buildTerminalTab() {
    if (isBootstrapping) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(statusText, style: const TextStyle(color: Colors.white)),
          ],
        )
      );
    }
    return Column(
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
