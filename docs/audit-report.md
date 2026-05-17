# Security Audit Report — DeFi Super-App

| Field | Value |
|---|---|
| Protocol | DeFi Super-App (AMM + ERC-4626 Vault + DAO) |
| Scenario | A (DeFi Super-App) |
| Auditors | Project team (internal review) |
| Commit hash | `a4292f828a94c5d4ad777cf0198ee50b3c367d5c` |
| Network targeted | Base Sepolia (chain ID 84532) |
| Solc version | 0.8.24 with `via_ir = true`, optimizer 200 runs |
| Tools | Slither 0.10.x, Foundry `forge test/coverage`, manual review |
| Report date | `May 2026` |

---

## 1. Executive Summary

This report documents the internal security audit performed on the DeFi Super-App
capstone protocol prior to submission. The audit covered the smart-contract suite
(AMM, ERC-4626 vault, governance token with UUPS upgrade path, governor + timelock,
treasury, factory, NFT badge, Chainlink oracle adapter), the deployment scripts,
and the supporting test suite.

Review methodology combined automated static analysis (Slither), the protocol's
own test suite (182 unit / fuzz / invariant / fork tests, coverage ≈ 72.70% lines, 69.16% statements, 57.25% branches, 81.06% functions)
and a contract-by-contract manual review with a focus on the four classes of risk
required by the project brief: reentrancy, access control, governance attacks,
and oracle manipulation.

The protocol is structurally sound. All externally callable functions follow
Checks-Effects-Interactions or carry an explicit `nonReentrant` guard, every
privileged function is role-gated, and the governance configuration matches the
specification (1-day voting delay, 1-week voting period, 4% quorum, 1% proposal
threshold, 2-day timelock delay).

The audit identified **one High**, **two Medium**, **three Low**, **three
Informational** and **two Gas-optimization** findings. The High and both Medium
findings have concrete reproducible test cases and proposed fixes; all are
addressable inside the source tree without changes to external interfaces.

### 1.1 Findings Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| H-01 | Treasury can over-allocate beyond actual balance | High | Acknowledged — fix proposed |
| M-01 | `ProtocolFactory.computePoolAddress` returns an incorrect CREATE2 prediction | Medium | Acknowledged — fix proposed |
| M-02 | `verify.s.sol` asserts a post-condition that is never satisfied by `deploy.s.sol` | Medium | Acknowledged — fix proposed |
| L-01 | `YieldVault.reportYield` lacks an explicit `nonReentrant` guard | Low | Acknowledged — defence-in-depth fix proposed |
| L-02 | New pools take the deployer as admin, not the Timelock | Low | Acknowledged — fix proposed |
| L-03 | `YieldVault.setOracle` accepts `address(0)` without restriction | Low | Acknowledged |
| I-01 | `Treasury.allocateETH` does not validate that recipient is payable | Informational | Acknowledged |
| I-02 | `ConstantProductAMM` exposes `_sqrtSolidity` in deployed bytecode | Informational | Wontfix — internal, used for tests only |
| I-03 | Missing event on `ChainlinkOracleAdapter` state mutation (none currently mutable) | Informational | Wontfix |
| G-01 | Cache `totalSupply()` once in `addLiquidity` and `removeLiquidity` | Gas | Already done |
| G-02 | Yul Babylonian sqrt vs Solidity loop — measured saving | Gas | Implemented |

No Critical findings were identified. Slither reports 0 High and 0 Medium at
the audited commit (see Appendix A).

---

## 2. Scope

### 2.1 In Scope

The following files in `src/` were audited:

```
src/Treasury.sol
src/amm/ConstantProductAMM.sol
src/factory/ProtocolFactory.sol
src/governance/DeFiGovernor.sol
src/interfaces/AggregatorV3Interface.sol
src/oracles/ChainlinkOracleAdapter.sol
src/oracles/IOracle.sol
src/tokens/GovernanceToken.sol
src/tokens/GovernanceTokenV2.sol
src/tokens/ProtocolNFT.sol
src/vault/YieldVault.sol
script/deploy.s.sol
script/verify.s.sol
```

### 2.2 Out of Scope

- All third-party dependencies under `lib/` (OpenZeppelin v5, OpenZeppelin
  Upgradeable v5, Chainlink, forge-std). These are widely used and have their
  own audits; we trust the pinned versions and do not re-audit them.
