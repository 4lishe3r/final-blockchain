# Subgraph Queries

Update `subgraph.yaml` with deployed addresses and start blocks before running codegen/build.

```bash
cd subgraph
npm install
npm run codegen
npm run build
npm run deploy
```

## Query 1: latest swaps

```graphql
{
  swaps(first: 10, orderBy: timestamp, orderDirection: desc) {
    id
    sender
    tokenIn
    amountIn
    amountOut
    to
  }
}
```

## Query 2: pool reserves

```graphql
{
  pools(first: 5) {
    id
    reserve0
    reserve1
    totalSupply
    swapCount
  }
}
```

## Query 3: liquidity events

```graphql
{
  liquidityEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
    provider
    type
    amount0
    amount1
    shares
  }
}
```

## Query 4: DAO proposals

```graphql
{
  proposals(first: 10, orderBy: createdAtTimestamp, orderDirection: desc) {
    id
    proposer
    description
    state
    forVotes
    againstVotes
    abstainVotes
  }
}
```

## Query 5: protocol stats

```graphql
{
  protocolStats(id: "protocol") {
    totalPools
    totalSwaps
    totalProposals
    totalVotes
    updatedAtBlock
  }
}
```
