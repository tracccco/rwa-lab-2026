# Lab 2 — How to Tokenize an RWA (Tokenized T-Bills)

In Lab 1 the collateral was **itself a token**. That is why the whole thing could prove itself:
`totalCollateral() == totalSupply()` was a statement the chain could check on its own, and nothing
outside the code had to be trusted.

This lab removes that assumption. The asset is now a **short-dated US Treasury bill**, sitting at a
custodian. What is on-chain is not the asset — it is a **claim on the asset**. The subject of this
lab is the machinery that connects the two:

> **The bridge.** Custody, attestation, physical redemption, and permissioning — the four things
> that have to exist before an off-chain asset can become an on-chain token, and the four places
> where such a token breaks.

Every exercise below is built around a plank of the bridge. If you find yourself only reading NAV
numbers and yields, you have drifted back into Lab 1.

---

## 1. Setup

Pick the track that matches your machine. **Everything after this section is identical for everyone.**

| You are on | Track |
|---|---|
| macOS / Linux | **A** — install Foundry locally |
| Windows | **B** — Codespaces, nothing installed on your machine |

> `lib/` (`forge-std`, `openzeppelin-contracts`) **ships inside this repository**.
> Neither track needs `git clone --recursive`, and neither needs `make setup` —
> a plain clone compiles as-is.

### Track A — macOS / Linux

**Step 1. Install Foundry**

First check whether you already have it:

```bash
forge --version
```

If that prints a version, skip to Step 2. Otherwise install it with the script in this repo (**do not use `foundryup`**):

```bash
bash scripts/install-foundry-cn.sh
```

The script detects your platform, tries GitHub directly, and falls back to the `gh-proxy.com`
mirror. Add the line it prints to `~/.zshrc` or `~/.bashrc`, then reopen your terminal:

```bash
export PATH="$PATH:$HOME/.foundry/bin"
```

> ⚠️ **Why not `foundryup`**: its download goes through GitHub's CDN, which times out reliably from
> mainland China. The mirror does not.

**Step 2. Get the code**

```bash
git clone https://github.com/hgwoops/rwa-lab-2026 && cd rwa-lab-2026
```

Then go to **Verify** below.

### Track B — Windows (Codespaces)

Foundry has **no native Windows binary**, so the straightforward path is to run the lab on
GitHub's servers from your browser. Nothing is installed locally, which also makes it the only
option on locked-down corporate machines.

1. Open <https://github.com/hgwoops/rwa-lab-2026>
2. Green **`Code`** button → **`Codespaces`** tab → **`Create codespace on main`**
3. **The first launch takes 2–5 minutes**: it builds the environment from `.devcontainer/`,
   then automatically runs `make doctor` — you should see a row of `✓` in the terminal
4. In the terminal at the bottom, run:

```bash
make test
```

`7 passed; 0 failed` means you are set.

The free tier is 120 core-hours/month — far more than this lab needs. **Stop it when you are done**
at <https://github.com/codespaces>; a running Codespace keeps burning quota.

### Verify (both tracks)

```bash
make doctor
```

In about 30 seconds this checks the toolchain, the dependencies, and runs the core tests. Anything
marked `✗` comes with the exact command to fix it. All green means you can start; if you cannot fix
it, paste the whole `make doctor` output to the TA.

> New to Foundry? Read **`FOUNDRY-101.md`** before you touch the tests: how a test is shaped, the
> cheatcodes you will need, the command band, and where to look when it breaks.

---

## 2. Quick start

```bash
make doctor        # environment check — all green before you go on
make test          # the checkpoint: core tests, should be all green (7 passed)
make exercise      # Ex2–Ex6 acceptance tests; all green (19 passed)
make anvil         # terminal A: start a local chain
make deploy-anvil  # terminal B: deploy to it
```

Deployment prints the admin plus seven contracts. Export the ones you need (`$USDC`, `$COMPLIANCE`,
`$FEED`, `$TBILL`, `$CUSTODIAN`, `$VAULT`, `$QUEUE`); the run-it-by-hand commands are in
`EXERCISES.md` Ex1.

**Your task list is `EXERCISES.md`** — every exercise's goal, acceptance command, and where to look.

---

## 3. What the contracts do

The bridge has four planks. Each one is a contract or a role in this repo.

