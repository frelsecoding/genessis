// AudioProcessor.swift

import Foundation
import Accelerate // For vDSP

// MARK: - Librosa-Style Slaney (Piece-wise) Helper Functions

fileprivate func librosaSlaneyHzToMel(_ hz: Float) -> Float {
    // Matches librosa.core.convert.hz_to_mel for htk=False (Slaney Auditory Toolbox)
    let f_min_slaney: Float = 0.0       // Librosa's internal f_min for this formula part
    let f_sp_slaney: Float = 200.0 / 3.0  // Librosa's internal f_sp for this formula part

    var mels = (hz - f_min_slaney) / f_sp_slaney // Linear part initially

    // Log-scale part for frequencies >= 1000 Hz
    let min_log_hz_slaney: Float = 1000.0
    // Mel value at 1000 Hz using the linear formula part: (1000 - 0) / (200/3) = 15.0
    let min_log_mel_slaney: Float = (min_log_hz_slaney - f_min_slaney) / f_sp_slaney
    let logstep_slaney: Float = log(6.4) / 27.0 // log is natural log (base e)

    if hz >= min_log_hz_slaney {
        mels = min_log_mel_slaney + log(hz / min_log_hz_slaney) / logstep_slaney
    }
    return mels
}

fileprivate func librosaSlaneyMelToHz(_ mel: Float) -> Float {
    // Matches librosa.core.convert.mel_to_hz for htk=False (Slaney Auditory Toolbox)
    let f_min_slaney: Float = 0.0
    let f_sp_slaney: Float = 200.0 / 3.0

    var freqs = f_min_slaney + f_sp_slaney * mel // Linear part initially

    // Log-scale part for mels >= min_log_mel_slaney (which is 15.0)
    let min_log_hz_slaney: Float = 1000.0
    let min_log_mel_slaney: Float = (min_log_hz_slaney - f_min_slaney) / f_sp_slaney
    let logstep_slaney: Float = log(6.4) / 27.0

    if mel >= min_log_mel_slaney {
        freqs = min_log_hz_slaney * exp(logstep_slaney * (mel - min_log_mel_slaney))
    }
    return freqs
}


fileprivate func fftFrequencies(sr: Float, nFFT: Int) -> [Float] {
    let numBins = 1 + nFFT / 2
    return (0..<numBins).map { Float($0) * sr / Float(nFFT) }
}

// This function calculates the Mel boundary frequencies in HERTZ
fileprivate func calculateLibrosaMelBoundaryHz(
    nMelsForBoundaries: Int, // This will be nMelBands + 2
    fMin: Float,
    fMax: Float
) -> [Float] {

    // 1. Convert fMin and fMax to Librosa's Slaney Mel scale
    let minMel = librosaSlaneyHzToMel(fMin)
    let maxMel = librosaSlaneyHzToMel(fMax)

//    print("Swift: calculateLibrosaMelBoundaryHz: Using Librosa-Slaney minMel=\(minMel), maxMel=\(maxMel)")

    if nMelsForBoundaries <= 1 {
        if nMelsForBoundaries == 1 { return [librosaSlaneyMelToHz(minMel)] }
        return [] // Should not happen if nMelBands > 0
    }

    // 2. Create linearly spaced points in THAT Mel scale
    var intermediateMelPoints = [Float](repeating: 0.0, count: nMelsForBoundaries)
    if nMelsForBoundaries > 1 { // Denominator (nMelsForBoundaries - 1) must not be zero
        let step = (maxMel - minMel) / Float(nMelsForBoundaries - 1)
        for i in 0..<nMelsForBoundaries {
            intermediateMelPoints[i] = minMel + Float(i) * step
        }
    } else if nMelsForBoundaries == 1 { // Only one point
         intermediateMelPoints[0] = minMel
    }
    
//    print("Swift: calculateLibrosaMelBoundaryHz: Calculated intermediateMelPoints (First 5 based on Librosa-Slaney range): \(intermediateMelPoints.prefix(5))")

    // 3. Convert these intermediate Mel points back to Hertz using Librosa's Slaney MelToHz
    return intermediateMelPoints.map { librosaSlaneyMelToHz($0) }
}

// Helper to print a slice of an array (for cleaner logs)
//fileprivate func printSlice<T>(_ array: [T], name: String, first: Int = 5, last: Int = 5) {
//    if array.isEmpty { print("Swift:    \(name): (empty array)"); return }
//    let count = array.count; print("Swift:    \(name) (count: \(count)):")
//    if count <= first + last { print("Swift:      \(array)") }
//    else { print("Swift:      First \(first): \(array.prefix(first))"); print("Swift:      Last  \(last): \(array.suffix(last))") }
//}

