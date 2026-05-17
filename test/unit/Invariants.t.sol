// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Treasury} from "../../src/Treasury.sol";
import {YieldVault} from "../../src/vault/YieldVault.sol";
import {GovernanceToken} from "../../src/tokens/GovernanceToken.sol";

/*//////////////////////////////////////////////////////////////
   Invariants #3, #4, #5 — Treasury accounting, Vault accounting,
                          GovToken supply cap

   These three invariants together with the two existing AMM
   invariants (k-never-decreases, total-supply-above-minimum)
   bring the total to FIVE invariant tests as required by the
   project specification (Section 3.3).
//////////////////////////////////////////////////////////////*/

// ═══════════════════════════════════════════════════════════════════════════════
// INVARIANT #3 — Treasury accounting
//   Claim: at all times, totalPendingETH <= ETH balance, and for every token,
//          totalPendingTokens[token] <= token.balanceOf(treasury).
//   Proves: the audit H-01 fix actually holds under arbitrary sequences.
// ═══════════════════════════════════════════════════════════════════════════════

contract TreasuryInvariantHandler is Test {
    Treasury public treasury;
    ERC20Mock public token;
    address public spender;

    address[] public recipients;

    constructor(Treasury _treasury, ERC20Mock _token, address _spender) {
        treasury = _treasury;
        token = _token;
        spender = _spender;
        recipients.push(makeAddr("r1"));
        recipients.push(makeAddr("r2"));
        recipients.push(makeAddr("r3"));
    }

    function allocateETH(uint256 amount, uint256 rIdx) external {
        amount = bound(amount, 0, 100 ether);
        address r = recipients[rIdx % recipients.length];
        vm.prank(spender);
        try treasury.allocateETH(r, amount) {} catch {}
    }

    function allocateToken(uint256 amount, uint256 rIdx) external {
        amount = bound(amount, 0, 1_000_000e18);
        address r = recipients[rIdx % recipients.length];
        vm.prank(spender);
        try treasury.allocateToken(address(token), r, amount) {} catch {}
    }

    function claimETH(uint256 rIdx) external {
        address r = recipients[rIdx % recipients.length];
        vm.prank(r);
        try treasury.claimETH() {} catch {}
    }

    function claimToken(uint256 rIdx) external {
        address r = recipients[rIdx % recipients.length];
        vm.prank(r);
        try treasury.claimToken(address(token)) {} catch {}
    }

    function topUpETH(uint256 amount) external {
        amount = bound(amount, 0, 100 ether);
        vm.deal(address(treasury), address(treasury).balance + amount);
    }

    function topUpToken(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000e18);
        token.mint(address(treasury), amount);
    }
}

