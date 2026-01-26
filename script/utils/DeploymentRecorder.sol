// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";

/**
 * @title DeploymentRecorder
 * @notice Utility library for recording deployment results to JSON files
 * @dev Stores deployment history per chain for operational management
 *
 * File Structure:
 *   deployments/
 *     {chainId}/
 *       deployment-{timestamp}.json (individual deployment record)
 *       latest.json (symlink/copy of latest deployment)
 *       history.json (aggregated deployment history)
 */
abstract contract DeploymentRecorder is Script {
    // =============================================================
    // STRUCTS
    // =============================================================

    struct ContractDeployment {
        string name;
        address addr;
        bytes32 txHash;
        uint256 blockNumber;
        uint256 timestamp;
        string version;
    }

    // =============================================================
    // STATE VARIABLES
    // =============================================================

    /// @notice Chain name for the deployment
    string public chainName;

    /// @notice Deployment timestamp
    uint256 public deploymentTimestamp;

    /// @notice Array to track all deployed contracts in this session
    string[] internal _deployedContractNames;
    mapping(string => address) internal _deployedAddresses;

    // =============================================================
    // INITIALIZATION
    // =============================================================

    /**
     * @notice Initialize deployment recorder with chain info
     * @param _chainName Human-readable chain name
     */
    function _initRecorder(string memory _chainName) internal {
        chainName = _chainName;
        deploymentTimestamp = block.timestamp;
    }

    // =============================================================
    // RECORD FUNCTIONS
    // =============================================================

    /**
     * @notice Record a contract deployment
     * @param name Contract name (e.g., "EntryPoint", "Kernel")
     * @param addr Deployed contract address
     */
    function _recordDeployment(string memory name, address addr) internal {
        _deployedContractNames.push(name);
        _deployedAddresses[name] = addr;
    }

    /**
     * @notice Record multiple contract deployments
     * @param names Array of contract names
     * @param addrs Array of deployed addresses
     */
    function _recordDeployments(string[] memory names, address[] memory addrs) internal {
        require(names.length == addrs.length, "Array length mismatch");
        for (uint256 i = 0; i < names.length; i++) {
            _recordDeployment(names[i], addrs[i]);
        }
    }

    // =============================================================
    // SAVE FUNCTIONS
    // =============================================================

    /**
     * @notice Save deployment record to JSON file
     * @param deployer Address of the deployer
     * @return filePath Path to the saved JSON file
     */
    function _saveDeploymentRecord(address deployer) internal returns (string memory filePath) {
        uint256 chainId = block.chainid;

        // Create base directory path
        string memory baseDir = string.concat("deployments/", vm.toString(chainId));

        // Create directory if it doesn't exist
        vm.createDir(baseDir, true);

        // Create deployment JSON
        string memory json = _buildDeploymentJson(deployer, chainId);

        // Generate filename with timestamp
        string memory filename = string.concat("deployment-", vm.toString(deploymentTimestamp), ".json");

        filePath = string.concat(baseDir, "/", filename);

        // Write deployment record
        vm.writeJson(json, filePath);

        // Also write to latest.json for easy access
        string memory latestPath = string.concat(baseDir, "/latest.json");
        vm.writeJson(json, latestPath);

        console.log("\n[Deployment Record Saved]");
        console.log("  File:", filePath);
        console.log("  Latest:", latestPath);

        return filePath;
    }

    /**
     * @notice Build deployment JSON object
     */
    function _buildDeploymentJson(address deployer, uint256 chainId) internal returns (string memory) {
        // Start building JSON
        string memory obj = "deployment";

        // Metadata
        vm.serializeUint(obj, "chainId", chainId);
        vm.serializeString(obj, "chainName", chainName);
        vm.serializeUint(obj, "timestamp", deploymentTimestamp);
        vm.serializeString(obj, "date", _formatTimestamp(deploymentTimestamp));
        vm.serializeAddress(obj, "deployer", deployer);

        // Build contracts object
        string memory contracts = "contracts";
        for (uint256 i = 0; i < _deployedContractNames.length; i++) {
            string memory name = _deployedContractNames[i];
            address addr = _deployedAddresses[name];
            vm.serializeAddress(contracts, name, addr);
        }
        string memory contractsJson = vm.serializeString(contracts, "_", "");

        // Finalize main object with contracts
        string memory finalJson = vm.serializeString(obj, "contracts", contractsJson);

        return finalJson;
    }

    // =============================================================
    // UTILITY FUNCTIONS
    // =============================================================

    /**
     * @notice Format timestamp to ISO-like string (YYYY-MM-DD HH:MM:SS UTC)
     * @dev Simple implementation - for precise formatting, use off-chain tools
     */
    function _formatTimestamp(uint256 timestamp) internal pure returns (string memory) {
        // Return Unix timestamp as string for simplicity
        // Actual date formatting should be done off-chain
        return string.concat("unix:", vm.toString(timestamp));
    }

    /**
     * @notice Get deployed contract address by name
     */
    function _getDeployedAddress(string memory name) internal view returns (address) {
        return _deployedAddresses[name];
    }

    /**
     * @notice Get all deployed contract names
     */
    function _getDeployedContractNames() internal view returns (string[] memory) {
        return _deployedContractNames;
    }

    /**
     * @notice Print deployment summary to console
     */
    function _printDeploymentSummary() internal view {
        console.log("\n========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Chain Name:", chainName);
        console.log("Timestamp:", deploymentTimestamp);
        console.log("");
        console.log("Deployed Contracts:");

        for (uint256 i = 0; i < _deployedContractNames.length; i++) {
            string memory name = _deployedContractNames[i];
            address addr = _deployedAddresses[name];
            console.log(string.concat("  ", name, ": "), addr);
        }
        console.log("========================================");
    }
}
