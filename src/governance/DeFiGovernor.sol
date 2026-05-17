// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from
    "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DeFiGovernor
/// @notice On-chain governance for the DeFi Super-App. Extends the full OpenZeppelin Governor stack.
///
/// @dev Parameters (matching project spec):
///  • Voting delay:    1 day   (~7200 blocks at 12s/block)
///  • Voting period:   1 week  (~50400 blocks)
///  • Proposal threshold: 1%  of total supply (10_000 / 1_000_000 = 1%)
///  • Quorum:          4%      of total supply at proposal snapshot
///  • Timelock delay:  2 days  (set in TimelockController constructor)
///
/// @dev Governance attack mitigations (documented in audit report §7):
///  • Flash-loan attack: ERC20Votes snapshots at block N-1 (GovernorVotes).
///    A flash loan in block N cannot boost voting power used at N-1.
///  • Whale attack: 4% quorum and 2-day timelock limit impact of a single whale.
///  • Spam proposals: 1% proposal threshold requires skin in the game.
///  • Timelock bypass: Governor is the sole Proposer role on the Timelock.
///    No party can queue actions without passing a vote.
contract DeFiGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _token    GovernanceToken (ERC20Votes)
    /// @param _timelock TimelockController (2-day delay, set externally)
    constructor(IVotes _token, TimelockController _timelock)
        Governor("DeFiGovernor")
        GovernorSettings(
            7200,  // 1-day voting delay  (blocks, ~12s each)
            50400, // 1-week voting period (blocks)
            0      // proposal threshold set via quorumNumerator; override below
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4) // 4% quorum
        GovernorTimelockControl(_timelock)
    {}

    /*//////////////////////////////////////////////////////////////
                      PROPOSAL THRESHOLD (1%)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the minimum number of votes required to create a proposal.
    ///      1% of the current total supply of the governance token.
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return token().getPastTotalSupply(block.number - 1) / 100; // 1%
    }

    /*//////////////////////////////////////////////////////////////
                          OZ OVERRIDES (required)
    //////////////////////////////////////////////////////////////*/

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
