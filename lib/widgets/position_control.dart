import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/robot_state.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'dart:convert';
import 'package:logging/logging.dart';
import '../main.dart' show kMqttTopicControlRequest;

class PositionControl extends StatefulWidget {
  final MqttClient mqttClient;

  const PositionControl({super.key, required this.mqttClient});

  @override
  State<PositionControl> createState() => _PositionControlState();
}

class _PositionControlState extends State<PositionControl> {
  final _logger = Logger('PositionControl');
  
  @override
  Widget build(BuildContext context) {
    final robotState = Provider.of<RobotState>(context);
    final isNarrow = MediaQuery.of(context).size.width < 600;

    Widget controlsRow = Row(
      children: [
        Expanded(
          flex: 3,
          child: Slider(
            min: -500,
            max: 500,
            divisions: 1000,
            value: robotState.targetPosition,
            onChanged: (value) {
              final roundedValue = value.round();
              robotState.setTargetPosition(roundedValue.toDouble());
              if (widget.mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
                final builder = MqttClientPayloadBuilder();
                final message = {
                  'command': 'set_position',
                  'position': roundedValue,
                };
                builder.addString(jsonEncode(message));
                widget.mqttClient.publishMessage(kMqttTopicControlRequest, MqttQos.atMostOnce, builder.payload!);
                _logger.fine('Published position update: $roundedValue');
              } else {
                _logger.warning('Cannot publish position: MQTT client not connected');
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () {
            robotState.setTargetPosition(0);
            if (widget.mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
              final builder = MqttClientPayloadBuilder();
              final message = {
                'command': 'set_position',
                'position': 0,
              };
              builder.addString(jsonEncode(message));
              widget.mqttClient.publishMessage(kMqttTopicControlRequest, MqttQos.atMostOnce, builder.payload!);
              _logger.fine('Published reset position command');
            } else {
              _logger.warning('Cannot reset position: MQTT client not connected');
            }
          },
          child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Zero Position'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Target: ${robotState.targetPosition.round()} mm',
            ),
          ),
        ),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Current: ${robotState.pos.round()} mm',
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Distance: ${robotState.distance.toStringAsFixed(1)} cm',
              style: TextStyle(
                color: robotState.distance < 10 ? Colors.red : Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );

    if (isNarrow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          controlsRow,
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        controlsRow,
      ],
    );
  }
}
