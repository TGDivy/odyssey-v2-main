import Foundation
import OdysseyData
import Testing

@Test
func sha256MatchesKnownAnswersAcrossIncrementalBoundaries() {
    #expect(
        SHA256Digest.hexDigest(of: Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
        SHA256Digest.hexDigest(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    let longMessage = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    var hasher = SHA256Digest.Hasher()
    for byte in longMessage.utf8 {
        hasher.update(Data([byte]))
    }
    #expect(
        hasher.hexDigest()
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )

    var millionByteHasher = SHA256Digest.Hasher()
    let block = Data(repeating: 0x61, count: 1_000)
    for _ in 0 ..< 1_000 {
        millionByteHasher.update(block)
    }
    #expect(
        millionByteHasher.hexDigest()
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    )
}

@Test
func sha256StreamsFilesWithoutDependingOnReadChunkSize() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-sha256-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("fixture.bin", isDirectory: false)
    let bytes = Data((0 ..< 4_097).map { UInt8($0 % 251) })
    try bytes.write(to: fileURL)
    let expected = SHA256Digest.hexDigest(of: bytes)

    #expect(try SHA256Digest.hexDigest(ofFileAt: fileURL, chunkSize: 1) == expected)
    #expect(try SHA256Digest.hexDigest(ofFileAt: fileURL, chunkSize: 63) == expected)
    #expect(try SHA256Digest.hexDigest(ofFileAt: fileURL, chunkSize: 1_024) == expected)
    #expect(throws: SHA256DigestError.invalidChunkSize) {
        try SHA256Digest.hexDigest(ofFileAt: fileURL, chunkSize: 0)
    }
}
