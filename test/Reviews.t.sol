// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {SubmissionReviews} from "../src/SubmissionReviews.sol";
import {MockSeats} from "./mocks/MockSeats.sol";

/// @dev Reviews of artist submissions: one voice per identity.md seat and per claimed ARTIFACTS piece, editable while
/// pending, frozen once the curator decides, and advisory only.
contract ReviewsTest is Fixture {
    MockSeats internal seats;
    SubmissionReviews internal reviews;
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    uint256 internal PIECE;

    SubmissionReviews.Verdict internal constant BACK = SubmissionReviews.Verdict.Back;
    SubmissionReviews.Verdict internal constant NEUTRAL = SubmissionReviews.Verdict.Neutral;
    SubmissionReviews.Verdict internal constant PASS = SubmissionReviews.Verdict.Pass;

    function setUp() public override {
        super.setUp();
        seats = new MockSeats();
        reviews = new SubmissionReviews(address(house), address(seats), address(factory), address(source));
        PIECE = reviews.PIECE_VOICE();
        seats.mint(agent, 986);
        seats.mint(agent2, 4);
        vm.prank(alice);
        house.submit(keccak256("a drop"), "ipfs://preview");
    }

    function _tally(uint256 id) internal view returns (uint256[3] memory t) {
        (t[0], t[1], t[2]) = reviews.tally(id);
    }

    function test_seatsReview_andTheTallyFollows() public {
        vm.prank(agent);
        reviews.reviewAsSeat(0, 986, BACK, "Strong on-chain work; fits the house.");
        vm.prank(agent2);
        reviews.reviewAsSeat(0, 4, PASS, "");
        assertEq(_tally(0)[0], 1);
        assertEq(_tally(0)[1], 0);
        assertEq(_tally(0)[2], 1);
        assertEq(reviews.reviewCount(0), 2);
        SubmissionReviews.Review memory r = reviews.reviewOf(0, reviews.seatVoice(986));
        assertEq(uint8(r.verdict), uint8(BACK));
        assertEq(r.reviewer, agent);
        assertEq(r.note, "Strong on-chain work; fits the house.");
        assertEq(r.at, block.timestamp);
        (uint256[] memory voices, SubmissionReviews.Review[] memory list) = reviews.reviewsOf(0, 0, 10);
        assertEq(voices.length, 2);
        assertEq(voices[0], 986);
        assertEq(voices[1], 4);
        assertEq(list[1].reviewer, agent2);
    }

    function test_aClaimedPieceIsAVoice_andAnUnclaimedOneIsNot() public {
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(bob, address(0), 7);
        vm.prank(bob);
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(0, edition, BACK, "");
        ArtifactsPiece piece = _claim(bob, edition);
        vm.prank(carol);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsPiece(0, edition, BACK, "");
        vm.prank(bob);
        reviews.reviewAsPiece(0, edition, BACK, "from a collector");
        assertEq(reviews.reviewOf(0, PIECE + edition).reviewer, bob);
        assertEq(reviews.pieceVoice(edition), PIECE + edition);
        // the piece moves: its new holder speaks for it, still one voice
        vm.prank(bob);
        piece.transferFrom(bob, carol, 1);
        vm.prank(carol);
        reviews.reviewAsPiece(0, edition, NEUTRAL, "");
        assertEq(reviews.reviewCount(0), 1);
        assertEq(_tally(0)[1], 1);
        // THE SOURCE is a voice once its auction has made its contract; ids outside 1 to 256 are not pieces
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(0, 256, BACK, "");
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(0, 0, BACK, "");
        vm.expectRevert(SubmissionReviews.NoSuchPiece.selector);
        reviews.reviewAsPiece(0, 257, BACK, "");
    }

    function test_aSeatAndAPieceInOneWalletAreTwoVoices() public {
        _publishAll();
        _openSale(1 ether);
        vm.deal(agent, 10 ether);
        uint256 edition = _buyAndAssign(agent, address(0), 11);
        _claim(agent, edition);
        vm.startPrank(agent);
        reviews.reviewAsSeat(0, 986, BACK, "");
        reviews.reviewAsPiece(0, edition, BACK, "");
        vm.stopPrank();
        assertEq(_tally(0)[0], 2);
        assertEq(reviews.reviewCount(0), 2);
    }

    function test_changingAReviewMovesItsVote() public {
        vm.startPrank(agent);
        reviews.reviewAsSeat(0, 986, BACK, "first look");
        reviews.reviewAsSeat(0, 986, NEUTRAL, "second look");
        vm.stopPrank();
        assertEq(_tally(0)[0], 0);
        assertEq(_tally(0)[1], 1);
        assertEq(reviews.reviewCount(0), 1, "still one voice");
        assertEq(reviews.reviewOf(0, 986).note, "second look");
    }

    function test_onlyTheSeatHolderReviews() public {
        vm.prank(bob);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(0, 986, BACK, "");
        vm.prank(agent);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(0, 99, BACK, ""); // no such seat
        vm.prank(agent);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(0, PIECE + 1, BACK, ""); // a seat id can't reach a piece's voice
    }

    function test_aMovedSeatStillHasOneVoice() public {
        vm.prank(agent);
        reviews.reviewAsSeat(0, 986, BACK, "mine");
        vm.prank(agent);
        seats.transferFrom(agent, bob, 986);
        vm.prank(agent);
        vm.expectRevert(SubmissionReviews.NotHolder.selector);
        reviews.reviewAsSeat(0, 986, PASS, "");
        vm.prank(bob);
        reviews.reviewAsSeat(0, 986, PASS, "the new holder speaks for seat 986");
        assertEq(reviews.reviewCount(0), 1);
        assertEq(_tally(0)[0], 0);
        assertEq(_tally(0)[2], 1);
        assertEq(reviews.reviewOf(0, 986).reviewer, bob);
    }

    function test_frozenOnceTheCuratorDecides_andAdvisoryOnly() public {
        vm.prank(agent);
        reviews.reviewAsSeat(0, 986, PASS, "not for us");
        // the curator decides regardless of the reviews
        vm.prank(curator);
        house.decideSubmission(0, true);
        vm.prank(agent2);
        vm.expectRevert(SubmissionReviews.NotPending.selector);
        reviews.reviewAsSeat(0, 4, BACK, "");
        vm.prank(agent);
        vm.expectRevert(SubmissionReviews.NotPending.selector);
        reviews.reviewAsSeat(0, 986, BACK, "");
        // the record stays readable
        assertEq(uint8(reviews.reviewOf(0, 986).verdict), uint8(PASS));
        assertEq(_tally(0)[2], 1);
    }

    /// @dev Brokers publish theses: only brokers, up to MAX_THESIS bytes, the latest per author stands, open after
    /// acceptance (to promote the drop), closed once declined.
    function test_brokersPublishTheses() public {
        string memory text = "The case for this drop: on-chain, owner-only, and it fits the house.";
        vm.prank(bob);
        vm.expectRevert(SubmissionReviews.NotABroker.selector);
        reviews.postThesis(0, text);
        uint256 max = reviews.MAX_THESIS();
        vm.startPrank(broker); // approved by the curator in the fixture
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.postThesis(0, "");
        vm.expectRevert(SubmissionReviews.BadThesis.selector);
        reviews.postThesis(0, string(new bytes(max + 1)));
        vm.expectRevert(SubmissionReviews.NoSuchSubmission.selector);
        reviews.postThesis(5, text);
        vm.expectEmit(address(reviews));
        emit SubmissionReviews.Thesis(0, broker, text);
        reviews.postThesis(0, text);
        assertEq(reviews.thesisAuthors(0), 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        reviews.postThesis(0, string(new bytes(max))); // the longest allowed, as an update
        assertEq(reviews.thesisAuthors(0), 1, "an update, not a second author");
        assertEq(reviews.thesisAt(0, broker), vm.getBlockTimestamp());
        vm.stopPrank();
        // accepted: still open, to keep making the case for the drop
        vm.prank(curator);
        house.decideSubmission(0, true);
        vm.prank(broker);
        reviews.postThesis(0, "Now a drop: here is why to collect it.");
        // declined: closed
        vm.prank(alice);
        house.submit(keccak256("another drop"), "ipfs://another");
        vm.prank(curator);
        house.decideSubmission(1, false);
        vm.prank(broker);
        vm.expectRevert(SubmissionReviews.Declined.selector);
        reviews.postThesis(1, text);
        // a broker the curator stops approving (and with no pass) can't publish any more
        vm.prank(curator);
        house.setBroker(broker, false);
        vm.prank(broker);
        vm.expectRevert(SubmissionReviews.NotABroker.selector);
        reviews.postThesis(0, text);
    }

    function test_inputChecks() public {
        vm.startPrank(agent);
        vm.expectRevert(SubmissionReviews.NoSuchSubmission.selector);
        reviews.reviewAsSeat(1, 986, BACK, "");
        vm.expectRevert(SubmissionReviews.BadVerdict.selector);
        reviews.reviewAsSeat(0, 986, SubmissionReviews.Verdict.None, "");
        bytes memory long = new bytes(281);
        vm.expectRevert(SubmissionReviews.NoteTooLong.selector);
        reviews.reviewAsSeat(0, 986, BACK, string(long));
        reviews.reviewAsSeat(0, 986, BACK, string(new bytes(280)));
        vm.stopPrank();
        (uint256[] memory voices,) = reviews.reviewsOf(0, 5, 10);
        assertEq(voices.length, 0, "a page past the end is empty");
        vm.expectRevert(SubmissionReviews.ZeroAddress.selector);
        new SubmissionReviews(address(house), address(0), address(factory), address(source));
    }

    /// The tally always adds up to the number of voices that reviewed, whatever order reviews arrive in.
    function testFuzz_tallyMatchesVoices(uint8[12] calldata moves) public {
        seats.mint(agent, 5);
        seats.mint(agent2, 6);
        address[4] memory holder = [agent, agent2, agent, agent2];
        uint256[4] memory seat = [uint256(986), 4, 5, 6];
        bool[4] memory spoke;
        uint256 voices;
        for (uint256 i; i < moves.length; ++i) {
            uint256 who = moves[i] % 4;
            SubmissionReviews.Verdict v = SubmissionReviews.Verdict(1 + (moves[i] / 4) % 3);
            vm.prank(holder[who]);
            reviews.reviewAsSeat(0, seat[who], v, "");
            if (!spoke[who]) {
                spoke[who] = true;
                ++voices;
            }
            uint256[3] memory t = _tally(0);
            assertEq(t[0] + t[1] + t[2], voices);
            assertEq(reviews.reviewCount(0), voices);
        }
    }
}