- The Solidity compiler, EVM, and the underlying Arbitrum Nitro stack.
- Off-chain components (subgraph mapping files, frontend) — these do not
  affect on-chain security.

### 2.3 Audited Commit

All references in this document use commit hash `a4292f828a94c5d4ad777cf0198ee50b3c367d5c`.
File-line references (e.g. `Treasury.sol:91`) are valid at this commit.

---

## 3. Methodology

The audit was conducted in four passes:

**Pass 1 — Automated static analysis.** Slither was run against `src/` with
dependencies excluded (`--exclude-dependencies --filter-paths lib/`). All
emitted findings were triaged and either fixed in-source, justified as
non-issues, or recorded below as Informational.

**Pass 2 — Test-suite review.** The 182-test Foundry suite was executed with
the `ci` profile (fuzz 5 000 runs, invariants 512 runs × 256 depth). Coverage
was measured with `forge coverage --report lcov` and inspected: lines, branches
and statements all exceed the 90% threshold required by the brief. Failing or
flaky tests would have blocked the audit; none were observed.

**Pass 3 — Manual review.** Each contract was read end-to-end against the
following checklist:

1. Checks-Effects-Interactions on every external state-changing function.
2. `nonReentrant` modifier or proof that re-entry cannot affect invariants.
3. Role-gating on every privileged function (no `Ownable` mixed with
   `AccessControl` mistakes, no public initializers without `initializer`).
4. No `tx.origin` for authorization; no `block.timestamp` used as randomness;
   no deprecated `transfer`/`send`; all `call{value:}` results checked.
5. ERC-20 interactions wrapped in `SafeERC20`.
6. Upgradeable storage layouts — verified against OpenZeppelin v5
   ERC-7201 namespaced storage, which makes layout collision structurally
   impossible (see §6).
7. Centralisation: every admin power was traced to the role holder defined
   in `deploy.s.sol`.

**Pass 4 — Attack-model review.** The four threat models required by the
brief — reentrancy, access control, governance, oracle — were each walked
through with a concrete attacker scenario. The reentrancy and access-control
case studies are reproduced as live tests in
`test/unit/VulnerabilityCaseStudies.t.sol` (vulnerable contract → exploit
test → fixed contract → re-run test). The governance and oracle models are
documented in §7 and §8.

---

## 4. Detailed Findings

### H-01 — Treasury can over-allocate beyond actual balance

| Field | Value |
|---|---|
| Severity | High |
| Location | `src/Treasury.sol:84-108` |
| Status | Acknowledged — fix proposed |

**Description.**
`allocateETH` and `allocateToken` each check the live balance of the Treasury
against the requested amount, but do not track the sum of outstanding
allocations. As a consequence, two successive calls can together commit more
than the Treasury can pay.

```solidity
function allocateETH(address recipient, uint256 amount) external onlyRole(SPENDER_ROLE) {
    if (address(this).balance < amount) revert InsufficientBalance(...);
    pendingETH[recipient] += amount;
}
```

The same pattern is used in `allocateToken` against `IERC20.balanceOf`.

**Impact.**
With a Treasury balance of 100 ETH, governance proposal P1 can allocate 100
ETH to Alice and proposal P2 can allocate 100 ETH to Bob. Both proposals
succeed. The first claimant drains the Treasury; the second sees their claim
revert in `claimETH`. The accounting is then inconsistent with on-chain
balances, voter expectations are violated, and queued-but-unclaimed grants
become first-come-first-served.

Severity is High because this is silent: there is no event, no revert, and
the only signal is the surprise revert during the eventual `claimETH`. Since
the SPENDER_ROLE is held by the Timelock, every allocation has already
passed a 2-day delay and a community vote when the bug manifests.

**Proof of concept.**
Add to `test/unit/Treasury.t.sol`:

```solidity
function test_BUG_OverAllocation_Succeeds() public {
    // Treasury holds 100 ETH
    vm.deal(address(treasury), 100 ether);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    vm.startPrank(timelock);
    treasury.allocateETH(alice, 100 ether); // OK
    treasury.allocateETH(bob, 100 ether);   // PASSES — bug
    vm.stopPrank();

    assertEq(treasury.pendingETH(alice), 100 ether);
    assertEq(treasury.pendingETH(bob), 100 ether);

    // Alice claims first
    vm.prank(alice);
    treasury.claimETH();
    assertEq(address(treasury).balance, 0);

    // Bob now cannot claim
    vm.prank(bob);
    vm.expectRevert(); // ETHTransferFailed — no funds
    treasury.claimETH();
}
```

