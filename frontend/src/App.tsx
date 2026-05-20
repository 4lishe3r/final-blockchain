import { useEffect, useMemo, useState } from "react";
import { Address, formatEther, parseEther, zeroAddress } from "viem";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useReadContract,
  useSwitchChain,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { addresses, targetChain } from "./addresses";
import {
  ammAbi,
  erc20Abi,
  governanceTokenAbi,
  governorAbi,
  vaultAbi,
} from "./abi";

type Proposal = {
  id: string;
  description: string;
  state: string;
  forVotes: string;
  againstVotes: string;
  abstainVotes: string;
};

const isConfigured = (value: string) => value !== zeroAddress;
const fmt = (value?: bigint) =>
  value === undefined ? "—" : Number(formatEther(value)).toFixed(4);
const proposalStates = [
  "Pending",
  "Active",
  "Canceled",
  "Defeated",
  "Succeeded",
  "Queued",
  "Expired",
  "Executed",
];

function useContractRead(
  address: Address,
  abi: any,
  functionName: string,
  args: any[] = [],
  enabled = true,
) {
  return useReadContract({
    address,
    abi,
    functionName,
    args,
    query: { enabled: enabled && isConfigured(address) },
  });
}

// Safe BigInt parse — returns undefined if invalid
function safeBigInt(val: string): bigint | undefined {
  try {
    if (!val.trim()) return undefined;
    return BigInt(val.trim());
  } catch {
    return undefined;
  }
}

