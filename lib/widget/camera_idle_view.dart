import 'package:flutter/material.dart';

class CameraIdleView extends StatelessWidget {
  const CameraIdleView({super.key, required this.controls});

  final Widget controls;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Expanded(
          child: Center(
            child: Text(
              '촬영 버튼을 눌러 카메라를 시작하세요.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
        controls,
      ],
    );
  }
}
