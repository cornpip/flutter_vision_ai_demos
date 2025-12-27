import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

class FaceMeshPainter extends CustomPainter {
  FaceMeshPainter({
    required this.result,
    required this.rotationCompensation,
    required this.lensDirection,
    this.pointRadius = 2.0,
    this.color = Colors.redAccent,
  });

  final FaceMeshResult result;
  final int rotationCompensation;
  final CameraLensDirection lensDirection;
  final double pointRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (final lm in result.landmarks) {
      final Offset p = _mapNormalizedPointToPreview(
        x: lm.x,
        y: lm.y,
        rotationCompensation: rotationCompensation,
        lensDirection: lensDirection,
      );
      final double xNorm = p.dx;
      final double yNorm = p.dy;
      canvas.drawCircle(
        Offset(xNorm * size.width, yNorm * size.height),
        pointRadius,
        paint,
      );
    }
  }

  Offset _mapNormalizedPointToPreview({
    required double x,
    required double y,
    required int rotationCompensation,
    required CameraLensDirection lensDirection,
  }) {
    double xOut = x;
    double yOut = y;

    // Landmarks are normalized to the input image coordinates used by the mesh
    // inference (raw NV21 frame). Map them into the preview coordinate system
    // by applying the same rotation compensation as ML Kit.
    switch (rotationCompensation) {
      case 90:
        // raw -> rotated CW90
        xOut = 1.0 - y;
        yOut = x;
        break;
      case 180:
        xOut = 1.0 - x;
        yOut = 1.0 - y;
        break;
      case 270:
        // raw -> rotated CCW90
        xOut = y;
        yOut = 1.0 - x;
        break;
      default:
        break;
    }

    if (!Platform.isIOS && lensDirectiosn == CameraLensDirection.front) {
      xOut = 1.0 - xOut;
    }

    return Offset(xOut.clamp(0.0, 1.0), yOut.clamp(0.0, 1.0));
  }

  @override
  bool shouldRepaint(covariant FaceMeshPainter oldDelegate) {
    return oldDelegate.result != result ||
        oldDelegate.rotationCompensation != rotationCompensation ||
        oldDelegate.lensDirection != lensDirection ||
        oldDelegate.pointRadius != pointRadius ||
        oldDelegate.color != color;
  }
}
