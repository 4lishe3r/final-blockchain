# DeFi Super-App — Blockchain Technologies 2 Capstone

> Scenario A — AMM + ERC-4626 Vault + DAO Governance · Deployed on Base Sepolia

---

# Overview

DeFi Super-App is a full-stack decentralised finance protocol built for the Blockchain Technologies 2 final project.

The platform combines multiple DeFi primitives into one integrated dApp:

- Automated Market Maker (AMM)
- ERC-4626 Yield Vault
- DAO Governance
- Timelock Treasury
- Chainlink Oracle Integration
- Upgradeable Smart Contracts
- Wallet Integration
- Frontend Dashboard

The protocol is fully deployed on Base Sepolia testnet and connected to a working frontend application.

---

# Architecture

Users interact with the frontend dashboard through MetaMask.

The frontend communicates with deployed smart contracts:

- GovernanceToken
- ConstantProductAMM
- YieldVault
- DeFiGovernor
- Treasury
- ProtocolNFT
- ChainlinkOracleAdapter

The protocol uses:
- ERC-1967 UUPS proxies
- OpenZeppelin Governor
- TimelockController
- Role-based access control
- Chainlink oracle feeds
- ERC-4626 tokenized vault standard

---

# Smart Contracts

| Contract | Description |
|----------|-------------|
| GovernanceToken | ERC20Votes governance token |
| GovernanceTokenV2 | Upgradeable governance token version |
| ProtocolNFT | ERC721 membership NFT |
| ConstantProductAMM | x*y=k automated market maker |
| YieldVault | ERC4626 yield vault |
| ChainlinkOracleAdapter | Oracle price adapter |
| ProtocolFactory | Pool deployment factory |
| DeFiGovernor | DAO governance contract |
| TimelockController | Governance timelock |
| Treasury | Protocol treasury |

---

# Deployed Addresses

> Network: Base Sepolia (Chain ID 84532)

| Contract | Address |
|----------|---------|
| GovernanceToken | `0xA2E174F9fAB0690489DC6EA4300BA242ee4A6807` |
| ProtocolNFT | `0xD98FC5f700E7D7059981Fc2Def353eE6ffe2a827` |
| Oracle | `0x38E6cBb4fb3F0a20C741A2Ed9A08d5e408C07faa` |
| Factory | `0xD07ccA3995FdE9a3933Fb8A761451Bc7f42Edd82` |
| AMM Pool | `0x995f482A876364d82313Bd3b0c29F1350d19188C` |
| YieldVault | `0x556234E9cBaC3B7a8d9254811a7aDaA098aE8533` |
| Timelock | `0xF08eaD1d04C585A050B817E694862E9B570214F2` |
| Governor | `0x99ca18C410840087ef301A38659fc090632d1De8` |
| Treasury | `0x0ED85c9c8E347C3AccC086A9175336708F0665C7` |

---

# Features

## AMM
- Constant product liquidity pool
- Token swaps
- Liquidity provision
- LP token minting

## ERC-4626 Vault
- Tokenized vault shares
- Deposits and withdrawals
- Yield accounting
- Upgradeable architecture

## DAO Governance
- Proposal voting
- Timelock execution
- Delegated voting power
- Governor + Treasury system

## Oracle Integration
- Chainlink price feeds
- Oracle abstraction layer
- Staleness protection

## Security
- ReentrancyGuard
- AccessControl
- Timelock governance
- CEI pattern
- UUPS upgrade authorization

---

# Frontend

Frontend stack:
- React
- TypeScript
- Vite
- Wagmi
- MetaMask
- Ethers.js

The dashboard supports:
- Wallet connection
- Governance token management
- Voting delegation
- AMM interaction
- Vault interaction
- DAO voting

---

# Setup

```bash
git clone <repository>
cd defi-superapp

Install dependencies:

forge install
npm install
Build
forge build
Tests

Run all tests:

forge test -vvv

Coverage:

forge coverage --report summary
Deployment

Deploy contracts:

forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
Run Frontend
cd frontend
npm install
npm run dev

Open:

http://localhost:5173
Governance Flow
Connect MetaMask
Switch to Base Sepolia
Delegate voting power
Create proposal
Vote on proposal
Queue proposal
Execute proposal through Timelock
Security Design Patterns
Factory Pattern
Proxy/UUPS Pattern
CEI Pattern
Pull-over-Push Treasury
Timelock Governance
Oracle Adapter Pattern
Access Control
Reentrancy Protection
Final Result

The project demonstrates a complete decentralized finance ecosystem with:

Smart contracts
DAO governance
Upgradeable architecture
Frontend integration
On-chain deployment
Wallet interaction
Oracle integration
ERC standards
Security patterns

All components are deployed and operational on Base Sepolia testnet.