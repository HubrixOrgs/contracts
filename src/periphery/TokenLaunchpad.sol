// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {LaunchToken} from "../mocks/LaunchToken.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IPositionManagerLike {
    struct MintParamsLike {
        address tokenA;
        address tokenB;
        address hooks;
        uint24 feeSeed;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        address recipient;
        uint64 lockUntil;
    }

    function mint(MintParamsLike calldata p) external returns (uint256 tokenId);
    function collect(uint256 tokenId, address recipient) external returns (uint256 amount0, uint256 amount1);
    function PERMANENT_LOCK() external view returns (uint64);
    function ownerOf(uint256) external view returns (address);
}

/// @title Bonding-curve launchpad that graduates into permanently locked hook-pool liquidity.
/// @notice Supply: 1B tokens; 800M sold on a virtual x*y=k curve priced in ETH,
///         200M paired with the raised ETH at graduation. 1% curve trade fee
///         splits 50/50 protocol/creator. Graduation mints a position NFT with
///         a permanent lock; creator keeps 50% of graduation-pool LP fees.
contract TokenLaunchpad is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint24 public constant CURVE_FEE_BPS = 100; // 1.0%
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_ALLOCATION = 800_000_000 ether; // 80%
    uint256 public constant GRADUATION_ALLOCATION = 200_000_000 ether; // 20%
    uint256 public constant DEFAULT_GRADUATION_ETH = 4.395 ether;
    uint256 public constant VIRTUAL_ETH = 30 ether; // virtual ETH side of the curve

    struct Launch {
        address token;
        address creator;
        uint256 ethSide; // virtual ETH + raised ETH (WAD)
        uint256 tokenSide; // remaining sellable curve tokens
        uint256 realEth; // raised ETH (WAD)
        uint256 graduationEth; // threshold (overridable per launch, 0 = default)
        uint256 creatorFeePot; // claimable ETH (curve fees, creator half)
        uint256 positionTokenId; // graduation position (0 until graduated)
        bool graduated;
    }

    /// @custom:storage-location erc7201:tokenlaunchpad.storage.TokenLaunchpad
    struct LaunchpadStorage {
        IHub hub;
        IPoolManager manager;
        address hook;
        IWETH weth;
        IPositionManagerLike positions;
        mapping(uint256 => Launch) launches;
        uint256 nextId;
        uint256 protocolFeePot; // curve fees, protocol half (ETH)
    }

    // ERC-7201 slot for "tokenlaunchpad.storage.TokenLaunchpad"
    bytes32 private constant LP_STORAGE_SLOT = 0x9ffe5625ac6948930a3acd07f49aff8005130e6cdd174c529c4bdedcba8fa624;

    function _s() private pure returns (LaunchpadStorage storage $) {
        assembly {
            $.slot := LP_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error Paused();
    error Expired(uint256 deadline);
    error InsufficientOutput(uint256 got, uint256 min);
    error ZeroAmount();
    error UnknownLaunch(uint256 launchId);
    error NotCreator(uint256 launchId);
    error AlreadyGraduated(uint256 launchId);
    error NotGraduated(uint256 launchId);
    error InsufficientRaised(uint256 needed, uint256 have);
    error NothingToClaim();

    event LaunchCreated(uint256 indexed launchId, address indexed token, address indexed creator, string name, string symbol, uint256 graduationEth);
    event Bought(uint256 indexed launchId, address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 priceAfter);
    event Sold(uint256 indexed launchId, address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 priceAfter);
    event Graduated(uint256 indexed launchId, address indexed poolToken, uint256 indexed positionTokenId, uint256 pairedEth, uint256 pairedTokens);
    event CreatorFeesCollected(uint256 indexed launchId, address indexed creator, uint256 amount0, uint256 amount1);
    event CreatorFeePotClaimed(uint256 indexed launchId, address indexed creator, uint256 amountEth);
    event ProtocolFeesSwept(address indexed recipient, uint256 amountEth);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address manager_, address hook_, address weth_, address positions_, address admin)
        external
        initializer
    {
        if (hub_ == address(0) || manager_ == address(0) || hook_ == address(0) || weth_ == address(0)) {
            revert ZeroAddress();
        }
        if (positions_ == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        LaunchpadStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.manager = IPoolManager(manager_);
        $.hook = hook_;
        $.weth = IWETH(weth_);
        $.positions = IPositionManagerLike(positions_);
        $.nextId = 1;
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    function launchCount() external view returns (uint256) {
        return _s().nextId - 1;
    }

    function launch(uint256 launchId) external view returns (Launch memory) {
        return _s().launches[launchId];
    }

    /// @notice Spot price on the curve: ETH per token (WAD).
    function price(uint256 launchId) public view returns (uint256) {
        Launch storage l = _s().launches[launchId];
        return (l.ethSide * 1e18) / l.tokenSide;
    }

    function progressBps(uint256 launchId) external view returns (uint256) {
        Launch storage l = _s().launches[launchId];
        uint256 target = l.graduationEth == 0 ? DEFAULT_GRADUATION_ETH : l.graduationEth;
        return Math.min((l.realEth * 10_000) / target, 10_000);
    }

    // ---------- launch ----------

    /// @notice Create a launch with a fresh fixed-supply token.
    /// @param graduationEth 0 = default threshold (4.395 ETH).
    function create(string calldata name, string calldata symbol, uint256 graduationEth)
        external
        nonReentrant
        returns (uint256 launchId)
    {
        LaunchpadStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        LaunchToken token = new LaunchToken(name, symbol, address(this));
        launchId = _createLaunch(address(token), graduationEth);
        emit LaunchCreated(launchId, address(token), msg.sender, name, symbol, graduationEth);
    }

    function _createLaunch(address token, uint256 graduationEth) internal returns (uint256 launchId) {
        LaunchpadStorage storage $ = _s();
        launchId = $.nextId++;
        $.launches[launchId] = Launch({
            token: token,
            creator: msg.sender,
            ethSide: VIRTUAL_ETH,
            tokenSide: CURVE_ALLOCATION,
            realEth: 0,
            graduationEth: graduationEth,
            creatorFeePot: 0,
            positionTokenId: 0,
            graduated: false
        });
    }

    // ---------- curve trading ----------

    function buy(uint256 launchId, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        LaunchpadStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        Launch storage l = $.launches[launchId];
        if (l.token == address(0)) revert UnknownLaunch(launchId);
        if (l.graduated) revert AlreadyGraduated(launchId);
        uint256 ethIn = msg.value;
        if (ethIn == 0) revert ZeroAmount();

        uint256 fee = (ethIn * CURVE_FEE_BPS) / 10_000;
        uint256 netIn = ethIn - fee;
        l.creatorFeePot += fee / 2;
        $.protocolFeePot += fee - fee / 2;

        // dy = y * dx / (x + dx) on the virtual curve
        tokensOut = Math.mulDiv(l.tokenSide, netIn, l.ethSide + netIn);
        if (tokensOut < minTokensOut) revert InsufficientOutput(tokensOut, minTokensOut);
        l.ethSide += netIn;
        l.tokenSide -= tokensOut;
        l.realEth += netIn;

        LaunchToken(l.token).transfer(msg.sender, tokensOut);
        emit Bought(launchId, msg.sender, ethIn, tokensOut, price(launchId));
    }

    function sell(uint256 launchId, uint256 tokensIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        LaunchpadStorage storage $ = _s();
        Launch storage l = $.launches[launchId];
        if (l.token == address(0)) revert UnknownLaunch(launchId);
        if (l.graduated) revert AlreadyGraduated(launchId);
        if (tokensIn == 0) revert ZeroAmount();

        IERC20(l.token).safeTransferFrom(msg.sender, address(this), tokensIn);
        // dx = x * dy / (y + dy)
        ethOut = Math.mulDiv(l.ethSide, tokensIn, l.tokenSide + tokensIn);
        if (ethOut > l.realEth) {
            // cannot return more than was raised
            ethOut = l.realEth;
        }
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);

        uint256 fee = (ethOut * CURVE_FEE_BPS) / 10_000;
        uint256 netOut = ethOut - fee;
        l.creatorFeePot += fee / 2;
        $.protocolFeePot += fee - fee / 2;

        l.ethSide -= ethOut;
        l.tokenSide += tokensIn;
        l.realEth -= ethOut;

        (bool ok,) = msg.sender.call{value: netOut}("");
        require(ok, "eth transfer failed");
        emit Sold(launchId, msg.sender, tokensIn, ethOut, price(launchId));
    }

    // ---------- graduation ----------

    /// @notice Graduate into a hook pool with 200M tokens + raised ETH, locked forever.
    function graduate(uint256 launchId) external nonReentrant returns (uint256 positionTokenId) {
        LaunchpadStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        Launch storage l = $.launches[launchId];
        if (l.token == address(0)) revert UnknownLaunch(launchId);
        if (l.graduated) revert AlreadyGraduated(launchId);
        uint256 target = l.graduationEth == 0 ? DEFAULT_GRADUATION_ETH : l.graduationEth;
        if (l.realEth < target) revert InsufficientRaised(target, l.realEth);

        // wrap the raised ETH
        $.weth.deposit{value: l.realEth}();

        // seed the hook pool through the position manager; the implied price
        // (raised ETH / 200M tokens) sets the pool's initial price
        IERC20(l.token).forceApprove(address($.positions), GRADUATION_ALLOCATION);
        $.weth.approve(address($.positions), l.realEth);
        positionTokenId = $.positions.mint(
            IPositionManagerLike.MintParamsLike({
                tokenA: l.token,
                tokenB: address($.weth),
                hooks: $.hook,
                feeSeed: 0,
                amount0Desired: GRADUATION_ALLOCATION,
                amount1Desired: l.realEth,
                amount0Min: GRADUATION_ALLOCATION * 99 / 100,
                amount1Min: l.realEth * 99 / 100,
                deadline: block.timestamp + 1,
                recipient: address(this),
                lockUntil: $.positions.PERMANENT_LOCK()
            })
        );
        l.positionTokenId = positionTokenId;
        l.graduated = true;
        emit Graduated(launchId, l.token, positionTokenId, l.realEth, GRADUATION_ALLOCATION);
    }

    /// @notice Creator claims their 50% of accrued graduation-pool LP fees.
    function collectCreatorFees(uint256 launchId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LaunchpadStorage storage $ = _s();
        Launch storage l = $.launches[launchId];
        if (l.token == address(0)) revert UnknownLaunch(launchId);
        if (!l.graduated) revert NotGraduated(launchId);
        if (msg.sender != l.creator) revert NotCreator(launchId);
        (amount0, amount1) = $.positions.collect(l.positionTokenId, address(this));
        uint256 half0 = amount0 / 2;
        uint256 half1 = amount1 / 2;
        address feeTo = $.hub.feeRecipient();
        if (half0 > 0) IERC20(l.token).safeTransfer(feeTo, half0);
        if (amount1 - half1 > 0) IERC20(address($.weth)).safeTransfer(feeTo, amount1 - half1);
        if (amount0 - half0 > 0) IERC20(l.token).safeTransfer(l.creator, amount0 - half0);
        if (half1 > 0) IERC20(address($.weth)).safeTransfer(l.creator, half1);
        emit CreatorFeesCollected(launchId, l.creator, amount0 - half0, half1);
    }

    /// @notice Creator claims their ETH half of curve fees.
    function claimCreatorPot(uint256 launchId) external nonReentrant {
        LaunchpadStorage storage $ = _s();
        Launch storage l = $.launches[launchId];
        if (l.token == address(0)) revert UnknownLaunch(launchId);
        if (msg.sender != l.creator) revert NotCreator(launchId);
        uint256 amount = l.creatorFeePot;
        if (amount == 0) revert NothingToClaim();
        l.creatorFeePot = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth transfer failed");
        emit CreatorFeePotClaimed(launchId, l.creator, amount);
    }

    /// @notice Admin sweeps the protocol half of curve fees.
    function sweepProtocolFees() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        LaunchpadStorage storage $ = _s();
        uint256 amount = $.protocolFeePot;
        if (amount == 0) revert NothingToClaim();
        $.protocolFeePot = 0;
        address to = $.hub.feeRecipient();
        (bool ok,) = to.call{value: amount}("");
        require(ok, "eth transfer failed");
        emit ProtocolFeesSwept(to, amount);
    }

    receive() external payable {}

    /// @notice Accepts graduation position NFTs minted to the launchpad.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
