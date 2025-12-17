import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:yolo/common/input_image_converter.dart';

import '../common/colors.dart';
import '../models/detection.dart';
import '../paint/detection_painter.dart';
import '../view/camera_error_view.dart';

class MediaPipeFacePage extends StatefulWidget {
  const MediaPipeFacePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<MediaPipeFacePage> createState() => _MediaPipeFacePageState();
}

class _MediaPipeFacePageState extends State<MediaPipeFacePage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  String? _errorMessage;
  bool _isInitializing = true;
  bool _isCameraActive = false;
  bool _isCameraBusy = false;
  bool _isChangingCamera = false;
  int _currentCameraIndex = 0;
  bool _isDetectionActive = false;
  bool _isProcessingFrame = false;
  static const Duration _cameraFpsUpdateInterval =
      Duration(milliseconds: 200);
  double _cameraFps = 0;
  double _detectionFps = 0;
  DateTime? _lastCameraFrameTime;
  DateTime? _lastCameraFpsUpdateTime;
  List<Detection> _detections = const [];
  late final FaceDetector _faceDetector;
  final InputImageConverter _inputImageConverter = InputImageConverter();

  @override
  void initState() {
    super.initState();
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        enableClassification: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (widget.cameras.isEmpty) {
        throw StateError('No available cameras on this device.');
      }
      _currentCameraIndex = _preferredCameraIndex;
    } catch (error) {
      _errorMessage = '$error';
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      } else {
        _isInitializing = false;
      }
    }
  }

  int get _preferredCameraIndex {
    if (widget.cameras.isEmpty) {
      throw StateError('No cameras found on this device.');
    }
    final index = widget.cameras.indexWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
    return index == -1 ? 0 : index;
  }

  CameraDescription get _currentCamera => widget.cameras[_currentCameraIndex];

  Future<bool> _initializeCamera(CameraDescription description) async {
    final previousController = _cameraController;
    if (previousController != null) {
      if (previousController.value.isStreamingImages) {
        await previousController.stopImageStream();
      }
      if (mounted) {
        setState(() {
          _cameraController = null;
        });
      } else {
        _cameraController = null;
      }
      await previousController.dispose();
    }
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    _cameraController = controller;

    try {
      await controller.initialize();
      _clearCameraFps();
      _clearDetections();
      await _startImageStreamIfNeeded();
      if (mounted) {
        setState(() {});
      }
      return true;
    } on CameraException catch (error) {
      await controller.dispose();
      _cameraController = null;
      _errorMessage = 'Camera error: ${error.description ?? error.code}';
      if (mounted) {
        setState(() {});
      }
      return false;
    } catch (error) {
      await controller.dispose();
      _cameraController = null;
      _errorMessage = 'Camera stream error: $error';
      if (mounted) {
        setState(() {});
      }
      return false;
    }
  }

  Future<void> _startImageStreamIfNeeded() async {
    final controller = _cameraController;
    if (controller == null || controller.value.isStreamingImages) {
      return;
    }
    await controller.startImageStream(_processCameraImage);
  }

  void _updateCameraFps(DateTime timestamp) {
    final previousTimestamp = _lastCameraFrameTime;
    _lastCameraFrameTime = timestamp;
    if (previousTimestamp == null) {
      return;
    }
    final elapsedMicros =
        timestamp.difference(previousTimestamp).inMicroseconds;
    if (elapsedMicros <= 0) {
      return;
    }
    final fps = 1000000.0 / elapsedMicros;
    final lastUpdate = _lastCameraFpsUpdateTime;
    if (lastUpdate != null &&
        timestamp.difference(lastUpdate) < _cameraFpsUpdateInterval) {
      return;
    }
    _lastCameraFpsUpdateTime = timestamp;
    if (mounted) {
      setState(() {
        _cameraFps = fps;
      });
    } else {
      _cameraFps = fps;
    }
  }

  void _clearCameraFps() {
    _lastCameraFrameTime = null;
    _lastCameraFpsUpdateTime = null;
    _cameraFps = 0;
  }

  void _clearDetections() {
    _detections = const [];
    _detectionFps = 0;
    _isProcessingFrame = false;
  }

  Future<void> _reinitializeCurrentCamera() async {
    final initialized = await _initializeCamera(_currentCamera);
    if (!initialized) {
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _isDetectionActive = false;
          _clearCameraFps();
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _clearCameraFps();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      if (mounted) {
        setState(() {
          _cameraController = null;
          _isCameraActive = false;
          _isDetectionActive = false;
          _clearDetections();
          _clearCameraFps();
        });
      } else {
        _cameraController = null;
        _isCameraActive = false;
        _isDetectionActive = false;
        _clearDetections();
        _clearCameraFps();
      }
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (_isCameraActive) {
        _reinitializeCurrentCamera();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final isCameraAvailable =
        _isCameraActive && controller != null && controller.value.isInitialized;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: DEFAULT_BG,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        elevation: 0,
        backgroundColor: DEFAULT_BG,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "MediaPipe Face",
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _errorMessage != null
            ? CameraErrorView(
                message: _errorMessage ?? 'An unknown error occurred.',
              )
            : _isInitializing
                ? const Center(child: CircularProgressIndicator())
                : AnimatedPadding(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    padding: EdgeInsets.only(bottom: bottomInset),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      width: double.infinity,
                      height: double.infinity,
                      decoration: const BoxDecoration(color: DEFAULT_BG),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            padding:
                                EdgeInsets.only(bottom: 12.h, top: 12.h),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildCameraPreview(isCameraAvailable),
                                  SizedBox(height: 20.h),
                                  _buildControlButtons(),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _buildCameraPreview(bool isCameraAvailable) {
    final controller = _cameraController;
    final isControllerReady = controller?.value.isInitialized == true;
    final previewSize = isControllerReady ? controller!.value.previewSize : null;
    final previewSizeText = previewSize != null
        ? '${previewSize.width.toStringAsFixed(0)} x ${previewSize.height.toStringAsFixed(0)}'
        : 'Unknown';
    final previewAspectRatio = (previewSize != null && previewSize.width != 0)
        ? previewSize.height / previewSize.width
        : 3 / 4;
    final isBackCamera =
        controller?.description.lensDirection == CameraLensDirection.back;
    final borderRadius = BorderRadius.circular(20.r);
    final innerRadius = BorderRadius.circular(18.r);
    final previewWidth = 280.w;
    final previewHeight = previewWidth / previewAspectRatio;
    final cameraLabel = isBackCamera ? 'Back camera' : 'Front camera';
    final fpsText =
        'Cam: ${_cameraFps > 0 ? _cameraFps.toStringAsFixed(1) : '--'} fps\n'
        'Face: ${_detectionFps > 0 ? _detectionFps.toStringAsFixed(1) : '--'} fps';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: previewWidth * 1.05,
              decoration:
                  BoxDecoration(color: Colors.black54, borderRadius: borderRadius),
              child: AspectRatio(
                aspectRatio: previewAspectRatio,
                child: ClipRRect(
                  borderRadius: innerRadius,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: previewWidth,
                        height: previewHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (isCameraAvailable && controller != null)
                              ClipRRect(
                                borderRadius: borderRadius,
                                child: Transform(
                                  alignment: Alignment.center,
                                  transform: isBackCamera
                                      ? Matrix4.identity()
                                      : (Matrix4.identity()
                                        ..rotateY(math.pi)),
                                  child: CameraPreview(controller),
                                ),
                              )
                            else
                              AspectRatio(
                                aspectRatio: previewAspectRatio,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: borderRadius,
                                  ),
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'start capture',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                              ),
                            if (isCameraAvailable && controller != null)
                              Positioned.fill(
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    isComplex: true,
                                    painter: DetectionPainter(
                                      detections: _detections,
                                      showConfidence: false,
                                    ),
                                  ),
                                ),
                              ),
                            if (isCameraAvailable && controller != null)
                              Positioned(
                                top: 12.h,
                                right: 12.w,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    fpsText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ),
                            Positioned(
                              bottom: 12.h,
                              left: 12.w,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Faces: ${_detections.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8.h),
          child: Text(
            'Preview: $previewSizeText • $cameraLabel • Faces: ${_detections.length}',
            style: const TextStyle(color: Colors.black87),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildControlButtons() {
    final controller = _cameraController;
    final isControllerReady =
        controller != null && controller.value.isInitialized;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isCameraBusy ? null : _toggleCamera,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _isCameraActive ? Colors.redAccent : Colors.greenAccent,
                foregroundColor: Colors.black,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
              ),
              icon: Icon(
                _isCameraActive ? Icons.stop : Icons.videocam,
                color: Colors.black,
              ),
              label: Text(_isCameraActive ? 'Stop Cam' : 'Start Cam'),
            ),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (!_isCameraActive ||
                      _isCameraBusy ||
                      !isControllerReady)
                  ? null
                  : _toggleDetection,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isDetectionActive
                    ? Colors.orangeAccent
                    : Colors.blueAccent,
                foregroundColor: Colors.black,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
              ),
              icon: Icon(
                _isDetectionActive ? Icons.pause : Icons.play_arrow,
                color: Colors.black,
              ),
              label: Text(
                  _isDetectionActive ? 'Stop Detect' : 'Start Detect'),
            ),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (widget.cameras.length < 2 ||
                      _isChangingCamera ||
                      _isCameraBusy ||
                      !_isCameraActive ||
                      !isControllerReady)
                  ? null
                  : _switchCamera,
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
              ),
              icon: const Icon(Icons.cameraswitch),
              label: const Text('Switch'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleCamera() async {
    if (_isCameraBusy) {
      return;
    }
    if (_isCameraActive) {
      await _stopCamera();
    } else {
      await _startCamera();
    }
  }

  Future<void> _startCamera() async {
    if (_isCameraBusy || _isCameraActive) {
      return;
    }
    if (mounted) {
      setState(() {
        _isCameraBusy = true;
        _errorMessage = null;
        _isDetectionActive = false;
        _clearDetections();
      });
    } else {
      _isCameraBusy = true;
      _errorMessage = null;
      _isDetectionActive = false;
      _clearDetections();
    }
    try {
      final initialized = await _initializeCamera(_currentCamera);
      if (mounted) {
        setState(() {
          _isCameraActive = initialized;
          _clearCameraFps();
        });
      } else {
        _isCameraActive = initialized;
        _clearCameraFps();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCameraBusy = false;
        });
      } else {
        _isCameraBusy = false;
      }
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    if (controller == null || !_isCameraActive) {
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _isDetectionActive = false;
          _clearCameraFps();
          _clearDetections();
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _clearCameraFps();
        _clearDetections();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isCameraBusy = true;
        _isCameraActive = false;
        _isDetectionActive = false;
        _clearCameraFps();
        _clearDetections();
      });
    } else {
      _isCameraBusy = true;
      _isCameraActive = false;
      _isDetectionActive = false;
      _clearCameraFps();
      _clearDetections();
    }

    _cameraController = null;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    } catch (error) {
      _errorMessage ??= '$error';
    } finally {
      if (mounted) {
        setState(() {
          _isCameraBusy = false;
        });
      } else {
        _isCameraBusy = false;
      }
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2 ||
        _isChangingCamera ||
        _isCameraBusy ||
        !_isCameraActive) {
      return;
    }
    final nextIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    if (mounted) {
      setState(() {
        _isChangingCamera = true;
        _currentCameraIndex = nextIndex;
      });
    } else {
      _isChangingCamera = true;
      _currentCameraIndex = nextIndex;
    }

    try {
      if (_isCameraActive) {
        final initialized = await _initializeCamera(widget.cameras[nextIndex]);
        if (!initialized) {
          if (mounted) {
            setState(() {
              _isCameraActive = false;
            });
          } else {
            _isCameraActive = false;
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isChangingCamera = false;
        });
      } else {
        _isChangingCamera = false;
      }
    }
  }

  void _processCameraImage(CameraImage cameraImage) {
    if (_isProcessingFrame) {
      return;
    }
    _updateCameraFps(DateTime.now());
    if (_cameraController == null || !_isCameraActive || !_isDetectionActive) {
      return;
    }
    _isProcessingFrame = true;
    _runFaceDetection(cameraImage, _cameraController!).whenComplete(() {
      _isProcessingFrame = false;
    });
  }

  Future<void> _runFaceDetection(
    CameraImage cameraImage,
    CameraController controller,
  ) async {
    final startTime = DateTime.now();
    try {
      final inputImage = _inputImageConverter.fromCameraImage(image: cameraImage, controller: controller, camera: _currentCamera);
      if (inputImage == null) {
        return;
      }
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted || !_isCameraActive || !_isDetectionActive) {
        return;
      }
      final rotation = _inputImageRotation(controller.description.sensorOrientation);
      if (rotation == null) {
        return;
      }
      final detections = _mapFacesToDetections(
        faces: faces,
        imageSize: Size(
          cameraImage.width.toDouble(),
          cameraImage.height.toDouble(),
        ),
        rotation: rotation,
        lensDirection: controller.description.lensDirection,
      );
      final detectionDuration =
          DateTime.now().difference(startTime).inMicroseconds;
      final detectionFps =
          detectionDuration > 0 ? 1000000.0 / detectionDuration : 0.0;
      if (mounted) {
        setState(() {
          _detections = detections;
          _detectionFps = detectionFps;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage ??= '$error';
        });
      } else {
        _errorMessage ??= '$error';
      }
    }
  }

  InputImageRotation? _inputImageRotation(int sensorOrientation) {
    return InputImageRotationValue.fromRawValue(sensorOrientation);
  }

  Size _adjustedImageSize(Size imageSize, InputImageRotation rotation) {
    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      return Size(imageSize.height, imageSize.width);
    }
    return imageSize;
  }

  List<Detection> _mapFacesToDetections({
    required List<Face> faces,
    required Size imageSize,
    required InputImageRotation rotation,
    required CameraLensDirection lensDirection,
  }) {
    final adjustedSize = _adjustedImageSize(imageSize, rotation);
    return faces.map((face) {
      double left = face.boundingBox.left / adjustedSize.width;
      double top = face.boundingBox.top / adjustedSize.height;
      double right = face.boundingBox.right / adjustedSize.width;
      double bottom = face.boundingBox.bottom / adjustedSize.height;

      left = left.clamp(0.0, 1.0);
      top = top.clamp(0.0, 1.0);
      right = right.clamp(0.0, 1.0);
      bottom = bottom.clamp(0.0, 1.0);

      return Detection(
        boundingBox: Rect.fromLTRB(left, top, right, bottom),
        confidence: 1,
        label:
            face.trackingId != null ? 'Face #${face.trackingId}' : 'Face',
      );
    }).toList();
  }

  Future<void> _toggleDetection() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isCameraBusy) {
      return;
    }
    if (_isDetectionActive) {
      _isProcessingFrame = false;
      if (mounted) {
        setState(() {
          _isDetectionActive = false;
          _clearDetections();
        });
      } else {
        _isDetectionActive = false;
        _clearDetections();
      }
      return;
    }

    try {
      await _startImageStreamIfNeeded();
      if (mounted) {
        setState(() {
          _isDetectionActive = true;
          _clearDetections();
        });
      } else {
        _isDetectionActive = true;
        _clearDetections();
      }
    } on CameraException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Detection start error: ${error.description ?? error.code}';
        });
      } else {
        _errorMessage =
            'Detection start error: ${error.description ?? error.code}';
      }
    }
  }
}