// Helper to print a slice of weightsBuffer
fileprivate func printWeightsSlice( _ buffer: UnsafeMutablePointer<Float>, rows: Int, cols: Int, filterIndex: Int, numValues: Int, label: String) {
    if rows <= filterIndex || filterIndex < 0 { print("Swift:    \(label) (filter \(filterIndex)): Invalid filter index."); return }
    var slice: [Float] = []; let actualNumValues = min(numValues, cols)
    if actualNumValues <= 0 { print("Swift:    \(label) (filter \(filterIndex)): No values to print."); return }
    for k in 0..<actualNumValues { slice.append(buffer[filterIndex * cols + k]) }
//    print("Swift:    \(label) (filter \(filterIndex), first \(actualNumValues) values): \(slice)")
}


// MARK: - C-Exported Functions

@_cdecl("calculate_mel_filterbank")
public func calculate_mel_filterbank(
    param_n_fft: Int32,
    param_n_mels: Int32,
    param_sr: Float,
    param_f_min: Float,
    param_f_max: Float,
    out_rows: UnsafeMutablePointer<Int32>,
    out_cols: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<Float>? {

//    print("\nSwift: --- Start calculate_mel_filterbank (Librosa Slaney Replication) ---")
//    print("Swift: Input Params: N_FFT=\(param_n_fft), N_MELS=\(param_n_mels), SR=\(param_sr), FMIN=\(param_f_min), FMAX=\(param_f_max)")

    let nMelBands = Int(param_n_mels)
    let fftSize = Int(param_n_fft)
    let sampleRate = param_sr
    let fMin = param_f_min
    var fMax = param_f_max

    // Parameter validation
    if nMelBands <= 0 || fftSize <= 0 || sampleRate <= 0 { print("Swift Error: Invalid base params."); out_rows.pointee = 0; out_cols.pointee = 0; return nil }
    if fMin < 0 || fMax < 0 { print("Swift Error: Invalid freq params (negative)."); out_rows.pointee = 0; out_cols.pointee = 0; return nil }
    if fMax <= 0.0 || fMax > sampleRate / 2.0 { fMax = sampleRate / 2.0; print("Swift: fMax adjusted to Nyquist: \(fMax)") }
    if fMin > fMax { print("Swift Error: fMin (\(fMin)) > fMax (\(fMax))."); out_rows.pointee = 0; out_cols.pointee = 0; return nil }
    if fMin == fMax && nMelBands > 1 { print("Swift Error: fMin == fMax but >1 Mel band."); out_rows.pointee=0; out_cols.pointee=0; return nil}

    let numOutputFftBins = 1 + fftSize / 2
    out_rows.pointee = Int32(nMelBands)
    out_cols.pointee = Int32(numOutputFftBins)

    let totalElements = nMelBands * numOutputFftBins
    if totalElements <= 0 { print("Swift Error: totalElements <= 0."); out_rows.pointee = 0; out_cols.pointee = 0; return nil }
    let weightsBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalElements)
    weightsBuffer.initialize(repeating: 0.0, count: totalElements)
    print("Swift: Allocated weightsBuffer for \(totalElements) floats.")

    // --- STAGE 1: FFT bin frequencies ---
    let fftOutputFreqs = fftFrequencies(sr: sampleRate, nFFT: fftSize)
    guard fftOutputFreqs.count == numOutputFftBins else {
        print("Swift Error: fftOutputFreqs count mismatch."); weightsBuffer.deallocate(); out_rows.pointee = 0; out_cols.pointee = 0; return nil
    }
    print("\nSwift: 1. fftOutputFreqs")
//    printSlice(fftOutputFreqs, name: "fftOutputFreqs")

    // --- STAGE 2: Mel boundary frequencies (in Hz) ---
    // calculateLibrosaMelBoundaryHz uses the newly defined librosaSlaneyHzToMel and librosaSlaneyMelToHz
    let melBoundaryFreqsInHz = calculateLibrosaMelBoundaryHz( // Renamed for clarity
        nMelsForBoundaries: nMelBands + 2, // n_mels + 2 points
        fMin: fMin,
        fMax: fMax
    )
    guard melBoundaryFreqsInHz.count == nMelBands + 2 else {
        print("Swift Error: melBoundaryFreqsInHz count mismatch."); weightsBuffer.deallocate(); out_rows.pointee = 0; out_cols.pointee = 0; return nil
    }
    print("\nSwift: 2. melBoundaryFreqsInHz (for filter construction) - FINAL HZ VALUES")
//    printSlice(melBoundaryFreqsInHz, name: "melBoundaryFreqsInHz")

    // --- STAGE 3: Differences (fdiff) ---
    var fdiff = [Float](repeating: 0.0, count: melBoundaryFreqsInHz.count - 1)
    for i in 0..<fdiff.count {
        fdiff[i] = melBoundaryFreqsInHz[i+1] - melBoundaryFreqsInHz[i]
        if abs(fdiff[i]) < Float.ulpOfOne * 100 { // Stability for very small/zero differences
            let replacementFdiff = fdiff[i] < 0 ? -Float.ulpOfOne * 100 : Float.ulpOfOne * 100
            // print("Swift Warning: fdiff element at index \(i) is very small (\(fdiff[i])). Replacing with \(replacementFdiff).")
            fdiff[i] = replacementFdiff
        }
    }
//    print("\nSwift: 3. fdiff")
//    printSlice(fdiff, name: "fdiff")

    // --- STAGE 4: Construct UNNORMALIZED triangular filters ---
    for i in 0..<nMelBands {
        for k in 0..<numOutputFftBins {
            let currentFftFreq = fftOutputFreqs[k]
            // Uses melBoundaryFreqsInHz which are already in Hz
            let lowerSlopeVal = (currentFftFreq - melBoundaryFreqsInHz[i]) / fdiff[i]
            let upperSlopeVal = (melBoundaryFreqsInHz[i+2] - currentFftFreq) / fdiff[i+1]
            let triangularVal = max(0.0, min(lowerSlopeVal, upperSlopeVal))
            weightsBuffer[i * numOutputFftBins + k] = triangularVal
        }
    }
    print("\nSwift: 4. UNNORMALIZED Mel filter weights:")
    printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: 0, numValues: 10, label: "Unnorm")
    if nMelBands > 1 {
        let midFilterIdx = nMelBands / 2
        printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: midFilterIdx, numValues: 10, label: "Unnorm")
        printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: nMelBands - 1, numValues: 10, label: "Unnorm")
    }

    // --- STAGE 5: Slaney normalization factors (enorm) ---
    var enorm = [Float](repeating: 0.0, count: nMelBands)
    for i in 0..<nMelBands {
        // enorm = 2.0 / (mel_f[2 : n_mels + 2] - mel_f[:n_mels])
        // This means (melBoundaryFreqsInHz[i+2] - melBoundaryFreqsInHz[i])
        let melBandWidth = melBoundaryFreqsInHz[i+2] - melBoundaryFreqsInHz[i]
        if melBandWidth > Float.ulpOfOne * 100 {
            enorm[i] = 2.0 / melBandWidth
        } else {
            enorm[i] = 0.0
            // print("Swift Warning: Mel band width for Slaney norm is zero or very small for filter \(i).")
        }
    }
