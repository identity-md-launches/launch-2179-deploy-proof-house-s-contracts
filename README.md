# Proof House — contracts

Proof House is a curator-run house for fully on-chain art bought by people and AI agents, with agents as
brokers. This repository holds its Sepolia contracts and the first collection, **ARTIFACTS**: 256 encrypted
generative pieces — 255 editions and THE SOURCE. Reference: https://github.com/mylesdaughtry/proof-house
(its `RULES.md`, `PROTOCOL.md`, reference renderer and THE SOURCE payload are vendored under
`reference/`).

No fungible token is created and there is no pool. IMD (`0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A` on Sepolia)
is an existing ERC-20 that buyers of plain collections may pay with. The only tokens are ERC-721 pieces, minted
only when a piece is bought.

## Launch set (5 contracts, deployed in this order)

| # | Contract | Constructor | Role |
|---|----------|-------------|------|
| 0 | `ArtStorage` | `($owner)` | SSTORE2 chunk store for plain SVG collections; written only by ArtHouse |
| 1 | `ArtHouse` | `($owner, $contract:ArtStorage, IMD)` | The ledger: artists, brokers, sale modules, splits, balances, plain collections, submissions. Its constructor deploys the `ArtCollection` implementation. |
| 2 | `ArtifactsPiece` | `()` | Locked implementation: a one-token ERC-721 + ERC-2981 per piece (clone per edition; full copy for THE SOURCE) |
| 3 | `ArtifactsFactory` | `($owner, $contract:ArtHouse, $contract:ArtifactsPiece)` | Publishes the 255 editions, sells them, VRF assignment, claims |
| 4 | `ArtifactsSource` | `($owner, $contract:ArtHouse, $contract:ArtifactsPiece)` | THE SOURCE: stored payload, single-lot auction, settlement |

`$owner` is the curator: `0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386`. `script/Deploy.s.sol` shows the exact
wiring and is what the tests deploy; it broadcasts nothing. Constructors take only static values, the owner and
earlier contracts, and call no other contract. ArtifactsSource was split out of ArtifactsFactory so every
runtime stays well under the EIP-170 limit (largest: ArtifactsPiece, 18.5 KB).

Ownership is two-step everywhere (`transferOwnership` → `acceptOwnership`); there is no `renounceOwnership`,
no upgradeability, no DELEGATECALL/SELFDESTRUCT in any launched runtime. ETH leaves contracts by `call`, pull-style.

## After launch (curator, in this order)

1. `ArtStorage.setHouse(ArtHouse)` — one time, irreversible.
2. `ArtHouse.approveArtist(artist, name)` for the ARTIFACTS artist. The artist may `setPayout(address)` later;
   payout is kept across revoke/re-approval.
3. `ArtHouse.setSaleModule(ArtifactsFactory, true)` and `ArtHouse.setSaleModule(ArtifactsSource, true)`.
4. `ArtHouse.registerModuleCollection(ArtifactsFactory, artist)` and `…(ArtifactsSource, artist)` so their sales
   split and pay royalties to that artist (default split 15% broker / 15% house / 70% artist; `setSplit` to change).
5. `ArtHouse.setBroker(agent, true)` for each approved broker agent.
6. `ArtifactsFactory.configureVRF(coordinator, keyHash, subscriptionId, nativePayment)` — **set once**. Values come
   from Chainlink's published Sepolia VRF v2.5 coordinator and key hash, and the curator's own subscription id
   (create it at vrf.chain.link, fund it, and add ArtifactsFactory as a consumer). `nativePayment=false` pays in
   LINK, `true` in ETH. Buying reverts with `VRFNotConfigured` until this is done; it cannot be changed afterwards.
7. `ArtifactsFactory.setPiece(id, traits, ciphertext, commitment)` for ids 1..255: public traits (title, palette,
   colour count, direction), the AES-256-GCM encrypted seed and `keccak256(K)`. Then `lock()` — forever.
