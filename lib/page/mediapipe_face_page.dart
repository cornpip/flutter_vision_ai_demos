import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';
import 'package:yolo/common/input_image_converter.dart';

import '../common/colors.dart';
import '../models/detection.dart';
import '../paint/detection_painter.dart';
import '../paint/face_mesh_painter.dart';
import '../view/camera_error_view.dart';

class MediaPipeFacePage extends StatefulWidget {
  const MediaPipeFacePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<MediaPipeFacePage> createState() => _MediaPipeFacePageState();
}

class _MediaPipeFacePageState extends State<MediaPipeFacePage>
    with WidgetsBindingObserver {
  static const Map<DeviceOrientation, int> _deviceOrientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  CameraController? _cameraController;
  String? _errorMessage;
  bool _isInitializing = true;
  bool _isCameraActive = false;
  bool _isCameraBusy = false;
  bool _isChangingCamera = false;
  int _currentCameraIndex = 0;
  int? _backCameraIndex;
  int? _frontCameraIndex;
  bool _isDetectionActive = false;
  bool _isMeshActive = false;
  bool _isProcessingFrame = false;
  static const Duration _cameraFpsUpdateInterval =
      Duration(milliseconds: 200);
  double _cameraFps = 0;
  DateTime? _lastCameraFrameTime;
  DateTime? _lastCameraFpsUpdateTime;
  DateTime? _lastMeshLogTime;
  DateTime? _lastNv21LayoutLogTime;
  DateTime? _lastRoiMapLogTime;
  List<Detection> _detections = const [];
  FaceMeshResult? _meshResult;
  int? _meshRotationCompensation;
  CameraLensDirection? _meshLensDirection;
  late final FaceDetector _faceDetector;
  MediapipeFaceMesh? _faceMesh;
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
      _resolveCameraIndices();
      if (_backCameraIndex == null &&
          _frontCameraIndex == null &&
          widget.cameras.isNotEmpty) {
        _currentCameraIndex = 0;
      }

      final mesh = await MediapipeFaceMesh.create();
      setState(() {
        _faceMesh = mesh;
      });
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

  void _resolveCameraIndices() {
    _backCameraIndex = _preferredCameraIndexFor(
      direction: CameraLensDirection.back,
      preferredLensType: CameraLensType.wide,
    );
    _frontCameraIndex = _preferredCameraIndexFor(
      direction: CameraLensDirection.front,
      preferredLensType: CameraLensType.wide,
    );
    if (_backCameraIndex != null) {
      _currentCameraIndex = _backCameraIndex!;
    } else if (_frontCameraIndex != null) {
      _currentCameraIndex = _frontCameraIndex!;
    }
  }

  int? _preferredCameraIndexFor({
    required CameraLensDirection direction,
    CameraLensType preferredLensType = CameraLensType.wide,
  }) {
    if (widget.cameras.isEmpty) {
      return null;
    }
    int? preferred;
    int? fallback;
    for (var i = 0; i < widget.cameras.length; i++) {
      final camera = widget.cameras[i];
      if (camera.lensDirection != direction) {
        continue;
      }
      fallback ??= i;
      if (camera.lensType == preferredLensType) {
        preferred ??= i;
      }
    }
    return preferred ?? fallback;
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
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
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
    _isProcessingFrame = false;
  }

  void _clearMesh() {
    _meshResult = null;
    _meshRotationCompensation = null;
    _meshLensDirection = null;
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
          _isMeshActive = false;
          _clearMesh();
          _clearDetections();
          _clearCameraFps();
        });
      } else {
        _cameraController = null;
        _isCameraActive = false;
        _isDetectionActive = false;
        _isMeshActive = false;
        _clearMesh();
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
    _faceMesh?.close();
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
        'Cam: ${_cameraFps > 0 ? _cameraFps.toStringAsFixed(1) : '--'} fps';

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
                                      lensDirection:
                                          controller.description.lensDirection,
                                      showConfidence: false,
                                    ),
                                  ),
                                ),
                              ),
                            if (isCameraAvailable &&
                                controller != null &&
                                _meshResult != null)
                              Positioned.fill(
                                child: RepaintBoundary(
                                child: IgnorePointer(
                                    child: CustomPaint(
                                      isComplex: true,
                                      painter: FaceMeshPainter(
                                        result: _meshResult!,
                                        rotationCompensation:
                                            _meshRotationCompensation ?? 0,
                                        lensDirection: _meshLensDirection ??
                                            CameraLensDirection.back,
                                      ),
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
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isCameraBusy ? null : _toggleCamera,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isCameraActive ? Colors.redAccent : Colors.greenAccent,
                    foregroundColor: Colors.black,
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
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
                  onPressed: (!_isCameraActive || _isCameraBusy || !isControllerReady)
                      ? null
                      : _toggleDetection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDetectionActive
                        ? Colors.orangeAccent
                        : Colors.blueAccent,
                    foregroundColor: Colors.black,
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: Icon(
                    _isDetectionActive ? Icons.pause : Icons.play_arrow,
                    color: Colors.black,
                  ),
                  label: Text(
                      _isDetectionActive ? 'Stop Detect' : 'Start Detect'),
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!_isCameraActive ||
                          _isCameraBusy ||
                          !isControllerReady ||
                          !_isDetectionActive ||
                          _faceMesh == null)
                      ? null
                      : _toggleMesh,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isMeshActive ? Colors.purpleAccent : Colors.purple,
                    foregroundColor: Colors.black,
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: Icon(
                    _isMeshActive ? Icons.stop_circle : Icons.blur_on,
                    color: Colors.black,
                  ),
                  label: Text(_isMeshActive ? 'Stop Mesh' : 'Start Mesh'),
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
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: const Icon(Icons.cameraswitch),
                  label: const Text('Switch'),
                ),
              ),
            ],
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
        _isMeshActive = false;
        _clearMesh();
        _clearDetections();
      });
    } else {
      _isCameraBusy = true;
      _errorMessage = null;
      _isDetectionActive = false;
      _isMeshActive = false;
      _clearMesh();
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
          _isMeshActive = false;
          _clearMesh();
          _clearCameraFps();
          _clearDetections();
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _isMeshActive = false;
        _clearMesh();
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
        _isMeshActive = false;
        _clearMesh();
        _clearCameraFps();
        _clearDetections();
      });
    } else {
      _isCameraBusy = true;
      _isCameraActive = false;
      _isDetectionActive = false;
      _isMeshActive = false;
      _clearMesh();
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
    final currentLens = _currentCamera.lensDirection;
    int? nextIndex;
    if (currentLens == CameraLensDirection.back) {
      nextIndex = _frontCameraIndex ?? _backCameraIndex;
    } else {
      nextIndex = _backCameraIndex ?? _frontCameraIndex;
    }
    if (nextIndex == null || nextIndex == _currentCameraIndex) {
      return;
    }
    if (mounted) {
      setState(() {
        _isChangingCamera = true;
        _currentCameraIndex = nextIndex!;
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
    try {
      final inputImage = _inputImageConverter.fromCameraImage(
        image: cameraImage,
        controller: controller,
        camera: _currentCamera,
      );
      if (inputImage == null) {
        return;
      }
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted || !_isCameraActive || !_isDetectionActive) {
        return;
      }

      FaceMeshResult? meshResult;
      int? meshRotationCompensation;
      if (_isMeshActive && faces.isNotEmpty) {
        final mesh = _faceMesh;
        if (mesh != null) {
          if (Platform.isAndroid) {
            meshRotationCompensation = _rotationCompensationDegrees(
              controller: controller,
              camera: _currentCamera,
            );
            meshResult = _runFaceMeshOnAndroidNv21(
              mesh: mesh,
              cameraImage: cameraImage,
              controller: controller,
              camera: _currentCamera,
              face: faces.first,
              rotationCompensationDegrees: meshRotationCompensation,
            );
          } else if (Platform.isIOS) {
            meshRotationCompensation = _inputImageConverter
                .rotationFor(controller: controller, camera: _currentCamera)
                ?.rawValue;
            meshResult = _runFaceMeshOnIosBgra(
              mesh: mesh,
              cameraImage: cameraImage,
              face: faces.first,
              rotationCompensationDegrees: meshRotationCompensation,
            );
          }
          if (meshResult != null) {
            _logMeshResult(
              cameraImage: cameraImage,
              controller: controller,
              camera: _currentCamera,
              face: faces.first,
              result: meshResult,
            );
          }
        }
      }

      // detection
      final rotation = _inputImageConverter.rotationFor(
        controller: controller,
        camera: _currentCamera,
      );
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
      if (mounted) {
        setState(() {
          _detections = detections;
          if (_isMeshActive) {
            _meshResult = meshResult;
            // Mesh output is already expressed in the rotated coordinate system.
            _meshRotationCompensation = 0;
            _meshLensDirection = controller.description.lensDirection;
          }
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

  FaceMeshResult? _runFaceMeshOnAndroidNv21({
    required MediapipeFaceMesh mesh,
    required CameraImage cameraImage,
    required CameraController controller,
    required CameraDescription camera,
    required Face face,
    required int? rotationCompensationDegrees,
  }) {
    if (!Platform.isAndroid) {
      return null;
    }

    final now = DateTime.now();
    final lastLayoutLog = _lastNv21LayoutLogTime;
    if (lastLayoutLog == null ||
        now.difference(lastLayoutLog) >= const Duration(seconds: 1)) {
      _lastNv21LayoutLogTime = now;
      debugPrint(
        '[NV21 Layout] img=${cameraImage.width}x${cameraImage.height}'
        ' group=${cameraImage.format.group} raw=${cameraImage.format.raw}'
        ' planes=${cameraImage.planes.length}',
      );
      for (var i = 0; i < cameraImage.planes.length; i++) {
        final p = cameraImage.planes[i];
        debugPrint(
          '[NV21 Layout] plane$i'
          ' bytes=${p.bytes.length}'
          ' bytesPerRow=${p.bytesPerRow}'
          ' bytesPerPixel=${p.bytesPerPixel}'
          ' w=${p.width}'
          ' h=${p.height}',
        );
      }
      if (cameraImage.planes.length == 1) {
        final p0 = cameraImage.planes.first;
        final chromaHeight = (cameraImage.height + 1) ~/ 2;
        final expectedY = p0.bytesPerRow * cameraImage.height;
        final expectedVu = p0.bytesPerRow * chromaHeight;
        final expectedTotal = expectedY + expectedVu;
        debugPrint(
          '[NV21 Layout] planes=1 expected'
          ' chromaHeight=$chromaHeight'
          ' ySize=$expectedY'
          ' vuSize=$expectedVu'
          ' total=$expectedTotal'
          ' actual=${p0.bytes.length}',
        );
      }
    }

    final planes = cameraImage.planes;
    if (planes.isEmpty) {
      return null;
    }

    Uint8List yPlane;
    Uint8List vuPlane;
    int yBytesPerRow;
    int vuBytesPerRow;

    if (planes.length >= 2) {
      yPlane = planes[0].bytes;
      vuPlane = planes[1].bytes;
      yBytesPerRow = planes[0].bytesPerRow;
      vuBytesPerRow = planes[1].bytesPerRow;
    } else {
      final Plane plane = planes.first;
      final int width = cameraImage.width;
      final int height = cameraImage.height;
      final int rowStride = plane.bytesPerRow;
      final int ySize = rowStride * height;
      final int chromaHeight = (height + 1) ~/ 2;
      final int vuSize = rowStride * chromaHeight;
      if (plane.bytes.length < ySize + vuSize) {
        return null;
      }
      final Uint8List bytes = plane.bytes;
      yPlane = Uint8List.sublistView(bytes, 0, ySize);
      vuPlane = Uint8List.sublistView(bytes, ySize, ySize + vuSize);
      yBytesPerRow = rowStride;
      vuBytesPerRow = rowStride;
    }

    final FaceMeshNv21Image nv21 = FaceMeshNv21Image(
      yPlane: yPlane,
      vuPlane: vuPlane,
      width: cameraImage.width,
      height: cameraImage.height,
      yBytesPerRow: yBytesPerRow,
      vuBytesPerRow: vuBytesPerRow,
    );

    final rotationCompensation = rotationCompensationDegrees;
    if (rotationCompensation == null) {
      return null;
    }
    final inputImageRotation =
        InputImageRotationValue.fromRawValue(rotationCompensation);
    if (inputImageRotation == null) {
      return null;
    }

    // ML Kit returns bounding boxes in the coordinate system after applying
    // `rotationCompensation`. Use that box directly and let the native mesh
    // implementation apply the same rotation metadata to NV21 sampling.
    final adjustedSize = _adjustedImageSize(
      Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
      inputImageRotation,
    );
    final bbox = face.boundingBox;
    final clamped = Rect.fromLTRB(
      bbox.left.clamp(0.0, adjustedSize.width),
      bbox.top.clamp(0.0, adjustedSize.height),
      bbox.right.clamp(0.0, adjustedSize.width),
      bbox.bottom.clamp(0.0, adjustedSize.height),
    );

    final FaceMeshBox box = FaceMeshBox.fromLTWH(
      left: clamped.left,
      top: clamped.top,
      width: clamped.width,
      height: clamped.height,
    );

    final roiLogNow = DateTime.now();
    final lastRoiLog = _lastRoiMapLogTime;
    if (lastRoiLog == null ||
        roiLogNow.difference(lastRoiLog) >= const Duration(seconds: 1)) {
      _lastRoiMapLogTime = roiLogNow;
      debugPrint(
        '[ROI_MAP]'
        ' rotCompDeg=$rotationCompensation'
        ' mlkit=$bbox'
        ' clamped=$clamped'
        ' raw=${cameraImage.width}x${cameraImage.height}'
        ' adjusted=${adjustedSize.width.toStringAsFixed(0)}x${adjustedSize.height.toStringAsFixed(0)}',
      );
    }

    return mesh.processNv21(
      nv21,
      box: box,
      boxScale: 1.2,
      boxMakeSquare: true,
      rotationDegrees: rotationCompensation,
    );
  }

  FaceMeshResult? _runFaceMeshOnIosBgra({
    required MediapipeFaceMesh mesh,
    required CameraImage cameraImage,
    required Face face,
    required int? rotationCompensationDegrees,
  }) {
    if (!Platform.isIOS) {
      return null;
    }
    final planes = cameraImage.planes;
    if (planes.isEmpty) {
      return null;
    }
    final rotationCompensation = rotationCompensationDegrees;
    if (rotationCompensation == null) {
      return null;
    }
    final inputImageRotation =
        InputImageRotationValue.fromRawValue(rotationCompensation);
    if (inputImageRotation == null) {
      return null;
    }
    final Plane plane = planes.first;
    final FaceMeshImage image = FaceMeshImage(
      pixels: plane.bytes,
      width: cameraImage.width,
      height: cameraImage.height,
      bytesPerRow: plane.bytesPerRow,
      pixelFormat: FaceMeshPixelFormat.bgra,
    );
    final adjustedSize = _adjustedImageSize(
      Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
      inputImageRotation,
    );
    final bbox = face.boundingBox;
    final clamped = Rect.fromLTRB(
      bbox.left.clamp(0.0, adjustedSize.width),
      bbox.top.clamp(0.0, adjustedSize.height),
      bbox.right.clamp(0.0, adjustedSize.width),
      bbox.bottom.clamp(0.0, adjustedSize.height),
    );
    final FaceMeshBox box = FaceMeshBox.fromLTWH(
      left: clamped.left,
      top: clamped.top,
      width: clamped.width,
      height: clamped.height,
    );
    return mesh.process(
      image,
      box: box,
      boxScale: 1.2,
      boxMakeSquare: true,
      rotationDegrees: rotationCompensation,
    );
  }

  int? _rotationCompensationDegrees({
    required CameraController controller,
    required CameraDescription camera,
  }) {
    final deviceRotation = _deviceOrientationDegrees[controller.value.deviceOrientation];
    if (deviceRotation == null) {
      return null;
    }
    if (camera.lensDirection == CameraLensDirection.front) {
      return (camera.sensorOrientation + deviceRotation) % 360;
    }
    return (camera.sensorOrientation - deviceRotation + 360) % 360;
  }

  void _logMeshResult({
    required CameraImage cameraImage,
    required CameraController controller,
    required CameraDescription camera,
    required Face face,
    required FaceMeshResult result,
  }) {
    final now = DateTime.now();
    final last = _lastMeshLogTime;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastMeshLogTime = now;

    final roi = result.rect;
    final bbox = face.boundingBox;
    final lms = result.landmarks;

    double minX = double.infinity;
    double maxX = -double.infinity;
    double minY = double.infinity;
    double maxY = -double.infinity;
    double minZ = double.infinity;
    double maxZ = -double.infinity;
    for (final lm in lms) {
      minX = math.min(minX, lm.x);
      maxX = math.max(maxX, lm.x);
      minY = math.min(minY, lm.y);
      maxY = math.max(maxY, lm.y);
      minZ = math.min(minZ, lm.z);
      maxZ = math.max(maxZ, lm.z);
    }

    final deviceOrientation = controller.value.deviceOrientation;
    final deviceRotation = _deviceOrientationDegrees[deviceOrientation];
    int? rotationCompensation;
    if (deviceRotation != null) {
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (camera.sensorOrientation + deviceRotation) % 360;
      } else {
        rotationCompensation =
            (camera.sensorOrientation - deviceRotation + 360) % 360;
      }
    }
    final inputImageRotation =
        rotationCompensation != null
            ? InputImageRotationValue.fromRawValue(rotationCompensation)
            : null;

    final adjustedSize = (inputImageRotation == InputImageRotation.rotation90deg ||
            inputImageRotation == InputImageRotation.rotation270deg)
        ? Size(cameraImage.height.toDouble(), cameraImage.width.toDouble())
        : Size(cameraImage.width.toDouble(), cameraImage.height.toDouble());

    debugPrint(
      '[FRAME]'
      ' w=${cameraImage.width} h=${cameraImage.height}'
      ' group=${cameraImage.format.group} raw=${cameraImage.format.raw}'
      ' planes=${cameraImage.planes.length}'
      ' yStride=${cameraImage.planes.isNotEmpty ? cameraImage.planes[0].bytesPerRow : 'n/a'}'
      ' vuStride=${cameraImage.planes.length > 1 ? cameraImage.planes[1].bytesPerRow : 'n/a'}',
    );
    debugPrint(
      '[ORIENTATION]'
      ' lens=${camera.lensDirection}'
      ' sensorOrientation=${camera.sensorOrientation}'
      ' deviceOrientation=$deviceOrientation'
      ' deviceRotationDeg=${deviceRotation ?? 'n/a'}'
      ' rotationCompDeg=${rotationCompensation ?? 'n/a'}'
      ' inputImageRotation=${inputImageRotation ?? 'n/a'}'
      ' adjustedSize=${adjustedSize.width.toStringAsFixed(0)}x${adjustedSize.height.toStringAsFixed(0)}',
    );
    debugPrint(
      '[MLKIT_BBOX_PX]'
      ' l=${bbox.left.toStringAsFixed(1)}'
      ' t=${bbox.top.toStringAsFixed(1)}'
      ' r=${bbox.right.toStringAsFixed(1)}'
      ' b=${bbox.bottom.toStringAsFixed(1)}'
      ' w=${bbox.width.toStringAsFixed(1)}'
      ' h=${bbox.height.toStringAsFixed(1)}'
      ' inAdjusted=${bbox.left >= 0 && bbox.top >= 0 && bbox.right <= adjustedSize.width && bbox.bottom <= adjustedSize.height}',
    );
    debugPrint(
      '[MESH_ROI_NORM]'
      ' xC=${roi.xCenter.toStringAsFixed(4)}'
      ' yC=${roi.yCenter.toStringAsFixed(4)}'
      ' w=${roi.width.toStringAsFixed(4)}'
      ' h=${roi.height.toStringAsFixed(4)}'
      ' rot=${roi.rotation.toStringAsFixed(4)}',
    );
    debugPrint(
      '[MESH_RESULT]'
      ' landmarks=${lms.length}'
      ' score=${result.score.toStringAsFixed(4)}'
      ' imgW=${result.imageWidth}'
      ' imgH=${result.imageHeight}'
      ' lmRangeX=[${minX.toStringAsFixed(4)}, ${maxX.toStringAsFixed(4)}]'
      ' lmRangeY=[${minY.toStringAsFixed(4)}, ${maxY.toStringAsFixed(4)}]'
      ' lmRangeZ=[${minZ.toStringAsFixed(4)}, ${maxZ.toStringAsFixed(4)}]',
    );
    if (lms.isNotEmpty) {
      final sample = lms.take(5).map((lm) {
        return '(${lm.x.toStringAsFixed(3)}, ${lm.y.toStringAsFixed(3)}, ${lm.z.toStringAsFixed(3)})';
      }).join(', ');
      debugPrint('[MESH_FIRST5] $sample');
    }
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
          _isMeshActive = false;
          _clearMesh();
          _clearDetections();
        });
      } else {
        _isDetectionActive = false;
        _isMeshActive = false;
        _clearMesh();
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

  Future<void> _toggleMesh() async {
    if (_isCameraBusy) {
      return;
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (!_isDetectionActive) {
      if (mounted) {
        setState(() {
          _errorMessage ??= 'Start Detect first to get a face ROI.';
        });
      } else {
        _errorMessage ??= 'Start Detect first to get a face ROI.';
      }
      return;
    }
    if (_faceMesh == null) {
      return;
    }

    if (_isMeshActive) {
      if (mounted) {
        setState(() {
          _isMeshActive = false;
          _clearMesh();
        });
      } else {
        _isMeshActive = false;
        _clearMesh();
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isMeshActive = true;
        _clearMesh();
      });
    } else {
      _isMeshActive = true;
      _clearMesh();
    }
  }
}
