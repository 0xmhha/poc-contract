// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";
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
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

        authorizeFraudProofTokensFromEnv(fraudProofVerifier);
    }

    /**
     * @notice Authorize the bridgeable tokens of each source chain on the FraudProofVerifier
     * @dev Reads FRAUD_PROOF_SOURCE_CHAINS (comma-separated chain ids) and, for each chain id,
     *      FRAUD_PROOF_TOKENS_<chainId> (comma-separated token addresses). Only adds tokens; it
     *      never revokes, so re-running is safe. A chain with no authorized tokens fails closed:
     *      InvalidToken fraud proofs for requests from that chain always return false.
     *
     *      Example: FRAUD_PROOF_SOURCE_CHAINS=1,8453 FRAUD_PROOF_TOKENS_1=0xA0b8...,0xdAC1...
     */
    function authorizeFraudProofTokensFromEnv(FraudProofVerifier fraudProofVerifier) internal {
        uint256[] memory chainIds = VM.envOr("FRAUD_PROOF_SOURCE_CHAINS", ",", new uint256[](0));
        if (chainIds.length == 0) {
            console.log("  Warning: FRAUD_PROOF_SOURCE_CHAINS not set; InvalidToken fraud proofs fail closed");
            return;
        }

        for (uint256 i = 0; i < chainIds.length; i++) {
            string memory key = string.concat("FRAUD_PROOF_TOKENS_", VM.toString(chainIds[i]));
            address[] memory tokens = VM.envOr(key, ",", new address[](0));
            if (tokens.length == 0) {
                console.log("  Warning: no tokens configured for source chain", chainIds[i]);
                continue;
            }
            authorizeFraudProofTokens(fraudProofVerifier, chainIds[i], tokens);
        }
    }

    /**
     * @notice Authorize `tokens` for `chainId` on the FraudProofVerifier, skipping ones already set
     */
    function authorizeFraudProofTokens(FraudProofVerifier fraudProofVerifier, uint256 chainId, address[] memory tokens)
        internal
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!fraudProofVerifier.authorizedTokens(chainId, tokens[i])) {
                fraudProofVerifier.setAuthorizedToken(chainId, tokens[i], true);
                console.log("  FraudProofVerifier: authorized token", tokens[i]);
            }
        }
    }
}
