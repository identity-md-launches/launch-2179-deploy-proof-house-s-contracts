# Artifacts on Proof House: protocol for the Sepolia release

The decisions this design follows (Oct 13, 2026):
- 256 piece contracts
- Self-custodial key re-wrap
- Fixed price with VRF assignment for the editions; THE SOURCE in its own single-lot auction
- Edition price set by the curator: the sale starts closed, and the price can change only while it is closed
- A 7.5% ERC-2981 royalty to the artist on every piece
- ETH only
- The art follows `RULES.md` (R0–R13) exactly

Owners may do anything with their piece. The security goal is non-owners only.

## Contracts

**ArtifactsPiece**
- An implementation contract. Each piece is an EIP-1167 clone of it: a one-token ERC-721 with ERC-2981.
- It holds:
  - the piece's `ciphertext_seed` (SSTORE2)
  - its public traits
  - the commitments `H_K = keccak256(K)` and `H_seed = keccak256(seed‖params)`
  - the wrapped key for the current owner
- `tokenURI` shows the seal and the public traits (R3: title, palette, colour count, direction). THE SOURCE shows its render once revealed.

**ArtifactsFactory**
- Before the sale it publishes all 256 ciphertexts and commitments, so no piece can be swapped after assignment.
- It sells editions at one ETH price that the curator sets, through the Proof House ledger, with the 15/15/70 split and broker commissions. The sale starts closed; the curator sets the price (above zero) and opens it, and can change the price only while it is closed.
- Chainlink VRF assigns each buyer a random unassigned edition.
- At claim it deploys the buyer's piece clone.
- It runs keyed escrow for secondary sales.
- THE SOURCE is sold in its own single-lot ETH auction through the same ledger: the curator sets the reserve and end time; each bid must beat the high bid by at least 5%; a bid in the final 10 minutes moves the end to 10 minutes after it; outbid bids are refunded by pull.

**ArtifactsRenderer**
- An on-chain port of `RULES.md`. It must reproduce the 11 pieces in `reference/framed/` byte for byte, as `reference/check-framed.js` proves for the JavaScript reference.
- `renderSeal` draws the seal for any piece: the frame and its public traits, with no dots.
- THE SOURCE is not recomputed on-chain. Before its auction opens the curator stores its finished metadata with SSTORE2 and locks it forever: `reference/the-source.payload.b64`, base64 JSON whose image is framed-MASTER.svg byte for byte. Once revealed, `tokenURI` returns `data:application/json;base64,` plus those bytes, copied as is, in about 7M gas. It does not animate: R10's shimmer and R11's drift would change the colours of the approved art.
- Editions are never rendered on-chain (R13): owners render them in their browser with the JavaScript port, so a seed never goes to an RPC provider.

## Keys

**Content key.** Each piece has a random 256-bit key `K`. The seed and params are encrypted as `ciphertext_seed = AES-256-GCM(K, seed‖params, aad = pieceId)`.

**Viewing key (R13: gated by the owner's signature).** Each owner registers an X25519 viewing public key once, and `K` is wrapped to it with ECIES. The private half is derived in the browser from the owner's wallet signature over a fixed, domain-separated message, so it is the same every time and the wallet's private key never leaves the wallet. Where the browser supports it, a **passkey** (WebAuthn PRF) can derive it instead.
- SEED-SECURITY-SPEC §3's nonce and expiry can't apply to this signature: a nonce would change the signature and the key. So this signature is a long-lived secret; anyone who obtains it can view the piece. The site must only ever ask for it on the pinned viewer, and say so. Passkeys avoid this because they only work on the real site.

**Viewing a piece**, all in the browser, with nothing sent anywhere:
1. Derive the viewing key.
2. Unwrap `K`.
3. Check `keccak256(K) == H_K`.
4. Decrypt and render.
5. Discard the key and the seed.

**First claim.** From the ceremony until each edition is claimed, the curator holds the 256 keys, wrapped to the curator's own viewing key. At claim, the curator wraps `K` to the buyer's viewing key, and the buyer's browser checks it against `H_K`.
- **Disclose:** the curator can view every piece until the last claim, then deletes the keys.

**Secondary sale (keyed escrow).**
1. The seller lists the piece.
2. The buyer pays into escrow and registers a viewing key.
3. The seller's browser re-wraps `K` and posts it.
4. The buyer's browser checks it against `H_K`.

Payment releases when the buyer confirms, or after 72 hours. The buyer can cancel only until the key is posted.
- **Disclose:** a contract can't verify a wrapped key without a zero-knowledge proof. A dishonest seller could post a key that doesn't open; the buyer would see it fail but couldn't get a refund trustlessly. ZK verification is a later upgrade.

**Plain transfers.** Ordinary ERC-721 transfers stay allowed. The new owner sees only the seal until the previous owner calls `rewrapFor`.

**THE SOURCE.** Under R9 it has no seed: its image is fixed by the rules. Its owner can set its write-once `revealed` flag, once and irreversibly. Until then its `tokenURI` shows the seal; from then on it returns the stored image: framed-MASTER.svg exactly as approved.

## Disclose to buyers (consequences of the rules as written)
- **R9:** THE SOURCE's image is fixed by the public algorithm, so anyone running the rules can draw it before it is revealed. Revealing makes it official and puts it on-chain.
- **R1:** each edition's image depends on a 32-bit render key. Someone willing to run the renderer for many keys can look for one that matches an edition's public traits.
- SEED-SECURITY-SPEC already says not to market "only one person can ever see it".

## Never through IMD or any AI session
- The seed ceremony: air-gapped CSPRNG, keys, encryption, commitments. Production seeds must be newly generated, not the ones behind the existing renders in `artifacts-art/`.
- Real seeds, keys or plaintext renders.
- Before mainnet: a Solidity and applied-cryptography audit, as SEED-SECURITY-SPEC requires.

## What IMD's builders need
A public GitHub repository containing:
- `RULES.md`, `rules.js` and `check-framed.js`, the rules, the reference renderer and its test, which are public by design
- the framed test pieces: these are demo seeds 3–236, which aren't production pieces, plus THE SOURCE, which R9 already makes drawable by anyone
- this protocol
- the Proof House site prototype

It must not contain any production seeds, keys or `decrypted/` files.
