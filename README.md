# Polyneum (POLYNEUM)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Property        | Value                                              |
| --------------- | -------------------------------------------------- |
| Name            | `Polyneum`                                         |
| Symbol          | `POLYNEUM`                                         |
| Decimals        | 18                                                 |
| Total supply    | 1,000,000,000 POLYNEUM = `1000000000000000000000000000` minor units |
| Solidity name   | `Polyneum` (`src/Polyneum.sol`)                    |
| Constructor     | no arguments                                       |
| Minted to       | `msg.sender` of the creation transaction, once     |
| Compiler        | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Behaviour

- The constructor mints the entire supply to the deployer and emits `Transfer(0x0, deployer, supply)`.
  `totalSupply` is an immutable and can never change afterwards.
- Standard EIP-20 surface only: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`,
  `transfer`, `approve`, `transferFrom`, `Transfer`, `Approval`.
- No owner, no minter, no pause, no blocklist, no freeze, no burn, no fee on transfer, no upgrade path.
  There is no privileged function, so there is nothing an operator can do to a holder's balance.
- Transfers move exactly the stated amount. Every launch flow (factory to distributor, distributor to
  claimant, seeding the Uniswap v4 pool, trades through the PoolManager) therefore arrives whole without
  any exemption list.
- An allowance of `type(uint256).max` is treated as unlimited and is not decreased on `transferFrom`.
- Transfers and approvals to the zero address revert. Sending ether to the contract reverts.
- Failures use custom errors: `InsufficientBalance`, `InsufficientAllowance`, `InvalidReceiver`,
  `InvalidSpender`.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and depends on no external
  library, so there are no link placeholders in the bytecode.

## Deployment parameters

The token has no constructor arguments and no configuration. The only deployment-time input is the
sender of the creation transaction, who receives the whole supply.

On the IdentityMD launch, `ProjectFactory.launchCustom` deploys the token from its built bytecode, so
the factory is `msg.sender` and receives the supply. The factory then pays it out according to the
launch policy and the requester's economics:

| Share | Destination                                                                  |
| ----- | ---------------------------------------------------------------------------- |
| 10%   | the launch's MerkleDistributor (swarm share, forwarded by the factory)        |
| 88%   | single-sided liquidity in the Uniswap v4 POLYNEUM/IMD pool (`poolBps` 8800)   |
| 2%    | `economics.remainderTo` = `0x49c95a6ee32e9c0dc7a353c078e6158304bbce9f`       |

Launch constants, decided by the launch and not configurable in this repository: chain id 1; paired
currency IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`; pool fee 12500 (1.25%); tick spacing 60;
opening market cap 2,500 IMD for the whole supply. The manifest (`launch.json`) is written by the
manifest step after this work is accepted and is deliberately not included here.

For a manual deployment outside the launch, `script/DeployPolyneum.s.sol` wraps `new Polyneum()` in a
broadcast. It reads nothing from the environment; the broadcast sender is whichever key `forge script`
is given, and that address receives the supply. This repository does not authorize any transaction and
holds no keys.

## Assumptions

- The requester wants a plain, immutable token: the brief asks for name, symbol and a one-time mint to
  the deployer and nothing else, so no transfer rules, taxes, burns or governance were added.
- Minting to `msg.sender` is the required behaviour for the launch (the factory must hold the whole
  supply). A deployer who sends the creation transaction themselves holds the supply instead.
- Burning is intentionally unsupported in the contract. A holder who wants to burn can transfer to a
  dead address; `totalSupply` would not decrease.
- `decimals` is a constant 18, matching the manifest.

## Operational responsibilities

- **Before launch**: the IdentityMD verifier attests the source, and IdentityMD's deployer launches it
  through the factory. Nobody else needs to call anything. There is no "after launch" configuration:
  the token has no owner-settable values.
- **After launch**: there are no administrative powers to hold, rotate or renounce. Nobody can mint,
  pause, freeze or seize. Holders are responsible for their own keys and approvals; a compromised
  key can only move that key's own balance and allowances.
- **Explorer verification** of the deployed bytecode (for example `forge verify-contract` with the
  pinned compiler settings) is an open item for whoever deploys; it needs a deployed address.
- Tests passing are not a security audit. The contract is small and standard, but an independent
  adversarial review before release remains the policy for anything that holds other people's value.

## Project layout

```
foundry.toml                   compiler pins and build settings (solc 0.8.26, bytecode_hash none)
remappings.txt                 forge-std/ => lib/forge-std/src/
src/Polyneum.sol               the token
script/DeployPolyneum.s.sol    reviewable deployment logic (deploy() is tested directly)
test/Polyneum.t.sol            unit, failure and fuzz tests
test/Polyneum.invariant.t.sol  stateful invariant tests (supply conservation)
lib/forge-std/                 forge-std v1.9.6, vendored as ordinary files (MIT/Apache-2.0)
```

## Building and testing

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order, in parallel and with an empty environment. The invariant suite runs 256 sequences of 500
calls each and takes about 30 seconds.

## Security checklist

Reviewed against the eth-security reference supplied with the task:

- Reentrancy: no external calls are made by the token.
- Access control: no privileged functions exist.
- Arithmetic: Solidity 0.8 checked math; the two `unchecked` blocks are guarded by explicit checks and
  bounded by the fixed supply.
- Delegatecall / selfdestruct / upgradeability: none (asserted by a test that scans the runtime).
- Fee-on-transfer / rebasing: none; balances move exactly.
- Tooling: `forge build`, `forge test` (unit, fuzz, invariant) and `forge fmt --check` ran. Slither
  and Mythril are not provided on this machine and did not run.