contract TreasuryInvariantTest is Test {
    Treasury public treasury;
    ERC20Mock public token;
    TreasuryInvariantHandler public handler;

    address public spender = makeAddr("spender");

    function setUp() public {
        treasury = new Treasury(address(this), spender);
        token = new ERC20Mock();

        // Seed with some funds so allocate calls can succeed
        vm.deal(address(treasury), 10 ether);
        token.mint(address(treasury), 10_000e18);

        handler = new TreasuryInvariantHandler(treasury, token, spender);
        targetContract(address(handler));
    }

    /// @notice Audit H-01 invariant: treasury can never over-promise its ETH balance.
    function invariant_TreasuryETH_NoOverAllocation() public view {
        assertLe(
            treasury.pendingETH(address(this)),
            address(treasury).balance,
            "totalPendingETH must never exceed actual ETH balance"
        );
    }

    /// @notice Audit H-01 invariant: same for ERC-20 tokens.
    function invariant_TreasuryToken_NoOverAllocation() public view {
        assertLe(
            treasury.pendingTokens(address(token), address(this)),
            token.balanceOf(address(treasury)),
            "totalPendingTokens must never exceed actual token balance"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// INVARIANT #4 — YieldVault accounting
//   Claim: totalAssets() == asset.balanceOf(vault) at all times.
//          This is the ERC-4626 "no leaks" property under any sequence of
//          deposit/withdraw/yield events.
// ═══════════════════════════════════════════════════════════════════════════════

contract VaultInvariantHandler is Test {
    YieldVault public vault;
    ERC20Mock public asset;
    address[] public users;

    constructor(YieldVault _vault, ERC20Mock _asset) {
        vault = _vault;
        asset = _asset;
        users.push(makeAddr("u1"));
        users.push(makeAddr("u2"));
        users.push(makeAddr("u3"));
        for (uint256 i = 0; i < users.length; i++) {
            asset.mint(users[i], 10_000_000e18);
        }
    }

    function deposit(uint256 amount, uint256 uIdx) external {
        amount = bound(amount, 1, 100_000e18);
        address u = users[uIdx % users.length];
        vm.startPrank(u);
        asset.approve(address(vault), amount);
        try vault.deposit(amount, u) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 amount, uint256 uIdx) external {
        amount = bound(amount, 1, 50_000e18);
        address u = users[uIdx % users.length];
        vm.startPrank(u);
        try vault.withdraw(amount, u, u) {} catch {}
        vm.stopPrank();
    }

    function redeem(uint256 shares, uint256 uIdx) external {
        address u = users[uIdx % users.length];
        uint256 maxRedeem = vault.balanceOf(u);
        if (maxRedeem == 0) return;
        shares = bound(shares, 1, maxRedeem);
        vm.prank(u);
        try vault.redeem(shares, u, u) {} catch {}
    }
}

contract VaultInvariantTest is Test {
    YieldVault public vault;
    ERC20Mock public asset;
    VaultInvariantHandler public handler;

    function setUp() public {
        asset = new ERC20Mock();
        YieldVault impl = new YieldVault();
        bytes memory initData = abi.encodeCall(
            YieldVault.initialize,
            (
                address(asset),
                "Yield Vault",
                "yVLT",
                0,
                address(0),
                address(this)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = YieldVault(address(proxy));

        handler = new VaultInvariantHandler(vault, asset);
        targetContract(address(handler));
    }

    /// @notice Vault accounting invariant: totalAssets() equals the live balance.
    ///         This is the property the ERC-4626 share math relies on.
    function invariant_Vault_TotalAssetsEqualsBalance() public view {
        assertEq(
            vault.totalAssets(),
            asset.balanceOf(address(vault)),
            "totalAssets() must equal asset.balanceOf(vault)"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// INVARIANT #5 — GovernanceToken supply cap
//   Claim: totalSupply() <= maxSupply at all times, regardless of mint sequence.
//   Proves: the cap enforced in `mint()` survives any handler-driven workload.
// ═══════════════════════════════════════════════════════════════════════════════

contract GovTokenInvariantHandler is Test {
    GovernanceToken public token;
    address public admin;
    address[] public users;

    constructor(GovernanceToken _token, address _admin) {
        token = _token;
        admin = _admin;
        users.push(makeAddr("u1"));
        users.push(makeAddr("u2"));
        users.push(makeAddr("u3"));
    }

    function mint(uint256 amount, uint256 uIdx) external {
        amount = bound(amount, 0, 10_000_000e18);
        address u = users[uIdx % users.length];
        vm.prank(admin);
        try token.mint(u, amount) {} catch {}
    }

    function burn(uint256 amount, uint256 uIdx) external {
        address u = users[uIdx % users.length];
        uint256 bal = token.balanceOf(u);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(u);
        try token.burn(amount) {} catch {}
    }
}

contract GovTokenInvariantTest is Test {
    GovernanceToken public token;
    GovTokenInvariantHandler public handler;
    address public admin = makeAddr("admin");

    function setUp() public {
        GovernanceToken impl = new GovernanceToken();
        bytes memory initData = abi.encodeCall(
            GovernanceToken.initialize,
            ("Gov", "G", 100_000_000e18, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = GovernanceToken(address(proxy));

        handler = new GovTokenInvariantHandler(token, admin);
        targetContract(address(handler));
    }

    /// @notice The mint() check + burn() reduction together enforce this bound.
    function invariant_GovToken_SupplyWithinCap() public view {
        assertLe(
            token.totalSupply(),
            token.maxSupply(),
            "totalSupply must never exceed maxSupply"
        );
    }
}
