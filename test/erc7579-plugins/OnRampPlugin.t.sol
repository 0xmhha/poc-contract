// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OnRampPlugin} from "../../src/erc7579-plugins/OnRampPlugin.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/erc7579-smartaccount/types/Constants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OnRampPluginTest is Test {
    OnRampPlugin public plugin;
    MockERC20 public token;

    address public treasury;
    address public providerSigner;
    uint256 public providerSignerKey;
    address public recipient;
    address public admin;

    uint256 public providerId;

    event ProviderAdded(uint256 indexed providerId, string name, address signer);
    event ProviderUpdated(uint256 indexed providerId, OnRampPlugin.ProviderStatus status);
    event OrderCreated(
        bytes32 indexed orderId,
        uint256 indexed providerId,
        address indexed recipient,
        uint256 fiatAmount,
        uint256 cryptoAmount
    );
    event OrderCompleted(
        bytes32 indexed orderId,
        address indexed recipient,
        uint256 cryptoAmount,
        uint256 fee
    );
    event OrderCancelled(bytes32 indexed orderId);
    event KYCUpdated(address indexed user, OnRampPlugin.KYCLevel level);

    function setUp() public {
        treasury = makeAddr("treasury");
        (providerSigner, providerSignerKey) = makeAddrAndKey("providerSigner");
        recipient = makeAddr("recipient");
        admin = makeAddr("admin");

        vm.startPrank(admin);
        token = new MockERC20("USD Coin", "USDC");

        plugin = new OnRampPlugin(
            treasury,
            100,        // 1% fee
            24 hours    // order expiry
        );

        // Add provider
        providerId = plugin.addProvider(
            "Moonpay",
            providerSigner,
            address(token),
            10 ether,       // min amount
            10000 ether,    // max amount
            100000 ether,   // daily limit
            OnRampPlugin.KYCLevel.BASIC
        );

        // Fund plugin with tokens
        token.mint(address(plugin), 100000 ether);

        // Set user KYC
        plugin.setUserKyc(recipient, OnRampPlugin.KYCLevel.STANDARD, keccak256("kyc-docs"));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(plugin.treasury(), treasury);
        assertEq(plugin.feeBps(), 100);
        assertEq(plugin.orderExpiry(), 24 hours);
    }

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(OnRampPlugin.ZeroAddress.selector);
        new OnRampPlugin(address(0), 100, 24 hours);
    }

    function test_Constructor_DefaultExpiry() public {
        OnRampPlugin plugin2 = new OnRampPlugin(treasury, 100, 0);
        assertEq(plugin2.orderExpiry(), 24 hours);
    }

    // ============ IModule Tests ============

    function test_IsModuleType_Executor() public view {
        assertTrue(plugin.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(plugin.isModuleType(1));
    }

    function test_IsInitialized_AlwaysTrue() public view {
        assertTrue(plugin.isInitialized(recipient));
        assertTrue(plugin.isInitialized(address(0)));
    }

    function test_OnInstall_Succeeds() public {
        vm.prank(recipient);
        plugin.onInstall("");
    }

    function test_OnUninstall_Succeeds() public {
        vm.prank(recipient);
        plugin.onUninstall("");
    }

    // ============ Provider Management Tests ============

    function test_AddProvider_Success() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ProviderAdded(1, "Transak", newSigner);
        uint256 newProviderId = plugin.addProvider(
            "Transak",
            newSigner,
            address(token),
            5 ether,
            5000 ether,
            50000 ether,
            OnRampPlugin.KYCLevel.NONE
        );

        assertEq(newProviderId, 1);

        OnRampPlugin.Provider memory provider = plugin.getProvider(newProviderId);
        assertEq(provider.name, "Transak");
        assertEq(provider.signer, newSigner);
        assertEq(uint8(provider.status), uint8(OnRampPlugin.ProviderStatus.ACTIVE));
    }

    function test_AddProvider_RevertsOnZeroSigner() public {
        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.ZeroAddress.selector);
        plugin.addProvider(
            "Test",
            address(0),
            address(token),
            10 ether,
            10000 ether,
            100000 ether,
            OnRampPlugin.KYCLevel.NONE
        );
    }

    function test_SetProviderStatus_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ProviderUpdated(providerId, OnRampPlugin.ProviderStatus.PAUSED);
        plugin.setProviderStatus(providerId, OnRampPlugin.ProviderStatus.PAUSED);

        OnRampPlugin.Provider memory provider = plugin.getProvider(providerId);
        assertEq(uint8(provider.status), uint8(OnRampPlugin.ProviderStatus.PAUSED));
    }

    function test_SetProviderSigner_Success() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(admin);
        plugin.setProviderSigner(providerId, newSigner);

        OnRampPlugin.Provider memory provider = plugin.getProvider(providerId);
        assertEq(provider.signer, newSigner);
    }

    function test_SetProviderSigner_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.ZeroAddress.selector);
        plugin.setProviderSigner(providerId, address(0));
    }

    function test_SetProviderLimits_Success() public {
        vm.prank(admin);
        plugin.setProviderLimits(providerId, 20 ether, 20000 ether, 200000 ether);

        OnRampPlugin.Provider memory provider = plugin.getProvider(providerId);
        assertEq(provider.minAmount, 20 ether);
        assertEq(provider.maxAmount, 20000 ether);
        assertEq(provider.dailyLimit, 200000 ether);
    }

    // ============ KYC Management Tests ============

    function test_SetUserKyc_Success() public {
        address user = makeAddr("user");

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit KYCUpdated(user, OnRampPlugin.KYCLevel.ENHANCED);
        plugin.setUserKyc(user, OnRampPlugin.KYCLevel.ENHANCED, keccak256("enhanced-docs"));

        OnRampPlugin.UserKyc memory kyc = plugin.getUserKycStatus(user);
        assertEq(uint8(kyc.level), uint8(OnRampPlugin.KYCLevel.ENHANCED));
        assertFalse(kyc.isBlacklisted);
    }

    function test_SetUserBlacklist_Success() public {
        vm.prank(admin);
        plugin.setUserBlacklist(recipient, true);

        OnRampPlugin.UserKyc memory kyc = plugin.getUserKycStatus(recipient);
        assertTrue(kyc.isBlacklisted);
    }

    // ============ Order Management Tests ============

    function test_CreateOrder_Success() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit OrderCreated(orderId, providerId, recipient, 10000, 100 ether);
        plugin.createOrder(
            orderId,
            providerId,
            recipient,
            10000,        // $100 in cents
            "USD",
            100 ether,
            1e18          // 1:1 exchange rate
        );

        OnRampPlugin.Order memory order = plugin.getOrder(orderId);
        assertEq(order.orderId, orderId);
        assertEq(order.providerId, providerId);
        assertEq(order.recipient, recipient);
        assertEq(order.fiatAmount, 10000);
        assertEq(keccak256(bytes(order.fiatCurrency)), keccak256(bytes("USD")));
        assertEq(order.cryptoAmount, 100 ether);
        assertEq(uint8(order.status), uint8(OnRampPlugin.OrderStatus.PENDING));
    }

    function test_CreateOrder_RevertsOnInactiveProvider() public {
        vm.prank(admin);
        plugin.setProviderStatus(providerId, OnRampPlugin.ProviderStatus.INACTIVE);

        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.ProviderNotActive.selector);
        plugin.createOrder(
            keccak256("order"),
            providerId,
            recipient,
            10000,
            "USD",
            100 ether,
            1e18
        );
    }

    function test_CreateOrder_RevertsOnAmountBelowMinimum() public {
        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.AmountBelowMinimum.selector);
        plugin.createOrder(
            keccak256("order"),
            providerId,
            recipient,
            100,
            "USD",
            1 ether,     // Below 10 ether minimum
            1e18
        );
    }

    function test_CreateOrder_RevertsOnAmountAboveMaximum() public {
        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.AmountAboveMaximum.selector);
        plugin.createOrder(
            keccak256("order"),
            providerId,
            recipient,
            1500000,
            "USD",
            15000 ether, // Above 10000 ether maximum
            1e18
        );
    }

    function test_CreateOrder_RevertsOnBlacklistedUser() public {
        vm.startPrank(admin);
        plugin.setUserBlacklist(recipient, true);

        vm.expectRevert(OnRampPlugin.UserBlacklisted.selector);
        plugin.createOrder(
            keccak256("order"),
            providerId,
            recipient,
            10000,
            "USD",
            100 ether,
            1e18
        );
        vm.stopPrank();
    }

    function test_CreateOrder_RevertsOnInsufficientKYC() public {
        address noKycUser = makeAddr("noKycUser");

        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.InsufficientKYC.selector);
        plugin.createOrder(
            keccak256("order"),
            providerId,
            noKycUser,
            10000,
            "USD",
            100 ether,
            1e18
        );
    }

    function test_CreateOrder_RevertsOnDailyLimitExceeded() public {
        // Create orders up to daily limit
        vm.startPrank(admin);
        for (uint256 i = 0; i < 10; i++) {
            plugin.createOrder(
                keccak256(abi.encodePacked("order", i)),
                providerId,
                recipient,
                1000000,
                "USD",
                10000 ether,
                1e18
            );
        }

        // This one exceeds the limit
        vm.expectRevert(OnRampPlugin.DailyLimitExceeded.selector);
        plugin.createOrder(
            keccak256("order-overflow"),
            providerId,
            recipient,
            1000000,
            "USD",
            10000 ether,
            1e18
        );
        vm.stopPrank();
    }

    // ============ Claim Order Tests ============

    function test_ClaimOrder_Success() public {
        bytes32 orderId = keccak256("order-1");

        // Create order
        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Create signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            orderId,
            recipient,
            uint256(100 ether),
            block.chainid
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerSignerKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Calculate expected amounts
        uint256 fee = (100 ether * 100) / 10000; // 1%
        uint256 netAmount = 100 ether - fee;

        vm.expectEmit(true, true, false, true);
        emit OrderCompleted(orderId, recipient, netAmount, fee);
        plugin.claimOrder(orderId, signature);

        // Check balances
        assertEq(token.balanceOf(recipient), netAmount);
        assertEq(token.balanceOf(treasury), fee);

        // Check order status
        OnRampPlugin.Order memory order = plugin.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OnRampPlugin.OrderStatus.COMPLETED));
    }

    function test_ClaimOrder_RevertsOnAlreadyClaimed() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Create signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            orderId,
            recipient,
            uint256(100 ether),
            block.chainid
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerSignerKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        plugin.claimOrder(orderId, signature);

        vm.expectRevert(OnRampPlugin.OrderAlreadyClaimed.selector);
        plugin.claimOrder(orderId, signature);
    }

    function test_ClaimOrder_RevertsOnInvalidOrderStatus() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Cancel the order
        vm.prank(admin);
        plugin.cancelOrder(orderId);

        bytes memory signature = new bytes(65);
        vm.expectRevert(OnRampPlugin.InvalidOrderStatus.selector);
        plugin.claimOrder(orderId, signature);
    }

    function test_ClaimOrder_RevertsOnExpired() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Move past expiry
        vm.warp(block.timestamp + 25 hours);

        bytes memory signature = new bytes(65);
        vm.expectRevert(OnRampPlugin.OrderExpiredError.selector);
        plugin.claimOrder(orderId, signature);
    }

    function test_ClaimOrder_RevertsOnInvalidSignature() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Wrong signature (signed by different key)
        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        bytes32 messageHash = keccak256(abi.encodePacked(
            orderId,
            recipient,
            uint256(100 ether),
            block.chainid
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(OnRampPlugin.InvalidSignature.selector);
        plugin.claimOrder(orderId, signature);
    }

    // ============ Cancel/Refund Order Tests ============

    function test_CancelOrder_Success() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit OrderCancelled(orderId);
        plugin.cancelOrder(orderId);

        OnRampPlugin.Order memory order = plugin.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OnRampPlugin.OrderStatus.CANCELLED));
    }

    function test_CancelOrder_RevertsOnInvalidStatus() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        vm.prank(admin);
        plugin.cancelOrder(orderId);

        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.InvalidOrderStatus.selector);
        plugin.cancelOrder(orderId);
    }

    function test_RefundOrder_FromPending() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        vm.prank(admin);
        plugin.refundOrder(orderId);

        OnRampPlugin.Order memory order = plugin.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OnRampPlugin.OrderStatus.REFUNDED));
    }

    function test_RefundOrder_RevertsOnInvalidStatus() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        vm.prank(admin);
        plugin.cancelOrder(orderId);

        vm.prank(admin);
        vm.expectRevert(OnRampPlugin.InvalidOrderStatus.selector);
        plugin.refundOrder(orderId);
    }

    // ============ View Function Tests ============

    function test_GetUserOrders() public {
        vm.startPrank(admin);
        plugin.createOrder(keccak256("order-1"), providerId, recipient, 10000, "USD", 100 ether, 1e18);
        plugin.createOrder(keccak256("order-2"), providerId, recipient, 20000, "USD", 200 ether, 1e18);
        vm.stopPrank();

        bytes32[] memory orders = plugin.getUserOrders(recipient);
        assertEq(orders.length, 2);
    }

    function test_CanClaimOrder_True() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        assertTrue(plugin.canClaimOrder(orderId));
    }

    function test_CanClaimOrder_FalseWhenClaimed() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        // Claim the order
        bytes32 messageHash = keccak256(abi.encodePacked(
            orderId,
            recipient,
            uint256(100 ether),
            block.chainid
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerSignerKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        plugin.claimOrder(orderId, signature);

        assertFalse(plugin.canClaimOrder(orderId));
    }

    function test_CanClaimOrder_FalseWhenExpired() public {
        bytes32 orderId = keccak256("order-1");

        vm.prank(admin);
        plugin.createOrder(orderId, providerId, recipient, 10000, "USD", 100 ether, 1e18);

        vm.warp(block.timestamp + 25 hours);

        assertFalse(plugin.canClaimOrder(orderId));
    }

    function test_GetRemainingDailyLimit() public {
        uint256 remaining = plugin.getRemainingDailyLimit(providerId);
        assertEq(remaining, 100000 ether);

        // Create an order
        vm.prank(admin);
        plugin.createOrder(keccak256("order"), providerId, recipient, 10000, "USD", 1000 ether, 1e18);

        remaining = plugin.getRemainingDailyLimit(providerId);
        assertEq(remaining, 99000 ether);
    }

    function test_GetRemainingDailyLimit_ResetsAfterDay() public {
        // Use some limit
        vm.prank(admin);
        plugin.createOrder(keccak256("order"), providerId, recipient, 10000, "USD", 1000 ether, 1e18);

        uint256 remaining = plugin.getRemainingDailyLimit(providerId);
        assertEq(remaining, 99000 ether);

        // Move forward 1 day
        vm.warp(block.timestamp + 1 days);

        remaining = plugin.getRemainingDailyLimit(providerId);
        assertEq(remaining, 100000 ether);
    }

    function test_GetRemainingDailyLimit_ReturnsZeroWhenExhausted() public {
        // Use up the entire limit
        vm.startPrank(admin);
        for (uint256 i = 0; i < 10; i++) {
            plugin.createOrder(
                keccak256(abi.encodePacked("order", i)),
                providerId,
                recipient,
                1000000,
                "USD",
                10000 ether,
                1e18
            );
        }
        vm.stopPrank();

        uint256 remaining = plugin.getRemainingDailyLimit(providerId);
        assertEq(remaining, 0);
    }
}
