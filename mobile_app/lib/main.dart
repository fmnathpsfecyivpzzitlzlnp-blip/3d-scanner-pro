import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:flutter/services.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // --- ЖЕСТКАЯ БЛОКИРОВКА ЭКРАНА ВЕРТИКАЛЬНО ---
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  cameras = await availableCameras();
  runApp(const ScannerApp());
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '3D Scanner Pro',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const CaptureScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _controller;
  bool isRecording = false;
  bool isUploading = false;
  String? lastVideoPath;
  String? currentFileName;

  // --- СЕТЬ, СТАТУСЫ И ЛОГИ ---
  http.Client? _httpClient;
  WebSocketChannel? _wsChannel;
  bool isModelReady = false;
  List<String> serverLogs = ["Ожидание отправки..."];

  // Честный прогресс-бар от 0.0 до 1.0
  double _conversionProgress = 0.0;

  // --- СЕКУНДОМЕР ЗАПИСИ ---
  Timer? _recordTimer;
  int _recordSeconds = 0;

  final String clientId = DateTime.now().millisecondsSinceEpoch.toString();

  // --- ДАТЧИКИ ДВИЖЕНИЯ ---
  bool isMovingTooFast = false;
  bool _isAccelTooFast = false;
  bool _isGyroTooFast = false;
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;

  // !!! ВНИМАНИЕ: ТВОЙ IP СЕРВЕРА !!!
  final String serverIP = "192.168.31.11:8000";

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initSensors();
  }

  void _initCamera() {
    if (cameras.isNotEmpty) {
      _controller = CameraController(
        cameras[0],
        ResolutionPreset.max,
        enableAudio: false,
      );
      _controller!.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
      });
    }
  }

  void _initSensors() {
    _accelSubscription = userAccelerometerEvents.listen((event) {
      double mag = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _isAccelTooFast = mag > 0.8;
      _updateMotionAlert();
    });
    _gyroSubscription = gyroscopeEvents.listen((event) {
      double mag = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _isGyroTooFast = mag > 0.5;
      _updateMotionAlert();
    });
  }

  void _updateMotionAlert() {
    bool shouldAlert = _isAccelTooFast || _isGyroTooFast;
    if (shouldAlert != isMovingTooFast) {
      setState(() => isMovingTooFast = shouldAlert);
    }
  }

  String _formatTime(int seconds) {
    int mins = seconds ~/ 60;
    int secs = seconds % 60;
    return "${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _recordTimer?.cancel();
    _controller?.dispose();
    _httpClient?.close();
    _wsChannel?.sink.close();
    super.dispose();
  }

  // Запись логов с выводом свежих сообщений в начало
  void _addLog(String msg) {
    if (mounted) {
      setState(() {
        serverLogs.insert(0, msg);
        if (serverLogs.length > 30) serverLogs.removeLast();
      });
    }
  }

  // --- ОТПРАВКА И УМНЫЙ ПРОГРЕСС-БАР ---
  Future<void> uploadVideo() async {
    if (lastVideoPath == null) return;
    currentFileName = lastVideoPath!.split('/').last;

    setState(() {
      isUploading = true;
      _conversionProgress = 0.05;
      serverLogs = ["🚀 Загрузка видео на сервер..."];
      _httpClient = http.Client();
    });

    try {
      _wsChannel = WebSocketChannel.connect(
        Uri.parse('ws://$serverIP/ws/$clientId'),
      );
      _wsChannel!.stream.listen(
        (message) {
          String msg = message.toString();
          _addLog(msg);

          setState(() {
            if (msg.contains("❌") || msg.contains("ОШИБКА")) {
              _conversionProgress = 0.0;
            } else if (msg.contains("Нарезка")) {
              _conversionProgress = 0.10; // Нарезка - это 10%
            } else if (msg.contains("Meshroom: Шаг")) {
              // Читаем честные проценты из строки "Шаг X из Y"
              RegExp regExp = RegExp(r'Шаг (\d+) из (\d+)');
              var match = regExp.firstMatch(msg);

              if (match != null) {
                int current = int.parse(match.group(1)!);
                int total = int.parse(match.group(2)!);
                // Вычисляем прогресс. Meshroom занимает 80% шкалы (от 10% до 90%)
                _conversionProgress = 0.10 + ((current / total) * 0.80);
              }
            } else if (msg.contains("Оптимизация")) {
              _conversionProgress = 0.95; // Блендер - это 95%
            } else if (msg.contains("ГОТОВО")) {
              _conversionProgress = 1.0; // 100%
              Future.delayed(const Duration(milliseconds: 800), () {
                if (mounted)
                  setState(() {
                    isModelReady = true;
                    isUploading = false;
                  });
              });
            }
          });
        },
        onDone: () {
          if (!isModelReady && isUploading)
            _addLog("⚠️ Связь с сервером потеряна");
        },
      );
    } catch (e) {
      _addLog("❌ Ошибка сокета");
    }

    try {
      var uri = Uri.parse('http://$serverIP/upload/$clientId');
      var request = http.MultipartRequest('POST', uri);
      request.files.add(
        await http.MultipartFile.fromPath('video', lastVideoPath!),
      );
      var response = await _httpClient!.send(request);
      if (response.statusCode == 200)
        _addLog("✅ Видео на сервере. Ожидание вычислений...");
    } catch (e) {
      _addLog("🛑 Ошибка сети");
    }
  }

  void cancelUpload() {
    _httpClient?.close();
    _wsChannel?.sink.close();
    setState(() {
      isUploading = false;
      serverLogs.clear();
      _conversionProgress = 0.0;
    });
  }

  // --- ЛОГИКА ЗАПИСИ С СЕКУНДОМЕРОМ ---
  Future<void> toggleRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (isRecording) {
      _recordTimer?.cancel();
      try {
        XFile videoFile = await _controller!.stopVideoRecording();
        setState(() {
          isRecording = false;
          lastVideoPath = videoFile.path;
        });
      } catch (e) {
        setState(() => isRecording = false);
      }
    } else {
      setState(() {
        lastVideoPath = null;
        isModelReady = false;
        _conversionProgress = 0.0;
        _recordSeconds = 0;
      });
      try {
        await _controller!.startVideoRecording();
        _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() => _recordSeconds++);
        });
        setState(() => isRecording = true);
      } catch (e) {
        debugPrint("Ошибка записи: $e");
      }
    }
  }

  Future<void> requestExport(String format) async {
    if (currentFileName == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⏳ Генерация $format...'),
        backgroundColor: Colors.blueAccent,
      ),
    );
    try {
      var response = await http.get(
        Uri.parse('http://$serverIP/export/$currentFileName/$format'),
      );
      if (response.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ $format готов на ПК!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('❌ Ошибка сервера')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // --- ЭКРАН 3D МОДЕЛИ ---
    if (isModelReady && currentFileName != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            '3D Preview',
            style: TextStyle(color: Colors.greenAccent),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              isModelReady = false;
              lastVideoPath = null;
            }),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ModelViewer(
                backgroundColor: const Color(0xFF121212),
                src: 'http://$serverIP/export/$currentFileName/glb',
                alt: "Model",
                ar: true,
                autoRotate: true,
                cameraControls: true,
              ),
            ),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: const BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(30),
                  topRight: Radius.circular(30),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'ЭКСПОРТ ДЛЯ Unreal / Unity / Godot:',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    spacing: 8,
                    runSpacing: 10,
                    children: [
                      _exportBtn(
                        'FBX',
                        'Unreal',
                        Colors.orange,
                        () => requestExport('fbx'),
                      ),
                      _exportBtn(
                        'GLB',
                        'Godot',
                        Colors.blue,
                        () => requestExport('glb'),
                      ),
                      _exportBtn(
                        'GLTF',
                        'Web',
                        Colors.lightBlueAccent,
                        () => requestExport('gltf'),
                      ),
                      _exportBtn(
                        'DAE',
                        'Maya',
                        Colors.purple,
                        () => requestExport('dae'),
                      ),
                      _exportBtn(
                        'USDZ',
                        'iOS AR',
                        Colors.white,
                        () => requestExport('usdz'),
                      ),
                      _exportBtn(
                        'STL',
                        'Печать',
                        Colors.grey,
                        () => requestExport('stl'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // --- ЭКРАН КАМЕРЫ ---
    return Scaffold(
      body: Stack(
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: CameraPreview(_controller!),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          if (isMovingTooFast)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.2),
                  border: Border.all(color: Colors.red, width: 6),
                ),
              ),
            ),

          Positioned.fill(child: CustomPaint(painter: GridPainter())),

          // --- ИНТЕРФЕЙС ЗАГРУЗКИ ---
          if (isUploading)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.memory,
                        size: 60,
                        color: Colors.greenAccent,
                      ),
                      const SizedBox(height: 20),
                      Container(
                        height: 150,
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          border: Border.all(
                            color: Colors.greenAccent.withOpacity(0.3),
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListView.builder(
                          reverse: true, // Самые новые логи всегда снизу
                          itemCount: serverLogs.length,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              "> ${serverLogs[index]}",
                              style: TextStyle(
                                color: index == 0
                                    ? Colors.greenAccent
                                    : Colors.grey,
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      LinearProgressIndicator(
                        value: _conversionProgress,
                        backgroundColor: Colors.white24,
                        color: Colors.greenAccent,
                        minHeight: 10,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${(_conversionProgress * 100).toInt()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 40),
                      OutlinedButton.icon(
                        onPressed: cancelUpload,
                        icon: const Icon(Icons.cancel, color: Colors.redAccent),
                        label: const Text('ОТМЕНА (На телефоне)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          // --- ПАНЕЛЬ ПОСЛЕ ЗАПИСИ ---
          else if (lastVideoPath != null && !isRecording)
            Positioned(
              bottom: 40,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.deepPurpleAccent),
                ),
                child: Column(
                  children: [
                    const Text(
                      'ВИДЕО ГОТОВО',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => setState(() => lastVideoPath = null),
                          icon: const Icon(Icons.delete, color: Colors.white),
                          label: const Text('Удалить'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: uploadVideo,
                          icon: const Icon(
                            Icons.cloud_upload,
                            color: Colors.white,
                          ),
                          label: const Text('В 3D'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          // --- ЭКРАН СЪЕМКИ ---
          else
            Stack(
              children: [
                if (isRecording)
                  Positioned(
                    top: 60,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _formatTime(_recordSeconds),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!isRecording)
                  Positioned(
                    top: 50,
                    left: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: Colors.greenAccent.withOpacity(0.5),
                        ),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'СОВЕТЫ ПО СЪЕМКЕ:',
                            style: TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '• Держите телефон всегда вертикально!',
                            style: TextStyle(
                              color: Colors.yellowAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '• Сделайте 2-3 круга на разной высоте',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                          Text(
                            '• Записывайте минимум 20-30 секунд',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 40,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: toggleRecording,
                        child: Container(
                          height: 80,
                          width: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            color: isRecording
                                ? Colors.red
                                : Colors.transparent,
                          ),
                          child: Center(
                            child: Icon(
                              isRecording ? Icons.stop : Icons.circle,
                              color: isRecording ? Colors.white : Colors.red,
                              size: 40,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        isRecording ? 'СЪЕМКА...' : 'Начни запись',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          backgroundColor: Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _exportBtn(
    String title,
    String subtitle,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      p,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      p,
    );
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      p,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      p,
    );
    final cp = Paint()
      ..color = Colors.greenAccent.withOpacity(0.6)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width / 2 - 15, size.height / 2),
      Offset(size.width / 2 + 15, size.height / 2),
      cp,
    );
    canvas.drawLine(
      Offset(size.width / 2, size.height / 2 - 15),
      Offset(size.width / 2, size.height / 2 + 15),
      cp,
    );
  }

  @override
  bool shouldRepaint(CustomPainter old) => false;
}
