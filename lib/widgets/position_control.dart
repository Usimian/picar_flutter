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
                  // 'timestamp': DateTime.now().toIso8601String()
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
        ElevatedButton(
          onPressed: () {
            robotState.setTargetPosition(0);
            if (widget.mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
              final builder = MqttClientPayloadBuilder();
              final message = {
                'command': 'set_position',
                'position': 0,
                // 'timestamp': DateTime.now().toIso8601String()
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
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: robotState.vb > 0  // Robot is running
                ? (robotState.adcStatus 
                    ? const Color.fromARGB(255, 0, 0, 255)  // Blue when running and ADC is mocked
                    : robotState.vb < 7.5
                        ? Colors.red   // Red when running but low battery
                        : Colors.green)  // Green when running and good battery
                : Colors.red,  // Red when not running
            borderRadius: BorderRadius.circular(4),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Battery: ${robotState.vb.toStringAsFixed(2)}V',
              style: const TextStyle(
                color: Colors.white,
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
