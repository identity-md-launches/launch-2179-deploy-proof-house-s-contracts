// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Lite} from "./base/ERC721Lite.sol";
import {Encoding} from "./libs/Encoding.sol";
import {IOwnerOf} from "./interfaces/Interfaces.sol";

interface IFactoryPieces {
    function pieceContract(uint256 edition) external view returns (address);
}

interface ISourcePiece {
    function pieceContract() external view returns (address);
}

interface IOwned {
    function owner() external view returns (address);
}

/// @notice Proof House Broker Pass: at most 100, free to claim, transferable, with no owner and no power over
/// holders. Holding one makes a wallet a Proof House broker (ArtHouse.isEligibleBroker). A pass is claimed with an
/// NFT the caller holds: an ARTIFACTS piece (1 to 255, or 256 for THE SOURCE) or an identity.md seat. Each piece id
/// and each seat id claims once, ever, so passes cannot be farmed with fresh wallets; and each wallet claims once,
/// ever, so a wallet holding many seats or pieces still claims one pass. Claims open at a start time the curator (the
/// owner of ArtifactsFactory) sets once, at launch; until then nobody can claim, and once set it never changes.
contract BrokerPass is ERC721Lite {
    uint256 public constant MAX_SUPPLY = 100;
    uint256 public constant SOURCE_ID = 256;

    IOwnerOf public immutable seats; // identity.md seats (ERC-721)
    address public immutable factory; // ArtifactsFactory: editions 1 to 255
    address public immutable source; // ArtifactsSource: THE SOURCE, 256

    uint256 public totalSupply;
    mapping(uint256 => bool) public pieceClaimed;
    mapping(uint256 => bool) public seatClaimed;
    mapping(address => bool) public walletClaimed;
    /// @notice When claims open: 0 until the curator sets it, then fixed forever.
    uint64 public claimsOpenAt;

    event PassClaimed(address indexed to, uint256 indexed passId, bool bySeat, uint256 usedId);
    event ClaimsOpenAtSet(uint64 at);

    error ZeroAddress();
    error AllClaimed();
    error AlreadyClaimed();
    error NotHolder();
    error NoSuchPiece();
    error WalletAlreadyClaimed();
    error ClaimsNotOpen();
    error NotCurator();
    error StartAlreadySet();
    error BadStart();

    constructor(address seats_, address factory_, address source_) {
        if (seats_ == address(0) || factory_ == address(0) || source_ == address(0)) revert ZeroAddress();
        seats = IOwnerOf(seats_);
        factory = factory_;
        source = source_;
        _name = "Proof House Broker Pass";
        _symbol = "PHPASS";
    }

    /// @notice The curator sets when claims open, once: a time in the past or now opens them at once, and no more
    /// than a year ahead (a mistyped far-off time would shut claims for good). It can never change after that, so
    /// nobody can claim early and nobody can close claims again.
    function setClaimsOpenAt(uint64 at) external {
        if (msg.sender != IOwned(factory).owner()) revert NotCurator();
        if (claimsOpenAt != 0) revert StartAlreadySet();
        if (at == 0 || at > block.timestamp + 365 days) revert BadStart();
        claimsOpenAt = at;
        emit ClaimsOpenAtSet(at);
    }

    /// @notice True once the start time is set and reached.
    function claimsOpen() public view returns (bool) {
        return claimsOpenAt != 0 && block.timestamp >= claimsOpenAt;
    }

    /// @notice Claim a pass with an ARTIFACTS piece the caller holds now. Each piece claims once, ever.
    function claimWithPiece(uint256 pieceId) external returns (uint256 passId) {
        if (!claimsOpen()) revert ClaimsNotOpen();
        if (walletClaimed[msg.sender]) revert WalletAlreadyClaimed();
        if (pieceClaimed[pieceId]) revert AlreadyClaimed();
        address piece;
        if (pieceId >= 1 && pieceId <= 255) piece = IFactoryPieces(factory).pieceContract(pieceId);
        else if (pieceId == SOURCE_ID) piece = ISourcePiece(source).pieceContract();
        if (piece == address(0)) revert NoSuchPiece(); // unclaimed editions have no contract yet
        if (IOwnerOf(piece).ownerOf(1) != msg.sender) revert NotHolder();
        pieceClaimed[pieceId] = true;
        passId = _issue(msg.sender);
        emit PassClaimed(msg.sender, passId, false, pieceId);
    }

    /// @notice Claim a pass with an identity.md seat the caller holds now. Each seat claims once, ever.
    function claimWithSeat(uint256 seatId) external returns (uint256 passId) {
        if (!claimsOpen()) revert ClaimsNotOpen();
        if (walletClaimed[msg.sender]) revert WalletAlreadyClaimed();
        if (seatClaimed[seatId]) revert AlreadyClaimed();
        if (seats.ownerOf(seatId) != msg.sender) revert NotHolder();
        seatClaimed[seatId] = true;
        passId = _issue(msg.sender);
        emit PassClaimed(msg.sender, passId, true, seatId);
    }

    function _issue(address to) private returns (uint256 id) {
        if (totalSupply >= MAX_SUPPLY) revert AllClaimed();
        id = ++totalSupply;
        walletClaimed[to] = true;
        _mint(to, id); // no receiver callback: claiming cannot re-enter
    }

    function remaining() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply;
    }

    function tokenURI(uint256 passId) external view returns (string memory) {
        ownerOf(passId);
        string memory no = Encoding.pad3(passId);
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 600 600' font-family='Menlo,monospace'>",
            "<rect width='600' height='600' fill='#ECEADF'/>",
            "<rect x='40' y='40' width='520' height='520' fill='none' stroke='#141414' stroke-width='6'/>",
            "<text x='72' y='120' font-size='22' letter-spacing='4' fill='#141414'>PROOF HOUSE</text>",
            "<text x='72' y='300' font-size='64' font-weight='700' fill='#141414'>BROKER</text>",
            "<text x='72' y='370' font-size='64' font-weight='700' fill='#141414'>PASS</text>",
            "<text x='72' y='500' font-size='22' letter-spacing='2' fill='#141414'>No. ",
            no,
            " of 100 / 15% on every sale you bring</text></svg>"
        );
        bytes memory json = abi.encodePacked(
            '{"name":"Proof House Broker Pass #',
            no,
            '","description":"Holding this pass makes your wallet a Proof House broker: name it on a sale and the contract pays you the broker share.","attributes":[{"trait_type":"Pass","value":',
            Encoding.toString(passId),
            '}],"image":"data:image/svg+xml;base64,',
            Encoding.base64(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Encoding.base64(json));
    }
}