8. `ArtifactsFactory.setPrice(wei)` (above zero, only while closed) and `setSaleOpen(true)`.
9. THE SOURCE: `ArtifactsSource.storePayloadChunk(bytes)` with consecutive ≤24,575-byte slices of
   `reference/the-source.payload.b64` (the bytes of the reference repository's `artifacts/reference/the-source.payload.b64`) (77 chunks of up to 24,000 bytes in the tests), then `lockPayload()`.
   `payloadHash()` must equal keccak256 of the file. Then
   `setAuction(reserveWei, endTime)`.

## ARTIFACTS flow

- **Buy an edition**: `ArtifactsFactory.buy{value: price}(broker)`. State is written, the ETH goes to
  `ArtHouse.recordSale` (credits written before any transfer), then a VRF v2.5 request is made. The callback
  `rawFulfillRandomWords` (coordinator only) assigns a uniformly random unassigned edition by a lazy
  Fisher-Yates over 1..255: none twice, none skipped (tested over all 255 purchases). If the coordinator never
  answers a request (Chainlink drops requests an underfunded subscription cannot pay within ~24h), the curator
  may `rerequestRandomness(requestId)` once `VRF_RETRY_BLOCKS` have passed: the old id is forgotten (a late
  answer to it is rejected), a new request carries the same buyer, and the purchase still yields exactly one
  edition. Watch `sold` vs `assigned` and the `Purchased`/`EditionAssigned`/`Rerequested` events.
- **Claim**: buyer `registerViewingKey(x25519PublicKey)`; curator `postWrappedKey(edition, K wrapped to it)`;
  buyer (or curator) `claim(edition)` deploys the EIP-1167 clone of ArtifactsPiece, named `ARTIFACTS #NNN`,
  symbol `ARTIFACTS`, holding the ciphertext pointer, traits, commitment and wrapped key, and mints token 1 to
  the buyer. There is no other mint path.
- **Seal**: each piece's `tokenURI` is on-chain base64 JSON whose image is the R8 frame (white sheet, double
  border, `File   View   Run` menu, title, status `PALETTE  ·  kC  ·  DIRECTION` / `SEED nnn`) with no dots;
  tested byte-for-byte against `framed-003.svg` with its dots removed.
