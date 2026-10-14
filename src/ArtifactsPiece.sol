// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Lite} from "./base/ERC721Lite.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Encoding} from "./libs/Encoding.sol";
import {Seal} from "./libs/Seal.sol";
import {IArtHouse, IPayloadSource, Traits} from "./interfaces/Interfaces.sol";

/// @notice One ARTIFACTS piece: a one-token ERC-721 + ERC-2981, deployed as an EIP-1167 clone at claim.
/// Holds the ciphertext pointer, public traits, key commitment and the current owner's wrapped content key.
/// Runs its own keyed resale escrow and re-keying after plain transfers. THE SOURCE (piece 256) adds the
/// write-once `revealed` flag and serves its stored metadata once revealed.
contract ArtifactsPiece is ERC721Lite, ReentrancyGuard {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant ESCROW_TIMEOUT = 72 hours;
    uint16 public constant ROYALTY_BPS = 750;
    uint16 public constant BPS = 10_000;

    address public controller; // ArtifactsFactory (editions) or ArtifactsSource (THE SOURCE)
    IArtHouse public house;
    uint256 public pieceId;
    bool public isSource;
    bool public revealed;

    Traits private _traits;
    address public ciphertextPointer;
    bytes32 public commitment;
    bytes public wrappedKey; // wrapped to the current owner's viewing key; cleared on plain transfer
    address public previousOwner; // may post a re-wrapped key after a plain transfer

    mapping(address => bytes32) public viewingKeyOf;
    mapping(address => uint256) public pendingWithdrawals;

    struct Escrow {
        uint256 price;
        address seller;
        address buyer;
        uint64 paidAt;
        bool keyPosted;
        bytes key;
    }

    Escrow public escrow;

    event ViewingKeyRegistered(address indexed account, bytes32 key);
    event WrappedKeyPosted(address indexed by, address indexed forOwner);
    event Listed(address indexed seller, uint256 price);
    event Delisted();
    event EscrowPaid(address indexed buyer, uint256 price);
    event EscrowKeyPosted();
    event EscrowCancelled(address indexed buyer);
    event EscrowReleased(address indexed seller, address indexed buyer, uint256 price, uint256 royalty);
    event Revealed();
    event Withdrawn(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotTokenOwner();
    error NotPreviousOwner();
    error NotSource();
    error AlreadyRevealed();
    error NotListed();
    error AlreadyListed();
    error EscrowActive();
    error NoEscrowBuyer();
    error NotEscrowBuyer();
    error NotSeller();
    error KeyAlreadyPosted();
    error KeyNotPosted();
    error TooEarly();
    error WrongPrice();
    error NoViewingKey();
    error TransferFailed();
    error NothingToWithdraw();
    error NotRevealable();

    constructor() {
        controller = address(this); // lock the implementation; only clones can be initialised
    }

    // ---------- initialisation (by the controller, at claim / settlement) ----------

    function initialize(
        address controller_,
        address house_,
        uint256 pieceId_,
        address to,
        Traits calldata traits_,
        address ciphertext_,
        bytes32 commitment_,
        bytes calldata wrappedKey_,
        bool isSource_
    ) external {
        if (controller != address(0)) revert AlreadyInitialized();
        controller = controller_;
        house = IArtHouse(house_);
        pieceId = pieceId_;
        isSource = isSource_;
        _traits = traits_;
        ciphertextPointer = ciphertext_;
        commitment = commitment_;
        wrappedKey = wrappedKey_;
        _name = isSource_ ? unicode"ARTIFACTS · THE SOURCE" : string.concat("ARTIFACTS #", Encoding.pad3(pieceId_));
        _symbol = "ARTIFACTS";
        _mint(to, TOKEN_ID);
    }

    // ---------- views ----------

    function traits() external view returns (Traits memory) {
        return _traits;
    }

    function ciphertext() external view returns (bytes memory) {
        return ciphertextPointer == address(0) ? bytes("") : SSTORE2.read(ciphertextPointer);
    }

    function royaltyInfo(uint256, uint256 salePrice) public view returns (address, uint256) {
        return house.royaltyFor(controller, salePrice);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    // ---------- keys ----------

    function registerViewingKey(bytes32 key) external {
        if (key == bytes32(0)) revert NoViewingKey();
        viewingKeyOf[msg.sender] = key;
        emit ViewingKeyRegistered(msg.sender, key);
    }

    /// @notice After a plain transfer the previous owner (or the controller, for first claims) re-wraps K to the
    /// new owner's viewing key and posts it here. One shot: the key slot must be empty, and posting ends the
    /// previous owner's right, so a delivered key can never be overwritten.
    function rewrapFor(bytes calldata wrapped) external {
        if (msg.sender != previousOwner && msg.sender != controller) revert NotPreviousOwner();
        if (wrappedKey.length != 0) revert KeyAlreadyPosted();
        if (wrapped.length == 0) revert KeyNotPosted();
        address current = ownerOf(TOKEN_ID);
        if (viewingKeyOf[current] == bytes32(0)) revert NoViewingKey();
        wrappedKey = wrapped;
        delete previousOwner;
        emit WrappedKeyPosted(msg.sender, current);
    }

    // ---------- keyed resale escrow ----------

    function list(uint256 price) external {
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotTokenOwner();
        if (escrow.seller != address(0)) revert AlreadyListed();
        if (price == 0) revert WrongPrice();
        escrow.price = price;
        escrow.seller = msg.sender;
        emit Listed(msg.sender, price);
    }

    function delist() external {
        if (msg.sender != escrow.seller) revert NotSeller();
        if (escrow.buyer != address(0)) revert EscrowActive();
        delete escrow;
        emit Delisted();
    }

    /// @notice The buyer pays the listed price into escrow and registers their viewing key in the same step.
    function buy(bytes32 viewingKey) external payable nonReentrant {
        Escrow storage e = escrow;
        if (e.seller == address(0)) revert NotListed();
        if (e.buyer != address(0)) revert EscrowActive();
        if (msg.value != e.price) revert WrongPrice();
        if (viewingKey == bytes32(0)) revert NoViewingKey();
        if (msg.sender == e.seller) revert NotEscrowBuyer();
        e.buyer = msg.sender;
        e.paidAt = uint64(block.timestamp);
        viewingKeyOf[msg.sender] = viewingKey;
        emit ViewingKeyRegistered(msg.sender, viewingKey);
        emit EscrowPaid(msg.sender, msg.value);
    }

    function postEscrowKey(bytes calldata wrapped) external {
        Escrow storage e = escrow;
        if (msg.sender != e.seller) revert NotSeller();
        if (e.buyer == address(0)) revert NoEscrowBuyer();
        if (e.keyPosted) revert KeyAlreadyPosted();
        if (wrapped.length == 0) revert KeyNotPosted();
        e.keyPosted = true;
        e.key = wrapped;
        emit EscrowKeyPosted();
    }

    /// @notice The buyer may cancel and take their payment back until the seller posts the key.
    function cancel() external nonReentrant {
        Escrow storage e = escrow;
        if (msg.sender != e.buyer) revert NotEscrowBuyer();
        if (e.keyPosted) revert KeyAlreadyPosted();
        uint256 refund = e.price;
        address buyer = e.buyer;
        e.buyer = address(0);
        e.paidAt = 0;
        pendingWithdrawals[buyer] += refund;
        emit EscrowCancelled(buyer);
    }

    /// @notice Release: by the buyer once the key is posted, or by anyone 72 hours after payment with the key posted.
    function release() external nonReentrant {
        Escrow storage e = escrow;
        if (e.buyer == address(0)) revert NoEscrowBuyer();
        if (!e.keyPosted) revert KeyNotPosted();
        if (msg.sender != e.buyer && block.timestamp < e.paidAt + ESCROW_TIMEOUT) revert TooEarly();
        address seller = e.seller;
        address buyer = e.buyer;
        uint256 price = e.price;
        bytes memory key = e.key;
        delete escrow;
        (address royaltyTo, uint256 royalty) = royaltyInfo(TOKEN_ID, price);
        if (royaltyTo == address(0)) royalty = 0;
        pendingWithdrawals[seller] += price - royalty;
        if (royalty > 0) pendingWithdrawals[royaltyTo] += royalty;
        _releasing = true;
        _transfer(seller, buyer, TOKEN_ID);
        _releasing = false;
        wrappedKey = key;
        delete previousOwner; // the escrowed key is delivered; the paid seller keeps no re-key right
        emit EscrowReleased(seller, buyer, price, royalty);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @dev Plain transfers stay allowed, except while a buyer's payment sits in escrow (only release() moves a
    /// token then). A transfer clears the wrapped key and remembers who can re-wrap it; a listing without a
    /// buyer is dropped.
    function _beforeTransfer(address from, address, uint256) internal override {
        if (from == address(0)) return;
        if (!_releasing) {
            if (escrow.buyer != address(0)) revert EscrowActive();
            delete escrow;
        }
        previousOwner = from;
        delete wrappedKey;
    }

    bool private _releasing;

    // ---------- THE SOURCE ----------

    function setRevealed() external {
        if (!isSource) revert NotSource();
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotTokenOwner();
        if (revealed) revert AlreadyRevealed();
        if (!IPayloadSource(controller).payloadLocked()) revert NotRevealable();
        revealed = true;
        emit Revealed();
    }

    // ---------- metadata ----------

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ownerOf(tokenId);
        if (isSource && revealed) return _revealedURI();
        string memory svg = isSource
            ? Seal.source()
            : Seal.edition(_traits.title, _traits.palette, _traits.colourCount, _traits.direction, pieceId);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _name,
            '","description":"',
            isSource
                ? "THE SOURCE. The full prism the 255 editions are fragments of. Sealed until its owner reveals it."
                : "An ARTIFACTS edition. Encrypted generative art; only the owner can render it. The seal shows its public traits.",
            '","attributes":[',
            _attributes(),
            '],"image":"data:image/svg+xml;base64,',
            Encoding.base64(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }

    function _attributes() private view returns (string memory) {
        if (isSource) return '{"trait_type":"Piece","value":"THE SOURCE"}';
        return string.concat(
            '{"trait_type":"Title","value":"',
            _traits.title,
            '"},{"trait_type":"Palette","value":"',
            _traits.palette,
            '"},{"trait_type":"Colours","value":',
            Encoding.toString(_traits.colourCount),
            '},{"trait_type":"Direction","value":"',
            _traits.direction,
            '"},{"trait_type":"Seed","value":"',
            Encoding.pad3(pieceId),
            '"}'
        );
    }

    /// @dev "data:application/json;base64," + the stored payload bytes copied as is, assembled in one memory
    /// buffer and returned directly so the 1.8 MB payload is never copied twice.
    function _revealedURI() private view returns (string memory) {
        address[] memory chunks = IPayloadSource(controller).payloadChunks();
        uint256 total = 29;
        for (uint256 i; i < chunks.length; ++i) {
            total += SSTORE2.size(chunks[i]);
        }
        bytes memory prefix = "data:application/json;base64,";
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x20) // offset of the string
            mstore(add(ptr, 0x20), total) // length
            let data := add(ptr, 0x40)
            mstore(data, mload(add(prefix, 0x20))) // 29 prefix bytes (the tail gets overwritten below)
            let cursor := add(data, 29)
            let n := mload(chunks)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let p := mload(add(add(chunks, 0x20), mul(i, 0x20)))
                let len := sub(extcodesize(p), 1)
                extcodecopy(p, cursor, 1, len)
                cursor := add(cursor, len)
            }
            // pad to a word boundary and return the ABI-encoded string
            let end := and(add(cursor, 31), not(31))
            return(ptr, sub(end, ptr))
        }
    }
}
