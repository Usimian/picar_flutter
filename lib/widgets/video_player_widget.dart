import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'dart:async';
import '../models/robot_state.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';

// Custom preprocessor to detect frame updates
class FrameDetectionPreprocessor extends MjpegPreprocessor {
  final Function onFrameReceived;

  FrameDetectionPreprocessor(this.onFrameReceived);

  @override
  List<int>? process(List<int> frame) {
    // Call the callback when a frame is received
    onFrameReceived();
    // Return the original frame
    return frame;
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final String videoUrl;

  const VideoPlayerWidget({
    super.key,
    required this.videoUrl,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  // Add logger instance
  final _logger = Logger('VideoPlayerWidget');

  bool _isConnected = false;
  Timer? _retryTimer;
  Key _streamKey = UniqueKey();
  int _retryCount = 0;
  static const int maxRetries = 3;

  // Add variables for video feed monitoring
  DateTime? _lastFrameTimestamp;
  Timer? _frameCheckTimer;
  bool _isVideoStalled = false;
  static const Duration stallThreshold = Duration(seconds: 3);

  // Add debounce variables to prevent excessive rebuilds
  bool _needsRebuild = false;
  Timer? _rebuildDebounceTimer;

  @override
  void initState() {
    super.initState();
    _startRetryTimer();
    _startFrameCheckTimer();
    _startRebuildDebounceTimer();

    // Initially set connection status based on robot state
    _isConnected = RobotState.isVideoAvailable;

    // Force a rebuild when the app starts to ensure video shows if available
    if (_isConnected) {
      _requestRebuild();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Get the current robot running state
    final robotRunning =
        Provider.of<RobotState>(context, listen: false).isRunning;

    // Make sure we have the latest video availability state
    // Only consider video available if the robot is running
    final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;

    if (_isConnected != videoAvailable) {
      _isConnected = videoAvailable;
      _requestRebuild();
    }

    // Debug log to help troubleshoot
    _logger.info(
        'didChangeDependencies: robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, videoAvailable=$videoAvailable, videoUrl=${widget.videoUrl}');
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _frameCheckTimer?.cancel();
    _rebuildDebounceTimer?.cancel();
    super.dispose();
  }

  // Improve the debounce timer for rebuilds with a true debounce pattern
  void _startRebuildDebounceTimer() {
    // Cancel any existing timer first
    _rebuildDebounceTimer?.cancel();

    // Create a periodic check, but only rebuild when needed
    _rebuildDebounceTimer =
        Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (_needsRebuild && mounted) {
        setState(() {
          _needsRebuild = false;
        });
      }

      // Also check if RobotState.isVideoAvailable has changed
      // Only consider video available if the robot is running
      final robotRunning =
          Provider.of<RobotState>(context, listen: false).isRunning;
      final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;

      if (_isConnected != videoAvailable) {
        _isConnected = videoAvailable;
        setState(() {});
      }
    });
  }

  // Request a rebuild with proper debouncing
  void _requestRebuild() {
    _needsRebuild = true;
    // No immediate setState - the periodic timer will handle it
  }

  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isConnected && mounted && _retryCount < maxRetries) {
        _requestRebuild();
        _streamKey = UniqueKey(); // Force stream reconnection
        _retryCount++;
        _isConnected = true; // Assume connected until error occurs
        _isVideoStalled = false; // Reset stall detection on retry
        _lastFrameTimestamp = DateTime.now(); // Reset frame timestamp
      } else if (_retryCount >= maxRetries) {
        // After max retries, slow down retry attempts
        timer.cancel();
        Timer(const Duration(seconds: 5), () {
          if (mounted) {
            _retryCount = 0;
            _startRetryTimer();
          }
        });
      }
    });
  }

  // Add method to start frame check timer
  void _startFrameCheckTimer() {
    _frameCheckTimer?.cancel();
    _frameCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      // Get the current robot running state
      final robotRunning =
          Provider.of<RobotState>(context, listen: false).isRunning;

      // Only check for video stalls if the robot is running
      if (mounted &&
          _isConnected &&
          _lastFrameTimestamp != null &&
          robotRunning) {
        final now = DateTime.now();
        final timeSinceLastFrame = now.difference(_lastFrameTimestamp!);

        // Also check video stalled status in RobotState
        final isStalled =
            RobotState.checkVideoStalled(stallThreshold: stallThreshold);

        if ((timeSinceLastFrame > stallThreshold || isStalled) &&
            !_isVideoStalled) {
          _isVideoStalled = true;
          _requestRebuild(); // Use the debounce method instead

          // Update robot state to reflect video unavailability
          // Only update if we're the first to detect the issue
          if (RobotState.isVideoAvailable) {
            RobotState.isVideoAvailable = false;
          }

          // Try to restart the video stream - but only do this once per stall detection
          _streamKey = UniqueKey();
        }
      }
    });
  }

  // Add method to update frame timestamp
  void _updateFrameTimestamp() {
    final now = DateTime.now();

    // Increase threshold to reduce sensitivity (from 100ms to 250ms)
    if (_lastFrameTimestamp == null ||
        now.difference(_lastFrameTimestamp!).inMilliseconds > 250) {
      _lastFrameTimestamp = now;

      // Also update the frame timestamp in RobotState
      RobotState.updateVideoFrameTime();

      if (_isVideoStalled) {
        _isVideoStalled = false;
        _requestRebuild(); // Use the debounce method instead

        // Update robot state to reflect video availability
        // Only update if we're the first to detect recovery
        if (!RobotState.isVideoAvailable) {
          RobotState.isVideoAvailable = true;
        }
      }
    }
  }

  void _handleError() {
    if (!mounted) return;

    // Use the debounce method instead of immediate setState
    _isConnected = false;
    _requestRebuild();
  }

  @override
  Widget build(BuildContext context) {
    // Use local variables to prevent rebuilds due to state changes during build
    final robotRunning =
        Provider.of<RobotState>(context, listen: false).isRunning;
    final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;
    final bool localIsConnected = _isConnected;
    final bool localIsStalled = _isVideoStalled;

    // Debug log to help troubleshoot
    _logger.info(
        'build: robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, videoAvailable=$videoAvailable, localIsConnected=$localIsConnected, videoUrl=${widget.videoUrl}');

    // Always attempt to show the video feed if the robot is running
    // This is a more permissive approach that will try to connect even if isVideoAvailable is false
    if (!robotRunning) {
      return Container(
        width: 320,
        height: 240,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            border: Border.all(
              color: Colors.grey,
              width: 1.0,
            ),
            borderRadius: BorderRadius.zero),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('Robot not running', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    // Ensure the video URL is valid
    final String videoUrl = widget.videoUrl.trim();
    if (videoUrl.isEmpty) {
      _logger.warning('Empty video URL');
      return Container(
        width: 320,
        height: 240,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            border: Border.all(
              color: Colors.grey,
              width: 1.0,
            ),
            borderRadius: BorderRadius.zero),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, size: 48, color: Colors.red),
              SizedBox(height: 8),
              Text('Invalid video URL', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Container(
      width: 320, // Fixed width
      height: 240, // Fixed height
      clipBehavior: Clip.antiAlias, // Ensure clean corners
      decoration: BoxDecoration(
          border: Border.all(
            color: Colors.grey,
            width: 1.0, // Explicit border width
          ),
          borderRadius: BorderRadius.zero),
      child: Stack(
        children: [
          Mjpeg(
            key: _streamKey,
            isLive: true,
            stream: videoUrl,
            error: (context, error, stack) {
              _logger.warning('Error loading video: $error');
              _handleError();
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 48, color: Colors.red),
                    const SizedBox(height: 8),
                    Text('Connection error: Retry $_retryCount/$maxRetries'),
                    const SizedBox(height: 8),
                    if (_retryCount < maxRetries)
                      const Text('Attempting to reconnect...'),
                  ],
                ),
              );
            },
            fit: BoxFit.contain,
            // Add a custom preprocessor to detect frames
            preprocessor: FrameDetectionPreprocessor(() {
              _updateFrameTimestamp();
            }),
          ),
          // Show stalled indicator if video is stalled
          if (localIsStalled)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.video_stable, size: 48, color: Colors.orange),
                    SizedBox(height: 8),
                    Text('Video feed stalled',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Text('Attempting to restart...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
