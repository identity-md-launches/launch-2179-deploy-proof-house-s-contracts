// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Clones} from "./libs/Clones.sol";
import {IArtHouse, IArtifactsPiece, Traits} from "./interfaces/Interfaces.sol";

/// @notice THE SOURCE (ARTIFACTS piece 256): stores its metadata encrypted with SSTORE2, locks it forever with a
/// commitment to its content key, and sells the single lot by an ascending ETH auction whose proceeds go through the
/// Proof House ledger. The curator delivers the key to the winner once, wrapped to their viewing key; the winner
/// alone decides whether to reveal it.
///
/// Encryption: byte j of the stored payload is plaintext byte j XOR byte (j % 32) of keccak256(K ‖ uint256(j / 32)),
/// with K a random 256-bit key and the commitment keccak256(K). Revealing publishes K; the piece then decrypts.
contract ArtifactsSource is TwoStepOwnable, ReentrancyGuard {
    uint256 public constant SOURCE_ID = 256;
    uint256 public constant MIN_RAISE_BPS = 500; // each bid beats the high bid by 5%
    uint256 public constant EXTENSION = 10 minutes;

    IArtHouse public immutable house;
    address public immutable pieceImplementation;

    // ---------- payload ----------
    address[] private _chunks;
    uint256 public payloadSize;
    bool public payloadLocked;
    bytes32 public keyCommitment; // keccak256(K), K the key that decrypts the stored payload
    bool public keyDelivered; // the curator's one delivery of K to the winner

    // ---------- auction ----------
    uint256 public reserve;
    uint64 public endTime;
    bool public auctionOpen;
    bool public settled;
    address public highBidder;
    uint256 public highBid;
    address public highBroker;
    mapping(address => uint256) public refunds;
    address public pieceContract;

    event PayloadChunkStored(uint256 index, address pointer, uint256 size);
    event PayloadLocked(bytes32 hash, uint256 size, bytes32 keyCommitment);
    event KeyDelivered(address indexed owner);
    event AuctionSet(uint256 reserve, uint64 endTime);
    event Bid(address indexed bidder, address indexed broker, uint256 amount, uint64 endTime);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event Settled(address indexed winner, uint256 amount, address piece);

    error IsLocked();
    error NotLocked();
    error EmptyPayload();
    error AuctionLive();
    error AuctionNotOpen();
    error AuctionEnded();
    error AuctionNotEnded();
    error BadEndTime();
    error BidTooLow();
    error AlreadySettled();
    error NoBids();
    error NothingToWithdraw();
    error TransferFailed();
    error NoCommitment();
    error NotSettled();
    error AlreadyDelivered();

    constructor(address owner_, address house_, address pieceImplementation_) TwoStepOwnable(owner_) {
        if (house_ == address(0) || pieceImplementation_ == address(0)) revert ZeroAddress();
        house = IArtHouse(house_);
        pieceImplementation = pieceImplementation_;
    }

    // ---------- payload (the encrypted bytes of THE SOURCE's base64 metadata, from the offline ceremony) ----------

    function storePayloadChunk(bytes calldata data) external onlyOwner {
        if (payloadLocked) revert IsLocked();
        if (data.length == 0) revert EmptyPayload();
        address ptr = SSTORE2.write(data);
        _chunks.push(ptr);
        payloadSize += data.length;
        emit PayloadChunkStored(_chunks.length - 1, ptr, data.length);
    }

    /// @notice Drops every stored chunk so the upload can start over (only while unlocked).
    function resetPayload() external onlyOwner {
        if (payloadLocked) revert IsLocked();
        delete _chunks;
        payloadSize = 0;
    }

    /// @notice Locks the stored ciphertext forever, with the commitment keccak256(K) to the key that decrypts it.
    function lockPayload(bytes32 keyCommitment_) external onlyOwner {
        if (payloadLocked) revert IsLocked();
        if (_chunks.length == 0) revert EmptyPayload();
        if (keyCommitment_ == bytes32(0)) revert NoCommitment();
        payloadLocked = true;
        keyCommitment = keyCommitment_;
        emit PayloadLocked(payloadHash(), payloadSize, keyCommitment_);
    }

    function payloadChunks() external view returns (address[] memory) {
        return _chunks;
    }

    function payload() public view returns (bytes memory data) {
        data = new bytes(payloadSize);
        uint256 offset;
        for (uint256 i; i < _chunks.length; ++i) {
            uint256 dest;
            assembly ("memory-safe") {
                dest := add(add(data, 32), offset)
            }
            offset += SSTORE2.copyTo(_chunks[i], dest);
        }
    }

    /// @notice keccak256 of the stored (encrypted) payload.
    function payloadHash() public view returns (bytes32) {
        return keccak256(payload());
    }

    // ---------- the key ----------

    /// @notice The curator's single delivery of K to THE SOURCE's owner after settlement, wrapped to the viewing key
    /// they registered on THE SOURCE's contract. Later owners receive K from the owner before them (re-wrap after a
    /// transfer, or the keyed escrow), never from the curator.
    function deliverKey(bytes calldata wrapped) external onlyOwner {
        if (!settled) revert NotSettled();
        if (keyDelivered) revert AlreadyDelivered();
        keyDelivered = true;
        IArtifactsPiece piece = IArtifactsPiece(pieceContract);
        piece.rewrapFor(wrapped);
        emit KeyDelivered(piece.ownerOf(1));
    }

    // ---------- auction ----------

    /// @notice Opens (or re-opens, if no bid came) the single-lot auction. Needs the locked payload.
    function setAuction(uint256 reserve_, uint64 endTime_) external onlyOwner {
        if (!payloadLocked) revert NotLocked();
        if (settled) revert AlreadySettled();
        if (highBidder != address(0)) revert AuctionLive();
        if (endTime_ <= block.timestamp) revert BadEndTime();
        if (reserve_ == 0) revert BidTooLow();
        reserve = reserve_;
        endTime = endTime_;
        auctionOpen = true;
        emit AuctionSet(reserve_, endTime_);
    }

    function bid(address broker) external payable nonReentrant {
        if (!auctionOpen) revert AuctionNotOpen();
        if (block.timestamp >= endTime) revert AuctionEnded();
        if (msg.value < reserve) revert BidTooLow();
        // the 5% raise rounds up, so a bid must strictly exceed the high bid even at dust sizes
        if (highBid != 0 && msg.value < (highBid * (10_000 + MIN_RAISE_BPS) + 9_999) / 10_000) revert BidTooLow();
        if (highBidder != address(0)) refunds[highBidder] += highBid;
        highBidder = msg.sender;
        highBid = msg.value;
        highBroker = broker;
        if (endTime - block.timestamp < EXTENSION) endTime = uint64(block.timestamp + EXTENSION);
        emit Bid(msg.sender, broker, msg.value, endTime);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RefundWithdrawn(msg.sender, amount);
    }

    /// @notice After the end: proceeds go through the ledger and THE SOURCE's contract is deployed to the winner.
    function settle() external nonReentrant returns (address piece) {
        if (!auctionOpen) revert AuctionNotOpen();
        if (block.timestamp < endTime) revert AuctionNotEnded();
        if (settled) revert AlreadySettled();
        if (highBidder == address(0)) revert NoBids();
        settled = true;
        auctionOpen = false;
        // THE SOURCE gets its own full contract (a byte copy of ArtifactsPiece's runtime, not an EIP-1167 proxy),
        // so the revealed 1.8 MB tokenURI is copied once and stays under 10M gas.
        piece = Clones.copyCode(pieceImplementation);
        pieceContract = piece;
        house.recordSale{value: highBid}(address(this), highBidder, highBroker);
        IArtifactsPiece(piece)
            .initialize(
                address(this),
                address(house),
                SOURCE_ID,
                highBidder,
                Traits({
                    title: unicode"ARTIFACTS  ◆  MASTER", palette: "PRISM", colourCount: 9, direction: "DIAGONAL"
                }),
                address(0),
                keyCommitment,
                "",
                true
            );
        emit Settled(highBidder, highBid, piece);
    }

    /// @notice True only for THE SOURCE's own piece contract (the ledger checks resale callers with it).
    function isPiece(address piece) external view returns (bool) {
        return piece != address(0) && piece == pieceContract;
    }

    function auctionState()
        external
        view
        returns (bool open, bool isSettled, uint256 reserve_, uint64 endTime_, address bidder, uint256 amount)
    {
        return (auctionOpen, settled, reserve, endTime, highBidder, highBid);
    }
}