| File | Role | Plank |
|---|---|---|
| `src/MockUSDC.sol` | **Cash.** 6 decimals, with a test faucet. The thing that flows across the bridge | — |
| `src/ComplianceRegistry.sol` | **The guest list.** `setWhitelisted()` / `isWhitelisted()`, gated by `COMPLIANCE_ROLE` | (d) admission |
| `src/TBillToken.sol` | **The claim.** ERC-20, **18 decimals**, mint/burn gated, and every balance change must pass both endpoints' whitelist | (d) admission |
| `src/TBillVault.sol` | **The on-ramp and the books.** `subscribe()` prices shares at the feed's NAV; `attest()` is the role-gated update path through the vault | (b) attestation |
| `src/exercises/MockTBillCustodian.sol` | **The custodian / SPV.** Answers exactly one question: `realHoldings()` — how much is actually there? | (a) custody |
| `src/exercises/MockPriceFeed.sol` | **The NAV oracle.** 8 decimals; `1.00e8` is par | (b) attestation |
| `src/exercises/RedemptionQueue.sol` | **T+1.** Shares in, a queue ticket out, cash later (Ex5) | (c) redemption |

### The two invariants you will defend (Ex6)

```
escrow conservation   tBill.balanceOf(queue) == queue.pendingShares()
settlement solvency   usdc.balanceOf(queue) >= queue.totalClaimable()
```

The first says the queue never loses a share and never invents one. The second says it never owes
settled cash it does not hold. Neither is something the chain can verify against the off-chain
asset — that is the point. The three decimal scales (18 + 8 − 6) are in `EXERCISES.md` Ex5; the
third relation that *looks* like an invariant and is not is Ex6.

`script/Deploy.s.sol` wires the whole system together, and the wiring at the bottom **is** part of
the lesson: the vault needs `MINTER_ROLE`; the queue needs `MINTER_ROLE` **and** must be
whitelisted (burning its escrowed shares is a balance change); the vault must be told where the
queue is; the custodian must recognize the vault. Skip any one and the loop reverts.

---

## Architecture — the bridge

```
                         ┌────────────────────────────────────────────────────┐
                         │                   THE BRIDGE                       │
                         │  four planks: custody (a), attestation (b),        │
                         │  redemption (c), admission (d)                     │
                         └────────────────────────────────────────────────────┘

     INVESTORS
        │  USDC (cash, 6dp)
        ▼
   ┌──────────────┐   (b) ATTESTATION — the chain's only window on the asset.
   │  TBillVault  │   MockPriceFeed supplies the NAV (8dp). The reporter
   │ the on-ramp  │◄── uses vault.attest() (REPORTER_ROLE); subscribe and
   │ & the books  │   enqueue use the NAV for pricing. The two invariants
   │              │   check escrowed shares and settled cash, not NAV.
   │  subscribe(): cash in, shares out at today's NAV
   │  invest(): cash out to the custodian's books
   │  depositReserves(): T+1 proceeds back
   │  releaseReserves(): cash out, queue only
   └──────┬───────┘
          │ shares (mint / burn, 18dp)
          ▼
   ┌──────────────┐   (d) ADMISSION — ComplianceRegistry whitelist; TBillToken.
   │  TBillToken  │   _update() checks BOTH endpoints of every balance change:
   │  the claim   │   mint, burn and transfer alike. No KYC, no shares — even
   │              │   if you pay; and a freeze blocks a burn too.
   └──────┬───────┘
          │ shares escrowed (enqueue)
          ▼
   ┌──────────────┐   (c) REDEMPTION — T+1 FIFO. enqueue locks the payout at
   │RedemptionQueue│  today's NAV; settle honours the head ticket in full or
   │   the exit    │  not at all, never out of order; claim pays cash out
   └──────┬───────┘  (checks-effects-interactions).
          │ USDC (cash) on claim
          ▼
      INVESTORS

   (a) CUSTODY — off-chain: the US Treasury Bills themselves sit at the SPV's
   custodian. On-chain there is only MockTBillCustodian.realHoldings(), a
   number a permissioned address types in. The asset never crosses the
   bridge; only claims on it do.

   cash  (USDC, 6dp)   moves on subscribe, invest, depositReserves,
                      settle/releaseReserves, and claim
   shares (tBILL, 18dp) cross on subscribe, enqueue, and settle
```

### One subscription and redemption, state by state

