import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class GuidedSelfieScreen extends StatefulWidget {
  final Function(File) onSelfieTaken;
  const GuidedSelfieScreen({Key? key, required this.onSelfieTaken})
      : super(key: key);

  @override
  _GuidedSelfieScreenState createState() => _GuidedSelfieScreenState();
}

class _GuidedSelfieScreenState extends State<GuidedSelfieScreen> {
  CameraController? _controller;
  late FaceDetector _faceDetector;
  bool _isProcessing = false;

  // Instruction state
  String currentInstruction = '';
  Timer? _timeoutTimer;
  bool _gestureDetected = false;

  // Blink state
  bool _blinkStarted = false;
  bool _blinkClosed = false;

  // Head-turn state
  int _currentHeadIndex = 0;
  bool _hasDetectedDirection = false;

  // persistent variables (class-level)
  double? _neutralY;
  double? _neutralX;
  double _lastHeadY = 0.0;
  double _lastHeadX = 0.0;

  // thresholds (tweakable)
  final double _turnThreshold = 50.0; // yaw degrees away from neutral
  final double _verticalThreshold = 40.0; // pitch degrees away from neutral
  final bool _enableDebug = true; 

  final List<String> _headDirections = ['right', 'left', 'down', 'up'];
  final List<String> instructions = ['blink', 'smile', 'turn_head'];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
          (cam) => cam.lensDirection == CameraLensDirection.front);
      _controller = CameraController(frontCamera, ResolutionPreset.medium);
      await _controller!.initialize();

      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableTracking: true,
          enableLandmarks: true,
          enableContours: false,
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.1,
        ),
      );

      setState(() {});
      _startNewGestureInstruction();
      _startDetectionLoop();
    } catch (e) {
      if (kDebugMode) print("Camera init error: $e");
      _showMessage("Camera initialization failed. Please check permissions.");
      Navigator.of(context).pop();
    }
  }

  void _startNewGestureInstruction() {
    currentInstruction = instructions[Random().nextInt(instructions.length)];
    _gestureDetected = false;
    _blinkStarted = false;
    _blinkClosed = false;
    _hasDetectedDirection = false;
    _currentHeadIndex = 0;

    // Reset calibration only for turn_head
    if (currentInstruction == 'turn_head') {
      _neutralY = null;
      _neutralX = null;
      if (_enableDebug) print("➡️ Starting turn_head sequence");
    }

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 50), () {
      if (!_gestureDetected) {
        _showMessage("❌ $currentInstruction not detected in time");
        Navigator.of(context).pop();
      }
    });

    setState(() {}); // update UI instruction text
  }

  Future<void> _startDetectionLoop() async {
    while (mounted && !_gestureDetected) {
      if (_isProcessing || _controller == null || !_controller!.value.isInitialized) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      try {
        _isProcessing = true;

        // Capture a still for detection (your previous approach)
        final file = await _controller!.takePicture();
        final inputImage = InputImage.fromFilePath(file.path);
        final faces = await _faceDetector.processImage(inputImage);

        if (_gestureDetected) break;

        if (faces.isNotEmpty) {
          await _handleFaceDetection(faces.first, file);
        }

        _isProcessing = false;
        await Future.delayed(const Duration(milliseconds: 120));
      } catch (e, st) {
        if (kDebugMode) {
          print("Detection error: $e");
          print(st);
        }
        _isProcessing = false;
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<void> _handleFaceDetection(Face face, XFile capturedFile) async {
    final headEulerY = face.headEulerAngleY ?? 0.0; // yaw
    final headEulerX = face.headEulerAngleX ?? 0.0; // pitch
    final smileProb = face.smilingProbability ?? 0.0;
    final leftEye = face.leftEyeOpenProbability ?? 1.0;
    final rightEye = face.rightEyeOpenProbability ?? 1.0;

    // keep last values for on-screen debug
    _lastHeadY = headEulerY;
    _lastHeadX = headEulerX;

    if (_enableDebug) {
      if (kDebugMode) print("Face angles raw => Y: $headEulerY, X: $headEulerX");
    }

    switch (currentInstruction) {
      case 'blink':
        final eyesOpen = leftEye > 0.7 && rightEye > 0.7;
        final eyesClosed = leftEye < 0.3 && rightEye < 0.3;

        if (!_blinkStarted && eyesOpen) {
          _blinkStarted = true;
          _blinkClosed = false;
          if (kDebugMode) print("👀 Eyes open - waiting for blink");
        }

        if (_blinkStarted && !_blinkClosed && eyesClosed) {
          _blinkClosed = true;
          if (kDebugMode) print("😑 Eyes closed - blink started");
        }

        if (_blinkStarted && _blinkClosed && eyesOpen) {
          _blinkStarted = false;
          _blinkClosed = false;
          _onGestureDetected("Blink");
          _captureSelfie(capturedFile);
          if (kDebugMode) print("✅ Blink detected!");
        }
        break;

      case 'smile':
        if (smileProb > 0.6) {
          _onGestureDetected("Smile");
          _captureSelfie(capturedFile);
          if (kDebugMode) print("😄 Smile detected!");
        }
        break;

      case 'turn_head':
        // 1) calibrate neutral once when entering this instruction
        if (_neutralY == null || _neutralX == null) {
          _neutralY = headEulerY;
          _neutralX = headEulerX;
          if (_enableDebug) {
            if (kDebugMode) print("🎯 Neutral set: Y=$_neutralY, X=$_neutralX");
          }
          // wait a frame before detecting movement
          return;
        }

        // Compute relative angles from neutral
        final relY = headEulerY - _neutralY!;
        final relX = headEulerX - _neutralX!;

        if (_enableDebug && kDebugMode) {
          print("📐 relY: ${relY.toStringAsFixed(2)}  relX: ${relX.toStringAsFixed(2)}  dirIndex: $_currentHeadIndex");
        }

        if (_currentHeadIndex < _headDirections.length) {
          final direction = _headDirections[_currentHeadIndex];
          bool detected = false;

          switch (direction) {
            case 'right':
              // front camera mirror: right often gives negative yaw relative to neutral
              detected = relY < -_turnThreshold;
              break;
            case 'left':
              detected = relY > _turnThreshold;
              break;
            case 'down':
  // Pitching head up is negative in many face APIs
            detected = relX < -_verticalThreshold;
            break;
            case 'up':
            detected = relX > _verticalThreshold;
            break;
            }

          // If we detected the requested direction and we're not in cooldown
          if (detected && !_hasDetectedDirection) {
            _hasDetectedDirection = true;

            // Immediately advance instruction (per your request)
            setState(() {
              _currentHeadIndex++;
            });

            if (kDebugMode) print("✅ $direction detected → next index: $_currentHeadIndex");

            // If done, capture selfie
            if (_currentHeadIndex >= _headDirections.length) {
              _onGestureDetected('Head Turn');
              _captureSelfie(capturedFile);
              return;
            }

            // cooldown: avoid multiple increments while user still holds the head turn
            Future.delayed(const Duration(milliseconds: 800), () {
              _hasDetectedDirection = false;
              if (kDebugMode) print("🔁 cooldown ended, ready for next direction");
            });
          }
        }
        break;

      default:
        break;
    }
  }

  void _onGestureDetected(String gestureName) {
    _gestureDetected = true;
    _timeoutTimer?.cancel();
    _showMessage("✅ $gestureName detected!");
  }

  void _captureSelfie(XFile capturedFile) {
    try {
      widget.onSelfieTaken(File(capturedFile.path));
    } catch (e) {
      if (kDebugMode) print("Error sending selfie file: $e");
    }
    Navigator.of(context).pop();
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Guided Selfie"),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: _controller != null && _controller!.value.isInitialized
          ? Stack(
              children: [
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(pi), // mirror preview to user
                  child: CameraPreview(_controller!),
                ),

                // instruction text
                Positioned(
                  bottom: 32,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      _getInstructionText(),
                      style: const TextStyle(color: Colors.white, fontSize: 20),
                    ),
                  ),
                ),

                // small debug overlay (only when enabled)
                if (_enableDebug)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("instr: $currentInstruction",
                              style: const TextStyle(color: Colors.white)),
                          Text("idx: $_currentHeadIndex / ${_headDirections.length}",
                              style: const TextStyle(color: Colors.white)),
                          Text("lastY: ${_lastHeadY.toStringAsFixed(2)}",
                              style: const TextStyle(color: Colors.white)),
                          Text("lastX: ${_lastHeadX.toStringAsFixed(2)}",
                              style: const TextStyle(color: Colors.white)),
                          if (_neutralY != null)
                            Text("neutralY: ${_neutralY!.toStringAsFixed(2)}",
                                style: const TextStyle(color: Colors.white)),
                          if (_neutralX != null)
                            Text("neutralX: ${_neutralX!.toStringAsFixed(2)}",
                                style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  String _getInstructionText() {
    switch (currentInstruction) {
      case 'blink':
        return 'Please blink your eyes';
      case 'smile':
        return 'Please smile';
      case 'turn_head':
        if (_currentHeadIndex < _headDirections.length) {
          return 'Please turn your head ${_headDirections[_currentHeadIndex]}';
        } else {
          return 'Please look straight ahead';
        }
      default:
        return '';
    }
  }
}
