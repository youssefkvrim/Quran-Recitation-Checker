import Foundation

private let fftSize = 512
private let preemph = 0.97
private let lowFreq = 20.0
private let highFreq = 7600.0
private let logFloor = 1.1920929e-7
private let trimExtra = 1600
private let nyquistBins = fftSize / 2
private let frameLength = Audio.frameLength
private let frameShift = Audio.frameShift
private let bins = Audio.fbankBins

private let povey: [Double] = (0..<frameLength).map { i in
  pow(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameLength - 1)), 0.85)
}

private func hzToMel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }

private struct MelFilter {
  var firstBin: Int
  var weights: [Double]
}

private let melFilters: [MelFilter] = {
  let melLow = hzToMel(lowFreq)
  let melHigh = hzToMel(highFreq)
  let points = (0..<(bins + 2)).map { melLow + Double($0) * (melHigh - melLow) / Double(bins + 1) }
  let binHz = Double(Audio.sampleRate) / Double(fftSize)
  return (0..<bins).map { b in
    let left = points[b], center = points[b + 1], right = points[b + 2]
    var weights: [Double] = []
    var first = -1
    for k in 0..<nyquistBins {
      let mel = hzToMel(Double(k) * binHz)
      if !(mel > left && mel < right) { continue }
      weights.append(mel < center ? (mel - left) / (center - left) : (right - mel) / (right - center))
      if first < 0 { first = k }
    }
    return MelFilter(firstBin: max(first, 0), weights: weights)
  }
}()

/// Unscaled in-place radix-2 FFT of 512 points (same recurrence as the reference).
private func fft512(_ re: UnsafeMutableBufferPointer<Double>, _ im: UnsafeMutableBufferPointer<Double>) {
  let n = fftSize
  var j = 0
  for i in 1..<n {
    var bit = n >> 1
    while j & bit != 0 {
      j ^= bit
      bit >>= 1
    }
    j ^= bit
    if i < j {
      re.swapAt(i, j)
      im.swapAt(i, j)
    }
  }
  var len = 2
  while len <= n {
    let ang = -2 * Double.pi / Double(len)
    let wlenRe = cos(ang)
    let wlenIm = sin(ang)
    let half = len >> 1
    var i = 0
    while i < n {
      var wRe = 1.0
      var wIm = 0.0
      for k in 0..<half {
        let ur = re[i + k], ui = im[i + k]
        let xr = re[i + k + half], xi = im[i + k + half]
        let vr = xr * wRe - xi * wIm
        let vi = xr * wIm + xi * wRe
        re[i + k] = ur + vr
        im[i + k] = ui + vi
        re[i + k + half] = ur - vr
        im[i + k + half] = ui - vi
        let nwRe = wRe * wlenRe - wIm * wlenIm
        wIm = wRe * wlenIm + wIm * wlenRe
        wRe = nwRe
      }
      i += len
    }
    len <<= 1
  }
}

/// Streaming Kaldi log-mel filterbank (spec §1): 80 bins, 25 ms / 10 ms,
/// povey window, `snip_edges=false`. Frames come out flat, 80 floats each.
public final class KaldiFbank {
  private var buffer: [Float] = []
  private var sampleOffset = 0
  private var framesProduced = 0
  private var trueLength = 0
  private var window = [Double](repeating: 0, count: frameLength)
  private var fftRe = [Double](repeating: 0, count: fftSize)
  private var fftIm = [Double](repeating: 0, count: fftSize)

  public init() {}

  /// Append samples; returns every frame whose last sample now exists.
  public func acceptWaveform<C: Collection<Float>>(_ samples: C) -> [Float] {
    buffer.append(contentsOf: samples)
    trueLength = sampleOffset + buffer.count
    var out: [Float] = []
    while framesProduced * frameShift + 280 <= sampleOffset + buffer.count {
      computeFrame(framesProduced, streamEnd: nil, into: &out)
      framesProduced += 1
    }
    trim()
    return out
  }

  /// End of stream: the remaining frames, reflecting past the true end.
  public func inputFinished() -> [Float] {
    let n = trueLength
    let total = (n + frameShift / 2) / frameShift
    var out: [Float] = []
    while framesProduced < total {
      computeFrame(framesProduced, streamEnd: n, into: &out)
      framesProduced += 1
    }
    return out
  }

  public func reset() {
    buffer.removeAll()
    sampleOffset = 0
    framesProduced = 0
    trueLength = 0
  }

  private func trim() {
    let firstNeeded = max(0, framesProduced * frameShift - 120)
    let extra = firstNeeded - sampleOffset
    if extra <= trimExtra { return }
    buffer.removeFirst(extra)
    sampleOffset += extra
  }

  private func computeFrame(_ f: Int, streamEnd n: Int?, into out: inout [Float]) {
    let start = f * frameShift - 120
    window.withUnsafeMutableBufferPointer { win in
      buffer.withUnsafeBufferPointer { buf in
        for i in 0..<frameLength {
          var s = start + i
          while s < 0 || (n != nil && s >= n!) {
            if s < 0 { s = -s - 1 } else { s = 2 * n! - 1 - s }
          }
          win[i] = Double(buf[s - sampleOffset])
        }
      }
      var mean = 0.0
      for i in 0..<frameLength { mean += win[i] }
      mean /= Double(frameLength)
      for i in 0..<frameLength { win[i] -= mean }
      var i = frameLength - 1
      while i >= 1 {
        win[i] -= preemph * win[i - 1]
        i -= 1
      }
      win[0] -= preemph * win[0]
      fftRe.withUnsafeMutableBufferPointer { re in
        fftIm.withUnsafeMutableBufferPointer { im in
          for k in 0..<fftSize {
            re[k] = k < frameLength ? win[k] * povey[k] : 0
            im[k] = 0
          }
          fft512(re, im)
          for filter in melFilters {
            var energy = 0.0
            for (w, weight) in filter.weights.enumerated() {
              let k = filter.firstBin + w
              energy += (re[k] * re[k] + im[k] * im[k]) * weight
            }
            out.append(Float(log(max(energy, logFloor))))
          }
        }
      }
    }
  }
}
