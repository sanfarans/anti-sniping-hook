# AntiSnipingHook: Secure Liquidity Provision in Uniswap V4

## Introduction

The **AntiSnipingHook** is a Uniswap V4 hook designed to enhance the security and fairness of liquidity provision. It prevents MEV (Miner Extractable Value) sniping attacks by preventing **swap fee sniping** and **donation sniping**, which is a novel way of exploiting LPs unique to Uniswap V4 where the `donate` function was introduced. The hook enforces time locks on positions and redistributes fees accrued in the initial block to genuine liquidity providers.

## Problem Statement

In decentralized exchanges like Uniswap, opportunistic actors can exploit large swaps or donations by rapidly adding liquidity to a pool just before a significant transaction occurs. This allows them to capture a disproportionate share of the fees without bearing the typical risks associated with liquidity provision. Such practices undermine the incentives for honest LPs and can destabilize the ecosystem.

## Solution Overview

The AntiSnipingHook mitigates these risks by:

- **Time-Locking Positions:** Positions are locked for a specified number of blocks (`positionLockDuration`), preventing immediate withdrawal and forcing LPs to maintain their position over time.
- **Redistributing Initial Fees:** Fees accrued in the first block after position creation are redistributed to existing LPs or, if no liquidity remains, returned to the sender.

## Key Features

- **Prevents MEV Sniping:** By enforcing time locks and redistributing early fees, the hook deters attackers from sniping fees through quick position adjustments.
- **Prevents Swap Fee and Donation Sniping:** Addresses both swap fee sniping and the novel donation sniping unique to Uniswap V4.
- **Enhances Fairness:** Ensures that fees are earned by LPs who contribute to the pool over time, not by those who attempt to game the system.
- **Edge Case Handling:** If no liquidity remains in the pool, fees accrued in the first block are returned to the sender, ensuring no funds are lost.
- **Safeguards:** Enforces full withdrawal only after the lock duration and disallows partial withdrawals to prevent exploitation.

## Scenarios

### Swap Fee Sniping Prevention

An attacker might try to snipe swap fees by adding liquidity just before a large swap:

- **Without AntiSnipingHook:** The attacker adds liquidity, captures a significant portion of the fees from the swap, and removes liquidity immediately.
- **With AntiSnipingHook:** The attacker is forced to lock their position for the specified duration. Fees accrued in the first block are redistributed to existing LPs, removing the financial incentive for the attack.

### Donation Sniping Prevention

An attacker may attempt to capture fees from a large donation by quickly adding liquidity. This is a novel exploit unique to Uniswap V4 due to the introduction of the `donate` function:

- **Without AntiSnipingHook:** The attacker adds liquidity just before the donation and claims a large share of the fees.
- **With AntiSnipingHook:** The time lock and fee redistribution mechanisms prevent the attacker from profiting, as early fees are redistributed, and they cannot withdraw immediately.

### Edge Case: No Liquidity Left

When there is no liquidity left in the pool to redistribute fees:

- **Behavior:** The fees accrued in the first block are returned to the sender when they remove liquidity.
- **Benefit:** Ensures that funds are not locked or lost, maintaining user trust and contract reliability.

## Safeguards and Their Benefits

- **Position Lock Duration (`positionLockDuration`):** Prevents immediate withdrawal of liquidity, reducing the incentive for short-term sniping and exposing LPs to market risk.
- **Same Block Positions Limit (`sameBlockPositionsLimit`):** Caps the gas consumption of the fee collection function, ensuring efficient operation even under high activity.
- **No Partial Withdrawals:** Enforces full withdrawal only, ensuring that LPs cannot game the system by partially withdrawing to bypass the lock.

## Preventing LP Sniping (JIT Rebalancing Attacks)

LP sniping or Just-In-Time (JIT) rebalancing attacks involve adding liquidity just before a significant trade and removing it immediately after to capture fees without exposure to price risk.

**How AntiSnipingHook Prevents This:**

1. **Fee Redistribution:** Fees accrued in the first block after adding liquidity are not granted to the new LP but redistributed to existing LPs, removing the financial incentive for sniping.
2. **Time Lock Enforcement:** Positions must remain locked for a set duration, forcing potential attackers to maintain exposure to market volatility, which increases their risk.
3. **Risk of Asset Volatility:** By requiring LPs to lock up their positions, attackers are exposed to the risk of asset price changes, making sniping unprofitable over time.

By combining these mechanisms, the AntiSnipingHook effectively prevents LP sniping and JIT rebalancing attacks indefinitely, ensuring that only LPs who are committed to providing liquidity over time are rewarded.

## Conclusion

The AntiSnipingHook provides a robust solution to prevent fee sniping attacks in Uniswap V4, particularly addressing the novel donation sniping exploit. By enforcing time locks, redistributing early fees, and implementing strategic safeguards, it ensures that liquidity provision remains fair and secure for all participants.

## Usage Instructions

1. **Deployment:**

   Deploy the AntiSnipingHook contract with the desired `positionLockDuration` and `sameBlockPositionsLimit` parameters:

   ```solidity
   AntiSnipingHook hook = new AntiSnipingHook(
       poolManagerAddress,
       positionLockDurationInBlocks,
       sameBlockPositionsLimitPerPool
   );
   ```

2. **Integration:**

Integrate the hook with your Uniswap V4 pool by specifying it in the pool's hook configuration.

3. **Liquidity Provision:**

LPs can add liquidity as usual but should be aware of the time lock and withdrawal restrictions enforced by the hook.

## License

This project is licensed under the MIT License.
