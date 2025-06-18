// FeatureExtractor.swift
import Foundation
import Accelerate

fileprivate func printFE(_ message: String) {
     print("[FeatureExtractor Swift] \(message)") // Uncomment for debugging
}

fileprivate func normalizeAudioRMS(audioData: UnsafePointer<Float>, length: Int, targetRMS: Float) -> [Float] {
    // 1. Handle empty audio or invalid targetRMS
    if length == 0 || targetRMS <= 0.0 {
        if length > 0 {
            return Array(UnsafeBufferPointer(start: audioData, count: length)) // Return copy of original
        }
        return [] // Return empty if input is empty
    }

    // 2. Calculate current RMS of the input audio data using vDSP_rmsqv
    var currentRMS: Float = 0.0
    vDSP_rmsqv(audioData, 1, &currentRMS, vDSP_Length(length))

    // 3. Handle silence or very low RMS to avoid division by zero or extreme gains
    let epsilon: Float = 1e-7 // A small value to compare against
    if currentRMS < epsilon {
        // Audio is silent or near silent, no gain to apply or return as is (or scaled to targetRMS if it's also very small)
        // For simplicity, returning a copy, or you could return zeros scaled to targetRMS if that's desired.
        printFE("Normalization: Audio is silent or near silent (RMS: \(currentRMS)). Returning copy of original audio.")
        return Array(UnsafeBufferPointer(start: audioData, count: length))
    }

    // 4. Calculate the gain needed
    let gain = targetRMS / currentRMS
    
    // Optional: Cap the gain to prevent extreme amplification of very quiet signals
    let maxGain: Float = 15.0 // Example: limit gain to 15x (approx 23.5 dB)
    let cappedGain = min(gain, maxGain)
    printFE("Normalization: Current RMS: \(currentRMS), Target RMS: \(targetRMS), Calculated Gain: \(gain), Capped Gain: \(cappedGain)")


    // 5. Create a mutable copy of the audio data
    var normalizedAudio = [Float](repeating: 0.0, count: length)
    normalizedAudio.withUnsafeMutableBufferPointer { bufferPtr in
        guard let baseAddress = bufferPtr.baseAddress else {
            printFE("Error: Failed to get base address for mutable normalizedAudio buffer.")
            // In case of error, return original audio
            for i in 0..<length { bufferPtr[i] = audioData[i] }
            return
        }
        // Copy original data to mutable buffer
        cblas_scopy(Int32(length), audioData, 1, baseAddress, 1)
        
        // 6. Apply the gain using vDSP_vsmul
        // Using 'gain' directly, or 'cappedGain' if implementing gain capping
        var mutableGain = cappedGain // Use cappedGain
        vDSP_vsmul(baseAddress, 1, &mutableGain, baseAddress, 1, vDSP_Length(length))
    }
    
    // VERIFY new RMS (for debugging)
    var newRMS: Float = 0.0
    normalizedAudio.withUnsafeBufferPointer { ptr in
       if let base = ptr.baseAddress {
           if length > 0 { // Add check for length > 0 to avoid vDSP_rmsqv error on empty array
               vDSP_rmsqv(base, 1, &newRMS, vDSP_Length(length))
               printFE("Normalization: RMS after normalization: \(newRMS) (Target was: \(targetRMS), Gain Applied: \(cappedGain))")
           } else {
               printFE("Normalization: Audio length is 0 after normalization attempt, cannot calculate new RMS.")
           }
       }
    }

    return normalizedAudio
}

