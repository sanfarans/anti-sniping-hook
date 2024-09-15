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
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

contract AntiSnipingHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;

    // used for time-locking positions
    mapping(PoolId => mapping(bytes32 => uint256)) public positionCreationBlockNumber;
    uint128 public positionLockDuration;
    uint128 public sameBlockPositionsLimit;

    // used for tracking positions created in the last seen block - to collect the changes in fee growth
    mapping(PoolId => uint256) lastSeenBlockNumber;
    mapping(PoolId => bytes32[]) positionsCreatedInLastSeenBlock;

    mapping(PoolId => mapping(bytes32 => uint256)) public feesAccruedInFirstBlock0;
    mapping(PoolId => mapping(bytes32 => uint256)) public feesAccruedInFirstBlock1;

    mapping(PoolId => mapping(bytes32 => int24)) public positionKeyToTickLower;
    mapping(PoolId => mapping(bytes32 => int24)) public positionKeyToTickUpper;

    error PositionLocked();
    error PositionAlreadyExists(); // positions are not modifiable after creation - prevent edge cases;
    // still it is possible to create a similar position with a different salt
    error PositionPartiallyWithdrawn();
    error TooManyPositionsOpenedSameBlock(); // to prevent having to many positions to go through when collecting info (gas costly)

    constructor(IPoolManager _poolManager, uint128 _positionLockDuration, uint128 _sameBlockPoistionsLimit)
        BaseHook(_poolManager)
    {
        positionLockDuration = _positionLockDuration;
        sameBlockPositionsLimit = _sameBlockPoistionsLimit;
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

    // for positions created in the last seen block, collect how much fees they accrued
    function collectLastBlockInfo(PoolId poolId) public {
        if (block.number <= lastSeenBlockNumber[poolId]) {
            return;
        }
        lastSeenBlockNumber[poolId] = block.number;
        for (uint256 i = 0; i < positionsCreatedInLastSeenBlock[poolId].length; i++) {
            bytes32 positionKey = positionsCreatedInLastSeenBlock[poolId][i];
            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
                poolManager.getPositionInfo(poolId, positionKey);
            int24 tickLower = positionKeyToTickLower[poolId][positionKey];
            int24 tickUpper = positionKeyToTickUpper[poolId][positionKey];
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
            uint256 feeGrowthDiffSinceLastBlockInside0X128 = feeGrowthInside0X128 - feeGrowthInside0LastX128;
            uint256 feeGrowthDiffSinceLastBlockInside1X128 = feeGrowthInside1X128 - feeGrowthInside1LastX128;
            feesAccruedInFirstBlock0[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDiffSinceLastBlockInside0X128, liquidity, FixedPoint128.Q128);
            feesAccruedInFirstBlock1[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDiffSinceLastBlockInside1X128, liquidity, FixedPoint128.Q128);
        }
        delete positionsCreatedInLastSeenBlock[poolId];
    }

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
                feesAccruedInFirstBlock0[poolId][positionKey].toInt128(),
                feesAccruedInFirstBlock1[poolId][positionKey].toInt128()
            );
            poolManager.donate(
                key,
                feesAccruedInFirstBlock0[poolId][positionKey],
                feesAccruedInFirstBlock1[poolId][positionKey],
                new bytes(0)
            );
        } else {
            // if the pool is empty, the fees are not donated and are returned to the sender
            hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        }

        // cleanup
        delete positionCreationBlockNumber[poolId][positionKey];
        delete feesAccruedInFirstBlock0[poolId][positionKey];
        delete feesAccruedInFirstBlock1[poolId][positionKey];
        delete positionKeyToTickLower[poolId][positionKey];
        delete positionKeyToTickUpper[poolId][positionKey];

        return (this.afterRemoveLiquidity.selector, hookDelta);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        require(positionCreationBlockNumber[poolId][positionKey] == 0, PositionAlreadyExists());
        require(positionsCreatedInLastSeenBlock[poolId].length < sameBlockPositionsLimit);
        positionCreationBlockNumber[poolId][positionKey] = block.number;
        positionsCreatedInLastSeenBlock[poolId].push(positionKey);
        positionKeyToTickLower[poolId][positionKey] = params.tickLower;
        positionKeyToTickUpper[poolId][positionKey] = params.tickUpper;
        return (this.beforeAddLiquidity.selector);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeDonate.selector);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        require(
            block.number - positionCreationBlockNumber[poolId][positionKey] >= positionLockDuration, PositionLocked()
        );
        (uint128 liquidity,,) = poolManager.getPositionInfo(poolId, positionKey);
        require(int128(liquidity) + params.liquidityDelta == 0, PositionPartiallyWithdrawn());
        return (this.beforeRemoveLiquidity.selector);
    }
}
