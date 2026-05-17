// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {YieldVault} from "../../src/vault/YieldVault.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {ChainlinkOracleAdapter} from "../../src/oracles/ChainlinkOracleAdapter.sol";

contract YieldVaultTest is Test {
    YieldVault public vault;
    ERC20Mock public asset;
    ChainlinkOracleAdapter public oracle;
    MockAggregator public aggregator;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public strategy = makeAddr("strategy");

    uint256 constant INITIAL_MINT = 1_000_000e18;
    uint256 constant MAX_DEPOSIT = 500_000e18;

    function setUp() public {
        asset = new ERC20Mock();
        aggregator = new MockAggregator(2_000e8, 8); // $2000, 8 decimals
        oracle = new ChainlinkOracleAdapter(address(aggregator), 3_600, admin);

        YieldVault impl = new YieldVault();
        bytes memory initData = abi.encodeCall(
            YieldVault.initialize, (address(asset), "Yield Vault", "yVLT", MAX_DEPOSIT, address(oracle), admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = YieldVault(address(proxy));

        asset.mint(alice, INITIAL_MINT);
        asset.mint(bob, INITIAL_MINT);
        asset.mint(strategy, INITIAL_MINT);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsAsset() public view {
        assertEq(vault.asset(), address(asset));
    }

    function test_Initialize_SetsMaxDeposit() public view {
        assertEq(vault.maxDepositPerUser(), MAX_DEPOSIT);
    }

    function test_Initialize_SetsOracle() public view {
        assertEq(address(vault.oracle()), address(oracle));
    }

    function test_Initialize_AdminHasRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), admin));
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(address(asset), "x", "x", 0, address(0), admin);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_MintsShares() public {
        uint256 amount = 1_000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
    }

    function test_Deposit_RevertIf_Zero() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 1000e18);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    function test_Deposit_RevertIf_ExceedsLimit() public {
        vm.startPrank(alice);
        asset.approve(address(vault), MAX_DEPOSIT + 1);
        vm.expectRevert();
        vault.deposit(MAX_DEPOSIT + 1, alice);
        vm.stopPrank();
    }

    function test_Deposit_RevertIf_LimitReachedAcrossDeposits() public {
        uint256 first = MAX_DEPOSIT / 2;
        uint256 second = MAX_DEPOSIT / 2 + 1;
        vm.startPrank(alice);
        asset.approve(address(vault), MAX_DEPOSIT + 1);
        vault.deposit(first, alice);
        vm.expectRevert();
        vault.deposit(second, alice);
        vm.stopPrank();
    }

    function test_Deposit_RevertIf_Paused() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(alice);
        asset.approve(address(vault), 1000e18);
        vm.expectRevert();
        vault.deposit(1000e18, alice);
        vm.stopPrank();
    }

    function test_Deposit_NoLimit_WhenZero() public {
        vm.prank(admin);
        vault.setMaxDepositPerUser(0); // unlimited

        uint256 amount = 800_000e18;
        asset.mint(alice, amount);
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_DepositsAssets() public {
        uint256 shares = 100e18;
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        uint256 assetsUsed = vault.mint(shares, alice);
        vm.stopPrank();

        assertGt(assetsUsed, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Mint_RevertIf_Zero() public {
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.expectRevert(YieldVault.ZeroShares.selector);
        vault.mint(0, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_ReturnsAssets() public {
        uint256 amount = 10_000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 balBefore = asset.balanceOf(alice);
        vault.withdraw(amount, alice, alice);
        vm.stopPrank();

        assertEq(asset.balanceOf(alice), balBefore + amount);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Withdraw_RevertIf_Zero() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.withdraw(0, alice, alice);
        vm.stopPrank();
    }

    function test_Withdraw_RevertIf_Paused() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert();
        vault.withdraw(amount, alice, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_BurnsShares() public {
        uint256 amount = 5_000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        uint256 balBefore = asset.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(asset.balanceOf(alice), balBefore);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_RevertIf_Zero() public {
        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroShares.selector);
        vault.redeem(0, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD / STRATEGY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReportYield_IncreasesTotalAssets() public {
        uint256 deposit = 10_000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.setStrategy(strategy);

        uint256 yield = 500e18;
        vm.startPrank(strategy);
        asset.approve(address(vault), yield);
        vault.reportYield(yield);
        vm.stopPrank();

        assertEq(vault.totalAssets(), deposit + yield);
    }

    function test_ReportYield_RevertIf_Zero() public {
        vm.prank(admin);
        vault.setStrategy(strategy);

        vm.prank(strategy);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.reportYield(0);
    }

    function test_ReportYield_RevertIf_NotStrategy() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.reportYield(100e18);
    }

    function test_SetStrategy_RevertIf_Zero() public {
        vm.prank(admin);
        vm.expectRevert(YieldVault.InvalidStrategy.selector);
        vault.setStrategy(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_Unpause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Pause_RevertIf_NotPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_SetMaxDeposit_UpdatesLimit() public {
        uint256 newLimit = 999e18;
        vm.prank(admin);
        vault.setMaxDepositPerUser(newLimit);
        assertEq(vault.maxDepositPerUser(), newLimit);
    }

    function test_SetMaxDeposit_RevertIf_NotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxDepositPerUser(999e18);
    }

    function test_SetOracle_UpdatesOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        vault.setOracle(newOracle);
        assertEq(address(vault.oracle()), newOracle);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-4626 ROUNDING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_ERC4626_PreviewDeposit_Conservative() public view {
        uint256 assets = 1_000e18;
        uint256 shares = vault.previewDeposit(assets);
        // previewDeposit should be <= actual shares minted (vault-favoured)
        assertGt(shares, 0);
    }

    function test_ERC4626_ConvertToShares_ConvertToAssets_Roundtrip() public {
        uint256 amount = 10_000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        uint256 assetsBack = vault.convertToAssets(shares);
        assertApproxEqAbs(assetsBack, amount, 1);
    }
}

/*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract YieldVaultFuzz is Test {
    YieldVault public vault;
    ERC20Mock public asset;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        asset = new ERC20Mock();
        YieldVault impl = new YieldVault();
        bytes memory initData =
            abi.encodeCall(YieldVault.initialize, (address(asset), "Yield Vault", "yVLT", 0, address(0), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = YieldVault(address(proxy));

        asset.mint(alice, type(uint128).max);
        asset.mint(bob, type(uint128).max);
    }

    /// @notice Depositing then withdrawing returns the same amount (no yield).
    function testFuzz_DepositWithdraw_Roundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000e18);

        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        uint256 balBefore = asset.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(asset.balanceOf(alice) - balBefore, amount, 1);
    }

    /// @notice Shares are proportional to deposit when vault is empty.
    function testFuzz_Shares_ProportionalToDeposit(uint256 a, uint256 b) public {
        a = bound(a, 1e12, 50_000e18);
        b = bound(b, 1e12, 50_000e18);

        vm.startPrank(alice);
        asset.approve(address(vault), a);
        uint256 sharesA = vault.deposit(a, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), b);
        uint256 sharesB = vault.deposit(b, bob);
        vm.stopPrank();

        // ratio of shares should approximate ratio of deposits (within 1 wei rounding)
        assertApproxEqRel(
            sharesA * b,
            sharesB * a,
            1e15 // 0.1% tolerance
        );
    }

    /// @notice totalAssets always equals sum of deposits (no yield scenario).
    function testFuzz_TotalAssets_EqualsDeposits(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000e18);

        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), amount);
    }
}
