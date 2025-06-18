import Accelerate
import Foundation

@_cdecl("reduce_noise_spectral_subtraction")
public func reduce_noise_spectral_subtraction(
    noisy_audio_ptr: UnsafeMutablePointer<Float>?,
    audio_length: Int32,
    sample_rate_in: Int32,
    noise_profile_ptr: UnsafeMutablePointer<Float>?,
    noise_profile_length: Int32,
    n_fft: Int32,
    hop_length: Int32,
    over_subtraction_factor: Float,
    spectral_floor_factor: Float,
    output_audio_ptr: UnsafeMutablePointer<Float>?
) -> Int32 {

    print("SwiftNR: --- reduce_noise_spectral_subtraction called ---")
    print("SwiftNR: Received params: audio_length=\(audio_length), n_fft=\(n_fft), hop_length=\(hop_length)")
    print("SwiftNR: overs_sub_factor=\(over_subtraction_factor), spectral_floor_factor=\(spectral_floor_factor)")

    guard let noisy_audio_ptr = noisy_audio_ptr,
          let noise_profile_ptr = noise_profile_ptr,
          let output_audio_ptr = output_audio_ptr else {
        print("SwiftNR: Nil pointer received.")
        return -1 // Error: Nil pointers
    }

    if audio_length <= 0 || n_fft <= 0 || hop_length <= 0 || noise_profile_length <= 0 {
        print("SwiftNR: Invalid audio_length (\(audio_length)), n_fft (\(n_fft)), hop_length (\(hop_length)), or noise_profile_length (\(noise_profile_length)).")
        return -2 // Error: Invalid parameters
    }

    // n_fft must be a positive power of 2.
    // Check if n_fft is positive and if n_fft & (n_fft - 1) == 0 (which is true for powers of 2)
    if n_fft <= 0 || (n_fft & (n_fft - 1)) != 0 {
        print("SwiftNR: n_fft must be a positive power of 2 for this Accelerate FFT implementation. Got \(n_fft).")
        // Copy input to output if params are bad, to avoid crash and allow app to continue
        output_audio_ptr.assign(from: noisy_audio_ptr, count: Int(audio_length))
        return -2
    }

    let expected_profile_len_for_current_n_fft = n_fft / 2 + 1
    if noise_profile_length != expected_profile_len_for_current_n_fft {
        print("SwiftNR: Warning: noise_profile_length (\(noise_profile_length)) " +
              "does not match expected length for n_fft=\(n_fft) (i.e., \(expected_profile_len_for_current_n_fft)). " +
              "Ensure profile is compatible. Proceeding with caution.")
        // Depending on how critical this is, you might return an error or try to adapt.
        // For now, we proceed. The spectral subtraction loop has a bounds check.
    }

    let noisyAudio = UnsafeBufferPointer(start: noisy_audio_ptr, count: Int(audio_length))
    let noiseProfilePower = UnsafeBufferPointer(start: noise_profile_ptr, count: Int(noise_profile_length))
    let outputAudioBuffer = UnsafeMutableBufferPointer(start: output_audio_ptr, count: Int(audio_length))
    outputAudioBuffer.initialize(repeating: 0.0)

    // Print some info about the noise profile
    if noise_profile_length > 0 {
        var avgNoiseProfilePower: Float = 0.0
        var maxNoiseProfilePower: Float = 0.0
        vDSP_meanv(noise_profile_ptr, 1, &avgNoiseProfilePower, vDSP_Length(noise_profile_length))
        vDSP_maxv(noise_profile_ptr, 1, &maxNoiseProfilePower, vDSP_Length(noise_profile_length))
        print("SwiftNR: Noise Profile (length: \(noise_profile_length)): Avg Power=\(avgNoiseProfilePower), Max Power=\(maxNoiseProfilePower)")
        if noise_profile_length > 10 {
            let firstFewNoiseVals = UnsafeBufferPointer(start: noise_profile_ptr, count: 10).map { String(format: "%.4e", $0) }.joined(separator: ", ")
            print("SwiftNR: First 10 noise profile values: [\(firstFewNoiseVals)]")
        }
    }

    let frameCount = (Int(audio_length) - Int(n_fft)) / Int(hop_length) + 1
    if frameCount <= 0 {
        print("SwiftNR: Not enough audio data for even one frame (audio_length: \(audio_length), n_fft: \(n_fft)). Copying input to output.")
        for i in 0..<Int(audio_length) { outputAudioBuffer[i] = noisyAudio[i] }
        return 0 // Successfully did nothing but copy
    }

    var hannWindow = [Float](repeating: 0.0, count: Int(n_fft))
    vDSP_hann_window(&hannWindow, vDSP_Length(n_fft), Int32(vDSP_HANN_NORM))

    // For real FFTs with vDSP, log2n is based on n_fft / 2 (number of complex pairs)
    // This is used for both vDSP_create_fftsetup and vDSP_fft_zip.
    let log2n = vDSP_Length(floor(log2(Float(n_fft / 2))))
    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        print("SwiftNR: Failed to create FFT setup with log2n = \(log2n) for n_fft = \(n_fft).")
        // Copy input to output
        output_audio_ptr.assign(from: noisy_audio_ptr, count: Int(audio_length))
        return -3
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    // Temporary buffers for FFT
    var realIn = [Float](repeating: 0.0, count: Int(n_fft / 2))
    var imagIn = [Float](repeating: 0.0, count: Int(n_fft / 2))
    var complexBufferIn = DSPSplitComplex(realp: &realIn, imagp: &imagIn)

    var realOut = [Float](repeating: 0.0, count: Int(n_fft / 2))
    var imagOut = [Float](repeating: 0.0, count: Int(n_fft / 2))
    var complexBufferOut = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
    
    var tempOverlapAddBuffer = [Float](repeating: 0.0, count: Int(audio_length))
    var sumOfSquaresWindowOLA = [Float](repeating: 0.0, count: Int(audio_length))


    for frameIndex in 0..<frameCount {
        let frameStart = frameIndex * Int(hop_length)
        var currentFrame = [Float](repeating: 0.0, count: Int(n_fft))

        // 1. Apply window to frame
        for i in 0..<Int(n_fft) {
            currentFrame[i] = noisyAudio[frameStart + i] * hannWindow[i]
        }

        currentFrame.withUnsafeBufferPointer { currentFramePtr in
            currentFramePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Int(n_fft / 2)) { dspComplexPtr in
                vDSP_ctoz(dspComplexPtr, 2, &complexBufferIn, 1, vDSP_Length(n_fft / 2))
            }
        }
        vDSP_fft_zop(fftSetup, &complexBufferIn, vDSP_Stride(1), &complexBufferOut, vDSP_Stride(1), log2n, FFTDirection(FFT_FORWARD))

        // 3. Calculate Power Spectrum & Store Original Phase
        var noisyPowerMag = [Float](repeating: 0.0, count: Int(n_fft / 2 + 1)) // Magnitude spectrum
        var originalPhase = [Float](repeating: 0.0, count: Int(n_fft / 2 + 1))

        // DC component
        let dcReal = complexBufferOut.realp[0]
        noisyPowerMag[0] = abs(dcReal) // Magnitude for DC
        originalPhase[0] = dcReal < 0 ? .pi : 0.0


        // Nyquist component (stored in imagp[0] for real FFTs by vDSP_fft_zip)
        let nyquistReal = complexBufferOut.imagp[0]
        noisyPowerMag[Int(n_fft / 2)] = abs(nyquistReal) // Magnitude for Nyquist
        originalPhase[Int(n_fft / 2)] = nyquistReal < 0 ? .pi : 0.0


        for k in 1..<Int(n_fft / 2) {
            let real = complexBufferOut.realp[k]
            let imag = complexBufferOut.imagp[k]
            noisyPowerMag[k] = sqrt(real * real + imag * imag) // Magnitude
            originalPhase[k] = atan2(imag, real)
        }

        // 4. Spectral Subtraction (on magnitude)
        var cleanedMagnitude = [Float](repeating: 0.0, count: Int(n_fft / 2 + 1))
        for k in 0...Int(n_fft / 2) {
            let noisyM = noisyPowerMag[k]
            let noiseP_k_profile_val = (k < noiseProfilePower.count) ? noiseProfilePower[k] : 0.0 
            
            let noisyP_k_signal = noisyM * noisyM
            
            var estimatedCleanP = noisyP_k_signal - (over_subtraction_factor * noiseP_k_profile_val)
            
            let floor = spectral_floor_factor * noisyP_k_signal 
            estimatedCleanP = max(estimatedCleanP, floor)
            estimatedCleanP = max(estimatedCleanP, 0.0) 

            cleanedMagnitude[k] = sqrt(estimatedCleanP) 

            if frameIndex < 2 && k % (Int(n_fft)/16) == 0 { // Print for first 2 frames, and only some bins
                print("SwiftNR: Frame \(frameIndex), Bin \(k): NoisyMag=\(String(format: "%.3e", noisyM)), NoisyPow=\(String(format: "%.3e", noisyP_k_signal)), NoiseProfilePow=\(String(format: "%.3e", noiseP_k_profile_val)), EstCleanPow=\(String(format: "%.3e", estimatedCleanP)), FinalCleanMag=\(String(format: "%.3e", cleanedMagnitude[k]))")
            }
        }
        
        // 5. Reconstruct Complex Spectrum (using original phase and cleaned magnitude)
        // DC
        complexBufferIn.realp[0] = cleanedMagnitude[0] * cos(originalPhase[0]) // cos is 1 or -1
        complexBufferIn.imagp[0] = 0 // Imaginary part of DC is zero for real signals

        // Nyquist
        // For vDSP, the Nyquist component is stored in imagp[0] of the input to IFFT
        // if it's to be treated as real.
        complexBufferIn.imagp[0] = cleanedMagnitude[Int(n_fft/2)] * cos(originalPhase[Int(n_fft/2)])


        for k in 1..<Int(n_fft / 2) {
            complexBufferIn.realp[k] = cleanedMagnitude[k] * cos(originalPhase[k])
            complexBufferIn.imagp[k] = cleanedMagnitude[k] * sin(originalPhase[k])
        }

        // 6. IFFT
        vDSP_fft_zop(fftSetup, &complexBufferIn, vDSP_Stride(1), &complexBufferOut, vDSP_Stride(1), log2n, FFTDirection(FFT_INVERSE))

        // Convert back from split complex and scale
        var timeDomainCleanedFrame = [Float](repeating: 0.0, count: Int(n_fft))
        // vDSP_ztoc expects UnsafeMutablePointer<DSPComplex>. We have UnsafeMutablePointer<Float>.
        // We need to rebind the memory temporarily for the call.
        // The output array `timeDomainCleanedFrame` will receive n_fft Float elements.
        // `vDSP_ztoc` will write `n_fft / 2` complex pairs (which is `n_fft` Floats).
        timeDomainCleanedFrame.withUnsafeMutableBufferPointer { timeDomainCleanedFramePtr in
            timeDomainCleanedFramePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Int(n_fft / 2)) { dspComplexMutablePtr in
                vDSP_ztoc(&complexBufferOut, 1, dspComplexMutablePtr, 2, vDSP_Length(n_fft / 2))
            }
        }

        // Scale IFFT output: vDSP_fft_zip (inverse) does not scale by 1/N.
        // The typical scaling is 1/N for IFFT(FFT(x)) = x.
        // However, the vDSP_fft_zip seems to require 1/(2N) for real signals.
        // Let's use 1/N first and verify this specific scaling factor.
        // A common scaling factor after vDSP_ztoc (from IFFT) is 0.5 / N_fft
        var scaleIFFT = 1.0 / Float(n_fft) // Common scaling for IFFT
        // var scaleIFFT = 0.5 / Float(n_fft) // Alternative vDSP specific for real signals
        
        // Create a new buffer for the scaled output to avoid overlapping access
        var scaledTimeDomainFrame = [Float](repeating: 0.0, count: Int(n_fft))
        vDSP_vsmul(&timeDomainCleanedFrame, 1, &scaleIFFT, &scaledTimeDomainFrame, 1, vDSP_Length(n_fft))
        
        // 7. Overlap-Add
        // Apply synthesis window (same as analysis window for Hann)
        for i in 0..<Int(n_fft) {
            let windowedSample = scaledTimeDomainFrame[i] * hannWindow[i] // Apply synthesis window
            tempOverlapAddBuffer[frameStart + i] += windowedSample
            sumOfSquaresWindowOLA[frameStart + i] += hannWindow[i] * hannWindow[i]
        }
    }

    // Normalize by sum of squares of the window for OLA
    for i in 0..<Int(audio_length) {
        if sumOfSquaresWindowOLA[i] > Float.ulpOfOne { 
            outputAudioBuffer[i] = tempOverlapAddBuffer[i] / sumOfSquaresWindowOLA[i]
        } else if i < tempOverlapAddBuffer.count { 
             outputAudioBuffer[i] = tempOverlapAddBuffer[i] 
        }
        if i < 10 && frameCount > 0 { // Print first 10 samples of sumOfSquaresWindowOLA and output for the first processed chunk
            print("SwiftNR: OLA Debug: i=\(i), sumSqWin=\(String(format: "%.3e", sumOfSquaresWindowOLA[i])), tempOLA=\(String(format: "%.3e", tempOverlapAddBuffer[i])), output=\(String(format: "%.3e", outputAudioBuffer[i]))")
        }
    }
    
    // Optional: Check for NaN/Inf in output, replace with 0
    for i in 0..<outputAudioBuffer.count {
        if outputAudioBuffer[i].isNaN || outputAudioBuffer[i].isInfinite {
            outputAudioBuffer[i] = 0.0
        }
    }

    print("SwiftNR: Noise reduction processing completed successfully.")
    return 0 // Success
}

// Helper for debugging
/* // Removing this as we are using print() directly now
func debugPrint(_ string: String) {
    #if DEBUG
    print(string)
    #endif
}
*/
