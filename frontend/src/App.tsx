import { useEffect, useMemo, useState } from 'react';
import { Address, formatEther, parseEther, zeroAddress } from 'viem';
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useReadContract,
  useSwitchChain,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { addresses, targetChain } from './addresses';
import { ammAbi, erc20Abi, governanceTokenAbi, governorAbi, vaultAbi } from './abi';

type Proposal = {
  id: string;
  description: string;
  state: string;
  forVotes: string;
  againstVotes: string;
  abstainVotes: string;
};

const isConfigured = (value: string) => value !== zeroAddress;
const fmt = (value?: bigint) => (value === undefined ? '—' : Number(formatEther(value)).toFixed(4));
const proposalStates = ['Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed'];

function useContractRead(address: Address, abi: any, functionName: string, args: any[] = [], enabled = true) {
  return useReadContract({ address, abi, functionName, args, query: { enabled: enabled && isConfigured(address) } });
}

export function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors, error: connectError } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync, data: hash, error: writeError, isPending } = useWriteContract();
  const { isLoading: txLoading, isSuccess: txSuccess } = useWaitForTransactionReceipt({ hash });

  const [amountIn, setAmountIn] = useState('0.01');
  const [depositAmount, setDepositAmount] = useState('0.01');
  const [proposalId, setProposalId] = useState('');
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [uiError, setUiError] = useState('');

  const tokenAddress = addresses.governanceToken as Address;
  const ammAddress = addresses.amm as Address;
  const vaultAddress = addresses.vault as Address;
  const governorAddress = addresses.governor as Address;

  const wrongNetwork = isConnected && chainId !== targetChain.id;
  const connector = connectors[0];

  const tokenBalance = useContractRead(tokenAddress, governanceTokenAbi, 'balanceOf', [address], Boolean(address));
  const votingPower = useContractRead(tokenAddress, governanceTokenAbi, 'getVotes', [address], Boolean(address));
  const delegate = useContractRead(tokenAddress, governanceTokenAbi, 'delegates', [address], Boolean(address));
  const reserves = useContractRead(ammAddress, ammAbi, 'getReserves');
  const token0 = useContractRead(ammAddress, ammAbi, 'token0');
  const token1 = useContractRead(ammAddress, ammAbi, 'token1');
  const lpSupply = useContractRead(ammAddress, ammAbi, 'totalSupply');
  const vaultAsset = useContractRead(vaultAddress, vaultAbi, 'asset');
  const vaultAssets = useContractRead(vaultAddress, vaultAbi, 'totalAssets');
  const vaultShares = useContractRead(vaultAddress, vaultAbi, 'balanceOf', [address], Boolean(address));

  const reserveValues = reserves.data as [bigint, bigint] | undefined;

  useEffect(() => {
    async function loadSubgraph() {
      if (!addresses.subgraphUrl.includes('api.studio.thegraph.com')) return;
      try {
        const response = await fetch(addresses.subgraphUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            query: `{
              proposals(first: 10, orderBy: createdAtTimestamp, orderDirection: desc) {
                id
                description
                state
                forVotes
                againstVotes
                abstainVotes
              }
            }`,
          }),
        });
        const json = await response.json();
        setProposals(json.data?.proposals ?? []);
      } catch {
        setProposals([]);
      }
    }
    loadSubgraph();
  }, []);

  const status = useMemo(() => {
    if (isPending) return 'Waiting for wallet confirmation...';
    if (txLoading) return 'Transaction submitted. Waiting for confirmation...';
    if (txSuccess) return 'Transaction confirmed.';
    return '';
  }, [isPending, txLoading, txSuccess]);

  async function runTx(action: () => Promise<`0x${string}`>) {
    setUiError('');
    if (!isConnected || !address) return setUiError('Connect wallet first.');
    if (wrongNetwork) return setUiError(`Wrong network. Switch to ${targetChain.name}.`);
    try {
      await action();
    } catch (error: any) {
      const message = error?.shortMessage || error?.message || 'Transaction failed.';
      if (message.toLowerCase().includes('user rejected')) setUiError('Transaction rejected in wallet.');
      else if (message.toLowerCase().includes('insufficient')) setUiError('Insufficient balance or allowance.');
      else setUiError(message);
    }
  }

  async function approveToken(spender: Address, amount: bigint, token: Address) {
    return writeContractAsync({ address: token, abi: erc20Abi, functionName: 'approve', args: [spender, amount] });
  }

  return (
    <main className="page">
      <section className="hero">
        <div>
          <p className="eyebrow">Blockchain Technologies 2 Final Project</p>
          <h1>DeFi Super-App Dashboard</h1>
          <p>AMM, ERC-4626 vault, DAO governance, Chainlink oracle data and The Graph indexing in one dApp.</p>
        </div>
        <div className="walletBox">
          {isConnected ? (
            <>
              <span>{address}</span>
              <button onClick={() => disconnect()}>Disconnect</button>
            </>
          ) : (
            <button onClick={() => connect({ connector })}>Connect MetaMask</button>
          )}
          {wrongNetwork && <button onClick={() => switchChain({ chainId: targetChain.id })}>Switch to {targetChain.name}</button>}
        </div>
      </section>

      {!isConfigured(tokenAddress) && (
        <div className="warning">Update frontend/src/addresses.ts with deployed contract addresses before the demo.</div>
      )}
      {(uiError || writeError || connectError) && <div className="error">{uiError || writeError?.message || connectError?.message}</div>}
      {status && <div className="success">{status}</div>}

      <section className="grid">
        <article className="card">
          <h2>Wallet & Governance Token</h2>
          <div className="row"><span>Token balance</span><b>{fmt(tokenBalance.data as bigint)}</b></div>
          <div className="row"><span>Voting power</span><b>{fmt(votingPower.data as bigint)}</b></div>
          <div className="row"><span>Delegate</span><b className="addressText">{(delegate.data as string) || '—'}</b></div>
          <button onClick={() => runTx(() => writeContractAsync({ address: tokenAddress, abi: governanceTokenAbi, functionName: 'delegate', args: [address!] }))}>
            Delegate to myself
          </button>
        </article>

        <article className="card">
          <h2>AMM Pool</h2>
          <div className="row"><span>Token0</span><b className="addressText">{(token0.data as string) || '—'}</b></div>
          <div className="row"><span>Token1</span><b className="addressText">{(token1.data as string) || '—'}</b></div>
          <div className="row"><span>Reserve0</span><b>{fmt(reserveValues?.[0])}</b></div>
          <div className="row"><span>Reserve1</span><b>{fmt(reserveValues?.[1])}</b></div>
          <div className="row"><span>LP supply</span><b>{fmt(lpSupply.data as bigint)}</b></div>
          <input value={amountIn} onChange={(e) => setAmountIn(e.target.value)} placeholder="Token0 amount" />
          <button onClick={() => runTx(async () => approveToken(ammAddress, parseEther(amountIn), (token0.data as Address) || tokenAddress))}>
            Approve token0
          </button>
          <button onClick={() => runTx(() => writeContractAsync({ address: ammAddress, abi: ammAbi, functionName: 'swap', args: [(token0.data as Address) || tokenAddress, parseEther(amountIn), 0n, address!] }))}>
            Swap token0 to token1
          </button>
        </article>

        <article className="card">
          <h2>ERC-4626 Vault</h2>
          <div className="row"><span>Vault asset</span><b className="addressText">{(vaultAsset.data as string) || '—'}</b></div>
          <div className="row"><span>Total assets</span><b>{fmt(vaultAssets.data as bigint)}</b></div>
          <div className="row"><span>My shares</span><b>{fmt(vaultShares.data as bigint)}</b></div>
          <input value={depositAmount} onChange={(e) => setDepositAmount(e.target.value)} placeholder="Deposit amount" />
          <button onClick={() => runTx(async () => approveToken(vaultAddress, parseEther(depositAmount), (vaultAsset.data as Address) || tokenAddress))}>
            Approve vault asset
          </button>
          <button onClick={() => runTx(() => writeContractAsync({ address: vaultAddress, abi: vaultAbi, functionName: 'deposit', args: [parseEther(depositAmount), address!] }))}>
            Deposit to vault
          </button>
        </article>

        <article className="card">
          <h2>DAO Vote</h2>
          <input value={proposalId} onChange={(e) => setProposalId(e.target.value)} placeholder="Proposal ID" />
          <button onClick={() => runTx(() => writeContractAsync({ address: governorAddress, abi: governorAbi, functionName: 'castVote', args: [BigInt(proposalId), 1] }))}>
            Vote For
          </button>
          <button onClick={() => runTx(() => writeContractAsync({ address: governorAddress, abi: governorAbi, functionName: 'castVote', args: [BigInt(proposalId), 0] }))}>
            Vote Against
          </button>
        </article>
      </section>

      <section className="card full">
        <h2>Active Proposals from The Graph</h2>
        {proposals.length === 0 ? (
          <p>No indexed proposals loaded yet. Deploy the subgraph and update subgraphUrl in addresses.ts.</p>
        ) : (
          <div className="table">
            {proposals.map((p) => (
              <div className="proposal" key={p.id}>
                <b>{p.description}</b>
                <span>ID: {p.id}</span>
                <span>State: {proposalStates[Number(p.state)] || p.state}</span>
                <span>For: {p.forVotes} · Against: {p.againstVotes} · Abstain: {p.abstainVotes}</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}
