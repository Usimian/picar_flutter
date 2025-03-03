import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

class RobotState extends ChangeNotifier {
  // Create a logger instance for this class
  static final Logger _logger = Logger('RobotState');

  // Change from static const to static String to allow updates
  static String videoUrl = "http://192.168.1.167:9000/mjpg";

  // Use a private backing field with a getter/setter to control updates
  static bool _isVideoAvailable = false;
  static bool get isVideoAvailable => _isVideoAvailable;
  static set isVideoAvailable(bool value) {
    // Only update if the value is actually changing
    if (_isVideoAvailable != value) {
      _isVideoAvailable = value;
      // Log video availability changes for debugging
      _logger.info('Video availability changed to: $value');
    }
  }

  // Add a method to update the video URL
  static void updateVideoUrl(String newUrl) {
    if (videoUrl != newUrl && newUrl.isNotEmpty) {
      _logger.info('Updating video URL from $videoUrl to $newUrl');
      videoUrl = newUrl;
    }
  }

  static DateTime? lastVideoFrameTime;
  static bool isVideoStalled = false;

  double pos = 0.0;
  double vb = 0.0;
  double targetPosition = 0.0;
  double distance = 0.0; // Distance from ultrasonic sensor

  // Add a property to track if the robot is running
  bool isRunning = false;

  // Status flags
  bool gpioStatus = false;
  bool i2cStatus = false;
  bool adcStatus = false;
  bool cameraStatus = false; // true means test pattern, false means real camera

  void updateFromJson(Map<String, dynamic> json) {
    if (json.containsKey('Vb')) vb = json['Vb']?.toDouble() ?? 0.0;
    if (json.containsKey('distance')) {
      distance = json['distance']?.toDouble() ?? 0.0;
    }

    // Update isRunning based on battery voltage
    final bool wasRunning = isRunning;
    isRunning = vb > 0.0;

    if (json.containsKey('mock_status')) {
      final mockStatus = json['mock_status'] as Map<String, dynamic>;
      if (mockStatus.containsKey('gpio')) {
        gpioStatus = mockStatus['gpio'] ?? false;
      }
      if (mockStatus.containsKey('i2c')) i2cStatus = mockStatus['i2c'] ?? false;
      if (mockStatus.containsKey('adc')) adcStatus = mockStatus['adc'] ?? false;
      if (mockStatus.containsKey('camera')) {
        cameraStatus = mockStatus['camera'] ?? false;
      }
    }

    // Only update video availability if the robot running state has changed
    // or if this is the first time we're setting it
    if (wasRunning != isRunning) {
      _logger.info('Robot running state changed: $wasRunning -> $isRunning');

      // REMOVE automatic video availability updates based on running state
      // Let the main.dart status handler control this instead
      // This prevents unnecessary updates during status checks

      // Debug print to help troubleshoot
      _logger.info(
          'RobotState.updateFromJson: isRunning=$isRunning, cameraStatus=$cameraStatus, isVideoAvailable=$isVideoAvailable, videoUrl=$videoUrl');
    }

    notifyListeners();
  }

  // Method to update video frame timestamp
  static void updateVideoFrameTime() {
    // Only update if a significant amount of time has passed since the last update
    // or if this is the first update
    final now = DateTime.now();
    if (lastVideoFrameTime == null ||
        now.difference(lastVideoFrameTime!).inMilliseconds > 100) {
      lastVideoFrameTime = now;
      isVideoStalled = false;
    }
  }

  // Method to check if video feed is stalled
  static bool checkVideoStalled(
      {Duration stallThreshold = const Duration(seconds: 5)}) {
    if (lastVideoFrameTime == null) {
      return true; // No frames received yet
    }

    final timeSinceLastFrame = DateTime.now().difference(lastVideoFrameTime!);
    if (timeSinceLastFrame > stallThreshold) {
      isVideoStalled = true;
      return true;
    }

    return false;
  }

  void setTargetPosition(double newPosition) {
    targetPosition = newPosition;
    notifyListeners();
  }

  Color getBatteryColor() {
    if (vb <= 7.5) {
      return const Color.fromARGB(255, 255, 17, 0);
    } else if (vb <= 7.4) {
      return const Color.fromARGB(255, 255, 255, 0);
    } else {
      return const Color.fromARGB(255, 0, 255, 0);
    }
  }
}
