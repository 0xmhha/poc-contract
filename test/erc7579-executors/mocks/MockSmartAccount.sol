// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC7579Account} from "../../../src/erc7579-smartaccount/interfaces/IERC7579Account.sol";
import {IExecutor} from "../../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {ExecMode} from "../../../src/erc7579-smartaccount/types/Types.sol";
import {MODULE_TYPE_EXECUTOR} from "../../../src/erc7579-smartaccount/types/Constants.sol";

/**
 * @title MockSmartAccount
 * @notice Mock smart account for testing executors
 */
contract MockSmartAccount is IERC7579Account {
    mapping(address => bool) public installedExecutors;
    address public owner;

    event ExecutionFromExecutor(address indexed executor, address indexed target, uint256 value, bytes data);

    constructor(address _owner) {
        owner = _owner;
    }

    function installModule(uint256 moduleType, address module, bytes calldata initData) external payable override {
        if (moduleType == MODULE_TYPE_EXECUTOR) {
            installedExecutors[module] = true;
            if (initData.length > 0) {
                IExecutor(module).onInstall(initData);
            }
        }
    }

    function uninstallModule(uint256 moduleType, address module, bytes calldata deInitData) external payable override {
        if (moduleType == MODULE_TYPE_EXECUTOR) {
            installedExecutors[module] = false;
            IExecutor(module).onUninstall(deInitData);
        }
    }

    function isModuleInstalled(uint256 moduleType, address module, bytes calldata) external view override returns (bool) {
        if (moduleType == MODULE_TYPE_EXECUTOR) {
            return installedExecutors[module];
        }
        return false;
    }

    function execute(ExecMode, bytes calldata executionCalldata) external payable override {
        // Simple single execution
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];

        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, string(result));
    }

    function executeFromExecutor(ExecMode, bytes calldata executionCalldata)
        external
        payable
        override
        returns (bytes[] memory returnData)
    {
        require(installedExecutors[msg.sender], "MockSmartAccount: executor not installed");

        // Simple single execution
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];

        emit ExecutionFromExecutor(msg.sender, target, value, data);

        returnData = new bytes[](1);
        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, string(result));
        returnData[0] = result;
    }

    function accountId() external pure override returns (string memory) {
        return "mock.smartaccount.v1";
    }

    function supportsModule(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function supportsExecutionMode(ExecMode) external pure override returns (bool) {
        return true;
    }

    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0x1626ba7e; // EIP-1271 magic value
    }

    receive() external payable {}
}