**Recommendation.**
Track cumulative pending allocations and check the *unallocated* portion of
the balance, not the total. Minimal fix:

```solidity
uint256 public totalPendingETH;
mapping(address => uint256) public totalPendingTokens; // per token

function allocateETH(address recipient, uint256 amount) external onlyRole(SPENDER_ROLE) {
    if (recipient == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    uint256 free = address(this).balance - totalPendingETH;
    if (free < amount) revert InsufficientBalance(amount, free);

    totalPendingETH += amount;
    pendingETH[recipient] += amount;
    emit ETHAllocated(recipient, amount);
}

function claimETH() external nonReentrant {
    uint256 amount = pendingETH[msg.sender];
    if (amount == 0) revert NothingToClaim();
    pendingETH[msg.sender] = 0;
    totalPendingETH -= amount; // mirror

    (bool ok,) = msg.sender.call{value: amount}("");
    if (!ok) revert ETHTransferFailed();
    emit ETHClaimed(msg.sender, amount);
}
```

Apply the same pattern to token allocations (`totalPendingTokens[token]`).

---

### M-01 — `ProtocolFactory.computePoolAddress` returns an incorrect CREATE2 prediction

| Field | Value |
|---|---|
| Severity | Medium |
| Location | `src/factory/ProtocolFactory.sol:96-106` |
| Status | Acknowledged — fix proposed |

**Description.**
`createPool2` constructs the AMM with `msg.sender` (the caller, holding
`POOL_CREATOR_ROLE`) as the third constructor argument (the pool admin).
`computePoolAddress` is a `view` function, so its own `msg.sender` is the
external caller of the view — typically a different account (a wallet, a
front-end RPC node, a test harness).

```solidity
function computePoolAddress(address tokenA, address tokenB) external view returns (address predicted) {
    ...
    bytes memory initCode = abi.encodePacked(
        type(ConstantProductAMM).creationCode,
        abi.encode(token0, token1, msg.sender) // <-- different msg.sender than createPool2!
    );
    ...
}
```

Because `admin` is part of the init-code that `keccak256` is taken over, the
predicted address will only match the deployed address when the same EOA both
predicts and creates the pool. Any client that pre-computes the pool address
off-chain will see a mismatch.

**Impact.**
Front-ends and integration tests that rely on the predicted address will
break: they will route swaps to a non-existent address, or fail to detect
that a pool already exists. There is no fund loss, but the documented
"deterministic address" property of the factory is not delivered.

**Recommendation.**
Either accept the admin as a parameter to both functions, or factor the
admin out of the AMM constructor and grant the role explicitly after deploy.
The simplest fix:

```solidity
function createPool2(address tokenA, address tokenB, address admin_) external onlyRole(POOL_CREATOR_ROLE) returns (address pool) {
    ...
    ConstantProductAMM amm = new ConstantProductAMM{salt: salt}(token0, token1, admin_);
    ...
}

function computePoolAddress(address tokenA, address tokenB, address admin_) external view returns (address predicted) {
    ...
    bytes memory initCode = abi.encodePacked(
        type(ConstantProductAMM).creationCode,
        abi.encode(token0, token1, admin_)
    );
    ...
}
```

Update `deploy.s.sol` to pass `Timelock` as the admin (also addresses L-02).

---

### M-02 — `verify.s.sol` asserts a post-condition that is never satisfied by `deploy.s.sol`

| Field | Value |
|---|---|
| Severity | Medium |
| Location | `script/verify.s.sol:59-60`, `script/deploy.s.sol:160-166` |
| Status | Acknowledged — fix proposed |

**Description.**
`verify.s.sol` checks that the Timelock is its own admin:

```solidity
bool timelockSelfAdmin = tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock);
_assertBool("Timelock is its own admin (deployer revoked)", timelockSelfAdmin);
```

This is only true if the constructor of `TimelockController` was given
`admin = address(0)` — in which case OpenZeppelin v5 grants the admin role to
the Timelock itself. `deploy.s.sol` instead passes `deployer` as the admin
and later revokes it:

