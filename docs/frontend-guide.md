# Frontend Guide

The frontend is located in `frontend/` and is built with React, Vite, Wagmi and Viem.

## Setup

```bash
cd frontend
npm install
npm run dev
```

Open the URL printed by Vite, connect MetaMask, and switch to Arbitrum Sepolia.

## Before demo

Update `frontend/src/addresses.ts`:

```ts
export const addresses = {
  governanceToken: 'DEPLOYED_GOVERNANCE_TOKEN_PROXY',
  amm: 'DEPLOYED_AMM',
  vault: 'DEPLOYED_YIELD_VAULT_PROXY',
  governor: 'DEPLOYED_GOVERNOR',
  subgraphUrl: 'DEPLOYED_SUBGRAPH_URL',
};
```

## Demo checklist

1. Connect MetaMask.
2. Show network detection and switch button.
3. Show governance token balance, voting power and delegate address.
4. Click `Delegate to myself`.
5. Show AMM reserves and LP supply.
6. Approve token0 and perform a swap.
7. Approve vault asset and deposit to the ERC-4626 vault.
8. Load proposals from The Graph section.
9. Paste proposal ID and cast a vote.
10. Show readable error messages by rejecting one transaction in MetaMask.
