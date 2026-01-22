// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BridgeDeploymentHelper} from "../../script/DeployBridge.s.sol";

contract BridgeDeploymentSimulationTest is Test, BridgeDeploymentHelper {
    function testBridgeDeploymentWiring() public {
        BridgeDeploymentConfig memory config;
        config.deployer = address(this);
        config.feeRecipient = address(0xFEE);

        address[] memory signers = new address[](3);
        signers[0] = address(0x1);
        signers[1] = address(0x2);
        signers[2] = address(0x3);
        config.signers = signers;
        config.signerThreshold = 2;

        address[] memory guardians = new address[](3);
        guardians[0] = address(0xA1);
        guardians[1] = address(0xA2);
        guardians[2] = address(0xA3);
        config.guardians = guardians;
        config.guardianThreshold = 2;

        BridgeDeploymentArtifacts memory artifacts = _deployBridge(config);

        // SecureBridge wiring
        assertEq(address(artifacts.secureBridge.bridgeValidator()), address(artifacts.bridgeValidator), "validator wiring");
        assertEq(address(artifacts.secureBridge.guardian()), address(artifacts.bridgeGuardian), "guardian wiring");
        assertEq(address(artifacts.secureBridge.rateLimiter()), address(artifacts.bridgeRateLimiter), "rate limiter wiring");
        assertEq(address(artifacts.secureBridge.optimisticVerifier()), address(artifacts.optimisticVerifier), "optimistic verifier wiring");
        assertEq(artifacts.secureBridge.feeRecipient(), config.feeRecipient, "fee recipient");

        // Cross-contract authorizations
        assertTrue(artifacts.bridgeRateLimiter.authorizedCallers(address(artifacts.secureBridge)), "rate limiter auth");
        assertTrue(artifacts.optimisticVerifier.authorizedCallers(address(artifacts.secureBridge)), "optimistic verifier auth");
        assertEq(artifacts.bridgeGuardian.bridgeTarget(), address(artifacts.secureBridge), "guardian target");

        // Fraud proof links
        assertEq(artifacts.optimisticVerifier.fraudProofVerifier(), address(artifacts.fraudProofVerifier), "optimistic->fraud");
        assertEq(artifacts.fraudProofVerifier.optimisticVerifier(), address(artifacts.optimisticVerifier), "fraud->optimistic");
        assertEq(artifacts.fraudProofVerifier.bridgeValidator(), address(artifacts.bridgeValidator), "fraud validator");
    }
}
