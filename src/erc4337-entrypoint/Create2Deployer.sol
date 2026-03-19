// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Create2Deployer
 * @notice Minimal CREATE2 factory for deterministic contract deployment.
 *         Deploy this contract first (via regular CREATE), then use it to deploy
 *         other contracts at predictable addresses via CREATE2.
 *
 * @dev Address formula: keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
 *      As long as this factory is at the same address and the same salt + initCode are used,
 *      the deployed contract will always be at the same address.
 */
contract Create2Deployer {
    event Deployed(address indexed addr, bytes32 indexed salt);

    error DeploymentFailed();
    error AlreadyDeployed(address existing);

    /**
     * @notice Deploy a contract using CREATE2
     * @param initCode The contract creation bytecode (constructor + args)
     * @param salt The salt for deterministic address computation
     * @return addr The address of the deployed contract
     */
    function deploy(bytes memory initCode, bytes32 salt) external returns (address addr) {
        // Check if already deployed at the target address
        address predicted = computeAddress(initCode, salt);
        if (predicted.code.length > 0) {
            revert AlreadyDeployed(predicted);
        }

        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }

        if (addr == address(0)) {
            revert DeploymentFailed();
        }

        emit Deployed(addr, salt);
    }

    /**
     * @notice Predict the address of a CREATE2 deployment
     * @param initCode The contract creation bytecode
     * @param salt The salt value
     * @return The predicted address
     */
    function computeAddress(bytes memory initCode, bytes32 salt) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode)))))
        );
    }
}
