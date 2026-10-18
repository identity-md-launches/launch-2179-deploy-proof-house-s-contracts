# Additional stateful coverage

These suites extend the accepted tests without changing application code, deployment arguments, or configuration. Each handler uses an explicit selector list, bounded inputs, several callers, and `fail-on-revert = true`. Expected failures are checked with specific custom errors; an unexpected failure stops the campaign. The run settings travel in Solidity comments: 96 sequences of 64 calls per suite, and 1,000 funding/burning fuzz cases.

- `BuybackConservation.t.sol` covers the separately deployed buyback burner, a value holder that previously had unit and fork tests but no dedicated invariant handler. Ghost totals track ETH funding, actual ETH spent, direct IMD funding, and both sources of burned IMD. Invariants reconcile the burner, pool, burn destination, and cumulative counters. Calls include donations, full/partial swaps, direct burns, curator handovers, public swaps across inactivity and daily windows, failed slippage/deadline/amount/minimum checks, and unauthorized callbacks. Deterministic tests pin one wei, the exact inactivity and daily boundaries, rollback of the curator clock after failed slippage, and the last public swap below its cap.
- `BrokerClaimsInvariant.t.sol` uses real application deployments, two purchased and claimed editions, and THE SOURCE after auction settlement. Random calls move seats, pieces, and passes, claim through both credential routes, and attempt unauthorized or zero-recipient transfers. Independent histories check each wallet and credential claims only once, NFT balances reconcile with token owners, and ArtHouse broker eligibility follows pass ownership. Deterministic sequences pin the opening second and cross-check wallet/credential reuse after transfers. The existing cap test still supplies the exact 100-pass exhaustion case; this campaign uses eight mobile wallets.
- `ReviewHistoryInvariant.t.sol` models reviews independently by seat across transfers, verdict changes, and curator decisions. Invariants compare every stored review, exact verdict tallies, pagination contents and first-review order, submission status, distinct thesis authors, and the absence of broker privileges. Submission zero stays pending to sustain edits in long sequences; two others may be accepted or rejected and their records must freeze. Deterministic sequences exercise both final decisions and a new holder changing the same voice. Claimed-piece review routes remain covered by the existing `Reviews.t.sol` tests.

The added tests run offline with existing local stand-ins for identity seats, IMD, and the pool manager. The pool stand-in enforces unlock/settle/take accounting at a fixed rate; these checks do not establish real pool liquidity, pricing, partial fills caused by a price limit, or live Chainlink service behavior. The existing mainnet pool and coordinator fork suites require `FORK_URL` and skip without it; those live-state runs remain owed when an RPC is available. No new dependency is required.

## Local validation

Foundry 1.8.5 / Solidity 0.8.26:

- `forge build`: passed.
- Full `forge test` with `FOUNDRY_FUZZ_SEED=0x9c11807f812cb2361b4137f8ffa9aa8f637b5257d865e6236bfc291828760e1e`: 244 passed, zero failed, two RPC-dependent fork suites skipped.
- Added suites alone with that seed: 12 passed, zero failed, zero skipped, including 18,432 randomized handler calls and 1,000 funding/burn fuzz cases.
- All invariant suites together with that seed: 16 passed, zero failed, zero skipped.
- Formatting and whitespace checks passed for the added files.
