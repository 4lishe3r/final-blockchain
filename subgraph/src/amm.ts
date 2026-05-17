import { Address, BigInt } from '@graphprotocol/graph-ts';
import { LiquidityAdded, LiquidityRemoved, ReservesUpdated, Swap as SwapEvent } from '../generated/ConstantProductAMM/ConstantProductAMM';
import { LiquidityEvent, Pool } from '../generated/schema';
import { getStats, idFromTx, ONE, ZERO } from './helpers';

function getPool(poolAddress: Address, eventBlockNumber: BigInt, eventTimestamp: BigInt): Pool {
  let id = poolAddress.toHexString();
  let pool = Pool.load(id);
  if (pool == null) {
    pool = new Pool(id);
    pool.token0 = poolAddress;
    pool.token1 = poolAddress;
    pool.reserve0 = ZERO;
    pool.reserve1 = ZERO;
    pool.totalSupply = ZERO;
    pool.swapCount = ZERO;
    pool.volumeToken0 = ZERO;
    pool.volumeToken1 = ZERO;
    pool.createdAtBlock = eventBlockNumber;
    pool.createdAtTimestamp = eventTimestamp;
    let stats = getStats();
    stats.totalPools = stats.totalPools.plus(ONE);
    stats.updatedAtBlock = eventBlockNumber;
    stats.save();
  }
  return pool as Pool;
}

export function handleSwap(event: SwapEvent): void {
  let pool = getPool(event.address, event.block.number, event.block.timestamp);
  let entity = new Swap(idFromTx(event.transaction.hash, event.logIndex));
  entity.pool = pool.id;
  entity.sender = event.params.sender;
  entity.tokenIn = event.params.tokenIn;
  entity.amountIn = event.params.amountIn;
  entity.amountOut = event.params.amountOut;
  entity.to = event.params.to;
  entity.blockNumber = event.block.number;
  entity.timestamp = event.block.timestamp;
  entity.txHash = event.transaction.hash;
  entity.save();

  pool.swapCount = pool.swapCount.plus(ONE);
  pool.volumeToken0 = pool.volumeToken0.plus(event.params.amountIn);
  pool.volumeToken1 = pool.volumeToken1.plus(event.params.amountOut);
  pool.save();

  let stats = getStats();
  stats.totalSwaps = stats.totalSwaps.plus(ONE);
  stats.updatedAtBlock = event.block.number;
  stats.save();
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let pool = getPool(event.address, event.block.number, event.block.timestamp);
  let entity = new LiquidityEvent(idFromTx(event.transaction.hash, event.logIndex));
  entity.pool = pool.id;
  entity.type = 'ADD';
  entity.provider = event.params.provider;
  entity.amount0 = event.params.amount0;
  entity.amount1 = event.params.amount1;
  entity.shares = event.params.shares;
  entity.blockNumber = event.block.number;
  entity.timestamp = event.block.timestamp;
  entity.txHash = event.transaction.hash;
  entity.save();
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let pool = getPool(event.address, event.block.number, event.block.timestamp);
  let entity = new LiquidityEvent(idFromTx(event.transaction.hash, event.logIndex));
  entity.pool = pool.id;
  entity.type = 'REMOVE';
  entity.provider = event.params.provider;
  entity.amount0 = event.params.amount0;
  entity.amount1 = event.params.amount1;
  entity.shares = event.params.shares;
  entity.blockNumber = event.block.number;
  entity.timestamp = event.block.timestamp;
  entity.txHash = event.transaction.hash;
  entity.save();
}

export function handleReservesUpdated(event: ReservesUpdated): void {
  let pool = getPool(event.address, event.block.number, event.block.timestamp);
  pool.reserve0 = event.params.reserve0;
  pool.reserve1 = event.params.reserve1;
  pool.save();
}
