import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';

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
  @override
  Widget build(BuildContext context) {
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
      child: Mjpeg(
        isLive: true,
        stream: widget.videoUrl,
        error: (context, error, stack) {
          return const Center(
            child: Text('Error loading video stream'),
          );
        },
      ),
    );
  }
}
