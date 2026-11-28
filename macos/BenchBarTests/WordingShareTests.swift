import Foundation
import Testing
@testable import BenchBar

/// The counts of the Share and Network panes (Wording+Share.swift), and the catalogue keys
/// behind them.
@Suite("Wording, Share and Network")
struct WordingShareTests {
    @Test func peopleAgreeWithTheirCount() {
        #expect(Wording.peopleConnected(1) == "1 person is connected and will be signed out.")
        #expect(Wording.peopleConnected(2) == "2 people are connected and will be signed out.")
        #expect(Wording.stopSharing(online: 1) == "Stop sharing? 1 person is connected and will be signed out.")
        #expect(Wording.stopSharing(online: 3) == "Stop sharing? 3 people are connected and will be signed out.")
        #expect(Wording.restartSharing(online: 1) == "Restart sharing? 1 person is connected and will be signed out.")
        #expect(Wording.restartSharing(online: 4) == "Restart sharing? 4 people are connected and will be signed out.")
    }

    @Test func oneRoomHasItsOwnSentence() {
        #expect(Wording.roomsClose(1) == "The room you opened closes on this Mac.")
        #expect(Wording.roomsClose(2) == "The 2 rooms you opened close on this Mac.")
    }

    @Test func waitingPeopleHaveTheirOwnSentences() {
        #expect(Wording.peopleWaiting(1) == "1 person waits for a seat. Choose Give a Seat next to their name.")
        #expect(Wording.peopleWaiting(3) == "3 people wait for a seat. Choose Give a Seat next to each name.")
    }

    /// Two numbers: the noun follows the second, so one seat is "1 of 1 seat taken".
    @Test func seatsAgreeWithTheirTotal() {
        #expect(Wording.seatsTaken(3, of: 5) == "3 of 5 seats taken")
        #expect(Wording.seatsTaken(1, of: 1) == "1 of 1 seat taken")
        #expect(Wording.seatsTaken(0, of: 1) == "0 of 1 seat taken")
    }
}
