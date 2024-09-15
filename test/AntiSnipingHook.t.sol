// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {AntiSnipingHook} from "../src/AntiSnipingHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Position} from "v4-core/libraries/Position.sol";

contract AntiSnipingHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    AntiSnipingHook hook;
    uint24 constant FEE = 3000;
    uint128 constant POSITION_LOCK_DURATION = 1000;
    uint128 constant SAME_BLOCK_POSITIONS_LIMIT = 5;

    address constant ALICE = address(0x1); // Alice is an honest liquidity provider
    address constant BOB = address(0x2); // Bob is wanna-be sniper

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
        deployCodeTo(
            "AntiSnipingHook", abi.encode(manager, POSITION_LOCK_DURATION, SAME_BLOCK_POSITIONS_LIMIT), hookAddress
        );
        hook = AntiSnipingHook(hookAddress);

        (key,) = initPool(currency0, currency1, hook, FEE, SQRT_PRICE_1_1, ZERO_BYTES);

        // Mint tokens to Alice and Bob
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.mint(ALICE, 10000 ether);
        token1.mint(ALICE, 10000 ether);
        token0.mint(BOB, 10000 ether);
        token1.mint(BOB, 10000 ether);

        // Approve tokens for all routers
        address[9] memory routers = [
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

        vm.startPrank(ALICE);
        for (uint256 i = 0; i < routers.length; i++) {
            token0.approve(routers[i], type(uint256).max);
            token1.approve(routers[i], type(uint256).max);
        }
        vm.stopPrank();

        vm.startPrank(BOB);
        for (uint256 i = 0; i < routers.length; i++) {
            token0.approve(routers[i], type(uint256).max);
            token1.approve(routers[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    // Helper function to modify liquidity positions (add or remove)
    function _modifyLiquidityPosition(
        address user,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        bytes32 salt
    ) internal {
        vm.prank(user);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: salt
            }),
            ZERO_BYTES
        );
    }

    // Helper function to perform a swap
    function _performSwap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // --- Test Scenarios ---

    /// @notice Test that swap fee sniping is prevented
    function testSwapFeeSnipingPrevention() public {
        // Record initial balances
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);
        uint256 aliceToken1Before = currency1.balanceOf(ALICE);
        uint256 bobToken0Before = currency0.balanceOf(BOB);
        uint256 bobToken1Before = currency1.balanceOf(BOB);

        // Alice adds liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10000 ether), bytes32(0));

        // Advance to next block
        vm.roll(2);

        // Bob attempts to snipe by adding liquidity just before a swap
        _modifyLiquidityPosition(BOB, -60, 60, int128(10000 ether), bytes32("0xBOB"));

        // Swap occurs in the same block
        int256 swapAmount = int256(1 ether);
        _performSwap(true, swapAmount, TickMath.MIN_SQRT_PRICE + 1);

        // Expected fees from swap
        uint256 token0ExpectedFees = (uint256(swapAmount) * FEE) / 1e6; // Swap amount * fee percentage

        // Advance to next block and perform another swap
        vm.roll(3);
        _performSwap(false, swapAmount, TickMath.MAX_SQRT_PRICE - 1);
        uint256 token1ExpectedFees = (uint256(swapAmount) * FEE) / 1e6;

        // Collect fee info
        PoolId poolId = key.toId();
        hook.collectLastBlockInfo(poolId);

        // Calculate position keys
        bytes32 alicePositionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));
        bytes32 bobPositionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32("0xBOB"));

        // Verify that Alice did not accrue fees in the creation block
        assertEq(hook.firstBlockFeesToken0(poolId, alicePositionKey), 0);
        assertEq(hook.firstBlockFeesToken1(poolId, alicePositionKey), 0);

        // Verify that Bob accrued fees from the first swap
        assertApproxEqAbsDecimal(hook.firstBlockFeesToken0(poolId, bobPositionKey), token0ExpectedFees / 2, 1e15, 18);
        assertEq(hook.firstBlockFeesToken1(poolId, bobPositionKey), 0);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 2);

        // Bob removes liquidity
        _modifyLiquidityPosition(BOB, -60, 60, -int128(10000 ether), bytes32("0xBOB"));

        // Verify that Bob received fees from the second swap only
        uint256 bobToken0After = currency0.balanceOf(BOB);
        uint256 bobToken1After = currency1.balanceOf(BOB);
        assertApproxEqAbsDecimal(bobToken0After, bobToken0Before, 1e15, 18);
        assertApproxEqAbsDecimal(bobToken1After, bobToken1Before + token1ExpectedFees / 2, 1e15, 18);

        // Alice removes liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, -int128(10000 ether), bytes32(0));

        // Verify that Alice received full fees from the first swap and half from the second
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        uint256 aliceToken1After = currency1.balanceOf(ALICE);
        assertApproxEqAbsDecimal(aliceToken0After, aliceToken0Before + token0ExpectedFees, 1e15, 18);
        assertApproxEqAbsDecimal(aliceToken1After, aliceToken1Before + token1ExpectedFees / 2, 1e15, 18);
    }

    /// @notice Test that donation sniping is prevented
    function testDonationSnipingPrevention() public {
        // Record initial balances
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);
        uint256 aliceToken1Before = currency1.balanceOf(ALICE);
        uint256 bobToken0Before = currency0.balanceOf(BOB);
        uint256 bobToken1Before = currency1.balanceOf(BOB);

        // Alice adds liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10000 ether), bytes32(0));

        // Advance to next block
        vm.roll(2);

        // Bob attempts to snipe by adding liquidity just before a donation
        _modifyLiquidityPosition(BOB, -60, 60, int128(10000 ether), bytes32("0xBOB"));

        // Donation occurs
        uint256 token0Donation = 1 ether;
        uint256 token1Donation = 2 ether;
        donateRouter.donate(key, token0Donation, token1Donation, ZERO_BYTES);

        // Advance to next block and collect fee info
        vm.roll(3);
        PoolId poolId = key.toId();
        hook.collectLastBlockInfo(poolId);

        // Calculate position keys
        bytes32 alicePositionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));
        bytes32 bobPositionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32("0xBOB"));

        // Verify that Alice did not accrue fees in the creation block
        assertEq(hook.firstBlockFeesToken0(poolId, alicePositionKey), 0);
        assertEq(hook.firstBlockFeesToken1(poolId, alicePositionKey), 0);

        // Verify that Bob accrued fees in the creation block
        uint256 allowedError = 0.00001e18; // 0.001%
        assertApproxEqRel(hook.firstBlockFeesToken0(poolId, bobPositionKey), token0Donation / 2, allowedError);
        assertApproxEqRel(hook.firstBlockFeesToken1(poolId, bobPositionKey), token1Donation / 2, allowedError);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 2);

        // Bob removes liquidity
        _modifyLiquidityPosition(BOB, -60, 60, -int128(10000 ether), bytes32("0xBOB"));

        // Verify that Bob did not receive any fees
        uint256 bobToken0After = currency0.balanceOf(BOB);
        uint256 bobToken1After = currency1.balanceOf(BOB);
        assertApproxEqRel(bobToken0After, bobToken0Before, allowedError);
        assertApproxEqRel(bobToken1After, bobToken1Before, allowedError);

        // Alice removes liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, -int128(10000 ether), bytes32(0));

        // Verify that Alice received all the donation fees
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        uint256 aliceToken1After = currency1.balanceOf(ALICE);
        assertApproxEqRel(aliceToken0After, aliceToken0Before + token0Donation, allowedError);
        assertApproxEqRel(aliceToken1After, aliceToken1Before + token1Donation, allowedError);
    }

    /// @notice Test that fees are returned to the sender when no liquidity is left to donate to
    function testFeeRedistributionWhenNoLiquidity() public {
        // Record initial balance
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);

        // Alice adds liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10000 ether), bytes32(0));

        // Swap occurs in the same block
        int256 swapAmount = int256(1 ether);
        _performSwap(true, swapAmount, TickMath.MIN_SQRT_PRICE + 1);
        uint256 token0ExpectedFees = (uint256(swapAmount) * FEE) / 1e6;

        // Advance to next block and collect fee info
        vm.roll(2);
        PoolId poolId = key.toId();
        hook.collectLastBlockInfo(poolId);

        // Calculate position key
        bytes32 positionKey = Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));

        // Verify that Alice accrued fees in the creation block
        assertApproxEqAbsDecimal(hook.firstBlockFeesToken0(poolId, positionKey), token0ExpectedFees, 1e15, 18);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 1);

        // Alice removes liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, -int128(10000 ether), bytes32(0));

        // Verify that fees are returned to Alice since there's no liquidity left to donate to
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        assertApproxEqAbsDecimal(
            aliceToken0After, aliceToken0Before + uint256(swapAmount) + token0ExpectedFees, 1e15, 18
        );
    }

    // --- Safeguard Tests ---

    /// @notice Test that attempting to remove liquidity before lock duration reverts
    function testEarlyLiquidityRemovalReverts() public {
        // Alice adds liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10 ether), bytes32(0));

        // Advance a few blocks but less than lock duration
        vm.roll(vm.getBlockNumber() + 5);
        assertLt(5, hook.positionLockDuration());

        // Attempt to remove liquidity and expect revert
        vm.expectRevert();
        _modifyLiquidityPosition(ALICE, -60, 60, -int128(10 ether), bytes32(0));
    }

    /// @notice Test that partial liquidity removal reverts
    function testPartialLiquidityRemovalReverts() public {
        // Alice adds liquidity
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10 ether), bytes32(0));

        // Advance past lock duration
        vm.roll(POSITION_LOCK_DURATION);

        // Attempt to partially remove liquidity and expect revert
        vm.expectRevert();
        _modifyLiquidityPosition(ALICE, -60, 60, -int128(5 ether), bytes32(0));
    }

    /// @notice Test that exceeding same block position limit reverts
    function testExceedingSameBlockPositionsLimitReverts() public {
        // Add positions up to the limit
        for (uint256 i = 0; i < SAME_BLOCK_POSITIONS_LIMIT; ++i) {
            _modifyLiquidityPosition(ALICE, -60, 60, int128(10 ether), bytes32(i));
        }

        // Attempt to add one more position and expect revert
        vm.expectRevert();
        _modifyLiquidityPosition(ALICE, -60, 60, int128(10 ether), bytes32(0));
    }
}
