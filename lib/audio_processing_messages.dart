// lib/audio_processing_messages.dart
import 'dart:isolate';

class AudioTask {
  final List<double> audioData;
  final int inputRate;
  final int targetRate;
  final List<List<double>>? melFilterbankData;
  final String selectedModelTitle;
  final SendPort replyPort;

  AudioTask({
    required this.audioData,
    required this.inputRate,
    required this.targetRate,
    required this.melFilterbankData,
    required this.selectedModelTitle,
    required this.replyPort,
  });
}

class AudioResult {
  final String? classification;
  final String? error;

  AudioResult({this.classification, this.error});
}