//    print("\nSwift: 5. 'enorm' (Slaney normalization factors)")
//    printSlice(enorm, name: "enorm")

    // --- STAGE 6: Apply Slaney normalization ---
    for i in 0..<nMelBands {
        let normFactor = enorm[i]
        let rowStartPointer = weightsBuffer.advanced(by: i * numOutputFftBins)
        vDSP_vsmul(rowStartPointer, 1, [normFactor], rowStartPointer, 1, vDSP_Length(numOutputFftBins))
    }
    print("\nSwift: 6. FINAL NORMALIZED Mel filter weights (after Slaney):")
    printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: 0, numValues: 10, label: "Norm")
    if nMelBands > 1 {
        let midFilterIdx = nMelBands / 2
        printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: midFilterIdx, numValues: 10, label: "Norm")
        printWeightsSlice(weightsBuffer, rows: nMelBands, cols: numOutputFftBins, filterIndex: nMelBands - 1, numValues: 10, label: "Norm")
    }
    
    print("\nSwift: --- Mel filterbank calculation complete (Librosa Slaney Replication) ---")
    return weightsBuffer
}

@_cdecl("free_mel_filterbank_memory")
public func free_mel_filterbank_memory(ptr: UnsafeMutableRawPointer?) {
    print("Swift: free_mel_filterbank_memory called for ptr: \(String(describing: ptr))")
    if let validPtr = ptr {
        validPtr.deallocate()
        print("Swift: Memory deallocated.")
    } else {
        print("Swift: Received null ptr in free_mel_filterbank_memory, nothing to deallocate.")
    }
}
