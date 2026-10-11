// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeploymentHelper } from "../../script/utils/DeploymentAddresses.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";

/// @dev Stand-in for an older KernelFactory that has no STAKER() getter
contract LegacyFactoryWithoutStaker {
    address public immutable IMPLEMENTATION = address(1);
}

/// @notice Deploy scripts must not reuse a KernelFactory that trusts a different FactoryStaker
contract KernelFactoryStakerCheckTest is Test, DeploymentHelper {
    string internal constant MISMATCH =
        "Existing KernelFactory STAKER() does not match the FactoryStaker in use. Redeploy KernelFactory.";

    address internal staker = makeAddr("staker");

    function _factory(address factoryStaker) internal returns (address) {
        return address(new KernelFactory(address(this), IEntryPoint(makeAddr("entryPoint")), factoryStaker));
    }

    function check(address factory, address factoryStaker) external view {
        _requireFactoryStaker(factory, factoryStaker);
    }

    function test_MatchingStakerPasses() public {
        this.check(_factory(staker), staker);
    }

    function test_RevertsOnStakerMismatch() public {
        address factory = _factory(makeAddr("oldStaker"));
        vm.expectRevert(bytes(MISMATCH));
        this.check(factory, staker);
    }

    function test_RevertsOnFactoryWithoutStakerGetter() public {
        address legacy = address(new LegacyFactoryWithoutStaker());
        vm.expectRevert(bytes(MISMATCH));
        this.check(legacy, staker);
    }

    function test_RevertsOnFactoryWithoutCode() public {
        vm.expectRevert(bytes(MISMATCH));
        this.check(makeAddr("noCode"), staker);
    }
}
