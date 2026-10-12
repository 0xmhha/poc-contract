// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployAllScript } from "../../script/deploy-contract/DeployAll.s.sol";
import { DeploymentAddresses } from "../../script/utils/DeploymentAddresses.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";

contract ForceDeployHarness is DeployAllScript {
    function configure(address owner) external {
        admin = owner;
        forceRedeploy = true;
    }

    function deployCore() external {
        _deployPhase0BaseInfrastructure();
        _deployPhase1CoreSmartAccount();
    }

    function cached(string memory key) external view returns (address) {
        return _addresses[key];
    }
}

contract DeployAllForceTest is Test {
    function test_ForceRedeployPreservesFreshDependencyAddresses() public {
        // Scripts include every contract's creation code and exceed ordinary contract size limits.
        // Install the script runtime directly; its core deployment calls still execute normally.
        address scriptAddress = address(0xD3E10);
        vm.etch(scriptAddress, vm.getDeployedCode("DeployAllForce.t.sol:ForceDeployHarness"));
        ForceDeployHarness deployment = ForceDeployHarness(scriptAddress);
        deployment.configure(address(deployment));
        deployment.deployCore();
        address firstKernel = deployment.cached(DeploymentAddresses.KEY_KERNEL);
        address firstFactory = deployment.cached(DeploymentAddresses.KEY_KERNEL_FACTORY);
        assertGt(firstKernel.code.length, 0);
        deployment.deployCore();
        address kernel = deployment.cached(DeploymentAddresses.KEY_KERNEL);
        address factory = deployment.cached(DeploymentAddresses.KEY_KERNEL_FACTORY);
        address entryPoint = deployment.cached(DeploymentAddresses.KEY_ENTRYPOINT);
        address staker = deployment.cached(DeploymentAddresses.KEY_FACTORY_STAKER);
        assertTrue(kernel != firstKernel);
        assertTrue(factory != firstFactory);
        assertGt(entryPoint.code.length, 0);
        assertGt(staker.code.length, 0);
        assertEq(KernelFactory(factory).IMPLEMENTATION(), kernel);
        assertEq(address(KernelFactory(factory).ENTRYPOINT()), entryPoint);
        assertEq(KernelFactory(factory).STAKER(), staker);
    }
}
