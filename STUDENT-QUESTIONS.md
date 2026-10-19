# STUDENT-QUESTIONS.md — Discussion questions (goes inside your submission zip)

Answer directly under each question. 150–300 words each — **reasoning over length**.

The sections follow the four planks of the bridge. There are no standard answers; these are the
real point of the lab.

---

## A. Custody — where the asset actually is (plank a)

**A1.** In Lab 1, `totalCollateral()` read the vault's own ERC-20 balance, and the chain could
prove the invariant. Here, `MockTBillCustodian.realHoldings()` is just a number that a permissioned
address can move. Write the equivalent of `totalCollateral() == totalSupply()` for *this* system.
What does it actually assert, and what does it no longer prove?

> Lab 1 could count ERC-20 collateral held by its vault. Here a useful *pre-queue* coverage
> check must include both reported T-Bills and uninvested USDC:
>
> ```
> realHoldings() + usdc.balanceOf(vault) >= totalClaimValue()
> ```
>
> A custodian-only check would falsely flag Ex2.1: immediately after `subscribe()`, the vault
> holds the investor's cash and the custodian reports zero. Once redemption tickets exist,
> however, `totalClaimValue()` is not the whole liability. It values *all* unburned shares at
> the current NAV, while `enqueue()` fixes each ticket's payout at its earlier NAV. If a queued
> share locked 1.00 and NAV falls to 0.90, it still needs 1.00, not 0.90. A fuller accounting
> check for obligations not yet settled is:
>
> ```
> realHoldings() + usdc.balanceOf(vault)
>   >= (tBill.totalSupply() - queue.pendingShares()) * NAV / 1e20
>      + queue.pendingAssets()
> ```
>
> Escrowed shares leave the floating-NAV term; their locked USDC promises enter through
> `pendingAssets()`. After settlement, their shares are burned and Ex6 separately requires
> `usdc.balanceOf(queue) >= queue.totalClaimable()`.
>
> These are checks on reported books, not proof that the T-Bills exist or can be sold. In
> Ex2.2, `recordPurchase()` increases `realHoldings()` without moving cash, so a false report
> can satisfy the check. A `recordSale()` can change the report before proceeds reach the
> vault. Unlike Lab 1, the chain cannot verify the off-chain asset or its availability at T+1.

<br><br><br>

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> An SPV separates the fund's assets from the issuer's own balance sheet, but a smart contract
> cannot make that separation legally effective. Subscription terms, the SPV's ownership and
> custody records, and applicable insolvency law determine what the token holder can enforce.
> In a real issuance the token would evidence a fund interest and redemption rights; it does not,
> by itself, give the holder title to a particular Treasury bill. If assets were properly
> segregated, the SPV or its administrator may seek their return from an insolvent custodian.
> Whether and when that succeeds depends on the legal documents and actual records.
>
> If the custodian fails, an administrator may freeze accounts while reconciling holdings. The
> SPV may then be unable to sell T-Bills or receive the proceeds on time.
> `realHoldings()` could still display the last reported number. If the vault's USDC buffer has
> run out, the operator cannot refill it with those proceeds; `settle()` cannot draw enough cash
> through `releaseReserves()`. The ticket remains pending at its original FIFO position, and
> `claim()` is unavailable until it has settled. The investor retains whatever claim the fund
> documents provide but cannot turn it into USDC on schedule. Independent custody records,
> segregation, a backup custodian and a liquidity buffer can reduce this delay; none guarantees
> immediate exit through an insolvency proceeding.

<br><br><br>

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> A single trusted reporter fails in three ways, and each needs a different mitigation.
>
> 1. Compromised key. A leaked or bribed reporter key lets an attacker write any NAV. Ex7 shows
> how a false number can overstate a redemption ticket; cash extraction also requires a settler
> and available vault reserves. The mitigation is an M-of-N attestation quorum, independent
> price sources, or a challenge period before a large NAV change prices transactions.
>
> 2. Honest but stale. A feed that stops updating leaves a price the market has moved past.
> Anyone who knows the current value can trade against it (B2). A real feed should store the
> timestamp of its last *write*; `subscribe()` and `enqueue()` should reject a price older than
> a defined heartbeat, with bounds and secondary confirmation for large jumps.
>
> 3. Honest but wrong. A data-entry error or bad upstream source produces a fresh but inaccurate
> price. Reconciliation against independent custody and pricing records before publication,
> followed by auditor review and a contractual error-correction process, addresses that case.
>
> There is a more basic limitation in *this mock*: `MockPriceFeed.setPrice()` is callable by
> anyone, so `REPORTER_ROLE` gates only the `vault.attest()` route. Also,
> `latestRoundData()` returns the current block time even without a new price. Production
> safeguards must first restrict feed writes and record the real update time; merely checking
> `updatedAt` as this mock returns it would not detect staleness.

