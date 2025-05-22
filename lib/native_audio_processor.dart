import 'dart:ffi';
import 'dart:math'; // Already present, used by NativeAudioProcessor's classifyOnDevice
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart'; // Already present

// Typedefs for NativeAudioProcessor (Mel Filterbank)
typedef CalculateMelFilterbankNative = Pointer<Float> Function(
    Int32 nFft, Int32 nMels, Float sr, Float fMin, Float fMax,
    Pointer<Int32> outRows, Pointer<Int32> outCols);
typedef CalculateMelFilterbankDart = Pointer<Float> Function(
    int nFft, int nMels, double sr, double fMin, double fMax,
    Pointer<Int32> outRows, Pointer<Int32> outCols);

typedef FreeMelFilterbankMemoryNative = Void Function(Pointer<Void> ptr);
typedef FreeMelFilterbankMemoryDart = void Function(Pointer<Void> ptr);
// --- End Typedefs for NativeAudioProcessor ---

class NativeAudioProcessor {
  late final DynamicLibrary _dylib;

  late final CalculateMelFilterbankDart _calculateMelFilterbank;
  late final FreeMelFilterbankMemoryDart _freeMelFilterbankMemory;

  Pointer<Float>? _nativeFilterbankPointer;
  int _filterbankRows = 0;
  int _filterbankCols = 0;

  // --- Getters for filterbank properties ---
  Pointer<Float>? get nativeFilterbankPointer => _nativeFilterbankPointer;
  int get filterbankRows => _filterbankRows;
  int get filterbankCols => _filterbankCols;
  // --- End Getters ---

  NativeAudioProcessor() {
    if (Platform.isIOS || Platform.isMacOS) {
      _dylib = DynamicLibrary.process();
    } else {
      throw Exception("Unsupported platform for FFI in NativeAudioProcessor. Define library loading for other platforms.");
    }

    _calculateMelFilterbank = _dylib
        .lookup<NativeFunction<CalculateMelFilterbankNative>>('calculate_mel_filterbank')
        .asFunction();
    _freeMelFilterbankMemory = _dylib
        .lookup<NativeFunction<FreeMelFilterbankMemoryNative>>('free_mel_filterbank_memory')
        .asFunction();

    debugPrint("NativeAudioProcessor: FFI functions (calculate_mel_filterbank, free_mel_filterbank_memory) looked up.");
  }

  Future<List<List<double>>?> fetchAndStoreMelFilterbank({
    required int nFft,
    required int nMels,
    required double sampleRate,
    required double fMin,
    double? fMax,
  }) async {
    debugPrint("NativeAudioProcessor: Requesting Mel filterbank from Swift (SR: $sampleRate, nFFT: $nFft, nMels: $nMels)...");

    if (_nativeFilterbankPointer != null) {
      releaseMelFilterbankMemory();
    }

    Pointer<Int32> outRows = calloc<Int32>();
    Pointer<Int32> outCols = calloc<Int32>();

    try {
      final Pointer<Float> filterbankPtr = _calculateMelFilterbank(
          nFft, nMels, sampleRate, fMin, fMax ?? (sampleRate / 2.0),
          outRows, outCols);

      if (filterbankPtr == nullptr) {
        debugPrint("NativeAudioProcessor: Native function calculate_mel_filterbank returned null pointer.");
        return null;
      }

      _filterbankRows = outRows.value;
      _filterbankCols = outCols.value;
      _nativeFilterbankPointer = filterbankPtr;

      debugPrint("NativeAudioProcessor: Mel filterbank received. Dimensions: $_filterbankRows x $_filterbankCols");

      if (_filterbankRows <= 0 || _filterbankCols <= 0) {
        debugPrint("NativeAudioProcessor: Mel filterbank dimensions from native are invalid.");
        releaseMelFilterbankMemory();
        return null;
      }
      if (_filterbankRows != nMels) {
        debugPrint("NativeAudioProcessor: WARNING - nMels mismatch. Requested: $nMels, Loaded: $_filterbankRows");
      }

      final List<List<double>> melFilterbank = List.generate(
        _filterbankRows,
            (i) => List.generate(
          _filterbankCols,
              (j) => (_nativeFilterbankPointer! + (i * _filterbankCols + j)).value,
        ),
      );
      return melFilterbank;

    } catch (e) {
      debugPrint("NativeAudioProcessor: Error in fetchAndStoreMelFilterbank: $e");
      if (_nativeFilterbankPointer != null) {
        releaseMelFilterbankMemory();
      }
      rethrow;
    } finally {
      calloc.free(outRows);
      calloc.free(outCols);
    }
  }

