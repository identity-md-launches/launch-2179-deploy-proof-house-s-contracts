// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Lite} from "./base/ERC721Lite.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Encoding} from "./libs/Encoding.sol";
import {Seal} from "./libs/Seal.sol";
import {IArtHouse, ISourceStore, Traits} from "./interfaces/Interfaces.sol";

/// @notice One ARTIFACTS piece: a one-token ERC-721 + ERC-2981, deployed as an EIP-1167 clone at claim.
/// Holds the ciphertext pointer, public traits, key commitment and the current owner's wrapped content key.
/// Runs its own keyed resale escrow and re-keying after plain transfers. THE SOURCE (piece 256) adds a one-time
/// reveal: its owner publishes its content key, which opens its stored seed; from then on tokenURI serves the
/// on-chain renderer page drawing it from that seed.
contract ArtifactsPiece is ERC721Lite, ReentrancyGuard {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant ESCROW_TIMEOUT = 72 hours;
    uint16 public constant ROYALTY_BPS = 750;
    uint16 public constant RESALE_BROKER_BPS = 250; // 2.5% of a resale to the broker who brought the buyer
    uint16 public constant BPS = 10_000;
    /// @notice Closes THE SOURCE's renderer page after its seed (tools/source/renderer.js SUFFIX, byte for byte).
    string public constant RENDER_SUFFIX =
        '"),true);document.body.innerHTML=s;try{if(parent!==window)parent.postMessage({artifacts:s},"*")}catch(e){}</script></body></html>';

    address public controller; // ArtifactsFactory (editions) or ArtifactsSource (THE SOURCE)
    IArtHouse public house;
    uint256 public pieceId;
    bool public isSource;
    bool public revealed;
    bytes32 public revealKey; // THE SOURCE's content key K, published by its owner at reveal

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
        address broker; // named by the buyer; paid at release if the ledger counts it as a broker
    }

    Escrow public escrow;

    event ViewingKeyRegistered(address indexed account, bytes32 key);
    event WrappedKeyPosted(address indexed by, address indexed forOwner);
    event Listed(address indexed seller, uint256 price);
    event Delisted();
    event EscrowPaid(address indexed buyer, uint256 price);
    event EscrowKeyPosted();
    event EscrowCancelled(address indexed buyer);
    event EscrowReleased(
        address indexed seller, address indexed buyer, uint256 price, uint256 royalty, address broker, uint256 brokerShare
    );
    event Revealed(bytes32 key);
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
    error WrongKey();

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

    /// @notice The buyer pays the listed price into escrow and registers their viewing key in the same step,
    /// naming the broker who brought them (or the zero address).
    function buy(bytes32 viewingKey, address broker) external payable nonReentrant {
        Escrow storage e = escrow;
        if (e.seller == address(0)) revert NotListed();
        if (e.buyer != address(0)) revert EscrowActive();
        if (msg.value != e.price) revert WrongPrice();
        if (viewingKey == bytes32(0)) revert NoViewingKey();
        if (msg.sender == e.seller) revert NotEscrowBuyer();
        e.buyer = msg.sender;
        e.paidAt = uint64(block.timestamp);
        e.broker = broker;
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
        e.broker = address(0);
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
        address broker = e.broker;
        uint256 price = e.price;
        bytes memory key = e.key;
        delete escrow;
        (address royaltyTo, uint256 royalty) = royaltyInfo(TOKEN_ID, price);
        if (royaltyTo == address(0)) royalty = 0;
        uint256 brokerShare;
        if (broker != buyer && broker != seller && _isBroker(broker)) brokerShare = (price * RESALE_BROKER_BPS) / BPS;
        else broker = address(0);
        pendingWithdrawals[seller] += price - royalty - brokerShare;
        // The royalty and broker share go to the ledger, so each party withdraws once from one place. If the
        // ledger refuses (e.g. this piece's module was revoked), they stay here as pull payments instead.
        uint256 toLedger = royalty + brokerShare;
        if (toLedger > 0) {
            try house.recordResale{value: toLedger}(broker, royalty, brokerShare) {}
            catch {
                if (royalty > 0) pendingWithdrawals[royaltyTo] += royalty;
                if (brokerShare > 0) pendingWithdrawals[broker] += brokerShare;
            }
        }
        _releasing = true;
        _transfer(seller, buyer, TOKEN_ID);
        _releasing = false;
        wrappedKey = key;
        delete previousOwner; // the escrowed key is delivered; the paid seller keeps no re-key right
        emit EscrowReleased(seller, buyer, price, royalty, broker, brokerShare);
    }

    function _isBroker(address broker) private view returns (bool) {
        if (broker == address(0)) return false;
        try house.isEligibleBroker(broker) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
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

    /// @notice THE SOURCE's owner reveals it to everyone, once and forever, by publishing its content key K, which
    /// opens its stored seed. The key must match the commitment locked before the auction. Not while a buyer's payment
    /// sits in escrow: they paid for it sealed.
    function reveal(bytes32 key) external {
        if (!isSource) revert NotSource();
        if (msg.sender != ownerOf(TOKEN_ID)) revert NotTokenOwner();
        if (revealed) revert AlreadyRevealed();
        if (!ISourceStore(controller).locked()) revert NotRevealable();
        if (escrow.buyer != address(0)) revert EscrowActive();
        if (keccak256(abi.encodePacked(key)) != commitment) revert WrongKey();
        revealKey = key;
        revealed = true;
        emit Revealed(key);
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

    /// @notice THE SOURCE's seed, once revealed (zero before): the stored sealed seed XOR keccak256(K ‖ uint256(0)).
    function revealedSeed() public view returns (bytes32) {
        if (!revealed) return bytes32(0);
        return ISourceStore(controller).sealedSeed() ^ keccak256(abi.encodePacked(revealKey, uint256(0)));
    }

    /// @dev After the reveal the seal stays the still image (marketplace thumbnails), and animation_url is the
    /// on-chain renderer page drawing THE SOURCE from its seed: the rules, stored once, plus the seed.
    function _revealedURI() private view returns (string memory) {
        string memory seedHex = Encoding.toHexString(revealedSeed());
        address[] memory chunks = ISourceStore(controller).rendererChunks();
        bytes memory page;
        for (uint256 i; i < chunks.length; ++i) {
            page = bytes.concat(page, SSTORE2.read(chunks[i]));
        }
        page = bytes.concat(page, bytes(seedHex), bytes(RENDER_SUFFIX));
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _name,
            '","description":"THE SOURCE, revealed by its owner. Drawn from its seed by the ARTIFACTS rules stored on-chain.",',
            '"attributes":[{"trait_type":"Piece","value":"THE SOURCE"},{"trait_type":"Seed","value":"',
            seedHex,
            '"}],"image":"data:image/svg+xml;base64,',
            Encoding.base64(bytes(Seal.source())),
            '","animation_url":"data:text/html;base64,',
            Encoding.base64(page),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }
}
