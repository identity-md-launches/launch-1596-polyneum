// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Ghost-accounted handler for Polyneum. Two layers, after the fizz handler pattern:
///         - unclamped (`*Raw`): arbitrary receivers, spenders and amounts. Each call predicts the
///           outcome from the ERC-20 rules before the call and records a violation if the token
///           disagrees (wrong success, wrong revert, wrong error data). These are the failure paths.
///         - clamped: inputs bounded so the call succeeds, plus stress variants pinned to the
///           boundaries (full balance, one wei, zero, the unlimited allowance sentinel).
///         Ghost variables track every address that ever held or was sent tokens, the tokens that
///         flowed in and out of each, and the allowance every (owner, spender) pair should have.
///         The token never calls out, so no address needs excluding.
contract PolyneumGhostHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Polyneum public immutable token;
    address public immutable deployer;

    address[] public actors;

    // ---- ghosts ---------------------------------------------------------------------------------
    address[] public touched;
    mapping(address => bool) public isTouched;
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;

    address[] public pairOwners;
    address[] public pairSpenders;
    mapping(address => mapping(address => bool)) public pairSeen;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public violations;
    string public lastViolation;

    // ---- call accounting (for coverage sanity, not for assertions) ------------------------------
    uint256 public okTransfers;
    uint256 public revertedTransfers;
    uint256 public okApprovals;
    uint256 public revertedApprovals;
    uint256 public okTransferFroms;
    uint256 public revertedTransferFroms;
    uint256 public privilegedAttempts;
    uint256 public unknownSelectorAttempts;
    uint256 public etherAttempts;

    string[22] internal privilegedSignatures = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "unpause()",
        "setMinter(address)",
        "pause()",
        "blacklist(address)",
        "blocklist(address)",
        "freeze(address)",
        "freezeAccount(address)",
        "setBlacklist(address,bool)",
        "setBlocked(address,bool)",
        "lock(address)",
        "disableTransfers()",
        "setTransfersEnabled(bool)",
        "burnFrom(address,uint256)",
        "seize(address)"
    ];

    constructor(Polyneum token_, address deployer_, address[] memory actors_) {
        token = token_;
        deployer = deployer_;
        actors = actors_;
        _touch(deployer_);
        for (uint256 i; i < actors_.length; ++i) {
            _touch(actors_[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function pairCount() external view returns (uint256) {
        return pairOwners.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev What `account` should hold: the mint (deployer only) plus everything received minus
    ///      everything sent.
    function expectedBalance(address account) public view returns (uint256) {
        uint256 base = account == deployer ? SUPPLY : 0;
        return base + ghostIn[account] - ghostOut[account];
    }

    // ---------------------------------------------------------------------------------------------
    // Unclamped: arbitrary inputs, predicted outcome, failure paths asserted exactly
    // ---------------------------------------------------------------------------------------------

    function transferRaw(uint256 fromSeed, address to, uint256 amount) external {
        address from = _actor(fromSeed);
        _transferExpecting(from, to, amount);
    }

    function approveRaw(uint256 ownerSeed, address spender, uint256 amount) external {
        address owner = _actor(ownerSeed);
        _approveExpecting(owner, spender, amount);
    }

    function transferFromRaw(uint256 ownerSeed, uint256 spenderSeed, address to, uint256 amount) external {
        _transferFromExpecting(_actor(ownerSeed), _actor(spenderSeed), to, amount);
    }

    /// @dev A spender who was never approved by anyone (an address outside the actor set).
    function transferFromByStranger(uint256 ownerSeed, address stranger, uint256 toSeed, uint256 amount) external {
        _transferFromExpecting(_actor(ownerSeed), stranger, _actor(toSeed), amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Clamped: bounded to succeed, so the sequence moves value around
    // ---------------------------------------------------------------------------------------------

    function transferClamped(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transferExpecting(from, _actor(toSeed), amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transferExpecting(from, _actor(toSeed), token.balanceOf(from));
    }

    function transferOneWei(uint256 fromSeed, uint256 toSeed) external {
        _transferExpecting(_actor(fromSeed), _actor(toSeed), 1);
    }

    function transferZero(uint256 fromSeed, uint256 toSeed) external {
        _transferExpecting(_actor(fromSeed), _actor(toSeed), 0);
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        uint256 bal = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - bal);
        _transferExpecting(from, _actor(toSeed), bal + excess);
    }

    function approveClamped(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        amount = bound(amount, 0, SUPPLY);
        _approveExpecting(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function approveMax(uint256 ownerSeed, uint256 spenderSeed) external {
        _approveExpecting(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    function approveMaxMinusOne(uint256 ownerSeed, uint256 spenderSeed) external {
        _approveExpecting(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max - 1);
    }

    function approveZero(uint256 ownerSeed, uint256 spenderSeed) external {
        _approveExpecting(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFromClamped(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        if (bal < cap) cap = bal;
        amount = bound(amount, 0, cap);
        _transferFromExpecting(owner, spender, _actor(toSeed), amount);
    }

    /// @dev Spend exactly the whole allowance (or the whole balance if that is smaller).
    function transferFromExactAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        if (bal < cap) cap = bal;
        _transferFromExpecting(owner, spender, _actor(toSeed), cap);
    }

    /// @dev One wei past the allowance must fail without touching anything.
    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return;
        _transferFromExpecting(owner, spender, _actor(toSeed), allowed + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Hostile surface: nothing here may ever succeed
    // ---------------------------------------------------------------------------------------------

    function privilegedCall(uint256 callerSeed, uint256 sigSeed, address target, uint256 value) external {
        address caller = _actor(callerSeed);
        string memory sig = privilegedSignatures[sigSeed % privilegedSignatures.length];
        bytes memory data = abi.encodeWithSignature(sig, target, value);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ++privilegedAttempts;
        if (ok) _violation(string.concat("privileged call succeeded: ", sig));
    }

    function unknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata tail) external {
        if (_isKnownSelector(selector)) return;
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(abi.encodePacked(selector, tail));
        ++unknownSelectorAttempts;
        if (ok) _violation("unknown selector did not revert");
    }

    function sendEther(uint256 callerSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        amount = bound(amount, 0, 100 ether);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}("");
        ++etherAttempts;
        if (ok) _violation("ether was accepted");
        if (address(token).balance != 0) _violation("token holds ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: predict, call, compare, account
    // ---------------------------------------------------------------------------------------------

    function _transferExpecting(address from, address to, uint256 amount) private {
        uint256 fromBal = token.balanceOf(from);
        bytes memory want;
        if (to == address(0)) {
            want = abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0));
        } else if (fromBal < amount) {
            want = abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, from, fromBal, amount);
        }

        uint256 toBal = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            ++okTransfers;
            if (want.length != 0) _violation("transfer succeeded where it should have reverted");
            if (!ok) _violation("transfer returned false");
            _recordMove(from, to, amount);
            _checkPostTransfer(from, to, amount, fromBal, toBal);
        } catch (bytes memory got) {
            ++revertedTransfers;
            _checkRevert(got, want, "transfer");
            _checkUnchanged(from, to, fromBal, toBal);
        }
    }

    function _approveExpecting(address owner, address spender, uint256 amount) private {
        bytes memory want;
        if (spender == address(0)) want = abi.encodeWithSelector(Polyneum.InvalidSpender.selector, address(0));
        uint256 prior = token.allowance(owner, spender);

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            ++okApprovals;
            if (want.length != 0) _violation("approve succeeded where it should have reverted");
            if (!ok) _violation("approve returned false");
            _recordAllowance(owner, spender, amount);
            if (token.allowance(owner, spender) != amount) _violation("approve did not set the allowance");
        } catch (bytes memory got) {
            ++revertedApprovals;
            _checkRevert(got, want, "approve");
            if (token.allowance(owner, spender) != prior) _violation("failed approve changed the allowance");
        }
    }

    function _transferFromExpecting(address owner, address spender, address to, uint256 amount) private {
        uint256 allowed = token.allowance(owner, spender);
        uint256 ownerBal = token.balanceOf(owner);
        uint256 toBal = token.balanceOf(to);
        bool unlimited = allowed == type(uint256).max;

        bytes memory want;
        if (!unlimited && allowed < amount) {
            want = abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, spender, allowed, amount);
        } else if (to == address(0)) {
            want = abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0));
        } else if (ownerBal < amount) {
            want = abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, owner, ownerBal, amount);
        }

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            ++okTransferFroms;
            if (want.length != 0) _violation("transferFrom succeeded where it should have reverted");
            if (!ok) _violation("transferFrom returned false");
            _recordMove(owner, to, amount);
            if (!unlimited) _recordAllowance(owner, spender, allowed - amount);
            uint256 after_ = token.allowance(owner, spender);
            if (unlimited && after_ != type(uint256).max) _violation("unlimited allowance was decreased");
            if (!unlimited && after_ != allowed - amount) _violation("allowance not decreased by amount");
            _checkPostTransfer(owner, to, amount, ownerBal, toBal);
        } catch (bytes memory got) {
            ++revertedTransferFroms;
            _checkRevert(got, want, "transferFrom");
            _checkUnchanged(owner, to, ownerBal, toBal);
            if (token.allowance(owner, spender) != allowed) _violation("failed transferFrom changed the allowance");
        }
    }

    function _checkPostTransfer(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore)
        private
    {
        if (from == to) {
            if (token.balanceOf(from) != fromBefore) _violation("self-transfer changed the balance");
        } else {
            if (token.balanceOf(from) != fromBefore - amount) _violation("sender balance not decreased by amount");
            if (token.balanceOf(to) != toBefore + amount) _violation("receiver balance not increased by amount");
        }
    }

    function _checkUnchanged(address from, address to, uint256 fromBefore, uint256 toBefore) private {
        if (token.balanceOf(from) != fromBefore) _violation("failed call changed the sender balance");
        if (token.balanceOf(to) != toBefore) _violation("failed call changed the receiver balance");
    }

    function _checkRevert(bytes memory got, bytes memory want, string memory where) private {
        if (want.length == 0) {
            _violation(string.concat(where, " reverted where it should have succeeded"));
        } else if (keccak256(got) != keccak256(want)) {
            _violation(string.concat(where, " reverted with the wrong error"));
        }
    }

    function _recordMove(address from, address to, uint256 amount) private {
        _touch(from);
        _touch(to);
        ghostOut[from] += amount;
        ghostIn[to] += amount;
    }

    function _recordAllowance(address owner, address spender, uint256 amount) private {
        if (!pairSeen[owner][spender]) {
            pairSeen[owner][spender] = true;
            pairOwners.push(owner);
            pairSpenders.push(spender);
        }
        ghostAllowance[owner][spender] = amount;
    }

    function _touch(address account) private {
        if (!isTouched[account]) {
            isTouched[account] = true;
            touched.push(account);
        }
    }

    function _violation(string memory what) private {
        ++violations;
        lastViolation = what;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _isKnownSelector(bytes4 s) private pure returns (bool) {
        return s == Polyneum.transfer.selector || s == Polyneum.approve.selector || s == Polyneum.transferFrom.selector
            || s == bytes4(keccak256("balanceOf(address)")) || s == bytes4(keccak256("allowance(address,address)"))
            || s == bytes4(keccak256("totalSupply()")) || s == bytes4(keccak256("name()"))
            || s == bytes4(keccak256("symbol()")) || s == bytes4(keccak256("decimals()"))
            || s == bytes4(keccak256("INITIAL_SUPPLY()"));
    }
}

/// @notice Stateful properties over random sequences driven by `PolyneumGhostHandler`. Every handler
///         call is wrapped in try/catch and compared with its predicted outcome, so an unexpected
///         revert is a finding rather than noise: `fail-on-revert` is on.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract PolyneumGhostInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address constant DEPLOYER = address(0xFAC7);

    Polyneum token;
    PolyneumGhostHandler handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new Polyneum();

        address[] memory actors = new address[](6);
        actors[0] = DEPLOYER;
        actors[1] = address(0xA11CE);
        actors[2] = address(0xB0B);
        actors[3] = address(0xCA201);
        actors[4] = address(0xDA7E);
        actors[5] = address(0xE4E);

        handler = new PolyneumGhostHandler(token, DEPLOYER, actors);

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.transferRaw.selector;
        selectors[1] = handler.approveRaw.selector;
        selectors[2] = handler.transferFromRaw.selector;
        selectors[3] = handler.transferFromByStranger.selector;
        selectors[4] = handler.transferClamped.selector;
        selectors[5] = handler.transferAll.selector;
        selectors[6] = handler.transferOneWei.selector;
        selectors[7] = handler.transferZero.selector;
        selectors[8] = handler.transferAboveBalance.selector;
        selectors[9] = handler.approveClamped.selector;
        selectors[10] = handler.approveMax.selector;
        selectors[11] = handler.approveMaxMinusOne.selector;
        selectors[12] = handler.approveZero.selector;
        selectors[13] = handler.transferFromClamped.selector;
        selectors[14] = handler.transferFromExactAllowance.selector;
        selectors[15] = handler.transferFromAboveAllowance.selector;
        selectors[16] = handler.privilegedCall.selector;
        selectors[17] = handler.unknownSelector.selector;
        selectors[18] = handler.sendEther.selector;
        selectors[19] = handler.transferClamped.selector; // weight the value-moving path a little more

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Every per-call prediction held: no wrong success, no wrong revert, no wrong error data,
    ///      no state change on a failed call, no privileged or unknown call ever succeeded.
    function invariant_handlerSawNoViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @dev Conservation (T-01): the supply is fixed and is exactly the sum over every address that
    ///      ever held or was sent tokens, including arbitrary receivers outside the actor set.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function invariant_sumOfAllTouchedBalancesIsSupply() public view {
        uint256 n = handler.touchedCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY);
    }

    /// @dev Per-entity flow accounting: what each address holds is what it was minted plus what it
    ///      received minus what it sent. Nobody ends up with more than flowed in.
    function invariant_eachBalanceEqualsItsFlows() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.touched(i);
            assertEq(token.balanceOf(a), handler.expectedBalance(a));
            assertLe(token.balanceOf(a), SUPPLY);
        }
    }

    /// @dev Allowance accounting (T-05): every allowance the sequence set or spent is exactly what
    ///      the approve/transferFrom rules say it should be.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.pairCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.pairOwners(i);
            address spender = handler.pairSpenders(i);
            assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
        }
    }

    /// @dev Allowances only exist where an actor set them: a stranger never acquires one.
    function invariant_noAllowanceOutsideRecordedPairs() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                if (!handler.pairSeen(owner, spender)) assertEq(token.allowance(owner, spender), 0);
            }
        }
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }
}
