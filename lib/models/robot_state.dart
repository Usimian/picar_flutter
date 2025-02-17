import 'package:flutter/foundation.dart';

class RobotState extends ChangeNotifier {
  double pos = 0.0;
  double vb = 0.0;
  double targetPosition = 0.0;

  // Mock status flags
  bool gpioStatus = false;
  bool i2cStatus = false;
  bool adcStatus = false;

  void updateFromJson(Map<String, dynamic> json) {
    pos = json['Pos']?.toDouble() ?? 0.0;
    vb = json['Vb']?.toDouble() ?? 0.0;

    // Update mock status flags if present
    if (json['mock_status'] != null) {
      Map<String, dynamic> mockStatus = json['mock_status'];
      gpioStatus = mockStatus['gpio'] ?? false;
      i2cStatus = mockStatus['i2c'] ?? false;
      adcStatus = mockStatus['adc'] ?? false;
    }
    
    notifyListeners();
  }

  void setTargetPosition(double newPosition) {
    targetPosition = newPosition;
    notifyListeners();
  }
}
