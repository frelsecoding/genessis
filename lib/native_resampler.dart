import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef ResampleAudioNative = Int64 Function(
    Pointer<Float> inputBuffer,
    Int64 inputFrames,
    Pointer<Float> outputBuffer,
    Int64 outputFramesCapacity,
    Double srcRatio);

typedef ResampleAudioDart = int Function(
    Pointer<Float> inputBuffer,
    int inputFrames,
    Pointer<Float> outputBuffer,
    int outputFramesCapacity,
    double srcRatio);

class NativeResampler {
  late ResampleAudioDart _resampleAudio;
  bool _isInitialized = false;

  NativeResampler() {
    debugPrint("NativeResampler: Constructor called.");
    _load();
  }

  void _load() {
    debugPrint("NativeResampler: _load() called.");
    try {
      final DynamicLibrary nativeLib = _openDynamicLibrary();
      debugPrint("NativeResampler: Dynamic library opened successfully.");
      _resampleAudio = nativeLib
          .lookup<NativeFunction<ResampleAudioNative>>('resample_audio')
          .asFunction<ResampleAudioDart>();
      _isInitialized = true;
      debugPrint("NativeResampler: FFI function 'resample_audio' looked up. Initialization SUCCESSFUL.");
    } catch (e) {
      _isInitialized = false;
      debugPrint("NativeResampler: FFI lookup FAILED. Error: $e");
    }
  }

  DynamicLibrary _openDynamicLibrary() {
    if (Platform.isMacOS || Platform.isIOS) {
      debugPrint("NativeResampler: Opening DynamicLibrary.process() for iOS/macOS.");
      return DynamicLibrary.process();
    } else if (Platform.isAndroid) {
      debugPrint("NativeResampler: Opening 'libnative_resampler.so' for Android.");
      return DynamicLibrary.open('libnative_resampler.so');
    } else if (Platform.isLinux) {
      debugPrint("NativeResampler: Opening 'libnative_resampler.so' for Linux.");
      return DynamicLibrary.open('libnative_resampler.so');
    } else if (Platform.isWindows) {
      debugPrint("NativeResampler: Opening 'native_resampler.dll' for Windows.");
      return DynamicLibrary.open('native_resampler.dll');
    }
    debugPrint("NativeResampler: ERROR - Unsupported platform for native resampling.");
    throw UnsupportedError('Unsupported platform for native resampling');
  }

  List<double>? resample(List<double> inputAudio, int inputSampleRate, int outputSampleRate) {
    debugPrint("NativeResampler: resample() called. Initialized: $_isInitialized");
    if (!_isInitialized) {
      debugPrint("NativeResampler: Not initialized, cannot resample.");
      return null;
    }
    if (inputAudio.isEmpty || inputSampleRate <= 0 || outputSampleRate <= 0) {
      debugPrint("NativeResampler: Invalid parameters for resampling. Input empty: ${inputAudio.isEmpty}, Input SR: $inputSampleRate, Output SR: $outputSampleRate");
      return null;
    }

    if (inputSampleRate == outputSampleRate) {
      debugPrint("NativeResampler: Input and output sample rates are the same ($inputSampleRate Hz). No resampling needed.");
      return List.from(inputAudio);
    }

    final double srcRatio = outputSampleRate / inputSampleRate;
    final int inputFrames = inputAudio.length;
    final int estimatedOutputFrames = (inputFrames * srcRatio).ceil() + 10;
    debugPrint("NativeResampler: Resampling $inputFrames frames from $inputSampleRate Hz to $outputSampleRate Hz (ratio: $srcRatio). Estimated output frames: $estimatedOutputFrames");

    final Pointer<Float> inputPtr = calloc<Float>(inputFrames);
    final Pointer<Float> outputPtr = calloc<Float>(estimatedOutputFrames);
    debugPrint("NativeResampler: Native memory allocated (input: $inputFrames floats, output: $estimatedOutputFrames floats).");

    final inputList = inputPtr.asTypedList(inputFrames);
    for (int i = 0; i < inputFrames; i++) {
      inputList[i] = inputAudio[i];
    }
    debugPrint("NativeResampler: Input audio copied to native memory.");

    List<double>? result;
    try {
      debugPrint("NativeResampler: Calling native 'resample_audio' function...");
      final int outputFramesGenerated = _resampleAudio(
        inputPtr,
        inputFrames,
        outputPtr,
        estimatedOutputFrames,
        srcRatio,
      );
      debugPrint("NativeResampler: Native 'resample_audio' returned: $outputFramesGenerated frames.");

      if (outputFramesGenerated >= 0) {
        final outputList = outputPtr.asTypedList(outputFramesGenerated);
        result = List<double>.from(outputList);
        debugPrint("NativeResampler: Resampling successful. Output frames: ${result.length}");
      } else {
        debugPrint("NativeResampler: Native resampling function indicated an error (returned < 0).");
        result = null;
      }
    } catch (e) {
      debugPrint("NativeResampler: Exception during native call or data copy: $e");
      result = null;
    } finally {
      calloc.free(inputPtr);
      calloc.free(outputPtr);
      debugPrint("NativeResampler: Native memory freed.");
    }
    return result;
  }

  void dispose() {
    debugPrint("NativeResampler: dispose() called. Setting _isInitialized to false.");
    _isInitialized = false;
  }
}