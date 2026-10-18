# Artifacts on Proof House: protocol for the Sepolia release

The decisions this design follows (Oct 13, 2026):
- 256 piece contracts
- Self-custodial key re-wrap
- Fixed price with VRF assignment for the editions; THE SOURCE in its own single-lot auction
- Edition price set by the curator: the sale starts closed, and the price can change only while it is closed
- A 7.5% ERC-2981 royalty to the artist on every piece
- ETH only
- The art follows `RULES.md` (R0 to R13) exactly

Owners may do anything with their piece. The security goal is non-owners only.

## Contracts

**ArtifactsPiece**
- An implementation contract. Each edition is an EIP-1167 clone of it (THE SOURCE a full copy): a one-token ERC-721 with ERC-2981.
- It holds:
  - the piece's `ciphertext_seed` (SSTORE2)
  - its public traits
  - the commitment `H_K = keccak256(K)`
  - the wrapped key for the current owner
- It runs its own keyed escrow for secondary sales (below).
- `tokenURI` shows the seal and the public traits (R3: title, palette, colour count, direction). The seal is the R8 frame with no dots, the edition's number (No. nnn) in its status bar, and a closed lock marked SEALED in its middle. THE SOURCE shows its render once revealed.

**ArtifactsFactory**
- Before the sale it publishes the 255 editions' ciphertexts and commitments and locks them, so no piece can be swapped after assignment. THE SOURCE's sealed seed is stored separately, by ArtifactsSource.
- It sells editions at one ETH price that the curator sets, through the Proof House ledger, with the 75/15/5/5 split (artist, broker, house, IMD buyback and burn; a broker share nobody earned goes to the buyback). The sale starts closed; the curator sets the price (above zero) and opens it, and can change the price only while it is closed.
- Chainlink VRF assigns each buyer a random unassigned edition. If Chainlink never answers, about 3 days after the purchase anyone may draw it from the hash of a block a few blocks ahead.
- At claim it deploys the buyer's piece clone.

**ArtifactsSource**
- THE SOURCE is sold in its own single-lot ETH auction through the same ledger, with an 85/15 split (artist, broker): the curator sets the reserve and end time; each bid must beat the high bid by at least 5%; a bid in the final 10 minutes moves the end to 10 minutes after it; outbid bids are refunded by pull. Holders only, start to finish. If it isn't settled within 7 days of its end, anyone may void it and the high bid is refunded.

**Rendering** (there is no renderer contract)
- The rules are the JavaScript reference `rules.js`. It must reproduce the 11 pieces in `reference/framed/` byte for byte, as `reference/check-framed.js` proves.
- Each piece's `tokenURI` draws the seal on-chain (the `Seal` library in ArtifactsPiece): the frame and its public traits, with no dots, and a closed lock marked SEALED in the middle (an open lock marked REVEALED, OPEN TO VIEW for THE SOURCE once revealed).
- THE SOURCE is stored as its seed, never as an image. Before its auction opens the curator stores the renderer page in ArtifactsSource (the rules in an HTML page, ≈12.8 KB) with SSTORE2 and the seed, encrypted, and locks both forever with `keccak256(K)`. Once its owner reveals K, `tokenURI` marks its still image REVEALED, OPEN TO VIEW (the same frame, an open lock) and adds an `animation_url`: the renderer page plus the seed, which draws THE SOURCE in the viewer's browser, byte for byte. It does not animate: R10's shimmer and R11's drift would change the colours.
- Editions are never rendered on-chain (R13): owners render them in their browser with the JavaScript port, so a seed never goes to an RPC provider.

## Keys

**Content key.** Each piece has a random 256-bit key `K`. An edition's seed is encrypted as `ciphertext_seed = nonce ‖ AES-256-GCM(K, seed, aad = pieceId)`.