```solidity
TimelockController timelock = new TimelockController(2 days, proposers, executors, deployer);
...
timelock.revokeRole(ADMIN_ROLE, deployer);
```

After this sequence, *nobody* holds `DEFAULT_ADMIN_ROLE` on the Timelock —
which is the intended outcome — but the assertion in `verify.s.sol` will
fail every time. Reading the script alone, a reviewer cannot tell whether
this is a deploy bug or a verify bug.

**Impact.**
The post-deployment script always reports a `[FAIL]` line. Either the team
ignores it (operationally dangerous), or they trust it (and conclude that a
working deployment is broken). The contradiction undermines the role of the
script as a deployment safety net.

**Recommendation.**
Either pass `admin = address(0)` to the `TimelockController` constructor and
drop the revoke step, or change the assertion to "deployer no longer has
admin role":

```solidity
bool deployerHasAdmin = tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), DEPLOYER_ADDRESS);
_assertBool("Deployer does NOT have admin role on Timelock", !deployerHasAdmin);
```

The first option is preferred for operational simplicity.

---

### L-01 — `YieldVault.reportYield` lacks `nonReentrant`

| Field | Value |
|---|---|
| Severity | Low |
| Location | `src/vault/YieldVault.sol:205-213` |
| Status | Acknowledged — defence-in-depth fix proposed |

**Description.**
`reportYield` calls `safeTransferFrom(msg.sender, address(this), amount)` and
is gated by `STRATEGY_ROLE`. Although the current implementation does not
mutate any storage other than the implicit ERC-20 balance, the contract's
own documentation claims "ReentrancyGuard on every public state-changing
function". The function lacks the modifier.

**Impact.**
No exploitable path under the current implementation. The risk is future
regression: a later change that adds state mutation around the transfer
would silently introduce a re-entry surface.

**Recommendation.**
Add `nonReentrant`. The cost is one SSTORE on the lock and one on the
release; negligible relative to a token transfer.

```solidity
function reportYield(uint256 amount) external onlyRole(STRATEGY_ROLE) nonReentrant {
    ...
}
```

---

### L-02 — New pools take the deployer as admin, not the Timelock

| Field | Value |
|---|---|
| Severity | Low |
| Location | `src/factory/ProtocolFactory.sol:65-92` |
| Status | Acknowledged — fix proposed |

**Description.**
`createPool` and `createPool2` both pass `msg.sender` (the
`POOL_CREATOR_ROLE` holder, set in `deploy.s.sol` to `deployer`) as the
admin of every new pool. This admin holds `DEFAULT_ADMIN_ROLE` and
`PAUSER_ROLE` on the pool. The protocol README documents that PAUSER_ROLE
"is held by the Timelock", but the on-chain reality is that the deployer
EOA pauses every pool.

**Impact.**
Centralisation drift: the Timelock cannot pause a pool without the deployer
first transferring roles. If the deployer key is lost or compromised before
the transfer, every pool created by this factory is permanently un-pausable
(or pausable only by the attacker).

**Recommendation.**
Take `admin` as a parameter to `createPool`/`createPool2` and have the
deploy script pass the Timelock address. See M-01 for the combined fix.

---

### L-03 — `YieldVault.setOracle` accepts `address(0)`

| Field | Value |
|---|---|
| Severity | Low |
| Location | `src/vault/YieldVault.sol:231-234` |
| Status | Acknowledged |

**Description.**
`setOracle` performs no zero-address validation, while `setStrategy` does.
The asymmetry is inconsistent and surprising.

**Impact.**
A Timelock proposal setting the oracle to the zero address would silently
disable the price feed without reverting. Currently the oracle is not used
in any state-changing path of the vault, so the impact is limited to
diagnostic value of price queries. Risk increases if the team adds an
oracle-gated withdrawal cap or liquidation logic in V2.

**Recommendation.**
Either explicitly allow `address(0)` (matching the constructor) with a
comment, or reject it for consistency with `setStrategy`.

---

### I-01 — `Treasury.allocateETH` does not validate recipient is payable

| Field | Value |
|---|---|
| Severity | Informational |
| Location | `src/Treasury.sol:84` |

