#ifndef AUDIO_PROCESSOR_BINDINGS_H
#define AUDIO_PROCESSOR_BINDINGS_H

#include <stdint.h> // For int32_t
#include <stddef.h> // For NULL // Should be <cstddef> for C++ or <stddef.h> for C

#ifdef __cplusplus
extern "C" {
#endif

// --- Mel Filterbank Calculation Function ---
// Corresponds to Swift's calculate_mel_filterbank
// Returns a pointer to the calculated filterbank data.
// The caller is responsible for freeing this memory using free_mel_filterbank_memory.
float* calculate_mel_filterbank(
    int32_t n_fft,
    int32_t n_mels,
    float sr,
    float f_min,
    float f_max,
    int32_t* out_rows, // Output: number of rows in the filterbank (should be n_mels)
    int32_t* out_cols  // Output: number of columns in the filterbank (should be 1 + n_fft / 2)
);

// --- Memory Freeing Function for the Mel Filterbank ---
// Corresponds to Swift's free_mel_filterbank_memory
void free_mel_filterbank_memory(void* ptr);

#ifdef __cplusplus
}
#endif

#endif // AUDIO_PROCESSOR_BINDINGS_H