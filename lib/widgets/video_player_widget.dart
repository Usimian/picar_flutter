import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'dart:async';
import '../models/robot_state.dart';

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
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _frameCheckTimer?.cancel();
    _rebuildDebounceTimer?.cancel();
    super.dispose();
  }

  // Add a debounce timer for rebuilds
  void _startRebuildDebounceTimer() {
    _rebuildDebounceTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_needsRebuild && mounted) {
        setState(() {
          _needsRebuild = false;
        });
      }
    });
  }

  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isConnected && mounted && _retryCount < maxRetries) {
        _needsRebuild = true;
        _streamKey = UniqueKey(); // Force stream reconnection
        _retryCount++;
        _isConnected = true; // Assume connected until error occurs
        _isVideoStalled = false; // Reset stall detection on retry
        _lastFrameTimestamp = DateTime.now(); // Reset frame timestamp
      } else if (_retryCount >= maxRetries) {
        // After max retries, slow down retry attempts
        timer.cancel();
        Timer(const Duration(seconds: 10), () {
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
      if (mounted && _isConnected && _lastFrameTimestamp != null) {
        final now = DateTime.now();
        final timeSinceLastFrame = now.difference(_lastFrameTimestamp!);
        
        // Also check video stalled status in RobotState
        final isStalled = RobotState.checkVideoStalled(stallThreshold: stallThreshold);
        
        if ((timeSinceLastFrame > stallThreshold || isStalled) && !_isVideoStalled) {
          _isVideoStalled = true;
          _needsRebuild = true;
          
          // Update robot state to reflect video unavailability
          RobotState.isVideoAvailable = false;
          
          // Try to restart the video stream - but only do this once per stall detection
          _streamKey = UniqueKey();
        }
      }
    });
  }

  // Add method to update frame timestamp
  void _updateFrameTimestamp() {
    final now = DateTime.now();
    
    // Only update if significant time has passed since last update
    if (_lastFrameTimestamp == null || 
        now.difference(_lastFrameTimestamp!).inMilliseconds > 100) {
      
      _lastFrameTimestamp = now;
      
      // Also update the frame timestamp in RobotState
      RobotState.updateVideoFrameTime();
      
      if (_isVideoStalled) {
        _isVideoStalled = false;
        _needsRebuild = true;
        
        // Update robot state to reflect video availability
        RobotState.isVideoAvailable = true;
      }
    }
  }

  void _handleError() {
    if (!mounted) return;
    
    // Use the debounce flag instead of immediate setState
    _isConnected = false;
    _needsRebuild = true;
  }

  @override
  Widget build(BuildContext context) {
    // Check if video is available according to robot state
    final bool videoAvailable = RobotState.isVideoAvailable;
    
    if (!videoAvailable) {
      return Container(
        width: 320,
        height: 240,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.grey,
            width: 1.0,
          ),
          borderRadius: BorderRadius.zero
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('Camera not available', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    
    return Container(
      width: 320,  // Fixed width
      height: 240, // Fixed height
      clipBehavior: Clip.antiAlias,  // Ensure clean corners
      decoration: BoxDecoration(
        border: Border.all(
          color: Colors.grey,
          width: 1.0,  // Explicit border width
        ),
        borderRadius: BorderRadius.zero
      ),
      child: _isConnected 
        ? Stack(
            children: [
              Mjpeg(
                key: _streamKey,
                isLive: true,
                stream: widget.videoUrl,
                error: (context, error, stack) {
                  _handleError();
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.red),
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
              if (_isVideoStalled)
                Container(
                  color: Colors.black54,
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.video_stable, size: 48, color: Colors.orange),
                        SizedBox(height: 8),
                        Text('Video feed stalled', 
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        SizedBox(height: 8),
                        Text('Attempting to restart...', 
                          style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
            ],
          )
        : Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.orange),
                const SizedBox(height: 8),
                Text('Connection error: Retry $_retryCount/$maxRetries'),
                const SizedBox(height: 8),
                if (_retryCount < maxRetries)
                  const Text('Attempting to reconnect...'),
              ],
            ),
          ),
    );
  }
}
