import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../common/colors.dart';
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
  bool _isProcessingFrame = false;
  static const Duration _cameraFpsUpdateInterval =
      Duration(milliseconds: 200);
  double _cameraFps = 0;
  DateTime? _lastCameraFrameTime;
  DateTime? _lastCameraFpsUpdateTime;

  @override
  void initState() {
    super.initState();
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
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _cameraController = controller;

    try {
      await controller.initialize();
      _clearCameraFps();
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

  void _processCameraImage(CameraImage cameraImage) {
    if (_isProcessingFrame) {
      return;
    }
    _updateCameraFps(DateTime.now());
    _isProcessingFrame = true;
    // MediaPipe 처리 로직을 여기에 추가할 수 있습니다.
    _isProcessingFrame = false;
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

  Future<void> _reinitializeCurrentCamera() async {
    final initialized = await _initializeCamera(_currentCamera);
    if (!initialized) {
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _clearCameraFps();
        });
      } else {
        _isCameraActive = false;
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
          _clearCameraFps();
        });
      } else {
        _cameraController = null;
        _isCameraActive = false;
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
            'Preview: $previewSizeText • $cameraLabel',
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
      });
    } else {
      _isCameraBusy = true;
      _errorMessage = null;
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
          _clearCameraFps();
        });
      } else {
        _isCameraActive = false;
        _clearCameraFps();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isCameraBusy = true;
        _isCameraActive = false;
        _clearCameraFps();
      });
    } else {
      _isCameraBusy = true;
      _isCameraActive = false;
      _clearCameraFps();
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
}
