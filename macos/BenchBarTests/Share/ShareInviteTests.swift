import Foundation
import Testing
@testable import BenchBar

nonisolated enum InviteFixture {
    static let hostHex = String(repeating: "ab", count: 32)
    static let salt = String(repeating: "00", count: 16)

    static func link(v: String = "1", room: String = "Standup", h: String = hostHex, s: String = salt, c: String = "482913",
                     a: String = "192.168.1.9:8443", x: Int = 1_800_003_600, extra: String = "") -> String {
        "benchbar://share/join?v=\(v)&r=\(room)&h=\(h)&s=\(s)&c=\(c)&a=\(a)&x=\(x)\(extra)"
    }

    static func invite(_ text: String = link()) -> ShareInvite? {
        guard let url = URL(string: text) else { return nil }
        return try? ShareInvite.parse(url).get()
    }
}

@Suite struct ShareInviteTests {
    @Test func aValidInviteParsesToItsFields() throws {
        let invite = try #require(InviteFixture.invite())
        #expect(invite.room == "Standup")
        #expect(invite.hostPin == Data(repeating: 0xab, count: 32))
        #expect(invite.salt == InviteFixture.salt)
        #expect(invite.code == "482913")
        #expect(invite.address == .init(host: "192.168.1.9", port: 8443))
        #expect(invite.expires == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(invite.check == .init(hostPin: Data(repeating: 0xab, count: 32), salt: InviteFixture.salt))
    }

    /// The shape `share invite` prints (c4a825c, tests/test-share-admin.sh): every value
    /// percent-encoded, a space as %20, the colon of `a` as %3A.
    @Test func theCLIsLinkParsesBackToItsFields() throws {
        let link = "benchbar://share/join?v=1&r=Caf%C3%A9%20%26%20Lab%3D1%20%22Q%22&h=\(InviteFixture.hostHex)&s=ffeeddccbbaa99887766554433221100&c=482913&a=192.168.1.20%3A8443&x=1800003600"
        let invite = try ShareInvite.parse(URL(string: link)!).get()
        #expect(invite.room == "Caf\u{e9} & Lab=1 \"Q\"")
        #expect(invite.salt == "ffeeddccbbaa99887766554433221100")
        #expect(invite.address == .init(host: "192.168.1.20", port: 8443))
        #expect(try ShareInvite.first(in: "Join my BenchBar room\n\(link)\nOr: open BenchBar").get() == invite)
    }

    @Test func percentEncodingAndUnknownParametersAreHandled() throws {
        let invite = try #require(InviteFixture.invite(InviteFixture.link(room: "Priya%E2%80%99s%20room%20%26%20co", extra: "&z=later&utm=1")))
        #expect(invite.room == "Priya\u{2019}s room & co")
        let hostile = try #require(InviteFixture.invite(InviteFixture.link(room: "A%E2%80%AEB%0Aend")))
        #expect(hostile.room == "A B end")
    }

    @Test func everyRequiredFieldMustBeThereAndWellFormed() {
        let broken = [
            "benchbar://share/join?v=1&h=\(InviteFixture.hostHex)&s=\(InviteFixture.salt)&c=482913&x=1800003600",
            "benchbar://share/join?v=1&r=R&s=\(InviteFixture.salt)&c=482913&x=1800003600",
            "benchbar://share/join?v=1&r=R&h=\(InviteFixture.hostHex)&c=482913&x=1800003600",
            "benchbar://share/join?v=1&r=R&h=\(InviteFixture.hostHex)&s=\(InviteFixture.salt)&x=1800003600",
            "benchbar://share/join?v=1&r=R&h=\(InviteFixture.hostHex)&s=\(InviteFixture.salt)&c=482913",
            "benchbar://share/join?r=R&h=\(InviteFixture.hostHex)&s=\(InviteFixture.salt)&c=482913&x=1800003600",
            InviteFixture.link(h: String(InviteFixture.hostHex.dropLast(2))),
            InviteFixture.link(h: String(repeating: "zz", count: 32)),
            InviteFixture.link(s: "00"),
            InviteFixture.link(c: "48291"),
            InviteFixture.link(c: "482%20913"),
            InviteFixture.link(c: "\u{0664}82913"),
            InviteFixture.link(x: -5),
            InviteFixture.link(extra: "&h=\(String(repeating: "cd", count: 32))"),
            "benchbar://share/joinx?v=1",
        ]
        for text in broken {
            #expect(ShareInvite.parse(URL(string: text)!) == .failure(.malformed), "\(text)")
        }
    }

    @Test func anotherVersionAsksForANewerBenchBar() {
        #expect(ShareInvite.parse(URL(string: InviteFixture.link(v: "2"))!) == .failure(.newerVersion))
        #expect(NetworkPanePresentation.inviteProblem(.newerVersion) == "This invite needs a newer BenchBar.")
    }

