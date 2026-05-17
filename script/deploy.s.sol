// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    TimelockController
} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GovernanceToken} from "../src/tokens/GovernanceToken.sol";
import {ProtocolNFT} from "../src/tokens/ProtocolNFT.sol";
import {ConstantProductAMM} from "../src/amm/ConstantProductAMM.sol";
import {YieldVault} from "../src/vault/YieldVault.sol";
import {
    ChainlinkOracleAdapter
} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {ProtocolFactory} from "../src/factory/ProtocolFactory.sol";
import {DeFiGovernor} from "../src/governance/DeFiGovernor.sol";
import {Treasury} from "../src/Treasury.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";

contract DeployScript is Script {
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
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address deployer = vm.addr(deployerKey);

        address multisig = vm.envAddress("MULTISIG_ADDRESS");

        address assetToken = vm.envAddress("ASSET_TOKEN");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");

        console2.log("=== DeFi Super-App Deployment ===");
        console2.log("Deployer  :", deployer);

        vm.startBroadcast(deployerKey);

        MockAggregator mockFeed = new MockAggregator(3000e8, 8);

        GovernanceToken govImpl = new GovernanceToken();

        bytes memory govInitData = abi.encodeCall(
            GovernanceToken.initialize,
            ("DeFi Governance Token", "DGT", 100_000_000e18, deployer)
        );

        ERC1967Proxy govProxy = new ERC1967Proxy(address(govImpl), govInitData);

        d.govTokenImpl = address(govImpl);
        d.govTokenProxy = address(govProxy);

        console2.log("GovToken proxy :", d.govTokenProxy);

        d.protocolNFT = address(
            new ProtocolNFT("ipfs://protocol-nft/", deployer, false)
        );

        console2.log("ProtocolNFT    :", d.protocolNFT);

        d.oracle = address(
            new ChainlinkOracleAdapter(address(mockFeed), 3600, deployer)
        );

        console2.log("Oracle         :", d.oracle);

        d.factory = address(new ProtocolFactory(deployer));

        console2.log("Factory        :", d.factory);

        d.ammPool = ProtocolFactory(d.factory).createPool2(tokenA, tokenB);

        console2.log("AMM Pool       :", d.ammPool);

        YieldVault vaultImpl = new YieldVault();

        bytes memory vaultInitData = abi.encodeCall(
            YieldVault.initialize,
            (
                assetToken,
                "Yield Vault Shares",
                "yvShares",
                0,
                d.oracle,
                deployer
            )
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );

        d.vault = address(vaultImpl);
        d.vaultProxy = address(vaultProxy);

        console2.log("Vault proxy    :", d.vaultProxy);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);

        proposers[0] = address(0);
        executors[0] = address(0);

        TimelockController timelock = new TimelockController(
            2 days,
            proposers,
            executors,
            deployer
        );

        d.timelock = address(timelock);

        d.governor = address(
            new DeFiGovernor(IVotes(d.govTokenProxy), timelock)
        );

        d.treasury = address(new Treasury(deployer, d.timelock));

        bytes32 PROPOSER_ROLE = timelock.PROPOSER_ROLE();
        bytes32 CANCELLER_ROLE = timelock.CANCELLER_ROLE();
        bytes32 ADMIN_ROLE = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(PROPOSER_ROLE, d.governor);
        timelock.grantRole(CANCELLER_ROLE, multisig);
        timelock.revokeRole(ADMIN_ROLE, deployer);

        GovernanceToken(d.govTokenProxy).grantRole(
            GovernanceToken(d.govTokenProxy).DEFAULT_ADMIN_ROLE(),
            d.timelock
        );

        GovernanceToken(d.govTokenProxy).grantRole(
            GovernanceToken(d.govTokenProxy).UPGRADER_ROLE(),
            d.timelock
        );

        GovernanceToken(d.govTokenProxy).mint(multisig, 10_000_000e18);

        vm.stopBroadcast();

        console2.log("=== DEPLOY COMPLETE ===");

        console2.log("GOV_TOKEN =", d.govTokenProxy);
        console2.log("NFT       =", d.protocolNFT);
        console2.log("ORACLE    =", d.oracle);
        console2.log("FACTORY   =", d.factory);
        console2.log("AMM       =", d.ammPool);
        console2.log("VAULT     =", d.vaultProxy);
        console2.log("TIMELOCK  =", d.timelock);
        console2.log("GOVERNOR  =", d.governor);
        console2.log("TREASURY  =", d.treasury);

        return d;
    }
}
