// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";
import { SubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";
import { MerchantRegistry } from "../../src/subscription/MerchantRegistry.sol";

/**
 * @title SubscriptionWiring
 * @notice Optional link between SubscriptionManager and MerchantRegistry
 * @dev Opt-in through SUBSCRIPTION_ENFORCE_MERCHANT_REGISTRY=true. Once linked, only merchants that
 *      are verified and not suspended in the registry can create plans, gain subscribers and be
 *      paid, so a verifier must be added (MerchantRegistry.addVerifier) and merchants verified
 *      before plans can be created. Without the flag the manager stays open to any merchant.
 *      Idempotent; the broadcaster must own SubscriptionManager.
 */
library SubscriptionWiring {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function wireFromEnv(SubscriptionManager manager, MerchantRegistry registry) internal {
        if (!VM.envOr("SUBSCRIPTION_ENFORCE_MERCHANT_REGISTRY", false)) {
            console.log("  MerchantRegistry not enforced (set SUBSCRIPTION_ENFORCE_MERCHANT_REGISTRY=true)");
            return;
        }
        wire(manager, registry);
    }

    function wire(SubscriptionManager manager, MerchantRegistry registry) internal {
        if (address(manager) == address(0) || address(registry) == address(0)) return;
        if (address(manager.merchantRegistry()) != address(registry)) {
            manager.setMerchantRegistry(address(registry));
            console.log("  SubscriptionManager.merchantRegistry ->", address(registry));
        }
    }
}
