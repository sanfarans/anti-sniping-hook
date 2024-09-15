// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    AntiSnipingHook hook;
    uint24 fee = 3000;

    address alice = address(0x1); // good liquidity provider
    address bob = address(0x2); // wanna-be sniper

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            )
        );

        deployCodeTo("AntiSnipingHook", abi.encode(manager), hookAddress);
        hook = AntiSnipingHook(hookAddress);

        (key,) = initPool(currency0, currency1, hook, fee, SQRT_PRICE_1_1, ZERO_BYTES);

        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.mint(alice, 10000 ether);
        token1.mint(alice, 10000 ether);
        token0.mint(bob, 10000 ether);
        token1.mint(bob, 10000 ether);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        vm.startPrank(alice);
        for (uint256 i = 0; i < toApprove.length; i++) {
            token0.approve(toApprove[i], type(uint256).max);
            token1.approve(toApprove[i], type(uint256).max);
        }
        vm.startPrank(bob);
        for (uint256 i = 0; i < toApprove.length; i++) {
            token0.approve(toApprove[i], type(uint256).max);
            token1.approve(toApprove[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    function test_firstBlockFeesRedistributed() public {
        uint256 aliceToken0BalanceBefore = currency0.balanceOf(address(alice));
        uint256 aliceToken1BalanceBefore = currency1.balanceOf(address(alice));
        uint256 bobToken0BalanceBefore = currency0.balanceOf(address(bob));
        uint256 bobToken1BalanceBefore = currency1.balanceOf(address(bob));
        // LP position created by Alice
        vm.prank(alice);
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
        vm.roll(2);
        // Bob sees a juicy swap in the mempool and decides to snipe it - Bob deposit his liquidity right before the swap happens
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10000 ether,
                salt: bytes32("0xbob") // ensure different salt is set for Bob
            }),
            ZERO_BYTES
        );
        // swap
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
        uint256 token0ExpectedFees = 1e12 * uint256(fee); // 1e18 * 0.03% = 3e15 - estimated total fees paid by swapper

        // another swap transaction occurs next block
        vm.roll(3);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 token1ExpectedFees = 1e12 * uint256(fee); // 1e18 * 0.03% = 3e15

        PoolId poolId = key.toId();
        bytes32 alicePositionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));
        bytes32 bobPositionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32("0xbob"));

        // Alice didn't accrue any fees in the block of creating her position
        assertEq(hook.feesAccruedInFirstBlock0(poolId, alicePositionKey), 0);
        assertEq(hook.feesAccruedInFirstBlock1(poolId, alicePositionKey), 0);

        // Bob accrued half of the fees generated by first swap in the block of creating his position
        assertApproxEqAbsDecimal(
            hook.feesAccruedInFirstBlock0(poolId, bobPositionKey), token0ExpectedFees / 2, 1e15, 18
        );
        // Bob's token1 accrued fees should be 0 because oneForZero swap happened in the next block
        assertEq(hook.feesAccruedInFirstBlock1(poolId, bobPositionKey), 0);

        vm.roll(1002);

        // Bob takes his liquidity out first
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10000 ether,
                salt: bytes32("0xbob")
            }),
            ZERO_BYTES
        );
        uint256 bobToken0BalanceAfter = currency0.balanceOf(address(bob));
        uint256 bobToken1BalanceAfter = currency1.balanceOf(address(bob));
        // Bob should have received only fees for the second swap (half of them)
        assertApproxEqAbsDecimal(bobToken0BalanceAfter, bobToken0BalanceBefore, 1e15, 18);
        assertApproxEqAbsDecimal(bobToken1BalanceAfter, bobToken1BalanceBefore + token1ExpectedFees / 2, 1e15, 18);

        // then Alice closes her position
        vm.prank(alice);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 aliceToken0BalanceAfter = currency0.balanceOf(address(alice));
        uint256 aliceToken1BalanceAfter = currency1.balanceOf(address(alice));
        // Alice should have received full fees for first swap and half for the second swap
        assertApproxEqAbsDecimal(aliceToken0BalanceAfter, aliceToken0BalanceBefore + token0ExpectedFees, 1e15, 18);
        assertApproxEqAbsDecimal(aliceToken1BalanceAfter, aliceToken1BalanceBefore + token1ExpectedFees / 2, 1e15, 18);
    }

    function test_firstBlockFeesNotRedistributed() public {
        uint256 token0BalanceBefore = currency0.balanceOf(address(alice));
        uint256 token1BalanceBefore = currency1.balanceOf(address(alice));
        // LP position created by Alice
        vm.prank(alice);
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
        // someone swaps in the same block
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
        uint256 token0ExpectedFees = 1e12 * uint256(fee); // 1e18 * 0.03% = 3e15

        // another swap transaction occurs next block
        vm.roll(2);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 token1ExpectedFees = 1e12 * uint256(fee); // 1e18 * 0.03% = 3e15

        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));

        // Alice accrued token0 fees right after her position was created - it should be recorded in the contract
        assertApproxEqAbsDecimal(hook.feesAccruedInFirstBlock0(poolId, positionKey), token0ExpectedFees, 1e15, 18);
        // token1 accrued fees should be 0 because oneForZero swap happened in the next block
        assertEq(hook.feesAccruedInFirstBlock1(poolId, positionKey), 0);

        vm.roll(1001);

        // Alice removes liquidity
        vm.prank(alice);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 token0BalanceAfter = currency0.balanceOf(address(alice));
        uint256 token1BalanceAfter = currency1.balanceOf(address(alice));

        // there's no other liquidity left in the pool so the fees are not donated and are returned to the sender
        assertApproxEqAbsDecimal(token0BalanceAfter, token0BalanceBefore + token0ExpectedFees, 1e15, 18);
        assertApproxEqAbsDecimal(token1BalanceAfter, token1BalanceBefore + token1ExpectedFees, 1e15, 18);
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
}
