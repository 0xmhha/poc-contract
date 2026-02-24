// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PaymasterPayload
 * @notice Type-specific payload encoders/decoders for envelope payloads
 * @dev Each paymaster type defines its own payload struct.
 *      Payloads are ABI-encoded inside the envelope's payload field.
 */
library PaymasterPayload {
    // ============ Payload Structs ============

    /// @notice Type 0 – Verifying Paymaster payload
    struct VerifyingPayload {
        bytes32 policyId;
        address sponsor;
        uint256 maxCost;
        bytes verifierExtra;
    }

    /// @notice Type 1 – Sponsor Paymaster payload (Visa 4-Party model)
    struct SponsorPayload {
        bytes32 campaignId;
        uint256 perUserLimit;
        address targetContract;
        bytes4 targetSelector;
        bytes sponsorExtra;
    }

    /// @notice Type 2 – ERC-20 Paymaster payload
    struct Erc20Payload {
        address token;
        uint256 maxTokenCost;
        uint256 quoteId;
        bytes erc20Extra;
    }

    /// @notice Type 3 – Permit2 Paymaster payload
    struct Permit2Payload {
        address token;
        uint160 permitAmount;
        uint48 permitExpiration;
        uint48 permitNonce;
        bytes permitSig;
        bytes permit2Extra;
    }

    // ============ Encoders ============

    function encodeVerifying(VerifyingPayload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.policyId, p.sponsor, p.maxCost, p.verifierExtra);
    }

    function encodeSponsor(SponsorPayload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.campaignId, p.perUserLimit, p.targetContract, p.targetSelector, p.sponsorExtra);
    }

    function encodeErc20(Erc20Payload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.token, p.maxTokenCost, p.quoteId, p.erc20Extra);
    }

    function encodePermit2(Permit2Payload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.token, p.permitAmount, p.permitExpiration, p.permitNonce, p.permitSig, p.permit2Extra);
    }

    // ============ Decoders ============

    function decodeVerifying(bytes memory payload) internal pure returns (VerifyingPayload memory p) {
        (p.policyId, p.sponsor, p.maxCost, p.verifierExtra) = abi.decode(payload, (bytes32, address, uint256, bytes));
    }

    function decodeSponsor(bytes memory payload) internal pure returns (SponsorPayload memory p) {
        (p.campaignId, p.perUserLimit, p.targetContract, p.targetSelector, p.sponsorExtra) =
            abi.decode(payload, (bytes32, uint256, address, bytes4, bytes));
    }

    function decodeErc20(bytes memory payload) internal pure returns (Erc20Payload memory p) {
        (p.token, p.maxTokenCost, p.quoteId, p.erc20Extra) = abi.decode(payload, (address, uint256, uint256, bytes));
    }

    function decodePermit2(bytes memory payload) internal pure returns (Permit2Payload memory p) {
        (p.token, p.permitAmount, p.permitExpiration, p.permitNonce, p.permitSig, p.permit2Extra) =
            abi.decode(payload, (address, uint160, uint48, uint48, bytes, bytes));
    }
}
