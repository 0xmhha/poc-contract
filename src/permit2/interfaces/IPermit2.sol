// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Uniswap Labs
// Adapted for StableNet PoC - Solidity version updated to ^0.8.28
pragma solidity ^0.8.28;

import { ISignatureTransfer } from "./ISignatureTransfer.sol";
import { IAllowanceTransfer } from "./IAllowanceTransfer.sol";

/// @notice Permit2 handles signature-based transfers in SignatureTransfer and allowance-based transfers in
/// AllowanceTransfer. @dev Users must approve Permit2 before calling any of the transfer functions.
interface IPermit2 is ISignatureTransfer, IAllowanceTransfer {
    // IPermit2 unifies the two interfaces so users have maximal flexibility with their approval.

    }