**Viewing key (R13: gated by the owner's signature).** Each owner registers a viewing public key, and `K` is wrapped to it by Diffie-Hellman. From v13 the keys are on secp256k1, Ethereum's own curve, so a contract can check them (version 2; version 1 used X25519 and AES-GCM). The exact format (site `sealcrypto.js`, shared by the site and the offline tools):
- viewing secret d = keccak256("Proof House viewing key v2" ‖ the wallet's 65-byte signature over the fixed message ‖ scope ‖ counter) mod n, for the first counter giving D = d·G with x < n, negated if D's y is odd; D.x is registered as a bytes32. Scope: empty for the wallet's key, chain id ‖ piece address for the key a buyer registers to buy that piece.
- wrapped K (65 bytes) = 0x02 ‖ E.x ‖ K XOR keccak256("Proof House key wrap v2" ‖ piece id ‖ B.x ‖ E.x ‖ S.x), where E = e·G is fresh (even y, x < n), B the viewing key lifted with an even y, and S = e·B = d·E (x < n). There is no tag: a key is checked by keccak256(K) against `H_K`. The private half is derived in the browser from the owner's wallet signature over a fixed, domain-separated message, so it is the same every time and the wallet's private key never leaves the wallet. Where the browser supports it, a **passkey** (WebAuthn PRF) can derive it instead.
- SEED-SECURITY-SPEC §3's nonce and expiry can't apply to this signature: a nonce would change the signature and the key. So this signature is a long-lived secret; anyone who obtains it can view the piece. The site must only ever ask for it on the pinned viewer, and say so. Passkeys avoid this because they only work on the real site.

**Viewing a piece**, all in the browser, with nothing sent anywhere:
1. Derive the viewing key.
2. Unwrap `K`.
3. Check `keccak256(K) == H_K`.
4. Decrypt and render.
5. Discard the key and the seed.

**First claim.** From the ceremony until each edition is claimed, the curator holds the 255 edition keys offline, never on an online computer. Each buyer registers a viewing key with the factory. The curator wraps each `K` to its buyer's viewing key offline, in batches (`tools/editions/wrap_keys.js`), and posts them with `ArtifactsFactory.postWrappedKeys`; the buyer's browser checks each against `H_K`, and the buyer claims. An edition whose key hasn't come 30 days after its draw can be claimed without it; the key can still be posted into the piece later.
- **Disclose:** the curator can view every edition until it is claimed with its key, then deletes that key (`tools/editions/prune_keys.js`).

**Secondary sale (keyed escrow).**
1. The seller lists the piece.
2. The buyer pays into escrow with a viewing key for this piece (`buy(viewingKey, broker)`; version 2, checked by `KeyProof.isViewingKey`). The escrow keeps it (`escrow().viewingKey`): the seller wraps to it, not to `viewingKeyOf(buyer)`.
3. The seller's browser re-wraps `K` to that key and posts it (`postEscrowKey(wrapped, r, z)`) with a deposit of 10% of the price, returned with the payment at release, and a proof that the seller made this wrapped key (below). Or the seller refunds the buyer (`refundBuyer`), only before posting.
4. The buyer's browser checks it against `H_K`.
5. Payment releases when the buyer confirms, or 72 hours after the key was posted (then anyone may release).
6. If the key doesn't open, the buyer proves it (`proveFakeKey`) any time before release: they reveal S for this one wrapped key with a Chaum-Pedersen proof that S = d·E for the d behind the viewing key they bought with (kept in the escrow), and `KeyProof` checks the proof with the ecrecover precompile, decrypts, and compares with `H_K`. A proven fake returns the payment and the deposit to the buyer; the seller keeps the piece. A key that opens can never be proven fake, so an honest seller can't lose the deposit and a buyer can't get a refund by lying.

**The seller's window.** For 24 hours from the payment (`SELLER_WINDOW`) only the seller can end the sale: post the key, or refund. After that, while no key has been posted, the buyer may `cancel()`. A key in a pending transaction is public: without the window a buyer could read it and cancel ahead of it. Sellers send the key well before the 24 hours end (the market warns in the last 2 hours). Once the key is posted, only release or a proven fake ends the sale.

**The seller's proof.** With the key the seller proves they know the e behind its E (Schnorr: R = k·G, given as its address `r`; z = k + c·e mod n; c = keccak256("Proof House key wrap v2 proof" ‖ chain id ‖ piece ‖ buyer ‖ viewing key ‖ keccak256(wrapped) ‖ r) mod n; checked by `KeyProof.knowsWrap`). So nobody can post a key built from someone else's E, and a proof of a fake reveals S = e·B only to the seller who made it, who already knew it. `wrapKeyForSale` in `sealcrypto.js` returns the wrapped key with `r` and `z`.
- **Disclose:** the proof of a fake reveals S, which opens only that wrapped key. Buyers use a viewing key for each piece (the site does: scope chain id ‖ piece address), and never prove with a key that also received another piece's key. Keys a curator sends (first claims, THE SOURCE) and re-keys after plain transfers carry no proof: no payment rides on them.

**Plain transfers.** Ordinary ERC-721 transfers stay allowed. The new owner sees only the seal until the previous owner calls `rewrapFor`.

**THE SOURCE.** Under R9 its dot field is keyed by its own secret 256-bit seed, made in the artist's offline ceremony (`tools/source/ceremony.js`) with its content key K. Everything else (composition, palette, drift, frame) is the public study, framed-MASTER.svg. The chain holds only its seed, encrypted: `sealedSeed = seed XOR keccak256(K ‖ uint256(0))`, locked with `keccak256(K)` before the auction, and the renderer page that draws it.
1. After settlement, the winner registers a viewing key on THE SOURCE's contract.
2. The curator wraps K to it offline (`tools/source/wrap_key.js`) and delivers it once (`ArtifactsSource.deliverKey`), then deletes K.
3. The owner can view it privately in the browser at any time.
4. The owner may `reveal(K)`, once and irreversibly: the contract checks K against the commitment, the seed becomes public, and from then on `tokenURI` serves the page that draws it for everyone. Later owners receive K from the owner before them, as with every piece.

## Disclose to buyers (consequences of the rules as written)
- **R9:** THE SOURCE's composition is public (the study, framed-MASTER.svg); only its dot field is secret. Before it is revealed, the artist and the curator (who made and delivered K) and its owner can see it.
- **Marketplaces:** after the reveal, a marketplace's grid shows the frame marked REVEALED, OPEN TO VIEW; the piece's own page runs the renderer page and shows THE SOURCE. A still image can't run the renderer, so the art itself is only ever the animation.
- **R1:** each edition's image depends on a 32-bit render key. Someone willing to run the renderer for many keys can look for one that matches an edition's public traits.
- SEED-SECURITY-SPEC already says not to market "only one person can ever see it".

## Never through IMD or any AI session
- The seed ceremony: air-gapped CSPRNG, keys, encryption, commitments. Production seeds must be newly generated, not the ones behind the existing renders in `artifacts-art/`.
- Real seeds, keys or plaintext renders.
- Before mainnet: a Solidity and applied-cryptography audit, as SEED-SECURITY-SPEC requires.

## What IMD's builders need
A public GitHub repository containing:
- `RULES.md`, `rules.js` and `check-framed.js`, the rules, the reference renderer and its test, which are public by design
- the framed test pieces: these are demo seeds 3 to 236, which aren't production pieces, plus THE SOURCE, which R9 already makes drawable by anyone
- this protocol
- the Proof House site prototype

It must not contain any production seeds, keys or `decrypted/` files.
