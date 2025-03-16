import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:logging/logging.dart';
import '../config/mqtt_config.dart';
import '../models/robot_state.dart';

class MqttService extends ChangeNotifier {
  final _logger = Logger('MqttService');
  late MqttServerClient _client;
  bool _isConnected = false;
  Timer? _statusCheckTimer;
  Timer? _statusTimeoutTimer;
  final RobotState _robotState;

  // Cache payload builders to avoid recreating them
  final _statusPayloadBuilder = MqttClientPayloadBuilder();
  final _drivePayloadBuilder = MqttClientPayloadBuilder();
  final _cameraPayloadBuilder = MqttClientPayloadBuilder();

  // Debounce timers for control messages
  Timer? _driveDebounceTimer;
  Timer? _cameraDebounceTimer;

  // Last sent values to avoid duplicate messages
  double? _lastSentSpeed;
  double? _lastSentTurn;
  double? _lastSentPan;
  double? _lastSentTilt;

  bool get isConnected => _isConnected;
  MqttServerClient get client => _client;

  MqttService({required RobotState robotState}) : _robotState = robotState {
    _setupMqttClient();
  }

  void _setupMqttClient() {
    _client = MqttServerClient(
      MqttConfig.serverIp,
      'picar_client_${DateTime.now().millisecondsSinceEpoch}',
    );
    _client.port = MqttConfig.port;
    _client.keepAlivePeriod = MqttConfig.keepAlivePeriod;
    _client.logging(on: false);
    _client.autoReconnect = false;
    _client.resubscribeOnAutoReconnect = true;
    _client.secure = false;

    _client.onDisconnected = _onDisconnected;
    _client.onConnected = _onConnected;
    _client.pongCallback = _onPong;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('picar_client_${DateTime.now().millisecondsSinceEpoch}')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .withWillTopic(MqttConfig.topicStatusRequest)
        .withWillMessage('offline');
    _client.connectionMessage = connMessage;

    _connect();
  }

  Future<void> _connect() async {
    try {
      _logger.info('Attempting to connect to MQTT broker...');
      await Future.delayed(const Duration(milliseconds: 500));

      final connectionStatus = await _client.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.warning('MQTT connection attempt timed out');
          return null;
        },
      );

      if (connectionStatus == null) {
        _logger.severe('Connection timed out');
        _updateConnectionStatus(false);
        return;
      }

      if (_client.connectionStatus?.state == MqttConnectionState.connected) {
        _logger.info('Successfully connected to MQTT broker');
        _updateConnectionStatus(true);
      } else {
        _logger.warning('Failed to connect: ${_client.connectionStatus?.state}');
        _updateConnectionStatus(false);
      }
    } catch (e) {
      _logger.severe('Failed to connect to MQTT broker: $e');
      _updateConnectionStatus(false);
    }
  }

  void _onDisconnected() {
    _logger.info('MQTT client disconnected');
    _updateConnectionStatus(false);

    Future.delayed(const Duration(seconds: 10), () {
      if (!_isConnected) {
        _logger.info('Attempting to reconnect to MQTT broker...');
        _connect();
      }
    });
  }

  void _onConnected() {
    _logger.info('MQTT client connected');
    _updateConnectionStatus(true);

    _client.subscribe(MqttConfig.topicStatusResponse, MqttQos.atMostOnce);
    _setupMessageHandler();
    _startStatusCheck();
  }

  void _onPong() {
    _logger.fine('Ping response received');
    _updateConnectionStatus(true);
  }

  void _updateConnectionStatus(bool connected) {
    if (_isConnected != connected) {
      _isConnected = connected;
      notifyListeners();
    }
  }

  void _setupMessageHandler() {
    _client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(message.payload.message);

      if (c[0].topic == MqttConfig.topicStatusResponse) {
        _statusTimeoutTimer?.cancel();
        _handleStatusResponse(payload);
      }
    });
  }

  void _handleStatusResponse(String payload) {
    try {
      _logger.info('Received status response: $payload');
      final jsonResponse = jsonDecode(payload) as Map<String, dynamic>;
      
      // Update the robot state using the provided instance
      _robotState.updateFromJson(jsonResponse);
      
      // Check for camera availability
      final bool cameraAvailable = _robotState.isRunning &&
          jsonResponse.containsKey('mock_status') &&
          jsonResponse['mock_status'].containsKey('camera');
      
      // Update video availability if needed
      if (RobotState.isVideoAvailable != cameraAvailable) {
        _logger.info('Updating video availability: ${RobotState.isVideoAvailable} -> $cameraAvailable');
        RobotState.isVideoAvailable = cameraAvailable;
      }
    } catch (e) {
      _logger.warning('Failed to parse status response: $e');
    }
  }

  void _startStatusCheck() {
    _statusCheckTimer?.cancel();
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isConnected) {
        _requestRobotStatus();
      }
    });
  }

  void _requestRobotStatus() {
    _statusPayloadBuilder.clear();
    final statusMessage = jsonEncode({'command': 'status'});
    _statusPayloadBuilder.addString(statusMessage);

    _client.publishMessage(
      MqttConfig.topicStatusRequest,
      MqttConfig.defaultQos,
      _statusPayloadBuilder.payload!,
    );

    _statusTimeoutTimer?.cancel();
    _statusTimeoutTimer = Timer(const Duration(seconds: 1), () {
      _robotState.updateFromJson({'Vb': 0.0});
      _logger.warning('No status response received, connection may be lost');
    });
  }

  void publishDriveControl(double speed, double turn) {
    if (!_isConnected) return;

    if (_lastSentSpeed != null &&
        _lastSentTurn != null &&
        (speed - _lastSentSpeed!).abs() < 0.01 &&
        (turn - _lastSentTurn!).abs() < 0.01) {
      return;
    }

    _driveDebounceTimer?.cancel();
    _driveDebounceTimer = Timer(const Duration(milliseconds: 50), () {
      _lastSentSpeed = speed;
      _lastSentTurn = turn;

      _drivePayloadBuilder.clear();
      _drivePayloadBuilder.addString(
        '{"turn": ${turn.toStringAsFixed(2)}, "speed": ${speed.toStringAsFixed(2)}}',
      );

      _client.publishMessage(
        MqttConfig.topicControlRequest,
        MqttConfig.defaultQos,
        _drivePayloadBuilder.payload!,
      );
    });
  }

  void publishCameraControl(double pan, double tilt) {
    if (!_isConnected) return;

    if (_lastSentPan != null &&
        _lastSentTilt != null &&
        (pan - _lastSentPan!).abs() < 0.01 &&
        (tilt - _lastSentTilt!).abs() < 0.01) {
      return;
    }

    _cameraDebounceTimer?.cancel();
    _cameraDebounceTimer = Timer(const Duration(milliseconds: 50), () {
      _lastSentPan = pan;
      _lastSentTilt = tilt;

      _cameraPayloadBuilder.clear();
      final controlMessage = {'tilt': tilt * 90, 'pan': pan * 90};
      _cameraPayloadBuilder.addString(json.encode(controlMessage));

      _client.publishMessage(
        MqttConfig.topicControlRequest,
        MqttConfig.defaultQos,
        _cameraPayloadBuilder.payload!,
      );
    });
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _statusTimeoutTimer?.cancel();
    _driveDebounceTimer?.cancel();
    _cameraDebounceTimer?.cancel();
    _client.disconnect();
    super.dispose();
  }
} 