// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { KernelFactory } from "./KernelFactory.sol";
import { IEntryPoint } from "../../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { Ownable } from "solady/auth/Ownable.sol";

contract FactoryStaker is Ownable {
    mapping(KernelFactory => bool) public approved;

    error NotApprovedFactory();
    error NotCalledFromEntryPoint();

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    function deployWithFactory(KernelFactory factory, bytes calldata createData, bytes32 salt)
        external
        payable
        returns (address)
    {
        if (!approved[factory]) {
            revert NotApprovedFactory();
        }
        // KernelFactory trusts this contract in place of the SenderCreator, so enforce the
        // SenderCreator check here. Read the factory's cached copy: calling the EntryPoint during
        // account creation is forbidden by ERC-7562 (OP-054).
        if (msg.sender != factory.SENDER_CREATOR()) {
            revert NotCalledFromEntryPoint();
        }
        return factory.createAccount(createData, salt);
    }

    function approveFactory(KernelFactory factory, bool approval) external payable onlyOwner {
        approved[factory] = approval;
    }

    function stake(IEntryPoint entryPoint, uint32 unstakeDelay) external payable onlyOwner {
        entryPoint.addStake{ value: msg.value }(unstakeDelay);
    }

    function unlockStake(IEntryPoint entryPoint) external payable onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(IEntryPoint entryPoint, address payable recipient) external payable onlyOwner {
        entryPoint.withdrawStake(recipient);
    }
}
