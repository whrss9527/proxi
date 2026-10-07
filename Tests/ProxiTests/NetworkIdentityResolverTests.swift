import XCTest
@testable import Proxi

final class NetworkIdentityResolverTests: XCTestCase {
    @MainActor
    func testIncompleteIdentityIsRetriedBeforeMatchingOtherNetwork() async {
        var reads = 0, probes: [String] = []
        let incomplete = NetworkIdentity(routerIP: "192.168.1.1")
        let complete = NetworkIdentity(routerIP: "192.168.1.1", routerMAC: "aa:bb:cc:dd:ee:ff")
        let resolver = NetworkIdentityResolver(read: {
            reads += 1
            return reads < 3 ? incomplete : complete
        }, probe: { probes.append($0) }, pause: {})
        let identity = await resolver.resolve()
        let company = NetworkRule(match: .router("aa:bb:cc:dd:ee:ff"), action: .profile(UUID()))
        let other = NetworkRule(match: .other, action: .off)
        XCTAssertEqual(identity, complete)
        XCTAssertEqual(NetworkRule.firstMatch([company, other], identity: identity)?.id, company.id)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(probes, ["192.168.1.1", "192.168.1.1"])
        XCTAssertFalse(identity.awaitingRouterMAC)
    }

    @MainActor
    func testExhaustedIdentityIsNotFinalAndLaterMACCanMatchAgain() async {
        var identity = NetworkIdentity(routerIP: "192.168.1.1")
        var reads = 0
        let resolver = NetworkIdentityResolver(read: { reads += 1; return identity }, probe: { _ in }, pause: {})
        let first = await resolver.resolve()
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(first.awaitingRouterMAC)
        identity.routerMAC = "aa:bb:cc:dd:ee:ff"
        let second = await resolver.resolve()
        XCTAssertEqual(reads, 4)
        XCTAssertFalse(second.awaitingRouterMAC)
        XCTAssertEqual(second.routerMAC, identity.routerMAC)
    }

    @MainActor
    func testNoIPv4GatewayOrAlreadyKnownMACDoesNotProbe() async {
        for identity in [NetworkIdentity(), NetworkIdentity(routerIP: "fe80::1"),
                         NetworkIdentity(routerIP: "192.168.1.1", routerMAC: "aa:bb:cc:dd:ee:ff")] {
            var reads = 0
            let resolver = NetworkIdentityResolver(read: { reads += 1; return identity }, probe: { _ in XCTFail() }, pause: {})
            let resolved = await resolver.resolve()
            XCTAssertEqual(resolved, identity)
            XCTAssertEqual(reads, 1)
        }
    }
}
