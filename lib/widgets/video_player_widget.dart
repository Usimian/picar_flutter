import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'dart:async';
import 'dart:typed_data';
import '../models/robot_state.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import '../utils/app_colors.dart';
import 'package:image/image.dart' as img;

// Custom preprocessor to detect frame updates
class FrameDetectionPreprocessor extends MjpegPreprocessor {
  final Function onFrameReceived;
  final Function(int width, int height)? onResolutionDetected;
  bool _hasDetectedResolution = false;
  final _logger = Logger('FrameDetectionPreprocessor');

  FrameDetectionPreprocessor(this.onFrameReceived, {this.onResolutionDetected});

  @override
  List<int>? process(List<int> frame) {
    // Call the callback when a frame is received
    onFrameReceived();

    // Extract resolution from the frame if we haven't already
    if (!_hasDetectedResolution && onResolutionDetected != null) {
      try {
        // Decode the JPEG image to extract its dimensions
        final decodedImage = img.decodeJpg(Uint8List.fromList(frame));
        if (decodedImage != null) {
          final width = decodedImage.width;
          final height = decodedImage.height;

          _logger.info('Detected video resolution: ${width}x$height');

          // Call the resolution callback with the detected dimensions
          onResolutionDetected!(width, height);

          // Mark that we've detected the resolution to avoid unnecessary processing
          _hasDetectedResolution = true;
        }
      } catch (e) {
        _logger.warning('Error extracting resolution from frame: $e');
      }
    }

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

  // Track the last time we forced a reconnection to prevent excessive reconnections
  static DateTime? _lastReconnectionTime;

  // Video dimensions - default to 4:3 aspect ratio (320x240)
  double _videoWidth = 320;
  double _videoHeight = 240;
  bool _hasReceivedFirstFrame = false;

  // Add a flag to track if we've detected the actual resolution
  bool _hasDetectedActualResolution = false;

  @override
  void initState() {
    super.initState();
    // Create a persistent key for the Mjpeg widget that won't change on rebuilds
    _streamKey = GlobalKey();
    _logger.info('Initialized video player with persistent stream key');

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

    // Only check for changes if we haven't already requested a rebuild
    if (_needsRebuild) {
      _logger.fine(
          'didChangeDependencies: Skipping because _needsRebuild is true');
      return;
    }

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
      _logger.warning(
          'Connection status changing in didChangeDependencies: $_isConnected -> $videoAvailable');

      // Update the connection status but don't trigger an immediate rebuild
      // Let the debounce timer handle the rebuild
      _isConnected = videoAvailable;
      _needsRebuild = true;
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
        Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      // Only process if the widget is still mounted
      if (!mounted) return;

      // Check if we need to rebuild due to an explicit request
      if (_needsRebuild) {
        _logger.info('Rebuilding due to explicit _needsRebuild flag');
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
        _logger.warning(
            'Connection status changed in debounce timer: $_isConnected -> $videoAvailable, robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}');

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
      // Only process if the widget is still mounted
      if (!mounted) return;

      // Check if we've received frames recently - if so, we're actually connected
      final bool receivingFrames = _lastFrameTimestamp != null &&
          DateTime.now().difference(_lastFrameTimestamp!).inSeconds < 3;

      // Only attempt reconnection if:
      // 1. We're not connected according to our state
      // 2. We haven't reached max retries
      // 3. We're not receiving frames (which would indicate we're actually connected)
      if (!_isConnected && _retryCount < maxRetries && !receivingFrames) {
        _logger.warning(
            'Retry attempt $_retryCount/$maxRetries - isConnected=$_isConnected, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, receivingFrames=$receivingFrames');

        // Only request a rebuild, don't force reconnection yet
        _requestRebuild();

        // Only reset the stream key if we're actually trying to reconnect
        // after a disconnection, not during normal operation
        if (_retryCount > 0 || !RobotState.isVideoAvailable) {
          _logger.warning(
              'Forcing stream reconnection during retry attempt $_retryCount');
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
      } else if (receivingFrames) {
        // If we're receiving frames, we're actually connected
        _logger.info('Receiving frames, updating _isConnected to true');
        _isConnected = true;
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

      // Only check for video stalls if the robot is running and we think we're connected
      if (_isConnected && _lastFrameTimestamp != null && robotRunning) {
        final now = DateTime.now();
        final timeSinceLastFrame = now.difference(_lastFrameTimestamp!);

        // Also check video stalled status in RobotState
        final isStalled =
            RobotState.checkVideoStalled(stallThreshold: stallThreshold);

        // Log frame check status periodically
        _logger.fine(
            'Frame check: timeSinceLastFrame=${timeSinceLastFrame.inMilliseconds}ms, isStalled=$isStalled, _isVideoStalled=$_isVideoStalled');

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
            _logger.warning(
                'Setting RobotState.isVideoAvailable to false due to stall');
            RobotState.isVideoAvailable = false;
          }

          // Only reset the stream key if we've detected a stall for a significant time
          // AND we haven't forced a reconnection recently
          if (timeSinceLastFrame >
                  Duration(milliseconds: stallThreshold.inMilliseconds * 2) &&
              (_lastReconnectionTime == null ||
                  now.difference(_lastReconnectionTime!).inSeconds > 10)) {
            _logger.warning(
                'Stall persisted for ${timeSinceLastFrame.inSeconds}s, forcing stream reconnection');
            _forceStreamReconnection();
          } else {
            _logger.info(
                'Not forcing reconnection yet - waiting for stall to persist or for cooldown period');
          }
        }
      } else if (!robotRunning && _isConnected) {
        // If the robot is not running but we think we're connected, update our state
        _logger
            .info('Robot not running but _isConnected=true, updating to false');
        _isConnected = false;
        _requestRebuild();
      }
    });
  }

