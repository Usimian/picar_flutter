import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class ParameterDisplay extends StatelessWidget {
  final MqttServerClient mqttClient;

  const ParameterDisplay({
    super.key,
    required this.mqttClient,
  });

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink(); // Remove the entire parameter display since it only showed PID-related values
  }
}
