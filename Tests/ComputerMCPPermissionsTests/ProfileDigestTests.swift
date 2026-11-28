import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsProfileDigestTests {
  @Test func canonicalEncodingPreservesPersistedArrayOrdering() {
    #expect(ProfileDigest.canonical([2, 10, 1, 2]) == "[1,10,2,2]")
    #expect(
      ProfileDigest.canonical(["z": [[3, 1], [2]], "a": [[], [10, 2]]])
        == #"{"a":[[10,2],[]],"z":[[1,3],[2]]}"#)
    #expect(
      ProfileDigest.canonical([["b": "two", "a": "one"], ["a": "zero"]])
        == #"[{"a":"one","b":"two"},{"a":"zero"}]"#)
  }

  @Test func standardSHA256Vectors() {
    #expect(
      ProfileDigest.hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(
      ProfileDigest.hash("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
      ProfileDigest.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  }
  @Test func frozenSHA256BoundaryVectors() {
    #expect(
      ProfileDigest.hash(String(repeating: "a", count: 55))
        == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
    #expect(
      ProfileDigest.hash(String(repeating: "a", count: 56))
        == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    #expect(
      ProfileDigest.hash(String(repeating: "a", count: 63))
        == "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34")
    #expect(
      ProfileDigest.hash(String(repeating: "a", count: 64))
        == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    #expect(
      ProfileDigest.hash(String(repeating: "a", count: 65))
        == "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0")
    #expect(
      ProfileDigest.hash(String(repeating: "长い文字🙂\0", count: 40))
        == "53e68559adf77244e8e54d48b0cafc6d827af2d9a6d158c404f87a634d65a9a9")
    #expect(
      ProfileDigest.hash("286")
        == "00328ce57bbc14b33bd6695bc8eb32cdf2fb5f3a7d89ec14a42825e15d39df60")
  }

  // Fixed persisted consents protect compatibility independently of current consent issuance.
  @Test func baselineLedgerConsentAndInputsRemainCompatible() throws {
    func fixture(_ name: String, extension fileExtension: String) throws -> URL {
      try #require(
        Bundle.module.url(
          forResource: name, withExtension: fileExtension, subdirectory: "Fixtures/PersistedConsent"
        ))
    }

    let bytes = try Data(contentsOf: fixture("ledger", extension: "json"))
    var ledger = try JSONDecoder().decode(PermissionLedger.self, from: bytes)
    try ledger.validatePersistedState()
    let principals: [Principal] = [
      .client("baseline-client"), .plugin(.package("baseline-provider")),
    ]
    let profiles = ["client-profile", "plugin-profile"]
    let digests = [
      "61d540546f330bd4d71f2fdd9609a5ace37a1dc0310f33b7193f7cda8d8f5486",
      "a66ea3d27557d7afcef412e1f140cef5a260f7322c0b72c5687e6bb630e254b2",
    ]
    for index in principals.indices {
      let input = try String(
        contentsOf: fixture(profiles[index], extension: "txt"), encoding: .utf8)
      #expect(ProfileDigest.hash(input) == digests[index])
      let consent = try #require(ledger.environment.modes[principals[index]])
      #expect(consent.profileDigest == digests[index])
      #expect(ledger.isConsentValid(consent, for: principals[index]))
    }
    for principal in principals {
      let consent = try #require(ledger.environment.modes[principal])
      try ledger.setPermission(
        .granted(.access), for: .screen, principal: principal,
        expectedRevision: ledger.revision)
      #expect(!ledger.isConsentValid(consent, for: principal))
    }
  }
}
