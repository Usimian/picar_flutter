import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/robot_state.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'dart:convert';
import 'package:logging/logging.dart';
import '../main.dart' show kMqttTopicControlRequest;
import 'dart:async';
import '../utils/app_colors.dart';

class PositionControl extends StatefulWidget {
  final MqttClient mqttClient;

  const PositionControl({super.key, required this.mqttClient});

  @override
  State<PositionControl> createState() => _PositionControlState();
}

class _PositionControlState extends State<PositionControl> {
  final _logger = Logger('PositionControl');
  final _payloadBuilder = MqttClientPayloadBuilder();
  Timer? _debounceTimer;
  int? _lastSentPosition;

  void _publishPositionUpdate(int position) {
    if (_lastSentPosition == position ||
        widget.mqttClient.connectionStatus?.state !=
            MqttConnectionState.connected) {
      return;
    }

    _lastSentPosition = position;
    _payloadBuilder.clear();

    final message = {
      'command': 'set_position',
      'position': position,
    };

    _payloadBuilder.addString(jsonEncode(message));
    widget.mqttClient.publishMessage(
        kMqttTopicControlRequest, MqttQos.atMostOnce, _payloadBuilder.payload!);

    _logger.fine('Published position update: $position');
  }

  void _debouncedPositionUpdate(int position) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      _publishPositionUpdate(position);
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RobotState>(
      builder: (context, robotState, _) {
        final targetText = Text(
          'Target: ${robotState.targetPosition.round()} mm',
        );

        final currentText = Text(
          'Current: ${robotState.pos.round()} mm',
        );

        final distanceText = Text(
          'Distance: ${robotState.distance == -2 ? '∞' : robotState.distance.toStringAsFixed(1)} cm',
          style: TextStyle(
            color: robotState.distance == -2
                ? AppColors.distanceWarning
                : (robotState.distance < 10
                    ? AppColors.distanceWarning
                    : AppColors.distanceNormal),
            fontWeight: FontWeight.bold,
          ),
        );

        final slider = Slider(
          min: -500,
          max: 500,
          divisions: 1000,
          value: robotState.targetPosition,
          onChanged: (value) {
            final roundedValue = value.round();
            robotState.setTargetPosition(roundedValue.toDouble());
            _debouncedPositionUpdate(roundedValue);
          },
        );

        final resetButton = ElevatedButton(
          onPressed: () {
            robotState.setTargetPosition(0);
            _publishPositionUpdate(0);
          },
          child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Zero Position'),
          ),
        );

        final controlsRow = Row(
          children: [
            Expanded(
              flex: 3,
              child: slider,
            ),
            const SizedBox(width: 8),
            resetButton,
            const SizedBox(width: 8),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: targetText,
              ),
            ),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: currentText,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: distanceText,
              ),
            ),
          ],
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            controlsRow,
          ],
        );
      },
    );
  }
}