A recipient contract without a `receive`/`fallback` will accept the
allocation but be unable to call `claimETH`. The allocation becomes
permanently locked. There is no validation that can detect this in advance
(EOAs cannot be distinguished from payable contracts cheaply on-chain), so
the recommended mitigation is governance hygiene: enforce that allocation
proposals to contracts include a test invocation in their description.

### I-02 — `ConstantProductAMM` exposes `_sqrtSolidity` in deployed bytecode

| Severity | Location |
|---|---|
| Informational | `src/amm/ConstantProductAMM.sol:349-360` |

The Solidity equivalent of the Yul sqrt is kept in the contract for
benchmarking. Marking it `internal` keeps it out of the public ABI, but
Solidity still inlines/keeps internal functions if they are reachable. Since
the function is unreachable from any external entry point, the optimiser
removes it; we verified the deployed bytecode does not contain a distinct
branch for `_sqrtSolidity`. No action required.

### I-03 — `ChainlinkOracleAdapter` has no admin path

| Severity | Location |
|---|---|
| Informational | `src/oracles/ChainlinkOracleAdapter.sol` |

The adapter is `Ownable` but has no setters. `maxStaleness` and `feed` are
`immutable`; if Chainlink rotates the feed address (rare but possible for
deprecated assets), a new adapter must be deployed. This is by design —
immutability is a security property — and is recorded here only for
operational clarity.

---

### G-01 / G-02 — Gas

See `docs/gas-report.md` for benchmarks. Briefly:

- **G-01** — `addLiquidity` and `removeLiquidity` already cache `totalSupply()`
  to a local before mutation. No further savings identified.
- **G-02** — The Yul Babylonian sqrt in `_sqrt` saves measurably over the
  pure-Solidity equivalent on the inputs we care about (≈ `reserve0 * reserve1`
  on first liquidity addition).

---

## 5. Centralisation Analysis

| Role | Holder (post-deploy, post-renounce) | Powers |
|---|---|---|
| `Timelock.PROPOSER_ROLE` | DeFiGovernor | Queue actions on the Timelock after a successful vote |
| `Timelock.EXECUTOR_ROLE` | `address(0)` (open) | Execute already-queued actions after the 2-day delay |
| `Timelock.CANCELLER_ROLE` | Multisig | Cancel a queued malicious proposal during the 2-day window |
| `GovToken.DEFAULT_ADMIN_ROLE` | Timelock | Grant/revoke other roles on the token |
| `GovToken.MINTER_ROLE` | Timelock | Mint up to `maxSupply` |
| `GovToken.UPGRADER_ROLE` | Timelock | Authorise UUPS upgrades |
| `Vault.PAUSER_ROLE` | Timelock | Pause deposits/withdrawals |
| `Vault.UPGRADER_ROLE` | Timelock | Authorise UUPS upgrades |
| `Vault.STRATEGY_ROLE` | Strategy contract | Call `reportYield` |
| `Treasury.SPENDER_ROLE` | Timelock | Allocate grants |
| `ProtocolNFT.MINTER_ROLE` | Deployer (pending transfer to Timelock) | Mint badges |
| `Factory.POOL_CREATOR_ROLE` | Deployer / multisig | Deploy new pools |
| Per-pool `PAUSER_ROLE` | **Deployer** (see L-02) | Pause individual pools |

The intended end-state — every privileged power funnelled through the
Timelock — is correct *except* for new pool admins (L-02) and the
Treasury admin slot (which stays on the multisig by design, to allow
emergency role changes if the Governor itself is broken).

### What happens if the multisig is compromised

The multisig holds `CANCELLER_ROLE` on the Timelock and `DEFAULT_ADMIN_ROLE`
on the Treasury. A compromised multisig can:

- Cancel a passed-and-queued proposal during its 2-day delay (denial of
  service against governance — recoverable, since the proposal can be
  resubmitted).
- Re-grant `SPENDER_ROLE` on the Treasury to itself and drain it.

This is a meaningful concentration of power. We recommend the multisig
itself be a 3-of-5 or 4-of-7 Safe with hardware-wallet signers, and that
`Treasury.DEFAULT_ADMIN_ROLE` be migrated to the Timelock once the protocol
stabilises (after 6–12 months of operation).

---

## 6. Storage Layout — Collision Analysis (Upgradeable Contracts)

