import 'dart:ffi';
import 'dart:io'; // For Platform.isAndroid
import 'package:ffi/ffi.dart';

// Assuming your Swift function will be something like:
// reduce_noise_spectral_subtraction(
//     noisy_audio_ptr: UnsafeMutablePointer<Float>,
//     audio_length: Int32,
//     sample_rate: Int32,
//     noise_profile_ptr: UnsafeMutablePointer<Float>,
//     noise_profile_length: Int32,
//     n_fft: Int32,
//     hop_length: Int32,
//     over_subtraction_factor: Float,
//     spectral_floor_factor: Float,
//     output_audio_ptr: UnsafeMutablePointer<Float>
// ) -> Int32 (status code)

// Typedef for the C function
typedef ReduceNoiseSpectralSubtractionNative = Int32 Function(
    Pointer<Float> noisyAudio,
    Int32 audioLength,
    Int32 sampleRate,
    Pointer<Float> noiseProfile,
    Int32 noiseProfileLength,
    Int32 nFft,
    Int32 hopLength,
    Float overSubtractionFactor,
    Float spectralFloorFactor,
    Pointer<Float> outputAudio);

// Typedef for the Dart function
typedef ReduceNoiseSpectralSubtractionDart = int Function(
    Pointer<Float> noisyAudio,
    int audioLength,
    int sampleRate,
    Pointer<Float> noiseProfile,
    int noiseProfileLength,
    int nFft,
    int hopLength,
    double overSubtractionFactor,
    double spectralFloorFactor,
    Pointer<Float> outputAudio);

class NativeNoiseReducer {
  late ReduceNoiseSpectralSubtractionDart _reduceNoise;
  bool _isInitialized = false;

  NativeNoiseReducer() {
    try {
      final DynamicLibrary nativeLib = Platform.isAndroid
          ? DynamicLibrary.open("libnoise_reducer.so") // Example for Android
          : DynamicLibrary.process(); // Default for iOS/macOS

      _reduceNoise = nativeLib
          .lookup<NativeFunction<ReduceNoiseSpectralSubtractionNative>>(
              "reduce_noise_spectral_subtraction")
          .asFunction<ReduceNoiseSpectralSubtractionDart>();
      _isInitialized = true;
    } catch (e) {
      // Use a more robust way to check for debug mode if flutter/foundation is not available
      const bool kDebugMode = !bool.fromEnvironment("dart.vm.product");
      if (kDebugMode) {
        print("NativeNoiseReducer: Error initializing FFI: $e");
        print("NativeNoiseReducer: Ensure 'reduce_noise_spectral_subtraction' is compiled and linked.");
      }
      _isInitialized = false;
    }
  }

  List<double>? reduceNoise({
    required List<double> audioData,
    required int sampleRate,
    required List<double> noiseProfile,
    int nFft = 2048, // Default, adjust as needed
    int hopLength = 512, // Default, adjust as needed
    double overSubtractionFactor = 1.5, // Default, adjust as needed
    double spectralFloorFactor = 0.01, // Default, adjust as needed
  }) {
    if (!_isInitialized) {
      const bool kDebugMode = !bool.fromEnvironment("dart.vm.product");
      if (kDebugMode) print("NativeNoiseReducer: FFI not initialized. Cannot reduce noise.");
      return null;
    }
    if (audioData.isEmpty || noiseProfile.isEmpty) {
      const bool kDebugMode = !bool.fromEnvironment("dart.vm.product");
      if (kDebugMode) print("NativeNoiseReducer: Audio data or noise profile is empty.");
      return null;
    }

    final noisyAudioPtr = calloc<Float>(audioData.length);
    final noiseProfilePtr = calloc<Float>(noiseProfile.length);
    final outputAudioPtr = calloc<Float>(audioData.length);

    for (int i = 0; i < audioData.length; i++) {
      noisyAudioPtr[i] = audioData[i];
    }
    for (int i = 0; i < noiseProfile.length; i++) {
      noiseProfilePtr[i] = noiseProfile[i];
    }

    try {
      final status = _reduceNoise(
        noisyAudioPtr,
        audioData.length,
        sampleRate,
        noiseProfilePtr,
        noiseProfile.length,
        nFft,
        hopLength,
        overSubtractionFactor,
        spectralFloorFactor,
        outputAudioPtr,
      );

      if (status == 0) { // Assuming 0 means success
        final cleanedAudio = List<double>.filled(audioData.length, 0.0);
        for (int i = 0; i < audioData.length; i++) {
          cleanedAudio[i] = outputAudioPtr[i];
        }
        return cleanedAudio;
      } else {
        const bool kDebugMode = !bool.fromEnvironment("dart.vm.product");
        if (kDebugMode) print("NativeNoiseReducer: Noise reduction failed with status: $status");
        return null; // Indicate failure
      }
    } catch (e) {
        const bool kDebugMode = !bool.fromEnvironment("dart.vm.product");
        if (kDebugMode) print("NativeNoiseReducer: Exception during noise reduction: $e");
        return null;
    } finally {
      calloc.free(noisyAudioPtr);
      calloc.free(noiseProfilePtr);
      calloc.free(outputAudioPtr);
    }
  }

  void dispose() {
    // If you allocate any persistent resources in Swift that need explicit freeing,
    // add a corresponding FFI call here.
    // For now, this class primarily manages memory for each call via calloc,
    // which is freed in the finally block of reduceNoise.
  }
} 