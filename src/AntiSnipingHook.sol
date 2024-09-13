// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import "forge-std/console.sol";

contract AntiSnipingHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // used for time-locking positions
    mapping(PoolId => mapping(bytes32 => uint256)) public positionCreationBlockNumber;
    uint256 public positionLockDuration = 1000;

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

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // for positions created in the last seen block, collect the changes in fee growth
    function collectLastBlockInfo(PoolId poolId) internal {
        if (block.number <= lastSeenBlockNumber[poolId]) {
            return;
        }
        lastSeenBlockNumber[poolId] = block.number;
        for (uint256 i = 0; i < positionsCreatedInLastSeenBlock[poolId].length; i++) {
            bytes32 positionKey = positionsCreatedInLastSeenBlock[poolId][i];
            (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
                StateLibrary.getPositionInfo(poolManager, poolId, positionKey);
            int24 tickLower = positionKeyToTickLower[poolId][positionKey];
            int24 tickUpper = positionKeyToTickUpper[poolId][positionKey];
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                StateLibrary.getFeeGrowthInside(poolManager, poolId, tickLower, tickUpper);
            uint256 feeGrowthDiffSinceLastBlockInside0X128 = feeGrowthInside0X128 - feeGrowthInside0LastX128;
            uint256 feeGrowthDiffSinceLastBlockInside1X128 = feeGrowthInside1X128 - feeGrowthInside1LastX128;
            feesAccruedInFirstBlock0[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDiffSinceLastBlockInside0X128, uint256(liquidity), FixedPoint128.Q128);
            feesAccruedInFirstBlock1[poolId][positionKey] =
                FullMath.mulDiv(feeGrowthDiffSinceLastBlockInside1X128, uint256(liquidity), FixedPoint128.Q128);
        }
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
        positionCreationBlockNumber[poolId][positionKey] = block.number;
        positionsCreatedInLastSeenBlock[poolId].push(positionKey);
        positionKeyToTickLower[poolId][positionKey] = params.tickLower;
        positionKeyToTickUpper[poolId][positionKey] = params.tickUpper;
        return (this.beforeAddLiquidity.selector);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // cleanup
        delete positionCreationBlockNumber[poolId][positionKey];
        delete feesAccruedInFirstBlock0[poolId][positionKey];
        delete feesAccruedInFirstBlock1[poolId][positionKey];
        delete positionKeyToTickLower[poolId][positionKey];
        delete positionKeyToTickUpper[poolId][positionKey];

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
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
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionKey);
        require(int128(liquidity) + params.liquidityDelta == 0, PositionPartiallyWithdrawn());
        return (this.beforeRemoveLiquidity.selector);
    }
}
