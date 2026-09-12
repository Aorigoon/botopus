import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final String? status;

  ChatMessage({required this.text, required this.isUser, this.status});
}

class TypewriterText extends StatefulWidget {
  final String text;
  const TypewriterText(this.text, {super.key});

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  String displayedText = "";
  Timer? _timer;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _startTyping();
  }

  void _startTyping() {
    _timer = Timer.periodic(const Duration(milliseconds: 15), (timer) {
      if (_currentIndex < widget.text.length) {
        setState(() {
          displayedText += widget.text[_currentIndex];
          _currentIndex++;
        });
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(displayedText, style: const TextStyle(color: Colors.white));
}

class ChatScreen extends StatefulWidget {
  final Pty? pty;
  final String apiKey;
  final Stream<String>? ptyOutputStream;

  const ChatScreen({super.key, required this.pty, required this.apiKey, this.ptyOutputStream});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with AutomaticKeepAliveClientMixin {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  bool _isProcessing = false;
  bool _cancelRequested = false;
  String _agentStatus = "";

  final List<String> _models = [
    'gemini-3.2-flash',
    'gemini-3.1-flash',
    'gemini-3.0-flash',
    'gemini-1.5-pro',
    'gemini-1.5-flash',
  ];
  int _currentModelIndex = 0;
  
  late GenerativeModel _model;
  late ChatSession _chatSession;
  
  StringBuffer _terminalBuffer = StringBuffer();
  StreamSubscription? _ptySubscription;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initAgent();
    
    if (widget.ptyOutputStream != null) {
      _ptySubscription = widget.ptyOutputStream!.listen((data) {
        if (_isProcessing) {
          _terminalBuffer.write(data);
        }
      });
    }
  }
  
  @override
  void dispose() {
    _ptySubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey) {
      _initAgent();
    }
  }

  void _initAgent() {
    final systemPrompt = '''
You are an advanced autonomous coding assistant named Botopus.
You are a conversational agent. You must understand the user's requirements FIRST before taking action. Ask clarifying questions if the request is ambiguous.
ALWAYS explain what you are going to do in a friendly, conversational manner BEFORE executing any commands.
Keep your responses short and concise. Do NOT dump large code blocks (like HTML/CSS) into the chat. Instead, write the code directly to a file using standard commands, and just tell the user briefly that you wrote it.
If you need to execute a bash command, wrap it strictly in <run>...</run> tags AFTER your explanation. For example: "I will now list the directory contents." <run>ls -la</run>
Only output ONE <run> block at a time. Wait for the terminal output before proceeding.
CRITICAL: If you run a server (e.g. python3 -m http.server, ngrok, localhost.run), you MUST run it in the background using `&` (e.g., <run>python3 -m http.server 8000 &</run>), otherwise it will block the terminal forever and you will be stuck!
''';

    _model = GenerativeModel(
      model: _models[_currentModelIndex],
      apiKey: widget.apiKey,
      systemInstruction: Content.system(systemPrompt),
    );
    _chatSession = _model.startChat();
  }

  Future<void> _sendMessage(String text) async {
    if (text.isEmpty || widget.apiKey.isEmpty || widget.pty == null) return;
    
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
      _isProcessing = true;
      _cancelRequested = false;
      _agentStatus = "Thinking...";
    });
    
    _controller.clear();
    
    try {
      await _agentLoop(text);
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(text: "Error: $e", isUser: false));
        _isProcessing = false;
        _agentStatus = "";
      });
    }
  }

  void _cancelTask() {
    setState(() {
      _cancelRequested = true;
      _agentStatus = "Cancelling...";
    });
  }

  Future<void> _agentLoop(String prompt) async {
    int maxLoops = 5;
    int currentLoop = 0;
    String currentPrompt = prompt;

    while (currentLoop < maxLoops) {
      if (_cancelRequested) {
        setState(() { _messages.add(ChatMessage(text: "Task cancelled.", isUser: false)); _isProcessing = false; _agentStatus = ""; });
        break;
      }
      setState(() { _agentStatus = "Thinking..."; });
      
      String responseText = "";
      try {
        final response = await _chatSession.sendMessage(Content.text(currentPrompt));
        responseText = response.text ?? "";
      } catch (e) {
        if (_currentModelIndex < _models.length - 1) {
          _currentModelIndex++;
          setState(() { _agentStatus = "Fallback to ${_models[_currentModelIndex]}..."; });
          final history = _chatSession.history.toList();
          _initAgent();
          _chatSession = _model.startChat(history: history);
          continue; // Retry with new model
        } else {
          setState(() { _messages.add(ChatMessage(text: "Error: All models failed. ${e.toString()}", isUser: false)); _isProcessing = false; _agentStatus = ""; });
          break;
        }
      }
      
      final runMatch = RegExp(r'<run>(.*?)</run>', dotAll: true).firstMatch(responseText);
      
      if (runMatch != null) {
        final command = runMatch.group(1)!.trim();
        final textBefore = responseText.substring(0, runMatch.start).trim();
        
        if (textBefore.isNotEmpty) {
           setState(() {
            _messages.add(ChatMessage(text: textBefore, isUser: false));
          });
        }
        
        setState(() { _agentStatus = "Running: $command"; });
        
        _terminalBuffer.clear();
        widget.pty!.write(utf8.encode(command + "\n"));
        
        // Check for cancel during wait
        for (int i = 0; i < 8; i++) {
          if (_cancelRequested) break;
          await Future.delayed(const Duration(milliseconds: 500));
        }
        
        if (_cancelRequested) {
          widget.pty!.write(Uint8List.fromList([0x03])); // Send Ctrl+C
          setState(() { _messages.add(ChatMessage(text: "Command execution cancelled.", isUser: false)); _isProcessing = false; _agentStatus = ""; });
          break;
        }
        
        String output = _terminalBuffer.toString();
        if (output.length > 2000) {
           output = "...[truncated]...\n" + output.substring(output.length - 2000);
        }
        
        setState(() { _agentStatus = "Analyzing output..."; });
        currentPrompt = "Command output:\n$output\nWhat next?";
        currentLoop++;
      } else {
        setState(() {
          _messages.add(ChatMessage(text: responseText, isUser: false));
          _isProcessing = false;
          _agentStatus = "";
        });
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [

        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16.0),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              return Align(
                alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12.0),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                  decoration: BoxDecoration(
                    color: msg.isUser ? const Color(0xFF2E2E2E) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16.0),
                  ),
                  child: msg.isUser
                      ? Text(
                          msg.text,
                          style: TextStyle(color: Colors.white, fontSize: 15),
                        )
                      : TypewriterText(msg.text),
                ),
              );
            },
          ),
        ),
        if (_isProcessing)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                ),
                const SizedBox(width: 12),
                Text(_agentStatus, style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(20.0),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 4.0),
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white),
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: "Ask, assign a task, type / for more",
                      hintStyle: TextStyle(color: Colors.white30),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12.0),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add, color: Colors.white54),
                            onPressed: () {},
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.all(8.0),
                          ),
                          IconButton(
                            icon: const Icon(Icons.cable, color: Colors.white54),
                            onPressed: () {},
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.all(8.0),
                          ),
                        ],
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: _isProcessing ? Colors.white : const Color(0xFF333333),
                          shape: _isProcessing ? BoxShape.rectangle : BoxShape.circle,
                          borderRadius: _isProcessing ? BorderRadius.circular(8.0) : null,
                        ),
                        child: IconButton(
                          icon: Icon(_isProcessing ? Icons.stop : Icons.arrow_upward, color: _isProcessing ? Colors.black : Colors.white),
                          onPressed: _isProcessing ? _cancelTask : () => _sendMessage(_controller.text),
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(8.0),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