  void releaseMelFilterbankMemory() {
    if (_nativeFilterbankPointer != null) {
      debugPrint("NativeAudioProcessor: Releasing native Mel filterbank memory.");
      _freeMelFilterbankMemory(_nativeFilterbankPointer!.cast<Void>());
      _nativeFilterbankPointer = null;
      _filterbankRows = 0;
      _filterbankCols = 0;
    }
  }

  Future<String> classifyOnDevice(List<List<double>>? melSpectrogramFeatures, String modelTitle) async {
    debugPrint("NativeAudioProcessor: classifyOnDevice called (SIMULATED). Model: $modelTitle");
    if (melSpectrogramFeatures == null || melSpectrogramFeatures.isEmpty) {
      debugPrint("NativeAudioProcessor: No features to classify.");
      return "Error: No features";
    }
    await Future.delayed(Duration(milliseconds: 50 + Random().nextInt(100)));
    final List<String> possibleResults = ["Blues", "Classical", "Rock", "Pop", "No Match"];
    return possibleResults[Random().nextInt(possibleResults.length)];
  }

  void dispose() {
    debugPrint("NativeAudioProcessor: dispose called. Releasing native resources.");
    releaseMelFilterbankMemory();
  }
}

// =========================================================================
// === NativeFeatureExtractor and related FFI definitions START HERE ===
// =========================================================================

// This class can be used in Dart to hold the structured results from native.
class ExtractedFeatures {
  final List<List<double>> data;
  final int nMels;
  final int numFrames;
  ExtractedFeatures({required this.data, required this.nMels, required this.numFrames});
}

// --- Typedefs for NativeFeatureExtractor (Log-Mel Spectrogram Calculation) ---
typedef CalculateLogMelSpectrogramNative = Void Function(
    Pointer<Float> audio_data_ptr,
    Int32 audio_data_length,
    Int32 sample_rate,
    Int32 n_fft,
    Int32 hop_length,
    Pointer<Float> mel_filterbank_ptr,
    Int32 n_mels,
    Int32 num_freq_bins_in_fft_output,
    // Output parameters
    Pointer<Pointer<Float>> out_data_ptr, // Pointer to a Pointer<Float>
    Pointer<Int32> out_n_mels,
    Pointer<Int32> out_num_frames);

typedef CalculateLogMelSpectrogramDart = void Function(
    Pointer<Float> audio_data_ptr,
    int audio_data_length,
    int sample_rate,
    int n_fft,
    int hop_length,
    Pointer<Float> mel_filterbank_ptr,
    int n_mels,
    int num_freq_bins_in_fft_output,
    // Output parameters
    Pointer<Pointer<Float>> out_data_ptr,
    Pointer<Int32> out_n_mels,
    Pointer<Int32> out_num_frames);

// For freeing the memory allocated by calculate_log_mel_spectrogram
typedef FreeFeatureMemoryNative = Void Function(Pointer<Void> ptr);
typedef FreeFeatureMemoryDart = void Function(Pointer<Void> ptr);
// --- End Typedefs for NativeFeatureExtractor ---

class NativeFeatureExtractor {
  late final DynamicLibrary _dylib; // Assumes same dylib as NativeAudioProcessor
  late final CalculateLogMelSpectrogramDart _calculateLogMelSpectrogram;
  late final FreeFeatureMemoryDart _freeFeatureMemory;

  Pointer<Float>? _lastFeaturesPointer; // To store the pointer to the native features data

  NativeFeatureExtractor() {
    // Assumes the functions are in the same dynamic library as NativeAudioProcessor
    if (Platform.isIOS || Platform.isMacOS) {
      _dylib = DynamicLibrary.process();
    } else {
      throw Exception("Unsupported platform for FFI in NativeFeatureExtractor. Define library loading.");
    }

    _calculateLogMelSpectrogram = _dylib
        .lookup<NativeFunction<CalculateLogMelSpectrogramNative>>(
        'calculate_log_mel_spectrogram')
        .asFunction<CalculateLogMelSpectrogramDart>();

    _freeFeatureMemory = _dylib
        .lookup<NativeFunction<FreeFeatureMemoryNative>>(
        'free_feature_extractor_memory') // Ensure this matches the C decl in Swift
        .asFunction<FreeFeatureMemoryDart>();
    debugPrint("NativeFeatureExtractor: FFI functions loaded.");
  }

