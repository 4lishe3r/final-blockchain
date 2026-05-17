import { ProposalCanceled, ProposalCreated, ProposalExecuted, ProposalQueued, VoteCast } from '../generated/DeFiGovernor/DeFiGovernor';
import { Proposal, Vote } from '../generated/schema';
import { getStats, idFromTx, ONE, ZERO } from './helpers';

export function handleProposalCreated(event: ProposalCreated): void {
  let proposal = new Proposal(event.params.proposalId.toString());
  proposal.proposer = event.params.proposer;
  proposal.targets = event.params.targets;
  proposal.values = event.params.values;
  proposal.calldatas = event.params.calldatas;
  proposal.description = event.params.description;
  proposal.startBlock = event.params.startBlock;
  proposal.endBlock = event.params.endBlock;
  proposal.state = 'Pending';
  proposal.forVotes = ZERO;
  proposal.againstVotes = ZERO;
  proposal.abstainVotes = ZERO;
  proposal.quorumReached = false;
  proposal.createdAtBlock = event.block.number;
  proposal.createdAtTimestamp = event.block.timestamp;
  proposal.save();

  let stats = getStats();
  stats.totalProposals = stats.totalProposals.plus(ONE);
  stats.updatedAtBlock = event.block.number;
  stats.save();
}

export function handleVoteCast(event: VoteCast): void {
  let proposal = Proposal.load(event.params.proposalId.toString());
  if (proposal == null) return;

  let vote = new Vote(idFromTx(event.transaction.hash, event.logIndex));
  vote.proposal = proposal.id;
  vote.voter = event.params.voter;
  vote.support = event.params.support;
  vote.weight = event.params.weight;
  vote.reason = event.params.reason;
  vote.blockNumber = event.block.number;
  vote.timestamp = event.block.timestamp;
  vote.txHash = event.transaction.hash;
  vote.save();

  if (event.params.support == 0) proposal.againstVotes = proposal.againstVotes.plus(event.params.weight);
  if (event.params.support == 1) proposal.forVotes = proposal.forVotes.plus(event.params.weight);
  if (event.params.support == 2) proposal.abstainVotes = proposal.abstainVotes.plus(event.params.weight);
  proposal.quorumReached = proposal.forVotes.gt(ZERO);
  proposal.state = 'Active';
  proposal.save();

  let stats = getStats();
  stats.totalVotes = stats.totalVotes.plus(ONE);
  stats.updatedAtBlock = event.block.number;
  stats.save();
}

export function handleProposalQueued(event: ProposalQueued): void {
  let proposal = Proposal.load(event.params.proposalId.toString());
  if (proposal == null) return;
  proposal.state = 'Queued';
  proposal.save();
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let proposal = Proposal.load(event.params.proposalId.toString());
  if (proposal == null) return;
  proposal.state = 'Executed';
  proposal.save();
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let proposal = Proposal.load(event.params.proposalId.toString());
  if (proposal == null) return;
  proposal.state = 'Canceled';
  proposal.save();
}
