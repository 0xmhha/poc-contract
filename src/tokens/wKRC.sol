// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title wKRC (Wrapped Native Token)
 * @notice Wrapped native token implementation for Uniswap V3 compatibility
 * @dev Compatible with IWETH9 interface used by Uniswap V3
 *      Allows native coins to be used in ERC-20 only pools
 */
contract wKRC is ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The native token transfer has failed.
    error NativeTransferFailed();

    // Note: InsufficientBalance is inherited from solady's ERC20

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when native tokens are deposited.
    event Deposit(address indexed from, uint256 amount);

    /// @notice Emitted when wrapped tokens are withdrawn.
    event Withdrawal(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                             ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the name of the token.
    function name() public view virtual override returns (string memory) {
        return "Wrapped Native Token";
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual override returns (string memory) {
        return "wKRC";
    }

    /// @dev Returns the decimals of the token (same as native coin).
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////
                            WRAP/UNWRAP LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit native tokens and receive wKRC
     * @dev Mints wKRC 1:1 for deposited native tokens
     */
    function deposit() public payable virtual {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw native tokens by burning wKRC
     * @param amount The amount of wKRC to burn
     */
    function withdraw(uint256 amount) public virtual {
        if (balanceOf(msg.sender) < amount) {
            revert InsufficientBalance();
        }

        _burn(msg.sender, amount);

        /// @solidity memory-safe-assembly
        assembly {
            // Transfer the native token and check if it succeeded
            if iszero(call(gas(), caller(), amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // `NativeTransferFailed()`.
                revert(0x1c, 0x04)
            }
        }

        emit Withdrawal(msg.sender, amount);
    }

    /**
     * @notice Deposit native tokens to a specific address
     * @param to The address to receive wKRC
     */
    function depositTo(address to) public payable virtual {
        _mint(to, msg.value);
        emit Deposit(to, msg.value);
    }

    /**
     * @notice Withdraw native tokens to a specific address
     * @param to The address to receive native tokens
     * @param amount The amount of wKRC to burn
     */
    function withdrawTo(address to, uint256 amount) public virtual {
        if (balanceOf(msg.sender) < amount) {
            revert InsufficientBalance();
        }

        _burn(msg.sender, amount);

        /// @solidity memory-safe-assembly
        assembly {
            // Transfer the native token to the specified address
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // `NativeTransferFailed()`.
                revert(0x1c, 0x04)
            }
        }

        emit Withdrawal(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @dev Equivalent to `deposit()`. Allows receiving native tokens directly.
    receive() external payable virtual {
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the total native token balance held by this contract
     * @return The contract's native token balance
     */
    function totalDeposits() external view returns (uint256) {
        return address(this).balance;
    }
}
