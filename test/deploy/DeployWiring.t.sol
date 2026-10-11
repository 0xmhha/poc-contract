// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BridgeWiring } from "../../script/utils/BridgeWiring.sol";
import { SubscriptionWiring } from "../../script/utils/SubscriptionWiring.sol";
import { FraudProofVerifier } from "../../src/bridge/FraudProofVerifier.sol";
import { ERC7715PermissionManager } from "../../src/subscription/ERC7715PermissionManager.sol";
import { SubscriptionManager, ISubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";
import { MerchantRegistry } from "../../src/subscription/MerchantRegistry.sol";

/// @notice Deploy-time wiring of FraudProofVerifier token lists and the MerchantRegistry link.
/// @dev Env-driven tests use chain ids and variables unique to this file, because vm.setEnv
///      changes the process environment shared with tests running in parallel.
contract DeployWiringTest is Test {
    FraudProofVerifier internal fraudProofVerifier;

    function setUp() public {
        fraudProofVerifier = new FraudProofVerifier();
    }

    function test_AuthorizeFraudProofTokens_SetsAndIsIdempotent() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0xA1);
        tokens[1] = address(0xA2);

        BridgeWiring.authorizeFraudProofTokens(fraudProofVerifier, 1, tokens);
        BridgeWiring.authorizeFraudProofTokens(fraudProofVerifier, 1, tokens);

        assertTrue(fraudProofVerifier.authorizedTokens(1, tokens[0]));
        assertTrue(fraudProofVerifier.authorizedTokens(1, tokens[1]));
        assertEq(fraudProofVerifier.authorizedTokenCount(1), 2);
        assertEq(fraudProofVerifier.authorizedTokenCount(8453), 0);
    }

    function test_AuthorizeFraudProofTokensFromEnv_ReadsPerChainLists() public {
        vm.setEnv("FRAUD_PROOF_SOURCE_CHAINS", "990001,990002");
        vm.setEnv("FRAUD_PROOF_TOKENS_990001", "0x00000000000000000000000000000000000000b1");
        vm.setEnv(
            "FRAUD_PROOF_TOKENS_990002",
            "0x00000000000000000000000000000000000000b2,0x00000000000000000000000000000000000000b3"
        );

        BridgeWiring.authorizeFraudProofTokensFromEnv(fraudProofVerifier);

        assertTrue(fraudProofVerifier.authorizedTokens(990001, address(0xB1)));
        assertFalse(fraudProofVerifier.authorizedTokens(990001, address(0xB2)));
        assertEq(fraudProofVerifier.authorizedTokenCount(990002), 2);
    }

    function test_SubscriptionWiring_LinksRegistryAndEnforcesVerification() public {
        SubscriptionManager manager = new SubscriptionManager(address(new ERC7715PermissionManager()));
        MerchantRegistry registry = new MerchantRegistry();
        address merchant = makeAddr("merchant");

        SubscriptionWiring.wire(manager, registry);
        SubscriptionWiring.wire(manager, registry);
        assertEq(address(manager.merchantRegistry()), address(registry));

        // An unverified merchant can no longer create plans
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        manager.createPlan(1 ether, 30 days, address(0xC0), 0, 0, 0, "Basic", "");
    }

    function test_SubscriptionWiringFromEnv_DisabledByDefault() public {
        SubscriptionManager manager = new SubscriptionManager(address(new ERC7715PermissionManager()));
        MerchantRegistry registry = new MerchantRegistry();

        // Not set anywhere in the test suite; the flag defaults to false
        SubscriptionWiring.wireFromEnv(manager, registry);
        assertEq(address(manager.merchantRegistry()), address(0));
    }
}
