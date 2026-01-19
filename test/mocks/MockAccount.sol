// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IAccount } from "../../src/erc4337-entrypoint/interfaces/IAccount.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";

/**
 * @title MockAccount
 * @notice A simple mock account for testing EntryPoint functionality
 */
contract MockAccount is IAccount {
    address public owner;
    IEntryPoint public immutable ENTRY_POINT;
    uint256 public executeCount;

    error NotOwner();
    error NotEntryPoint();

    constructor(IEntryPoint _entryPoint, address _owner) {
        ENTRY_POINT = _entryPoint;
        owner = _owner;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(ENTRY_POINT)) revert NotEntryPoint();
        _;
    }

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        (userOpHash); // Silence unused variable warning

        // Simple signature validation - just check if signature is from owner
        // In production, this would verify an actual signature
        bytes calldata signature = userOp.signature;

        // For testing: signature should be the owner address encoded
        if (signature.length >= 20) {
            address signer;
            assembly {
                signer := shr(96, calldataload(signature.offset))
            }
            if (signer == owner) {
                validationData = 0; // Success
            } else {
                validationData = 1; // Failure (SIG_VALIDATION_FAILED)
            }
        } else {
            validationData = 1; // Failure
        }

        // Pay prefund if needed
        if (missingAccountFunds > 0) {
            (bool success,) = payable(msg.sender).call{ value: missingAccountFunds }("");
            (success); // Silence unused variable warning
        }

        return validationData;
    }

    /// @notice Execute a call from this account
    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPoint {
        executeCount++;
        (bool success, bytes memory result) = target.call{ value: value }(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @notice Deposit funds to EntryPoint for this account
    function addDeposit() external payable {
        ENTRY_POINT.depositTo{ value: msg.value }(address(this));
    }

    /// @notice Get current deposit in EntryPoint
    function getDeposit() external view returns (uint256) {
        return ENTRY_POINT.balanceOf(address(this));
    }

    receive() external payable {}
}

/**
 * @title MockAccountFactory
 * @notice Factory to create MockAccount instances
 */
contract MockAccountFactory {
    IEntryPoint public immutable ENTRY_POINT;

    constructor(IEntryPoint _entryPoint) {
        ENTRY_POINT = _entryPoint;
    }

    function createAccount(address owner, uint256 salt) external returns (MockAccount account) {
        bytes32 saltBytes = bytes32(salt);
        account = new MockAccount{ salt: saltBytes }(ENTRY_POINT, owner);
    }

    function getAddress(address owner, uint256 salt) external view returns (address) {
        bytes32 saltBytes = bytes32(salt);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            saltBytes,
                            keccak256(abi.encodePacked(type(MockAccount).creationCode, abi.encode(ENTRY_POINT, owner)))
                        )
                    )
                )
            )
        );
    }
}
