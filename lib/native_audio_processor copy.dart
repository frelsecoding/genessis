import 'dart:ffi';
import 'dart:math';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef CalculateMelFilterbankNative = Pointer<Float> Function(
    Int32 nFft, Int32 nMels, Float sr, Float fMin, Float fMax,
    Pointer<Int32> outRows, Pointer<Int32> outCols);
typedef CalculateMelFilterbankDart = Pointer<Float> Function(
    int nFft, int nMels, double sr, double fMin, double fMax,
    Pointer<Int32> outRows, Pointer<Int32> outCols);

// For freeing the Mel Filterbank memory
typedef FreeMelFilterbankMemoryNative = Void Function(Pointer<Void> ptr);
typedef FreeMelFilterbankMemoryDart = void Function(Pointer<Void> ptr);
// --- End Typedefs ---

class NativeAudioProcessor {
  late final DynamicLibrary _dylib;

  late final CalculateMelFilterbankDart _calculateMelFilterbank;
  late final FreeMelFilterbankMemoryDart _freeMelFilterbankMemory;

  // To store the pointer to the native filterbank memory if fetched
  Pointer<Float>? _nativeFilterbankPointer;
  int _filterbankRows = 0;
  int _filterbankCols = 0;

  NativeAudioProcessor() {
    if (Platform.isIOS || Platform.isMacOS) {
      _dylib = DynamicLibrary.process();
    } else {
      // For other platforms, you might need to load the library differently:
      // if (Platform.isAndroid) {
      //   _dylib = DynamicLibrary.open("libaudioprocessor.so");
      // } else if (Platform.isWindows) {
      //   _dylib = DynamicLibrary.open("audioprocessor.dll");
      // } // etc.
      throw Exception("Unsupported platform for FFI in this example. Define library loading for other platforms.");
    }

    _calculateMelFilterbank = _dylib
        .lookup<NativeFunction<CalculateMelFilterbankNative>>('calculate_mel_filterbank')
        .asFunction();
    _freeMelFilterbankMemory = _dylib
        .lookup<NativeFunction<FreeMelFilterbankMemoryNative>>('free_mel_filterbank_memory')
        .asFunction();

    print("NativeAudioProcessor: FFI functions (calculate_mel_filterbank, free_mel_filterbank_memory) looked up.");
  }

  Future<List<List<double>>?> fetchAndStoreMelFilterbank({
    required int nFft,
    required int nMels,
    required double sampleRate,
    required double fMin,
    double? fMax, // fMax is optional, defaults to sampleRate / 2.0 in Swift if not provided or invalid
  }) async {
    print("NativeAudioProcessor: Requesting Mel filterbank from Swift (SR: $sampleRate, nFFT: $nFft, nMels: $nMels)...");

    // Free any previously allocated filterbank
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
        print("NativeAudioProcessor: Native function calculate_mel_filterbank returned null pointer.");
        return null;
      }

      _filterbankRows = outRows.value;
      _filterbankCols = outCols.value;
      _nativeFilterbankPointer = filterbankPtr;

      print("NativeAudioProcessor: Mel filterbank received from Swift. Dimensions: $_filterbankRows x $_filterbankCols");

      if (_filterbankRows <= 0 || _filterbankCols <= 0) {
        print("NativeAudioProcessor: Mel filterbank dimensions from native are invalid.");
        releaseMelFilterbankMemory(); // Free the invalid pointer if it was allocated
        return null;
      }
      if (_filterbankRows != nMels) {
        print("NativeAudioProcessor: WARNING - nMels mismatch. Requested: $nMels, Loaded: $_filterbankRows");
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
      print("NativeAudioProcessor: Error in fetchAndStoreMelFilterbank: $e");
      if (_nativeFilterbankPointer != null) {
        releaseMelFilterbankMemory(); // Attempt to free if pointer was assigned
      }
      rethrow;
    } finally {
      calloc.free(outRows);
      calloc.free(outCols);
    }
  }

  /// Releases the memory allocated by the native code for the Mel filterbank.
  void releaseMelFilterbankMemory() {
    if (_nativeFilterbankPointer != null) {
      print("NativeAudioProcessor: Releasing native Mel filterbank memory.");
      _freeMelFilterbankMemory(_nativeFilterbankPointer!.cast<Void>());
      _nativeFilterbankPointer = null;
      _filterbankRows = 0;
      _filterbankCols = 0;
    }
  }

  // --- Mel Spectrogram functionality is removed as it's not in AudioProcessor.swift ---
  // Future<List<List<double>>> getMelSpectrogram(...) async { ... }

  // --- Classification placeholder remains, but it won't get a spectrogram from this FFI ---
  Future<String> classifyOnDevice(List<List<double>>? melSpectrogramFeatures, String modelTitle) async {
    print("NativeAudioProcessor: classifyOnDevice called (SIMULATED). Model: $modelTitle");
    if (melSpectrogramFeatures == null || melSpectrogramFeatures.isEmpty) {
      print("NativeAudioProcessor: No features to classify.");
      return "Error: No features";
    }
    // Simulate model inference
    await Future.delayed(Duration(milliseconds: 50 + Random().nextInt(100)));
    final List<String> possibleResults = ["Blues", "Classical", "Rock", "Pop", "No Match"];
    return possibleResults[Random().nextInt(possibleResults.length)];
  }


  void dispose() {
    print("NativeAudioProcessor: dispose called. Releasing native resources.");
    releaseMelFilterbankMemory();
    // Any other cleanup
  }
}