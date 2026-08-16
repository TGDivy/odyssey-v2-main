import Foundation

public enum SHA256DigestError: Error, Equatable, Sendable {
    case invalidChunkSize
    case invalidFileURL
}

public enum SHA256Digest {
    public struct Hasher: Sendable {
        private var state = SHA256Digest.initialState
        private var bufferedBytes: [UInt8] = []
        private var byteCount: UInt64 = 0

        public init() {}

        public mutating func update(_ data: Data) {
            byteCount &+= UInt64(data.count)
            var bytes = bufferedBytes
            bytes.append(contentsOf: data)
            let completeByteCount = bytes.count - (bytes.count % 64)
            if completeByteCount > 0 {
                for chunkStart in stride(from: 0, to: completeByteCount, by: 64) {
                    SHA256Digest.compress(
                        bytes[chunkStart ..< chunkStart + 64],
                        into: &state
                    )
                }
            }
            bufferedBytes = Array(bytes[completeByteCount...])
        }

        public func hexDigest() -> String {
            var copy = self
            return copy.finalizedHexDigest()
        }

        private mutating func finalizedHexDigest() -> String {
            var finalBytes = bufferedBytes
            let bitCount = byteCount &* 8
            finalBytes.append(0x80)
            while finalBytes.count % 64 != 56 {
                finalBytes.append(0)
            }
            finalBytes.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian) { Array($0) })
            for chunkStart in stride(from: 0, to: finalBytes.count, by: 64) {
                SHA256Digest.compress(
                    finalBytes[chunkStart ..< chunkStart + 64],
                    into: &state
                )
            }
            return state.map { String(format: "%08x", $0) }.joined()
        }
    }

    fileprivate static let initialState: [UInt32] = [
        0x6a09e667,
        0xbb67ae85,
        0x3c6ef372,
        0xa54ff53a,
        0x510e527f,
        0x9b05688c,
        0x1f83d9ab,
        0x5be0cd19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hexDigest(of data: Data) -> String {
        var hasher = Hasher()
        hasher.update(data)
        return hasher.hexDigest()
    }

    public static func hexDigest(
        ofFileAt fileURL: URL,
        chunkSize: Int = 64 * 1_024
    ) throws -> String {
        guard fileURL.isFileURL else {
            throw SHA256DigestError.invalidFileURL
        }
        guard chunkSize > 0 else {
            throw SHA256DigestError.invalidChunkSize
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = Hasher()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.hexDigest()
    }

    fileprivate static func compress(
        _ chunk: ArraySlice<UInt8>,
        into state: inout [UInt32]
    ) {
        precondition(chunk.count == 64)
        var schedule = [UInt32](repeating: 0, count: 64)
        let chunkStart = chunk.startIndex
        for wordIndex in 0 ..< 16 {
            let offset = chunkStart + (wordIndex * 4)
            schedule[wordIndex] = UInt32(chunk[offset]) << 24
                | UInt32(chunk[offset + 1]) << 16
                | UInt32(chunk[offset + 2]) << 8
                | UInt32(chunk[offset + 3])
        }
        for wordIndex in 16 ..< 64 {
            let first = schedule[wordIndex - 15]
            let second = schedule[wordIndex - 2]
            let smallSigma0 = rotateRight(first, by: 7)
                ^ rotateRight(first, by: 18)
                ^ (first >> 3)
            let smallSigma1 = rotateRight(second, by: 17)
                ^ rotateRight(second, by: 19)
                ^ (second >> 10)
            schedule[wordIndex] = schedule[wordIndex - 16]
                &+ smallSigma0
                &+ schedule[wordIndex - 7]
                &+ smallSigma1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for round in 0 ..< 64 {
            let bigSigma1 = rotateRight(e, by: 6)
                ^ rotateRight(e, by: 11)
                ^ rotateRight(e, by: 25)
            let choice = (e & f) ^ ((~e) & g)
            let firstTemporary = h
                &+ bigSigma1
                &+ choice
                &+ roundConstants[round]
                &+ schedule[round]
            let bigSigma0 = rotateRight(a, by: 2)
                ^ rotateRight(a, by: 13)
                ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let secondTemporary = bigSigma0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ firstTemporary
            d = c
            c = b
            b = a
            a = firstTemporary &+ secondTemporary
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