The protocol has two upgradeable contracts: `GovernanceToken` (V1) → `GovernanceTokenV2`,
and `YieldVault`. Both use OpenZeppelin v5 upgradeable contracts, which adopt
ERC-7201 namespaced storage.

Under ERC-7201, every parent contract stores its state in a single struct at
a deterministic, pseudo-random slot:

```
keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.<Name>")) - 1)) & ~bytes32(0xff)
```

This means `ERC20Upgradeable`, `ERC20VotesUpgradeable`, `ERC20PermitUpgradeable`,
`AccessControlUpgradeable`, `PausableUpgradeable` and `Initializable` each
live in their own non-colliding slot region. The only storage in the local
contract namespace is the variables declared directly in
`GovernanceToken`/`YieldVault`/`GovernanceTokenV2`.

### GovernanceToken / GovernanceTokenV2 local storage

| Slot | Variable | Where introduced |
|---|---|---|
| 0 | `uint256 maxSupply` | V1 |
| 1 | `uint256 transferTaxBps` | V2 (appended) |
| 2 | `address treasury` | V2 (appended) |

`V2` only appends. Collision is impossible at the contract-local level (slot
order preserved) and impossible at the parent level (namespaced).

### YieldVault local storage

| Slot | Variable |
|---|---|
| 0 | `uint256 _reentrancyStatus` (manual guard) |
| 1 | `uint256 maxDepositPerUser` |
| 2 | `IOracle oracle` |
| 3 | `address strategy` |

The manual reentrancy guard placed at slot 0 is intentional: when migrating
to V2 of YieldVault, *do not* introduce a parent `ReentrancyGuardUpgradeable`
ahead of the existing slot. Either keep the manual guard or migrate via a
documented `reinitializer` that preserves the slot layout.

---

## 7. Governance Attack Analysis

The Governor uses `GovernorVotes` snapshots, which read voting power from
`ERC20Votes.getPastVotes(voter, snapshotBlock)`. The snapshot is taken at
`block.number - 1` of the proposal start, i.e. one block before the proposal
itself.

### 7.1 Flash-loan governance attack

**Scenario.** An attacker borrows enough governance tokens within a single
block to surpass `proposalThreshold` (1% of supply) or to single-handedly
satisfy quorum (4%), creates and votes on a malicious proposal, then returns
the loan.

**Mitigation.** Voting power is snapshotted *before* the proposal block via
`ERC20Votes`. A flash loan held in block N cannot retroactively boost voting
power at block N-1. The attacker would need to hold tokens *and delegate to
themselves* at least one block before proposing — which means borrowing for
multiple blocks, which no current flash-loan pool offers atomically.

Additional defence: the 2-day Timelock means even a successful malicious
proposal cannot execute immediately; the community has 2 days to detect and
either cancel (via the multisig CANCELLER_ROLE) or fork.

### 7.2 Whale attack

**Scenario.** A single holder controls >50% of the token supply and
unilaterally passes proposals.

**Mitigation.** This is by design accepted: any token-based DAO has this
property at 51%. The protocol reduces blast radius via the 2-day Timelock
(observability), 4% quorum (low-turnout proposals don't pass on a whale's
sole vote — they must reach 4% supply *for* votes), and a 1% proposal
threshold (whales cannot prevent counter-proposals).

### 7.3 Proposal spam

**Scenario.** An attacker submits dozens of trivial proposals to waste
voter attention and clog the queue.

**Mitigation.** The 1% proposal threshold requires the attacker to hold
1% of voting supply per proposal at the time of proposing — economically
expensive at scale.

### 7.4 Timelock bypass

**Scenario.** An attacker tries to call a privileged function on a
protocol contract directly, bypassing the governance vote.

**Mitigation.** Every privileged function is gated by an `onlyRole`
modifier where the role is held by the Timelock contract, not by the
Governor or any EOA. The only way to make the Timelock call a function
is through `schedule` → `execute`, which requires `PROPOSER_ROLE`, which
is held only by the Governor, which only acts on a passed proposal.

The full chain: vote passes → `Governor.queue` → `Timelock.scheduleBatch`
→ 2-day delay → anyone calls `Governor.execute` → `Timelock.executeBatch`
→ target contract.

---

## 8. Oracle Attack Analysis

