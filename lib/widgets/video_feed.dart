import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/robot_state.dart';
import '../utils/app_colors.dart';
import 'video_player_widget.dart';

class VideoFeed extends StatefulWidget {
  final bool videoEnabled;
  final Function() onGetImage;
  final Function(bool) onToggleVideo;

  const VideoFeed({
    super.key,
    required this.videoEnabled,
    required this.onGetImage,
    required this.onToggleVideo,
  });

  @override
  State<VideoFeed> createState() => _VideoFeedState();
}

class _VideoFeedState extends State<VideoFeed> {
  @override
  Widget build(BuildContext context) {
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
              child: Consumer<RobotState>(
                builder: (context, robotState, child) {
                  if (!robotState.isRunning) {
                    return _buildOfflineState();
                  }

                  return Stack(
                    children: [
                      VideoFeedContainer(
                        streaming: widget.videoEnabled,
                      ),
                      _buildDistanceIndicator(robotState),
                    ],
                  );
                },
              ),
            ),
          ),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildOfflineState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.power_off, size: 48, color: AppColors.disabledText),
          const SizedBox(height: 8),
          Text(
            'Robot is not running',
            style: TextStyle(color: AppColors.disabledText),
          ),
          const SizedBox(height: 4),
          Text(
            'Video feed disabled',
            style: TextStyle(color: AppColors.disabledText, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDistanceIndicator(RobotState robotState) {
    return Positioned(
      top: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: robotState.distance < 10
              ? Colors.red.withAlpha(204)
              : Colors.black.withAlpha(153),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.straighten,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Distance: ${robotState.distance == -2 ? '∞' : robotState.distance.toStringAsFixed(1)} cm',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return ElevatedButton.icon(
                onPressed: robotState.isRunning ? widget.onGetImage : null,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Get image'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.joystickStick,
                  foregroundColor: Colors.white,
                ),
              );
            },
          ),
          const SizedBox(width: 16),
          Consumer<RobotState>(
            builder: (context, robotState, child) {
              return Row(
                children: [
                  Checkbox(
                    value: widget.videoEnabled,
                    onChanged: robotState.isRunning
                        ? (value) => widget.onToggleVideo(value ?? true)
                        : null,
                  ),
                  const Text('Video'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
} 