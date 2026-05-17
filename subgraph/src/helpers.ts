import { BigInt, Bytes } from '@graphprotocol/graph-ts';
import { ProtocolStats } from '../generated/schema';

export let ZERO = BigInt.fromI32(0);
export let ONE = BigInt.fromI32(1);
export let PROTOCOL_ID = 'protocol';

export function getStats(): ProtocolStats {
  let stats = ProtocolStats.load(PROTOCOL_ID);
  if (stats == null) {
    stats = new ProtocolStats(PROTOCOL_ID);
    stats.totalPools = ZERO;
    stats.totalSwaps = ZERO;
    stats.totalProposals = ZERO;
    stats.totalVotes = ZERO;
    stats.updatedAtBlock = ZERO;
  }
  return stats as ProtocolStats;
}

export function idFromTx(hash: Bytes, logIndex: BigInt): string {
  return hash.toHexString().concat('-').concat(logIndex.toString());
}
