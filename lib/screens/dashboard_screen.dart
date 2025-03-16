import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import '../models/robot_state.dart';
import '../services/mqtt_service.dart';
import '../services/llava_service.dart';
import '../widgets/status_bar.dart';
import '../widgets/video_resolution_info.dart';
import '../widgets/video_feed.dart';
import '../widgets/joystick_controls.dart';
import '../widgets/llava_interface.dart';
import '../widgets/position_control.dart';
import '../widgets/video_player_widget.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _logger = Logger('DashboardScreen');
  late LlavaService _llavaService;
  bool _videoEnabled = true;
  bool _isProcessing = false;
  bool _llavaAvailable = false;
  String _llavaResponse = 'Responses will appear here';
  final TextEditingController _promptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _llavaService = LlavaService(baseUrl: 'http://192.168.1.162:11434');
    _checkLlavaAvailability();
  }

  Future<void> _checkLlavaAvailability() async {
    try {
      final available = await _llavaService.isAvailable();
      if (mounted) {
        setState(() {
          _llavaAvailable = available;
          if (available) {
            _logger.info('LLaVA service is available');
          } else {
            _logger.warning('LLaVA service is not available');
            _llavaResponse = 'LLaVA service is not available. Check your server.';
          }
        });
      }
    } catch (e) {
      _logger.severe('Error checking LLaVA availability: $e');
      if (mounted) {
        setState(() {
          _llavaAvailable = false;
          _llavaResponse = 'Error connecting to LLaVA: $e';
        });
      }
    }
  }

  Future<void> _processPromptWithImage() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _llavaResponse = 'Please enter a prompt first';
      });
      return;
    }

    if (!_llavaAvailable) {
      setState(() {
        _llavaResponse = 'LLaVA service is not available. Check your server.';
      });
      await _checkLlavaAvailability();
      return;
    }

    setState(() {
      _isProcessing = true;
      _llavaResponse = 'Processing...';
    });

    try {
      String response;
      if (RobotState.lastReceivedImage == null) {
        _logger.info('No image available, using text-only mode');
        response = await _llavaService.processTextOnly(prompt);
      } else {
        _logger.info('Image available, using image+text mode');
        response = await _llavaService.processImageAndText(
          RobotState.lastReceivedImage!,
          prompt,
        );
      }

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _llavaResponse = response;
        });
      }
    } catch (e) {
      _logger.severe('Error processing prompt: $e');
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _llavaResponse = 'Error: $e';
        });
      }
    }
  }

  void _getImage() {
    _logger.info('Capturing current image from video feed');
    if (!_videoEnabled) {
      _logger.info('Video streaming disabled in UI, capturing current frame');
      VideoFeedContainer.captureCurrentFrame();
    }
  }

  void _toggleVideo(bool value) {
    _logger.info('Toggling video display in UI: $value');
    setState(() {
      _videoEnabled = value;
    });
  }

  @override
  void dispose() {
    _llavaService.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mqttService = Provider.of<MqttService>(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('PiCar Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: const [
          StatusBar(),
        ],
      ),
      body: Column(
        children: [
          const VideoResolutionInfo(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: PositionControl(mqttClient: mqttService.client),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: JoystickControls(
                      mqttService: mqttService,
                      isDriveJoystick: true,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: VideoFeed(
                      videoEnabled: _videoEnabled,
                      onGetImage: _getImage,
                      onToggleVideo: _toggleVideo,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: JoystickControls(
                      mqttService: mqttService,
                      isDriveJoystick: false,
                    ),
                  ),
                ),
              ],
            ),
          ),
          LlavaInterface(
            llavaService: _llavaService,
            isProcessing: _isProcessing,
            llavaAvailable: _llavaAvailable,
            llavaResponse: _llavaResponse,
            onProcessPrompt: _processPromptWithImage,
            promptController: _promptController,
          ),
        ],
      ),
    );
  }
} 