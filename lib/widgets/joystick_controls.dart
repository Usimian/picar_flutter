import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import '../services/mqtt_service.dart';
import '../utils/app_colors.dart';

class JoystickControls extends StatefulWidget {
  final MqttService mqttService;
  final bool isDriveJoystick;

  const JoystickControls({
    super.key,
    required this.mqttService,
    required this.isDriveJoystick,
  });

  @override
  State<JoystickControls> createState() => _JoystickControlsState();
}

class _JoystickControlsState extends State<JoystickControls> {
  double _currentX = 0.0;
  double _currentY = 0.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.isDriveJoystick
              ? 'Speed: ${(-_currentY).toStringAsFixed(2)}\nTurn: ${_currentX.toStringAsFixed(2)}'
              : 'Pan: ${(_currentX * 90).toStringAsFixed(2)}°\nTilt: ${(_currentY * 90).toStringAsFixed(2)}°',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 200,
          height: 200,
          child: Joystick(
            mode: JoystickMode.all,
            listener: (details) {
              setState(() {
                _currentX = details.x;
                _currentY = details.y;
              });

              if (widget.isDriveJoystick) {
                widget.mqttService.publishDriveControl(-details.y, details.x);
              } else {
                widget.mqttService.publishCameraControl(details.x, details.y);
              }
            },
            base: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.joystickBase,
              ),
              child: widget.isDriveJoystick
                  ? const Center(
                      child: Text(
                        'DRIVE',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : null,
            ),
            stick: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.joystickStick,
              ),
            ),
          ),
        ),
      ],
    );
  }
} 