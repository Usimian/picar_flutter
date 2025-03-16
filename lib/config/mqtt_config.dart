import 'package:mqtt_client/mqtt_client.dart';

class MqttConfig {
  static const String serverIp = '192.168.1.167';
  static const int port = 1883;
  static const int keepAlivePeriod = 20;
  static const MqttQos defaultQos = MqttQos.exactlyOnce;

  // MQTT Topics
  static const String topicControlRequest = 'picar/control_request';
  static const String topicStatusRequest = 'picar/status_request';
  static const String topicStatusResponse = 'picar/status_response';
} 