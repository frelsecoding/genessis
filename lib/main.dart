import 'dart:async';
import 'dart:ffi';
import 'dart:io'; // For Platform.isIOS/Android in _getDeviceID
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For rootBundle
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:record/record.dart';
import 'package:thesis_app/native_audio_processor.dart';
import 'package:thesis_app/native_resampler.dart';
import 'package:thesis_app/native_noise_reducer.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:pie_chart/pie_chart.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart'; // Adding for file picking

// Helper class for decoded audio
// class AudioDecodeResult {
//   final List<double> samples;
//   final int sampleRate;
//   AudioDecodeResult({required this.samples, required this.sampleRate});
// }

// Enum to manage different UI screens/states
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
  bool _isFilePicking = false;
  bool _isHttpUploading = false; // New state for HTTP upload in progress
  AppScreenState _currentScreenState = AppScreenState.listening;
  Map<String, dynamic>? _smoothedPrimaryGenreResult; // Will store {'genre': String, 'score': double}
  List<Map<String, dynamic>> _smoothedOtherGenreSuggestions = []; // List of {'genre': String, 'score': double}

  final int _predictionHistoryLength = 3;
  List<Map<String, dynamic>> _recentApiResponses = [];

  bool _isMelFilterbankReady = false;
  String _ffiInitializationError = "";
  final NativeAudioProcessor _audioProcessor = NativeAudioProcessor();
  final NativeResampler _nativeResampler = NativeResampler();

  List<double> _loadedNoiseProfile = [];

  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<List<int>>? _audioStreamSubscription;
  final int _captureSampleRate = 44100;
  List<double> _continuousAudioBuffer = [];
  final int _targetSampleRate = 22050;
  final int _processingSegmentDurationSeconds = 15;
  final int _maxBufferDurationSeconds = 17;

  late final int _segmentLengthSamplesForBuffer;
  late final int _maxBufferCapacitySamplesForBuffer;

  bool _isProcessingAudio = false;
  Timer? _processingScheduler;

  final int _nFftForFeatures = 2048;
  final int _nMelsForFeatures = 128;
  final int _hopLengthForFeatures = 512;

  final TextEditingController _songNameController = TextEditingController();
  final FocusNode _songNameFocusNode = FocusNode(); // Add FocusNode
  bool _isAwaitingSongNameInput = false;

  final List<ModelOption> _modelOptions = const [
    ModelOption(title: 'RCRNN-M', description: 'The highsest performing model for Mainstream Genres such as Pop, Rock, Classical, etc.'),
    ModelOption(title: 'RCRNN-B', description: 'This model is highly accurate for Ballroom Genres such as Cha-Cha, Samba, etc.'),
  ];

  final List<String> _initialGreetings = const [
    "What's playing?", "Let's identify this tune!", "Ready for a genre?",
    "Tap G to discover!", "Listening for music...", "Make some noise!",
  ];

  final List<String> _engagingAnalyzingMessages = const [
    "Crunching the numbers...", "Detecting the vibes...", "Decoding the soundwaves...",
    "Identifying the rhythm...", "Almost there...", "Just a moment...",
    "Working its magic...", "Tuning in...", "Calibrating...",
  ];

  final List<String> _engagingProgressMessages = const [
    "Gathering clues", "Fine-tuning", "Almost focused", "Getting clearer",
    "Zeroing in", "Sharpening senses", "Analyzing deeper",
  ];

  String _getRandomEngagingMessage() {
    final random = Random();
    return _engagingAnalyzingMessages[random.nextInt(_engagingAnalyzingMessages.length)];
  }

  String _getEngagingProgressMessage() {
    final random = Random();
    return _engagingProgressMessages[random.nextInt(_engagingProgressMessages.length)];
  }

  Map<String, double> _genreHistoryDataMap = {};
  bool _isHistoryLoading = false;
  String? _historyError;
  String? _cachedDeviceID;
  bool _historySheetFetchInitiated = false;

  // New state variable for detailed history
  Map<String, List<Map<String, dynamic>>> _detailedSongHistoryByGenre = {};

  final List<Color> _pieChartColorList = [ // Expanded list for more genres
    Colors.blue.shade400, Colors.red.shade400, Colors.green.shade400, Colors.orange.shade400,
    Colors.purple.shade400, Colors.teal.shade400, Colors.pink.shade300, Colors.amber.shade600,
    Colors.cyan.shade400, Colors.lime.shade600, Colors.indigo.shade400, Colors.brown.shade400,
    Colors.grey.shade500, Colors.deepPurple.shade300, Colors.lightBlue.shade300, Colors.lightGreen.shade400,
  ];


  @override
  void initState() {
    super.initState();
    _segmentLengthSamplesForBuffer = _captureSampleRate * _processingSegmentDurationSeconds;
    _maxBufferCapacitySamplesForBuffer = _captureSampleRate * _maxBufferDurationSeconds;
    _initializeGreeting();
    _loadMelFilterbank();
    _loadNoiseProfile();
    _requestMicrophonePermissionOnInit();
    _cacheDeviceID();
    _loadInitialHistoryFromCache();
    _processingScheduler = Timer.periodic(const Duration(milliseconds: 1700), (timer) {
      if (_currentScreenState != AppScreenState.showingResults &&
          _isMicrophoneRecording &&
          !_isProcessingAudio &&
          mounted) {
        _tryProcessingAudio();
      }
    });
  }

  Future<void> _cacheDeviceID() async {
    _cachedDeviceID = await _getDeviceID();
    if (kDebugMode) print("HomeScreen: Cached Device ID: $_cachedDeviceID");
  }

  Future<String> _getDeviceID() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    String? deviceId;
    try {
      if (kIsWeb) {
        WebBrowserInfo webBrowserInfo = await deviceInfo.webBrowserInfo;
        final uniquePart = webBrowserInfo.hashCode.toRadixString(16); // Simple unique part
        deviceId = "web_${uniquePart}_${webBrowserInfo.appVersion?.hashCode.toRadixString(16) ?? Random().nextInt(9999)}";
      } else if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor;
      }
    } catch (e) {
      if (kDebugMode) print("Error getting device ID: $e");
    }
    return deviceId ?? "unknown_device_${Random().nextInt(999999)}";
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

  Future<void> _loadNoiseProfile() async {
    try {
      final byteData = await rootBundle.load('assets/ambient_noise_final_profile.npy');
      // Assuming the .npy file stores data as 4-byte floats (float32)
      // Skip a potential header if your .npy generation script includes one.
      // For a simple array from np.save(), the data might start after a small header.
      // You'll need to know the exact offset or parse the .npy header properly.
      // This example assumes a simple raw float array or a known offset.

      // THIS IS A SIMPLIFIED PARSING. .npy files have a header.
      // For robust .npy parsing, you might need a more complex logic or a package.
      // For now, let's assume the header is, for example, 128 bytes.
      // You MUST adjust this offset based on your actual .npy file structure.
      int headerOffset = 80; // Placeholder - ADJUST THIS

      if (byteData.lengthInBytes <= headerOffset) {
          if (kDebugMode) print("HomeScreen: Noise profile file too small or header offset too large.");
          _loadedNoiseProfile = [];
          return;
      }

      final floatList = byteData.buffer.asFloat32List(byteData.offsetInBytes + headerOffset);
      _loadedNoiseProfile = List<double>.from(floatList.map((f) => f.toDouble())); // Convert Float32List to List<double>
      if (kDebugMode) print("HomeScreen: Noise profile loaded with ${_loadedNoiseProfile.length} samples.");
      if (_loadedNoiseProfile.isEmpty && mounted) {
        // Optionally inform user or log, but don't block app functionality
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load noise profile. Using raw audio.')),
        );
      }
    } catch (e) {
      if (kDebugMode) print("HomeScreen: Error loading noise profile: $e");
      _loadedNoiseProfile = []; // Ensure it's empty on error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading noise profile: ${e.toString().substring(0,min(e.toString().length, 50))}')),
        );
      }
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
        _isAwaitingSongNameInput = false; // Reset song input state
        _songNameController.clear(); // Clear controller
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
        _isAwaitingSongNameInput = false; // Ensure this is reset
        _songNameController.clear(); // Clear song name input
      });
      _initializeGreeting();
    }
  }

  void _addPredictionToHistory(Map<String, dynamic> newPredictionData) {
    if (!mounted) return;
    Map<String, dynamic>? primaryMap = newPredictionData['primary_prediction_map'] as Map<String, dynamic>?;
    List<dynamic>? topListRaw = newPredictionData['top_predictions_list'] as List<dynamic>?;

    if (primaryMap == null || primaryMap['label'] == null || primaryMap['score'] == null || topListRaw == null) {
      if (kDebugMode) print("HomeScreen AddToHistory: Invalid prediction data structure or missing score.");
      return;
    }
    // Ensure topList items also have 'genre' and 'score'
    List<Map<String, dynamic>> topList = [];
    for (var e in topListRaw) {
      if (e is Map<String, dynamic> && e['genre'] != null && e['score'] != null) {
        topList.add(e);
      }
    }

    setState(() {
      _recentApiResponses.add({"primary_prediction": primaryMap, "top_predictions": topList});
      if (_recentApiResponses.length > _predictionHistoryLength) _recentApiResponses.removeAt(0);
    });
    if (kDebugMode) print("HomeScreen AddToHistory: Count: ${_recentApiResponses.length}");
  }

  void _performSmoothingAndDisplay() {
    if (!mounted) return;
    if (kDebugMode) print("HomeScreen PerformSmoothing: History count: ${_recentApiResponses.length}, CurrentScreenState: $_currentScreenState");

    if (_recentApiResponses.isEmpty) {
      // If showing results and history becomes empty (e.g. after an error/clear), switch back gracefully
      if (_currentScreenState == AppScreenState.showingResults) {
         _switchToListeningUI(clearHistory: false);
      }
      return;
    }

    Map<String, int> genreCounts = {};
    Map<String, List<double>> genreScores = {};

    for (var responseMap in _recentApiResponses) {
      Map<String, dynamic>? primary = responseMap["primary_prediction"] as Map<String, dynamic>?;
      if (primary != null && primary["label"] != null && (primary["label"] as String).isNotEmpty && primary["score"] != null) {
        String label = primary["label"] as String;
        double score = (primary["score"] as num).toDouble();
        genreCounts[label] = (genreCounts[label] ?? 0) + 1;
        (genreScores[label] ??= []).add(score);
      }
    }

    String? smoothedPrimaryLabel;
    double? smoothedPrimaryScore;
    int maxCount = 0;

    if (genreCounts.isNotEmpty) {
      genreCounts.forEach((genre, count) {
        if (count > maxCount) {
          maxCount = count;
          smoothedPrimaryLabel = genre;
        } else if (count == maxCount) {
          // Tie-breaking: prefer the one with the highest average score among those tied
          double currentPrimaryAvgScore = (genreScores[smoothedPrimaryLabel!]?.reduce((a, b) => a + b) ?? 0.0) / (genreScores[smoothedPrimaryLabel!]?.length ?? 1);
          double candidateAvgScore = (genreScores[genre]?.reduce((a, b) => a + b) ?? 0.0) / (genreScores[genre]?.length ?? 1);
          if (candidateAvgScore > currentPrimaryAvgScore) {
            smoothedPrimaryLabel = genre;
          }
        }
      });

      // Get the score from the most recent prediction of the smoothed primary label
      if (smoothedPrimaryLabel != null) {
         var lastPredictionOfSmoothed = _recentApiResponses.lastWhere(
                (r) => (r["primary_prediction"] as Map<String,dynamic>?)?["label"] == smoothedPrimaryLabel,
            orElse: () => _recentApiResponses.last // Should ideally find it
        );
        smoothedPrimaryScore = (lastPredictionOfSmoothed["primary_prediction"]["score"] as num).toDouble();
      }
    }


    List<Map<String, dynamic>> smoothedSuggestions = [];
    if (smoothedPrimaryLabel != null) {
      Map<String, dynamic>? representativeResponse = _recentApiResponses.lastWhere(
              (r) => (r["primary_prediction"] as Map<String,dynamic>?)?["label"] == smoothedPrimaryLabel,
          orElse: () => _recentApiResponses.last
      );
      final List<dynamic>? topPreds = representativeResponse["top_predictions"] as List<dynamic>?;
      if (topPreds != null) {
        int suggestionsCount = 0;
        for (var predEntry in topPreds) {
          final Map<String, dynamic> predMap = predEntry as Map<String, dynamic>;
          if (predMap["genre"] != null && predMap["genre"] != smoothedPrimaryLabel && predMap["score"] != null) {
            smoothedSuggestions.add({'genre': predMap["genre"] as String, 'score': (predMap["score"] as num).toDouble()});
            if (++suggestionsCount >= 2) break;
          }
        }
      }
    }

    bool isConfident = (_recentApiResponses.length >= _predictionHistoryLength &&
        maxCount >= ((_predictionHistoryLength / 2.0).ceil()) && // Majority
        smoothedPrimaryLabel != null &&
        smoothedPrimaryLabel != "Unknown"); // Don't show "Unknown" as confident result

    if (kDebugMode) print("Smoothing Result - Confident: $isConfident, Smoothed: $smoothedPrimaryLabel, Score: $smoothedPrimaryScore, MaxCount: $maxCount");

    if (isConfident && smoothedPrimaryLabel != null) {
      setState(() {
        _smoothedPrimaryGenreResult = {'genre': smoothedPrimaryLabel!, 'score': smoothedPrimaryScore ?? 0.0};
        _smoothedOtherGenreSuggestions = smoothedSuggestions;
        _currentScreenState = AppScreenState.showingResults;
        _isAwaitingSongNameInput = true; // Set flag to await song name
        if (_isMicrophoneRecording) _isMicrophoneRecording = false;
        _isProcessingAudio = false;
      });
      _internalStopMicStreamOnly();
      // Request focus for the song name field when it becomes visible
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isAwaitingSongNameInput) {
          _songNameFocusNode.requestFocus();
        }
      });
      // Defer _storeClassificationInHistory until song name is provided or skipped
    } else if (_recentApiResponses.length >= _predictionHistoryLength) {
      _updateListeningUIMessage("${_getEngagingProgressMessage()}...");
      if (_currentScreenState != AppScreenState.analyzing) setState(() => _currentScreenState = AppScreenState.analyzing);
    } else {
      _updateListeningUIMessage("${_getEngagingProgressMessage()} (${_recentApiResponses.length}/$_predictionHistoryLength)...");
      if (_currentScreenState != AppScreenState.analyzing) setState(() => _currentScreenState = AppScreenState.analyzing);
    }
  }

  Future<void> _tryProcessingAudio() async {
    if (!_isMelFilterbankReady || _audioProcessor.nativeFilterbankPointer == null ||
        _continuousAudioBuffer.length < _segmentLengthSamplesForBuffer || _isProcessingAudio ||
        !_isMicrophoneRecording || _currentScreenState == AppScreenState.showingResults || !mounted) {
      return;
    }
    setState(() {
      _isProcessingAudio = true; // This shows the loader circle
      // REVERTED CHANGE: The following block was removed to prevent immediate state change to analyzing here
      // if (_currentScreenState == AppScreenState.listening) {
      //   _currentScreenState = AppScreenState.analyzing;
      //   _currentGreeting = _getRandomEngagingMessage();
      // }
      // Ensure main UI state is 'analyzing' if it was 'listening'
      if (_currentScreenState == AppScreenState.listening) {
        _currentScreenState = AppScreenState.analyzing;
        // _currentGreeting will be updated by _performSmoothingAndDisplay via _updateListeningUIMessage
        // and handled by its own AnimatedSwitcher.
      }
    });

    final int startIndex = (_continuousAudioBuffer.length - _segmentLengthSamplesForBuffer).clamp(0, _continuousAudioBuffer.length);
    List<double> segmentToProcess = List.from(_continuousAudioBuffer.sublist(startIndex));
    final isolateMessage = {
      'audioData': segmentToProcess, 'inputRate': _captureSampleRate, 'targetRate': _targetSampleRate,
      'selectedModelTitle': _selectedModelTitle ?? _modelOptions.first.title,
      'nativeFilterbankPtrAddress': _audioProcessor.nativeFilterbankPointer!.address,
      'filterbankRows': _audioProcessor.filterbankRows, 'filterbankCols': _audioProcessor.filterbankCols,
      'nFftForFeatures': _nFftForFeatures, 'hopLengthForFeatures': _hopLengthForFeatures,
      'noiseProfileData': _loadedNoiseProfile,
      'isUploadedFile': false,
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

      if (mounted && _currentScreenState != AppScreenState.showingResults) {
        setState(() => _isProcessingAudio = false);
      } else if (mounted && _currentScreenState == AppScreenState.showingResults) {
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
    final bool isUploadedFile = message['isUploadedFile'] ?? false;

    final NativeResampler resampler = NativeResampler();
    final NativeFeatureExtractor featureExtractor = NativeFeatureExtractor();
    final NativeNoiseReducer noiseReducer = NativeNoiseReducer();

    String processingStatus = "Error: Processing incomplete";
    String? displayStringForResultOnError = "Could not classify audio.";
    String? primaryGenreForStorage;
    Map<String, dynamic>? primaryPredictionMapForResult;
    List<dynamic>? topPredictionsListForResult;

    List<double> audioForResampling = audioDataFromMain;

    // Prepare noise profile with correct length
    List<double> noiseProfileFromMessage = List<double>.from(message['noiseProfileData'] ?? []);
    List<double> correctlySizedNoiseProfile = [];
    int expectedNoiseProfileLength = (nFftForFeatures / 2).floor() + 1;

    if (noiseProfileFromMessage.isNotEmpty) {
        if (noiseProfileFromMessage.length >= expectedNoiseProfileLength) {
            correctlySizedNoiseProfile = noiseProfileFromMessage.sublist(0, expectedNoiseProfileLength);
            if (noiseProfileFromMessage.length != expectedNoiseProfileLength) {
                 if (kDebugMode) print("Isolate: Adjusted noise profile length from ${noiseProfileFromMessage.length} to $expectedNoiseProfileLength to match nFft/2 + 1.");
            }
        } else {
            // If the loaded profile is shorter than expected, it's problematic.
            // For now, we'll pass it as is (or empty), but this indicates an issue with the profile itself.
            correctlySizedNoiseProfile = noiseProfileFromMessage; // Or potentially set to empty / handle error
            if (kDebugMode) print("Isolate: Warning: Loaded noise profile length (${noiseProfileFromMessage.length}) is SHORTER than expected ($expectedNoiseProfileLength). Noise reduction might be ineffective or behave unexpectedly.");
        }
    }

    try {
      // Use correctlySizedNoiseProfile instead of noiseProfile directly
      // TEMPORARILY BYPASSING NOISE REDUCTION FOR MICROPHONE INPUT DUE TO PROFILE ISSUES
      bool shouldAttemptNoiseReduction = !isUploadedFile && correctlySizedNoiseProfile.isNotEmpty && audioDataFromMain.isNotEmpty;
      
      // --- TEMPORARY BYPASS --- 
      // Force skip noise reduction for microphone input for now to ensure app functionality for defense
      if (!isUploadedFile) {
          if (kDebugMode) print("Isolate: Temporarily BYPASSING noise reduction for microphone input.");
          shouldAttemptNoiseReduction = false;
      }
      // --- END TEMPORARY BYPASS ---

      if (shouldAttemptNoiseReduction) { // Original condition: !isUploadedFile && correctlySizedNoiseProfile.isNotEmpty && audioDataFromMain.isNotEmpty
          if (kDebugMode) print("Isolate: Attempting noise reduction. Profile samples: ${correctlySizedNoiseProfile.length}, Audio samples: ${audioDataFromMain.length}");
          try {
              List<double>? cleanedAudio = noiseReducer.reduceNoise(
                  audioData: audioDataFromMain,
                  sampleRate: inputSampleRate,
                  noiseProfile: correctlySizedNoiseProfile, // Use the adjusted profile
                  nFft: nFftForFeatures,
                  hopLength: hopLengthForFeatures,
              );
              if (cleanedAudio != null && cleanedAudio.isNotEmpty) {
                  audioForResampling = cleanedAudio;
                  if (kDebugMode) print("Isolate: Noise reduction applied. Cleaned audio samples: ${cleanedAudio.length}");
              } else {
                  if (kDebugMode) print("Isolate: Noise reduction failed or returned empty, using original audio for resampling.");
              }
          } catch (e) {
              if (kDebugMode) print("Isolate: Error during noise reduction: $e");
          }
      } else if (isUploadedFile) {
          if (kDebugMode) print("Isolate: Skipping noise reduction for uploaded file.");
      }

      List<double>? audioForFeatures;
      if (inputSampleRate == targetSampleRate) {
        audioForFeatures = List<double>.from(audioForResampling);
      } else {
        audioForFeatures = resampler.resample(audioForResampling, inputSampleRate, targetSampleRate);
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
            final String apiUrl = 'https://b7flkztfy5.execute-api.ap-southeast-1.amazonaws.com/classify';
            if (apiUrl == 'YOUR_API_GATEWAY_INVOKE_URL/classify') {
              processingStatus = "Error: API URL not configured";
              displayStringForResultOnError = "App config error.";
            } else {
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
      noiseReducer.dispose();
    }
    return {
      "status_message": processingStatus,
      "display_greeting_override": displayStringForResultOnError,
      "primary_prediction_map": primaryPredictionMapForResult,
      "top_predictions_list": topPredictionsListForResult,
      "primary_genre_for_storage": primaryGenreForStorage,
    };
  }

  Future<void> _storeClassificationInHistory(String genre, String modelUsed, {String? songName}) async {
    if (!mounted || _cachedDeviceID == null || _cachedDeviceID!.startsWith("unknown_device")) {
      if (kDebugMode) print("HomeScreen: Cannot store history - Device ID not available or is placeholder.");
      return;
    }
    // !!! IMPORTANT: REPLACE WITH YOUR ACTUAL API GATEWAY URL !!!
    final String historyApiUrl = 'https://b7flkztfy5.execute-api.ap-southeast-1.amazonaws.com/history';
    if (historyApiUrl == 'YOUR_API_GATEWAY_INVOKE_URL/history') {
      if (kDebugMode) print("HomeScreen: History API URL not configured. Skipping history store.");
      return;
    }

    // Since songName is now mandatory from the UI flow, we assert it's not null or rely on the UI to ensure it.
    // However, the parameter remains nullable for potential other call sites, though current UI flow makes it non-null.
    final Map<String, String?> payload = {
      'deviceID': _cachedDeviceID!,
      'classifiedGenre': genre,
      'modelUsed': modelUsed,
      'songName': songName, 
    };
    try {
      if (kDebugMode) print("HomeScreen: Storing history: $payload");
      await http.post(
        Uri.parse(historyApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds:10));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(songName != null && songName.isNotEmpty ? 'Song "${songName.length > 20 ? songName.substring(0,20)+"..." : songName}" & genre saved!' : 'Genre saved (song name missing).')),
        );
      }
    } catch (e) {
      if (kDebugMode) print("HomeScreen: Exception storing history: $e");
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save to history. Check connection.')),
        );
      }
    }
  }

  Future<void> _loadInitialHistoryFromCache() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cachedHistoryJson = prefs.getString('fullHistoryCache'); // Use new cache key
      if (cachedHistoryJson != null) {
        List<dynamic> decodedList = jsonDecode(cachedHistoryJson);
        // Ensure all items in decodedList are Map<String, dynamic>
        List<Map<String, dynamic>> wellTypedList = decodedList.map((item) {
          if (item is Map<String, dynamic>) return item;
          // Handle cases where item might not be a map, though ideally it always should be
          return <String, dynamic>{}; 
        }).toList();
        if (mounted) {
          _processRawHistoryData(wellTypedList);
        }
      }
    } catch (e) {
      if (kDebugMode) print("HomeScreen: Error loading detailed history from cache: $e");
      // Optionally clear corrupted cache
      // SharedPreferences prefs = await SharedPreferences.getInstance();
      // await prefs.remove('fullHistoryCache');
    }
  }

  Future<void> _saveHistoryToCache(List<Map<String, dynamic>> dataToCache) async { // Expecting raw list
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String jsonString = jsonEncode(dataToCache);
      await prefs.setString('fullHistoryCache', jsonString); // Use new cache key
    } catch (e) {
      if (kDebugMode) print("HomeScreen: Error saving detailed history to cache: $e");
    }
  }

  // New helper method to process raw history data
  void _processRawHistoryData(List<Map<String, dynamic>> rawHistoryItems) {
    if (!mounted) return;

    Map<String, List<Map<String, dynamic>>> newDetailedHistory = {};
    Map<String, double> newGenreCounts = {};

    for (var item in rawHistoryItems) {
      String? genre = item['classifiedGenre'] as String?;
      String? songName = item['songName'] as String?;
      String? timestampStr = item['timestamp'] as String?;

      if (genre != null && genre.isNotEmpty) {
        // Populate genre counts for pie chart
        newGenreCounts[genre] = (newGenreCounts[genre] ?? 0) + 1;

        // Populate detailed history
        if (songName != null && songName.isNotEmpty) { // Only add to detailed view if song name exists
          (newDetailedHistory[genre] ??= []).add({
            'songName': songName,
            'timestamp': timestampStr, // Store as string, parse later for display/sort
          });
        }
      }
    }

    // Sort songs within each genre by timestamp (descending - newest first)
    newDetailedHistory.forEach((genre, songs) {
      songs.sort((a, b) {
        String? tsA = a['timestamp'] as String?;
        String? tsB = b['timestamp'] as String?;
        if (tsA == null && tsB == null) return 0;
        if (tsA == null) return 1; // Nulls last
        if (tsB == null) return -1; // Nulls last
        try {
          return DateTime.parse(tsB).compareTo(DateTime.parse(tsA)); // Sort descending
        } catch (e) {
          return 0; // If parsing fails, don't sort
        }
      });
    });

    setState(() {
      _detailedSongHistoryByGenre = newDetailedHistory;
      _genreHistoryDataMap = newGenreCounts;
    });
  }

  Future<void> _fetchHistoryAndShowChart({StateSetter? setSheetStateCallback}) async {
    if (!mounted) return;

    final updateState = setSheetStateCallback ?? setState;

    if (_cachedDeviceID == null || _cachedDeviceID!.startsWith("unknown_device")) {
      await _cacheDeviceID(); // Ensure device ID is cached
      if (!mounted) return; // Check mounted again after await
      if (_cachedDeviceID == null || _cachedDeviceID!.startsWith("unknown_device")) {
        updateState(() => _historyError = "Device ID unavailable for history.");
        return;
      }
    }

    updateState(() { _isHistoryLoading = true; _historyError = null; /* Keep existing _genreHistoryDataMap for spinner background */ });

    // !!! IMPORTANT: REPLACE WITH YOUR ACTUAL API GATEWAY URL !!!
    final String readHistoryApiUrl = 'https://b7flkztfy5.execute-api.ap-southeast-1.amazonaws.com/history?deviceID=${Uri.encodeComponent(_cachedDeviceID!)}';
    if (readHistoryApiUrl.startsWith('YOUR_API_GATEWAY_INVOKE_URL')) {
      if (kDebugMode) print("HomeScreen: History Read API URL not configured. Skipping history fetch.");
      if (mounted) updateState(() { _historyError = "App config error for history."; _isHistoryLoading = false; });
      return;
    }

    try {
      final response = await http.get(Uri.parse(readHistoryApiUrl)).timeout(const Duration(seconds: 15));
      if (!mounted) return; // Check mounted again after await

      if (response.statusCode == 200) {
        final List<dynamic> historyItemsRaw = jsonDecode(response.body);
        // Ensure all items are Map<String, dynamic>
        final List<Map<String, dynamic>> historyItems = historyItemsRaw.map((item) {
            if (item is Map<String, dynamic>) return item;
            return <String, dynamic>{}; // Or handle error appropriately
        }).toList();
        
        await _saveHistoryToCache(historyItems); // Save raw history to cache
        if(mounted) {
            _processRawHistoryData(historyItems); // Process raw data to update both state vars
            updateState(() { _isHistoryLoading = false; _historyError = null; });
        }
      } else {
        updateState(() { _historyError = "Failed to load history (${response.statusCode})."; _isHistoryLoading = false;});
      }
    } on TimeoutException catch (_) {
      if (!mounted) return;
      updateState(() { _historyError = "History request timed out."; _isHistoryLoading = false; });
    } catch (e) {
      if (!mounted) return;
      updateState(() { _historyError = "Error loading history: ${e.toString()}"; _isHistoryLoading = false; });
    } finally {
      // _isHistoryLoading is already set to false in success/error specific blocks above.
      // Redundant call, but safe:
      // if (mounted && _isHistoryLoading) updateState(() => _isHistoryLoading = false);
    }
  }

  void _showHistoryBottomSheet(BuildContext context) {
    _historySheetFetchInitiated = false; // Reset flag each time sheet is shown

    // The _genreHistoryDataMap might already contain cached data from _loadInitialHistoryFromCache()
    // or from a previous fetch if the sheet was opened before in this app session.
    // The PieChart will display this existing data immediately.
    // The _fetchHistoryAndShowChart call below will then update it from the network.

    showModalBottomSheet<void>(
      context: context, backgroundColor: Colors.transparent,
      isScrollControlled: true, elevation: 0,
      builder: (BuildContext builderContext) {
        // Removed the empty WidgetsBinding.instance.addPostFrameCallback((_) {});
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            if (!_historySheetFetchInitiated && mounted) {
              _historySheetFetchInitiated = true; // Mark that fetch has been initiated for this sheet instance
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) { // Ensure widget is still mounted when callback executes
                  _fetchHistoryAndShowChart(setSheetStateCallback: setSheetState);
                }
              });
            }

            Widget content;
            if (_isHistoryLoading) {
              content = const Center(child: CircularProgressIndicator(color: Colors.black54));
            } else if (_historyError != null) {
              content = Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text(_historyError!, style: const TextStyle(color: Colors.redAccent, fontSize: 16, fontFamily: 'InstrumentSans'), textAlign: TextAlign.center,)));
            } else if (_genreHistoryDataMap.isEmpty && _detailedSongHistoryByGenre.isEmpty) { // Check both
              content = const Center(child: Text('No history yet. Start classifying!', style: TextStyle(color: Colors.black54, fontSize: 16, fontFamily: 'InstrumentSans')));
            } else {
              List<Widget> historyWidgets = [];

              // 1. Pie Chart (if data exists)
              if (_genreHistoryDataMap.isNotEmpty) {
                 historyWidgets.add(
                   Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 24.0),
                    child: PieChart(
                      dataMap: _genreHistoryDataMap,
                      animationDuration: const Duration(milliseconds: 800),
                      chartLegendSpacing: 42,
                      chartRadius: MediaQuery.of(context).size.width / 2.7, // Slightly smaller radius if needed
                      key: ValueKey(_genreHistoryDataMap.hashCode), // Use a key that changes if data changes
                      colorList: _pieChartColorList.take(_genreHistoryDataMap.length).toList(),
                      initialAngleInDegree: 0,
                      chartType: ChartType.ring,
                      ringStrokeWidth: 48,
                      centerText: "GENRES",
                      legendOptions: const LegendOptions(
                        showLegendsInRow: false, legendPosition: LegendPosition.right,
                        showLegends: true, legendShape: BoxShape.circle,
                        legendTextStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontFamily: 'InstrumentSans'),
                      ),
                      chartValuesOptions: const ChartValuesOptions(
                          showChartValueBackground: false, showChartValues: true,
                          showChartValuesInPercentage: true, showChartValuesOutside: true,
                          decimalPlaces: 0,
                          chartValueStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 12, fontFamily: 'InstrumentSans')
                      ),
                    ),
                  )
                 );
                 historyWidgets.add(const Divider(height: 30, thickness: 1, indent: 20, endIndent: 20));
                 historyWidgets.add(const Padding(
                   padding: EdgeInsets.only(bottom: 10.0),
                   child: Text("Songs by Genre", textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87, fontFamily: 'InstrumentSans')),
                 ));
              } else if (_detailedSongHistoryByGenre.isNotEmpty) {
                // If no pie chart data but detailed history exists, still show the title for the list
                 historyWidgets.add(const Padding(
                   padding: EdgeInsets.only(bottom: 10.0, top: 10.0),
                   child: Text("Classified Songs", textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87, fontFamily: 'InstrumentSans')),
                 ));
              }

              // 2. Expandable List of Songs by Genre
              if (_detailedSongHistoryByGenre.isNotEmpty) {
                historyWidgets.add(
                  Expanded(
                    child: ListView.builder(
                      itemCount: _detailedSongHistoryByGenre.keys.length,
                      itemBuilder: (context, index) {
                        String genre = _detailedSongHistoryByGenre.keys.elementAt(index);
                        List<Map<String, dynamic>> songs = _detailedSongHistoryByGenre[genre]!;
                        return ExpansionTile(
                          key: PageStorageKey<String>(genre), // Helps preserve expanded state
                          iconColor: Colors.black54,
                          collapsedIconColor: Colors.black54,
                          title: Text(genre, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87, fontSize: 17, fontFamily: 'InstrumentSans')),
                          children: songs.map((songData) {
                            String songName = songData['songName'] as String;
                            String? timestampStr = songData['timestamp'] as String?;
                            String displayTimestamp = "";
                            if (timestampStr != null) {
                              try {
                                DateTime dt = DateTime.parse(timestampStr);
                                // Basic formatting, can be improved with 'intl' package for better date formats
                                displayTimestamp = " - ${dt.year}/${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}";
                              } catch (e) {
                                displayTimestamp = ""; // Error parsing date
                              }
                            }
                            return ListTile(
                              title: Text(songName, style: const TextStyle(fontFamily: 'InstrumentSans', color: Colors.black87)),
                              subtitle: displayTimestamp.isNotEmpty ? Text(displayTimestamp, style: TextStyle(fontFamily: 'InstrumentSans', fontSize: 12, color: Colors.black54)) : null,
                              dense: true,
                            );
                          }).toList(),
                        );
                      },
                    ),
                  )
                );
              } else if (_genreHistoryDataMap.isEmpty) {
                 // This case is covered by the top-level check, but as a fallback
                 historyWidgets.add(const Center(child: Text('No songs recorded yet.', style: TextStyle(color: Colors.black54, fontSize: 16, fontFamily: 'InstrumentSans'))));
              }
              
              content = Column(children: historyWidgets);
            }
            return FractionallySizedBox( heightFactor: 0.85,
              child: ClipRRect( borderRadius: const BorderRadius.only(topLeft: Radius.circular(28.0), topRight: Radius.circular(28.0)),
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFFE0E0E0), border: Border.all(color: Colors.grey.shade400, width: 0.5)),
                  child: Column(
                    children: <Widget>[
                      Container( width: 40, height: 5, margin: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(color: Colors.grey[500], borderRadius: BorderRadius.circular(10))),
                      const Text('Genre History', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87, fontFamily: 'InstrumentSans')),
                      const SizedBox(height: 10),
                      Expanded(child: content),
                      Padding( padding: const EdgeInsets.all(16.0),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[700]),
                          child: const Text('Close', style: TextStyle(color: Colors.white, fontFamily: 'InstrumentSans')),
                          onPressed: () => Navigator.pop(builderContext),
                        ),
                      )
                    ],
                  ),
                ),
              ),
            );
          },
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

  Widget _buildListeningUI(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // Determine if we should visually be in an analyzing state for the button/loader
    final bool isCurrentlyAnalyzing = _isProcessingAudio || // Actively processing an audio chunk
                                    (_currentScreenState == AppScreenState.analyzing && _isMicrophoneRecording && !_isHttpUploading); // In mic analyzing state, waiting for enough predictions, and not currently http uploading

    // Determine G button properties based on state
    Color gButtonOuterColor = isCurrentlyAnalyzing
        ? Colors.grey.shade800
        : (_isMicrophoneRecording ? Colors.green.shade400 : Colors.grey.shade400);
    String gButtonText = isCurrentlyAnalyzing
        ? "" // No text when showing loader
        : (_isMicrophoneRecording ? "..." : "G");

    // If FFI failed, show an error message instead of the G button and other controls
    bool isDisabledLook = _ffiInitializationError.isNotEmpty || isCurrentlyAnalyzing;

    Color dropdownContainerColor = const Color(0xFF353936);
    Color dropdownIconColor = const Color(0xFFD9D9D9);
    const TextStyle collapsedButtonTextStyle = TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'InstrumentSans', fontWeight: FontWeight.w600, letterSpacing: 2);
    double dropdownButtonWidth = 149.0;
    double dropdownButtonHeight = 29.0;
    const TextStyle menuItemTitleStyle = TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold, fontFamily: 'InstrumentSans');
    const TextStyle menuItemDescriptionStyle = TextStyle(color: Colors.black87, fontSize: 13, fontFamily: 'InstrumentSans', height: 1.3);
    const double greetingAreaHeight = 96.0;

    Widget dropdownWidget;
    if (isDisabledLook) {
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
          height: greetingAreaHeight, // Ensure this container has a defined height
          alignment: Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (Widget child, Animation<double> animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: Text( // Important: Add a Key here for AnimatedSwitcher to detect change
              _currentGreeting,
              key: ValueKey<String>(_currentGreeting), 
              style: const TextStyle(fontSize: 40, letterSpacing: -1, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2, fontFamily: 'Inter'),
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 40),
        Expanded(
          child: Center(
            child: isCurrentlyAnalyzing
              ? SizedBox(
                  width: screenWidth * 0.5, // Adjust size as needed
                  height: screenWidth * 0.5, // Adjust size as needed
                  child: CircularProgressIndicator(
                    strokeWidth: 6.0, // Adjust thickness
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withOpacity(0.8)),
                  ),
                )
              : GestureDetector(
              onTap: (_ffiInitializationError.isNotEmpty) ? null : _handleGButtonTap, // isDisabledLook check removed as isCurrentlyAnalyzing handles loader
              child: Container(
                width: screenWidth * 0.65, height: screenWidth * 0.65,
                decoration: BoxDecoration(
                  shape: BoxShape.circle, color: gButtonOuterColor,
                  boxShadow: [ BoxShadow(color: const Color(0xFF8A9A93).withOpacity(0.8), blurRadius: 20.0, spreadRadius: 5.0), BoxShadow(color: const Color(0xFF8A9A93).withOpacity(0.5), blurRadius: 30.0, spreadRadius: 10.0)],
                  border: Border.all(color: const Color(0xFF8A9A93).withOpacity(0.9), width: 6),
                ),
                child: Center(child: Text(gButtonText, style: TextStyle(fontSize: screenWidth * (gButtonText == "G" ? 0.25 : 0.15), fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'SFProDisplay'))),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 30.0, top: 40.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withOpacity(0.1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  textStyle: const TextStyle(fontSize: 16, fontFamily: 'InstrumentSans'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30.0)),
                ).copyWith(elevation: ButtonStyleButton.allOrNull(0.0)),
                onPressed: (_isMicrophoneRecording || _isFilePicking || _isHttpUploading) 
                    ? null // Disable if recording, picking a file, or an HTTP upload is in progress
                    : _uploadRawAudioFileToServer,
                child: const Text('UPLOAD'),
              ),
              ElevatedButton(
                onPressed: () => _showHistoryBottomSheet(context),
                child: const Text('HISTORY', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD9D9D9).withOpacity(0.06),
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w300, letterSpacing: 2, fontFamily: 'InstrumentSans'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultsUI(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.white70, fontFamily: 'InstrumentSans', height: 1.3);
    const primaryGenreStyle = TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Inter', height: 1.1);
    const secondaryTitleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.white70, fontFamily: 'InstrumentSans', height: 1.8);
    const secondaryGenreStyle = TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: Colors.white, fontFamily: 'InstrumentSans', height: 1.3);

    String primaryGenreText = "N/A";
    String rawPrimaryGenre = "N/A"; // For storing
    Widget primaryGenreWidget = Text(primaryGenreText, style: primaryGenreStyle, textAlign: TextAlign.start);

    if (_smoothedPrimaryGenreResult != null) {
      rawPrimaryGenre = _smoothedPrimaryGenreResult!['genre'] as String;
      double score = (_smoothedPrimaryGenreResult!['score'] as num?)?.toDouble() ?? 0.0;
      primaryGenreText = "$rawPrimaryGenre (${(score * 100).toStringAsFixed(0)}%)";
      primaryGenreWidget = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(primaryGenreText, style: primaryGenreStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }


    return GestureDetector(
      key: const ValueKey("resultsView"), 
      onTap: _isAwaitingSongNameInput ? null : _switchToListeningUI, // Disable tap to go back when awaiting input
      child: Container( color: Colors.transparent, padding: const EdgeInsets.only(top: 6.0),
        child: SingleChildScrollView( // Wrap the Column in SingleChildScrollView
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
              // Text(primaryGenreText, style: primaryGenreStyle), // Replaced by widget
              primaryGenreWidget, // Use the FittedBox widget here
              const SizedBox(height: 50),
              if (_smoothedOtherGenreSuggestions.isNotEmpty) ...[
                const Text("It may also be", style: secondaryTitleStyle), const SizedBox(height: 8),
                ..._smoothedOtherGenreSuggestions.map((suggestionMap) {
                    String genre = suggestionMap['genre'] as String;
                    double score = (suggestionMap['score'] as num?)?.toDouble() ?? 0.0;
                    String suggestionText = "$genre (${(score * 100).toStringAsFixed(0)}%)";
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      // child: Text(suggestionText, style: secondaryGenreStyle));
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(suggestionText, style: secondaryGenreStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      )
                    );
                  }).toList(),
              ],
              const Spacer(),

              if (_isAwaitingSongNameInput)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("What is the name of this song?", style: titleStyle.copyWith(fontSize: 18)),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _songNameController,
                        focusNode: _songNameFocusNode, // Assign FocusNode
                        cursorColor: Colors.white, // Explicitly set cursor color
                        autofocus: false, // We handle focus manually with requestFocus
                        style: const TextStyle(color: Colors.white, fontFamily: 'InstrumentSans', fontSize: 18),
                        decoration: InputDecoration(
                          hintText: "Enter song name (required)",
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.7), fontFamily: 'InstrumentSans'), // Slightly more visible hint
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.15), // Slightly more opaque for better contrast if needed
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade400,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                textStyle: const TextStyle(fontFamily: 'InstrumentSans', fontWeight: FontWeight.bold)
                              ),
                              onPressed: () {
                                final String currentSongName = _songNameController.text.trim();
                                if (currentSongName.isEmpty) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Please enter the song name.')),
                                    );
                                  }
                                  return; // Do not proceed if song name is empty
                                }
                                if (_smoothedPrimaryGenreResult != null && _selectedModelTitle != null) {
                                  _storeClassificationInHistory(
                                    _smoothedPrimaryGenreResult!['genre'] as String,
                                    _selectedModelTitle!,
                                    songName: currentSongName,
                                  );
                                }
                                _switchToListeningUI();
                              },
                              child: const Text("CONFIRM & SAVE", style: TextStyle(color: Colors.white)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              // Constrain the height of the content that could be pushed by keyboard
              // This SizedBox ensures that the SingleChildScrollView has a boundary
              // if the content above the input field is shorter than the screen minus keyboard.
              // Adjust height as necessary, or make it more dynamic if other elements above can vary a lot.
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 ? 0 : 50), // Add some space if keyboard not visible

              if (!_isAwaitingSongNameInput) // Only show history button if not awaiting input
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
      ),
    );
  }

  void _showLoadingDialog(BuildContext context, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Text(message),
            ],
          ),
        );
      },
    );
  }

  void _hideLoadingDialog(BuildContext context) {
    if (!mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      if (kDebugMode) print("Attempted to hide a dialog that wasn't on top or context issue.");
    }
  }

  @override
  void dispose() {
    _processingScheduler?.cancel();
    _songNameController.dispose(); 
    _songNameFocusNode.dispose(); // Dispose FocusNode
    _stopListeningAndClearHistory();
    _audioRecorder.dispose();
    _audioProcessor.dispose();
    _nativeResampler.dispose();
    super.dispose();
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
      default:
        currentView = _buildListeningUI(context);
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

  Future<void> _uploadRawAudioFileToServer() async {
    if (!mounted || _isFilePicking || _isHttpUploading) return;

    setState(() {
      _isFilePicking = true;
      // _isHttpUploading will be set later, right before the HTTP request
    });

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );
    } catch (e) {
      if (kDebugMode) print("File picker exception: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("File picker error: ${e.toString().substring(0, min(e.toString().length, 50))}")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFilePicking = false; // Reset picking flag here
        });
      }
    }

    if (result == null || result.files.single.path == null) {
      if (kDebugMode) print("User canceled the file picker or path is null.");
      return;
    }

    String? filePath = result.files.single.path;
    String fileName = result.files.single.name ?? filePath!.split('/').last;
    String? fileExtension = result.files.single.extension?.toLowerCase();
    List<String> allowedExtensions = ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'];

    if (fileExtension == null || !allowedExtensions.contains(fileExtension)) {
      if (kDebugMode) print("Invalid file type selected: $fileName, extension: $fileExtension");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Invalid file type: .$fileExtension. Please select an audio file.")),
        );
      }
      return;
    }

    File audioFileToUpload = File(filePath!);
    if (kDebugMode) print("File picked for raw upload: ${audioFileToUpload.path}");

    if (_cachedDeviceID == null || _cachedDeviceID!.startsWith("unknown_device")) {
      if (kDebugMode) print("Upload Error: Device ID not available for upload.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Upload Error: Device ID not ready. Please try again.")),
        );
      }
      return;
    }
    if (_selectedModelTitle == null || _selectedModelTitle!.isEmpty) {
       if (kDebugMode) print("Upload Error: Model not selected for upload.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Upload Error: Please select a model first.")),
        );
      }
      return;
    }

    final String uploadUrl = 'https://b7flkztfy5.execute-api.ap-southeast-1.amazonaws.com/upload';

    if (uploadUrl == 'YOUR_AWS_API_GATEWAY_UPLOAD_URL' || uploadUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Upload Error: Server endpoint not configured in app.")),
        );
      }
      if (kDebugMode) print("Upload Error: Server endpoint 'YOUR_AWS_API_GATEWAY_UPLOAD_URL' is a placeholder or empty.");
      return;
    }

    if (!mounted) return;

    setState(() { // Set uploading state right before showing dialog and making request
      _isHttpUploading = true;
    });
    _showLoadingDialog(context, "Uploading ${fileName}...");

    try {
      var request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
      request.fields['deviceID'] = _cachedDeviceID!;
      request.fields['modelTitle'] = _selectedModelTitle!;
      request.files.add(await http.MultipartFile.fromPath('audioFile', audioFileToUpload.path));

      var response = await request.send().timeout(const Duration(minutes: 3));
      
      bool isStillMountedAfterUploadAttempt = mounted;
      if (isStillMountedAfterUploadAttempt) {
        _hideLoadingDialog(context);
      }

      if (!isStillMountedAfterUploadAttempt) return;

      final responseBody = await response.stream.bytesToString();
      if (response.statusCode == 200 || response.statusCode == 201) {
        if (kDebugMode) print("File uploaded successfully. Server response: $responseBody");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Uploaded successfully, please check the History section for results later.")),
          );
          // Ensure the UI is in listening state
          if (_currentScreenState != AppScreenState.listening) {
            setState(() {
              _currentScreenState = AppScreenState.listening;
              _initializeGreeting();
            });
          }
        }
      } else {
        if (kDebugMode) print("File upload failed. Status: ${response.statusCode}, Body: $responseBody");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Upload failed for ${fileName} (${response.statusCode}). Server: ${responseBody.substring(0, min(responseBody.length, 100))}")),
          );
        }
      }
    } on TimeoutException catch (_) {
      if (kDebugMode) print("Upload for ${fileName} timed out.");
      if (mounted) {
        _hideLoadingDialog(context); // Ensure dialog is hidden on timeout
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Upload for ${fileName} timed out. Check network or server.")),
        );
      }
    } catch (e) {
      if (kDebugMode) print("Error uploading file: $e");
      if (mounted) {
         _hideLoadingDialog(context); // Ensure dialog is hidden on other errors
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error uploading ${fileName}: ${e.toString().substring(0, min(e.toString().length, 70))}")),
        );
      }
    } finally {
        if (mounted) { 
            setState(() { // Reset http uploading flag in finally
                _isHttpUploading = false;
            });
        }
    }
  }
}