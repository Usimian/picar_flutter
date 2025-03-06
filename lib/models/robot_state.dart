import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../utils/app_colors.dart';

class RobotState extends ChangeNotifier {
  // Create a logger instance for this class
  static final Logger _logger = Logger('RobotState');

  // Cache for battery color to avoid recreating it on every call
  Color? _batteryColorCache;
  double _lastVbForColorCache = -1;

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

  // Add video resolution properties
  static int _videoWidth = 320; // Default width
  static int _videoHeight = 240; // Default height
  static bool _hasDetectedResolution = false;

  // Getters and setters for video resolution
  static int get videoWidth => _videoWidth;
  static int get videoHeight => _videoHeight;
  static bool get hasDetectedResolution => _hasDetectedResolution;

  // Method to update video resolution
  static void updateVideoResolution(int width, int height) {
    if (width > 0 &&
        height > 0 &&
        (_videoWidth != width || _videoHeight != height)) {
      _logger.info(
          'Updating video resolution from ${_videoWidth}x$_videoHeight to ${width}x$height');
      _videoWidth = width;
      _videoHeight = height;
      _hasDetectedResolution = true;
    }
  }

  // Add a method to update the video URL
  static void updateVideoUrl(String newUrl) {
    if (videoUrl != newUrl && newUrl.isNotEmpty) {
      _logger.info('Updating video URL from $videoUrl to $newUrl');
      videoUrl = newUrl;
    }
  }

  // Use a more efficient approach for video frame time tracking
  static DateTime? lastVideoFrameTime;
  static bool isVideoStalled = false;
  static int _lastFrameCheckMs = 0;

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

  // Track if state has actually changed to avoid unnecessary notifications
  bool _hasStateChanged = false;

  void updateFromJson(Map<String, dynamic> json) {
    _hasStateChanged = false;

    // Update battery voltage if changed
    if (json.containsKey('Vb')) {
      final newVb = json['Vb']?.toDouble() ?? 0.0;
      if (vb != newVb) {
        vb = newVb;
        _hasStateChanged = true;
        // Invalidate battery color cache when voltage changes
        _batteryColorCache = null;
      }
    }

    // Update distance if changed
    if (json.containsKey('distance')) {
      final newDistance = json['distance']?.toDouble() ?? 0.0;
      if (distance != newDistance) {
        distance = newDistance;
        _hasStateChanged = true;
      }
    }

    // Update position if present
    if (json.containsKey('pos')) {
      final newPos = json['pos']?.toDouble() ?? 0.0;
      if (pos != newPos) {
        pos = newPos;
        _hasStateChanged = true;
      }
    }

    // Update isRunning based on battery voltage
    final bool wasRunning = isRunning;
    final bool newRunningState = vb > 0.0;
    if (isRunning != newRunningState) {
      isRunning = newRunningState;
      _hasStateChanged = true;
    }

    // Batch update status flags
    if (json.containsKey('mock_status')) {
      final mockStatus = json['mock_status'] as Map<String, dynamic>;

      // Update GPIO status if changed
      if (mockStatus.containsKey('gpio')) {
        final newGpioStatus = mockStatus['gpio'] ?? false;
        if (gpioStatus != newGpioStatus) {
          gpioStatus = newGpioStatus;
          _hasStateChanged = true;
        }
      }

      // Update I2C status if changed
      if (mockStatus.containsKey('i2c')) {
        final newI2cStatus = mockStatus['i2c'] ?? false;
        if (i2cStatus != newI2cStatus) {
          i2cStatus = newI2cStatus;
          _hasStateChanged = true;
        }
      }

      // Update ADC status if changed
      if (mockStatus.containsKey('adc')) {
        final newAdcStatus = mockStatus['adc'] ?? false;
        if (adcStatus != newAdcStatus) {
          adcStatus = newAdcStatus;
          _hasStateChanged = true;
        }
      }

      // Update camera status if changed
      if (mockStatus.containsKey('camera')) {
        final newCameraStatus = mockStatus['camera'] ?? false;
        if (cameraStatus != newCameraStatus) {
          cameraStatus = newCameraStatus;
          _hasStateChanged = true;
        }
      }
    }

    // Only log if running state changed
    if (wasRunning != isRunning) {
      _logger.info('Robot running state changed: $wasRunning -> $isRunning');
      _logger.info(
          'RobotState.updateFromJson: isRunning=$isRunning, cameraStatus=$cameraStatus, isVideoAvailable=$isVideoAvailable, videoUrl=$videoUrl');
    }

    // Only notify listeners if something actually changed
    if (_hasStateChanged) {
      notifyListeners();
    }
  }

  // Optimized method to update video frame timestamp
  static void updateVideoFrameTime() {
    final now = DateTime.now();
    final currentTimeMs = now.millisecondsSinceEpoch;

    // Only update if at least 100ms have passed since last update
    // This reduces the number of DateTime objects created
    if (lastVideoFrameTime == null || currentTimeMs - _lastFrameCheckMs > 100) {
      lastVideoFrameTime = now;
      isVideoStalled = false;
      _lastFrameCheckMs = currentTimeMs;
    }
  }

  // Optimized method to check if video feed is stalled
  static bool checkVideoStalled(
      {Duration stallThreshold = const Duration(seconds: 5)}) {
    if (lastVideoFrameTime == null) {
      return true; // No frames received yet
    }

    final currentTimeMs = DateTime.now().millisecondsSinceEpoch;
    final lastFrameMs = lastVideoFrameTime!.millisecondsSinceEpoch;
    final stallThresholdMs = stallThreshold.inMilliseconds;

    if (currentTimeMs - lastFrameMs > stallThresholdMs) {
      isVideoStalled = true;
      return true;
    }

    return false;
  }

  void setTargetPosition(double newPosition) {
    if (targetPosition != newPosition) {
      targetPosition = newPosition;
      notifyListeners();
    }
  }

  Color getBatteryColor() {
    // Return cached color if voltage hasn't changed
    if (_batteryColorCache != null && _lastVbForColorCache == vb) {
      return _batteryColorCache!;
    }

    // Calculate new color
    Color color;
    if (vb <= 7.5) {
      color = AppColors.batteryLow;
    } else if (vb <= 7.4) {
      color = AppColors.batteryMedium;
    } else {
      color = AppColors.batteryGood;
    }

    // Cache the result
    _batteryColorCache = color;
    _lastVbForColorCache = vb;

    return color;
  }
}
