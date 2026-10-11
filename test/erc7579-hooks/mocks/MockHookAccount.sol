// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHook } from "../../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { IERC7579Account } from "../../../src/erc7579-smartaccount/interfaces/IERC7579Account.sol";
import { ExecMode } from "../../../src/erc7579-smartaccount/types/Types.sol";

/// @notice msgData Kernel passes to hooks for a single-call execute:
///         execute.selector || abi.encode(ExecMode(CALLTYPE_SINGLE), target || value || callData)
function kernelExecuteMsgData(address target, uint256 value, bytes memory callData) pure returns (bytes memory) {
    return
        abi.encodeCall(IERC7579Account.execute, (ExecMode.wrap(bytes32(0)), abi.encodePacked(target, value, callData)));
}

/**
 * @title MockHookAccount
 * @notice Mock smart account for testing ERC-7579 Hook modules
 */
contract MockHookAccount {
    IHook public hook;

    function installHook(address _hook, bytes calldata data) external {
        hook = IHook(_hook);
        hook.onInstall(data);
    }

    function uninstallHook(bytes calldata data) external {
        hook.onUninstall(data);
    }

    /// @notice Simulate a transaction execution through the hook
    function executeWithHook(address target, uint256 value, bytes calldata callData)
        external
        payable
        returns (bytes memory)
    {
        // Build msgData as Kernel passes it to hooks (single-call execute)
        bytes memory msgData = kernelExecuteMsgData(target, value, callData);

        // Pre-check
        bytes memory hookData = hook.preCheck{ value: msg.value }(msg.sender, value, msgData);

        // Simulate execution (just return empty for mock)
        // In real scenario, this would call target

        // Post-check
        hook.postCheck(hookData);

        return "";
    }

    /// @notice Execute with hook and actually call the target
    function executeWithHookAndCall(address target, uint256 value, bytes calldata callData)
        external
        payable
        returns (bytes memory result)
    {
        // Build msgData as Kernel passes it to hooks (single-call execute)
        bytes memory msgData = kernelExecuteMsgData(target, value, callData);

        // Pre-check
        bytes memory hookData = hook.preCheck{ value: 0 }(msg.sender, value, msgData);

        // Actual execution
        (bool success, bytes memory returnData) = target.call{ value: value }(callData);
        require(success, "Execution failed");

        // Post-check
        hook.postCheck(hookData);

        return returnData;
    }

    /// @notice Allow direct hook configuration calls
    function callHook(bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = address(hook).call(data);
        require(success, "Hook call failed");
        return result;
    }

    receive() external payable { }
}

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing spending limits
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
