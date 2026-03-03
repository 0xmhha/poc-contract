// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { LibClone } from "solady/utils/LibClone.sol";
import { IEntryPoint } from "../../erc4337-entrypoint/interfaces/IEntryPoint.sol";

contract KernelFactory {
    error InitializeError();
    error ImplementationNotDeployed();
    error NotCalledFromEntryPoint();

    address public immutable IMPLEMENTATION;
    IEntryPoint public immutable ENTRYPOINT;

    constructor(address _impl, IEntryPoint _entryPoint) {
        IMPLEMENTATION = _impl;
        ENTRYPOINT = _entryPoint;
        require(_impl.code.length > 0, ImplementationNotDeployed());
    }

    function createAccount(bytes calldata data, bytes32 salt) public payable returns (address) {
        // Per ERC-4337 §4.2: factory should verify it is being called via the EntryPoint's
        // SenderCreator. This prevents direct calls from bypassing EntryPoint validation.
        // CREATE2 determinism means the practical risk is low, but this guard adds defense-in-depth.
        if (msg.sender != address(ENTRYPOINT.senderCreator())) {
            revert NotCalledFromEntryPoint();
        }
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 actualSalt = keccak256(abi.encodePacked(data, salt));
        (bool alreadyDeployed, address account) =
            LibClone.createDeterministicERC1967(msg.value, IMPLEMENTATION, actualSalt);
        if (!alreadyDeployed) {
            (bool success,) = account.call(data);
            if (!success) {
                revert InitializeError();
            }
        }
        return account;
    }

    function getAddress(bytes calldata data, bytes32 salt) public view virtual returns (address) {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 actualSalt = keccak256(abi.encodePacked(data, salt));
        return LibClone.predictDeterministicAddressERC1967(IMPLEMENTATION, actualSalt, address(this));
    }
}
