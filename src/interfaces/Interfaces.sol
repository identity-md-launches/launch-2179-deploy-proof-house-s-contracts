// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC2981 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
}

interface IArtHouse {
    function recordSale(address collection, address buyer, address broker) external payable;
    function recordResale(address broker, uint256 royalty, uint256 brokerShare) external payable;
    function isEligibleBroker(address broker) external view returns (bool);
    function royaltyFor(address collection, uint256 salePrice) external view returns (address, uint256);
    function pieceMetadata(address collection, uint256 pieceId)
        external
        view
        returns (string memory title, string memory description, bytes memory svg);
    function owner() external view returns (address);
}

interface IArtCollection {
    function initialize(address house, string calldata name_, string calldata symbol_) external;
    function mint(address to, uint256 tokenId) external;
}

/// @notice Chainlink VRF v2.5 coordinator surface used by ArtifactsFactory.
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

struct Traits {
    string title;
    string palette;
    uint8 colourCount;
    string direction;
}

interface IArtifactsPiece {
    function initialize(
        address controller,
        address house,
        uint256 pieceId,
        address to,
        Traits calldata traits,
        address ciphertext,
        bytes32 commitment,
        bytes calldata wrappedKey,
        bool isSource
    ) external;
    function rewrapFor(bytes calldata wrapped) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice A sale module that deploys piece contracts answers whether a contract is one of its pieces.
interface IPieceRegistry {
    function isPiece(address piece) external view returns (bool);
}

interface IPieceController {
    function controller() external view returns (address);
}

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice What an ArtifactsPiece needs from THE SOURCE's controller to serve the revealed tokenURI.
/// @notice What THE SOURCE's piece reads from ArtifactsSource: its renderer page and its encrypted seed.
interface ISourceStore {
    function rendererChunks() external view returns (address[] memory);
    function locked() external view returns (bool);
    function sealedSeed() external view returns (bytes32);
}
