// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {Clones} from "./libs/Clones.sol";
import {ArtStorage} from "./ArtStorage.sol";
import {ArtCollection} from "./ArtCollection.sol";
import {IERC20, IArtCollection} from "./interfaces/Interfaces.sol";

/// @notice Proof House ledger: artists, brokers, sale modules, per-collection splits, balances per currency,
/// plain SVG collections (curation, pricing, minting) and open submissions. Owner = curator.
contract ArtHouse is TwoStepOwnable, ReentrancyGuard {
    // ---------- constants ----------
    uint16 public constant BPS = 10_000;
    uint16 public constant ROYALTY_BPS = 750;
    uint16 public constant DEFAULT_BROKER_BPS = 1500;
    uint16 public constant DEFAULT_HOUSE_BPS = 1500;
    uint16 public constant DEFAULT_ARTIST_BPS = 7000;
    uint256 public constant MAX_PIECE_BYTES = 100_000;
    address public constant ETH = address(0);

    // ---------- immutables ----------
    ArtStorage public immutable artStorage;
    address public immutable imd;
    address public immutable collectionImplementation;

    // ---------- types ----------
    struct Artist {
        string name;
        address payout;
        bool approved;
    }

    struct Collection {
        bool exists;
        bool isModule; // sold by an approved sale module (e.g. ArtifactsFactory) rather than by mint()
        bool open;
        bool isSealed;
        address artist;
        uint16 brokerBps;
        uint16 houseBps;
        uint16 artistBps;
        uint256 pieceCount;
        uint256 priceETH;
        uint256 priceIMD;
    }

    struct Piece {
        bytes32 contentHash;
        string title;
        string description;
        bool finalized;
        bool minted;
        uint256 size;
    }

    enum SubmissionStatus {
        Pending,
        Accepted,
        Rejected
    }

    struct Submission {
        address submitter;
        bytes32 contentHash;
        string previewURI;
        SubmissionStatus status;
    }

    // ---------- state ----------
    mapping(address => Artist) public artists;
    mapping(address => bool) public brokers;
    mapping(address => bool) public saleModules;
    mapping(address => Collection) public collections;
    mapping(address => mapping(uint256 => Piece)) public pieces;
    // party => currency => balance; the house's own balance is keyed by address(this)
    mapping(address => mapping(address => uint256)) public balances;
    Submission[] public submissions;
    address[] public collectionList;

    // ---------- events ----------
    event ArtistApproved(address indexed artist, string name, address payout);
    event ArtistRevoked(address indexed artist);
    event PayoutChanged(address indexed artist, address payout);
    event BrokerSet(address indexed broker, bool approved);
    event SaleModuleSet(address indexed module, bool approved);
    event CollectionCreated(address indexed collection, address indexed artist, string name, string symbol);
    event ModuleCollectionRegistered(address indexed collection, address indexed artist);
    event SplitSet(address indexed collection, uint16 brokerBps, uint16 houseBps, uint16 artistBps);
    event PricesSet(address indexed collection, uint256 priceETH, uint256 priceIMD);
    event SaleOpenSet(address indexed collection, bool open);
    event PieceRegistered(address indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event PieceUpdated(address indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event PieceCleared(address indexed collection, uint256 indexed pieceId);
    event PieceFinalized(address indexed collection, uint256 indexed pieceId);
    event CollectionSealed(address indexed collection);
    event Sale(
        address indexed collection,
        address indexed buyer,
        address indexed broker,
        address currency,
        uint256 amount,
        uint256 brokerShare,
        uint256 houseShare,
        uint256 artistShare
    );
    event Withdrawn(address indexed party, address indexed currency, address to, uint256 amount);
    event Submitted(uint256 indexed id, address indexed submitter, bytes32 contentHash, string previewURI);
    event SubmissionDecided(uint256 indexed id, SubmissionStatus status);

    // ---------- errors ----------
    error NotApprovedArtist();
    error NotArtist();
    error NotSaleModule();
    error UnknownCollection();
    error BadSplit();
    error BadPieceId();
    error BadIndex();
    error Sealed();
    error NotSealed();
    error Finalized();
    error NotFinalized();
    error TooLarge();
    error HashMismatch();
    error SaleClosed();
    error WrongPrice();
    error AlreadyMinted();
    error NothingToWithdraw();
    error TransferFailed();
    error NotCurator();
    error BadSubmission();
    error NotPending();
    error NotModuleCollection();

    constructor(address owner_, address storage_, address imd_) TwoStepOwnable(owner_) {
        if (storage_ == address(0) || imd_ == address(0)) revert ZeroAddress();
        artStorage = ArtStorage(storage_);
        imd = imd_;
        collectionImplementation = address(new ArtCollection());
    }

    // ---------- artists & brokers ----------

    function approveArtist(address artist, string calldata name_) external onlyOwner {
        if (artist == address(0)) revert ZeroAddress();
        Artist storage a = artists[artist];
        a.name = name_;
        a.approved = true;
        if (a.payout == address(0)) a.payout = artist; // kept across re-approval once the artist changed it
        emit ArtistApproved(artist, name_, a.payout);
    }

    function revokeArtist(address artist) external onlyOwner {
        artists[artist].approved = false;
        emit ArtistRevoked(artist);
    }

    /// @notice Only the artist can change where their earnings and royalties go.
    function setPayout(address payout) external {
        if (artists[msg.sender].payout == address(0)) revert NotArtist();
        if (payout == address(0)) revert ZeroAddress();
        artists[msg.sender].payout = payout;
        emit PayoutChanged(msg.sender, payout);
    }

    function setBroker(address broker, bool approved) external onlyOwner {
        brokers[broker] = approved;
        emit BrokerSet(broker, approved);
    }

    function setSaleModule(address module, bool approved) external onlyOwner {
        saleModules[module] = approved;
        emit SaleModuleSet(module, approved);
    }

    // ---------- collections ----------

    function createCollection(string calldata name_, string calldata symbol_, address artist)
        external
        onlyOwner
        returns (address collection)
    {
        if (!artists[artist].approved) revert NotApprovedArtist();
        collection = Clones.clone(collectionImplementation);
        IArtCollection(collection).initialize(address(this), name_, symbol_);
        _newCollection(collection, artist, false);
        emit CollectionCreated(collection, artist, name_, symbol_);
    }

    /// @notice Registers a sale module (e.g. ArtifactsFactory) as a collection for splits and royalties.
    function registerModuleCollection(address module, address artist) external onlyOwner {
        if (!artists[artist].approved) revert NotApprovedArtist();
        if (collections[module].exists) revert UnknownCollection();
        _newCollection(module, artist, true);
        emit ModuleCollectionRegistered(module, artist);
    }

    function _newCollection(address collection, address artist, bool isModule) private {
        Collection storage c = collections[collection];
        c.exists = true;
        c.isModule = isModule;
        c.artist = artist;
        c.brokerBps = DEFAULT_BROKER_BPS;
        c.houseBps = DEFAULT_HOUSE_BPS;
        c.artistBps = DEFAULT_ARTIST_BPS;
        collectionList.push(collection);
    }

    function setSplit(address collection, uint16 brokerBps, uint16 houseBps, uint16 artistBps) external onlyOwner {
        if (!collections[collection].exists) revert UnknownCollection();
        if (uint256(brokerBps) + houseBps + artistBps != BPS) revert BadSplit();
        Collection storage c = collections[collection];
        c.brokerBps = brokerBps;
        c.houseBps = houseBps;
        c.artistBps = artistBps;
        emit SplitSet(collection, brokerBps, houseBps, artistBps);
    }

    function setPrices(address collection, uint256 priceETH, uint256 priceIMD) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        c.priceETH = priceETH;
        c.priceIMD = priceIMD;
        emit PricesSet(collection, priceETH, priceIMD);
    }

    function setSaleOpen(address collection, bool open) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (open && !c.isSealed) revert NotSealed();
        c.open = open;
        emit SaleOpenSet(collection, open);
    }

    function collectionCount() external view returns (uint256) {
        return collectionList.length;
    }

    // ---------- piece curation (plain SVG) ----------

    /// @dev The curator, or the collection's artist while still approved: revocation ends curation rights too.
    function _curatorOrArtist(Collection storage c) private view {
        if (msg.sender == owner) return;
        if (msg.sender != c.artist || !artists[c.artist].approved) revert NotCurator();
    }

    function registerPiece(
        address collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (c.isSealed) revert Sealed();
        if (pieceId != c.pieceCount) revert BadPieceId();
        c.pieceCount = pieceId + 1;
        Piece storage p = pieces[collection][pieceId];
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceRegistered(collection, pieceId, contentHash, title);
    }

    /// @notice Corrects an unfinalized piece's content hash, title and description (a mistyped hash would otherwise
    /// leave the collection unsealable forever). Uploaded chunks are kept; finalizePiece checks against the new hash.
    function updatePiece(
        address collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (c.isSealed) revert Sealed();
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceUpdated(collection, pieceId, contentHash, title);
    }

    function uploadChunk(address collection, uint256 pieceId, uint256 index, bytes calldata data) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        if (index != artStorage.chunkCount(collection, pieceId)) revert BadIndex();
        p.size += data.length;
        if (p.size > MAX_PIECE_BYTES) revert TooLarge();
        artStorage.write(collection, pieceId, index, data);
    }

    /// @notice The curator may wipe an unfinalized piece's chunks so they can be re-uploaded.
    function clearPiece(address collection, uint256 pieceId) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        p.size = 0;
        artStorage.clear(collection, pieceId);
        emit PieceCleared(collection, pieceId);
    }

    function finalizePiece(address collection, uint256 pieceId) external {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        _curatorOrArtist(c);
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (p.finalized) revert Finalized();
        if (p.size == 0 || keccak256(artStorage.read(collection, pieceId)) != p.contentHash) revert HashMismatch();
        p.finalized = true;
        emit PieceFinalized(collection, pieceId);
    }

    function sealCollection(address collection) external onlyOwner {
        Collection storage c = collections[collection];
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (c.isSealed) revert Sealed();
        if (c.pieceCount == 0) revert NotFinalized();
        for (uint256 i; i < c.pieceCount; ++i) {
            if (!pieces[collection][i].finalized) revert NotFinalized();
        }
        c.isSealed = true;
        emit CollectionSealed(collection);
    }

    // ---------- buying ----------

    function mint(address collection, uint256 pieceId, address broker) external payable nonReentrant {
        Collection storage c = collections[collection];
        _checkMintable(c, collection, pieceId);
        if (c.priceETH == 0 || msg.value != c.priceETH) revert WrongPrice();
        pieces[collection][pieceId].minted = true;
        _credit(collection, msg.sender, broker, ETH, msg.value);
        IArtCollection(collection).mint(msg.sender, pieceId);
    }

    function mintWithIMD(address collection, uint256 pieceId, address broker, uint256 price) external nonReentrant {
        Collection storage c = collections[collection];
        _checkMintable(c, collection, pieceId);
        if (c.priceIMD == 0 || price != c.priceIMD) revert WrongPrice();
        pieces[collection][pieceId].minted = true;
        _credit(collection, msg.sender, broker, imd, price);
        _pullIMD(msg.sender, price);
        IArtCollection(collection).mint(msg.sender, pieceId);
    }

    function _checkMintable(Collection storage c, address collection, uint256 pieceId) private view {
        if (!c.exists || c.isModule) revert UnknownCollection();
        if (!c.open) revert SaleClosed();
        if (pieceId >= c.pieceCount) revert BadPieceId();
        Piece storage p = pieces[collection][pieceId];
        if (!p.finalized) revert NotFinalized();
        if (p.minted) revert AlreadyMinted();
    }

    function _pullIMD(address from, uint256 amount) private {
        IERC20 token = IERC20(imd);
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
        if (token.balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    /// @notice Approved sale modules record an ETH sale of a module collection; the ETH comes with the call.
    function recordSale(address collection, address buyer, address broker) external payable {
        if (!saleModules[msg.sender]) revert NotSaleModule();
        Collection storage c = collections[collection];
        if (!c.exists || !c.isModule) revert NotModuleCollection();
        if (msg.value == 0) revert WrongPrice();
        _credit(collection, buyer, broker, ETH, msg.value);
    }

    function _credit(address collection, address buyer, address broker, address currency, uint256 amount) private {
        Collection storage c = collections[collection];
        uint256 artistShare = (amount * c.artistBps) / BPS;
        uint256 brokerShare;
        if (broker != address(0) && broker != buyer && brokers[broker]) {
            brokerShare = (amount * c.brokerBps) / BPS;
            balances[broker][currency] += brokerShare;
        } else {
            broker = address(0);
        }
        uint256 houseShare = amount - artistShare - brokerShare; // rounding and any unearned broker share
        balances[c.artist][currency] += artistShare;
        balances[address(this)][currency] += houseShare;
        emit Sale(collection, buyer, broker, currency, amount, brokerShare, houseShare, artistShare);
    }

    // ---------- withdrawals ----------

    /// @notice Artists and brokers withdraw their own balance; an artist's goes to their payout address.
    function withdraw(address currency) external nonReentrant {
        uint256 amount = balances[msg.sender][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[msg.sender][currency] = 0;
        address to = artists[msg.sender].payout;
        if (to == address(0)) to = msg.sender;
        _pay(currency, to, amount);
        emit Withdrawn(msg.sender, currency, to, amount);
    }

    /// @notice The house balance goes to the current owner.
    function withdrawHouse(address currency) external nonReentrant onlyOwner {
        uint256 amount = balances[address(this)][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[address(this)][currency] = 0;
        _pay(currency, owner, amount);
        emit Withdrawn(address(this), currency, owner, amount);
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (currency == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20(currency).transfer(to, amount)) revert TransferFailed();
        }
    }

    // ---------- views for collections ----------

    function royaltyFor(address collection, uint256 salePrice) external view returns (address, uint256) {
        Collection storage c = collections[collection];
        if (!c.exists) revert UnknownCollection();
        return (artists[c.artist].payout, (salePrice * ROYALTY_BPS) / BPS);
    }

    function pieceMetadata(address collection, uint256 pieceId)
        external
        view
        returns (string memory title, string memory description, bytes memory svg)
    {
        Piece storage p = pieces[collection][pieceId];
        return (p.title, p.description, artStorage.read(collection, pieceId));
    }

    function artistPayout(address artist) external view returns (address) {
        return artists[artist].payout;
    }

    // ---------- submissions ----------

    function submit(bytes32 contentHash, string calldata previewURI) external returns (uint256 id) {
        if (contentHash == bytes32(0)) revert BadSubmission();
        id = submissions.length;
        submissions.push(Submission(msg.sender, contentHash, previewURI, SubmissionStatus.Pending));
        emit Submitted(id, msg.sender, contentHash, previewURI);
    }

    function decideSubmission(uint256 id, bool accept) external onlyOwner {
        if (id >= submissions.length) revert BadSubmission();
        Submission storage s = submissions[id];
        if (s.status != SubmissionStatus.Pending) revert NotPending();
        s.status = accept ? SubmissionStatus.Accepted : SubmissionStatus.Rejected;
        emit SubmissionDecided(id, s.status);
    }

    function submissionCount() external view returns (uint256) {
        return submissions.length;
    }
}