    @Test func theAddressIsOnlyAHintAndOnlyAnIPv4Literal() throws {
        for bad in ["evil.example:8443", "192.168.1.9", "192.168.1.9:0", "192.168.1.9:99999", "[::1]:8443", "192.168.1.9:84a"] {
            let invite = try #require(InviteFixture.invite(InviteFixture.link(a: bad)), "\(bad)")
            #expect(invite.address == nil, "\(bad)")
        }
    }

    @Test func theFirstInviteIsFoundInAChatMessage() throws {
        let link = InviteFixture.link()
        let slack = "Hey! <\(link)|Join Standup>. Thanks"
        let plain = "Join my BenchBar room \"Standup\" (office Wi-Fi, until 18:00)\n\(link).\nOr: open BenchBar → On your network → Paste invite"
        let quoted = "\"\(link)\""
        for text in [slack, plain, quoted] {
            let invite = try ShareInvite.first(in: text).get()
            #expect(invite.code == "482913" && invite.expires == Date(timeIntervalSince1970: 1_800_003_600), "\(text)")
        }
        let two = "\(InviteFixture.link(c: "111111")) then \(InviteFixture.link(c: "222222"))"
        #expect(try ShareInvite.first(in: two).get().code == "111111")
        #expect(ShareInvite.first(in: "no link here, just benchbar://share/0011223344556677/app") == .failure(.notFound))
        #expect(ShareInvite.first(in: "") == .failure(.notFound))
    }

    @Test func printingAnInviteNeverShowsTheCode() throws {
        let invite = try #require(InviteFixture.invite())
        var dumped = ""
        dump(invite, to: &dumped)
        for text in ["\(invite)", String(reflecting: invite), dumped, "\(Optional(invite) as Any)", "\([invite])"] {
            #expect(!text.contains("482913"), "\(text)")
        }
    }

    @Test func aShareLinkWithAQueryIsAnInviteAndNeverIgnored() throws {
        let invite = try #require(InviteFixture.invite())
        #expect(URLRouter.route(URL(string: InviteFixture.link())!, benches: [], selected: nil) == .shareInvite(.success(invite)))
        #expect(URLRouter.route(URL(string: InviteFixture.link(v: "2"))!, benches: [], selected: nil) == .shareInvite(.failure(.newerVersion)))
        // `.ignore` and `.explain` log the link; a query may hold a code.
        for text in ["benchbar://share/join?c=482913", "benchbar://share/0011223344556677/app?c=482913", "benchbar://SHARE/Join?v=1&c=482913"] {
            let outcome = URLRouter.route(URL(string: text)!, benches: [], selected: nil)
            #expect(outcome == .shareInvite(.failure(.malformed)), "\(text)")
        }
    }
}

@Suite struct InviteJoinTests {
    private func joiner() -> RoomJoin {
        RoomJoin(name: "Asha", model: "Mac14,2", makeMap: { () throws(CPace.Failure) in throw .mapUnavailable }, sleep: { _ in })
    }

    private func room(salt: String = InviteFixture.salt) -> ScriptedTransport {
        ScriptedTransport(["/room/hello": (200, #"{"v":3,"room":"Standup","host":"Priya","site":"macdev","salt":"\#(salt)","locked":false,"full":false,"people":1,"seats":2}"#)])
    }

    @Test func anotherKeyStopsBeforeTheHello() async {
        let transport = room()
        let result = await joiner().join(over: transport, code: "482913", fg: Data(count: 32),
                                         invite: .init(hostPin: Data(repeating: 0xab, count: 32), salt: InviteFixture.salt))
        #expect(result == .failure(.notTheInvitedRoom))
        #expect(transport.calls.isEmpty)
    }

    @Test func anotherSaltStopsAfterTheHelloWithoutAStart() async {
        let transport = room(salt: String(repeating: "11", count: 16))
        // ScriptedTransport's key is 32 zero bytes.
        let result = await joiner().join(over: transport, code: "482913", fg: Data(count: 32),
                                         invite: .init(hostPin: Data(count: 32), salt: InviteFixture.salt))
        #expect(result == .failure(.inviteOutOfDate))
        #expect(transport.calls == ["GET /room/hello"])
    }

    @Test func theInviteRefusalsSayWhatHappenedAndOfferNoRetry() {
        #expect(NetworkPanePresentation.refusal(.inviteExpired, host: "Standup") == "This invite has expired. Ask Standup's host for a new one.")
        #expect(NetworkPanePresentation.refusal(.notTheInvitedRoom, host: "Standup") == "This isn't the room in the invite.")
        #expect(NetworkPanePresentation.refusal(.inviteOutOfDate, host: "Standup") == "This invite is out of date (the host changed the code). Ask for a new one.")
        #expect(!NetworkPanePresentation.canRetry(.inviteOutOfDate) && !NetworkPanePresentation.canRetry(.inviteExpired))
        #expect(NetworkPanePresentation.canRetry(.unreachable))
    }
}
