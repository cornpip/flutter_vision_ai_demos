import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class CameraControlButtons extends StatelessWidget {
  const CameraControlButtons({
    super.key,
    required this.isCameraActive,
    required this.isDetectionActive,
    required this.isControllerReady,
    required this.isCameraBusy,
    required this.isChangingCamera,
    required this.camerasLength,
    required this.onToggleCamera,
    required this.onToggleDetection,
    required this.onSwitchCamera,
  });

  final bool isCameraActive;
  final bool isDetectionActive;
  final bool isControllerReady;
  final bool isCameraBusy;
  final bool isChangingCamera;
  final int camerasLength;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleDetection;
  final VoidCallback onSwitchCamera;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isCameraBusy ? null : onToggleCamera,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isCameraActive
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    foregroundColor: Colors.black,
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: Icon(
                    isCameraActive ? Icons.stop : Icons.videocam,
                    color: Colors.black,
                  ),
                  label: Text(isCameraActive ? 'Stop Cam' : 'Start Cam'),
                ),
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!isCameraActive ||
                          !isControllerReady ||
                          isCameraBusy)
                      ? null
                      : onToggleDetection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDetectionActive
                        ? Colors.orangeAccent
                        : Colors.blueAccent,
                    foregroundColor: Colors.black,
                    padding: EdgeInsets.symmetric(
                        horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: Icon(
                    isDetectionActive
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: Colors.black,
                  ),
                  label: Text(
                      isDetectionActive ? 'Stop YOLO' : 'Start YOLO'),
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (camerasLength < 2 ||
                          isChangingCamera ||
                          isCameraBusy ||
                          !isCameraActive ||
                          !isControllerReady)
                      ? null
                      : onSwitchCamera,
                  style: ElevatedButton.styleFrom(
                    padding:
                        EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  ),
                  icon: const Icon(Icons.cameraswitch),
                  label: const Text('Switch'),
                ),
              ),
              SizedBox(width: 8.w),
              const Expanded(
                child: SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
