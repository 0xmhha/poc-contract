// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {EntryPoint} from "../../src/erc4337-entrypoint/EntryPoint.sol";

contract DeployEntryPointScript is DeploymentHelper {
    EntryPoint public entryPoint;

    function setUp() public {}

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        address existing = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        if (existing == address(0)) {
            entryPoint = new EntryPoint();
            _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
            console.log("EntryPoint deployed at:", address(entryPoint));
            console.log("SenderCreator deployed at:", address(entryPoint.senderCreator()));
        } else {
            entryPoint = EntryPoint(payable(existing));
            console.log("EntryPoint: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();
    }
}
