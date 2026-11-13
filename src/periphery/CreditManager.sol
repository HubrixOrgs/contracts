// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";

interface IPositionManagerNFT {
    function safeTransferFrom(address, address, uint256) external;
    function positionPool(uint256 tokenId) external view returns (bytes32 poolId);
    function positionAmounts(uint256 tokenId)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 feesOwed0, uint256 feesOwed1);
}

interface IVaultLike {
    function asset() external view returns (address);
    function borrowTo(address to, uint256 amount) external;
    function repayFrom(uint256 amount) external;
}

/// @title Borrow against pledged position NFTs, funded by the lending vault.
/// @notice Loans: pledge NFT -> borrow <= 50% of valuation -> repay with
///         per-second interest -> unpledge. Underwater loans (health factor < 1)
///         are liquidated by keepers who repay the debt and seize the NFT.
/// @dev Debt model: `normDebt`/`normPrincipal` are RAY-normalized
///      (currentDebt = normDebt * borrowIndex / RAY); the global borrowIndex
///      compounds per second from the utilization curve.
contract CreditManager is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR = 365 days;

    struct Loan {
        uint256 positionTokenId;
        address owner;
        uint256 normDebt; // RAY-normalized total debt
        uint256 normPrincipal; // RAY-normalized principal (interest = debt - principal)
        bool active;
    }

    /// @custom:storage-location erc7201:creditmanager.storage.CreditManager
    struct CMStorage {
        IHub hub;
        IVaultLike vault;
        IPositionManagerNFT positions;
        IPoolManager manager;
        uint24 ltvBps; // 5_000 = 50%
        uint24 liquidationThresholdBps; // 6_500
        uint24 liquidationPenaltyBps; // 800
        uint24 baseAprBps; // 500 = 5%
        uint24 slopeAprBps; // 3_000 = 30% per unit utilization
        uint24 maxAprBps; // 20_000 = 200%
        uint24 reserveFactorBps; // 1_000 = 10% of interest to protocol
        uint64 staleness;
        uint256 borrowIndex; // RAY
        uint64 lastAccrual;
        uint256 totalDebt; // current debt of all loans (asset units)
        mapping(uint256 => Loan) loans;
        mapping(uint256 => uint256) loanByToken; // positionTokenId -> loanId (0 = none)
        uint256 nextLoanId;
    }

    // ERC-7201 slot for "creditmanager.storage.CreditManager"
    bytes32 private constant CM_STORAGE_SLOT = 0xa3a114f90d6383c0b9ec61268eab9c227be4a1645ea88d43d718a0fcc3e48700;

    function _s() private pure returns (CMStorage storage $) {
        assembly {
            $.slot := CM_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error Paused();
    error UnknownLoan(uint256 loanId);
    error NotLoanOwner(uint256 loanId);
    error AlreadyPledged(uint256 positionTokenId);
    error ExceedsLtv(uint256 newDebt, uint256 maxDebt);
    error DebtOutstanding(uint256 debt);
    error LoanHealthy(uint256 debt, uint256 thresholdValue);
    error ZeroAmount();
    error OracleStale();
    error NoOracle(address token);
    error BadRiskParams();
    error WrongSender();

    event Pledged(uint256 indexed loanId, uint256 indexed positionTokenId, address indexed owner);
    event Borrowed(uint256 indexed loanId, address indexed borrower, uint256 amount, uint256 debtAfter);
    event Repaid(uint256 indexed loanId, address indexed payer, uint256 amount, uint256 debtAfter);
    event Unpledged(uint256 indexed loanId, uint256 indexed positionTokenId, address indexed owner);
    event Liquidated(uint256 indexed loanId, uint256 indexed positionTokenId, address indexed liquidator, uint256 debtPaid);
    event RiskParamsUpdated();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address vault_, address positions_, address manager_, address admin)
        external
        initializer
    {
        if (hub_ == address(0) || vault_ == address(0) || positions_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        CMStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.vault = IVaultLike(vault_);
        $.positions = IPositionManagerNFT(positions_);
        $.manager = IPoolManager(manager_);
        $.ltvBps = 5_000;
        $.liquidationThresholdBps = 6_500;
        $.liquidationPenaltyBps = 800;
        $.baseAprBps = 500;
        $.slopeAprBps = 3_000;
        $.maxAprBps = 20_000;
        $.reserveFactorBps = 1_000;
        $.staleness = 24 hours;
        $.borrowIndex = RAY;
        $.lastAccrual = uint64(block.timestamp);
        $.nextLoanId = 1;
    }

    function setRiskParams(
        uint24 ltvBps,
        uint24 liquidationThresholdBps,
        uint24 liquidationPenaltyBps,
        uint24 baseAprBps,
        uint24 slopeAprBps,
        uint24 maxAprBps,
        uint24 reserveFactorBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CMStorage storage $ = _s();
        if (ltvBps >= liquidationThresholdBps || liquidationThresholdBps > 10_000) revert BadRiskParams();
        if (maxAprBps < baseAprBps || reserveFactorBps > 5_000) revert BadRiskParams();
        $.ltvBps = ltvBps;
        $.liquidationThresholdBps = liquidationThresholdBps;
        $.liquidationPenaltyBps = liquidationPenaltyBps;
        $.baseAprBps = baseAprBps;
        $.slopeAprBps = slopeAprBps;
        $.maxAprBps = maxAprBps;
        $.reserveFactorBps = reserveFactorBps;
        emit RiskParamsUpdated();
    }

    // ---------- views ----------

    function loan(uint256 loanId) external view returns (Loan memory) {
        return _s().loans[loanId];
    }

    function loanOf(uint256 positionTokenId) external view returns (uint256) {
        return _s().loanByToken[positionTokenId];
    }

    function pledgedToken(uint256 positionTokenId) public view returns (bool) {
        return _s().loanByToken[positionTokenId] != 0;
    }

    function riskParams()
        external
        view
        returns (
            uint24 ltvBps,
            uint24 liquidationThresholdBps,
            uint24 liquidationPenaltyBps,
            uint24 baseAprBps,
            uint24 slopeAprBps,
            uint24 maxAprBps,
            uint24 reserveFactorBps,
            uint64 staleness
        )
    {
        CMStorage storage $ = _s();
        return (
            $.ltvBps,
            $.liquidationThresholdBps,
            $.liquidationPenaltyBps,
            $.baseAprBps,
            $.slopeAprBps,
            $.maxAprBps,
            $.reserveFactorBps,
            $.staleness
        );
    }

    function borrowIndex() external view returns (uint256) {
        return _s().borrowIndex;
    }

    function totalDebt() external view returns (uint256) {
        return _s().totalDebt;
    }

    /// @notice Current total debt of a loan (asset units).
    function debtOf(uint256 loanId) public view returns (uint256) {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        if (!l.active) return 0;
        (uint256 idx,) = _accruedIndex();
        return (l.normDebt * idx) / RAY;
    }

    /// @notice Current principal portion of a loan (asset units).
    function principalOf(uint256 loanId) external view returns (uint256) {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        (uint256 idx,) = _accruedIndex();
        return (l.normPrincipal * idx) / RAY;
    }

    /// @notice Utilization-based borrow APR (bps). Uses the current total debt
    ///         (not projected) so it is callable from the accrual path.
    function borrowAprBps() public view returns (uint24) {
        CMStorage storage $ = _s();
        uint256 cash = IERC20($.vault.asset()).balanceOf(address($.vault));
        uint256 debt = $.totalDebt;
        uint256 util = debt == 0 ? 0 : (debt * 1e18) / (debt + cash);
        uint256 apr = $.baseAprBps + (($.slopeAprBps * util) / 1e18);
        if (apr > $.maxAprBps) apr = $.maxAprBps;
        return uint24(apr);
    }

    function supplyAprBps() external view returns (uint24) {
        CMStorage storage $ = _s();
        uint256 apr = borrowAprBps();
        uint256 cash = IERC20($.vault.asset()).balanceOf(address($.vault));
        uint256 debt = $.totalDebt;
        uint256 util = debt == 0 ? 0 : (debt * 1e18) / (debt + cash);
        uint256 supply = (((apr * util) / 1e18) * (10_000 - $.reserveFactorBps)) / 10_000;
        return uint24(Math.min(supply, $.maxAprBps));
    }

    /// @notice USD valuation (WAD, 18d) of a position NFT via registered oracles.
    function valuation(uint256 positionTokenId) public view returns (uint256 usdWad) {
        CMStorage storage $ = _s();
        (, uint256 a0, uint256 a1,,) = $.positions.positionAmounts(positionTokenId);
        bytes32 poolId = $.positions.positionPool(positionTokenId);
        (address t0, address t1) = $.manager.poolTokens(poolId);
        usdWad = _usdValue(t0, a0) + _usdValue(t1, a1);
    }

    /// @notice Health factor in RAY: valuation * liqThreshold / debt. > 1e27 = healthy.
    function healthFactor(uint256 loanId) external view returns (uint256) {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        uint256 debt = debtOf(loanId);
        if (debt == 0) return type(uint256).max;
        return (valuation(l.positionTokenId) * $.liquidationThresholdBps * RAY) / (debt * 10_000);
    }

    // ---------- loan lifecycle ----------

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        CMStorage storage $ = _s();
        if (msg.sender != address($.positions)) revert WrongSender();
        if ($.loanByToken[tokenId] != 0) revert AlreadyPledged(tokenId);
        uint256 loanId = $.nextLoanId++;
        $.loans[loanId] = Loan({
            positionTokenId: tokenId,
            owner: from,
            normDebt: 0,
            normPrincipal: 0,
            active: true
        });
        $.loanByToken[tokenId] = loanId;
        emit Pledged(loanId, tokenId, from);
        return IERC721Receiver.onERC721Received.selector;
    }

    function borrow(uint256 loanId, uint256 amount) external nonReentrant returns (uint256) {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        if (!l.active) revert UnknownLoan(loanId);
        if (msg.sender != l.owner) revert NotLoanOwner(loanId);
        if (amount == 0) revert ZeroAmount();
        if ($.hub.paused()) revert Paused();
        _accrue();
        uint256 debt = (l.normDebt * $.borrowIndex) / RAY;
        uint256 maxDebt = (valuation(l.positionTokenId) * $.ltvBps) / 10_000;
        if (debt + amount > maxDebt) revert ExceedsLtv(debt + amount, maxDebt);
        l.normDebt += (amount * RAY) / $.borrowIndex;
        l.normPrincipal += (amount * RAY) / $.borrowIndex;
        $.totalDebt += amount;
        $.vault.borrowTo(msg.sender, amount);
        emit Borrowed(loanId, msg.sender, amount, debt + amount);
        return amount;
    }

    /// @notice Repay debt (partial or full). Anyone may repay.
    function repay(uint256 loanId, uint256 amount) external nonReentrant returns (uint256 debtAfter) {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        if (!l.active) revert UnknownLoan(loanId);
        if (amount == 0) revert ZeroAmount();
        _accrue();
        uint256 debt = (l.normDebt * $.borrowIndex) / RAY;
        if (amount > debt) amount = debt;
        uint256 principal = (l.normPrincipal * $.borrowIndex) / RAY;
        uint256 outstandingInterest = debt - principal;
        uint256 interestPortion = amount > outstandingInterest ? outstandingInterest : amount;

        IERC20 asset = IERC20($.vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 reserve = (interestPortion * $.reserveFactorBps) / 10_000;
        asset.forceApprove(address($.vault), amount - reserve);
        $.vault.repayFrom(amount - reserve);
        if (reserve > 0) asset.safeTransfer($.hub.feeRecipient(), reserve);

        // principal reduction (in normalized units)
        uint256 principalPaid = amount - interestPortion;
        l.normPrincipal -= (principalPaid * RAY) / $.borrowIndex;
        l.normDebt -= (amount * RAY) / $.borrowIndex;
        $.totalDebt -= Math.min(amount, $.totalDebt);
        // forgive rounding dust so full repayments can close the loan
        if ((l.normDebt * $.borrowIndex) / RAY <= 1e6) {
            $.totalDebt -= Math.min((l.normDebt * $.borrowIndex) / RAY, $.totalDebt);
            l.normDebt = 0;
            l.normPrincipal = 0;
        }
        debtAfter = (l.normDebt * $.borrowIndex) / RAY;
        emit Repaid(loanId, msg.sender, amount, debtAfter);
    }

    function unpledge(uint256 loanId) external nonReentrant {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        if (!l.active) revert UnknownLoan(loanId);
        if (msg.sender != l.owner) revert NotLoanOwner(loanId);
        _accrue();
        uint256 debt = (l.normDebt * $.borrowIndex) / RAY;
        if (debt > 0) revert DebtOutstanding(debt);
        uint256 tokenId = l.positionTokenId;
        delete $.loanByToken[tokenId];
        l.active = false;
        $.positions.safeTransferFrom(address(this), l.owner, tokenId);
        emit Unpledged(loanId, tokenId, l.owner);
    }

    /// @notice Liquidate an underwater loan: repay the outstanding debt, seize the NFT.
    function liquidate(uint256 loanId) external nonReentrant {
        CMStorage storage $ = _s();
        Loan storage l = $.loans[loanId];
        if (!l.active) revert UnknownLoan(loanId);
        _accrue();
        uint256 debt = (l.normDebt * $.borrowIndex) / RAY;
        uint256 thresholdValue = (valuation(l.positionTokenId) * $.liquidationThresholdBps) / 10_000;
        if (debt <= thresholdValue) revert LoanHealthy(debt, thresholdValue);

        IERC20 asset = IERC20($.vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), debt);
        asset.forceApprove(address($.vault), debt);
        $.vault.repayFrom(debt);
        $.totalDebt -= Math.min(debt, $.totalDebt);
        uint256 tokenId = l.positionTokenId;
        delete $.loanByToken[tokenId];
        l.active = false;
        $.positions.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Liquidated(loanId, tokenId, msg.sender, debt);
    }

    // ---------- internals ----------

    function _accruedIndex() internal view returns (uint256 idx, uint24 apr) {
        CMStorage storage $ = _s();
        apr = borrowAprBps();
        uint256 dt = block.timestamp - $.lastAccrual;
        idx = $.borrowIndex + (($.borrowIndex * apr * dt) / (10_000 * YEAR));
    }

    function _projectedDebt() internal view returns (uint256) {
        CMStorage storage $ = _s();
        (uint256 idx,) = _accruedIndex();
        return ($.totalDebt * idx) / $.borrowIndex;
    }

    function _accrue() internal {
        CMStorage storage $ = _s();
        (uint256 idx,) = _accruedIndex();
        if (idx != $.borrowIndex) {
            $.totalDebt = ($.totalDebt * idx) / $.borrowIndex;
            $.borrowIndex = idx;
        }
        $.lastAccrual = uint64(block.timestamp);
    }

    function _usdValue(address token, uint256 amount) internal view returns (uint256) {
        CMStorage storage $ = _s();
        IHub.AssetInfo memory info = $.hub.assetInfo(token);
        if (info.oracle == address(0)) revert NoOracle(token);
        (uint256 p, uint64 updatedAt) = IOracle(info.oracle).getTokenPrice(token);
        if (p == 0) revert NoOracle(token);
        if (block.timestamp - updatedAt > $.staleness) revert OracleStale();
        return (amount * p) / 1e18;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
