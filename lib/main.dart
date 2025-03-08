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
import 'utils/app_colors.dart';
import 'services/llava_service.dart'; // Import the LlavaService

// MQTT Topics
const String kMqttTopicControlRequest = 'picar/control_request';
const String kMqttTopicStatusRequest =
    'picar/status_request'; // Used with 'status' or 'info' parameter
const String kMqttTopicStatusResponse =
    'picar/status_response'; // Responses to status requests

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
  bool _videoEnabled = true; // Add state for video checkbox

  // LLaVA related variables
  late LlavaService _llavaService;
  final TextEditingController _promptController = TextEditingController();
  String _llavaResponse = 'Responses will appear here';
  bool _isProcessing = false;
  bool _llavaAvailable = false;

  // Cache payload builders to avoid recreating them
  final _statusPayloadBuilder = MqttClientPayloadBuilder();
  final _drivePayloadBuilder = MqttClientPayloadBuilder();
  final _cameraPayloadBuilder = MqttClientPayloadBuilder();

  // Debounce timers for joystick controls
  Timer? _driveDebounceTimer;
  Timer? _cameraDebounceTimer;

  // Last sent values to avoid duplicate messages
  double? _lastSentSpeed;
  double? _lastSentTurn;
  double? _lastSentPan;
  double? _lastSentTilt;

  @override
  void initState() {
    super.initState();

    // Set logger level but don't add another listener
    Logger.root.level = Level.INFO;

    _logger.info('Dashboard initializing...');

    // Set initial video availability to false until we confirm connection
    RobotState.isVideoAvailable = false;

    // Initialize robot state
    _robotState = Provider.of<RobotState>(context, listen: false);

    // Setup MQTT client
    _setupMqttClient();

    // Initialize LLaVA service
    _llavaService =
        LlavaService(baseUrl: 'http://localhost:11434'); // Ollama API endpoint
    _checkLlavaAvailability();

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
    // Reuse the payload builder instead of creating a new one each time
    _statusPayloadBuilder.clear();
    final statusMessage = jsonEncode({
      'command': 'status',
    });
    _statusPayloadBuilder.addString(statusMessage);

    // Publish the message to the status request topic
    _mqttClient.publishMessage(
      kMqttTopicStatusRequest,
      MqttQos.exactlyOnce, // Using exactlyOnce to prevent duplicates
      _statusPayloadBuilder.payload!,
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

          _logger.fine('Camera status check: '
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

  // Optimized method to publish drive control updates with debouncing
  void _publishDriveControl(double speed, double turn) {
    // Skip if values haven't changed significantly or MQTT is disconnected
    if ((_lastSentSpeed != null &&
            _lastSentTurn != null &&
            (speed - _lastSentSpeed!).abs() < 0.01 &&
            (turn - _lastSentTurn!).abs() < 0.01) ||
        _mqttClient.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }

    _driveDebounceTimer?.cancel();
    _driveDebounceTimer = Timer(const Duration(milliseconds: 50), () {
      _lastSentSpeed = speed;
      _lastSentTurn = turn;

      _drivePayloadBuilder.clear();
      _drivePayloadBuilder.addString(
          '{"turn": ${turn.toStringAsFixed(2)}, "speed": ${speed.toStringAsFixed(2)}}');

      _mqttClient.publishMessage(
        'picar/control_request',
        MqttQos.exactlyOnce,
        _drivePayloadBuilder.payload!,
      );
    });
  }

  // Optimized method to publish camera control updates with debouncing
  void _publishCameraControl(double pan, double tilt) {
    // Skip if values haven't changed significantly or MQTT is disconnected
    if ((_lastSentPan != null &&
            _lastSentTilt != null &&
            (pan - _lastSentPan!).abs() < 0.01 &&
            (tilt - _lastSentTilt!).abs() < 0.01) ||
        _mqttClient.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }

    _cameraDebounceTimer?.cancel();
    _cameraDebounceTimer = Timer(const Duration(milliseconds: 50), () {
      _lastSentPan = pan;
      _lastSentTilt = tilt;

      _cameraPayloadBuilder.clear();
      final controlMessage = {'tilt': tilt * 90, 'pan': pan * 90};

      _cameraPayloadBuilder.addString(json.encode(controlMessage));
      _mqttClient.publishMessage(
        kMqttTopicControlRequest,
        MqttQos.exactlyOnce,
        _cameraPayloadBuilder.payload!,
      );
    });
  }

  void _getImage() {
    _logger.info('Capturing current image from video feed');

    // If video streaming is disabled in the UI, we need to capture a frame
    // The video feed is always on from the web server
    if (!_videoEnabled) {
      _logger.info('Video streaming disabled in UI, capturing current frame');
      VideoFeedContainer.captureCurrentFrame();
    }
  }

  void _toggleVideo(bool value) {
    _logger.info('Toggling video display in UI: $value');
    setState(() {
      _videoEnabled = value;
    });
  }

  // Process the user's prompt with the current image
  Future<void> _processPromptWithImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      _logger.warning('Prompt is empty');
      setState(() {
        _llavaResponse = 'Please enter a prompt first';
      });
      return;
    }

    // Check if we have an image
    if (RobotState.lastReceivedImage == null) {
      _logger.warning('No image available');
      setState(() {
        _llavaResponse =
            'No image available. Make sure the video feed is working.';
      });
      return;
    }

    // Check if LLaVA service is available
    if (!_llavaAvailable) {
      _logger.warning('LLaVA service is not available');
      setState(() {
        _llavaResponse = 'LLaVA service is not available. Check your server.';
      });
      await _checkLlavaAvailability();
      return;
    }

    // Process the prompt with the image
    setState(() {
      _isProcessing = true;
      _llavaResponse = 'Processing...';
    });

    try {
      final response = await _llavaService.processImageAndText(
        RobotState.lastReceivedImage!,
        prompt,
      );

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _llavaResponse = response;
        });
      }
    } catch (e) {
      _logger.severe('Error processing prompt with image: $e');
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _llavaResponse = 'Error: $e';
        });
      }
    }
  }

  // Check if LLaVA service is available
  Future<void> _checkLlavaAvailability() async {
    try {
      final available = await _llavaService.isAvailable();
      if (mounted) {
        setState(() {
          _llavaAvailable = available;
          if (available) {
            _logger.info('LLaVA service is available');
          } else {
            _logger.warning('LLaVA service is not available');
            _llavaResponse =
                'LLaVA service is not available. Check your server.';
          }
        });
      }
    } catch (e) {
      _logger.severe('Error checking LLaVA availability: $e');
      if (mounted) {
        setState(() {
          _llavaAvailable = false;
          _llavaResponse = 'Error connecting to LLaVA: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _statusTimeoutTimer?.cancel();
    _driveDebounceTimer?.cancel();
    _cameraDebounceTimer?.cancel();
    _mqttClient.disconnect();
    _promptController.dispose();
    _llavaService.dispose();
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
                          ? AppColors.statusRed // Red when not running
                          : robotState.gpioStatus
                              ? AppColors
                                  .statusBlue // Blue when running and true
                              : AppColors
                                  .statusGreen, // Green when running and false
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
                          ? AppColors.statusRed
                          : robotState.i2cStatus
                              ? AppColors.statusBlue
                              : AppColors.statusGreen,
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
                          ? AppColors.statusRed
                          : robotState.adcStatus
                              ? AppColors.statusBlue
                              : AppColors.statusGreen,
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
                          ? AppColors.statusRed
                          : robotState.cameraStatus
                              ? AppColors
                                  .statusBlue // Blue when using test pattern
                              : AppColors
                                  .statusGreen, // Green when using real camera
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
                      ? AppColors.connected
                      : AppColors.disconnected,
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
                          ? AppColors.statusGreen
                          : AppColors.statusRed,
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
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Video URL: ${RobotState.videoUrl}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Native: ${RobotState.videoWidth}x${RobotState.videoHeight}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        RobotState.hasDetectedResolution
                            ? Icons.check_circle
                            : Icons.pending,
                        size: 16,
                        color: RobotState.hasDetectedResolution
                            ? Colors.green
                            : Colors.orange,
                      ),
                      const SizedBox(width: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          // Calculate the actual display size based on the video container
                          // The video is in the middle column with flex: 2 in a Row with total flex: 4
                          final containerWidth =
                              MediaQuery.of(context).size.width * 0.5;
                          final containerHeight =
                              MediaQuery.of(context).size.height - 200;

                          // Calculate the displayed size while maintaining aspect ratio
                          final aspectRatio = RobotState.hasDetectedResolution
                              ? RobotState.videoWidth / RobotState.videoHeight
                              : 4.0 /
                                  3.0; // Default 4:3 aspect ratio if not detected
                          int displayWidth;
                          int displayHeight;

                          if (containerWidth / containerHeight > aspectRatio) {
                            // Height constrained
                            displayHeight = containerHeight.toInt();
                            displayWidth =
                                (containerHeight * aspectRatio).toInt();
                          } else {
                            // Width constrained
                            displayWidth = containerWidth.toInt();
                            displayHeight =
                                (containerWidth / aspectRatio).toInt();
                          }

                          return Text(
                            'Display: ${displayWidth}x$displayHeight',
                            style: const TextStyle(fontSize: 14),
                          );
                        },
                      ),
                    ],
                  ),
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

                                  _publishDriveControl(desiredSpeed, details.x);
                                },
                                base: Container(
                                  width: 150,
                                  height: 150,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: robotState.distance < 10
                                        ? AppColors
                                            .distanceBackground // Light red background when too close
                                        : AppColors.joystickBase,
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
                                          Text(
                                            'TOO CLOSE!',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.distanceWarning,
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
                                    color: AppColors.joystickStick,
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
                          decoration: BoxDecoration(
                            border: Border.all(color: AppColors.borderColor),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: robotState.isRunning
                                      ? VideoFeedContainer(
                                          streaming: _videoEnabled,
                                        )
                                      : Center(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.power_off,
                                                  size: 48,
                                                  color:
                                                      AppColors.disabledText),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Robot is not running',
                                                style: TextStyle(
                                                    color:
                                                        AppColors.disabledText),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                'Video feed disabled',
                                                style: TextStyle(
                                                    color:
                                                        AppColors.disabledText,
                                                    fontSize: 12),
                                              ),
                                            ],
                                          ),
                                        ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    ElevatedButton.icon(
                                      onPressed: robotState.isRunning
                                          ? _getImage
                                          : null,
                                      icon: const Icon(Icons.camera_alt),
                                      label: const Text('Get image'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            AppColors.joystickStick,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Row(
                                      children: [
                                        Checkbox(
                                          value: _videoEnabled,
                                          onChanged: robotState.isRunning
                                              ? (value) =>
                                                  _toggleVideo(value ?? true)
                                              : null,
                                        ),
                                        const Text('Video'),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
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

                              _publishCameraControl(details.x, details.y);
                            },
                            base: Container(
                              width: 150,
                              height: 150,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.joystickBase,
                              ),
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
                    ),
                  ),
                ),
              ],
            ),
          ),

          // New text input and display at the bottom
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Text input field
                TextField(
                  controller: _promptController,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Enter prompt for LLaVA',
                    hintText: 'Ask about what you see in the image...',
                    suffixIcon: IconButton(
                      icon: Icon(
                          _isProcessing ? Icons.hourglass_top : Icons.send),
                      onPressed: _isProcessing ? null : _processPromptWithImage,
                    ),
                  ),
                  enabled: !_isProcessing && _llavaAvailable,
                  onSubmitted: (_) => _processPromptWithImage(),
                ),

                // Text display area
                Container(
                  margin: const EdgeInsets.only(top: 8.0),
                  padding: const EdgeInsets.all(12.0),
                  width: double.infinity,
                  height: 150, // Fixed height for response area
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(color: Colors.grey[400]!),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _llavaResponse,
                      style: TextStyle(fontSize: 14.0),
                    ),
                  ),
                ),

                // Status indicator
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Row(
                    children: [
                      Icon(
                        _llavaAvailable ? Icons.check_circle : Icons.error,
                        color: _llavaAvailable ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _llavaAvailable
                            ? 'LLaVA service connected'
                            : 'LLaVA service unavailable',
                        style: TextStyle(
                          fontSize: 12,
                          color: _llavaAvailable ? Colors.green : Colors.red,
                        ),
                      ),
                      const Spacer(),
                      if (_isProcessing)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
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
