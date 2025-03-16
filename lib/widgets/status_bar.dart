import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/robot_state.dart';
import '../services/mqtt_service.dart';
import '../utils/app_colors.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          // Battery Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return Row(
                children: [
                  Icon(
                    Icons.battery_full,
                    color: robotState.getBatteryColor(),
                    size: 24,
                  ),
                  const SizedBox(width: 4),
                  Text('${robotState.vb.toStringAsFixed(2)}V'),
                ],
              );
            },
          ),
          const SizedBox(width: 16),

          // GPIO Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return _StatusIndicator(
                icon: Icons.car_repair,
                label: 'GPIO',
                isRunning: robotState.isRunning,
                status: robotState.gpioStatus,
              );
            },
          ),
          const SizedBox(width: 16),

          // I2C Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return _StatusIndicator(
                icon: Icons.cable,
                label: 'I2C',
                isRunning: robotState.isRunning,
                status: robotState.i2cStatus,
              );
            },
          ),
          const SizedBox(width: 16),

          // ADC Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return _StatusIndicator(
                icon: Icons.memory,
                label: 'ADC',
                isRunning: robotState.isRunning,
                status: robotState.adcStatus,
              );
            },
          ),
          const SizedBox(width: 16),

          // Camera Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return _StatusIndicator(
                icon: Icons.camera_alt,
                label: 'Camera',
                isRunning: robotState.isRunning,
                status: robotState.cameraStatus,
              );
            },
          ),
          const SizedBox(width: 16),

          // Connection Status
          Consumer<MqttService>(
            builder: (context, mqttService, child) {
              return Row(
                children: [
                  Icon(
                    Icons.connect_without_contact,
                    color: mqttService.isConnected
                        ? AppColors.connected
                        : AppColors.disconnected,
                    size: 24,
                  ),
                  const SizedBox(width: 4),
                  Text(mqttService.isConnected ? 'Connected' : 'Disconnected'),
                ],
              );
            },
          ),
          const SizedBox(width: 16),

          // Robot Running Status
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return Row(
                children: [
                  Icon(
                    Icons.run_circle,
                    color: robotState.isRunning
                        ? AppColors.statusGreen
                        : AppColors.statusRed,
                    size: 24,
                  ),
                  const SizedBox(width: 4),
                  Text(robotState.isRunning ? 'Running' : 'Stopped'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isRunning;
  final bool status;

  const _StatusIndicator({
    required this.icon,
    required this.label,
    required this.isRunning,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          color: !isRunning
              ? AppColors.statusRed
              : status
                  ? AppColors.statusBlue
                  : AppColors.statusGreen,
          size: 24,
        ),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }
} 