@_cdecl("calculate_log_mel_spectrogram")
public func calculate_log_mel_spectrogram(
    audio_data_ptr: UnsafePointer<Float>,
    audio_data_length: Int32,
    sample_rate: Int32,
    n_fft: Int32,
    hop_length: Int32,
    mel_filterbank_ptr: UnsafePointer<Float>,
    n_mels: Int32,
    num_freq_bins_in_fft_output: Int32, // This is n_fft / 2 + 1
    // Output parameters
    out_data_ptr: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
    out_n_mels: UnsafeMutablePointer<Int32>,
    out_num_frames: UnsafeMutablePointer<Int32>
) -> Void {

    printFE("--- Start calculate_log_mel_spectrogram (Corrected DSPSplitComplex, Using vvlog10f) ---")
    // --- 0. Initialize output parameters to error/default state ---
    out_data_ptr.pointee = nil
    out_n_mels.pointee = 0
    out_num_frames.pointee = 0

    // --- 1. Validate Input and Parameters ---
    let N_FFT = Int(n_fft)
    let HOP_LENGTH = Int(hop_length)
    let N_MELS = Int(n_mels)
    let AUDIO_LENGTH = Int(audio_data_length)
    
    let expected_fft_bins_in_filterbank = Int(num_freq_bins_in_fft_output)
    let calculated_fft_bins_for_stft = (N_FFT / 2) + 1

    guard calculated_fft_bins_for_stft == expected_fft_bins_in_filterbank else {
        print("Swift FeatureExtractor Error: Mismatch in FFT bin count. For STFT: \(calculated_fft_bins_for_stft), For Filterbank: \(expected_fft_bins_in_filterbank). Aborting.")
        return
    }
    guard AUDIO_LENGTH > 0 && N_FFT > 0 && HOP_LENGTH > 0 && N_MELS > 0 else {
        print("Swift FeatureExtractor Error: Invalid audio length or STFT/Mel parameters (<=0).")
        return
    }

    // let targetLinearRMS: Float = 0.1 // REVERTED from 0.05 back to 0.1

    // --- Normalize Audio (New Step) ---  >>> REMOVING THIS STEP TO MATCH PYTHON SCRIPT <<<
    // printFE("Normalizing audio to target RMS: \(targetLinearRMS)...")
    // let normalizedAudioSamples = normalizeAudioRMS(
    //     audioData: audio_data_ptr, 
    //     length: AUDIO_LENGTH,      
    //     targetRMS: targetLinearRMS
    // )
    // printFE("Normalization complete. Normalized audio length: \(normalizedAudioSamples.count)")

    // if normalizedAudioSamples.count > 20 { 
    //     let firstSamples = normalizedAudioSamples[0..<20].map { String(format: "%.4f", $0) }.joined(separator: ", ")
    //     printFE("First few normalized samples: \(firstSamples)")
    //     var checkRMS: Float = 0.0
    //     if normalizedAudioSamples.count > 0 { 
    //          vDSP_rmsqv(normalizedAudioSamples, 1, &checkRMS, vDSP_Length(normalizedAudioSamples.count))
    //          printFE("RMS of normalizedAudioSamples just before padding: \(checkRMS)")
    //     }
    // } else if normalizedAudioSamples.isEmpty {
    //     printFE("normalizedAudioSamples is EMPTY after normalization call!")
    // }

    // --- 2. Padding (using original audio_data_ptr) ---
    let padLength = N_FFT / 2
    var paddedAudio = [Float](repeating: 0.0, count: padLength)
    if AUDIO_LENGTH > 0 { 
        // paddedAudio.append(contentsOf: normalizedAudioSamples) // OLD when normalizing
        paddedAudio.append(contentsOf: UnsafeBufferPointer(start: audio_data_ptr, count: AUDIO_LENGTH)) // NEW: Use original audio
    }
    paddedAudio.append(contentsOf: [Float](repeating: 0.0, count: padLength))
    let paddedAudioLength = AUDIO_LENGTH + 2 * padLength 
    printFE("Original audio length: \(AUDIO_LENGTH), Padded audio length: \(paddedAudioLength)")

    // --- 3. Calculate Number of Frames --- 
    // Based on original unpadded audio length
    let numFrames = Int(floor(Double(AUDIO_LENGTH) / Double(HOP_LENGTH))) + 1
    if numFrames <= 0 {
        print("Swift FeatureExtractor Error: Not enough audio data for frames.")
        return
    }
    printFE("Calculated num_frames (from original audio): \(numFrames)")

    // --- 4. Prepare FFT Setup & Window ---
    var hannWindow = [Float](repeating: 0.0, count: N_FFT)
    vDSP_hann_window(&hannWindow, vDSP_Length(N_FFT), Int32(vDSP_HANN_NORM))

    let log2N = vDSP_Length(floor(log2(Float(N_FFT))))
    guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
        print("Swift FeatureExtractor Error: Failed to create FFT setup.")
        return
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    // Buffers for FFT output. Reused for each frame.
    var realp_fft_output = [Float](repeating: 0.0, count: N_FFT / 2)
    var imagp_fft_output = [Float](repeating: 0.0, count: N_FFT / 2)
    
    var melEnergiesFlat = [Float](repeating: 0.0, count: N_MELS * numFrames)
    var stftFrameProcessingErrorOccurred = false

    // --- 5. STFT Loop ---
    for frameIdx in 0..<numFrames {
        if stftFrameProcessingErrorOccurred { break }

        let startSampleInPadded = frameIdx * HOP_LENGTH
        guard startSampleInPadded + N_FFT <= paddedAudioLength else {
            print("Swift FeatureExtractor Warning: Frame \(frameIdx) calculation extends beyond padded audio. Skipping.")
            continue
        }

        var frame = Array(paddedAudio[startSampleInPadded..<(startSampleInPadded + N_FFT)])

        frame.withUnsafeMutableBufferPointer { frameBufferPtr_unsafe in
            guard let frameBaseAddress = frameBufferPtr_unsafe.baseAddress else {
                printFE("Error: Frame base address is nil for frame \(frameIdx)."); stftFrameProcessingErrorOccurred = true; return
            }
            hannWindow.withUnsafeBufferPointer { hannBufferPtr_unsafe in
                guard let hannBaseAddress = hannBufferPtr_unsafe.baseAddress else {
                    printFE("Error: Hann window base address is nil."); stftFrameProcessingErrorOccurred = true; return
                }
                vDSP_vmul(frameBaseAddress, 1, hannBaseAddress, 1, frameBaseAddress, 1, vDSP_Length(N_FFT))
                
                frameBaseAddress.withMemoryRebound(to: DSPComplex.self, capacity: N_FFT / 2) { dspComplexFramePtr in
                    realp_fft_output.withUnsafeMutableBufferPointer { rpBuff_unsafe in
                        imagp_fft_output.withUnsafeMutableBufferPointer { ipBuff_unsafe in
                            guard let rBase = rpBuff_unsafe.baseAddress, let iBase = ipBuff_unsafe.baseAddress else {
                                printFE("Error: FFT output buffer base address is nil for frame \(frameIdx)."); stftFrameProcessingErrorOccurred = true; return
                            }
                            var localSplitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)
                            vDSP_ctoz(dspComplexFramePtr, 2, &localSplitComplex, 1, vDSP_Length(N_FFT / 2))
                            vDSP_fft_zrip(fftSetup, &localSplitComplex, 1, log2N, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }
        }
        if stftFrameProcessingErrorOccurred { break }

        var powerSpectrum = [Float](repeating: 0.0, count: calculated_fft_bins_for_stft)
        powerSpectrum[0] = realp_fft_output[0] * realp_fft_output[0]
        if N_FFT % 2 == 0 { powerSpectrum[N_FFT / 2] = imagp_fft_output[0] * imagp_fft_output[0] }
        for k in 1..<(N_FFT / 2) { powerSpectrum[k] = realp_fft_output[k] * realp_fft_output[k] + imagp_fft_output[k] * imagp_fft_output[k] }
        
        for melIdx in 0..<N_MELS {
            var melEnergy: Float = 0.0
            let fbankRowOffset = melIdx * calculated_fft_bins_for_stft
            vDSP_dotpr(&powerSpectrum, 1, mel_filterbank_ptr.advanced(by: fbankRowOffset), 1, &melEnergy, vDSP_Length(calculated_fft_bins_for_stft))
            melEnergiesFlat[melIdx * numFrames + frameIdx] = melEnergy
        }
    }

    if stftFrameProcessingErrorOccurred { print("Swift FeatureExtractor: Error during STFT. Aborting."); return }
    printFE("Mel spectrogram raw energies calculated. Flat size: \(melEnergiesFlat.count)")

    // --- 6. Logarithmic Conversion (Power to dB) ---
    
    guard !melEnergiesFlat.isEmpty else { print("Swift Error: melEnergiesFlat empty before log conversion."); return }

    let amin: Float = 1e-10
    let top_db: Float = 80.0

    // --- REVERT TO S_ref_value logic to match librosa.power_to_db(ref=np.max) ---
    var S_ref_value: Float = 0.0
    if melEnergiesFlat.count > 0 { 
        vDSP_maxv(&melEnergiesFlat, 1, &S_ref_value, vDSP_Length(melEnergiesFlat.count))
    }
    printFE("Max raw Mel energy (S_ref_value): \(S_ref_value)") // Keep this for verification

    var S_clipped = melEnergiesFlat
    for i in 0..<S_clipped.count { S_clipped[i] = max(amin, S_clipped[i]) } // Clip to amin 
    let ref_value_clipped_scalar = max(amin, S_ref_value) // Reference is max of S_clipped (or amin)

    var S_div_ref = [Float](repeating: 0.0, count: S_clipped.count)
    if ref_value_clipped_scalar > Float.ulpOfOne * 100 { 
        var divisor = ref_value_clipped_scalar
        vDSP_vsdiv(&S_clipped, 1, &divisor, &S_div_ref, 1, vDSP_Length(S_clipped.count))
    } else {
        printFE("Warning: ref_value_clipped_scalar (\(ref_value_clipped_scalar)) is small. Manually computing S_div_ref.")
        for i in 0..<S_clipped.count {
            if ref_value_clipped_scalar > Float.ulpOfOne * 100 { S_div_ref[i] = S_clipped[i] / ref_value_clipped_scalar }
            else if S_clipped[i] > Float.ulpOfOne * 100 { S_div_ref[i] = Float.greatestFiniteMagnitude } // Avoid NaN if S_clipped[i] is large and ref is tiny
            else { S_div_ref[i] = 1.0 } // Both S_clipped[i] and ref are tiny, treat as S/ref = 1
        }
    }
    // Ensure S_div_ref values are positive for log operation, clipping very small/zero values to ulpOfOne.
    // This step is crucial if any S_clipped[i] was amin and ref_value_clipped_scalar was also amin, leading to S_div_ref[i] = 1,
    // or if S_clipped[i] was extremely small compared to ref_value_clipped_scalar.
    for i in 0..<S_div_ref.count { S_div_ref[i] = max(Float.ulpOfOne, S_div_ref[i]) }

    var log10_S_div_ref = [Float](repeating: 0.0, count: S_div_ref.count) // Renamed back
    var logOperationErrorOccurred = false 
    
    if !S_div_ref.isEmpty { // Operate on S_div_ref
        printFE("Using vvlog10f (C-API for log10) on S_div_ref")
        S_div_ref.withUnsafeBufferPointer { xPtr_unsafe in
            log10_S_div_ref.withUnsafeMutableBufferPointer { yPtr_unsafe in
                var n_elements = Int32(S_div_ref.count)
                guard let xBase = xPtr_unsafe.baseAddress, let yBase = yPtr_unsafe.baseAddress else {
                    printFE("Error: Nil buffer pointer for vvlog10f."); logOperationErrorOccurred = true; return
                }
                vvlog10f(yBase, xBase, &n_elements)
            }
        }
    }
    if logOperationErrorOccurred { print("Swift FeatureExtractor: Error during log10 operation (vvlog10f). Aborting."); return }

    var db_values = [Float](repeating: 0.0, count: log10_S_div_ref.count)
    let ten_scalar: Float = 10.0
    
    var mutable_log_input_for_mul = log10_S_div_ref // Use log10_S_div_ref
    vDSP_vsmul(&mutable_log_input_for_mul, 1, [ten_scalar], &db_values, 1, vDSP_Length(mutable_log_input_for_mul.count))

    var max_db_val: Float = -Float.infinity // This will be the max of (10 * log10(S/S_ref)), so should be 0.0
    if !db_values.isEmpty { 
        vDSP_maxv(&db_values, 1, &max_db_val, vDSP_Length(db_values.count))
    } else { 
        max_db_val = 0.0 
    }
    // printFE("Max dB after 10*log10(S_clipped): \(max_db_val)") // This log line is from the incorrect version
    printFE("Max dB (should be ~0.0 if ref=np.max logic is correct): \(max_db_val)") // Corrected log line
        
    let cutOff_db = max_db_val - top_db // e.g., 0.0 - 80.0 = -80.0
    for i in 0..<db_values.count { db_values[i] = max(db_values[i], cutOff_db) }

    melEnergiesFlat = db_values 
    // printFE("Log-Mel (dB) values finalized. Max dB after top_db logic: \(max_db_val), Cutoff was: \(cutOff_db)")
    printFE("Log-Mel (dB) values finalized. Peak dB: \(max_db_val), Cutoff applied at: \(cutOff_db)") // More descriptive

    // --- 7. Prepare Output Buffer ---
    let totalOutputElements = N_MELS * numFrames
    guard totalOutputElements > 0, melEnergiesFlat.count == totalOutputElements else {
        print("Swift Error: Final element count mismatch. Expected \(totalOutputElements), got \(melEnergiesFlat.count).")
        return
    }
    
    let outputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalOutputElements)
    outputBuffer.initialize(from: melEnergiesFlat, count: totalOutputElements)
    
    out_data_ptr.pointee = outputBuffer
    out_n_mels.pointee = Int32(N_MELS)
    out_num_frames.pointee = Int32(numFrames)

    printFE("--- End calculate_log_mel_spectrogram. Output dims: (\(N_MELS), \(numFrames)) ---")
}

@_cdecl("free_feature_extractor_memory")
public func free_feature_extractor_memory(ptr: UnsafeMutableRawPointer?) {
    printFE("free_feature_extractor_memory called for ptr: \(String(describing: ptr))")
    if let validPtr = ptr?.assumingMemoryBound(to: Float.self) {
        validPtr.deallocate()
        printFE("Feature memory deallocated.")
    } else {
        printFE("Received null or invalid ptr in free_feature_extractor_memory, nothing to deallocate.")
    }
}
