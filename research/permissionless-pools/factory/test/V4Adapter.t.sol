// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {Phase2ASPPool} from 'rc3/Phase2ASPPool.sol';
import {Phase2ASPRegistry} from 'rc3/Phase2ASPRegistry.sol';
import {IPhase2RouteSourcePool} from 'rc3/Phase2RouteAdapter.sol';
import {Phase2FeeV4Adapter} from '../src/Phase2FeeV4Adapter.sol';
import {MockV4PoolManager, V4MockToken, V4TaxToken, V4NoReceive} from './mocks/V4Mocks.sol';

/// @dev Minimal cheatcode surface; forge-std is not vendored in this repository.
interface Vm {
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function chainId(uint256) external;
    function prank(address) external;
    function deal(address, uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert() external;
}

/// @dev Accepts every proof: these tests cover adapter accounting and authorization, not circuits.
contract V4MockJoinSplitVerifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[9] calldata)
        external pure returns (bool) { return true; }
}

contract V4MockExitVerifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external pure returns (bool) { return true; }
}

contract V4AdapterTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
    uint256 internal constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    address internal constant PROVIDER = address(0xA5B);
    address internal constant GUARDIAN = address(0x6A2D);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant HOOK = address(0x4B00C);
    uint256 internal constant START = 1_800_000_000;
    uint16 internal constant BPS = 30;
    uint160 internal constant PRICE = 79228162514264337593543950336; // 1:1
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    error AssertionFailed(string message);

    Phase2ASPRegistry internal registry;
    V4MockJoinSplitVerifier internal verifier;
    V4MockExitVerifier internal exitVerifier;
    MockV4PoolManager internal manager;
    V4MockToken internal meme;
    V4MockToken internal usd;
    Phase2ASPPool internal ethPool;
    Phase2ASPPool internal memePool;
    Phase2ASPPool internal usdPool;
    Phase2FeeV4Adapter internal buyNative;  // ETH pool -> meme pool, ETH is currency0: zeroForOne
    Phase2FeeV4Adapter internal sellNative; // meme pool -> ETH pool, native output
    Phase2FeeV4Adapter internal buyErc20;   // usd pool -> meme pool
    Phase2FeeV4Adapter.PoolKey internal nativeKey;
    Phase2FeeV4Adapter.PoolKey internal erc20Key;
    uint256 internal nonce;

    struct Prepared {
        Phase2FeeV4Adapter.Action action;
        Phase2FeeV4Adapter.Proof proof;
        IPhase2RouteSourcePool.ExtData data;
        bytes[2] out;
    }

    receive() external payable {}

    function setUp() public {
        vm.chainId(4663);
        vm.warp(START);
        registry = new Phase2ASPRegistry(PROVIDER, GUARDIAN);
        verifier = new V4MockJoinSplitVerifier();
        exitVerifier = new V4MockExitVerifier();
        manager = new MockV4PoolManager();
        meme = new V4MockToken('MEME');
        usd = new V4MockToken('USD');
        ethPool = newPool(address(0));
        memePool = newPool(address(meme));
        usdPool = newPool(address(usd));
        nativeKey = Phase2FeeV4Adapter.PoolKey(address(0), address(meme), 10_000, 200, HOOK);
        erc20Key = address(meme) < address(usd)
            ? Phase2FeeV4Adapter.PoolKey(address(meme), address(usd), 3000, 60, HOOK)
            : Phase2FeeV4Adapter.PoolKey(address(usd), address(meme), 3000, 60, HOOK);
        init(nativeKey);
        init(erc20Key);
        buyNative = deploy(ethPool, memePool, nativeKey, BPS, TREASURY);
        sellNative = deploy(memePool, ethPool, nativeKey, BPS, TREASURY);
        buyErc20 = deploy(usdPool, memePool, erc20Key, BPS, TREASURY);
        vm.prank(PROVIDER);
        registry.updateRoot(1, keccak256('root'), uint64(START + 7 days));
        vm.deal(address(this), 1_000_000 ether);
        vm.deal(address(manager), 1_000_000 ether);
        meme.mint(address(manager), 1e36);
        usd.mint(address(manager), 1e36);
    }

    // ---------- helpers ----------

    function check(bool condition, string memory message) internal pure { if (!condition) revert AssertionFailed(message); }
    function eq(uint256 a, uint256 b, string memory message) internal pure { if (a != b) revert AssertionFailed(message); }
    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) { return min + x % (max - min + 1); }
    function now_() internal view returns (uint256) { return vm.getBlockTimestamp(); }

    function cipher(uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(256);
        bytes32 word = keccak256(abi.encode(seed));
        assembly ('memory-safe') { mstore(add(out, 0x20), word) }
    }

    function newPool(address asset) internal returns (Phase2ASPPool) {
        return new Phase2ASPPool(address(verifier), address(exitVerifier), address(registry), asset, type(uint128).max, type(uint128).max);
    }

    function init(Phase2FeeV4Adapter.PoolKey memory key) internal {
        manager.initialize(MockV4PoolManager.PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks), PRICE);
    }

    function deploy(Phase2ASPPool from, Phase2ASPPool to, Phase2FeeV4Adapter.PoolKey memory key, uint16 bps, address treasury)
        internal returns (Phase2FeeV4Adapter)
    {
        return new Phase2FeeV4Adapter(address(from), address(to), address(manager), key, bps, treasury);
    }

    function bal(address asset, address who) internal view returns (uint256) {
        return asset == address(0) ? who.balance : IERC20(asset).balanceOf(who);
    }

    function fund(Phase2ASPPool pool, uint128 value) internal {
        address asset = pool.ASSET();
        if (asset == address(0)) {
            pool.depositDynamic{value: value}(value, ++nonce, cipher(nonce));
        } else {
            V4MockToken(asset).mint(address(this), value);
            IERC20(asset).approve(address(pool), value);
            pool.depositDynamic(value, ++nonce, cipher(nonce));
        }
    }

    function prepare(Phase2FeeV4Adapter a, uint128 noteValue, uint128 amountIn, uint128 minNet, uint128 maxFee)
        internal returns (Prepared memory p)
    {
        Phase2ASPPool pool = Phase2ASPPool(payable(address(a.SOURCE_POOL())));
        fund(pool, noteValue);
        p.action = Phase2FeeV4Adapter.Action({processor: address(this), amountIn: amountIn, minAmountOut: minNet,
            deadline: now_() + 1 hours, targetPrecommitment: ++nonce, encryptedTemplate: cipher(nonce), maxServiceFee: maxFee});
        p.out[0] = cipher(++nonce);
        p.out[1] = a.actionEnvelope(p.action);
        p.data = IPhase2RouteSourcePool.ExtData({recipient: address(a), feeRecipient: address(0),
            processor: address(a), publicIn: 0, publicOut: amountIn, fee: 0});
        Phase2ASPPool.ExtData memory poolData = Phase2ASPPool.ExtData({recipient: address(a), feeRecipient: address(0),
            processor: address(a), publicIn: 0, publicOut: amountIn, fee: 0});
        uint128 change = noteValue - amountIn;
        p.proof.pubSignals = [pool.currentRoot(), 0, uint256(amountIn), pool.hashContext(poolData, p.out), pool.SCOPE(),
            ++nonce, ++nonce, change == 0 ? 0 : ++nonce, 0];
    }

    function reenvelope(Phase2FeeV4Adapter a, Prepared memory p) internal view {
        Phase2ASPPool pool = Phase2ASPPool(payable(address(a.SOURCE_POOL())));
        p.out[1] = a.actionEnvelope(p.action);
        Phase2ASPPool.ExtData memory poolData = Phase2ASPPool.ExtData({recipient: p.data.recipient, feeRecipient: p.data.feeRecipient,
            processor: p.data.processor, publicIn: p.data.publicIn, publicOut: p.data.publicOut, fee: p.data.fee});
        p.proof.pubSignals[3] = pool.hashContext(poolData, p.out);
    }

    function run(Phase2FeeV4Adapter a, Prepared memory p) internal returns (uint256, uint256) {
        return a.swap(p.action, p.proof, p.data, p.out);
    }

    function feeOf(uint256 gross) internal pure returns (uint256) { return gross * BPS / 10_000; }

    // ---------- constructor ----------

    function test_constructorBindsKeyAndDirection() public view {
        check(buyNative.ZERO_FOR_ONE() && !sellNative.ZERO_FOR_ONE(), 'direction');
        eq(buyNative.SQRT_PRICE_LIMIT_X96(), MIN_SQRT_PRICE + 1, 'zeroForOne limit');
        eq(sellNative.SQRT_PRICE_LIMIT_X96(), MAX_SQRT_PRICE - 1, 'oneForZero limit');
        check(buyNative.POOL_ID() == keccak256(abi.encode(nativeKey)), 'pool id');
        check(buyNative.INPUT() == address(0) && buyNative.OUTPUT() == address(meme), 'buy assets');
        check(sellNative.INPUT() == address(meme) && sellNative.OUTPUT() == address(0), 'sell assets');
        Phase2FeeV4Adapter.PoolKey memory k = buyNative.poolKey();
        check(k.currency0 == nativeKey.currency0 && k.currency1 == nativeKey.currency1 && k.fee == nativeKey.fee
            && k.tickSpacing == nativeKey.tickSpacing && k.hooks == nativeKey.hooks, 'key');
        check(buyErc20.ZERO_FOR_ONE() == (address(usd) == erc20Key.currency0), 'erc20 direction');
    }

    function test_constructorRejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert(Phase2FeeV4Adapter.UnsupportedChainId.selector);
        deploy(ethPool, memePool, nativeKey, BPS, TREASURY);
    }

    function test_constructorRejectsBadPools() public {
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        deploy(ethPool, ethPool, nativeKey, BPS, TREASURY);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        new Phase2FeeV4Adapter(address(0xBEEF), address(memePool), address(manager), nativeKey, BPS, TREASURY);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        new Phase2FeeV4Adapter(address(ethPool), address(memePool), address(0xBEEF), nativeKey, BPS, TREASURY);
        // Assets do not match the key.
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        deploy(usdPool, memePool, nativeKey, BPS, TREASURY);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        deploy(ethPool, usdPool, nativeKey, BPS, TREASURY);
        // Unsorted key.
        Phase2FeeV4Adapter.PoolKey memory flipped = Phase2FeeV4Adapter.PoolKey(address(meme), address(0), 10_000, 200, HOOK);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidRoute.selector);
        deploy(ethPool, memePool, flipped, BPS, TREASURY);
    }

    function test_constructorRejectsUninitializedPool() public {
        Phase2FeeV4Adapter.PoolKey memory other = Phase2FeeV4Adapter.PoolKey(address(0), address(meme), 3000, 60, HOOK);
        vm.expectRevert(Phase2FeeV4Adapter.PoolNotInitialized.selector);
        deploy(ethPool, memePool, other, BPS, TREASURY);
        init(other);
        deploy(ethPool, memePool, other, BPS, TREASURY);
    }

    function test_constructorRejectsBadFeeAndTreasury() public {
        vm.expectRevert(Phase2FeeV4Adapter.InvalidServiceFee.selector);
        deploy(ethPool, memePool, nativeKey, 0, TREASURY);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidServiceFee.selector);
        deploy(ethPool, memePool, nativeKey, 101, TREASURY);
        deploy(ethPool, memePool, nativeKey, 100, TREASURY);
        address[6] memory bad = [address(0), address(ethPool), address(memePool), address(manager), address(meme), HOOK];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Phase2FeeV4Adapter.InvalidServiceFee.selector);
            deploy(ethPool, memePool, nativeKey, BPS, bad[i]);
        }
    }

    function test_actionHashLayout() public view {
        Phase2FeeV4Adapter.Action memory a = Phase2FeeV4Adapter.Action(address(this), 5, 4, 6, 7, cipher(1), 3);
        bytes32 expected = keccak256(abi.encode(keccak256('LINCOLN_PHASE2_FEE_V4_ROUTES_V1'), uint256(4663), address(buyNative),
            address(ethPool), address(memePool), address(manager), keccak256(abi.encode(nativeKey)), address(0), address(meme),
            uint24(10_000), int24(200), HOOK, true, BPS, TREASURY, address(this), uint128(5), uint128(4), uint256(6), uint256(7),
            keccak256(cipher(1)), uint128(3)));
        check(buyNative.actionHash(a) == expected, 'action hash layout');
        check(sellNative.actionHash(a) != buyNative.actionHash(a), 'adapters do not share actions');
        bytes memory env = buyNative.actionEnvelope(a);
        eq(env.length, 256, 'envelope length');
    }

    // ---------- action / proof validation ----------

    function test_rejectsWrongProcessor() public {
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(Phase2FeeV4Adapter.InvalidProcessor.selector);
        buyNative.swap(p.action, p.proof, p.data, p.out);
    }

    function test_rejectsExpired() public {
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.warp(p.action.deadline + 1);
        vm.expectRevert(Phase2FeeV4Adapter.ExpiredSwap.selector);
        run(buyNative, p);
    }

    function test_rejectsAmountAboveInt128() public {
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        p.action.amountIn = uint128(type(int128).max) + 1;
        vm.expectRevert(Phase2FeeV4Adapter.InvalidSwapAmount.selector);
        run(buyNative, p);
    }

    function test_rejectsTamperedEnvelopeAndExtData() public {
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        p.action.minAmountOut = 0.5 ether; // the proof's envelope still binds 1 wei
        vm.expectRevert(Phase2FeeV4Adapter.ActionMismatch.selector);
        run(buyNative, p);
        p.action.minAmountOut = 1;
        p.out[1] = sellNative.actionEnvelope(p.action); // another adapter's envelope
        vm.expectRevert(Phase2FeeV4Adapter.ActionMismatch.selector);
        run(buyNative, p);
        p.out[1] = buyNative.actionEnvelope(p.action);
        p.data.recipient = address(this);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidSourceAuthorization.selector);
        run(buyNative, p);
    }

    // ---------- callback access control ----------

    function test_callbackOnlyFromManagerWhileArmed() public {
        bytes memory payload = abi.encode(bytes32(uint256(1)), uint128(1));
        vm.expectRevert(Phase2FeeV4Adapter.InvalidCallback.selector);
        buyNative.unlockCallback(payload);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidCallback.selector);
        manager.poke(address(buyNative), payload);
    }

    function test_nestedCallbackReverts() public {
        manager.configure(manager.NESTED(), 1e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidCallback.selector);
        run(buyNative, p);
    }

    function test_tamperedCallbackPayloadReverts() public {
        manager.configure(manager.TAMPER(), 1e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidCallback.selector);
        run(buyNative, p);
    }

    function test_rejectsUnexpectedNative() public {
        (bool ok,) = address(buyNative).call{value: 1}('');
        check(!ok, 'native from a stranger accepted');
    }

    // ---------- settlement ----------

    function test_partialFillReverts() public {
        manager.configure(manager.PARTIAL(), 1e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.expectRevert(Phase2FeeV4Adapter.PartialFill.selector);
        run(buyNative, p);
        check(!ethPool.spentNullifiers(p.proof.pubSignals[5]), 'note stays unspent');
        manager.configure(manager.OVERSPEND(), 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.PartialFill.selector);
        run(buyNative, p);
        manager.configure(manager.WRONG_SIGN(), 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.PartialFill.selector);
        run(buyNative, p);
        manager.configure(manager.ZERO_OUT(), 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.InvalidSwapDelta.selector);
        run(buyNative, p);
    }

    function test_falseSettleReturnReverts() public {
        manager.configure(manager.SHORT_SETTLE(), 1e18);
        Prepared memory p = prepare(buyErc20, 10e18, 5e18, 1, 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.SettlementMismatch.selector);
        run(buyErc20, p);
    }

    function test_donatedOutputReverts() public {
        manager.configure(manager.DONATE(), 1e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 1 ether);
        vm.expectRevert(Phase2FeeV4Adapter.UnexpectedBalanceDelta.selector);
        run(buyNative, p);
        p = prepare(sellNative, 2e18, 1e18, 1, 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.UnexpectedBalanceDelta.selector);
        run(sellNative, p);
    }

    function test_feeCapAndMinOut() public {
        manager.configure(0, 2e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1 ether, 1, 0.006 ether - 1); // fee is 0.006
        vm.expectRevert(Phase2FeeV4Adapter.ServiceFeeAboveLimit.selector);
        run(buyNative, p);
        p = prepare(buyNative, 2 ether, 1 ether, 1.994 ether + 1, 1 ether); // net is 1.994
        vm.expectRevert(Phase2FeeV4Adapter.InvalidSwapAmount.selector);
        run(buyNative, p);
        p = prepare(buyNative, 2 ether, 1 ether, 1.994 ether, 0.006 ether);
        (uint256 net,) = run(buyNative, p);
        eq(net, 1.994 ether, 'exact minimum accepted');
    }

    function test_feeOnTransferInputReverts() public {
        V4TaxToken tax = new V4TaxToken();
        Phase2ASPPool taxPool = newPool(address(tax));
        Phase2FeeV4Adapter.PoolKey memory key = Phase2FeeV4Adapter.PoolKey(address(0), address(tax), 3000, 60, address(0));
        init(key);
        Phase2FeeV4Adapter a = deploy(taxPool, ethPool, key, BPS, TREASURY);
        tax.mint(address(this), 10e18);
        tax.approve(address(taxPool), 10e18);
        taxPool.depositDynamic(10e18, ++nonce, cipher(nonce));
        tax.setTaxed(address(manager), address(0)); // only transfers into the manager are taxed
        Prepared memory p;
        p.action = Phase2FeeV4Adapter.Action(address(this), 5e18, 1, now_() + 1 hours, ++nonce, cipher(nonce), 1e18);
        p.out[0] = cipher(++nonce);
        p.out[1] = a.actionEnvelope(p.action);
        p.data = IPhase2RouteSourcePool.ExtData(address(a), address(0), address(a), 0, 5e18, 0);
        p.proof.pubSignals = [taxPool.currentRoot(), 0, 5e18, 0, taxPool.SCOPE(), ++nonce, ++nonce, ++nonce, 0];
        reenvelope(a, p);
        vm.expectRevert(Phase2FeeV4Adapter.SettlementMismatch.selector);
        run(a, p);
    }

    function test_feeOnTransferOutputReverts() public {
        V4TaxToken tax = new V4TaxToken();
        Phase2ASPPool taxPool = newPool(address(tax));
        Phase2FeeV4Adapter.PoolKey memory key = Phase2FeeV4Adapter.PoolKey(address(0), address(tax), 3000, 60, address(0));
        init(key);
        Phase2FeeV4Adapter a = deploy(ethPool, taxPool, key, BPS, TREASURY);
        tax.mint(address(manager), 1e30);
        tax.setTaxed(address(0), address(manager)); // the manager's take delivers less than reported
        Prepared memory p = prepare(a, 2 ether, 1 ether, 1, 1 ether);
        vm.expectRevert(Phase2FeeV4Adapter.UnexpectedBalanceDelta.selector);
        run(a, p);
    }

    function test_nativeOutputTreasuryMustAcceptEth() public {
        V4NoReceive sink = new V4NoReceive();
        Phase2FeeV4Adapter a = deploy(memePool, ethPool, nativeKey, BPS, address(sink));
        Prepared memory p = prepare(a, 2e18, 1e18, 1, 1e18);
        vm.expectRevert(Phase2FeeV4Adapter.NativeTransferFailed.selector);
        run(a, p);
    }

    // ---------- success paths ----------

    function test_nativeInputBuy() public {
        manager.configure(0, 3e18);
        Prepared memory p = prepare(buyNative, 2 ether, 1.5 ether, 4 ether, 1 ether);
        uint256 sourceBefore = address(ethPool).balance;
        (uint256 net, uint256 commitment) = run(buyNative, p);
        uint256 gross = 4.5 ether;
        eq(net, gross - feeOf(gross), 'net');
        eq(meme.balanceOf(TREASURY), feeOf(gross), 'fee in meme');
        eq(meme.balanceOf(address(memePool)), net, 'target custody');
        eq(address(ethPool).balance, sourceBefore - 1.5 ether, 'source custody');
        eq(commitment, PoseidonT3.hash([net, p.action.targetPrecommitment]), 'note value is net');
        check(memePool.commitments(commitment) && ethPool.spentNullifiers(p.proof.pubSignals[5]), 'note moved');
        check(manager.lastZeroForOne() && manager.lastLimit() == MIN_SQRT_PRICE + 1, 'direction and limit');
        check(manager.lastAmountSpecified() == -1.5 ether && manager.lastHookDataLength() == 0, 'exact input, no hook data');
        check(manager.lastPoolId() == buyNative.POOL_ID(), 'pinned key');
        eq(address(buyNative).balance + meme.balanceOf(address(buyNative)), 0, 'adapter empty');
        eq(meme.allowance(address(buyNative), address(memePool)), 0, 'allowance cleared');
    }

    function test_nativeOutputSell() public {
        manager.configure(0, 0.25e18);
        Prepared memory p = prepare(sellNative, 8e18, 8e18, 1.9 ether, 0.01 ether);
        uint256 targetBefore = address(ethPool).balance;
        (uint256 net, uint256 commitment) = run(sellNative, p);
        eq(net, 2 ether - feeOf(2 ether), 'net');
        eq(TREASURY.balance, feeOf(2 ether), 'native fee to treasury');
        eq(address(ethPool).balance, targetBefore + net, 'target custody');
        check(ethPool.commitments(commitment), 'native note');
        check(!manager.lastZeroForOne() && manager.lastLimit() == MAX_SQRT_PRICE - 1, 'direction and limit');
        eq(address(sellNative).balance + meme.balanceOf(address(sellNative)), 0, 'adapter empty');
    }

    function test_erc20Pair() public {
        manager.configure(0, 1.5e18);
        Prepared memory p = prepare(buyErc20, 10e18, 4e18, 5e18, 1e18);
        (uint256 net,) = run(buyErc20, p);
        eq(net, 6e18 - feeOf(6e18), 'net');
        eq(meme.balanceOf(TREASURY), feeOf(6e18), 'fee');
        eq(usd.balanceOf(address(usdPool)), 6e18, 'source keeps change');
        eq(usd.balanceOf(address(buyErc20)) + meme.balanceOf(address(buyErc20)), 0, 'adapter empty');
    }

    /// Against a misbehaving manager: either everything balances to the wei,
    /// or the whole transaction, including the source spend, reverts.
    function testFuzz_exactOrReverts(uint128 noteValue, uint128 amountIn, uint256 rate, uint128 minNet,
        uint128 maxFee, uint8 mode, bool sell) public
    {
        Phase2FeeV4Adapter a = sell ? sellNative : buyNative;
        noteValue = uint128(bound(noteValue, 2, 100 ether));
        amountIn = uint128(bound(amountIn, 1, noteValue));
        rate = bound(rate, 0, 5e18);
        minNet = uint128(bound(minNet, 1, uint256(amountIn) * 5));
        maxFee = uint128(bound(maxFee, 0, uint256(amountIn) * 5 / 100));
        uint8[7] memory modes = [0, 1, 2, 3, 5, 6, 8];
        mode = modes[bound(mode, 0, 6)];
        manager.configure(mode, rate);
        Prepared memory p = prepare(a, noteValue, amountIn, minNet, maxFee);
        uint256 gross = mode == 5 ? 0 : uint256(amountIn) * rate / 1e18;
        uint256 fee = feeOf(gross);
        bool shouldSucceed = mode == 0 && gross != 0
            && gross - fee >= minNet && fee <= maxFee;
        Phase2ASPPool source = Phase2ASPPool(payable(address(a.SOURCE_POOL())));
        address output = a.OUTPUT();
        uint256 targetBefore = bal(output, address(a.TARGET_POOL()));
        uint256 sourceBefore = bal(a.INPUT(), address(source));
        uint256 treasuryBefore = bal(output, TREASURY);
        try a.swap(p.action, p.proof, p.data, p.out) returns (uint256 net, uint256 commitment) {
            check(shouldSucceed, 'adapter accepted a short, padded, under-minimum or over-fee swap');
            eq(net, gross - fee, 'net is measured gross minus floor fee');
            eq(bal(output, TREASURY), treasuryBefore + fee, 'treasury receives exactly the fee');
            eq(bal(output, address(a.TARGET_POOL())), targetBefore + net, 'target custody');
            eq(commitment, PoseidonT3.hash([net, p.action.targetPrecommitment]), 'target note value is net');
            eq(bal(a.INPUT(), address(source)), sourceBefore - amountIn, 'source custody');
            check(source.spentNullifiers(p.proof.pubSignals[5]), 'source spent');
        } catch {
            check(!shouldSucceed, 'valid swap reverted');
            eq(bal(output, TREASURY), treasuryBefore, 'no fee on failure');
            eq(bal(output, address(a.TARGET_POOL())), targetBefore, 'atomic target');
            eq(bal(a.INPUT(), address(source)), sourceBefore, 'atomic source');
            check(!source.spentNullifiers(p.proof.pubSignals[5]), 'atomic nullifier');
        }
        eq(address(a).balance + meme.balanceOf(address(a)), 0, 'adapter holds nothing');
    }
}
