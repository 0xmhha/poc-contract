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
    /// This allows the mock account to receive ERC-721, ERC-1155, and flash loan callbacks
    fallback() external payable {
        address handler = fallbackHandlers[msg.sig];
        if (handler != address(0)) {
            // Forward with extended ERC-2771 context:
            // Append original caller (msg.sender) + smart account address (this)
            // Total 40 bytes appended: [original_caller:20][smart_account:20]
            bytes memory callData = abi.encodePacked(msg.data, msg.sender, address(this));
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
 * @title MockERC721
 * @notice Simple ERC-721 mock for testing token receiver fallback
 */
contract MockERC721 {
    string public name;
    string public symbol;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    uint256 private _tokenIdCounter;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        ownerOf[tokenId] = to;
        balanceOf[to]++;
        emit Transfer(address(0), to, tokenId);
        return tokenId;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        require(ownerOf[tokenId] == from, "Not owner");
        require(
            msg.sender == from || getApproved[tokenId] == msg.sender || isApprovedForAll[from][msg.sender],
            "Not approved"
        );

        ownerOf[tokenId] = to;
        balanceOf[from]--;
        balanceOf[to]++;

        emit Transfer(from, to, tokenId);

        // Call onERC721Received if recipient is a contract
        if (to.code.length > 0) {
            bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
            require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: transfer rejected");
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        this.safeTransferFrom(from, to, tokenId, "");
    }

    function approve(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "Not owner");
        getApproved[tokenId] = to;
        emit Approval(msg.sender, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/**
 * @title MockERC1155
 * @notice Simple ERC-1155 mock for testing token receiver fallback
 */
contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        require(ids.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            balanceOf[to][ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, amounts);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "Not approved");
        require(balanceOf[from][id] >= amount, "Insufficient balance");

        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);

        // Call onERC1155Received if recipient is a contract
        if (to.code.length > 0) {
            bytes4 retval = IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(retval == IERC1155Receiver.onERC1155Received.selector, "ERC1155: transfer rejected");
        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(ids.length == amounts.length, "Length mismatch");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "Not approved");

        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[from][ids[i]] >= amounts[i], "Insufficient balance");
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        // Call onERC1155BatchReceived if recipient is a contract
        if (to.code.length > 0) {
            bytes4 retval = IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data);
            require(retval == IERC1155Receiver.onERC1155BatchReceived.selector, "ERC1155: batch transfer rejected");
        }
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

interface IERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
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
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
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
