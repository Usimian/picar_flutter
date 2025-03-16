import 'package:flutter/material.dart';
import '../models/robot_state.dart';
import '../services/llava_service.dart';

class LlavaInterface extends StatefulWidget {
  final LlavaService llavaService;
  final bool isProcessing;
  final bool llavaAvailable;
  final String llavaResponse;
  final Function() onProcessPrompt;
  final TextEditingController promptController;

  const LlavaInterface({
    super.key,
    required this.llavaService,
    required this.isProcessing,
    required this.llavaAvailable,
    required this.llavaResponse,
    required this.onProcessPrompt,
    required this.promptController,
  });

  @override
  State<LlavaInterface> createState() => _LlavaInterfaceState();
}

class _LlavaInterfaceState extends State<LlavaInterface> {
  double _responseHeight = 150.0;

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          _buildPromptInput(),
          _buildResponseArea(),
          _buildStatusIndicator(),
        ],
      ),
    );
  }

  Widget _buildPromptInput() {
    return TextField(
      controller: widget.promptController,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: 'Enter prompt for LLaVA',
        hintText: 'Ask about what you see in the image...',
        suffixIcon: IconButton(
          icon: Icon(widget.isProcessing ? Icons.hourglass_top : Icons.send),
          onPressed: widget.isProcessing ? null : _handlePromptSubmission,
        ),
        helperText: RobotState.lastReceivedImage == null
            ? 'No image available - will use text-only mode'
            : 'Image available - will use image+text mode',
        helperStyle: TextStyle(
          color: RobotState.lastReceivedImage == null
              ? Colors.orange
              : Colors.green,
          fontSize: 12,
        ),
      ),
      enabled: !widget.isProcessing && widget.llavaAvailable,
      onSubmitted: (_) => _handlePromptSubmission(),
    );
  }

  Widget _buildResponseArea() {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 8.0),
          padding: const EdgeInsets.all(12.0),
          width: double.infinity,
          height: _responseHeight,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(8.0),
              topRight: const Radius.circular(8.0),
              bottomLeft: Radius.circular(_responseHeight <= 50 ? 8.0 : 0),
              bottomRight: Radius.circular(_responseHeight <= 50 ? 8.0 : 0),
            ),
            border: Border.all(color: Colors.grey[400]!),
          ),
          child: SingleChildScrollView(
            child: Text(
              widget.llavaResponse,
              style: const TextStyle(fontSize: 14.0),
            ),
          ),
        ),
        if (_responseHeight > 50) _buildResizeHandle(),
      ],
    );
  }

  Widget _buildResizeHandle() {
    return Tooltip(
      message: 'Drag to resize • Double-tap to reset',
      preferBelow: true,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _responseHeight += details.delta.dy;
            if (_responseHeight < 50) _responseHeight = 50;
            if (_responseHeight > 500) _responseHeight = 500;
          });
        },
        onDoubleTap: () {
          setState(() {
            _responseHeight = 150.0;
          });
        },
        child: Container(
          height: 10,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(8.0),
              bottomRight: Radius.circular(8.0),
            ),
            border: Border(
              left: BorderSide(color: Colors.grey[400]!),
              right: BorderSide(color: Colors.grey[400]!),
              bottom: BorderSide(color: Colors.grey[400]!),
            ),
          ),
          child: Center(
            child: Container(
              width: 30,
              height: 3,
              color: Colors.grey[600],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Row(
        children: [
          Icon(
            widget.llavaAvailable ? Icons.check_circle : Icons.error,
            color: widget.llavaAvailable ? Colors.green : Colors.red,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.llavaAvailable
                  ? 'LLaVA service connected (${widget.llavaService.baseUrl})'
                  : 'LLaVA service unavailable (${widget.llavaService.baseUrl})',
              style: TextStyle(
                fontSize: 12,
                color: widget.llavaAvailable ? Colors.green : Colors.red,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.isProcessing)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  void _handlePromptSubmission() {
    final prompt = widget.promptController.text.trim();
    if (prompt.isEmpty) return;

    widget.onProcessPrompt();
  }
} 