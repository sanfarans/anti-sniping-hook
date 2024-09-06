// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {AntiSnipingHook} from "../src/AntiSnipingHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {Position} from "v4-core/libraries/Position.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    AntiSnipingHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );

        deployCodeTo("AntiSnipingHook", abi.encode(manager), hookAddress);
        hook = AntiSnipingHook(hookAddress);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function test_savesPositionCreationBlockNumber() public {
        uint256 blockNumber = 42;
        vm.roll(blockNumber);

        address lpAddress = address(modifyLiquidityRouter);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(lpAddress, -60, 60, bytes32(0));
        assertEq(hook.positionCreationBlockNumber(poolId, positionKey), blockNumber);
    }

    function test_timeLockRevertsLiquidityRemoval() public {
        // adds liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // waits couple blocks < positionLockDuration
        assertLt(5, hook.positionLockDuration());
        vm.roll(vm.getBlockNumber() + 5);
        // tries to remove liquidity
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_timeLockExpiresEnablesLiquidityRemoval() public {
        // adds liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // waits enough blocks
        uint256 lockDuration = hook.positionLockDuration();
        vm.roll(block.number + lockDuration);
        // successfully removes liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_partialWithdrawalRevertsLiquidityRemoval() public {
        // adds liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // waits enough blocks
        uint256 lockDuration = hook.positionLockDuration();
        vm.roll(block.number + lockDuration);
        // tries to remove liquidity
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -5 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_infoCollectedAfterSwap() public {
        // lp position
        assertEq(block.number, 1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        assertEq(block.number, 1);
        // swap in the same block
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        // some transaction happens next block and triggers info collection
        vm.roll(block.number + 1);
        assertEq(block.number, 2);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));

        assertGt(hook.subtractFeeGrowthInside0LastX128(poolId, positionKey), 0);
        assertGt(hook.subtractFeeGrowthInside1LastX128(poolId, positionKey), 0);
    }
}
