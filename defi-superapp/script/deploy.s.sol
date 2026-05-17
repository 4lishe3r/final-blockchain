// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GovernanceToken} from "../src/tokens/GovernanceToken.sol";
import {GovernanceTokenV2} from "../src/tokens/GovernanceTokenV2.sol";
import {ProtocolNFT} from "../src/tokens/ProtocolNFT.sol";
import {ConstantProductAMM} from "../src/amm/ConstantProductAMM.sol";
import {YieldVault} from "../src/vault/YieldVault.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {ProtocolFactory} from "../src/factory/ProtocolFactory.sol";
import {DeFiGovernor} from "../src/governance/DeFiGovernor.sol";
import {Treasury} from "../src/Treasury.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DeployScript
/// @notice Reproducible deployment of the entire DeFi Super-App protocol.
///
/// @dev Usage:
///   forge script script/deploy.s.sol:DeployScript \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
///     --broadcast \
///     --verify \
///     --etherscan-api-key $ARBISCAN_API_KEY \
///     -vvvv
///
/// @dev The script is IDEMPOTENT within a single run (no re-deployments).
///      Re-running on a fresh network always gives the same contract addresses
///      because ProtocolFactory uses CREATE2 for pools.
///
/// @dev Required env vars:
///   DEPLOYER_PRIVATE_KEY  — private key of the deployer EOA
///   MULTISIG_ADDRESS      — gnosis safe that will hold DEFAULT_ADMIN_ROLE initially
///   CHAINLINK_ETH_USD     — Chainlink ETH/USD aggregator on the target network
///   ASSET_TOKEN           — underlying asset for YieldVault (e.g. testnet USDC)
///   TOKEN_A / TOKEN_B     — token pair for the first AMM pool
contract DeployScript is Script {
    // ── Deployment output (written to console and logs) ───────────
    struct Deployment {
        address govTokenProxy;
        address govTokenImpl;
        address protocolNFT;
        address factory;
        address ammPool;
        address oracle;
        address vault;
        address vaultProxy;
        address timelock;
        address governor;
        address treasury;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address multisig     = vm.envAddress("MULTISIG_ADDRESS");
        address chainlinkFeed = vm.envAddress("CHAINLINK_ETH_USD");
        address assetToken   = vm.envAddress("ASSET_TOKEN");
        address tokenA       = vm.envAddress("TOKEN_A");
        address tokenB       = vm.envAddress("TOKEN_B");

        console2.log("=== DeFi Super-App Deployment ===");
        console2.log("Deployer  :", deployer);
        console2.log("Multisig  :", multisig);
        console2.log("Network   :", block.chainid);
        console2.log("Block     :", block.number);

        vm.startBroadcast(deployerKey);

        // ─────────────────────────────────────────────────────────
        // 1. GovernanceToken — UUPS proxy
        // ─────────────────────────────────────────────────────────
        GovernanceToken govImpl = new GovernanceToken();
        bytes memory govInitData = abi.encodeCall(
            GovernanceToken.initialize,
            ("DeFi Governance Token", "DGT", 100_000_000e18, deployer)
        );
        ERC1967Proxy govProxy = new ERC1967Proxy(address(govImpl), govInitData);
        d.govTokenImpl  = address(govImpl);
        d.govTokenProxy = address(govProxy);
        console2.log("GovToken impl  :", d.govTokenImpl);
        console2.log("GovToken proxy :", d.govTokenProxy);

        // ─────────────────────────────────────────────────────────
        // 2. ProtocolNFT (ERC-721)
        // ─────────────────────────────────────────────────────────
        d.protocolNFT = address(new ProtocolNFT("ipfs://protocol-nft/", deployer, false));
        console2.log("ProtocolNFT    :", d.protocolNFT);

        // ─────────────────────────────────────────────────────────
        // 3. ChainlinkOracleAdapter
        // ─────────────────────────────────────────────────────────
        d.oracle = address(new ChainlinkOracleAdapter(chainlinkFeed, 3_600, deployer));
        console2.log("Oracle         :", d.oracle);

        // ─────────────────────────────────────────────────────────
        // 4. ProtocolFactory (CREATE + CREATE2)
        // ─────────────────────────────────────────────────────────
        d.factory = address(new ProtocolFactory(deployer));
        console2.log("Factory        :", d.factory);

        // ─────────────────────────────────────────────────────────
        // 5. Deploy first AMM pool via Factory (CREATE2 → deterministic)
        // ─────────────────────────────────────────────────────────
        d.ammPool = ProtocolFactory(d.factory).createPool2(tokenA, tokenB);
        console2.log("AMM Pool       :", d.ammPool);

        // ─────────────────────────────────────────────────────────
        // 6. YieldVault — UUPS proxy
        // ─────────────────────────────────────────────────────────
        YieldVault vaultImpl = new YieldVault();
        bytes memory vaultInitData = abi.encodeCall(
            YieldVault.initialize,
            (assetToken, "Yield Vault Shares", "yvShares", 0, d.oracle, deployer)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        d.vault      = address(vaultImpl);
        d.vaultProxy = address(vaultProxy);
        console2.log("Vault impl     :", d.vault);
        console2.log("Vault proxy    :", d.vaultProxy);

        // ─────────────────────────────────────────────────────────
        // 7. TimelockController (2-day delay)
        //    Proposer = Governor (set after Governor deploy)
        //    Executor = anyone (address(0))
        //    Admin    = deployer (renounced after setup)
        // ─────────────────────────────────────────────────────────
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // placeholder — updated after Governor deploy
        executors[0] = address(0); // anyone can execute after delay

        TimelockController timelock = new TimelockController(
            2 days,
            proposers,
            executors,
            deployer  // temporary admin
        );
        d.timelock = address(timelock);
        console2.log("Timelock       :", d.timelock);

        // ─────────────────────────────────────────────────────────
        // 8. DeFiGovernor
        // ─────────────────────────────────────────────────────────
        d.governor = address(new DeFiGovernor(IVotes(d.govTokenProxy), timelock));
        console2.log("Governor       :", d.governor);

        // ─────────────────────────────────────────────────────────
        // 9. Treasury (owner = Timelock)
        // ─────────────────────────────────────────────────────────
        d.treasury = address(new Treasury(deployer, d.timelock));
        console2.log("Treasury       :", d.treasury);

        // ─────────────────────────────────────────────────────────
        // 10. Wire up Timelock roles
        //     • PROPOSER_ROLE → Governor
        //     • CANCELLER_ROLE → multisig (emergency)
        //     • Revoke deployer's TIMELOCK_ADMIN_ROLE
        // ─────────────────────────────────────────────────────────
        bytes32 PROPOSER_ROLE   = timelock.PROPOSER_ROLE();
        bytes32 CANCELLER_ROLE  = timelock.CANCELLER_ROLE();
        bytes32 ADMIN_ROLE      = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(PROPOSER_ROLE,  d.governor);
        timelock.grantRole(CANCELLER_ROLE, multisig);
        timelock.revokeRole(ADMIN_ROLE, deployer); // no admin backdoor

        // ─────────────────────────────────────────────────────────
        // 11. Transfer protocol admin roles to Timelock
        //     (deployer relinquishes control)
        // ─────────────────────────────────────────────────────────
        GovernanceToken(d.govTokenProxy).grantRole(
            GovernanceToken(d.govTokenProxy).DEFAULT_ADMIN_ROLE(), d.timelock
        );
        GovernanceToken(d.govTokenProxy).grantRole(
            GovernanceToken(d.govTokenProxy).UPGRADER_ROLE(), d.timelock
        );

        // ─────────────────────────────────────────────────────────
        // 12. Mint initial token supply to multisig for distribution
        // ─────────────────────────────────────────────────────────
        GovernanceToken(d.govTokenProxy).mint(multisig, 10_000_000e18); // 10M DGT

        vm.stopBroadcast();

        _printSummary(d);
        return d;
    }

    function _printSummary(Deployment memory d) internal pure {
        console2.log("\n=== DEPLOYMENT COMPLETE ===");
        console2.log("Add the following to your .env / README:");
        console2.log("GOV_TOKEN=", d.govTokenProxy);
        console2.log("PROTOCOL_NFT=", d.protocolNFT);
        console2.log("ORACLE=", d.oracle);
        console2.log("FACTORY=", d.factory);
        console2.log("AMM_POOL=", d.ammPool);
        console2.log("VAULT=", d.vaultProxy);
        console2.log("TIMELOCK=", d.timelock);
        console2.log("GOVERNOR=", d.governor);
        console2.log("TREASURY=", d.treasury);
    }
}
