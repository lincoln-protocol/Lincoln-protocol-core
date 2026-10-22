# Proving parameter provenance

Review circuit sources under `zk/circuits/`, final proving materials under `zk/parameters/`, ceremony evidence under `zk/ceremony/` and generated verifiers under `contracts/verifiers/`.

These regular circuit/parameter/verifier files preserve the same final bytes used by RC.2. The current `review-manifest.json` maps them to `releases/rc3/`; `npm run check` verifies the candidate binding. RC.3 changes the pool cap-increase delay to 12 hours and therefore its pool bytecode. It does not change the circuit statements, final keys or historical `v0.1.0-rc.2` tag/archive.

## Physical review paths and logical release paths

Parameter manifests contain the original logical names used by the release tooling. A manifest's witness-WASM or verifier path need not equal its readable root location. Renaming a display path does not rewrite its manifest or authorize a substitute file.

The root map resolves physical files to those logical originals and checks byte lengths/SHA256. Build/proof wrappers then execute preserved tooling with the original path identities in the reproduction capsule. This also keeps Solidity source-unit metadata and library links stable. Direct compilation under new filenames is not evidence of reproducing the frozen bytecode.

For historical comparison, the preserved RC.2 identities are:

| Item | SHA256 |
| --- | --- |
| Core artifact | `6bea6c23a5a6e80aec8411d8269978a584058e40a4cdf14e4eb231e4f7b7f41e` |
| Fee artifact | `52f71b538b613ec315727afce2eb4f86604adcce698be58a1ff12d8ab256a36a` |
| Release inventory | `abbb1064147919a7936569cd6f8105b39f885835ba19c002be75960b69aa58e3` |

Older release snapshots and extraction/change records remain historical provenance in the capsule and original tags. An older successful report cannot certify arbitrary changed source. A review-tree edit without a separately identified release must fail the binding check.

## Circuit statements and tooling

The system uses Groth16 over BN128, two note inputs/two outputs, current-note association membership and depth-20 Merkle trees. JoinSplit has nine public inputs, holder exit has five. Holder exit does not require ASP membership. Circuit/manifests specify the exact ordering.

The recorded compiler stack is `circom2@0.2.22` containing Circom 2.2.2, `circomlib@2.0.5` and `snarkjs@0.7.5`, with optimization `O2`. The pinned Circomlib include closure contains Poseidon, constants, comparators, bitify, aliascheck, binsum and compconstant sources. Compiler/tool and source digests are retained in the capsule.

| Circuit | R1CS SHA256 | Witness WASM SHA256 |
| --- | --- | --- |
| JoinSplit | `f5e6448b8c432cd28027f9b6f09f3ae1721c0648caf1a54b1368caced6bc5f2d` | `54dd12b723c5a3da1b3bae05b554404aa13b3cbaedbbd07f08a26957a6294fdf` |
| Holder exit | `899c9e5e9feb4db2184cd14a0d0f44b0a552abc706879a238e4bf67df8d4f87b` | `fb570f26df068248b980b0460bb13ce5fc886462201206fcdafea26e6901ae3f` |

The final computations match the previously tested circuit computation; final keys are separately contributed keys. Matching an old R1CS is not permission to replace the final zkey. Legacy comments are preserved source bytes, not evidence that an initial development/setup key is a production key. Deposit caps, pause and selected fees retain these circuit statements and do not require another contribution ceremony.

## Public transcript and final key identity

The power-15 transcript is available from the [public source](https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_15.ptau) and reviewed at `zk/parameters/powersOfTau28_hez_final_15.ptau`.

| Property | Value |
| --- | --- |
| Bytes | `37831832` |
| SHA256 | `3ef2ecc5b75d687048cf2d59195119b42fb07c5af639c5f283d84bfa69829e7f` |
| BLAKE2b-512 | `982372c867d229c236091f767e703253249a9b432c1710b4f326306bfa2428a17b06240359606cfe4d580b10a5a1f63fbed499527069c18ae17060472969ae6e` |

Each final zkey contains two non-beacon records followed by a beacon. Recorded labels `lincoln-local-20261016` and `leo-independent-20261016` are transcript labels, not authenticated identities or a count of independently controlled machines. Parent keys and public beacon records are retained in `zk/ceremony/`.

The public [beacon commitment at an immutable revision](https://raw.githubusercontent.com/lincoln-protocol/beacon/1229e4e1a0259bce86fa6b5c4edc030b3069eea5/artifacts/phase2-ceremony/beacon-commitment.json) records the precommitment. The final beacon hash is `0x5b9e2e64568bf74f5892c0d26211590d3159ddcca3b6c3a922abbc940ed48ed1`, with SnarkJS iteration exponent **20**. Observations record Ethereum mainnet and two RPC hosts; they are not a consensus light-client proof or an independent timestamp attestation.

The beacon repository moved from `LincolnProtocol-com/beacon` to `lincoln-protocol/beacon` on 2026-10-22 with its full history, so the commit and the file bytes are identical. Records under `releases/`, `audit/` and `zk/ceremony/` keep the original URL as published.

| Circuit | Final zkey SHA256 | Final manifest SHA256 |
| --- | --- | --- |
| JoinSplit | `36a228e5cf8b81e6930bcb42b82fb60bbfa2fe7e7039d450b1e49e2fa31059ed` | `ff7dd97461c7190b13808add36cc73254f0c1b1c9b3bb03cceb39d3019bd59b0` |
| Holder exit | `d17b8e06b15c48b97dc4dc18a1d0a89014fbc4d807c222792edda7f271d500d3` | `b80c9987281b10a20697511b31716bd2c1fd6c0b08887ad6c7af4cb8f64b0cba` |

Verification checks final-key consistency against R1CS/ptau, embedded contribution records, exported verification keys and generated Solidity. The only recorded verifier-source transformations are the builder's deterministic pragma and contract-name changes; the readable layout adds none.

## Assurance limits and reproduction

The recorded assurance fields remain false:

```json
{
  "independentOperatorIdentityAuthenticated": false,
  "publicPrecommitTimingCryptographicallyAuthenticated": false
}
```

Hash checks prove byte identity. SnarkJS checks mathematical consistency and contribution-chain structure. Neither authenticates contributor independence, honest entropy generation, destroyed toxic waste, uncompromised machines, publication before the future block became predictable or completed independent audit.

The capsule retains final public materials and required pinned tooling records, not every historical ceremony working file or installed tool tree. It supports verification of this packaged candidate and its public bindings; it must not be described as a complete replay of every historical ceremony-stage check.

```sh
npm run check
npm run build
npm run check:circuits
npm run test:proofs
```

Run these at the repository root. Actual-proof acceptance uses fresh local chains. RC.3 requires a new run against its new pool bytecode; the recorded RC.2 results below are historical only: 11 native proofs/48 transactions plus four fee proofs/73 transactions, totaling 15 proofs and 121 local transactions. Fee liquidity/router/token fixtures are mocks. Contract fuzz tests with accepting verifier mocks are separate evidence. None establishes live mainnet execution, real market liquidity or measured anonymity.

See [tests](../test/README.md) for report scope and [releases](../releases/README.md) for original-path reproduction. New runs must retain their own identity and must not overwrite preserved release reports.

The approved seven-stock integer caps are operational constructor configuration, not a circuit change. Stock fork/DEX acceptance remains pending. Both original libraries are now confirmed in the shared signer ledger; this does not establish a completed RC.3 mainnet deployment.
