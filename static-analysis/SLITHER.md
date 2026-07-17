# Static Analysis (Slither): results and triage

Tool: Slither 0.11.5 (Trail of Bits), solc 0.8.36.
Run date: 2026-07-16. Raw per-contract output is in `slither-<Contract>.txt` in this folder.

This run predates the WoblCurve remediation (see README, "Prior review"), so the WoblCurve line
numbers below do not match the shipped source, and the one real finding it produced (the ownership
zero-check) is now fixed. Rerunning on the current source will differ.

Command per file (contracts are self-contained, no imports):
```
slither contracts/<Contract>.sol --exclude-informational
```

## Summary

| Contract | Results | True positives | Disposition |
|---|---|---|---|
| SwapHelper | 0 | 0 | Clean. |
| RevSplitLocker | 2 | 0 | Both reentrancy flags are false positives (manual guard). |
| Launchpad | 15 | 0 | All known-LOW/INFO or false positives. |
| WoblCurve | 27 | 1 LOW | Missing zero-check on ownership, since fixed; rest FP/minor. |

## Triage detail

### SwapHelper: 0 findings
Clean under all 80 detectors.

### RevSplitLocker: 2 findings, both FALSE POSITIVE
- `reentrancy-no-eth` / `reentrancy-events` in `collect()` (`RevSplitLocker.sol:100-128`).
  `collect()` carries a hand-rolled reentrancy guard: `_entered` is set to `2` at line 101 (before any external call) and released to `1` at line 127 (after all transfers). A reentrant call reverts at the `_entered == 2` check. Slither does not model manual guards (only the `nonReentrant` modifier pattern), so it reports the external-call-then-emit shape. Verified by hand: the guard is set before the NFPM `collect` and all token transfers, and the only state written after the external calls is the guard release, so there is no exploitable reentrancy. The locker's only other entrypoint, `onERC721Received`, is gated to the NFPM, so there is no cross-function reentrancy path either.

### Launchpad: 15 findings
- `arbitrary-send-eth` in `_refund` (`Launchpad.sol:405-415`): FALSE POSITIVE in context. The destination is `msg.sender` (the creator being refunded their own overpaid dev-buy), not an attacker-chosen address. Slither flags any value-bearing `.call` to a non-constant address. The refund path is `nonReentrant`-guarded at the `createToken` entry. (Cosmetic: `_refund` runs before the registry write; strict CEI would reorder. INFO.)
- `unchecked-transfer` in `_refund` (`:414`): ignores the return of `LaunchToken(token).transfer(msg.sender, dust)`. `LaunchToken` is our own ERC20 defined in the same file; its `transfer` returns `true` or reverts, so the ignored return is safe. Belt-and-suspenders: add a return check. LOW.
- `incorrect-equality`: `tokensOut == 0` in `_devBuy` (`:384`) and one strict equality in `_seedAndLock`. These are intentional guard checks (revert when a dev buy yields nothing / seed sanity), not manipulable balance-equality checks. FALSE POSITIVE.
- `unused-return`: destructuring `slot0()` to take only `sqrtPriceX96` (`:328`, intentional) and ignoring `approve()` return on our own token (`:340`, safe). Intentional.
- `reentrancy-benign` in `createToken` / `_devBuy`: state written after external calls, but both are `nonReentrant`. Benign per Slither, matches manual review.
- `timestamp`: FALSE POSITIVE (Slither flags every `block.timestamp` read).
- `immutable-states`: minor gas optimization suggestion.

### WoblCurve: 27 findings
- `missing-zero-check` on `owner` in the constructor and `transferOwnership`: REAL LOW. Impact is limited to the pause key. Fixed: zero-address guard plus 2-step ownership (`pendingOwner` / `acceptOwnership`).
- `unused-return`: ignores `approve()` return in `_seedAndLockTwoSided` (`:753`, our own token). The `mint()` return IS captured (`tokenId, liquidity`). Safe.
- `reentrancy-benign` in `createToken` (`:528-562`): the `curves`/`pool`/`allTokens` writes happen after `_initPool`'s external `createAndInitializePoolIfNecessary`. Guarded by `nonReentrant`; benign. (The CEI-cosmetic note from the manual review.)
- `timestamp`: FALSE POSITIVE. Slither labels the `c.creator == address(0)` existence checks as "uses timestamp" because the enclosing functions also read `block.timestamp`; the flagged comparisons themselves are not timestamp-dependent.
- `immutable-states`: `WoblToken.totalSupply` could be `immutable` (minor gas).

## Actions taken to the code as a result
The zero-address guard and 2-step ownership on WoblCurve were added (see README, "Prior review").
The remaining items (explicit return checks on internal transfers/approvals of our own token,
marking eligible state `immutable`) are LOW/INFORMATIONAL and untaken. No true-positive
vulnerability was found by static analysis.
