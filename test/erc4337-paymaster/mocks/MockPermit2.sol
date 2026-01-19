// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit2} from "../../../src/erc4337-paymaster/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockPermit2
 * @notice Mock Permit2 contract for testing
 */
contract MockPermit2 is IPermit2 {
    using SafeERC20 for IERC20;

    // owner => token => spender => allowance
    mapping(address => mapping(address => mapping(address => Allowance))) private _allowances;

    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    // Track if permit should fail
    bool public shouldFailPermit;

    function setShouldFailPermit(bool _fail) external {
        shouldFailPermit = _fail;
    }

    function permit(
        address owner,
        PermitSingle calldata permitSingle,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        _allowances[owner][permitSingle.details.token][permitSingle.spender] = Allowance({
            amount: permitSingle.details.amount,
            expiration: permitSingle.details.expiration,
            nonce: permitSingle.details.nonce + 1
        });
    }

    function allowance(
        address owner,
        address token,
        address spender
    ) external view override returns (uint160 amount, uint48 expiration, uint48 nonce) {
        Allowance storage a = _allowances[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external override {
        Allowance storage a = _allowances[from][token][msg.sender];
        require(a.amount >= amount, "MockPermit2: insufficient allowance");
        require(a.expiration >= block.timestamp, "MockPermit2: expired");

        a.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permitData,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        IERC20(permitData.permitted.token).safeTransferFrom(
            owner,
            transferDetails.to,
            transferDetails.requestedAmount
        );
    }

    // Helper to set allowance directly for testing
    function setAllowance(
        address owner,
        address token,
        address spender,
        uint160 amount,
        uint48 expiration,
        uint48 nonce
    ) external {
        _allowances[owner][token][spender] = Allowance({
            amount: amount,
            expiration: expiration,
            nonce: nonce
        });
    }
}