  // Method to update frame timestamp and detect video dimensions
  void _updateFrameTimestamp() {
    final now = DateTime.now();
    _lastFrameTimestamp = now;

    // Update the global timestamp in RobotState
    RobotState.updateVideoFrameTime();

    // Reset stalled state if it was stalled
    if (_isVideoStalled) {
      setState(() {
        _isVideoStalled = false;
      });
    }

    // Mark that we've received at least one frame
    if (!_hasReceivedFirstFrame) {
      _hasReceivedFirstFrame = true;
      _logger.info('Received first video frame');
    }
  }

  // Method to handle resolution detection
  void _handleResolutionDetected(int width, int height) {
    _logger.info('Resolution detected: ${width}x$height');

    // Only update if the resolution is valid and different from current
    if (width > 0 &&
        height > 0 &&
        (_videoWidth != width.toDouble() ||
            _videoHeight != height.toDouble())) {
      setState(() {
        _videoWidth = width.toDouble();
        _videoHeight = height.toDouble();
        _hasDetectedActualResolution = true;
      });

      // Update RobotState with the detected resolution
      RobotState.updateVideoResolution(width, height);
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
    _logger.warning(
        'Forcing stream reconnection with new stream key - CALLED FROM: ${StackTrace.current}');

    final now = DateTime.now();

    // Only allow reconnection if it's been at least 5 seconds since the last one
    if (_lastReconnectionTime != null &&
        now.difference(_lastReconnectionTime!).inSeconds < 5) {
      _logger
          .warning('Skipping reconnection - too soon since last reconnection');
      return;
    }

    // Check if we've received frames recently - if so, don't reconnect
    if (_lastFrameTimestamp != null &&
        now.difference(_lastFrameTimestamp!).inSeconds < 2) {
      _logger
          .warning('Skipping reconnection - frames are still being received');
      return;
    }

    // Only force reconnection if we're not already in the process of reconnecting
    if (mounted) {
      setState(() {
        // Create a new key to force widget recreation
        final oldKey = _streamKey;
        _streamKey = UniqueKey();
        _lastReconnectionTime = now;
        _logger.warning(
            'Stream key reset to force reconnection: $oldKey -> $_streamKey');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use local variables to prevent rebuilds due to state changes during build
    final robotRunning =
        Provider.of<RobotState>(context, listen: false).isRunning;
    final bool videoAvailable = robotRunning && RobotState.isVideoAvailable;
    final bool localIsConnected = _isConnected;
    final bool localIsStalled = _isVideoStalled;
    final Key currentStreamKey = _streamKey;

    // Use resolution from RobotState if available, otherwise use local values
    final double displayWidth = RobotState.hasDetectedResolution
        ? RobotState.videoWidth.toDouble()
        : _videoWidth;
    final double displayHeight = RobotState.hasDetectedResolution
        ? RobotState.videoHeight.toDouble()
        : _videoHeight;

    // Debug log to help troubleshoot - only log when verbose logging is enabled
    _logger.warning(
        'VideoPlayerWidget.build called - STACK TRACE: ${StackTrace.current}');
    _logger.fine(
        'build: robotRunning=$robotRunning, RobotState.isVideoAvailable=${RobotState.isVideoAvailable}, videoAvailable=$videoAvailable, localIsConnected=$localIsConnected, videoUrl=${widget.videoUrl}');
    _logger.fine('build: using stream key: $currentStreamKey');
    _logger.fine(
        'build: using resolution: ${displayWidth}x$displayHeight, hasDetectedResolution=${RobotState.hasDetectedResolution}');

    // Always attempt to show the video feed if the robot is running
    // This is a more permissive approach that will try to connect even if isVideoAvailable is false
    if (!robotRunning) {
      return _buildPlaceholderContainer(
        icon: Icons.videocam_off,
        message: 'Robot not running',
      );
    }

    // Ensure the video URL is valid
    final String videoUrl = widget.videoUrl.trim();
    if (videoUrl.isEmpty) {
      _logger.warning('Empty video URL');
      return _buildPlaceholderContainer(
        icon: Icons.error,
        message: 'Invalid video URL',
        iconColor: AppColors.statusRed,
      );
    }

    // Create a widget that will adapt to the video stream size
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          clipBehavior: Clip.antiAlias, // Ensure clean corners
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.borderColor,
              width: 1.0, // Explicit border width
            ),
            borderRadius: BorderRadius.zero,
          ),
          // Use FittedBox to scale the video to fit the available space
          // while maintaining aspect ratio
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: displayWidth,
              height: displayHeight,
              child: Stack(
                children: [
                  // Use a RepaintBoundary to prevent unnecessary repaints
                  RepaintBoundary(
                    // Use ValueKey instead of UniqueKey to maintain the same key across rebuilds
                    // Only change the key when _streamKey changes (forced reconnection)
                    child: Mjpeg(
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
                              Icon(Icons.error_outline,
                                  size: 48, color: AppColors.statusRed),
                              const SizedBox(height: 8),
                              Text(
                                  'Connection error: Retry $_retryCount/$maxRetries'),
                              const SizedBox(height: 8),
                              if (_retryCount < maxRetries)
                                const Text('Attempting to reconnect...'),
                            ],
                          ),
                        );
                      },
                      fit: BoxFit.contain,
                      // Add a custom preprocessor to detect frames and resolution
                      preprocessor: FrameDetectionPreprocessor(
                        () {
                          _updateFrameTimestamp();
                        },
                        onResolutionDetected: _hasDetectedActualResolution
                            ? null // Skip resolution detection if we already have it
                            : _handleResolutionDetected,
                      ),
                    ),
                  ),
                  // Show stalled indicator if video is stalled
                  if (localIsStalled)
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.video_stable,
                                size: 48, color: Colors.orange),
                            const SizedBox(height: 8),
                            const Text('Video feed stalled',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            const Text('Attempting to restart...',
                                style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Helper method to build placeholder containers
  Widget _buildPlaceholderContainer({
    required IconData icon,
    required String message,
    Color iconColor = AppColors.disabledText,
  }) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(
          color: AppColors.borderColor,
          width: 1.0,
        ),
        borderRadius: BorderRadius.zero,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: iconColor),
            const SizedBox(height: 8),
            Text(message, style: TextStyle(color: AppColors.disabledText)),
          ],
        ),
      ),
    );
  }

  // Override the updateShouldNotify method to prevent unnecessary rebuilds
  @override
  void didUpdateWidget(VideoPlayerWidget oldWidget) {
    // Only call super.didUpdateWidget if the video URL has actually changed
    if (oldWidget.videoUrl != widget.videoUrl) {
      _logger.warning(
          'Video URL changed: ${oldWidget.videoUrl} -> ${widget.videoUrl}');
      super.didUpdateWidget(oldWidget);
    } else {
      _logger.fine('Skipping didUpdateWidget - video URL unchanged');
    }
  }
}

class VideoFeedContainer extends StatefulWidget {
  const VideoFeedContainer({super.key});

  @override
  State<VideoFeedContainer> createState() => _VideoFeedContainerState();
}

class _VideoFeedContainerState extends State<VideoFeedContainer> {
  // Use a GlobalKey to preserve the VideoPlayerWidget instance across rebuilds
  final GlobalKey<_VideoPlayerWidgetState> _videoPlayerKey =
      GlobalKey<_VideoPlayerWidgetState>();

  // Create the VideoPlayerWidget once and reuse it
  late final VideoPlayerWidget _videoPlayer;

  @override
  void initState() {
    super.initState();
    // Create the VideoPlayerWidget once in initState
    _videoPlayer = VideoPlayerWidget(
      key: _videoPlayerKey,
      videoUrl: RobotState.videoUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Simply return the pre-created VideoPlayerWidget
    // This won't create a new instance on rebuilds
    return _videoPlayer;
  }
}
