import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:yolo/models/detection.dart';
import 'package:yolo/paint/detection_painter.dart';

class CameraPreviewView extends StatelessWidget {
  const CameraPreviewView({
    super.key,
    required this.controller,
    required this.detections,
    required this.statusChip,
    required this.controls,
  });

  final CameraController controller;
  final List<Detection> detections;
  final Widget statusChip;
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;
    final previewSizeText = previewSize != null
        ? '${previewSize.width.toStringAsFixed(0)} x ${previewSize.height.toStringAsFixed(0)}'
        : '알 수 없음';
    final preview = AspectRatio(
      aspectRatio: 1 / controller.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller),
          Positioned.fill(
            child: CustomPaint(
              painter: DetectionPainter(detections: detections),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 16,
            child: statusChip,
          ),
        ],
      ),
    );

    return Column(
      children: [
        Expanded(child: Center(child: preview)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Model: YOLOv11-nano • Detections: ${detections.length}\n이미지 크기: $previewSizeText',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
        controls,
      ],
    );
  }
}
