// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";
import {GovernanceTokenV2} from "../../src/tokens/GovernanceTokenV2.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken public token;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public minter = makeAddr("minter");

    uint256 constant MAX_SUPPLY = 100_000_000e18;

    function setUp() public {
        GovernanceToken impl = new GovernanceToken();
        bytes memory initData = abi.encodeCall(GovernanceToken.initialize, ("DeFi Gov Token", "DGT", MAX_SUPPLY, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = GovernanceToken(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsName() public view {
        assertEq(token.name(), "DeFi Gov Token");
    }

    function test_Initialize_SetsSymbol() public view {
        assertEq(token.symbol(), "DGT");
    }

    function test_Initialize_SetsMaxSupply() public view {
        assertEq(token.maxSupply(), MAX_SUPPLY);
    }

    function test_Initialize_AdminHasRoles() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_RevertIf_ZeroAdmin() public {
        GovernanceToken impl2 = new GovernanceToken();
        bytes memory bad = abi.encodeCall(GovernanceToken.initialize, ("T", "T", 1e18, address(0)));
        vm.expectRevert();
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        token.initialize("X", "X", 1, admin);
    }

    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_IncreasesBalance() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_Mint_RevertIf_ExceedsMaxSupply() public {
        vm.prank(admin);
        vm.expectRevert();
        token.mint(alice, MAX_SUPPLY + 1);
    }

    function test_Mint_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    function test_Mint_RevertIf_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100e18);
    }

    function test_Mint_CustomMinter() public {
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        token.mint(bob, 500e18);
        assertEq(token.balanceOf(bob), 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                        BURN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Burn_DecreasesBalance() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(alice);
        token.burn(400e18);
        assertEq(token.balanceOf(alice), 600e18);
    }

    function test_Burn_AllowsMintingUpToMax() public {
        vm.prank(admin);
        token.mint(alice, MAX_SUPPLY);

        vm.prank(alice);
        token.burn(500e18);

        vm.prank(admin);
        token.mint(bob, 500e18); // should succeed — space freed up
        assertEq(token.balanceOf(bob), 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                        MAX SUPPLY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetMaxSupply_Updates() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(admin);
        token.setMaxSupply(MAX_SUPPLY * 2);
        assertEq(token.maxSupply(), MAX_SUPPLY * 2);
    }

    function test_SetMaxSupply_RevertIf_BelowCurrentSupply() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(admin);
        vm.expectRevert();
        token.setMaxSupply(999e18);
    }

    function test_SetMaxSupply_RevertIf_NotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setMaxSupply(MAX_SUPPLY * 2);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20VOTES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Votes_DelegateSelf() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), 1_000e18);
    }

    function test_Votes_DelegateToOther() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(alice);
        token.delegate(bob);

        assertEq(token.getVotes(bob), 1_000e18);
        assertEq(token.getVotes(alice), 0);
    }

    function test_Votes_SnapshotOnTransfer() public {
        vm.prank(admin);
        token.mint(alice, 1_000e18);

        vm.prank(alice);
        token.delegate(alice);

        uint256 blockBefore = block.number;
        vm.roll(block.number + 1);

        vm.prank(alice);
        token.transfer(bob, 500e18);

        // Snapshot at blockBefore still shows 1000
        assertEq(token.getPastVotes(alice, blockBefore), 1_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Permit_WorksWithSignature() public {
        uint256 privKey = 0xA11CE;
        address owner = vm.addr(privKey);

        vm.prank(admin);
        token.mint(owner, 1_000e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privKey, owner, bob, 500e18, deadline);

        token.permit(owner, bob, 500e18, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOCK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Clock_ReturnsBlockNumber() public view {
        assertEq(token.clock(), uint48(block.number));
    }

    function test_ClockMode_IsBlockNumber() public view {
        assertEq(token.CLOCK_MODE(), "mode=blocknumber&from=default");
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _signPermit(uint256 privKey, address owner_, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner_,
                spender,
                value,
                token.nonces(owner_),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(privKey, digest);
    }
}

/*//////////////////////////////////////////////////////////////
            GovernanceTokenV2 — UPGRADE PATH TESTS
//////////////////////////////////////////////////////////////*/

contract GovernanceTokenV2Test is Test {
    GovernanceToken public v1;
    GovernanceTokenV2 public v2;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public treasury = makeAddr("treasury");

    function setUp() public {
        // Deploy V1
        GovernanceToken impl1 = new GovernanceToken();
        bytes memory initData =
            abi.encodeCall(GovernanceToken.initialize, ("DeFi Gov Token", "DGT", 100_000_000e18, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl1), initData);
        v1 = GovernanceToken(address(proxy));

        // Mint some tokens
        vm.prank(admin);
        v1.mint(alice, 10_000e18);

        // Upgrade to V2
        GovernanceTokenV2 impl2 = new GovernanceTokenV2();
        bytes memory upgradeData = abi.encodeCall(
            GovernanceTokenV2.initializeV2,
            (100, treasury) // 1% tax
        );
        vm.prank(admin);
        v1.upgradeToAndCall(address(impl2), upgradeData);
        v2 = GovernanceTokenV2(address(proxy));
    }

    function test_Upgrade_PreservesBalance() public view {
        assertEq(v2.balanceOf(alice), 10_000e18);
    }

    function test_Upgrade_PreservesMaxSupply() public view {
        assertEq(v2.maxSupply(), 100_000_000e18);
    }

    function test_Upgrade_SetsTransferTax() public view {
        assertEq(v2.transferTaxBps(), 100);
    }

    function test_Upgrade_SetsTreasury() public view {
        assertEq(v2.treasury(), treasury);
    }

    function test_V2_TransferTax_SendsTaxToTreasury() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 1_000e18;

        vm.prank(alice);
        v2.transfer(recipient, amount);

        uint256 expectedTax = (amount * 100) / 10_000; // 1%
        assertEq(v2.balanceOf(treasury), expectedTax);
        assertEq(v2.balanceOf(recipient), amount - expectedTax);
    }

    function test_V2_Mint_ExemptFromTax() public {
        vm.prank(admin);
        v2.mint(alice, 500e18);
        // Treasury should not receive anything from a mint
        assertEq(v2.balanceOf(treasury), 0);
    }

    function test_V2_SetTransferTax_RevertIf_TooHigh() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceTokenV2.TaxTooHigh.selector);
        v2.setTransferTax(501);
    }

    function test_V2_SetTransferTax_UpdatesBps() public {
        vm.prank(admin);
        v2.setTransferTax(200);
        assertEq(v2.transferTaxBps(), 200);
    }

    function test_V2_SetTreasury_RevertIf_Zero() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceTokenV2.ZeroTreasury.selector);
        v2.setTreasury(address(0));
    }

    function test_V2_SetTreasury_Updates() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        v2.setTreasury(newTreasury);
        assertEq(v2.treasury(), newTreasury);
    }

    function test_V2_InitializeV2_CannotCallTwice() public {
        vm.prank(admin);
        vm.expectRevert();
        v2.initializeV2(100, treasury);
    }

    function test_V2_UpgradeByNonUpgrader_Reverts() public {
        GovernanceTokenV2 impl3 = new GovernanceTokenV2();
        vm.prank(alice);
        vm.expectRevert();
        v2.upgradeToAndCall(address(impl3), "");
    }
}

/*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract GovernanceTokenFuzz is Test {
    GovernanceToken public token;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        GovernanceToken impl = new GovernanceToken();
        bytes memory initData =
            abi.encodeCall(GovernanceToken.initialize, ("DeFi Gov Token", "DGT", type(uint128).max, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = GovernanceToken(address(proxy));
    }

    function testFuzz_Mint_NeverExceedsMaxSupply(uint256 amount) public {
        amount = bound(amount, 0, token.maxSupply());
        vm.prank(admin);
        token.mint(alice, amount);
        assertLe(token.totalSupply(), token.maxSupply());
    }

    function testFuzz_Votes_MatchBalance(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e18);
        vm.prank(admin);
        token.mint(alice, amount);

        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), amount);
    }
}
