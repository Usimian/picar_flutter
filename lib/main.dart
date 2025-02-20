import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:logging/logging.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'dart:async';
import 'dart:convert'; // Import the dart:convert library
import 'models/robot_state.dart';
import 'widgets/position_control.dart';

// MQTT Topics
const String kMqttTopicStatusRequest = 'picar/status_request';
const String kMqttTopicStatusResponse = 'picar/status_response';
const String kMqttTopicControlRequest = 'picar/control_request';
const String kMqttTopicStatusInfo = 'picar/status_info';          // Get battery level and ultrasonic distance

void main() {
  // Set up logging
  hierarchicalLoggingEnabled = true;  // Enable per-logger levels
  Logger.root.level = Level.WARNING;
  
  // Set MQTT logging level
  Logger('mqtt_client').level = Level.SEVERE;  // This controls the MQTT client package logging

  final mainLogger = Logger('Main');
  
  Logger.root.onRecord.listen((record) {
    final message = StringBuffer();
    message.write('${record.time}: ${record.level.name}: ${record.loggerName}: ${record.message}');
    
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
  static const String _mqttServerIp = '192.168.1.167'; // Update this to your robot's IP address
  late RobotState _robotState;
  late MqttServerClient _mqttClient;
  final _logger = Logger('DashboardScreen');
  bool _isMqttConnected = false;
  bool _isRobotRunning = false;
  Timer? _connectionCheckTimer;
  Timer? _statusCheckTimer;
  Timer? _statusTimeoutTimer;
  double _currentSpeed = 0.0;  // Add speed tracking
  double _currentTurn = 0.0;   // Add turn tracking
  double _currentPan = 0.0;    // Add pan tracking
  double _currentTilt = 0.0;   // Add tilt tracking

  @override
  void initState() {
    super.initState();
    _robotState = context.read<RobotState>();
    _setupMqttClient();
    
    // Start periodic connection check
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted && _mqttClient.connectionStatus?.state != MqttConnectionState.connected) {
        setState(() {
          _isMqttConnected = false;
        });
      }
    });

    // Start periodic status check
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted && _isMqttConnected) {
        _requestRobotStatus();
      }
    });
  }

  void _requestRobotStatus() {
    final builder = MqttClientPayloadBuilder();
    builder.addString('status');
    _mqttClient.publishMessage(
      kMqttTopicStatusRequest,
      MqttQos.atMostOnce,
      builder.payload!,
    );

    // Request status info for ultrasonic distance and battery
    final statusBuilder = MqttClientPayloadBuilder();
    statusBuilder.addString('status');
    _mqttClient.publishMessage(
      kMqttTopicStatusInfo,
      MqttQos.atLeastOnce,  // Changed from atMostOnce to ensure delivery
      statusBuilder.payload!,
    );

    // Cancel any existing timeout timer
    _statusTimeoutTimer?.cancel();
    
    // Start a new timeout timer
    _statusTimeoutTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _isRobotRunning = false;  // Set to stopped if no response received
        });
        // Set battery voltage to 0 when no response
        _robotState.updateFromJson({'Vb': 0.0});
      }
    });
  }

  Future<void> _setupMqttClient() async {
    _mqttClient = MqttServerClient(_mqttServerIp, 'picar_client_${DateTime.now().millisecondsSinceEpoch}');
    _mqttClient.port = 1883;
    _mqttClient.keepAlivePeriod = 20; // Reduced keep-alive period for faster detection
    _mqttClient.logging(on: false);
    _mqttClient.autoReconnect = true;
    _mqttClient.resubscribeOnAutoReconnect = true;
    _mqttClient.secure = false;
    _mqttClient.onDisconnected = _onDisconnected;
    _mqttClient.onConnected = _onConnected;
    _mqttClient.onAutoReconnect = () {
      _logger.info('Auto reconnect triggered');
      setState(() {
        _isMqttConnected = false;
      });
    };
    _mqttClient.onAutoReconnected = () {
      _logger.info('Auto reconnected successfully');
      setState(() {
        _isMqttConnected = true;
      });
    };
    _mqttClient.pongCallback = () {
      _logger.fine('Ping response received');
      setState(() {
        _isMqttConnected = true;
      });
    };

    // Set connection message with more detailed options
    final connMessage = MqttConnectMessage()
        .withClientIdentifier('picar_client_${DateTime.now().millisecondsSinceEpoch}')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .withWillTopic(kMqttTopicStatusRequest)
        .withWillMessage('offline');
    _mqttClient.connectionMessage = connMessage;

    try {
      _logger.info('Attempting to connect to MQTT broker at $_mqttServerIp:${_mqttClient.port}');
      _logger.info('Connection settings: keepAlive=${_mqttClient.keepAlivePeriod}, autoReconnect=${_mqttClient.autoReconnect}');
      
      await _mqttClient.connect();
      
      if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
        _logger.info('Successfully connected to MQTT broker');
        _logger.info('Client state: ${_mqttClient.connectionStatus}');
        setState(() {
          _isMqttConnected = true;
        });
      } else {
        _logger.severe('Failed to connect. Status: ${_mqttClient.connectionStatus?.state}');
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
    }
  }

  Future<void> _connectClient() async {
    try {
      _logger.info('MQTT Connecting...');
      await _mqttClient.connect();
      if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
        _logger.info('MQTT client connected successfully');
        setState(() {
          _isMqttConnected = true;
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
    // Try to reconnect after a delay
    Future.delayed(const Duration(seconds: 5), () {
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

    // Subscribe to response topic
    _mqttClient.subscribe(kMqttTopicStatusResponse, MqttQos.atMostOnce);
    _mqttClient.subscribe(kMqttTopicStatusInfo, MqttQos.atMostOnce);

    // Set up message handler for status updates
    _mqttClient.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(message.payload.message);
      
      if (c[0].topic == kMqttTopicStatusResponse) {
        // Cancel the timeout timer since we received a response
        _statusTimeoutTimer?.cancel();
        
        try {
          _logger.info('Received status response: $payload');
          final Map<String, dynamic> jsonResponse = jsonDecode(payload);
          final double batteryVoltage = jsonResponse['Vb']?.toDouble() ?? 0.0;
          final bool isRunning = batteryVoltage > 0;
          
          setState(() {
            _isRobotRunning = isRunning;
          });
          
          // Update robot state with all parameters from the response
          _robotState.updateFromJson(jsonResponse);
        } catch (e) {
          _logger.warning('Failed to parse status response: $e');
        }
      }
    });
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
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
                Icon(
                  Icons.car_repair,
                  color: !_isRobotRunning 
                      ? const Color.fromARGB(255, 255, 0, 0)  // Red when not running
                      : context.watch<RobotState>().gpioStatus 
                          ? const Color.fromARGB(255, 0, 0, 255)  // Blue when running and true
                          : const Color.fromARGB(255, 0, 255, 8),  // Green when running and false
                  size: 24,
                ),
                const SizedBox(width: 4),
                const Text('GPIO'),
                const SizedBox(width: 8),
                
                // I2C Status
                Icon(
                  Icons.cable,
                  color: !_isRobotRunning 
                      ? const Color.fromARGB(255, 255, 0, 0)
                      : context.watch<RobotState>().i2cStatus 
                          ? const Color.fromARGB(255, 0, 0, 255)
                          : const Color.fromARGB(255, 0, 255, 8),
                  size: 24,
                ),
                const SizedBox(width: 4),
                const Text('I2C'),
                const SizedBox(width: 8),
                
                // ADC Status
                Icon(
                  Icons.memory,
                  color: !_isRobotRunning 
                      ? const Color.fromARGB(255, 255, 0, 0)
                      : context.watch<RobotState>().adcStatus 
                          ? const Color.fromARGB(255, 0, 0, 255)
                          : const Color.fromARGB(255, 0, 255, 8),
                  size: 24,
                ),
                const SizedBox(width: 4),
                const Text('ADC'),
                const SizedBox(width: 8),
                
                // Camera Status
                Icon(
                  Icons.camera_alt,
                  color: !_isRobotRunning 
                      ? const Color.fromARGB(255, 255, 0, 0)
                      : context.watch<RobotState>().cameraStatus 
                          ? const Color.fromARGB(255, 0, 0, 255)  // Blue when using test pattern
                          : const Color.fromARGB(255, 0, 255, 8),  // Green when using real camera
                  size: 24,
                ),
                const SizedBox(width: 4),
                const Text('Camera'),
                const SizedBox(width: 8),

                // Connection Status
                Icon(
                  Icons.connect_without_contact,
                  color: _isMqttConnected ? const Color.fromARGB(255, 0, 255, 8) : const Color.fromARGB(255, 255, 17, 0),
                  size: 24,
                ),
                const SizedBox(width: 4),
                Text(_isMqttConnected ? 'Connected' : 'Disconnected'),
                const SizedBox(width: 16),
                
                // Robot Running Status
                Icon(
                  Icons.run_circle,
                  color: _isRobotRunning ? const Color.fromARGB(255, 0, 255, 8) : const Color.fromARGB(255, 255, 0, 0),
                  size: 24,
                ),
                const SizedBox(width: 4),
                Text(_isRobotRunning ? 'Running' : 'Stopped'),
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
                                  
                                  // If distance is less than 10cm and trying to move forward, force speed to 0
                                  if (robotState.distance < 30 && desiredSpeed > 0) {
                                    desiredSpeed = 0;
                                  }

                                  setState(() {
                                    _currentSpeed = desiredSpeed;
                                    _currentTurn = details.x;
                                  });

                                  if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
                                    final builder = MqttClientPayloadBuilder();
                                    builder.addString(
                                        '{"turn": ${details.x.toStringAsFixed(2)}, "speed": ${desiredSpeed.toStringAsFixed(2)}}');
                                    _mqttClient.publishMessage(
                                      'picar/control_request',
                                      MqttQos.atLeastOnce,
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
                                        ? Colors.red[100]  // Light red background when too close
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
                            child: Mjpeg(
                              isLive: true,
                              stream: RobotState.videoUrl,
                              error: (context, error, stack) {
                                return const Center(
                                  child: Text('Error loading video stream'),
                                );
                              },
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
                              if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
                                // details.x and details.y are already normalized to -1.0 to 1.0
                                final controlMessage = {
                                  'tilt': details.y*90,  // Invert Y axis so up is positive
                                  'pan': details.x*90
                                };
                                
                                // Publish control message
                                final builder = MqttClientPayloadBuilder();
                                builder.addString(json.encode(controlMessage));
                                _mqttClient.publishMessage(
                                  kMqttTopicControlRequest,
                                  MqttQos.atLeastOnce,
                                  builder.payload!
                                );
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
