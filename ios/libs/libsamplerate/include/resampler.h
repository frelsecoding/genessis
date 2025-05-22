#ifndef RESAMPLER_H
#define RESAMPLER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

long resample_audio(const float* input_buffer, long input_frames,
                    float* output_buffer, long output_frames_capacity,
                    double src_ratio);

#ifdef __cplusplus
}
#endif

#endif