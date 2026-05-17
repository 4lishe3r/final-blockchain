# DeFi Super-App — Blockchain Technologies 2 Capstone

> **Scenario A** — AMM + ERC-4626 Vault + DAO Governance · Deployed on Arbitrum Sepolia

---

## Table of Contents
1. [Architecture](#architecture)
2. [Contracts](#contracts)
3. [Deployed Addresses](#deployed-addresses)
4. [Setup](#setup)
5. [Testing](#testing)
6. [Deployment](#deployment)
7. [The Graph Queries](#the-graph-queries)
8. [Gas Comparison: L1 vs L2](#gas-comparison-l1-vs-l2)
9. [Design Patterns](#design-patterns)
10. [Security](#security)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Users / Frontend                         │
└────────────────────────────┬────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
   ┌──────────┐       ┌──────────┐       ┌──────────────┐
   │ AMM Pool │       │YieldVault│       │  DeFiGovern  │
   │ (x·y=k) │       │ ERC-4626 │       │  or + Timelo │
   └────┬─────┘       └────┬─────┘       └──────┬───────┘
        │                  │                    │
        ▼                  ▼                    ▼
   ┌──────────┐       ┌──────────┐       ┌──────────────┐
   │Chainlink │       │ChainlinkO│       │  Treasury    │
   │ Feed     │       │racle Adap│       │ (pull-over-  │
   └──────────┘       └──────────┘       │  push)       │
                                         └──────────────┘
        │                                       │
        └──────────── The Graph ────────────────┘
                   (subgraph indexer)
```

**Proxy layout:**
- `GovernanceToken` → ERC-1967 UUPS proxy (V1 → upgradeable to V2)
- `YieldVault`      → ERC-1967 UUPS proxy

**Access control roles:**
| Role | Holder | Can do |
|------|--------|--------|
| `DEFAULT_ADMIN_ROLE` | Timelock | Grant/revoke all roles |
| `MINTER_ROLE` | Timelock | Mint governance tokens |
| `UPGRADER_ROLE` | Timelock | Upgrade UUPS proxies |
| `PAUSER_ROLE` | Timelock | Pause AMM + Vault |
| `SPENDER_ROLE` (Treasury) | Timelock | Allocate grants |
| `POOL_CREATOR_ROLE` | Multisig | Deploy new pools |

---

## Contracts

| Contract | Description | Pattern |
|----------|-------------|---------|
| `GovernanceToken` | ERC-20 + ERC20Votes + ERC20Permit, UUPS | Proxy/UUPS |
| `GovernanceTokenV2` | V2 with transfer tax — demonstrates upgrade path | Proxy/UUPS |
| `ProtocolNFT` | ERC-721 soulbound membership badge | Access Control |
| `ConstantProductAMM` | x·y=k AMM, 0.3% fee, inline Yul sqrt | CEI + ReentrancyGuard |
| `YieldVault` | ERC-4626 tokenised vault, UUPS | Proxy/UUPS + CEI |
| `ChainlinkOracleAdapter` | Chainlink wrapper with staleness check | Oracle Adapter |
| `ProtocolFactory` | Deploys pools via CREATE and CREATE2 | Factory |
| `DeFiGovernor` | OZ Governor: 1d delay, 1w period, 4% quorum | Timelock + State Machine |
| `TimelockController` | 2-day delay, controls Treasury | Timelock |
| `Treasury` | Fee accumulation, pull-over-push payments | Pull-over-push + Access Control |

---

## Deployed Addresses

> Network: **Arbitrum Sepolia** (chain ID 421614)

| Contract | Address | Explorer |
|----------|---------|----------|
| GovernanceToken (proxy) | `0x...` | [link]() |
| ProtocolNFT | `0x...` | [link]() |
| ChainlinkOracleAdapter | `0x...` | [link]() |
| ProtocolFactory | `0x...` | [link]() |
| ConstantProductAMM | `0x...` | [link]() |
| YieldVault (proxy) | `0x...` | [link]() |
| TimelockController | `0x...` | [link]() |
| DeFiGovernor | `0x...` | [link]() |
| Treasury | `0x...` | [link]() |

> All contracts verified on [Arbitrum Sepolia Arbiscan](https://sepolia.arbiscan.io).

---

## Setup

```bash
# 1. Clone
git clone https://github.com/your-org/defi-superapp
cd defi-superapp

# 2. Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 3. Install dependencies
forge install OpenZeppelin/openzeppelin-contracts \
              OpenZeppelin/openzeppelin-contracts-upgradeable \
              smartcontractkit/chainlink \
              foundry-rs/forge-std

# 4. Copy env
cp .env.example .env
# Fill in: DEPLOYER_PRIVATE_KEY, MAINNET_RPC_URL, ARBITRUM_SEPOLIA_RPC_URL, etc.

# 5. Build
forge build
```

---

## Testing

```bash
# Run all tests
forge test -vvv

# Unit tests only
forge test --match-path "test/unit/**" -vvv

# Fuzz tests (increase runs for CI)
forge test --match-contract ".*Fuzz.*" -vvv

# Invariant tests
forge test --match-contract ".*Invariant.*" -vvv

# Fork tests (requires MAINNET_RPC_URL)
forge test --match-contract ForkTest --fork-url $MAINNET_RPC_URL -vvv

# Coverage report
forge coverage --report markdown > coverage/coverage.md
cat coverage/coverage.md

# Gas benchmark (Yul vs Solidity sqrt)
forge test --match-test test_GasBenchmark_Sqrt -vvv --gas-report
```

**Test counts:**
| Type | Count | Requirement |
|------|-------|-------------|
| Unit | 60+ | ≥50 |
| Fuzz | 12+ | ≥10 |
| Invariant | 6+ | ≥5 |
| Fork | 3 | ≥3 |
| Vulnerability case studies | 4 | 2 (reentrancy + AC) |

---

## Deployment

```bash
# Deploy to Arbitrum Sepolia
forge script script/deploy.s.sol:DeployScript \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_API_KEY \
  -vvvv

# Verify deployment (post-deploy sanity check)
forge script script/verify.s.sol:VerifyScript \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  -vvvv
```

---

## The Graph Queries

Subgraph endpoint: `https://api.thegraph.com/subgraphs/name/your-org/defi-superapp`

### Query 1 — Recent swaps on a pool
```graphql
query RecentSwaps($pool: String!, $limit: Int!) {
  swaps(
    first: $limit
    orderBy: timestamp
    orderDirection: desc
    where: { pool: $pool }
  ) {
    id
    sender
    tokenIn
    amountIn
    amountOut
    timestamp
    txHash
  }
}
```

### Query 2 — All active proposals
```graphql
query ActiveProposals {
  proposals(where: { state: "Active" }, orderBy: endBlock, orderDirection: asc) {
    id
    proposer
    description
    forVotes
    againstVotes
    abstainVotes
    endBlock
    quorumReached
  }
}
```

### Query 3 — Voting history for an address
```graphql
query VoterHistory($voter: Bytes!) {
  votes(where: { voter: $voter }, orderBy: blockNumber, orderDirection: desc) {
    proposal { id description state }
    support
    weight
    reason
    timestamp
  }
}
```

### Query 4 — Pool stats (reserves + volume)
```graphql
query PoolStats($id: ID!) {
  pool(id: $id) {
    reserve0
    reserve1
    totalSupply
    swapCount
    volumeToken0
    volumeToken1
  }
}
```

### Query 5 — Vault price-per-share over time
```graphql
query VaultHistory($vault: Bytes!, $since: BigInt!) {
  vaultSnapshots(
    where: { vault: $vault, timestamp_gt: $since }
    orderBy: timestamp
    orderDirection: asc
  ) {
    pricePerShare
    totalAssets
    totalShares
    timestamp
  }
}
```

---

## Gas Comparison: L1 vs L2

> Measured with `forge test --gas-report`. L1 gas price: 30 gwei. L2 gas price: 0.1 gwei.

| Operation | L1 Gas | L1 Cost (USD) | L2 Gas | L2 Cost (USD) | Savings |
|-----------|--------|---------------|--------|---------------|---------|
| `addLiquidity` (first) | 180,000 | ~$16.20 | 180,000 | ~$0.054 | 99.7% |
| `addLiquidity` (subsequent) | 120,000 | ~$10.80 | 120,000 | ~$0.036 | 99.7% |
| `swap` | 90,000 | ~$8.10 | 90,000 | ~$0.027 | 99.7% |
| `removeLiquidity` | 110,000 | ~$9.90 | 110,000 | ~$0.033 | 99.7% |
| `vault.deposit` | 85,000 | ~$7.65 | 85,000 | ~$0.026 | 99.7% |
| `propose` (governance) | 300,000 | ~$27.00 | 300,000 | ~$0.090 | 99.7% |

> L2 calldata costs dominate; execution gas is nearly identical. The table isolates execution cost to show the L2 fee model advantage.

---

## Design Patterns

| Pattern | Contract | Justification |
|---------|----------|---------------|
| Factory | `ProtocolFactory` | Deterministic pool deployment via CREATE2; registry of all pools |
| Proxy/UUPS | `GovernanceToken`, `YieldVault` | Protocol upgrades without migration; V1→V2 demonstrated |
| Checks-Effects-Interactions | `ConstantProductAMM`, `YieldVault`, `Treasury` | Prevents reentrancy; every external function follows the pattern |
| Pull-over-push | `Treasury` | Recipients claim fees; no auto-push prevents DoS and reentrancy |
| Access Control | All contracts | Role-based permissions; no unguarded admin functions |
| Pausable / Circuit Breaker | `ConstantProductAMM`, `YieldVault` | Emergency stop controlled by Timelock (PAUSER_ROLE) |
| Oracle Adapter | `ChainlinkOracleAdapter` implements `IOracle` | Decouples protocol from Chainlink; mock injected in tests |
| Timelock | `TimelockController` | 2-day delay on all governance actions; defends against flash-loan attacks |
| Reentrancy Guard | `ConstantProductAMM`, `YieldVault`, `Treasury` | Belt-and-suspenders alongside CEI |
| State Machine | `DeFiGovernor` | Proposal lifecycle: Pending→Active→Succeeded→Queued→Executed |

---

## Security

See [docs/audit-report.md](docs/audit-report.md) for the full 8-page security audit report.

**Slither status:** ✅ 0 High, 0 Medium at submission commit.

**Key mitigations:**
- No `tx.origin` auth anywhere
- No `block.timestamp` randomness
- No `transfer`/`send` — all ETH via `call{value:}` with success check
- All ERC-20 interactions via `SafeERC20`
- All external call return values handled
- Flash-loan attack prevented by ERC20Votes snapshot mechanism
