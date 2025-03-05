import 'package:flutter/material.dart';

/// A centralized class for all colors used in the application.
/// This makes it easier to maintain consistent colors and update them in one place.
class AppColors {
  // Status colors
  static const Color statusRed = Color.fromARGB(255, 255, 0, 0);
  static const Color statusYellow = Color.fromARGB(255, 255, 255, 0);
  static const Color statusGreen = Color.fromARGB(255, 0, 255, 0);
  static const Color statusBlue = Color.fromARGB(255, 0, 0, 255);

  // Battery status colors
  static const Color batteryLow = statusRed;
  static const Color batteryMedium = statusYellow;
  static const Color batteryGood = statusGreen;

  // Connection status colors
  static const Color connected = statusGreen;
  static const Color disconnected = statusRed;

  // Distance warning colors
  static const Color distanceWarning = statusRed;
  static const Color distanceNormal = Colors.black;
  static const Color distanceBackground =
      Color.fromARGB(255, 255, 200, 200); // Light red

  // UI element colors
  static const Color joystickBase =
      Color.fromARGB(255, 224, 224, 224); // Grey[300] equivalent
  static const Color joystickStick =
      Color.fromARGB(255, 117, 117, 117); // Grey[600] equivalent

  // Text colors
  static const Color disabledText = Colors.grey;

  // Border colors
  static const Color borderColor = Colors.grey;
}
