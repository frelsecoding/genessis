#include "resampler.h"
#include "samplerate.h" // This MUST be findable by your compiler
#include <stdio.h>
#include <stdlib.h>

#if defined(__GNUC__) || defined(__clang__)
    long resample_audio(const float* input_buffer, long input_frames,
                        float* output_buffer, long output_frames_capacity,
                        double src_ratio) __attribute__((used));
#endif

long resample_audio(const float* input_buffer, long input_frames,
                    float* output_buffer, long output_frames_capacity,
                    double src_ratio) {

    if (input_buffer == NULL || output_buffer == NULL || input_frames <= 0 || output_frames_capacity <= 0 || src_ratio <= 0.0) {
        return -1;
    }

    SRC_DATA src_data;
    src_data.data_in = input_buffer;
    src_data.input_frames = input_frames;
    src_data.data_out = output_buffer;
    src_data.output_frames = output_frames_capacity;
    src_data.src_ratio = src_ratio;
    src_data.end_of_input = 1;

    int converter_type = SRC_SINC_FASTEST; // Use SRC_SINC_BEST_QUALITY for higher quality but slower
    int error = src_simple(&src_data, converter_type, 1);

    if (error != 0) {
        fprintf(stderr, "libsamplerate error: %s\n", src_strerror(error));
        return -1;
    }
    return src_data.output_frames_gen;
}
