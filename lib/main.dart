import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import 'models/robot_state.dart';
import 'services/mqtt_service.dart';
import 'screens/dashboard_screen.dart';

void main() {
  // Set up logging
  hierarchicalLoggingEnabled = true; // Enable per-logger levels
  Logger.root.level = Level.WARNING; // Logging level for application

  // Set MQTT logging level
  Logger('mqtt_client').level = Level.SEVERE;

  final mainLogger = Logger('Main');

  Logger.root.onRecord.listen((record) {
    final message = StringBuffer();
    message.write(
        '${record.time}: ${record.level.name}: ${record.loggerName}: ${record.message}');

    if (record.error != null) {
      message.write('\nError: ${record.error}');
    }
    if (record.stackTrace != null) {
      message.write('\nStack trace:\n${record.stackTrace}');
    }

    debugPrint(message.toString());
  });

  mainLogger.info('Starting PiCar Flutter application');

  // Create a RobotState instance first
  final robotState = RobotState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RobotState>.value(value: robotState),
        ChangeNotifierProvider<MqttService>(
          create: (context) => MqttService(robotState: robotState),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PiCar Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}
