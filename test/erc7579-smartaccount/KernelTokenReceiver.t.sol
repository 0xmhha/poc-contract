// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { KernelModuleTestBase } from "../utils/KernelModuleTestBase.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { IFallback } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_FALLBACK } from "../../src/erc7579-smartaccount/types/Constants.sol";

/// @dev Minimal token that performs the ERC-721 / ERC-1155 safe-transfer receiver check
contract ReceiverCheckingToken {
    error UnsafeRecipient();

    function safeTransfer721(address to) external {
        bytes4 sel = 0x150b7a02; // onERC721Received(address,address,uint256,bytes)
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(sel, msg.sender, msg.sender, 1, ""));
        if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != sel) revert UnsafeRecipient();
    }

    function safeTransfer1155(address to) external {
        bytes4 sel = 0xf23a6e61; // onERC1155Received(address,address,uint256,uint256,bytes)
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(sel, msg.sender, msg.sender, 1, 10, ""));
        if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != sel) revert UnsafeRecipient();
    }

    function safeBatchTransfer1155(address to) external {
        bytes4 sel = 0xbc197c81; // onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(sel, msg.sender, msg.sender, ids, amounts, ""));
        if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != sel) revert UnsafeRecipient();
    }
}

/// @dev Fallback module that would reject ERC-721 transfers if it were reached
contract RejectingReceiverFallback is IFallback {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_FALLBACK;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(bytes4(0xdeadbeef));
    }
}

/// @notice Kernel answers ERC-721 / ERC-1155 receiver callbacks from its fallback (no dedicated functions)
contract KernelTokenReceiverTest is KernelModuleTestBase {
    ReceiverCheckingToken internal token;
    address internal account;

    function setUp() public {
        _deployKernel();
        account = _createAccount(0);
        token = new ReceiverCheckingToken();
    }

    function test_AcceptsERC721SafeTransfer() public {
        token.safeTransfer721(account);
    }

    function test_AcceptsERC1155SafeTransfer() public {
        token.safeTransfer1155(account);
    }

    function test_AcceptsERC1155SafeBatchTransfer() public {
        token.safeBatchTransfer1155(account);
    }

    function test_UnknownSelectorStillReverts() public {
        (bool ok, bytes memory ret) = account.call(abi.encodeWithSelector(bytes4(0x12345678)));
        assertFalse(ok);
        assertEq(bytes4(ret), Kernel.InvalidSelector.selector);
    }

    /// @dev Reception does not depend on modules: a fallback installed for a receiver selector is
    ///      never reached (same as when these were explicit functions)
    function test_InstalledFallbackCannotBlockReception() public {
        RejectingReceiverFallback rejecting = new RejectingReceiverFallback();
        _installFallback(account, address(rejecting), bytes4(0x150b7a02), "");

        token.safeTransfer721(account);
    }
}