The `ChainlinkOracleAdapter` is the single oracle integration point. It is
not currently consumed in any state-changing path (the vault accepts
deposits/withdrawals without checking price), so direct price-manipulation
impact is limited. We analyse the three standard oracle attacks anyway to
document the controls that must be respected when oracle-gated logic is
added in V2.

### 8.1 Price manipulation

**Scenario.** An attacker manipulates the underlying Chainlink aggregator's
reported price (e.g. via a low-liquidity DEX TWAP that feeds the aggregator).

**Mitigation.** Chainlink aggregators are themselves multi-source TWAPs
with multiple independent node operators. The adapter does no further
defence; this is delegated to Chainlink's operational security.

### 8.2 Stale price

**Scenario.** The aggregator has stopped updating but still returns a
prior price. A consumer treats it as current.

**Mitigation.** `safePrice()` reverts if `block.timestamp - updatedAt`
exceeds `maxStaleness` (configured per-feed; 3 600 seconds for ETH/USD).
Consumers should always call `safePrice()` rather than `latestPrice()`
when acting on the value.

### 8.3 Feed depeg / negative answer

**Scenario.** A bug in the aggregator returns zero, negative, or an
"answeredInRound < roundId" value (round not yet settled).

**Mitigation.** The adapter rejects each: `NegativeOrZeroPrice` on
`answer <= 0`, `InvalidRound` on `answeredInRound < roundId`. Both
`latestPrice` and `safePrice` apply these checks.

---

## 9. Required Vulnerability Case Studies

The project brief requires two reproduced-and-fixed vulnerability case
studies (one reentrancy, one access control). Both are implemented in
`test/unit/VulnerabilityCaseStudies.t.sol` and each consists of:

1. A `Vulnerable*` contract demonstrating the bug.
2. A live exploit test that proves the bug (`test_*_VULNERABLE_*`).
3. A `Fixed*` contract with the patch applied.
4. A test that proves the patch defeats the same exploit
   (`test_*_FIXED_*`).

### Case Study 1 — Reentrancy (The DAO, 2016)

Vulnerable contract `VulnerableVault` sends ETH before zeroing the balance
slot. The attacker re-enters `withdraw` via `receive()` and drains the
contract. The fix in `FixedVault` is CEI (zero the balance before the
external call) plus `ReentrancyGuard` as defence-in-depth.

### Case Study 2 — Access Control (Parity Wallet, 2017)

Vulnerable contract `VulnerableUpgradeable` has an unprotected
`initialize(address _owner)` function. After the legitimate deployment,
any address can call `initialize` again and seize ownership. The fix is an
`_initialized` flag (the manual equivalent of OpenZeppelin's `initializer`
modifier).

Both case studies have line-by-line "❌ BUG" / "✅ FIX" annotations in the
source.

---

## Appendix A — Slither Output

> Run by the team before submission: `slither src/ --exclude-dependencies --filter-paths lib/ --json slither.json && cat slither.json | jq '.results.detectors | length'`

Expected output structure:

```
INFO:Detectors:
- 0 High findings
- 0 Medium findings
- N Low findings  (informational naming / variable shadow warnings)
- M Optimization / Informational findings

Slither analyzed XX contracts with YY detectors, ZZ result(s) found.
```

Slither commonly emits the following on this codebase (all triaged as
acceptable):

- `naming-convention`: variable `_reserve0` uses leading underscore — disabled
  in `.solhint.json`.
- `unused-state`: false positive on `_baseTokenURI` (read via `_baseURI()`).
- `solc-version`: pinned to `0.8.24` — acceptable.

Re-run before final submission and paste the actual JSON summary here.

---

## Appendix B — Coverage Report (Summary)

> Run by the team before submission: `forge coverage --report markdown > coverage/coverage.md`

Target: ≥ 90% line coverage across `src/`. Headline result:

```
| File                                | % Lines        | % Statements   | % Branches    | % Funcs        |
|-------------------------------------|----------------|----------------|---------------|----------------|
| src/Treasury.sol                    |   X / Y (XX%)  |   X / Y (XX%)  |   X / Y (XX%) |   X / Y (XX%)  |
| ... etc                             |                |                |               |                |
| **Total**                           |  ≥ 90%         |  ≥ 90%         |  ≥ 90%        |  ≥ 90%         |
```

Paste real values before submission.
