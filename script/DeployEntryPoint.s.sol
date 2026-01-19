// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { EntryPoint } from "../src/erc4337-entrypoint/EntryPoint.sol";

contract DeployEntryPointScript is Script {
    EntryPoint public entryPoint;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        entryPoint = new EntryPoint();

        console.log("EntryPoint deployed at:", address(entryPoint));
        console.log("SenderCreator deployed at:", address(entryPoint.senderCreator()));

        vm.stopBroadcast();
    }
}