At NAV 1.00, suppose the vault and queue start empty and a whitelisted investor subscribes
1,000 USDC, then redeems one of the 1,000 shares. Amounts below are whole USDC or tBILL,
before applying their 6- and 18-decimal integer scales.

| Call | Cash movement | Share ledger and supply | Queue record |
|---|---|---|---|
| `subscribe(1000)` | Investor −1,000 USDC; vault +1,000 | Investor +1,000 tBILL; `totalSupply` +1,000 | No ticket |
| `enqueue(1)` | None | Investor −1 tBILL; queue +1; supply unchanged | Ticket locks 1 USDC; `pendingShares` 1, `pendingAssets` 1 |
| `settle(1)` | Vault −1 USDC; queue +1 | Queue burns 1 tBILL; supply −1 | Head advances; both pending totals return to 0; investor `claimable` and `totalClaimable` become 1 |
| `claim()` | Queue −1 USDC; investor +1 | No share change | Investor `claimable` and `totalClaimable` return to 0 |

The ERC-20 balances and `totalSupply` are this lab's share ownership record. The
`ComplianceRegistry` checks whether addresses may hold shares; its whitelist is a precondition
for these calls and does not change during them. It is not a transfer-agent register of
individual legal identities.

This example settles from the vault's existing cash buffer. If `invest()` has moved that cash
to the mock custodian, the vault cannot settle until it has USDC again. A reported
`recordSale()` changes the custodian's number but transfers no cash; an operator must separately
use `depositReserves()` after receiving sale proceeds. If those proceeds are delayed, the
ticket stays pending in FIFO order and the investor cannot call `claim()` yet. The Sepolia
smoke test below demonstrates the contract path, not an actual off-chain T-Bill sale.

The mock feed has a separate security limit: anyone can call `MockPriceFeed.setPrice()`
directly, even though `vault.attest()` requires `REPORTER_ROLE`. Its `updatedAt` is also the
current block time on every read, not the time of the last price update. A production feed
would need restricted writes and a stored update timestamp.

---

## Deployment (Sepolia)

All seven contracts deployed to Sepolia, **verified on Etherscan** (and Sourcify), wired, and
exercised end-to-end. Deployer / admin is a
throwaway test wallet `0x9778ff76D21E7234264CD3062d93f4DD6c7B6596`; its key lives only in `.env`
and never leaves this machine.

