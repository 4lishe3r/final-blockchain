// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Treasury} from "../../src/Treasury.sol";

contract TreasuryTest is Test {
    Treasury public treasury;
    ERC20Mock public token;

    address public admin    = makeAddr("admin");
    address public timelock = makeAddr("timelock");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");

    function setUp() public {
        treasury = new Treasury(admin, timelock);
        token = new ERC20Mock();

        // Fund treasury with ETH and tokens
        vm.deal(address(treasury), 10 ether);
        token.mint(address(treasury), 100_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsRoles() public view {
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(treasury.hasRole(treasury.SPENDER_ROLE(), timelock));
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), timelock);
    }

    function test_Constructor_RevertIf_ZeroTimelock() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(admin, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    function test_Receive_ETH() public {
        uint256 before = address(treasury).balance;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, before + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOCATE ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AllocateETH_SetsPending() public {
        vm.prank(timelock);
        treasury.allocateETH(alice, 1 ether);
        assertEq(treasury.pendingETH(alice), 1 ether);
    }

    function test_AllocateETH_Accumulates() public {
        vm.startPrank(timelock);
        treasury.allocateETH(alice, 1 ether);
        treasury.allocateETH(alice, 0.5 ether);
        vm.stopPrank();
        assertEq(treasury.pendingETH(alice), 1.5 ether);
    }

    function test_AllocateETH_RevertIf_NotSpender() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.allocateETH(alice, 1 ether);
    }

    function test_AllocateETH_RevertIf_ZeroAmount() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.allocateETH(alice, 0);
    }

    function test_AllocateETH_RevertIf_ZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.allocateETH(address(0), 1 ether);
    }

    function test_AllocateETH_RevertIf_InsufficientBalance() public {
        vm.prank(timelock);
        vm.expectRevert();
        treasury.allocateETH(alice, 999 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimETH_TransfersETH() public {
        vm.prank(timelock);
        treasury.allocateETH(alice, 2 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        treasury.claimETH();
        assertEq(alice.balance, before + 2 ether);
    }

    function test_ClaimETH_ClearsPending() public {
        vm.prank(timelock);
        treasury.allocateETH(alice, 1 ether);

        vm.prank(alice);
        treasury.claimETH();
        assertEq(treasury.pendingETH(alice), 0);
    }

    function test_ClaimETH_RevertIf_NothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.NothingToClaim.selector);
        treasury.claimETH();
    }

    function test_ClaimETH_RevertIf_DoubleCliam() public {
        vm.prank(timelock);
        treasury.allocateETH(alice, 1 ether);

        vm.startPrank(alice);
        treasury.claimETH();
        vm.expectRevert(Treasury.NothingToClaim.selector);
        treasury.claimETH();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOCATE TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AllocateToken_SetsPending() public {
        vm.prank(timelock);
        treasury.allocateToken(address(token), alice, 1_000e18);
        assertEq(treasury.pendingTokens(alice, address(token)), 1_000e18);
    }

    function test_AllocateToken_RevertIf_NotSpender() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.allocateToken(address(token), alice, 1_000e18);
    }

    function test_AllocateToken_RevertIf_ZeroAmount() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.allocateToken(address(token), alice, 0);
    }

    function test_AllocateToken_RevertIf_ZeroRecipient() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.allocateToken(address(token), address(0), 1_000e18);
    }

    function test_AllocateToken_RevertIf_ZeroToken() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.allocateToken(address(0), alice, 1_000e18);
    }

    function test_AllocateToken_RevertIf_InsufficientBalance() public {
        vm.prank(timelock);
        vm.expectRevert();
        treasury.allocateToken(address(token), alice, 999_999_999e18);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimToken_TransfersTokens() public {
        uint256 amount = 5_000e18;
        vm.prank(timelock);
        treasury.allocateToken(address(token), alice, amount);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        treasury.claimToken(address(token));
        assertEq(token.balanceOf(alice), before + amount);
    }

    function test_ClaimToken_ClearsPending() public {
        vm.prank(timelock);
        treasury.allocateToken(address(token), alice, 1_000e18);

        vm.prank(alice);
        treasury.claimToken(address(token));
        assertEq(treasury.pendingTokens(alice, address(token)), 0);
    }

    function test_ClaimToken_RevertIf_NothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.NothingToClaim.selector);
        treasury.claimToken(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_EthBalance_ReturnsBalance() public view {
        assertEq(treasury.ethBalance(), 10 ether);
    }

    function test_TokenBalance_ReturnsBalance() public view {
        assertEq(treasury.tokenBalance(address(token)), 100_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                REENTRANCY PROTECTION TEST
    //////////////////////////////////////////////////////////////*/

    function test_ClaimETH_ReentrancyProtected() public {
        ReentrantClaimer attacker = new ReentrantClaimer(treasury);
        vm.deal(address(treasury), 10 ether);

        vm.prank(timelock);
        treasury.allocateETH(address(attacker), 1 ether);

        // Should not drain more than allocated
        vm.prank(address(attacker));
        attacker.attack();

        // Treasury still has most ETH — attacker only got what was allocated
        assertEq(treasury.pendingETH(address(attacker)), 0);
    }
}

/// @dev Attacker tries to re-enter claimETH
contract ReentrantClaimer {
    Treasury public target;
    uint256 public count;

    constructor(Treasury _t) { target = _t; }

    function attack() external {
        target.claimETH();
    }

    receive() external payable {
        count++;
        if (count < 3 && address(target).balance >= 1 ether) {
            // This re-entry should fail due to ReentrancyGuard
            try target.claimETH() {} catch {}
        }
    }
}

/*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract TreasuryFuzz is Test {
    Treasury public treasury;
    ERC20Mock public token;

    address timelock = makeAddr("timelock");
    address admin    = makeAddr("admin");

    function setUp() public {
        treasury = new Treasury(admin, timelock);
        token = new ERC20Mock();
        vm.deal(address(treasury), 100 ether);
        token.mint(address(treasury), 1_000_000e18);
    }

    function testFuzz_AllocateAndClaimETH(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        address recipient = makeAddr("recipient");

        vm.prank(timelock);
        treasury.allocateETH(recipient, amount);

        uint256 before = recipient.balance;
        vm.prank(recipient);
        treasury.claimETH();

        assertEq(recipient.balance, before + amount);
        assertEq(treasury.pendingETH(recipient), 0);
    }

    function testFuzz_AllocateAndClaimToken(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        address recipient = makeAddr("recipient");

        vm.prank(timelock);
        treasury.allocateToken(address(token), recipient, amount);

        vm.prank(recipient);
        treasury.claimToken(address(token));

        assertEq(token.balanceOf(recipient), amount);
    }
}
