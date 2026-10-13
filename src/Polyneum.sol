// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Polyneum (POLYNEUM)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 POLYNEUM (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). There is no owner, no minter, no
///         pause, no blocklist and no fee on transfer: after construction the contract has no
///         privileged functions at all, and the supply can never grow.
/// @dev    Self-contained implementation of ERC-20 (EIP-20) with custom errors. It depends on no
///         external library so the deployed bytecode has no link placeholders.
contract Polyneum {
    // ---------------------------------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------------------------------

    /// @notice Token name.
    string public constant name = "Polyneum";

    /// @notice Token symbol.
    string public constant symbol = "POLYNEUM";

    /// @notice Decimal places.
    uint8 public constant decimals = 18;

    /// @notice The one and only supply: 1,000,000,000 whole tokens in minor units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // ERC-20 state
    // ---------------------------------------------------------------------------------------------

    /// @notice Total number of tokens in existence. Set once in the constructor and never changed.
    uint256 public immutable totalSupply;

    /// @notice Balance of each account.
    mapping(address account => uint256) public balanceOf;

    /// @notice Allowance granted by `owner` to `spender`.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------------
    // Events (EIP-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to spend `needed` of `owner`'s tokens but is allowed only `allowed`.
    error InsufficientAllowance(address spender, uint256 allowed, uint256 needed);

    /// @notice A transfer to the zero address. Burning is not supported; use a transfer to a
    ///         dedicated dead address if burning is ever wanted.
    error InvalidReceiver(address receiver);

    /// @notice An approval naming the zero address as spender.
    error InvalidSpender(address spender);

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the whole supply to the deployer. No arguments: nothing about this token is
    ///         configurable, so there is nothing to misconfigure.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `amount`.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance. An allowance of
    ///         `type(uint256).max` is treated as unlimited and is not decreased.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidReceiver(address(0));
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // Cannot underflow: checked just above. Cannot overflow: the sum of all balances is
            // bounded by totalSupply, which fits in uint256.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert InvalidSpender(address(0));
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}
