import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/robot_state.dart';

class VideoResolutionInfo extends StatelessWidget {
  const VideoResolutionInfo({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                    final containerWidth =
                        MediaQuery.of(context).size.width * 0.5;
                    final containerHeight =
                        MediaQuery.of(context).size.height - 200;

                    final aspectRatio = RobotState.hasDetectedResolution
                        ? RobotState.videoWidth / RobotState.videoHeight
                        : 4.0 / 3.0;
                    int displayWidth;
                    int displayHeight;

                    if (containerWidth / containerHeight > aspectRatio) {
                      displayHeight = containerHeight.toInt();
                      displayWidth = (containerHeight * aspectRatio).toInt();
                    } else {
                      displayWidth = containerWidth.toInt();
                      displayHeight = (containerWidth / aspectRatio).toInt();
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
    );
  }
} 