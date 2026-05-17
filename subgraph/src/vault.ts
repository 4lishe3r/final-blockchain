import { Address, BigInt } from '@graphprotocol/graph-ts';
import { Deposit, Withdraw } from '../generated/YieldVault/YieldVault';
import { VaultSnapshot } from '../generated/schema';

function saveSnapshot(vaultAddress: Address, totalAssets: BigInt, totalShares: BigInt, blockNumber: BigInt, timestamp: BigInt): void {
  let snapshot = new VaultSnapshot(vaultAddress.toHexString().concat('-').concat(blockNumber.toString()));
  snapshot.vault = vaultAddress;
  snapshot.totalAssets = totalAssets;
  snapshot.totalShares = totalShares;
  snapshot.pricePerShare = totalShares.equals(BigInt.fromI32(0)) ? BigInt.fromI32(0) : totalAssets.times(BigInt.fromString('1000000000000000000')).div(totalShares);
  snapshot.blockNumber = blockNumber;
  snapshot.timestamp = timestamp;
  snapshot.save();
}

export function handleVaultDeposit(event: Deposit): void {
  saveSnapshot(event.address, event.params.assets, event.params.shares, event.block.number, event.block.timestamp);
}

export function handleVaultWithdraw(event: Withdraw): void {
  saveSnapshot(event.address, event.params.assets, event.params.shares, event.block.number, event.block.timestamp);
}