export function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors, error: connectError } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const {
    writeContractAsync,
    data: hash,
    error: writeError,
    isPending,
  } = useWriteContract();
  const { isLoading: txLoading, isSuccess: txSuccess } =
    useWaitForTransactionReceipt({ hash });

  const [amountIn, setAmountIn] = useState("1");
  const [liqAmount0, setLiqAmount0] = useState("100");
  const [liqAmount1, setLiqAmount1] = useState("100");
  const [depositAmount, setDepositAmount] = useState("1");
  const [proposalId, setProposalId] = useState("");
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [uiError, setUiError] = useState("");

  const tokenAddress = addresses.governanceToken as Address;
  const ammAddress = addresses.amm as Address;
  const vaultAddress = addresses.vault as Address;
  const governorAddress = addresses.governor as Address;

  const wrongNetwork = isConnected && chainId !== targetChain.id;
  const connector = connectors[0];

  // ── Contract reads ──────────────────────────────────────
  const tokenBalance = useContractRead(
    tokenAddress,
    governanceTokenAbi,
    "balanceOf",
    [address],
    Boolean(address),
  );
  const votingPower = useContractRead(
    tokenAddress,
    governanceTokenAbi,
    "getVotes",
    [address],
    Boolean(address),
  );
  const delegate = useContractRead(
    tokenAddress,
    governanceTokenAbi,
    "delegates",
    [address],
    Boolean(address),
  );

  const reserves = useContractRead(ammAddress, ammAbi, "getReserves");
  const token0 = useContractRead(ammAddress, ammAbi, "token0");
  const token1 = useContractRead(ammAddress, ammAbi, "token1");
  const lpSupply = useContractRead(ammAddress, ammAbi, "totalSupply");

  const vaultAsset = useContractRead(vaultAddress, vaultAbi, "asset");
  const vaultAssets = useContractRead(vaultAddress, vaultAbi, "totalAssets");
  const vaultShares = useContractRead(
    vaultAddress,
    vaultAbi,
    "balanceOf",
    [address],
    Boolean(address),
  );

  const reserveValues = reserves.data as [bigint, bigint] | undefined;
  const poolEmpty =
    !reserveValues || (reserveValues[0] === 0n && reserveValues[1] === 0n);

  // Resolved addresses (with fallback to governance token while loading)
  const token0Address = (token0.data as Address | undefined) ?? tokenAddress;
  const token1Address = (token1.data as Address | undefined) ?? tokenAddress;
  const assetAddress = (vaultAsset.data as Address | undefined) ?? tokenAddress;

  // Token1 balance (for AMM liquidity check)
  const token1Balance = useContractRead(
    token1Address,
    erc20Abi,
    "balanceOf",
    [address],
    Boolean(address) && token1Address !== tokenAddress,
  );

  useEffect(() => {
    async function loadSubgraph() {
      if (!addresses.subgraphUrl.includes("api.studio.thegraph.com")) return;
      try {
        const res = await fetch(addresses.subgraphUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `{ proposals(first:10, orderBy:createdAtTimestamp, orderDirection:desc) {
              id description state forVotes againstVotes abstainVotes } }`,
          }),
        });
        const json = await res.json();
        setProposals(json.data?.proposals ?? []);
      } catch {
        setProposals([]);
      }
    }
    loadSubgraph();
  }, []);

  const status = useMemo(() => {
    if (isPending) return "Waiting for wallet confirmation...";
    if (txLoading) return "Transaction submitted. Waiting for confirmation...";
    if (txSuccess) return "Transaction confirmed! ✓";
    return "";
  }, [isPending, txLoading, txSuccess]);

  async function runTx(action: () => Promise<`0x${string}`>) {
    setUiError("");
    if (!isConnected || !address) return setUiError("Connect wallet first.");
    if (wrongNetwork)
      return setUiError(`Wrong network. Switch to ${targetChain.name}.`);
    try {
      await action();
    } catch (error: any) {
      const msg =
        error?.shortMessage || error?.message || "Transaction failed.";
      if (msg.toLowerCase().includes("user rejected"))
        setUiError("Transaction rejected in wallet.");
      else if (msg.toLowerCase().includes("insufficient"))
        setUiError("Insufficient balance or allowance. Did you approve first?");
      else if (msg.toLowerCase().includes("liquidity"))
        setUiError("Pool has no liquidity. Add liquidity before swapping.");
      else if (msg.toLowerCase().includes("invalid token"))
        setUiError("Pool token mismatch. Check pool configuration.");
      else setUiError(msg.slice(0, 200));
    }
  }

  function approve(spender: Address, amount: bigint, token: Address) {
    return writeContractAsync({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [spender, amount],
      gas: 100_000n,
    });
  }

  // ── Proposal ID validation ───────────────────────────────
  const proposalIdBig = safeBigInt(proposalId);
  const proposalIdValid = proposalIdBig !== undefined;

  return (
    <main className="page">
      {/* ── Hero ── */}
      <section className="hero">
        <div>
          <p className="eyebrow">Blockchain Technologies 2 Final Project</p>
          <h1>DeFi Super-App Dashboard</h1>
          <p>
            AMM · ERC-4626 vault · DAO governance · Chainlink oracle · The Graph
            — Base Sepolia
          </p>
        </div>
        <div className="walletBox">
          {isConnected ? (
            <>
              <span>{address}</span>
              <button onClick={() => disconnect()}>Disconnect</button>
            </>
          ) : (
            <button onClick={() => connect({ connector })}>
              Connect MetaMask
            </button>
          )}
          {wrongNetwork && (
            <button onClick={() => switchChain({ chainId: targetChain.id })}>
              Switch to {targetChain.name}
            </button>
          )}
        </div>
      </section>

      {/* ── Banners ── */}
      {!isConfigured(tokenAddress) && (
        <div className="warning">
          Update src/addresses.ts with deployed contract addresses.
        </div>
      )}
      {(uiError || connectError) && (
        <div className="error">{uiError || connectError?.message}</div>
      )}
      {writeError && !uiError && (
        <div className="error">{writeError.message.slice(0, 300)}</div>
      )}
      {status && <div className="success">{status}</div>}

      <section className="grid">
        {/* ── Wallet & Governance Token ── */}
        <article className="card">
          <h2>Wallet &amp; Governance Token</h2>
          <div className="row">
            <span>Token balance</span>
            <b>{fmt(tokenBalance.data as bigint)}</b>
          </div>
          <div className="row">
            <span>Voting power</span>
            <b>{fmt(votingPower.data as bigint)}</b>
          </div>
          <div className="row">
            <span>Delegate</span>
            <b className="addressText">{(delegate.data as string) || "—"}</b>
          </div>
          <button
            onClick={() =>
              runTx(() =>
                writeContractAsync({
                  address: tokenAddress,
                  abi: governanceTokenAbi,
                  functionName: "delegate",
                  args: [address!],
                  gas: 150_000n,
                }),
              )
            }
          >
            Delegate to myself
          </button>
        </article>

        {/* ── AMM Pool ── */}
        <article className="card">
          <h2>AMM Pool</h2>
          <div className="row">
            <span>Token0</span>
            <b className="addressText">{token0Address}</b>
          </div>
          <div className="row">
            <span>Token1</span>
            <b className="addressText">{token1Address}</b>
          </div>
          <div className="row">
            <span>Reserve0</span>
            <b>{fmt(reserveValues?.[0])}</b>
          </div>
          <div className="row">
            <span>Reserve1</span>
            <b>{fmt(reserveValues?.[1])}</b>
          </div>
          <div className="row">
            <span>LP supply</span>
            <b>{fmt(lpSupply.data as bigint)}</b>
          </div>
          {isConnected && (
            <div className="row">
              <span>Your token1 balance</span>
              <b>{fmt(token1Balance.data as bigint)}</b>
            </div>
          )}

          {poolEmpty && (
            <div
              className="warning"
              style={{ fontSize: "12px", padding: "10px 14px" }}
            >
              Pool has no liquidity — add liquidity first before swapping.
            </div>
          )}

          {/* Add Liquidity */}
          <p
            style={{
              fontSize: "11px",
              color: "var(--txt-2)",
              marginTop: "4px",
            }}
          >
            ① Add liquidity (approve both tokens first)
          </p>
          <input
            value={liqAmount0}
            onChange={(e) => setLiqAmount0(e.target.value)}
            placeholder="Token0 amount"
          />
          <input
            value={liqAmount1}
            onChange={(e) => setLiqAmount1(e.target.value)}
            placeholder="Token1 amount"
          />
          <button
            onClick={() =>
              runTx(() =>
                approve(ammAddress, parseEther(liqAmount0), token0Address),
              )
            }
          >
            Approve token0
          </button>
          <button
            onClick={() =>
              runTx(() =>
                approve(ammAddress, parseEther(liqAmount1), token1Address),
              )
            }
          >
            Approve token1
          </button>
          <button
            onClick={() =>
              runTx(() =>
                writeContractAsync({
                  address: ammAddress,
                  abi: ammAbi,
                  functionName: "addLiquidity",
                  args: [
                    parseEther(liqAmount0),
                    parseEther(liqAmount1),
                    0n,
                    0n,
                    address!,
                  ],
                  gas: 400_000n,
                }),
              )
            }
          >
            Add Liquidity
          </button>

          <hr
            style={{
              border: "none",
              borderTop: "1px solid var(--border)",
              margin: "2px 0",
            }}
          />

          {/* Swap */}
          <p style={{ fontSize: "11px", color: "var(--txt-2)", margin: "0" }}>
            ② Swap (approve token0, then swap)
          </p>
          <input
            value={amountIn}
            onChange={(e) => setAmountIn(e.target.value)}
            placeholder="Token0 amount to swap"
          />
          <button
            onClick={() =>
              runTx(() =>
                approve(ammAddress, parseEther(amountIn), token0Address),
              )
            }
          >
            Approve token0
          </button>
          <button
            disabled={poolEmpty}
            title={poolEmpty ? "Add liquidity first" : ""}
            onClick={() =>
              runTx(() =>
                writeContractAsync({
                  address: ammAddress,
                  abi: ammAbi,
                  functionName: "swap",
                  args: [token0Address, parseEther(amountIn), 0n, address!],
                  gas: 300_000n,
                }),
              )
            }
          >
            {poolEmpty ? "Swap (no liquidity)" : "Swap token0 → token1"}
          </button>
        </article>

        {/* ── ERC-4626 Vault ── */}
        <article className="card">
          <h2>ERC-4626 Vault</h2>
          <div className="row">
            <span>Vault asset</span>
            <b className="addressText">{assetAddress}</b>
          </div>
          <div className="row">
            <span>Total assets</span>
            <b>{fmt(vaultAssets.data as bigint)}</b>
          </div>
          <div className="row">
            <span>My shares</span>
            <b>{fmt(vaultShares.data as bigint)}</b>
          </div>
          <input
            value={depositAmount}
            onChange={(e) => setDepositAmount(e.target.value)}
            placeholder="Amount to deposit"
          />
          <button
            onClick={() =>
              runTx(() =>
                approve(vaultAddress, parseEther(depositAmount), assetAddress),
              )
            }
          >
            Approve vault asset
          </button>
          <button
            onClick={() =>
              runTx(() =>
                writeContractAsync({
                  address: vaultAddress,
                  abi: vaultAbi,
                  functionName: "deposit",
                  args: [parseEther(depositAmount), address!],
                  gas: 200_000n,
                }),
              )
            }
          >
            Deposit to vault
          </button>
        </article>

        {/* ── DAO Vote ── */}
        <article className="card">
          <h2>DAO Vote</h2>
          <p style={{ fontSize: "12px", color: "var(--txt-2)" }}>
            Delegate voting power first, then enter a proposal ID to vote.
          </p>
          <input
            value={proposalId}
            onChange={(e) => setProposalId(e.target.value)}
            placeholder="Proposal ID (number)"
            style={
              proposalId && !proposalIdValid
                ? { borderColor: "var(--red)" }
                : {}
            }
          />
          {proposalId && !proposalIdValid && (
            <p style={{ fontSize: "11px", color: "var(--red)", margin: "0" }}>
              Invalid proposal ID — must be a number
            </p>
          )}
          <button
            disabled={!proposalIdValid}
            onClick={() => {
              if (!proposalIdBig)
                return setUiError("Enter a valid proposal ID.");
              runTx(() =>
                writeContractAsync({
                  address: governorAddress,
                  abi: governorAbi,
                  functionName: "castVote",
                  args: [proposalIdBig, 1],
                  gas: 150_000n,
                }),
              );
            }}
          >
            Vote For
          </button>
          <button
            disabled={!proposalIdValid}
            onClick={() => {
              if (!proposalIdBig)
                return setUiError("Enter a valid proposal ID.");
              runTx(() =>
                writeContractAsync({
                  address: governorAddress,
                  abi: governorAbi,
                  functionName: "castVote",
                  args: [proposalIdBig, 0],
                  gas: 150_000n,
                }),
              );
            }}
          >
            Vote Against
          </button>
        </article>
      </section>

      {/* ── Proposals ── */}
      <section className="card full">
        <h2>Active Proposals from The Graph</h2>
        {proposals.length === 0 ? (
          <p>
            No indexed proposals yet. Deploy the subgraph and set subgraphUrl in
            addresses.ts.
          </p>
        ) : (
          <div className="table">
            {proposals.map((p) => (
              <div className="proposal" key={p.id}>
                <b>{p.description}</b>
                <span>ID: {p.id}</span>
                <span>State: {proposalStates[Number(p.state)] ?? p.state}</span>
                <span>
                  For: {p.forVotes} · Against: {p.againstVotes} · Abstain:{" "}
                  {p.abstainVotes}
                </span>
              </div>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}
