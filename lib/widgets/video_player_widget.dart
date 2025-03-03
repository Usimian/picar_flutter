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

  // Add debug flag to control verbose logging
  static const bool _debugVerboseLogging = false;

  bool _isConnected = false;
  Timer? _retryTimer;
  Key _streamKey = GlobalKey();
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
    // Create a persistent key for the Mjpeg widget that won't change on rebuilds
    _streamKey = UniqueKey();

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

    // Debug log to help troubleshoot - log before making any changes
    _logger.info(
        'didChangeDependencies: robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, videoAvailable=$videoAvailable, current _isConnected=$_isConnected');

    // Only update if there's an actual change in connection status
    if (_isConnected != videoAvailable) {
      _logger.info(
          'Connection status changing in didChangeDependencies: $_isConnected -> $videoAvailable');
      _isConnected = videoAvailable;

      // Only request a rebuild, don't force a stream reconnection here
      _requestRebuild();
    }
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
      // Only process if the widget is still mounted
      if (!mounted) return;

      // Check if we need to rebuild due to an explicit request
      if (_needsRebuild) {
        setState(() {
          _needsRebuild = false;
        });
        return; // Exit early after handling the rebuild request
      }

      // Check if RobotState.isVideoAvailable has changed
      // Only consider video available if the robot is running
      final robotRunning =
          Provider.of<RobotState>(context, listen: false).isRunning;
      final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;

      // Only update if there's an actual change in connection status
      if (_isConnected != videoAvailable) {
        _logger.info(
            'Connection status changed in debounce timer: $_isConnected -> $videoAvailable');

        // Don't reset the stream key here - that should only happen in retry logic
        // Just update the connection status
        setState(() {
          _isConnected = videoAvailable;
        });
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
        _logger.info('Retry attempt $_retryCount/$maxRetries');

        // Only request a rebuild, don't force reconnection yet
        _requestRebuild();

        // Only reset the stream key if we're actually trying to reconnect
        // after a disconnection, not during normal operation
        if (_retryCount > 0 || !RobotState.isVideoAvailable) {
          _forceStreamReconnection();
        } else {
          _logger.info(
              'First retry attempt - not forcing stream reconnection yet');
        }

        _retryCount++;
        _isConnected = true; // Assume connected until error occurs
        _isVideoStalled = false; // Reset stall detection on retry
        _lastFrameTimestamp = DateTime.now(); // Reset frame timestamp
      } else if (_retryCount >= maxRetries) {
        // After max retries, slow down retry attempts
        _logger.warning(
            'Max retries ($maxRetries) reached, slowing down retry attempts');
        timer.cancel();
        Timer(const Duration(seconds: 5), () {
          if (mounted) {
            _logger.info('Resetting retry count and restarting retry timer');
            _retryCount = 0;
            _startRetryTimer();
          }
        });
      } else if (_isConnected) {
        // If we're connected, log that we're skipping retry
        _logger.fine('Already connected, skipping retry');
      }
    });
  }

  // Add method to start frame check timer
  void _startFrameCheckTimer() {
    _frameCheckTimer?.cancel();
    _frameCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      // Only process if the widget is still mounted
      if (!mounted) return;

      // Get the current robot running state
      final robotRunning =
          Provider.of<RobotState>(context, listen: false).isRunning;

      // Only check for video stalls if the robot is running
      if (_isConnected && _lastFrameTimestamp != null && robotRunning) {
        final now = DateTime.now();
        final timeSinceLastFrame = now.difference(_lastFrameTimestamp!);

        // Also check video stalled status in RobotState
        final isStalled =
            RobotState.checkVideoStalled(stallThreshold: stallThreshold);

        // Only update state if there's an actual change in stall status
        if ((timeSinceLastFrame > stallThreshold || isStalled) &&
            !_isVideoStalled) {
          _isVideoStalled = true;
          _logger.warning(
              'Video feed stalled: timeSinceLastFrame=${timeSinceLastFrame.inSeconds}s, isStalled=$isStalled');
          _requestRebuild(); // Use the debounce method instead

          // Update robot state to reflect video unavailability
          // Only update if we're the first to detect the issue
          if (RobotState.isVideoAvailable) {
            RobotState.isVideoAvailable = false;
          }

          // Only reset the stream key if we've detected a stall for a significant time
          if (timeSinceLastFrame >
              Duration(milliseconds: stallThreshold.inMilliseconds * 2)) {
            _logger.warning(
                'Stall persisted for ${timeSinceLastFrame.inSeconds}s, forcing stream reconnection');
            _forceStreamReconnection();
          }
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

      // Only request a rebuild if the stalled state is changing
      if (_isVideoStalled) {
        _isVideoStalled = false;

        // Only request a rebuild if the stalled state changed
        _requestRebuild();

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

    // Log the error
    _logger.warning('Video stream error detected');

    // Use the debounce method instead of immediate setState
    _isConnected = false;
    _requestRebuild();

    // Don't force reconnection here - let the retry timer handle it
    // This prevents immediate reconnection attempts that might fail
  }

  // Method to preserve video stream connection
  void preserveVideoStream() {
    // This method intentionally does nothing - it's used to indicate
    // that we want to keep the current video stream connection
    _logger.info('Preserving current video stream connection');
  }

  // Method to force a reconnection of the video stream
  void _forceStreamReconnection() {
    _logger.warning('Forcing stream reconnection with new stream key');
    setState(() {
      _streamKey = UniqueKey(); // Create a new key to force widget recreation
    });
  }

  @override
  Widget build(BuildContext context) {
    // Use local variables to prevent rebuilds due to state changes during build
    final robotRunning =
        Provider.of<RobotState>(context, listen: false).isRunning;
    final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;
    final bool localIsConnected = _isConnected;
    final bool localIsStalled = _isVideoStalled;

    // Debug log to help troubleshoot - only log when verbose logging is enabled
    if (_debugVerboseLogging) {
      _logger.info(
          'build: robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, videoAvailable=$videoAvailable, localIsConnected=$localIsConnected, videoUrl=${widget.videoUrl}');
    }

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
          // Use a RepaintBoundary to prevent unnecessary repaints
          RepaintBoundary(
            child: Mjpeg(
              // Only use the stream key for forcing reconnection, not for normal rebuilds
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
