import 'package:flutter/material.dart';

class RobotState extends ChangeNotifier {
  static const String videoUrl = "http://192.168.1.167:9000/mjpg";
  double pos = 0.0;
  double vb = 0.0;
  double targetPosition = 0.0;
  double distance = 0.0; // Distance from ultrasonic sensor

  // Status flags
  bool gpioStatus = false;
  bool i2cStatus = false;
  bool adcStatus = false;
  bool cameraStatus = true; // true means test pattern, false means real camera

  void updateFromJson(Map<String, dynamic> json) {
    if (json.containsKey('Pos')) pos = json['Pos']?.toDouble() ?? 0.0;
    if (json.containsKey('Vb')) vb = json['Vb']?.toDouble() ?? 0.0;
    if (json.containsKey('distance')) distance = json['distance']?.toDouble() ?? 0.0;
    if (json.containsKey('camera')) cameraStatus = !(json['camera'] ?? true);

    if (json.containsKey('mock_status')) {
      final mockStatus = json['mock_status'] as Map<String, dynamic>;
      if (mockStatus.containsKey('gpio')) gpioStatus = mockStatus['gpio'] ?? false;
      if (mockStatus.containsKey('i2c')) i2cStatus = mockStatus['i2c'] ?? false;
      if (mockStatus.containsKey('adc')) adcStatus = mockStatus['adc'] ?? false;
      if (mockStatus.containsKey('camera')) cameraStatus = mockStatus['camera'] ?? false;
    }

    notifyListeners();
  }

  void setTargetPosition(double newPosition) {
    targetPosition = newPosition;
    notifyListeners();
  }

  Color getBatteryColor() {
    if (vb <= 7.15) {
      return const Color.fromARGB(255, 255, 0, 0);
    } else if (vb <= 7.6) {
      return const Color.fromARGB(255, 255, 255, 0);
    } else {
      return const Color.fromARGB(255, 0, 255, 8);
    }
  }
}
