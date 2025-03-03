import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:logging/logging.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'widgets/video_player_widget.dart';
import 'dart:async';
import 'dart:convert'; // Import the dart:convert library
import 'models/robot_state.dart';
import 'widgets/position_control.dart';

// MQTT Topics
const String kMqttTopicControlRequest = 'picar/control_request';
const String kMqttTopicStatusRequest =
    'picar/status_request'; // Used with 'status' or 'info' parameter
const String kMqttTopicStatusResponse =
    'picar/status_response'; // Responses to status requests

void main() {
  // Set up logging
  hierarchicalLoggingEnabled = true; // Enable per-logger levels
  Logger.root.level = Level.WARNING;

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

  mainLogger.info('Starting TwoBot Flutter application');

  runApp(
    ChangeNotifierProvider(
      create: (context) => RobotState(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TwoBot Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const String _mqttServerIp =
      '192.168.1.167'; // Update this to your robot's IP address
  late RobotState _robotState;
  late MqttServerClient _mqttClient;
  final _logger = Logger('DashboardScreen');
  bool _isMqttConnected = false;
  Timer? _statusCheckTimer;
  Timer? _statusTimeoutTimer;
  double _currentSpeed = 0.0; // Add speed tracking
  double _currentTurn = 0.0; // Add turn tracking
  double _currentPan = 0.0; // Add pan tracking
  double _currentTilt = 0.0; // Add tilt tracking

  @override
  void initState() {
    super.initState();

    // Set logger level but don't add another listener
    Logger.root.level = Level.ALL;

    _logger.info('Dashboard initializing...');

    // Set initial video availability to false until we confirm connection
    RobotState.isVideoAvailable = false;

    // Initialize robot state
    _robotState = Provider.of<RobotState>(context, listen: false);

    // Setup MQTT client
    _setupMqttClient();

    // Start periodic status check which will also handle connection checks
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted) {
        if (_isMqttConnected) {
          // Request status regardless of whether robot is running or not
          // The response will determine if the robot is running
          _logger.info('Requesting robot status...');
          _requestRobotStatus();
        } else {
          // If not connected, check connection
          final connectionState = _mqttClient.connectionStatus?.state;
          if (connectionState != MqttConnectionState.connecting) {
            _logger.info('Not connected to MQTT, attempting to connect...');
            _connectClient();
          }
        }
      }
    });
  }

  void _requestRobotStatus() {
    // Create a single message with all required status information
    final statusBuilder = MqttClientPayloadBuilder();
    final statusMessage = jsonEncode({
      'command': 'status',
    });
    statusBuilder.addString(statusMessage);
    // Publish the message to the status request topic
    _mqttClient.publishMessage(
      kMqttTopicStatusRequest,
      MqttQos.exactlyOnce, // Using exactlyOnce to prevent duplicates
      statusBuilder.payload!,
    );

    // Cancel any existing timeout timer
    _statusTimeoutTimer?.cancel();

    // Start a new timeout timer
    _statusTimeoutTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        // Set battery voltage to 0 when no response, which will set isRunning to false
        _robotState.updateFromJson({'Vb': 0.0});

        // Connection check is now handled by the status check timer
        // which will attempt to reconnect on the next cycle
        _logger.warning('No status response received, connection may be lost');
      }
    });
  }

  Future<void> _setupMqttClient() async {
    _mqttClient = MqttServerClient(
        _mqttServerIp, 'picar_client_${DateTime.now().millisecondsSinceEpoch}');
    _mqttClient.port = 1883;
    _mqttClient.keepAlivePeriod = 20;
    _mqttClient.logging(on: false);

    // Disable auto-reconnect initially - we'll handle reconnection manually
    _mqttClient.autoReconnect = false;
    _mqttClient.resubscribeOnAutoReconnect = true;
    _mqttClient.secure = false;

    // Set up callbacks
    _mqttClient.onDisconnected = _onDisconnected;
    _mqttClient.onConnected = _onConnected;

    _mqttClient.pongCallback = () {
      _logger.fine('Ping response received');
      setState(() {
        _isMqttConnected = true;
      });
    };

    // Set connection message with more detailed options
    final connMessage = MqttConnectMessage()
        .withClientIdentifier(
            'picar_client_${DateTime.now().millisecondsSinceEpoch}')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .withWillTopic(kMqttTopicStatusRequest)
        .withWillMessage('offline');
    _mqttClient.connectionMessage = connMessage;

    try {
      _logger.info(
          'Attempting to connect to MQTT broker at $_mqttServerIp:${_mqttClient.port}');
      _logger.info(
          'Connection settings: keepAlive=${_mqttClient.keepAlivePeriod}, autoReconnect=${_mqttClient.autoReconnect}');

      // Set a connection timeout
      final connectionStatus = await _mqttClient.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.warning('MQTT connection attempt timed out');
          return null;
        },
      );

      if (connectionStatus == null) {
        _logger.severe('Connection timed out');
        setState(() {
          _isMqttConnected = false;
        });
        return;
      }

      if (_mqttClient.connectionStatus?.state ==
          MqttConnectionState.connected) {
        _logger.info('Successfully connected to MQTT broker');
        _logger.info('Client state: ${_mqttClient.connectionStatus}');
        setState(() {
          _isMqttConnected = true;
        });
      } else {
        _logger.severe(
            'Failed to connect. Status: ${_mqttClient.connectionStatus?.state}');
        setState(() {
          _isMqttConnected = false;
        });
      }
    } catch (e) {
      _logger.severe('Failed to connect to MQTT broker: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect to robot: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        _isMqttConnected = false;
      });
    }
  }

  Future<void> _connectClient() async {
    try {
      _logger.info('MQTT Connecting...');

      // Add a delay before connection attempt to avoid rapid reconnection
      await Future.delayed(const Duration(milliseconds: 500));

      // Set a connection timeout
      final connectionStatus = await _mqttClient.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.warning('MQTT connection attempt timed out');
          return null;
        },
      );

      if (connectionStatus == null) {
        _logger.severe('Connection timed out');
        setState(() {
          _isMqttConnected = false;
        });
        return;
      }

      if (_mqttClient.connectionStatus?.state ==
          MqttConnectionState.connected) {
        _logger.info('MQTT client connected successfully');
        setState(() {
          _isMqttConnected = true;
        });
      } else {
        _logger.warning(
            'MQTT connection failed: ${_mqttClient.connectionStatus?.state}');
        setState(() {
          _isMqttConnected = false;
        });
      }
    } catch (e) {
      _logger.severe('Error connecting to MQTT broker: $e');
      setState(() {
        _isMqttConnected = false;
      });
    }
  }

  void _onDisconnected() {
    _logger.info('MQTT client disconnected');
    setState(() {
      _isMqttConnected = false;
    });

    // Try to reconnect after a longer delay to avoid rapid reconnection attempts
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) {
        _logger.info('Attempting to reconnect to MQTT broker...');
        _connectClient();
      }
    });
  }

  void _onConnected() {
    _logger.info('MQTT client connected callback');
    setState(() {
      _isMqttConnected = true;
    });

    // Subscribe only to status response topic
    _mqttClient.subscribe(kMqttTopicStatusResponse, MqttQos.atMostOnce);
    _logger
        .info('Subscribed to status response topic: $kMqttTopicStatusResponse');

    // Set up message handler for status updates
    _mqttClient.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
      final payload =
          MqttPublishPayload.bytesToStringAsString(message.payload.message);

      if (c[0].topic == kMqttTopicStatusResponse) {
        // Cancel the timeout timer since we received a response
        _statusTimeoutTimer?.cancel();

        try {
          _logger.info('Received status response: $payload');
          final jsonResponse = jsonDecode(payload) as Map<String, dynamic>;

          // Update the robot state which will set isRunning based on battery voltage
          _robotState.updateFromJson(jsonResponse);

          // The camera is available when:
          // 1. The robot is running (isRunning is true)
          // 2. mock_status exists in the response
          // 3. camera key exists in mock_status (regardless of its value)
          final bool cameraAvailable = _robotState.isRunning &&
              jsonResponse.containsKey('mock_status') &&
              jsonResponse['mock_status'].containsKey('camera');

          // Check if the camera status is actually changing before updating
          final bool currentVideoAvailable = RobotState.isVideoAvailable;

          _logger.info('Camera status check: '
              'cameraAvailable=$cameraAvailable, '
              'currentVideoAvailable=$currentVideoAvailable, '
              'isRunning=${_robotState.isRunning}, '
              'hasCamera=${jsonResponse.containsKey('mock_status') && jsonResponse['mock_status'].containsKey('camera')}');

          // Only update isVideoAvailable if there's an actual change
          if (cameraAvailable != currentVideoAvailable) {
            _logger.info(
                'Updating video availability: $currentVideoAvailable -> $cameraAvailable');
            RobotState.isVideoAvailable = cameraAvailable;
          }
        } catch (e) {
          _logger.warning('Failed to parse status response: $e');
        }
      }
    });
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _statusTimeoutTimer?.cancel();
    _mqttClient.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PiCar Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                // Battery Status
                Icon(
                  Icons.battery_full,
                  color: context.watch<RobotState>().getBatteryColor(),
                  size: 24,
                ),
                const SizedBox(width: 4),
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Text('${robotState.vb.toStringAsFixed(2)}V');
                  },
                ),
                const SizedBox(width: 16),

                // GPIO Status
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Icon(
                      Icons.car_repair,
                      color: !robotState.isRunning
                          ? const Color.fromARGB(
                              255, 255, 0, 0) // Red when not running
                          : robotState.gpioStatus
                              ? const Color.fromARGB(
                                  255, 0, 0, 255) // Blue when running and true
                              : const Color.fromARGB(255, 0, 255,
                                  8), // Green when running and false
                      size: 24,
                    );
                  },
                ),
                const SizedBox(width: 4),
                const Text('GPIO'),
                const SizedBox(width: 8),

                // I2C Status
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Icon(
                      Icons.cable,
                      color: !robotState.isRunning
                          ? const Color.fromARGB(255, 255, 0, 0)
                          : robotState.i2cStatus
                              ? const Color.fromARGB(255, 0, 0, 255)
                              : const Color.fromARGB(255, 0, 255, 8),
                      size: 24,
                    );
                  },
                ),
                const SizedBox(width: 4),
                const Text('I2C'),
                const SizedBox(width: 8),

                // ADC Status
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Icon(
                      Icons.memory,
                      color: !robotState.isRunning
                          ? const Color.fromARGB(255, 255, 0, 0)
                          : robotState.adcStatus
                              ? const Color.fromARGB(255, 0, 0, 255)
                              : const Color.fromARGB(255, 0, 255, 8),
                      size: 24,
                    );
                  },
                ),
                const SizedBox(width: 4),
                const Text('ADC'),
                const SizedBox(width: 8),

                // Camera Status
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Icon(
                      Icons.camera_alt,
                      color: !robotState.isRunning
                          ? const Color.fromARGB(255, 255, 0, 0)
                          : robotState.cameraStatus
                              ? const Color.fromARGB(255, 0, 0,
                                  255) // Blue when using test pattern
                              : const Color.fromARGB(255, 0, 255,
                                  8), // Green when using real camera
                      size: 24,
                    );
                  },
                ),
                const SizedBox(width: 4),
                const Text('Camera'),
                const SizedBox(width: 8),

                // Connection Status
                Icon(
                  Icons.connect_without_contact,
                  color: _isMqttConnected
                      ? const Color.fromARGB(255, 0, 255, 8)
                      : const Color.fromARGB(255, 255, 17, 0),
                  size: 24,
                ),
                const SizedBox(width: 4),
                Text(_isMqttConnected ? 'Connected' : 'Disconnected'),
                const SizedBox(width: 16),

                // Robot Running Status
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Icon(
                      Icons.run_circle,
                      color: robotState.isRunning
                          ? const Color.fromARGB(255, 0, 255, 8)
                          : const Color.fromARGB(255, 255, 0, 0),
                      size: 24,
                    );
                  },
                ),
                const SizedBox(width: 4),
                Consumer<RobotState>(
                  builder: (context, robotState, child) {
                    return Text(robotState.isRunning ? 'Running' : 'Stopped');
                  },
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Consumer<RobotState>(
              builder: (context, robotState, child) {
                return Text(
                  'Video URL: ${RobotState.videoUrl}',
                  style: const TextStyle(fontSize: 14),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: PositionControl(mqttClient: _mqttClient),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Speed: ${_currentSpeed.toStringAsFixed(2)}\nTurn: ${_currentTurn.toStringAsFixed(2)}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: 200,
                          height: 200,
                          child: Consumer<RobotState>(
                            builder: (context, robotState, child) {
                              return Joystick(
                                mode: JoystickMode.all,
                                listener: (details) {
                                  // Calculate desired speed (negative Y for forward)
                                  double desiredSpeed = -details.y;

                                  setState(() {
                                    _currentSpeed = desiredSpeed;
                                    _currentTurn = details.x;
                                  });

                                  if (_mqttClient.connectionStatus?.state ==
                                      MqttConnectionState.connected) {
                                    final builder = MqttClientPayloadBuilder();
                                    builder.addString(
                                        '{"turn": ${details.x.toStringAsFixed(2)}, "speed": ${desiredSpeed.toStringAsFixed(2)}}');
                                    _mqttClient.publishMessage(
                                      'picar/control_request',
                                      MqttQos
                                          .exactlyOnce, // Changed from atLeastOnce to ensure exactly one delivery
                                      builder.payload!,
                                    );
                                  }
                                },
                                base: Container(
                                  width: 150,
                                  height: 150,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: robotState.distance < 10
                                        ? Colors.red[
                                            100] // Light red background when too close
                                        : Colors.grey[300],
                                  ),
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'DRIVE',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (robotState.distance < 10)
                                          const Text(
                                            'TOO CLOSE!',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.red,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                stick: Container(
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Consumer<RobotState>(
                      builder: (context, robotState, child) {
                        return Container(
                          width: 320,
                          height: 240,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: robotState.isRunning
                                ? const VideoFeedContainer()
                                : Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: const [
                                        Icon(Icons.power_off,
                                            size: 48, color: Colors.grey),
                                        SizedBox(height: 8),
                                        Text(
                                          'Robot is not running',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Video feed disabled',
                                          style: TextStyle(
                                              color: Colors.grey, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Pan: ${(_currentPan * 90).toStringAsFixed(2)}°\nTilt: ${(_currentTilt * 90).toStringAsFixed(2)}°',
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
                                _currentPan = details.x;
                                _currentTilt = details.y;
                              });
                              if (_mqttClient.connectionStatus?.state ==
                                  MqttConnectionState.connected) {
                                // details.x and details.y are already normalized to -1.0 to 1.0
                                final controlMessage = {
                                  'tilt': details.y *
                                      90, // Invert Y axis so up is positive
                                  'pan': details.x * 90
                                };

                                // Publish control message
                                final builder = MqttClientPayloadBuilder();
                                builder.addString(json.encode(controlMessage));
                                _mqttClient.publishMessage(
                                    kMqttTopicControlRequest,
                                    MqttQos
                                        .exactlyOnce, // Changed from atLeastOnce to ensure exactly one delivery
                                    builder.payload!);
                              }
                            },
                            base: Container(
                              width: 150,
                              height: 150,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.grey[300],
                              ),
                            ),
                            stick: Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