| # | Contract | Address | Etherscan |
|---|---|---|---|
| 1 | `MockUSDC` | `0xcf637a2F099dB884fD53187E15f30C1C45863a04` | [link](https://sepolia.etherscan.io/address/0xcf637a2F099dB884fD53187E15f30C1C45863a04) |
| 2 | `ComplianceRegistry` | `0x31981F97f542337b81f811eC1Fe3d8e7E55B6084` | [link](https://sepolia.etherscan.io/address/0x31981F97f542337b81f811eC1Fe3d8e7E55B6084) |
| 3 | `MockPriceFeed` | `0x5B9cF5eE4A4420C8Ce5757740AB848Dfc6CdB34C` | [link](https://sepolia.etherscan.io/address/0x5B9cF5eE4A4420C8Ce5757740AB848Dfc6CdB34C) |
| 4 | `TBillToken` | `0x5Dcfed27649a45b23764d7000ea292D40D598E85` | [link](https://sepolia.etherscan.io/address/0x5Dcfed27649a45b23764d7000ea292D40D598E85) |
| 5 | `MockTBillCustodian` | `0x15ee1C77425D31727182aF39cC29750E5a061F5c` | [link](https://sepolia.etherscan.io/address/0x15ee1C77425D31727182aF39cC29750E5a061F5c) |
| 6 | `TBillVault` | `0xD24C7b1e97ceA9BBb075F7b13397a665eeE756a1` | [link](https://sepolia.etherscan.io/address/0xD24C7b1e97ceA9BBb075F7b13397a665eeE756a1) |
| 7 | `RedemptionQueue` | `0xD391de8d69da1E8750aDb11226b36F68a7cEF6Ff` | [link](https://sepolia.etherscan.io/address/0xD391de8d69da1E8750aDb11226b36F68a7cEF6Ff) |

Wiring, all verified on-chain: `TBillToken` granted `MINTER_ROLE` to the vault and the queue;
the custodian granted `CUSTODIAN_ROLE` to the vault; `vault.setQueue(queue)`; the admin and the
queue whitelisted in the compliance registry.

Smoke test (live on Sepolia — subscribe → enqueue → settle → claim):

1. `subscribe` 1,000 USDC at NAV 1.00 → 1,000 tBILL minted to the admin
2. `enqueue` 1 tBILL → 1.00 USDC locked at today's NAV — [tx](https://sepolia.etherscan.io/tx/0x5927564a617959cc3b053bc8614bfb5de57b63560187c1b26225eb3ca9156971)
3. `settle` → the queue burns the escrowed share and makes 1.00 USDC claimable — [tx](https://sepolia.etherscan.io/tx/0x6b2ed8bf9a8e179e247e5c07af9db1f5620cde618bb412dc282ba6bf6ce4e085)
4. `claim` → 1.00 USDC paid out — [tx](https://sepolia.etherscan.io/tx/0x6bcf3e08ef6a42d1f23fd9ef61861c4a1eb39e88d4c0d13bf6230676f30d12e1)

Both invariants hold at every step (`tBill.balanceOf(queue) == pendingShares()`,
`usdc.balanceOf(queue) >= totalClaimable()`), ending at 0 / 0 after the claim.

---

## 4. Homework

**Tier 1 (required)** — the exercises **Ex0–Ex6** in `EXERCISES.md`, and the discussion questions in
`STUDENT-QUESTIONS.md`. Ex1 is a warm-up and is **not graded**. A local Anvil is enough: Tier 1 does
**not** require a testnet. The acceptance command for every exercise is `make exercise` — green when
you are done.

**Tier 2 (bonus)** — deploy to Sepolia and verify the source on Etherscan; put **all seven**
addresses and their Etherscan links in your `README.md`, under a `## Deployment (Sepolia)` heading.
The deploy prints them in this order: `MockUSDC`, `ComplianceRegistry`, `MockPriceFeed`,
`TBillToken`, `MockTBillCustodian`, `TBillVault`, `RedemptionQueue`. The commands are Lab 1's
`README.md` §4, under "Tier 2 (bonus)" — the flow is identical.

**Tier 3 (challenge, optional)** — **Ex7**: `make challenge` (`test/challenges/FalseNav.t.sol`). The
reporter's number is the chain's only window onto the asset; show what happens when it lies, and
name the mechanism that would have caught it.

---

## 5. Common problems

**`Ownable` / role errors**
OpenZeppelin v5 has breaking changes, so v4 tutorials from the web will fail. This repo pins
`v5.0.2` — do not upgrade it.

**`subscribe` reverts with `NotWhitelisted`**
The token is permissioned. Whitelist the recipient first — and remember the **queue** must be
whitelisted too, because burning its escrowed shares counts as a balance change.

**`invest` reverts with `AccessControlUnauthorizedAccount`**
The custodian does not recognize the vault. `script/Deploy.s.sol` grants
`custodian.CUSTODIAN_ROLE()` to the vault — if you wired things by hand, you skipped it.

**Amounts are off by an order of magnitude**
`1000e6 = 1_000_000_000` in smallest units (USDC). Shares are 18 decimals and the NAV is 8 — the
conversion is `shares * nav / 1e20`. Do not compute 18-decimal to 18-decimal.

**Addresses change after restarting Anvil**
Anvil starts from a clean state every time, so you must redeploy.

**`make exercise` hangs, or an invariant failure looks strange**
Foundry replays a cached counterexample from `cache/invariant/` on the next run.
To search for a fresh one, `rm -rf cache/invariant` first.

---

## 6. Submission

Submission follows Lab 1: **one zip of the project** on Moodle, built from the project root.

```bash
rm -f .env        # a private key anywhere in the zip scores zero
zip -r submission.zip . -x '.git/*' 'out/*' 'cache/*' 'broadcast/*' '.env' '.DS_Store'
```

**Keep `lib/` inside it** — those vendored dependencies are what let the grader run `make test`
offline. Drop them and the grader has to fetch from GitHub.

What the zip must contain:

1. The code, with `make exercise` all green (the grader re-runs `make test` themselves)
2. Your answers to the discussion questions in `STUDENT-QUESTIONS.md`
3. An architecture diagram in your `README.md` — a photo of a hand drawing is fine, but it must
   show the **four planks** and where cash and shares cross the bridge

---

## 7. Questions left to you

The discussion prompts live in `STUDENT-QUESTIONS.md` — one per plank, no standard answers, and the
real point of this lab.
