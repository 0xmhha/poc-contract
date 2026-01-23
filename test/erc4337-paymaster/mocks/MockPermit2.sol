// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit2} from "../../../src/permit2/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "../../../src/permit2/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "../../../src/permit2/interfaces/ISignatureTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockPermit2
 * @notice Mock Permit2 contract for testing
 * @dev Implements the full IPermit2 interface for test purposes
 */
contract MockPermit2 is IPermit2 {
    using SafeERC20 for IERC20;

    // owner => token => spender => allowance
    mapping(address => mapping(address => mapping(address => PackedAllowance))) private _allowances;

    // owner => wordPos => bitmap for signature transfer nonces
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    // Track if permit should fail
    bool public shouldFailPermit;

    function setShouldFailPermit(bool _fail) external {
        shouldFailPermit = _fail;
    }

    // ============ IAllowanceTransfer ============

    function allowance(
        address owner,
        address token,
        address spender
    ) external view override returns (uint160 amount, uint48 expiration, uint48 nonce) {
        PackedAllowance storage a = _allowances[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external override {
        _allowances[msg.sender][token][spender].amount = amount;
        _allowances[msg.sender][token][spender].expiration = expiration;
        emit Approval(msg.sender, token, spender, amount, expiration);
    }

    function permit(
        address owner,
        PermitSingle memory permitSingle,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        _allowances[owner][permitSingle.details.token][permitSingle.spender] = PackedAllowance({
            amount: permitSingle.details.amount,
            expiration: permitSingle.details.expiration,
            nonce: permitSingle.details.nonce + 1
        });

        emit Permit(
            owner,
            permitSingle.details.token,
            permitSingle.spender,
            permitSingle.details.amount,
            permitSingle.details.expiration,
            permitSingle.details.nonce
        );
    }

    function permit(
        address owner,
        PermitBatch memory permitBatch,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        for (uint256 i = 0; i < permitBatch.details.length; i++) {
            PermitDetails memory details = permitBatch.details[i];
            _allowances[owner][details.token][permitBatch.spender] = PackedAllowance({
                amount: details.amount,
                expiration: details.expiration,
                nonce: details.nonce + 1
            });

            emit Permit(owner, details.token, permitBatch.spender, details.amount, details.expiration, details.nonce);
        }
    }

    function transferFrom(address from, address to, uint160 amount, address token) external override {
        PackedAllowance storage a = _allowances[from][token][msg.sender];
        require(a.amount >= amount, "MockPermit2: insufficient allowance");
        require(a.expiration >= block.timestamp, "MockPermit2: expired");

        if (a.amount != type(uint160).max) {
            a.amount -= amount;
        }
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external override {
        for (uint256 i = 0; i < transferDetails.length; i++) {
            AllowanceTransferDetails memory detail = transferDetails[i];
            PackedAllowance storage a = _allowances[detail.from][detail.token][msg.sender];
            require(a.amount >= detail.amount, "MockPermit2: insufficient allowance");
            require(a.expiration >= block.timestamp, "MockPermit2: expired");

            if (a.amount != type(uint160).max) {
                a.amount -= detail.amount;
            }
            IERC20(detail.token).safeTransferFrom(detail.from, detail.to, detail.amount);
        }
    }

    function lockdown(TokenSpenderPair[] calldata approvals) external override {
        for (uint256 i = 0; i < approvals.length; i++) {
            _allowances[msg.sender][approvals[i].token][approvals[i].spender].amount = 0;
            emit Lockdown(msg.sender, approvals[i].token, approvals[i].spender);
        }
    }

    function invalidateNonces(address token, address spender, uint48 newNonce) external override {
        uint48 oldNonce = _allowances[msg.sender][token][spender].nonce;
        require(newNonce > oldNonce, "MockPermit2: invalid nonce");
        _allowances[msg.sender][token][spender].nonce = newNonce;
        emit NonceInvalidation(msg.sender, token, spender, newNonce, oldNonce);
    }

    // ============ ISignatureTransfer ============

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        require(block.timestamp <= permit.deadline, "MockPermit2: expired");
        require(transferDetails.requestedAmount <= permit.permitted.amount, "MockPermit2: invalid amount");

        // Mark nonce as used
        _useUnorderedNonce(owner, permit.nonce);

        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 /* witness */,
        string calldata /* witnessTypeString */,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        require(block.timestamp <= permit.deadline, "MockPermit2: expired");
        require(transferDetails.requestedAmount <= permit.permitted.amount, "MockPermit2: invalid amount");

        _useUnorderedNonce(owner, permit.nonce);

        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitTransferFrom(
        PermitBatchTransferFrom memory permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        require(block.timestamp <= permit.deadline, "MockPermit2: expired");
        require(permit.permitted.length == transferDetails.length, "MockPermit2: length mismatch");

        _useUnorderedNonce(owner, permit.nonce);

        for (uint256 i = 0; i < permit.permitted.length; i++) {
            require(
                transferDetails[i].requestedAmount <= permit.permitted[i].amount, "MockPermit2: invalid amount"
            );
            if (transferDetails[i].requestedAmount > 0) {
                IERC20(permit.permitted[i].token).safeTransferFrom(
                    owner, transferDetails[i].to, transferDetails[i].requestedAmount
                );
            }
        }
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom memory permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 /* witness */,
        string calldata /* witnessTypeString */,
        bytes calldata /* signature */
    ) external override {
        if (shouldFailPermit) {
            revert("MockPermit2: permit failed");
        }

        require(block.timestamp <= permit.deadline, "MockPermit2: expired");
        require(permit.permitted.length == transferDetails.length, "MockPermit2: length mismatch");

        _useUnorderedNonce(owner, permit.nonce);

        for (uint256 i = 0; i < permit.permitted.length; i++) {
            require(
                transferDetails[i].requestedAmount <= permit.permitted[i].amount, "MockPermit2: invalid amount"
            );
            if (transferDetails[i].requestedAmount > 0) {
                IERC20(permit.permitted[i].token).safeTransferFrom(
                    owner, transferDetails[i].to, transferDetails[i].requestedAmount
                );
            }
        }
    }

    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external override {
        nonceBitmap[msg.sender][wordPos] |= mask;
        emit UnorderedNonceInvalidation(msg.sender, wordPos, mask);
    }

    // ============ IEIP712 ============

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        // Return a mock domain separator for testing
        return keccak256("MockPermit2");
    }

    // ============ Internal ============

    function _useUnorderedNonce(address from, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bitPos = nonce & 0xff;
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonceBitmap[from][wordPos] ^= bit;
        require(flipped & bit != 0, "MockPermit2: nonce already used");
    }

    // ============ Test Helpers ============

    function setAllowance(
        address owner,
        address token,
        address spender,
        uint160 amount,
        uint48 expiration,
        uint48 nonce
    ) external {
        _allowances[owner][token][spender] = PackedAllowance({amount: amount, expiration: expiration, nonce: nonce});
    }
}