  ExtractedFeatures? extractFeatures({
    required List<double> audioData,
    required int sampleRate,
    required int nFft,
    required int hopLength,
    required Pointer<Float> melFilterbankPointer, // From NativeAudioProcessor
    required int nMelsFromFilterbank, // This is n_mels for output features, should match filterbank
    required int numFreqBinsInFftOutput, // This is n_fft_filterbank/2 + 1
  }) {
    // 0. Free previous features if any, to prevent memory leaks if called multiple times
    releaseFeaturesMemory();

    // 1. Allocate memory for input audio and copy data
    final audioPtr = calloc<Float>(audioData.length);
    // More efficient copy using asTypedList if available and appropriate
    // For now, a loop is clear and works.
    for (int i = 0; i < audioData.length; i++) {
      audioPtr[i] = audioData[i];
    }

    // 2. Allocate memory for the output parameters that Swift will fill
    final outDataPtrPtr = calloc<Pointer<Float>>();
    final outNMelsPtr = calloc<Int32>();
    final outNumFramesPtr = calloc<Int32>();

    ExtractedFeatures? result;

    try {
      // 3. Call the native function
      _calculateLogMelSpectrogram(
        audioPtr,
        audioData.length,
        sampleRate,
        nFft,
        hopLength,
        melFilterbankPointer,
        nMelsFromFilterbank,
        numFreqBinsInFftOutput,
        // Pass pointers to output parameter holders
        outDataPtrPtr,
        outNMelsPtr,
        outNumFramesPtr,
      );

      // 4. Retrieve values written by the Swift function
      final Pointer<Float> featuresDataPtrValue = outDataPtrPtr.value;
      final int actualNMels = outNMelsPtr.value;
      final int actualNumFrames = outNumFramesPtr.value;

      if (featuresDataPtrValue == nullptr || actualNumFrames <= 0 || actualNMels <= 0) {
        debugPrint("NativeFeatureExtractor: Native feature extraction returned null or invalid dimensions.");
        _lastFeaturesPointer = null; // Ensure it's null if native call failed to produce valid data
        result = null;
      } else {
        _lastFeaturesPointer = featuresDataPtrValue; // Store for later freeing

        // 5. Convert Pointer<Float> to List<List<double>>
        // Assumes row-major order from Swift: (nMels rows, numFrames columns)
        final List<List<double>> resultFeaturesList = List.generate(
          actualNMels,
              (i) => List.generate(
            actualNumFrames,
                (j) => (_lastFeaturesPointer! + (i * actualNumFrames + j)).value,
          ),
          growable: false, // Typically features are fixed size once generated
        );
        debugPrint("NativeFeatureExtractor: Features extracted successfully. Shape: ($actualNMels, $actualNumFrames)");
        result = ExtractedFeatures(data: resultFeaturesList, nMels: actualNMels, numFrames: actualNumFrames);
      }
    } catch (e) {
      debugPrint("NativeFeatureExtractor: Error calling native feature extraction: $e");
      releaseFeaturesMemory(); // Attempt to clean up if error occurred mid-process
      result = null;
    } finally {
      // 6. Free memory allocated in Dart for FFI call parameters
      calloc.free(audioPtr);
      calloc.free(outDataPtrPtr);
      calloc.free(outNMelsPtr);
      calloc.free(outNumFramesPtr);
    }
    return result;
  }

  /// Releases the memory allocated by the native code for the features.
  void releaseFeaturesMemory() {
    if (_lastFeaturesPointer != null) {
      debugPrint("NativeFeatureExtractor: Releasing native features memory.");
      _freeFeatureMemory(_lastFeaturesPointer!.cast<Void>());
      _lastFeaturesPointer = null;
    }
  }

  void dispose() {
    debugPrint("NativeFeatureExtractor: dispose called. Releasing native resources.");
    releaseFeaturesMemory();
  }
}