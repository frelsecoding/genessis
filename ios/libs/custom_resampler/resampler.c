#include "resampler.h"
#include "samplerate.h" // This MUST be findable by your compiler
#include <stdio.h>
#include <stdlib.h>

// The function definition now directly uses the attributes for visibility
// and matches the header declaration style.
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((visibility("default"))) __attribute__((used))
    long resample_audio(const float* input_buffer, long input_frames,
                        float* output_buffer, long output_frames_capacity,
                        double src_ratio)
#else
    // Fallback for other compilers, ensuring the function is defined.
    long resample_audio(const float* input_buffer, long input_frames,
                        float* output_buffer, long output_frames_capacity,
                        double src_ratio)
#endif
{
    if (input_buffer == NULL || output_buffer == NULL || input_frames <= 0 || output_frames_capacity <= 0 || src_ratio <= 0.0) {
        return -1;
    }

    SRC_DATA src_data;
    src_data.data_in = input_buffer;
    src_data.input_frames = input_frames;
    src_data.data_out = output_buffer;
    src_data.output_frames = output_frames_capacity;
    src_data.src_ratio = src_ratio;
    src_data.end_of_input = 1; // Mark the entire input as a single block

    // SRC_SINC_FASTEST is quick, SRC_SINC_BEST_QUALITY is slower but better.
    int converter_type = SRC_SINC_FASTEST; 
    int error = src_simple(&src_data, converter_type, 1); // 1 channel

    if (error != 0) {
        fprintf(stderr, "libsamplerate error: %s\n", src_strerror(error));
        return -1; // Indicates an error during resampling
    }

    // Return the number of frames actually written to the output buffer
    return src_data.output_frames_gen;
}
