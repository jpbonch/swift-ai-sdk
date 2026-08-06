import Foundation

public func resampleAudio(
    _ input: [Float],
    inputRate: Int,
    outputRate: Int
) -> [Float] {
    guard inputRate > 0, outputRate > 0, inputRate != outputRate else { return input }
    guard input.count > 1 else { return input }

    let ratio = Double(outputRate) / Double(inputRate)
    let outputCount = max(Int((Double(input.count) * ratio).rounded()), 1)
    var output = [Float](repeating: 0, count: outputCount)

    let step = Double(input.count - 1) / Double(max(outputCount - 1, 1))
    for index in 0..<outputCount {
        let position = Double(index) * step
        let lower = Int(position)
        let upper = min(lower + 1, input.count - 1)
        let fraction = Float(position - Double(lower))
        output[index] = input[lower] + (input[upper] - input[lower]) * fraction
    }
    return output
}

public func resampleAudio(
    _ input: Data,
    inputRate: Int,
    outputRate: Int
) -> Data {
    let samples = decodePCM16(input)
    let resampled = resampleAudio(samples, inputRate: inputRate, outputRate: outputRate)
    return encodePCM16(resampled)
}

public func decodePCM16(_ data: Data) -> [Float] {
    let sampleCount = data.count / 2
    guard sampleCount > 0 else { return [] }
    var samples = [Float](repeating: 0, count: sampleCount)
    data.withUnsafeBytes { raw in
        for index in 0..<sampleCount {
            let low = UInt16(raw[index * 2])
            let high = UInt16(raw[index * 2 + 1])
            let value = Int16(bitPattern: low | (high << 8))
            samples[index] = Float(value) / 32768
        }
    }
    return samples
}

public func encodePCM16(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let clamped = max(-1, min(1, sample))
        let value = Int16(clamping: Int((clamped * 32767).rounded()))
        let bits = UInt16(bitPattern: value)
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
    }
    return data
}
