// Alignment (spec §6). The reference engine computes in float64 and stores
// cells in float32 arrays, comparing candidates against the stored value; these
// ports do exactly that (`Float(Double(a) + b)`), so results are bit-identical.

public struct SemiGlobalResult: Equatable, Sendable {
  public var cost: Float
  public var distance: Double
  public var refStart: Int
  public var refEnd: Int
  public var queryStart: Int
}

private let indel: Double = 1

/// Global weighted Levenshtein cost (float32 cells).
public func weightedLevenshtein<A: Collection<UInt8>, B: Collection<UInt8>>(_ a: A, _ b: B, table: CostTable = .shared) -> Float {
  let a = Array(a), b = Array(b)
  let n = a.count, m = b.count
  if n == 0 && m == 0 { return 0 }
  var prev = [Float](repeating: 0, count: m + 1)
  var cur = [Float](repeating: 0, count: m + 1)
  for j in 0...m { prev[j] = Float(j) }
  table.matrix.withUnsafeBufferPointer { matrix in
    let size = table.size
    for i in 1...max(n, 1) where n > 0 {
      cur[0] = Float(i)
      let row = Int(a[i - 1]) * size
      for j in 1...max(m, 1) where m > 0 {
        var v = Float(Double(prev[j - 1]) + Double(matrix[row + Int(b[j - 1])]))
        let up = Double(prev[j]) + indel
        let left = Double(cur[j - 1]) + indel
        if up < Double(v) { v = Float(up) }
        if left < Double(v) { v = Float(left) }
        cur[j] = v
      }
      swap(&prev, &cur)
    }
  }
  return prev[m]
}

/// `weightedLevenshtein / max(|a|, |b|)`; 0 for two empties, 1 if exactly one is empty.
public func normalizedDistance<A: Collection<UInt8>, B: Collection<UInt8>>(_ a: A, _ b: B, table: CostTable = .shared) -> Double {
  if a.isEmpty && b.isEmpty { return 0 }
  if a.isEmpty || b.isEmpty { return 1 }
  return Double(weightedLevenshtein(a, b, table: table)) / Double(max(a.count, b.count))
}

/// Needleman–Wunsch of `heard` onto `ref[from..<to]` with traceback: the ref
/// index each heard char was substituted onto, or -1 when it was inserted.
/// Traceback prefers diagonal, then up, then left.
public func alignGlobal(_ heard: [UInt8], _ ref: [UInt8], from: Int, to: Int, table: CostTable = .shared) -> [Int] {
  let n = heard.count
  let m = to - from
  var assign = [Int](repeating: -1, count: n)
  if n == 0 || m <= 0 { return assign }
  let cols = m + 1
  var c = [Float](repeating: 0, count: (n + 1) * cols)
  var t = [UInt8](repeating: 0, count: (n + 1) * cols)
  for j in 0...m { c[j] = Float(j) }
  for i in 1...n { c[i * cols] = Float(i) }
  table.matrix.withUnsafeBufferPointer { matrix in
    ref.withUnsafeBufferPointer { ref in
      c.withUnsafeMutableBufferPointer { c in
        t.withUnsafeMutableBufferPointer { t in
          let size = table.size
          for i in 1...n {
            let row = Int(heard[i - 1]) * size
            let r = i * cols
            let p = (i - 1) * cols
            for j in 1...m {
              var v = Float(Double(c[p + j - 1]) + Double(matrix[row + Int(ref[from + j - 1])]))
              var tr: UInt8 = 0
              let up = Double(c[p + j]) + indel
              let left = Double(c[r + j - 1]) + indel
              if up < Double(v) {
                v = Float(up)
                tr = 1
              }
              if left < Double(v) {
                v = Float(left)
                tr = 2
              }
              c[r + j] = v
              t[r + j] = tr
            }
          }
        }
      }
    }
  }
  var i = n
  var j = m
  while i > 0 || j > 0 {
    if i == 0 {
      j -= 1
      continue
    }
    if j == 0 {
      assign[i - 1] = -1
      i -= 1
      continue
    }
    switch t[i * cols + j] {
    case 0:
      assign[i - 1] = from + j - 1
      i -= 1
      j -= 1
    case 1:
      assign[i - 1] = -1
      i -= 1
    default:
      j -= 1
    }
  }
  return assign
}

/// Semi-global alignment for search verification (spec §6.3): the query must be
/// consumed to its end, may start and end anywhere in `ref[from..<to]`, and may
/// skip a prefix of itself at `headSkipCost` per char.
public func alignSemiGlobal(
  _ query: [UInt8], _ ref: [UInt8], from: Int, to: Int,
  table: CostTable = .shared, headSkipCost: Double = 0.5
) -> SemiGlobalResult {
  let n = query.count
  let m = max(0, to - from)
  if n == 0 { return SemiGlobalResult(cost: 0, distance: 1, refStart: from, refEnd: from, queryStart: 0) }
  var prevCost = [Float](repeating: 0, count: m + 1)
  var curCost = [Float](repeating: 0, count: m + 1)
  var prevStart = [Int32](repeating: 0, count: m + 1)
  var curStart = [Int32](repeating: 0, count: m + 1)
  var prevQ = [Int32](repeating: 0, count: m + 1)
  var curQ = [Int32](repeating: 0, count: m + 1)
  for j in 0...m { prevStart[j] = Int32(j) }
  let size = table.size
  table.matrix.withUnsafeBufferPointer { matrix in
    ref.withUnsafeBufferPointer { ref in
      for i in 1...n {
        let row = Int(query[i - 1]) * size
        let skip = Float(Double(i) * headSkipCost)
        curCost[0] = skip
        curStart[0] = 0
        curQ[0] = Int32(i)
        if m > 0 {
          for j in 1...m {
            let diag = Float(Double(prevCost[j - 1]) + Double(matrix[row + Int(ref[from + j - 1])]))
            let up = Float(Double(prevCost[j]) + indel)
            let left = Float(Double(curCost[j - 1]) + indel)
            var cost = diag
            var start = prevStart[j - 1]
            var q = prevQ[j - 1]
            if up < cost {
              cost = up
              start = prevStart[j]
              q = prevQ[j]
            }
            if left < cost {
              cost = left
              start = curStart[j - 1]
              q = curQ[j - 1]
            }
            if skip < cost {
              cost = skip
              start = Int32(j)
              q = Int32(i)
            }
            curCost[j] = cost
            curStart[j] = start
            curQ[j] = q
          }
        }
        swap(&prevCost, &curCost)
        swap(&prevStart, &curStart)
        swap(&prevQ, &curQ)
      }
    }
  }
  var bestJ = 0
  var best = prevCost[0]
  if m > 0 {
    for j in 1...m where prevCost[j] < best {
      best = prevCost[j]
      bestJ = j
    }
  }
  return SemiGlobalResult(
    cost: best,
    distance: Double(best) / Double(n),
    refStart: from + Int(prevStart[bestJ]),
    refEnd: from + bestJ,
    queryStart: Int(prevQ[bestJ])
  )
}
