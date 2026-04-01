import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  http.Client? _httpClient;

  // --- ПЕРЕМЕННЫЕ ДЛЯ ДВУХ ДАТЧИКОВ ---
  bool isMovingTooFast = false;
  bool _isAccelTooFast = false;
  bool _isGyroTooFast = false;

  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;

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

  // --- ЛОГИКА АНАЛИЗА ДВИЖЕНИЯ (ГИРОСКОП + АКСЕЛЕРОМЕТР) ---
  void _initSensors() {
    // 1. Акселерометр: ловит линейные рывки (вверх, вниз, влево, вправо)
    _accelSubscription = userAccelerometerEvents.listen((
      UserAccelerometerEvent event,
    ) {
      double magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _isAccelTooFast = magnitude > 0.8; // Чувствительность к тряске
      _updateMotionAlert();
    });

    // 2. Гироскоп: ловит быстрые повороты камеры (оглядывание)
    _gyroSubscription = gyroscopeEvents.listen((GyroscopeEvent event) {
      double magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      _isGyroTooFast = magnitude > 0.5; // Чувствительность к вращению
      _updateMotionAlert();
    });
  }

  void _updateMotionAlert() {
    bool shouldAlert = _isAccelTooFast || _isGyroTooFast;
    if (shouldAlert != isMovingTooFast) {
      setState(() {
        isMovingTooFast = shouldAlert;
      });
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _controller?.dispose();
    _httpClient?.close();
    super.dispose();
  }

  // --- ОТПРАВКА НА СЕРВЕР С ОТМЕНОЙ ---
  Future<void> uploadVideo() async {
    if (lastVideoPath == null) return;

    setState(() {
      isUploading = true;
      _httpClient = http.Client();
    });

    try {
      var uri = Uri.parse('http://192.168.31.11:8000/upload');
      var request = http.MultipartRequest('POST', uri);
      request.files.add(
        await http.MultipartFile.fromPath('video', lastVideoPath!),
      );

      var streamedResponse = await _httpClient!.send(request);

      if (streamedResponse.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Видео на сервере!'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          lastVideoPath = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🛑 Отправка прервана'),
          backgroundColor: Colors.orange,
        ),
      );
    } finally {
      setState(() {
        isUploading = false;
      });
    }
  }

  // --- КНОПКА ОТМЕНЫ ---
  void cancelUpload() {
    _httpClient?.close();
    setState(() {
      isUploading = false;
    });
  }

  // --- КНОПКА ЗАПИСИ ---
  Future<void> toggleRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (isRecording) {
      XFile videoFile = await _controller!.stopVideoRecording();
      setState(() {
        isRecording = false;
        lastVideoPath = videoFile.path;
      });
    } else {
      setState(() {
        lastVideoPath = null;
      });
      await _controller!.startVideoRecording();
      setState(() {
        isRecording = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Камера
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: CameraPreview(_controller!),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // 2. Красная вспышка при тряске или быстром повороте
          if (isMovingTooFast)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.2),
                  border: Border.all(color: Colors.red, width: 6),
                ),
              ),
            ),

          // 3. AR Сетка
          Positioned.fill(child: CustomPaint(painter: GridPainter())),

          // 4. Текст предупреждения
          if (isMovingTooFast)
            const Center(
              child: Text(
                'СЛИШКОМ БЫСТРО!\nРиск смазывания',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  backgroundColor: Colors.red,
                ),
              ),
            ),

          // 5. Чеклист (если не пишем и не загружаем)
          if (!isRecording && !isUploading && lastVideoPath == null)
            Positioned(
              top: 50,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.5),
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ПРАВИЛА СКАНИРОВАНИЯ:',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '• Плавные движения (следите за красной рамкой)',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    Text(
                      '• Матовые объекты, хорошее освещение',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),

          // --- ЛОГИКА НИЖНЕЙ ПАНЕЛИ (Взаимоисключающая) ---

          // А) СОСТОЯНИЕ 1: ИДЕТ ОТПРАВКА
          if (isUploading)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Colors.greenAccent),
                    const SizedBox(height: 20),
                    const Text(
                      'ОТПРАВКА НА СЕРВЕР...',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                    const SizedBox(height: 40),
                    OutlinedButton.icon(
                      onPressed: cancelUpload,
                      icon: const Icon(Icons.cancel, color: Colors.redAccent),
                      label: const Text('ОТМЕНИТЬ'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 30,
                          vertical: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          // Б) СОСТОЯНИЕ 2: ВИДЕО СНЯТО, ЖДЕТ ПОДТВЕРЖДЕНИЯ
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
                      'ВИДЕО ЗАПИСАНО',
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
                          label: const Text(
                            'Переснять',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 15,
                            ),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: uploadVideo,
                          icon: const Icon(Icons.memory, color: Colors.white),
                          label: const Text(
                            'Сгенерировать 3D',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          // В) СОСТОЯНИЕ 3: ГОТОВНОСТЬ ИЛИ ИДЕТ ЗАПИСЬ
          else
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
                        color: isRecording ? Colors.red : Colors.transparent,
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
                    isRecording
                        ? 'ЗАПИСЬ... (Двигайтесь плавно)'
                        : 'Нажмите для старта',
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
    );
  }
}

// Рисовка сетки
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      paint,
    );

    final centerPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.8)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width / 2 - 15, size.height / 2),
      Offset(size.width / 2 + 15, size.height / 2),
      centerPaint,
    );
    canvas.drawLine(
      Offset(size.width / 2, size.height / 2 - 15),
      Offset(size.width / 2, size.height / 2 + 15),
      centerPaint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
