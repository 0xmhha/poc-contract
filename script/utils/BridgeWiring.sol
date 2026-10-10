// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { SecureBridge } from "../../src/bridge/SecureBridge.sol";
import { BridgeValidator } from "../../src/bridge/BridgeValidator.sol";
import { BridgeRateLimiter } from "../../src/bridge/BridgeRateLimiter.sol";
import { OptimisticVerifier } from "../../src/bridge/OptimisticVerifier.sol";
import { BridgeGuardian } from "../../src/bridge/BridgeGuardian.sol";
import { FraudProofVerifier } from "../../src/bridge/FraudProofVerifier.sol";

/**
 * @title BridgeWiring
 * @notice Cross-contract authorizations a bridge deployment needs before it can move funds
 * @dev Idempotent: each setting is written only when it differs, so re-running a deploy script
 *      against existing contracts is safe. The broadcaster must own every component.
 *      Without this wiring SecureBridge.initiateBridge reverts in BridgeRateLimiter and
 *      completeBridge reverts in OptimisticVerifier.markExecuted / BridgeValidator.consumeNonce.
 */
library BridgeWiring {
    function wire(
        SecureBridge bridge,
        BridgeValidator validator,
        BridgeRateLimiter rateLimiter,
        OptimisticVerifier optimisticVerifier,
        BridgeGuardian guardian,
        FraudProofVerifier fraudProofVerifier
    ) internal {
        address b = address(bridge);

        if (validator.authorizedBridge() != b) {
            validator.setAuthorizedBridge(b);
            console.log("  BridgeValidator.authorizedBridge ->", b);
        }
        if (!rateLimiter.isAuthorizedCaller(b)) {
            rateLimiter.setAuthorizedCaller(b, true);
            console.log("  BridgeRateLimiter: authorized", b);
        }
        if (!optimisticVerifier.isAuthorizedCaller(b)) {
            optimisticVerifier.setAuthorizedCaller(b, true);
            console.log("  OptimisticVerifier: authorized", b);
        }
        if (guardian.bridgeTarget() != b) {
            guardian.setBridgeTarget(b);
            console.log("  BridgeGuardian.bridgeTarget ->", b);
        }

        if (address(fraudProofVerifier) == address(0)) return;

        if (optimisticVerifier.fraudProofVerifier() != address(fraudProofVerifier)) {
            optimisticVerifier.setFraudProofVerifier(address(fraudProofVerifier));
            console.log("  OptimisticVerifier.fraudProofVerifier ->", address(fraudProofVerifier));
        }
        if (fraudProofVerifier.optimisticVerifier() != address(optimisticVerifier)) {
            fraudProofVerifier.setOptimisticVerifier(address(optimisticVerifier));
            console.log("  FraudProofVerifier.optimisticVerifier ->", address(optimisticVerifier));
        }
        if (fraudProofVerifier.bridgeValidator() != address(validator)) {
            fraudProofVerifier.setBridgeValidator(address(validator));
            console.log("  FraudProofVerifier.bridgeValidator ->", address(validator));
        }
    }
}