- **Resale escrow** (in each piece): owner `list(price)`; buyer `buy{value: price}(viewingKey)`; seller
  `postEscrowKey(rewrapped)`; `release()` by the buyer, or by anyone after 72 hours; `cancel()` by the buyer until
  the key is posted. Seller proceeds (minus the 7.5% royalty to the artist's payout) and refunds are pulled with
  `withdraw()`. While a buyer's payment is in escrow the token cannot be transferred. Plain transfers stay allowed
  and clear the wrapped key; the previous owner may `rewrapFor(bytes)` once the new owner registered a key.
  Re-keying is one shot: the key slot must be empty, the key must not be empty (nor an escrow key), and posting
  ends the previous owner's right. A release clears it too, so a paid seller can never overwrite the key the
  buyer received. Viewing keys cannot be zero.
- **THE SOURCE**: single-lot ETH auction. Each bid must be ≥ reserve and ≥ 105% of the high bid (the 5% raise
  rounds up, so a bid always strictly exceeds the high bid, even at dust sizes); a bid in the
  final 10 minutes moves the end to 10 minutes after it; outbid bids are refunded by `withdrawRefund()` (pull).
  `settle()` sends the proceeds through the ledger and deploys THE SOURCE's own contract — a full byte copy of
  ArtifactsPiece's runtime (not a proxy, so the 1.8 MB revealed answer is copied once) named
  `ARTIFACTS · THE SOURCE`. Its owner may `setRevealed()` once; before that `tokenURI` is the R9 seal, after it
  returns `data:application/json;base64,` + the stored payload bytes copied as is, in ≈7.2M gas (tested under
  10M and byte-for-byte equal to the file, whose image decodes to `framed-MASTER.svg`). If the auction ends with
  no bid the curator may set it again.
- **Views**: `price`, `remaining`, `editionsOf`, `pieceContract`, `traitsOf`, `ciphertextOf`, `commitmentOf`,
  `wrappedKeyOf`, `auctionState`, `revealed`.

## Plain SVG collections (ArtHouse)

`createCollection(name, symbol, artist)` clones `ArtCollection`; supply = registered pieces. The curator or the
collection's artist (while still approved: `revokeArtist` ends curation rights as well as new collections)
`registerPiece(collection, pieceId, contentHash, title, description)` (next id only),
`uploadChunk(collection, pieceId, index, data)` (next index only, ≤100 KB per piece), `finalizePiece`
(keccak256 of the chunks must equal `contentHash`); a mistyped hash, title or description is corrected with
`updatePiece(collection, pieceId, contentHash, title, description)` while the piece is unfinalized (chunks are
kept). The curator may `clearPiece` while unfinalized and `sealCollection` once every piece is finalized. Sales start closed: `setPrices(collection, eth, imd)` and
`setSaleOpen`. `mint(collection, pieceId, broker)` takes exactly the ETH price; `mintWithIMD(collection, pieceId,
broker, price)` needs `price` to equal the current IMD price and pulls exactly that. `submit(contentHash,
previewURI)` is open to anyone; the curator `decideSubmission`.

Every sale is split in basis points per collection (house takes rounding); a broker earns only if approved and
not the buyer, otherwise its share goes to the house. Balances are per currency (ETH = address(0), IMD);
artists and brokers `withdraw(currency)` their own (artists to their payout address); `withdrawHouse` pays the
current owner. Every piece pays a 7.5% ERC-2981 royalty to its artist's payout address.

## Named constants (chosen where the brief left them open)

| Constant | Value | Where |
|----------|-------|-------|
| `VRF_CALLBACK_GAS` | 250,000 | ArtifactsFactory |
| `VRF_CONFIRMATIONS` | 3 | ArtifactsFactory |
| `VRF_RETRY_BLOCKS` | 7,200 (~24 h at 12 s blocks) | ArtifactsFactory |
| `MIN_RAISE_BPS` | 500 (5%) | ArtifactsSource |
| `EXTENSION` | 10 minutes | ArtifactsSource |
| `ESCROW_TIMEOUT` | 72 hours | ArtifactsPiece |
| `ROYALTY_BPS` | 750 | ArtHouse / ArtifactsPiece |
| default split | 1500 / 1500 / 7000 | ArtHouse |
| `MAX_PIECE_BYTES` | 100,000 | ArtHouse |

## Trust assumptions and responsibilities

- The curator (owner) approves artists, brokers and sale modules, sets prices and splits, publishes the
  ARTIFACTS ciphertexts/commitments before locking, posts first-claim wrapped keys, and runs THE SOURCE auction.
  Until the last claim the curator holds every content key (PROTOCOL.md). The contracts cannot verify that a
  wrapped key opens; a dishonest seller in escrow can post a bad (non-empty) key (disclosed in PROTOCOL.md).
- `setSplit` is read at sale time: the curator can change a module collection's split while bids or purchases
  are pending (e.g. before THE SOURCE settles). This is an owner power by design, not a bypass; bidders trust the
  curator not to redirect the artist's or broker's share after the fact.
- Chainlink VRF is the only randomness; the subscription must stay funded or purchases revert at request time.
  A purchase whose callback never arrives keeps the buyer's payment in the ledger with no edition until the
  curator calls `rerequestRandomness` (above); only the curator can, so the buyer relies on the curator doing so.
  The mock coordinator in tests is not production randomness.
- IMD is assumed to be a standard ERC-20 (no fee on transfer); `mintWithIMD` checks the balance delta.
- Tests passing is not an audit. Funds-holding code needs an independent adversarial review before mainnet.

## Build and test

```
forge build
forge test
forge fmt --check
```

Foundry profile: solc 0.8.26, via-IR, optimizer 200 runs, `bytecode_hash = "none"`, read-only `fs_permissions`
on `reference/` (tests read the payload and reference SVGs). Dependencies: forge-std only, vendored in `lib/`.
Tests cover: split invariants per currency (fuzzed), VRF assignment of all 255 editions, claim, escrow and
re-keying, auction, reveal, access control, reentrancy, seals per RULES.md R8, and THE SOURCE's revealed
tokenURI decoding to framed-MASTER.svg byte for byte.
