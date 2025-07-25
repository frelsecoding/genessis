import 'dart:async';
import 'dart:ffi';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:record/record.dart';
import 'package:thesis_app/native_audio_processor.dart';
import 'package:thesis_app/native_resampler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

enum AppScreenState {
  listening,
  analyzing,
  showingResults,
}

class ModelOption {
  final String title;
  final String description;
  const ModelOption({required this.title, required this.description});
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is ModelOption &&
              runtimeType == other.runtimeType &&
              title == other.title;
  @override
  int get hashCode => title.hashCode;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GenessisApp());
}

class GenessisApp extends StatelessWidget {
  const GenessisApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF2D2D2D),
        scaffoldBackgroundColor: const Color(0xFF121212),
        hintColor: Colors.white70,
        colorScheme:
        ThemeData.dark().colorScheme.copyWith(secondary: Colors.white70),
        textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'InstrumentSans',
            bodyColor: Colors.white,
            displayColor: Colors.white),
        buttonTheme: ButtonThemeData(
            textTheme: ButtonTextTheme.primary,
            buttonColor: Colors.grey[800]),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selectedModelTitle = 'RCRNN-M';
  String _currentGreeting = "";
  bool _isMicrophoneRecording = false;

  AppScreenState _currentScreenState = AppScreenState.listening;
  String _smoothedPrimaryGenreResult = "";
  List<String> _smoothedOtherGenreSuggestions = [];

  final int _predictionHistoryLength = 3;
  List<Map<String, dynamic>> _recentApiResponses = [];

  bool _isMelFilterbankReady = false;
  String _ffiInitializationError = "";
  final NativeAudioProcessor _audioProcessor = NativeAudioProcessor();
  final NativeResampler _nativeResampler = NativeResampler();

  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<List<int>>? _audioStreamSubscription;
  final int _captureSampleRate = 44100;
  List<double> _continuousAudioBuffer = [];
  final int _targetSampleRate = 22050;
  final int _processingSegmentDurationSeconds = 3;
  final int _maxBufferDurationSeconds = 7;

  late final int _segmentLengthSamplesForBuffer;
  late final int _maxBufferCapacitySamplesForBuffer;

  bool _isProcessingAudio = false;
  Timer? _processingScheduler;

  final int _nFftForFeatures = 2048;
  final int _nMelsForFeatures = 128;
  final int _hopLengthForFeatures = 512;

  final List<ModelOption> _modelOptions = const [
    ModelOption(title: 'RCRNN-M', description: 'Accurate for mainstream genres'),
    ModelOption(title: 'RCRNN-B', description: 'Accurate for Ballroom genres'),
  ];

  final List<String> _initialGreetings = const [
    "What's playing?", "Let's identify this tune!", "Ready for a genre?",
    "Tap G to discover!", "Listening for music...", "Make some noise!",
  ];

  @override
  void initState() {
    super.initState();
    _segmentLengthSamplesForBuffer = _captureSampleRate * _processingSegmentDurationSeconds;
    _maxBufferCapacitySamplesForBuffer = _captureSampleRate * _maxBufferDurationSeconds;
    _initializeGreeting();
    _loadMelFilterbank();
    _requestMicrophonePermissionOnInit();
    _processingScheduler = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      if (_currentScreenState != AppScreenState.showingResults &&
          _isMicrophoneRecording &&
          !_isProcessingAudio &&
          mounted) {
        _tryProcessingAudio();
      }
    });
  }

  void _initializeGreeting() {
    if (!mounted) return;
    setState(() {
      if (_initialGreetings.isNotEmpty) {
        final random = Random();
        _currentGreeting = _initialGreetings[random.nextInt(_initialGreetings.length)];
      } else {
        _currentGreeting = "Hello there!";
      }
    });
  }

  void _updateListeningUIMessage(String newGreeting) {
    if (mounted && (_currentScreenState == AppScreenState.listening || _currentScreenState == AppScreenState.analyzing)) {
      setState(() {
        _currentGreeting = newGreeting;
      });
    }
  }

  Future<void> _loadMelFilterbank() async {
    try {
      await _audioProcessor.fetchAndStoreMelFilterbank(
        nFft: _nFftForFeatures, nMels: _nMelsForFeatures,
        sampleRate: _targetSampleRate.toDouble(), fMin: 0.0,
      );
      if (mounted) {
        setState(() => _isMelFilterbankReady = (_audioProcessor.nativeFilterbankPointer != null && _audioProcessor.filterbankRows > 0));
        if (!_isMelFilterbankReady) _ffiInitializationError = 'Failed to get Mel filterbank from native code.';
      }
    } catch (e) {
      if (kDebugMode) print("HomeScreen Error: Loading Mel filterbank: $e");
      if (mounted) setState(() { _ffiInitializationError = 'Failed to initialize audio system.'; _isMelFilterbankReady = false; });
    }
  }

  Future<void> _requestMicrophonePermissionOnInit() async {
    final status = await ph.Permission.microphone.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      _updateListeningUIMessage("Mic Permission Needed");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mic permission required. Enable in settings.'),
            action: status.isPermanentlyDenied ? SnackBarAction(label: "Settings", onPressed: ph.openAppSettings) : null,
          ),
        );
      }
    }
  }

  Future<void> _handleGButtonTap() async {
    if (_currentScreenState == AppScreenState.showingResults) {
      _switchToListeningUI();
      return;
    }
    if (_isMicrophoneRecording) {
      await _stopListeningAndClearHistory();
    } else {
      if (!_isMelFilterbankReady || _audioProcessor.nativeFilterbankPointer == null) {
        _updateListeningUIMessage("System Not Ready");
        String errorMsg = _ffiInitializationError.isNotEmpty ? _ffiInitializationError : "Audio system not ready.";
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg)));
        return;
      }
      final hasPermission = await _audioRecorder.hasPermission();
      if (hasPermission) {
        await _startListening();
      } else {
        _updateListeningUIMessage("Permission Denied");
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mic permission required via settings.')));
      }
    }
  }

  Future<void> _startListening() async {
    if (_isMicrophoneRecording || !mounted) return;
    _continuousAudioBuffer.clear();
    _recentApiResponses.clear();
    try {
      setState(() { _isMicrophoneRecording = true; _currentScreenState = AppScreenState.listening; });
      _updateListeningUIMessage("Listening...");
      final config = RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _captureSampleRate, numChannels: 1);
      final stream = await _audioRecorder.startStream(config);
      _audioStreamSubscription = stream.listen((dataChunkBytes) {
        if (!mounted || !_isMicrophoneRecording) return;
        _continuousAudioBuffer.addAll(_convertBytesToFloat(dataChunkBytes));
        if (_continuousAudioBuffer.length > _maxBufferCapacitySamplesForBuffer) {
          _continuousAudioBuffer = _continuousAudioBuffer.sublist(_continuousAudioBuffer.length - _maxBufferCapacitySamplesForBuffer);
        }
      }, onError: (error) {
        if (kDebugMode) print("HomeScreen: Audio stream error: $error");
        if (mounted) { _updateListeningUIMessage("Mic Error!"); _stopListeningAndClearHistory(); }
      }, onDone: () {
        if (mounted && _isMicrophoneRecording) _stopListeningAndClearHistory();
      });
    } catch (e) {
      if (kDebugMode) print("HomeScreen: Error starting mic: $e");
      if (mounted) {
        setState(() => _isMicrophoneRecording = false);
        _updateListeningUIMessage("Mic Start Error!");
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start mic: ${e.toString().substring(0, min(e.toString().length, 50))}')));
      }
    }
  }

  List<double> _convertBytesToFloat(List<int> bytes) {
    List<double> floatSamples = List.filled(bytes.length ~/ 2, 0.0, growable: false);
    int floatIndex = 0;
    for (int i = 0; i < bytes.length; i += 2) {
      if (i + 1 < bytes.length) {
        int sampleInt = (bytes[i + 1] << 8) | bytes[i];
        if (sampleInt > 32767) sampleInt -= 65536;
        floatSamples[floatIndex++] = sampleInt / 32768.0;
      }
    }
    return floatSamples;
  }

  Future<void> _internalStopMicStreamOnly() async {
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
    _continuousAudioBuffer.clear();
  }

  Future<void> _stopListeningAndClearHistory() async {
    await _internalStopMicStreamOnly();
    _isProcessingAudio = false;
    if (mounted) {
      setState(() {
        _isMicrophoneRecording = false;
        _recentApiResponses.clear();
        _currentScreenState = AppScreenState.listening;
      });
      _initializeGreeting();
    }
  }

  void _switchToListeningUI({bool clearHistory = true}) {
    if (mounted) {
      if (_isMicrophoneRecording) _internalStopMicStreamOnly();
      setState(() {
        if (clearHistory) _recentApiResponses.clear();
        _isMicrophoneRecording = false; _isProcessingAudio = false;
        _currentScreenState = AppScreenState.listening;
      });
      _initializeGreeting();
    }
  }

  void _addPredictionToHistory(Map<String, dynamic> newPredictionData) {
    if (!mounted) return;
    Map<String, dynamic>? primaryMap = newPredictionData['primary_prediction_map'] as Map<String, dynamic>?;
    List<dynamic>? topListRaw = newPredictionData['top_predictions_list'] as List<dynamic>?;
    if (primaryMap == null || topListRaw == null) return;
    List<Map<String, dynamic>> topList = List<Map<String, dynamic>>.from(topListRaw.map((e) => e as Map<String, dynamic>));
    setState(() {
      _recentApiResponses.add({"primary_prediction": primaryMap, "top_predictions": topList});
      if (_recentApiResponses.length > _predictionHistoryLength) _recentApiResponses.removeAt(0);
    });
  }

  void _performSmoothingAndDisplay() {
    if (!mounted) return;
    if (_recentApiResponses.isEmpty) {
      if (_currentScreenState == AppScreenState.showingResults) _switchToListeningUI(clearHistory: false);
      return;
    }

    Map<String, int> genreCounts = {};
    for (var responseMap in _recentApiResponses) {
      Map<String, dynamic>? primary = responseMap["primary_prediction"] as Map<String, dynamic>?;
      if (primary != null && primary["label"] != null) {
        String label = primary["label"] as String;
        genreCounts[label] = (genreCounts[label] ?? 0) + 1;
      }
    }
    String smoothedPrimary = "N/A"; int maxCount = 0;
    if (genreCounts.isNotEmpty) genreCounts.forEach((genre, count) { if (count > maxCount) { maxCount = count; smoothedPrimary = genre; }});

    List<String> smoothedSuggestions = [];
    if (smoothedPrimary != "N/A") {
      Map<String, dynamic>? repResponse = _recentApiResponses.lastWhere(
              (r) => (r["primary_prediction"] as Map<String,dynamic>?)?["label"] == smoothedPrimary, orElse: () => _recentApiResponses.last);
      final List<dynamic>? topPreds = repResponse["top_predictions"] as List<dynamic>?;
      if (topPreds != null) {
        int suggestionsCount = 0;
        for (var predEntry in topPreds) {
          final Map<String, dynamic> predMap = predEntry as Map<String, dynamic>;
          if (predMap["genre"] != null && predMap["genre"] != smoothedPrimary) {
            smoothedSuggestions.add(predMap["genre"] as String);
            if (++suggestionsCount >= 2) break;
          }
        }
      }
    }

    bool isConfident = (_recentApiResponses.length >= _predictionHistoryLength && maxCount >= ((_predictionHistoryLength / 2.0).ceil()) && smoothedPrimary != "N/A");

    if (isConfident) {
      setState(() {
        _smoothedPrimaryGenreResult = smoothedPrimary; _smoothedOtherGenreSuggestions = smoothedSuggestions;
        _currentScreenState = AppScreenState.showingResults;
        if (_isMicrophoneRecording) _isMicrophoneRecording = false;
        _isProcessingAudio = false; // Done processing for this successful result
      });
      _internalStopMicStreamOnly();
      // TODO: Call _storeClassificationInHistory(smoothedPrimary);
    } else if (_recentApiResponses.length >= _predictionHistoryLength) {
      _updateListeningUIMessage("More context needed...");
      if (_currentScreenState != AppScreenState.analyzing) setState(() => _currentScreenState = AppScreenState.analyzing);
      // _isProcessingAudio will be set to false by the .then() of compute call, allowing next cycle
    } else {
      _updateListeningUIMessage("Analyzing (${_recentApiResponses.length}/$_predictionHistoryLength)...");
      if (_currentScreenState != AppScreenState.analyzing) setState(() => _currentScreenState = AppScreenState.analyzing);
      // _isProcessingAudio will be set to false by the .then() of compute call, allowing next cycle
    }
  }

  Future<void> _tryProcessingAudio() async {
    if (!_isMelFilterbankReady || _audioProcessor.nativeFilterbankPointer == null ||
        _continuousAudioBuffer.length < _segmentLengthSamplesForBuffer || _isProcessingAudio ||
        !_isMicrophoneRecording || _currentScreenState == AppScreenState.showingResults || !mounted) {
      return;
    }
    setState(() { _isProcessingAudio = true;
    if (_currentScreenState == AppScreenState.listening) { // Only set to analyzing if coming from plain listening
      _currentScreenState = AppScreenState.analyzing;
      _currentGreeting = "Analyzing..."; // Initial analyzing message
    }
    });

    final int startIndex = (_continuousAudioBuffer.length - _segmentLengthSamplesForBuffer).clamp(0, _continuousAudioBuffer.length);
    List<double> segmentToProcess = List.from(_continuousAudioBuffer.sublist(startIndex));
    final isolateMessage = { /* ... as before ... */
      'audioData': segmentToProcess, 'inputRate': _captureSampleRate, 'targetRate': _targetSampleRate,
      'selectedModelTitle': _selectedModelTitle ?? _modelOptions.first.title,
      'nativeFilterbankPtrAddress': _audioProcessor.nativeFilterbankPointer!.address,
      'filterbankRows': _audioProcessor.filterbankRows, 'filterbankCols': _audioProcessor.filterbankCols,
      'nFftForFeatures': _nFftForFeatures, 'hopLengthForFeatures': _hopLengthForFeatures,
    };

    compute(_processAudioIsolateEntrypoint, isolateMessage)
        .then((Map<String, dynamic>? resultDataFromIsolate) {
      if (!mounted) { _isProcessingAudio = false; return; }
      if (resultDataFromIsolate != null) {
        String statusMsg = resultDataFromIsolate['status_message'] ?? "Error";
        if (statusMsg.startsWith("Success")) {
          _addPredictionToHistory(resultDataFromIsolate);
          _performSmoothingAndDisplay();
        } else {
          _updateListeningUIMessage(resultDataFromIsolate['display_greeting_override'] ?? "Processing Error.");
          setState(() { _recentApiResponses.clear(); if(_currentScreenState != AppScreenState.showingResults) _currentScreenState = AppScreenState.listening; });
        }
      } else {
        _updateListeningUIMessage("Processing Error (Null Data)");
        setState(() { _recentApiResponses.clear(); if(_currentScreenState != AppScreenState.showingResults) _currentScreenState = AppScreenState.listening; });
      }
      if (mounted && _currentScreenState != AppScreenState.showingResults) { // If not showing results, allow next processing cycle
        setState(() => _isProcessingAudio = false);
      } else if (mounted && _currentScreenState == AppScreenState.showingResults) { // If showing results, processing is done
        setState(() => _isProcessingAudio = false);
      }
    }).catchError((e) {
      if (kDebugMode) print("HomeScreen: Error from compute: $e");
      if (mounted) {
        _updateListeningUIMessage("System Error");
        setState(() { _recentApiResponses.clear(); if(_currentScreenState != AppScreenState.showingResults) _currentScreenState = AppScreenState.listening; _isProcessingAudio = false; });
      }
    });
  }

  static Future<Map<String, dynamic>?> _processAudioIsolateEntrypoint(
      Map<String, dynamic> message) async {
    final List<double> audioDataFromMain = message['audioData'];
    final int inputSampleRate = message['inputRate'];
    final int targetSampleRate = message['targetRate'];
    final String selectedModelTitle = message['selectedModelTitle'];
    final int nativeFilterbankPtrAddress = message['nativeFilterbankPtrAddress'];
    final int filterbankNumMels = message['filterbankRows'];
    final int filterbankNumFftBins = message['filterbankCols'];
    final int nFftForFeatures = message['nFftForFeatures'];
    final int hopLengthForFeatures = message['hopLengthForFeatures'];

    final NativeResampler resampler = NativeResampler();
    final NativeFeatureExtractor featureExtractor = NativeFeatureExtractor();

    String processingStatus = "Error: Processing incomplete";
    String? displayStringForResultOnError = "Could not classify audio.";
    String? primaryGenreForStorage;
    Map<String, dynamic>? primaryPredictionMapForResult;
    List<dynamic>? topPredictionsListForResult;

    try {
      List<double>? audioForFeatures;
      if (inputSampleRate == targetSampleRate) {
        audioForFeatures = List<double>.from(audioDataFromMain);
      } else {
        audioForFeatures = resampler.resample(audioDataFromMain, inputSampleRate, targetSampleRate);
      }

      if (audioForFeatures == null || audioForFeatures.isEmpty) {
        processingStatus = "Error: Audio preparation failed";
      } else {
        if (nativeFilterbankPtrAddress == 0) {
          processingStatus = "Error: Filterbank native pointer missing";
        } else {
          final ExtractedFeatures? featuresResult = featureExtractor.extractFeatures(
            audioData: audioForFeatures, sampleRate: targetSampleRate,
            nFft: nFftForFeatures, hopLength: hopLengthForFeatures,
            melFilterbankPointer: Pointer.fromAddress(nativeFilterbankPtrAddress),
            nMelsFromFilterbank: filterbankNumMels, numFreqBinsInFftOutput: filterbankNumFftBins,
          );

          if (featuresResult != null && featuresResult.data.isNotEmpty) {
            final featuresForClassifier = featuresResult.data;
            final String apiUrl = 'placeholder'; // <<< !!! REPLACE THIS !!!

            final Map<String, dynamic> apiPayload = {
              "model_title": selectedModelTitle, "features": featuresForClassifier
            };
            try {
              final response = await http.post(
                Uri.parse(apiUrl), headers: {'Content-Type': 'application/json'},
                body: jsonEncode(apiPayload),
              ).timeout(const Duration(seconds: 25));

              if (response.statusCode == 200) {
                final Map<String, dynamic> responseData = jsonDecode(response.body);
                primaryPredictionMapForResult = responseData['primary_prediction'] as Map<String, dynamic>?;
                topPredictionsListForResult = responseData['top_predictions'] as List<dynamic>?;

                if (primaryPredictionMapForResult != null && primaryPredictionMapForResult['label'] != null) {
                  primaryGenreForStorage = primaryPredictionMapForResult['label'] as String?;
                  processingStatus = "Success: Classification received";
                } else {
                  processingStatus = "Error: API response format unexpected";
                  displayStringForResultOnError = "Classification data error.";
                }
              } else {
                processingStatus = "Error: API Call Failed (${response.statusCode})";
                displayStringForResultOnError = "Server error (${response.statusCode}).";
              }
            } on TimeoutException catch (_) {
              processingStatus = "Error: API Timeout"; displayStringForResultOnError = "Server timeout.";
            } catch (e) {
              processingStatus = "Error: API Exception"; displayStringForResultOnError = "Network error.";
            }
          } else {
            processingStatus = "Error: Feature extraction failed"; displayStringForResultOnError = "Could not process features.";
          }
        }
      }
    } catch (e) {
      processingStatus = "Error: Isolate Processing Exception"; displayStringForResultOnError = "Critical system error.";
    } finally {
      featureExtractor.dispose();
      resampler.dispose();
    }
    return {
      "status_message": processingStatus,
      "display_greeting_override": displayStringForResultOnError,
      "primary_prediction_map": primaryPredictionMapForResult,
      "top_predictions_list": topPredictionsListForResult,
      "primary_genre_for_storage": primaryGenreForStorage,
    };
  }

  @override
  void dispose() {
    _processingScheduler?.cancel();
    _stopListeningAndClearHistory();
    _audioRecorder.dispose();
    _audioProcessor.dispose();
    _nativeResampler.dispose();
    super.dispose();
  }

  Widget _buildListeningUI(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    Color gButtonInnerColor = _isMicrophoneRecording ? Colors.redAccent.withOpacity(0.7) : const Color(0xFF4A5550);
    String gButtonTextCurrent = "G";
    if (_currentScreenState == AppScreenState.analyzing || _isProcessingAudio || (_isMicrophoneRecording && _currentScreenState != AppScreenState.listening) ) {
      gButtonTextCurrent = "...";
    } else if (_isMicrophoneRecording && _currentScreenState == AppScreenState.listening) {
      gButtonTextCurrent = "..."; // Show ... if mic is on and just listening
    }

    bool isDropdownDisabled = _isMicrophoneRecording || _isProcessingAudio || _currentScreenState == AppScreenState.analyzing;

    Color dropdownContainerColor = const Color(0xFF353936);
    Color dropdownIconColor = const Color(0xFFD9D9D9);
    const TextStyle collapsedButtonTextStyle = TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'InstrumentSans', fontWeight: FontWeight.w600, letterSpacing: 2);
    double dropdownButtonWidth = 149.0;
    double dropdownButtonHeight = 29.0;
    const TextStyle menuItemTitleStyle = TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold, fontFamily: 'InstrumentSans');
    const TextStyle menuItemDescriptionStyle = TextStyle(color: Colors.black87, fontSize: 13, fontFamily: 'InstrumentSans', height: 1.3);
    const double greetingAreaHeight = 96.0;

    Widget dropdownWidget;
    if (isDropdownDisabled) {
      dropdownWidget = AbsorbPointer(
        absorbing: true,
        child: _buildCollapsedButton(
          selectedTitle: _selectedModelTitle, backgroundColor: dropdownContainerColor,
          iconColor: dropdownIconColor, textStyle: collapsedButtonTextStyle,
          width: dropdownButtonWidth, height: dropdownButtonHeight, isDisabledLook: true,
        ),
      );
    } else {
      dropdownWidget = PopupMenuButton<String>(
        tooltip: 'Select Model', initialValue: _selectedModelTitle,
        onSelected: (String newValue) => setState(() => _selectedModelTitle = newValue),
        offset: Offset(0, dropdownButtonHeight + 10.0), color: const Color(0xFFD9D9D9),
        elevation: 4.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11.0)),
        constraints: const BoxConstraints(maxHeight: 401.0),
        itemBuilder: (BuildContext context) => _modelOptions.map((ModelOption option) {
          return PopupMenuItem<String>(
            value: option.title, padding: EdgeInsets.zero,
            child: Container(
              constraints: BoxConstraints(minWidth: 267.0 - (16 * 2)),
              padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
              child: Column( crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                children: <Widget>[ Text(option.title, style: menuItemTitleStyle), const SizedBox(height: 4.0), Text(option.description, style: menuItemDescriptionStyle)],
              ),
            ),
          );
        }).toList(),
        child: _buildCollapsedButton(
          selectedTitle: _selectedModelTitle, backgroundColor: dropdownContainerColor,
          iconColor: dropdownIconColor, textStyle: collapsedButtonTextStyle,
          width: dropdownButtonWidth, height: dropdownButtonHeight, isDisabledLook: false,
        ),
      );
    }

    return Column(
      key: const ValueKey("listeningView"), crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
            padding: const EdgeInsets.only(top: 6.0, bottom: 20.0),
            child: Center(child: Text('GENESSIS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.85), letterSpacing: 1.5, fontFamily: 'InstrumentSans')))),
        dropdownWidget, const SizedBox(height: 25),
        Container(
          height: greetingAreaHeight, alignment: Alignment.centerLeft,
          child: Text( _currentGreeting,
            style: const TextStyle(fontSize: 40, letterSpacing: -1, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2, fontFamily: 'Inter'),
            maxLines: 2, overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 40),
        Expanded(
          child: Center(
            child: GestureDetector( onTap: _handleGButtonTap,
              child: Container(
                width: screenWidth * 0.65, height: screenWidth * 0.65,
                decoration: BoxDecoration(
                  shape: BoxShape.circle, color: gButtonInnerColor,
                  boxShadow: [ BoxShadow(color: const Color(0xFF8A9A93).withOpacity(0.8), blurRadius: 20.0, spreadRadius: 5.0), BoxShadow(color: const Color(0xFF8A9A93).withOpacity(0.5), blurRadius: 30.0, spreadRadius: 10.0)],
                  border: Border.all(color: const Color(0xFF8A9A93).withOpacity(0.9), width: 6),
                ),
                child: Center(child: Text(gButtonTextCurrent, style: TextStyle(fontSize: screenWidth * (gButtonTextCurrent == "..." ? 0.15 : 0.25), fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'SFProDisplay'))),
              ),
            ),
          ),
        ),
        const SizedBox(height: 40),
        Align( alignment: Alignment.bottomRight,
            child: Padding( padding: const EdgeInsets.only(bottom: 30.0),
                child: ElevatedButton(
                    onPressed: () => _showHistoryBottomSheet(context),
                    child: const Text('HISTORY', style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom( backgroundColor: const Color(0xFFD9D9D9).withOpacity(0.06), padding: const EdgeInsets.symmetric(horizontal: 47, vertical: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)), textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w300, letterSpacing: 2, fontFamily: 'InstrumentSans'))))),
      ],
    );
  }

  Widget _buildResultsUI(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.white70, fontFamily: 'InstrumentSans', height: 1.3);
    const primaryGenreStyle = TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter', height: 1.1);
    const secondaryTitleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.white70, fontFamily: 'InstrumentSans', height: 1.8);
    const secondaryGenreStyle = TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: Colors.white, fontFamily: 'InstrumentSans', height: 1.3);

    return GestureDetector(
      key: const ValueKey("resultsView"), onTap: _switchToListeningUI,
      child: Container( color: Colors.transparent, padding: const EdgeInsets.only(top: 6.0),
        child: Column( crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(child: Text('GENESSIS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.85), letterSpacing: 1.5, fontFamily: 'InstrumentSans'))),
            const SizedBox(height: 20),
            if (_selectedModelTitle != null)
              Padding( padding: const EdgeInsets.only(bottom: 25.0),
                  child: Container( padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                    decoration: BoxDecoration( color: const Color(0xFF353936).withOpacity(0.7), borderRadius: BorderRadius.circular(29.0 / 2)),
                    child: Text(_selectedModelTitle!, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'InstrumentSans', fontWeight: FontWeight.w600, letterSpacing: 2)),
                  )
              ),
            const SizedBox(height: 25),
            const Text("The genre was", style: titleStyle), const SizedBox(height: 10),
            Text(_smoothedPrimaryGenreResult.isNotEmpty ? _smoothedPrimaryGenreResult : "N/A", style: primaryGenreStyle),
            const SizedBox(height: 50),
            if (_smoothedOtherGenreSuggestions.isNotEmpty) ...[
              const Text("It may also be", style: secondaryTitleStyle), const SizedBox(height: 8),
              ..._smoothedOtherGenreSuggestions.map((suggestion) => Padding( padding: const EdgeInsets.only(bottom: 4.0),
                  child: Text(suggestion, style: secondaryGenreStyle))).toList(),
            ],
            const Spacer(),
            Align( alignment: Alignment.bottomRight,
              child: Padding( padding: const EdgeInsets.only(bottom: 30.0),
                child: ElevatedButton(
                  onPressed: () => _showHistoryBottomSheet(context),
                  child: const Text('HISTORY', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom( backgroundColor: const Color(0xFFD9D9D9).withOpacity(0.06), padding: const EdgeInsets.symmetric(horizontal: 47, vertical: 20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w300, letterSpacing: 2, fontFamily: 'InstrumentSans')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHistoryBottomSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context, backgroundColor: Colors.transparent, isScrollControlled: true, elevation: 0,
      builder: (BuildContext builderContext) {
        return FractionallySizedBox( heightFactor: 0.85,
          child: ClipRRect( borderRadius: const BorderRadius.only(topLeft: Radius.circular(28.0), topRight: Radius.circular(28.0)),
            child: Container(
              decoration: BoxDecoration( color: const Color(0xFFCAD3C6), border: Border.all(color: const Color(0xFF007AFF).withOpacity(0.1), width: 0.0)),
              child: Center(
                child: Column( mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container( width: 40, height: 5, margin: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10))),
                    const Text('History Panel', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black54, fontFamily: 'InstrumentSans')),
                    const SizedBox(height: 20),
                    const Text('Genre history will appear here.', style: TextStyle(color: Colors.black45, fontFamily: 'InstrumentSans')),
                    const SizedBox(height: 30),
                    ElevatedButton( style: ElevatedButton.styleFrom(backgroundColor: Colors.black38),
                      child: const Text('Close', style: TextStyle(color: Colors.white, fontFamily: 'InstrumentSans')),
                      onPressed: () => Navigator.pop(builderContext),
                    )
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCollapsedButton({
    required String? selectedTitle, required Color backgroundColor,
    required Color iconColor, required TextStyle textStyle,
    required double width, required double height, bool isDisabledLook = false,
  }) {
    return Container( width: width, height: height,
      decoration: BoxDecoration( color: isDisabledLook ? backgroundColor.withOpacity(0.5) : backgroundColor, borderRadius: BorderRadius.circular(height / 2)),
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Expanded( child: Align( alignment: const Alignment(0.15, 0.0),
              child: Text(selectedTitle ?? "", style: isDisabledLook ? textStyle.copyWith(color: textStyle.color?.withOpacity(0.5)) : textStyle, overflow: TextOverflow.ellipsis))),
          Icon(Icons.arrow_drop_down, color: isDisabledLook ? iconColor.withOpacity(0.5) : iconColor, size: 22.0),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget currentView;
    switch (_currentScreenState) {
      case AppScreenState.listening:
      case AppScreenState.analyzing:
        currentView = _buildListeningUI(context);
        break;
      case AppScreenState.showingResults:
        currentView = _buildResultsUI(context);
        break;
    // case AppScreenState.error: // You could create a specific error UI
    //   currentView = _buildErrorUI(context); // Example
    //   break;
      default:
        currentView = _buildListeningUI(context); // Fallback
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [const Color(0xFF71806B).withOpacity(0.65), const Color(0xFF1E1E1E).withOpacity(0.65)],
            stops: const [0.0, 0.85],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 0.0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Container(
                key: ValueKey<AppScreenState>(_currentScreenState),
                child: currentView,
              ),
            ),
          ),
        ),
      ),
    );
  }
}