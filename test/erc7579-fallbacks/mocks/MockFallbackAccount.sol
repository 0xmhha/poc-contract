// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFallback } from "../../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockFallbackAccount
 * @notice Mock smart account for testing ERC-7579 Fallback modules
 */
contract MockFallbackAccount {
    using SafeERC20 for IERC20;

    mapping(bytes4 => address) public fallbackHandlers;

    function installFallback(address module, bytes4 selector, bytes calldata data) external {
        fallbackHandlers[selector] = module;
        // Only call onInstall if this is the first selector being registered for this module
        // Skip if data is empty (already installed)
        if (data.length > 0) {
            IFallback(module).onInstall(data);
        }
    }

    /// @notice Register a fallback handler without calling onInstall
    function registerFallbackHandler(address module, bytes4 selector) external {
        fallbackHandlers[selector] = module;
    }

    function uninstallFallback(address module, bytes4 selector, bytes calldata data) external {
        delete fallbackHandlers[selector];
        if (data.length > 0) {
            IFallback(module).onUninstall(data);
        }
    }

    /// @notice Forward calls to registered fallback handlers with ERC-2771 context
    function forwardToFallback(bytes4 selector, bytes calldata data) external returns (bytes memory) {
        address handler = fallbackHandlers[selector];
        require(handler != address(0), "No fallback handler");

        // Append msg.sender (this contract) as the last 20 bytes (ERC-2771 style)
        bytes memory callData = abi.encodePacked(data, address(this));

        (bool success, bytes memory result) = handler.call(callData);
        require(success, "Fallback call failed");
        return result;
    }

    /// @notice Allow direct calls to fallback module (for configuration)
    function callFallback(address module, bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = module.call(data);
        require(success, "Fallback call failed");
        return result;
    }

    /// @notice Approve tokens for flash loan repayment
    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @notice Transfer tokens
    function transferToken(address token, address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Fallback function that forwards to registered fallback handlers
    /// This allows the mock account to receive ERC-777 and flash loan callbacks
    fallback() external payable {
        address handler = fallbackHandlers[msg.sig];
        if (handler != address(0)) {
            // Forward with ERC-2771 context:
            // Append original caller (msg.sender) as 20 bytes per ERC-2771 standard
            bytes memory callData = abi.encodePacked(msg.data, msg.sender);
            (bool success, bytes memory result) = handler.call(callData);

            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            assembly {
                return(add(result, 0x20), mload(result))
            }
        }
    }

    receive() external payable { }
}

/**
 * @title MockERC20
 * @notice Simple ERC-20 mock for testing
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

/**
 * @title MockFlashLoanProvider
 * @notice Mock flash loan provider for testing
 */
contract MockFlashLoanProvider {
    using SafeERC20 for IERC20;
    uint256 public constant FEE_BPS = 9; // 0.09%

    /// @notice AAVE-style flash loan
    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        address,
        bytes calldata params,
        uint16
    ) external {
        uint256[] memory premiums = new uint256[](assets.length);

        // Transfer assets to receiver
        for (uint256 i = 0; i < assets.length; i++) {
            premiums[i] = (amounts[i] * FEE_BPS) / 10_000;
            IERC20(assets[i]).safeTransfer(receiver, amounts[i]);
        }

        // Call receiver callback (the receiver's fallback will add ERC-2771 context)
        bytes memory callData = abi.encodeWithSignature(
            "executeOperation(address[],uint256[],uint256[],address,bytes)",
            assets,
            amounts,
            premiums,
            msg.sender,
            params
        );

        (bool success, bytes memory result) = receiver.call(callData);
        require(success, _getRevertMsg(result));

        // Verify repayment
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountOwing = amounts[i] + premiums[i];
            IERC20(assets[i]).safeTransferFrom(receiver, address(this), amountOwing);
        }
    }

    /// @notice ERC-3156 style flash loan
    function flashLoanERC3156(address receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        uint256 fee = (amount * FEE_BPS) / 10_000;

        // Transfer to receiver
        IERC20(token).safeTransfer(receiver, amount);

        // Call callback (the receiver's fallback will add ERC-2771 context)
        bytes memory callData = abi.encodeWithSignature(
            "onFlashLoan(address,address,uint256,uint256,bytes)", msg.sender, token, amount, fee, data
        );

        (bool success, bytes memory result) = receiver.call(callData);
        require(success, _getRevertMsg(result));

        // Verify repayment
        IERC20(token).safeTransferFrom(receiver, address(this), amount + fee);

        return true;
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
