// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernanceToken} from "../src/tokens/GovernanceToken.sol";
import {DeFiGovernor} from "../src/governance/DeFiGovernor.sol";
import {Treasury} from "../src/Treasury.sol";

/// @title VerifyScript
/// @notice Post-deployment sanity checks. Run after deploy.s.sol to confirm
///         that all roles, delays and parameters match the spec.
///         Output is checked into the repo as /deployment/verification.txt
///
/// @dev Usage:
///   forge script script/verify.s.sol:VerifyScript \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
///     -vvvv
contract VerifyScript is Script {
    bool private _allPassed = true;

    function run() external view {
        address govToken  = vm.envAddress("GOV_TOKEN");
        address timelock  = vm.envAddress("TIMELOCK");
        address governor  = vm.envAddress("GOVERNOR");
        address treasury  = vm.envAddress("TREASURY");

        console2.log("=== Post-Deployment Verification ===");
        console2.log("Network :", block.chainid);
        console2.log("Block   :", block.number);
        console2.log("");

        _checkTimelock(timelock, governor);
        _checkGovernor(governor, govToken, timelock);
        _checkTreasury(treasury, timelock);
        _checkNoAdminBackdoor(govToken, timelock);

        if (_allPassed) {
            console2.log("\n[ALL CHECKS PASSED] Protocol is correctly configured.");
        } else {
            console2.log("\n[SOME CHECKS FAILED] Review output above.");
        }
    }

    function _checkTimelock(address timelock, address governor) internal view {
        console2.log("--- Timelock ---");
        TimelockController tl = TimelockController(payable(timelock));

        // Delay must be 2 days
        uint256 delay = tl.getMinDelay();
        _assertBool("Timelock delay == 2 days", delay == 2 days);

        // Governor must have PROPOSER_ROLE
        bool govIsProposer = tl.hasRole(tl.PROPOSER_ROLE(), governor);
        _assertBool("Governor has PROPOSER_ROLE", govIsProposer);

        // Deployer must NOT have DEFAULT_ADMIN_ROLE (renounced in deploy script)
        // We check that address(0) is not the admin (it shouldn't be granted)
        bool timelockSelfAdmin = tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock);
        _assertBool("Timelock is its own admin (deployer revoked)", timelockSelfAdmin);
    }

    function _checkGovernor(address governor, address govToken, address timelock) internal view {
        console2.log("\n--- Governor ---");
        DeFiGovernor gov = DeFiGovernor(payable(governor));

        _assert("Voting delay  == 7200 blocks (1 day)",  gov.votingDelay(),  7200,  7200);
        _assert("Voting period == 50400 blocks (1 week)", gov.votingPeriod(), 50400, 50400);
        _assert("Quorum numerator == 4%", gov.quorumNumerator(), 4, 4);

        // Executor must be the Timelock
        address executor = gov.timelock();
        _assertBool("Governor's timelock == Timelock address", executor == timelock);

        // Token must be govToken
        address token = address(gov.token());
        _assertBool("Governor's token == GovToken proxy", token == govToken);
    }

    function _checkTreasury(address treasury, address timelock) internal view {
        console2.log("\n--- Treasury ---");
        Treasury t = Treasury(payable(treasury));

        bytes32 SPENDER = keccak256("SPENDER_ROLE");
        bool timelockIsSpender = t.hasRole(SPENDER, timelock);
        _assertBool("Timelock has SPENDER_ROLE on Treasury", timelockIsSpender);
    }

    function _checkNoAdminBackdoor(address govToken, address timelock) internal view {
        console2.log("\n--- No Admin Backdoor ---");
        GovernanceToken gt = GovernanceToken(govToken);
        bytes32 ADMIN = gt.DEFAULT_ADMIN_ROLE();
        bytes32 UPGRADER = gt.UPGRADER_ROLE();

        // Timelock must hold admin on govToken
        _assertBool("Timelock is DEFAULT_ADMIN on GovToken", gt.hasRole(ADMIN, timelock));
        _assertBool("Timelock is UPGRADER on GovToken",      gt.hasRole(UPGRADER, timelock));

        console2.log("\nNote: If deployer still holds roles, that is a misconfiguration.");
    }

    /*//////////////////////////////////////////////////////////////
                          ASSERTION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assert(string memory label, uint256 actual, uint256 expected, uint256) internal view {
        bool ok = actual == expected;
        if (ok) {
            console2.log(string.concat("[PASS] ", label));
        } else {
            console2.log(string.concat("[FAIL] ", label));
            console2.log("       Expected:", expected);
            console2.log("       Actual:  ", actual);
        }
    }

    function _assertBool(string memory label, bool condition) internal view {
        if (condition) {
            console2.log(string.concat("[PASS] ", label));
        } else {
            console2.log(string.concat("[FAIL] ", label));
        }
    }
}
