// File: ios/libs/custom_resampler/resampler.h

#ifndef CUSTOM_RESAMPLER_H
#define CUSTOM_RESAMPLER_H

// Define int64_t if not available or use long if that's what your .c file uses for frames
// For cross-platform consistency with Dart's int, int64_t from <stdint.h> is good.
// However, the .c file uses `long` for input_frames and the return type.
// Let's stick to `long` to match the .c file's signature for now.
// #include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Declaration for resample_audio
// Ensure this matches the definition in resampler.c
// Attributes are important for visibility in release builds.
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((visibility("default"))) __attribute__((used))
    long resample_audio(const float* input_buffer, long input_frames,
                        float* output_buffer, long output_frames_capacity,
                        double src_ratio);
#else
    // Fallback for other compilers: ensure the function is exported
    // The specific mechanism might vary (e.g., __declspec(dllexport) on Windows for DLLs)
    // For static linking into an executable, this simple declaration might be enough if
    // the linker is configured to include it.
    long resample_audio(const float* input_buffer, long input_frames,
                        float* output_buffer, long output_frames_capacity,
                        double src_ratio);
#endif

#ifdef __cplusplus
}
#endif

#endif // CUSTOM_RESAMPLER_H 