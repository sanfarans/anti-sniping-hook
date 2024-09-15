// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

/// @title AntiSnipingHook
/// @notice A Uniswap V4 hook that prevents MEV sniping attacks by enforcing time locks on positions and redistributing fees accrued in the initial block to legitimate liquidity providers.
/// @dev Positions are time-locked, and fees accrued in the first block after position creation are redistributed.
contract AntiSnipingHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;

    /// @notice Maps a pool ID and position key to the block number when the position was created.
    mapping(PoolId => mapping(bytes32 => uint256)) public positionCreationBlock;

    /// @notice The duration (in blocks) for which a position must remain locked before it can be removed.
    uint128 public positionLockDuration;

    /// @notice The maximum number of positions that can be created in the same block per pool to prevent excessive gas usage.
    uint128 public sameBlockPositionsLimit;

    mapping(PoolId => uint256) lastProcessedBlockNumber;

    mapping(PoolId => bytes32[]) positionsCreatedInLastBlock;

    /// @notice Maps a pool ID and position key to the fees accrued in the first block.
    mapping(PoolId => mapping(bytes32 => uint256)) public firstBlockFeesToken0;
    mapping(PoolId => mapping(bytes32 => uint256)) public firstBlockFeesToken1;

    mapping(PoolId => mapping(bytes32 => int24)) public positionTickLower;
    mapping(PoolId => mapping(bytes32 => int24)) public positionTickUpper;

    /// @notice Error thrown when a position is still locked and cannot be removed.
    error PositionLocked();

    /// @notice Error thrown when attempting to modify an existing position.
    /// @dev Positions cannot be modified after creation to prevent edge cases.
    error PositionAlreadyExists();

    /// @notice Error thrown when attempting to partially withdraw from a position.
    error PositionPartiallyWithdrawn();

    /// @notice Error thrown when too many positions are opened in the same block.
    /// @dev Limits the number of positions per block to prevent excessive gas consumption.
    error TooManyPositionsInSameBlock();

    constructor(IPoolManager _poolManager, uint128 _positionLockDuration, uint128 _sameBlockPositionsLimit)
        BaseHook(_poolManager)
    {
        positionLockDuration = _positionLockDuration;
        sameBlockPositionsLimit = _sameBlockPositionsLimit;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @notice Collects fee information for positions created in the last processed block.
    /// @dev This is called in all of the before hooks (except init) and can also be called manually.
    /// @param poolId The identifier of the pool.
    function collectLastBlockInfo(PoolId poolId) public {
        if (block.number <= lastProcessedBlockNumber[poolId]) {
            return;
        }
        lastProcessedBlockNumber[poolId] = block.number;
        for (uint256 i = 0; i < positionsCreatedInLastBlock[poolId].length; i++) {
            bytes32 positionKey = positionsCreatedInLastBlock[poolId][i];
            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
                poolManager.getPositionInfo(poolId, positionKey);
            int24 tickLower = positionTickLower[poolId][positionKey];
            int24 tickUpper = positionTickUpper[poolId][positionKey];
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
            uint256 feeGrowthDelta0X128 = feeGrowthInside0X128 - feeGrowthInside0LastX128;
            uint256 feeGrowthDelta1X128 = feeGrowthInside1X128 - feeGrowthInside1LastX128;
            firstBlockFeesToken0[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDelta0X128, liquidity, FixedPoint128.Q128);
            firstBlockFeesToken1[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDelta1X128, liquidity, FixedPoint128.Q128);
        }
        delete positionsCreatedInLastBlock[poolId];
    }

    /// @notice Handles logic after removing liquidity, redistributing first-block fees if applicable.
    /// @dev Donates first-block accrued fees to the pool if liquidity remains; otherwise, returns them to the sender.
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        BalanceDelta hookDelta;
        if (poolManager.getLiquidity(poolId) != 0) {
            hookDelta = toBalanceDelta(
                firstBlockFeesToken0[poolId][positionKey].toInt128(),
                firstBlockFeesToken1[poolId][positionKey].toInt128()
            );
            poolManager.donate(
                key, firstBlockFeesToken0[poolId][positionKey], firstBlockFeesToken1[poolId][positionKey], new bytes(0)
            );
        } else {
            // If the pool is empty, the fees are not donated and are returned to the sender
            hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        }

        // Cleanup stored data for the position
        delete positionCreationBlock[poolId][positionKey];
        delete firstBlockFeesToken0[poolId][positionKey];
        delete firstBlockFeesToken1[poolId][positionKey];
        delete positionTickLower[poolId][positionKey];
        delete positionTickUpper[poolId][positionKey];

        return (this.afterRemoveLiquidity.selector, hookDelta);
    }

    /// @notice Handles logic before adding liquidity, enforcing position creation constraints.
    /// @dev Records position creation block and ensures the position doesn't already exist or exceed the same block limit.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        if (positionCreationBlock[poolId][positionKey] != 0) revert PositionAlreadyExists();
        if (positionsCreatedInLastBlock[poolId].length >= sameBlockPositionsLimit) revert TooManyPositionsInSameBlock();
        positionCreationBlock[poolId][positionKey] = block.number;
        positionsCreatedInLastBlock[poolId].push(positionKey);
        positionTickLower[poolId][positionKey] = params.tickLower;
        positionTickUpper[poolId][positionKey] = params.tickUpper;
        return (this.beforeAddLiquidity.selector);
    }

    /// @notice Handles logic before removing liquidity, enforcing position lock duration and full withdrawal.
    /// @dev Checks that the position lock duration has passed and disallows partial withdrawals.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        if (block.number - positionCreationBlock[poolId][positionKey] < positionLockDuration) revert PositionLocked();
        (uint128 liquidity,,) = poolManager.getPositionInfo(poolId, positionKey);
        if (int128(liquidity) + params.liquidityDelta != 0) revert PositionPartiallyWithdrawn();
        return (this.beforeRemoveLiquidity.selector);
    }

    /// @notice Handles logic before a swap occurs.
    /// @dev Collects fee information for positions created in the last processed block.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Handles logic before a donation occurs.
    /// @dev Collects fee information for positions created in the last processed block.
    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeDonate.selector);
    }
}