<br><br><br>

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> The attacker is anyone who sees an asset-price move before the reporter updates the feed.
> Suppose 1,000 existing shares have assets worth 1,100 USDC, a true NAV of 1.10, while the
> feed still says 1.00. A buyer pays 1,000 USDC and `subscribe()` mints 1,000 shares instead
> of about 909. The combined fund has assets worth 2,100 USDC for 2,000 shares, a true NAV of 1.05:
> the buyer's position is worth 1,050, and the original holders have lost 50. If the true NAV
> instead falls while the feed stays high, a holder can `enqueue()` at that old price; the
> ticket fixes an excessive USDC payout that later settlement takes from the fund's cash.
> Neither trade needs a compromised key. Both are possible while the old NAV remains usable.
>
> A wrong *new* report calls for source checks and independent sign-off. Staleness needs a
> different control: store the actual time of the last NAV update, reject `subscribe()` and
> `enqueue()` after a short heartbeat expires, and halt pricing until a fresh report arrives.
> This mock's `latestRoundData()` returns `block.timestamp` on every read, so checking its
> current `updatedAt` value alone would falsely label an unchanged price as fresh.

<br><br><br>

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Suppose a holder queues one share at NAV 1.00, so `assetsLocked` is 1.00 USDC. If NAV rises
> to 1.10 before settlement, the ticket still pays 1.00. The redeemer misses the 0.10 gain,
> which remains with the fund's other holders. If NAV falls to 0.90, the ticket still pays
> 1.00. The extra 0.10 comes from the fund and reduces what remains for those holders.
> Someone expecting a fall therefore has a reason to queue early, before the lower NAV is
> posted. Locking the price at enqueue can increase pressure on the queue during a decline.
>
> This also explains why `vault.reserveBalance() >= queue.pendingAssets()` is not an Ex6
> invariant. `invest()` may move all USDC out of the vault while a ticket is pending; the
> ticket remains in the queue even though the immediate cash buffer is zero. The reported
> T-Bill position and the vault's USDC balance must be considered separately.
>
> I would price the payout at settlement, or at the price received when the underlying is
> sold, after costs. Then the redeemer bears NAV changes during T+1, although the final
> amount is unknown when they enter the queue. If the product instead promises a fixed
> amount at enqueue, it should disclose who bears later losses and use a separate queue
> intake gate or FIFO payout throttle when liquidity is short. Already-funded claims should
> remain payable.

