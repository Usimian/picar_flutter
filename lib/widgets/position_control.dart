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
  
  // PID state variables
  double _kp = 2.0;
  double _ki = 0.5;
  double _kd = 1.0;
  double _kp2 = 2.0;
  double _ki2 = 0.5;
  double _kd2 = 1.0;

  @override
  Widget build(BuildContext context) {
    return Consumer<RobotState>(
      builder: (context, robotState, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            bool isNarrow = constraints.maxWidth < 600;
            
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
                            : robotState.vb < 10.0 
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
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          const Text('PID Control', style: TextStyle(fontSize: 18)),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              // R Values Column
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey[400]!),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    _buildRValueDisplay("Rp", robotState.rp),
                                    const SizedBox(height: 40),
                                    _buildRValueDisplay("Ri", robotState.ri),
                                    const SizedBox(height: 40),
                                    _buildRValueDisplay("Rd", robotState.rd),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              // PID Sliders
                              Expanded(
                                child: Column(
                                  children: [
                                    _buildPidSlider(
                                      label: "KP",
                                      value: _kp,
                                      onChanged: (value) {
                                        setState(() => _kp = value);
                                        _sendPidUpdate('kp', value);
                                      },
                                    ),
                                    _buildPidSlider(
                                      label: "KI",
                                      value: _ki,
                                      onChanged: (value) {
                                        setState(() => _ki = value);
                                        _sendPidUpdate('ki', value);
                                      },
                                    ),
                                    _buildPidSlider(
                                      label: "KD",
                                      value: _kd,
                                      onChanged: (value) {
                                        setState(() => _kd = value);
                                        _sendPidUpdate('kd', value);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  children: [
                                    _buildPidSlider(
                                      label: "KP2",
                                      value: _kp2,
                                      onChanged: (value) {
                                        setState(() => _kp2 = value);
                                        _sendPidUpdate('kp2', value);
                                      },
                                    ),
                                    _buildPidSlider(
                                      label: "KI2",
                                      value: _ki2,
                                      onChanged: (value) {
                                        setState(() => _ki2 = value);
                                        _sendPidUpdate('ki2', value);
                                      },
                                    ),
                                    _buildPidSlider(
                                      label: "KD2",
                                      value: _kd2,
                                      onChanged: (value) {
                                        setState(() => _kd2 = value);
                                        _sendPidUpdate('kd2', value);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                controlsRow,
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text('PID Control', style: TextStyle(fontSize: 18)),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            // R Values Column
                            Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey[400]!),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    _buildRValueDisplay("Rp", robotState.rp),
                                    const SizedBox(height: 40),
                                    _buildRValueDisplay("Ri", robotState.ri),
                                    const SizedBox(height: 40),
                                    _buildRValueDisplay("Rd", robotState.rd),
                                  ],
                                ),
                              ),
                            const SizedBox(width: 16),
                            // PID Sliders
                            Expanded(
                              child: Column(
                                children: [
                                  _buildPidSlider(
                                    label: "KP",
                                    value: _kp,
                                    onChanged: (value) {
                                      setState(() => _kp = value);
                                      _sendPidUpdate('kp', value);
                                    },
                                  ),
                                  _buildPidSlider(
                                    label: "KI",
                                    value: _ki,
                                    onChanged: (value) {
                                      setState(() => _ki = value);
                                      _sendPidUpdate('ki', value);
                                    },
                                  ),
                                  _buildPidSlider(
                                    label: "KD",
                                    value: _kd,
                                    onChanged: (value) {
                                      setState(() => _kd = value);
                                      _sendPidUpdate('kd', value);
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                children: [
                                  _buildPidSlider(
                                    label: "KP2",
                                    value: _kp2,
                                    onChanged: (value) {
                                      setState(() => _kp2 = value);
                                      _sendPidUpdate('kp2', value);
                                    },
                                  ),
                                  _buildPidSlider(
                                    label: "KI2",
                                    value: _ki2,
                                    onChanged: (value) {
                                      setState(() => _ki2 = value);
                                      _sendPidUpdate('ki2', value);
                                    },
                                  ),
                                  _buildPidSlider(
                                    label: "KD2",
                                    value: _kd2,
                                    onChanged: (value) {
                                      setState(() => _kd2 = value);
                                      _sendPidUpdate('kd2', value);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPidSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: 0.0,
              max: 5.0,
              divisions: 50,
              label: value.toStringAsFixed(2),
              onChanged: (double newValue) {
                onChanged(newValue);
              },
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              value.toStringAsFixed(2),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRValueDisplay(String label, double value) {
    return Consumer<RobotState>(
      builder: (context, robotState, child) {
        final textColor = robotState.vb <= 0 
            ? Colors.red  // Red when not running
            : robotState.adcStatus 
                ? const Color.fromARGB(255, 0, 0, 255)  // Blue when running and ADC is mocked
                : Colors.black;  // Default color when running and ADC not mocked
            
        return Container(
          width: 100,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label, 
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: textColor,
                )
              ),
              Text(
                value.toStringAsFixed(2),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: textColor,
                ),
              ),
            ],
          ),
        );
      }
    );
  }

  void _sendPidUpdate(String parameter, double value) {
    if (widget.mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      final message = {
        'command': 'pid_update',
        'parameter': parameter,
        'value': value,
      };
      builder.addString(jsonEncode(message));
      widget.mqttClient.publishMessage(
        kMqttTopicControlRequest,
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      _logger.fine('Published PID update: $parameter = $value');
    } else {
      _logger.warning('Cannot update PID: MQTT client not connected');
    }
  }
}
