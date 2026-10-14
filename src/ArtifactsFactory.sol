// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";
import {Clones} from "./libs/Clones.sol";
import {IArtHouse, IArtifactsPiece, IVRFCoordinatorV2Plus, Traits} from "./interfaces/Interfaces.sol";

/// @notice Sells the 255 ARTIFACTS editions at one ETH price through the Proof House ledger, assigns editions
/// with Chainlink VRF v2.5, and deploys each buyer's piece clone at claim.
contract ArtifactsFactory is TwoStepOwnable, ReentrancyGuard {
    uint256 public constant EDITIONS = 255;
    uint32 public constant VRF_CALLBACK_GAS = 250_000;
    uint16 public constant VRF_CONFIRMATIONS = 3;
    /// @dev Blocks a VRF request may stay unfulfilled before the curator can re-request it (~24h at 12s blocks,
    /// Chainlink's own retry window for an underfunded subscription).
    uint256 public constant VRF_RETRY_BLOCKS = 7_200;

    IArtHouse public immutable house;
    address public immutable pieceImplementation;

    // ---------- piece publication (before the sale, then locked forever) ----------
    struct PieceData {
        Traits traits;
        address ciphertext;
        bytes32 commitment;
        bool set;
    }

    mapping(uint256 => PieceData) private _pieces;
    uint256 public piecesSet;
    bool public locked;

    // ---------- sale ----------
    uint256 public price;
    bool public saleOpen;
    uint256 public sold; // purchases paid (VRF requested)
    uint256 public assigned; // editions assigned by VRF callbacks

    // ---------- VRF ----------
    IVRFCoordinatorV2Plus public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubscriptionId;
    bool public vrfNativePayment;

    mapping(uint256 => address) public requestBuyer;
    mapping(uint256 => uint256) public requestEdition;
    mapping(uint256 => uint256) public requestBlock;
    mapping(uint16 => uint16) private _pool; // Fisher-Yates over 1..255, lazily initialised
    mapping(uint256 => address) public editionBuyer;
    mapping(address => uint256[]) private _editionsOf;

    // ---------- claim ----------
    mapping(address => bytes32) public viewingKeyOf;
    mapping(uint256 => bytes) private _wrappedKey;
    mapping(uint256 => address) public pieceContract;

    event PieceSet(uint256 indexed pieceId, bytes32 commitment, address ciphertext);
    event Locked();
    event PriceSet(uint256 price);
    event SaleOpenSet(bool open);
    event VRFConfigured(address coordinator, bytes32 keyHash, uint256 subscriptionId, bool nativePayment);
    event Purchased(address indexed buyer, address indexed broker, uint256 requestId, uint256 price);
    event EditionAssigned(uint256 indexed edition, address indexed buyer, uint256 requestId);
    event Rerequested(uint256 indexed oldRequestId, uint256 indexed newRequestId, address indexed buyer);
    event ViewingKeyRegistered(address indexed account, bytes32 key);
    event WrappedKeyPosted(uint256 indexed edition);
    event Claimed(uint256 indexed edition, address indexed owner, address piece);

    error BadPieceId();
    error IsLocked();
    error NotLocked();
    error NotAllSet();
    error SaleIsOpen();
    error SaleClosed();
    error WrongPrice();
    error SoldOut();
    error VRFNotConfigured();
    error VRFAlreadyConfigured();
    error NotCoordinator();
    error UnknownRequest();
    error NotAssigned();
    error NotBuyer();
    error NoViewingKey();
    error KeyNotPosted();
    error AlreadyClaimed();
    error AlreadyFulfilled();
    error RequestTooRecent();

    constructor(address owner_, address house_, address pieceImplementation_) TwoStepOwnable(owner_) {
        if (house_ == address(0) || pieceImplementation_ == address(0)) revert ZeroAddress();
        house = IArtHouse(house_);
        pieceImplementation = pieceImplementation_;
    }

    // ---------- publication ----------

    /// @notice Curator publishes a piece's public traits, AES-256-GCM encrypted seed and keccak256(K). Re-settable
    /// until lock(); set once per id is counted.
    function setPiece(uint256 pieceId, Traits calldata traits, bytes calldata ciphertext, bytes32 commitment)
        external
        onlyOwner
    {
        if (locked) revert IsLocked();
        if (pieceId == 0 || pieceId > EDITIONS) revert BadPieceId();
        if (commitment == bytes32(0) || ciphertext.length == 0) revert BadPieceId();
        PieceData storage p = _pieces[pieceId];
        if (!p.set) {
            p.set = true;
            piecesSet += 1;
        }
        p.traits = traits;
        p.ciphertext = SSTORE2.write(ciphertext);
        p.commitment = commitment;
        emit PieceSet(pieceId, commitment, p.ciphertext);
    }

    function lock() external onlyOwner {
        if (locked) revert IsLocked();
        if (piecesSet != EDITIONS) revert NotAllSet();
        locked = true;
        emit Locked();
    }

    // ---------- sale control ----------

    function setPrice(uint256 newPrice) external onlyOwner {
        if (saleOpen) revert SaleIsOpen();
        if (newPrice == 0) revert WrongPrice();
        price = newPrice;
        emit PriceSet(newPrice);
    }

    function setSaleOpen(bool open) external onlyOwner {
        if (open) {
            if (!locked) revert NotLocked();
            if (price == 0) revert WrongPrice();
            if (address(vrfCoordinator) == address(0)) revert VRFNotConfigured();
        }
        saleOpen = open;
        emit SaleOpenSet(open);
    }

    /// @notice Set once after launch: Chainlink VRF v2.5 coordinator, key hash and the curator's subscription id.
    function configureVRF(address coordinator, bytes32 keyHash, uint256 subscriptionId, bool nativePayment)
        external
        onlyOwner
    {
        if (address(vrfCoordinator) != address(0)) revert VRFAlreadyConfigured();
        if (coordinator == address(0) || keyHash == bytes32(0) || subscriptionId == 0) revert VRFNotConfigured();
        vrfCoordinator = IVRFCoordinatorV2Plus(coordinator);
        vrfKeyHash = keyHash;
        vrfSubscriptionId = subscriptionId;
        vrfNativePayment = nativePayment;
        emit VRFConfigured(coordinator, keyHash, subscriptionId, nativePayment);
    }

    // ---------- buying ----------

    /// @notice Pay exactly `price` in ETH; the sale is recorded in the ledger and a VRF request assigns the edition.
    function buy(address broker) external payable nonReentrant returns (uint256 requestId) {
        if (!saleOpen) revert SaleClosed();
        if (msg.value != price) revert WrongPrice();
        if (sold >= EDITIONS) revert SoldOut();
        if (address(vrfCoordinator) == address(0)) revert VRFNotConfigured();
        sold += 1;
        house.recordSale{value: msg.value}(address(this), msg.sender, broker);
        requestId = _requestRandomness(msg.sender);
        emit Purchased(msg.sender, broker, requestId, msg.value);
    }

    /// @notice If the coordinator never answered a purchase's request (e.g. the subscription ran dry and Chainlink
    /// dropped it), the curator may ask again after VRF_RETRY_BLOCKS. The old id is forgotten, so a late answer
    /// to it is rejected as unknown and the buyer still gets exactly one edition.
    function rerequestRandomness(uint256 requestId) external onlyOwner returns (uint256 newRequestId) {
        address buyer = requestBuyer[requestId];
        if (buyer == address(0)) revert UnknownRequest();
        if (requestEdition[requestId] != 0) revert AlreadyFulfilled();
        if (block.number < requestBlock[requestId] + VRF_RETRY_BLOCKS) revert RequestTooRecent();
        delete requestBuyer[requestId];
        delete requestBlock[requestId];
        newRequestId = _requestRandomness(buyer);
        emit Rerequested(requestId, newRequestId, buyer);
    }

    function _requestRandomness(address buyer) private returns (uint256 requestId) {
        requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), vrfNativePayment)
            })
        );
        if (requestBuyer[requestId] != address(0)) revert AlreadyFulfilled();
        requestBuyer[requestId] = buyer;
        requestBlock[requestId] = block.number;
    }

    /// @notice VRF callback: assigns a uniformly random unassigned edition (Fisher-Yates over the remaining set).
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert NotCoordinator();
        address buyer = requestBuyer[requestId];
        if (buyer == address(0)) revert UnknownRequest();
        if (requestEdition[requestId] != 0) revert AlreadyFulfilled();
        uint16 left = uint16(EDITIONS - assigned);
        uint16 idx = uint16(randomWords[0] % left);
        uint16 edition = _pool[idx] == 0 ? idx + 1 : _pool[idx];
        uint16 lastIdx = left - 1;
        uint16 last = _pool[lastIdx] == 0 ? lastIdx + 1 : _pool[lastIdx];
        _pool[idx] = last;
        assigned += 1;
        requestEdition[requestId] = edition;
        editionBuyer[edition] = buyer;
        _editionsOf[buyer].push(edition);
        emit EditionAssigned(edition, buyer, requestId);
    }

    // ---------- claim ----------

    function registerViewingKey(bytes32 key) external {
        if (key == bytes32(0)) revert NoViewingKey();
        viewingKeyOf[msg.sender] = key;
        emit ViewingKeyRegistered(msg.sender, key);
    }

    /// @notice Curator posts K wrapped to the buyer's registered viewing key.
    function postWrappedKey(uint256 edition, bytes calldata wrapped) external onlyOwner {
        address buyer = editionBuyer[edition];
        if (buyer == address(0)) revert NotAssigned();
        if (pieceContract[edition] != address(0)) revert AlreadyClaimed();
        if (viewingKeyOf[buyer] == bytes32(0)) revert NoViewingKey();
        if (wrapped.length == 0) revert KeyNotPosted();
        _wrappedKey[edition] = wrapped;
        emit WrappedKeyPosted(edition);
    }

    /// @notice Deploys the edition's piece contract (EIP-1167 clone) and mints its single token to the buyer.
    function claim(uint256 edition) external nonReentrant returns (address piece) {
        address buyer = editionBuyer[edition];
        if (buyer == address(0)) revert NotAssigned();
        if (msg.sender != buyer && msg.sender != owner) revert NotBuyer();
        if (pieceContract[edition] != address(0)) revert AlreadyClaimed();
        bytes memory wrapped = _wrappedKey[edition];
        if (wrapped.length == 0) revert KeyNotPosted();
        piece = Clones.clone(pieceImplementation);
        pieceContract[edition] = piece;
        PieceData storage p = _pieces[edition];
        IArtifactsPiece(piece)
            .initialize(
                address(this), address(house), edition, buyer, p.traits, p.ciphertext, p.commitment, wrapped, false
            );
        emit Claimed(edition, buyer, piece);
    }

    // ---------- views ----------

    function remaining() external view returns (uint256) {
        return EDITIONS - sold;
    }

    function editionsOf(address buyer) external view returns (uint256[] memory) {
        return _editionsOf[buyer];
    }

    function traitsOf(uint256 pieceId) external view returns (Traits memory) {
        return _pieces[pieceId].traits;
    }

    function ciphertextOf(uint256 pieceId) external view returns (bytes memory) {
        address ptr = _pieces[pieceId].ciphertext;
        return ptr == address(0) ? bytes("") : SSTORE2.read(ptr);
    }

    function ciphertextPointer(uint256 pieceId) external view returns (address) {
        return _pieces[pieceId].ciphertext;
    }

    function commitmentOf(uint256 pieceId) external view returns (bytes32) {
        return _pieces[pieceId].commitment;
    }

    function isSet(uint256 pieceId) external view returns (bool) {
        return _pieces[pieceId].set;
    }

    function wrappedKeyOf(uint256 edition) external view returns (bytes memory) {
        return _wrappedKey[edition];
    }

    function vrfConfigured() external view returns (bool) {
        return address(vrfCoordinator) != address(0);
    }
}