<br><br><br>

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Lehman losses pushed Reserve Primary Fund's September 2008 NAV to $0.97. It could not meet
> redemption requests, obtained SEC relief to suspend redemptions beyond the normal seven-day
> payment period ([SEC filing](https://www.sec.gov/Archives/edgar/data/83335/000110465908066624/a08-25991_5nq.htm)),
> and distributed cash in stages. Investors had recovered over 98 cents per
> dollar by January 2010 and about 99 cents by July 2010, after a long loss of access to their
> cash ([SEC](https://www.sec.gov/newsroom/press-releases/2010-16-reserve-primary-fund-distributes-assets-investors);
> [GAO](https://www.gao.gov/assets/a316444.html)). The fund's loss and delay fell on shareholders.
> In March 2023, Circle had $3.3bn of USDC reserves at failed Silicon Valley Bank. USDC traded
> below par while banking disruption delayed fiat redemptions; Circle maintained its 1:1 promise,
> and the authorities' protection of SVB depositors removed the reserve shortfall risk
> ([Circle, March 12](https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes)). Circle
> reported that most mint and redemption requests in its backlog had cleared by March 15
> ([Circle](https://www.circle.com/blog/march-15-update-on-usdc-operations)).
>
> For this T-Bill fund, a closure should reject new `enqueue()` requests, preserve existing
> tickets and their FIFO order, and stop settling tickets only while cash is unavailable. When
> sale proceeds refill the vault, settlement resumes from the head; already-settled USDC stays
> claimable. The lab's `TBillToken.pause()` instead blocks transfers, minting and burning: it
> prevents new tickets and settlement burns while also freezing ordinary holders' transfers.
> It does *not* block `queue.claim()`, which transfers only USDC. I would separate an intake
> gate from a cash-aware FIFO settlement throttle, disclose the delay, and keep funded claims
> payable. That targets the liquidity shortage without freezing unrelated token activity.

<br><br><br>

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> The two-endpoint check stops both directions of non-compliance. A sanctioned address cannot
> receive shares, and an ordinary investor who has not finished KYC cannot hold them either.
> If an investor pays USDC before being whitelisted, `tBill.mint()` reverts. The entire
> `subscribe()` transaction, including the USDC transfer, then reverts. This is an intentional
> restriction on who may hold the fund's shares.
>
> The eligibility rule must follow the fund's offering documents and applicable securities and
> sanctions requirements, with the issuer's compliance team accountable for implementing it.
> Everyone who can hold must meet those conditions; everyone else is out, regardless of price.
> The costs are real: transfers require two eligible wallets, and the public ledger reveals
> wallet-to-wallet activity. A whitelist enforces this one condition; it does not, on its own,
> make an offering legally compliant.
>
> A compliance officer should control whitelist changes. On-chain that means a
> COMPLIANCE_ROLE held by a compliance-controlled multisig or a delegated provider, separate
> from minting and pausing keys. Every change should emit an event and be tied to a retained
> off-chain decision record. The registry controls on-chain admission; the issuer still has
> to meet obligations that a wallet whitelist cannot express.

<br><br><br>

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> The fund has reasons to use both powers. A freeze enforces sanctions and court
> orders; a burn can extinguish fraudulently obtained or legally forfeited positions, with any
> compensation handled off-chain. The fund may need both powers to meet legal obligations.
>
> The same permissions can also be abused by a compromised or hostile issuer to freeze
> innocent holders or destroy balances. A mistaken freeze blocks an investor's transfer
> and `enqueue()`, delaying exit. Ex4.3 shows the levers collide: `_update` guards both
> endpoints, so once an address is off the list, `burn()` reverts too. If one issuer controls
> both roles, it can re-whitelist the address and then burn, so this collision is not a reliable
> safeguard. It also blocks a court-authorized burn while the address remains frozen.
>
> I would give COMPLIANCE_ROLE to a compliance-controlled multisig and MINTER_ROLE to a
> separate fund-administrator multisig. An emergency freeze can take effect immediately but
> needs a logged reason and prompt independent review. Confiscation needs dual approval and
> a documented legal basis; a narrowly scoped forfeiture path would bypass the frozen
> holder's `_update` check without reopening ordinary transfers. The aim is to make any
> legally required action possible and reviewable.

<br><br><br>

---

## E. Tests (Tier 1 required — this is Ex2, Ex3 and Ex4)

Turn the red tests green in `test/exercises/01_BridgeTasks.t.sol` to cover the scenarios below, and
write your test function names here:

| Plank | Scenario | Your test function name |
|---|---|---|
| a | Shares exist while the custodian holds nothing | `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` |
| a | `realHoldings()` moves with no cash moving | `test_Ex2_RealHoldingsIsJustANumber` |
| b | The claim value floats while the share count stays | `test_Ex3_TheClaimFloats_TheShareCountDoesNot` |
| b | One `attest` re-prices every holder at once | `test_Ex3_OneCallMovesTheWholeBook` |
| d | A non-whitelisted address cannot receive shares, even by paying | `test_Ex4_NoKyc_NoShares_EvenIfYouPay` |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | `test_Ex4_TransferChecksBothEndpoints` |
| d | Removing an address freezes that holder — and blocks a burn | `test_Ex4_FreezeBeatsConfiscation` |

Then write one more scenario you consider **most likely to be exploited** on a tokenized fund, and
say which plank it breaks:

> False NAV entering the feed breaks plank (b), attestation. In a role-gated production feed,
> a compromised reporter could raise NAV after buying shares, then enqueue to lock an inflated
> payout. Actual cash extraction needs sufficient vault USDC and an authorized settler, who
> might process the ticket in good faith; Ex7 grants its attacker both REPORTER_ROLE and
> SETTLER_ROLE for the demonstration. In this lab's mock, anyone can call
> `MockPriceFeed.setPrice()` directly. An attacker can create an inflated ticket before any
> real T-Bill value changes, shifting any eventual shortfall to the remaining holders.
