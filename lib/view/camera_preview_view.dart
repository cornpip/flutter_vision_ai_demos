import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:yolo/models/detection.dart';
import 'package:yolo/paint/detection_painter.dart';

class CameraPreviewView extends StatelessWidget {
  const CameraPreviewView({
    super.key,
    required this.controller,
    required this.detections,
    required this.cameraFps,
    required this.detectionFps,
    required this.statusChip,
    required this.controls,
    required this.isCameraAvailable,
  });

  final CameraController? controller;
  final List<Detection> detections;
  final double cameraFps;
  final double detectionFps;
  final Widget statusChip;
  final Widget controls;
  final bool isCameraAvailable;

  @override
  Widget build(BuildContext context) {
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
    final fpsText =
        'Cam: ${cameraFps > 0 ? cameraFps.toStringAsFixed(1) : '--'} fps\n'
        'YOLO: ${detectionFps > 0 ? detectionFps.toStringAsFixed(1) : '--'} fps';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: previewWidth * 1.1,
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
                                  child: CameraPreview(controller!),
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
                                child: CustomPaint(
                                  painter: DetectionPainter(
                                      detections: detections),
                                ),
                              ),
                            Positioned(
                              bottom: 12.h,
                              left: 12.w,
                              child: statusChip,
                            ),
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
          padding: EdgeInsets.symmetric(vertical: 0),
          child: Text(
            'Model: YOLOv11-nano • Detections: ${detections.length}\nImage size: $previewSizeText',
            style: const TextStyle(color: Colors.black),
            textAlign: TextAlign.center,
          ),
        ),
        controls,
      ],
    );
  }
}
