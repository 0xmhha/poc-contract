// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title P256
 * @notice Helper library for P256 (secp256r1) signature verification
 * @dev Based on kernel-7579-plugins P256.sol by ZeroDev
 *      Supports both EIP-7212 precompile and Daimo's Solidity-based P256Verifier fallback
 */
library P256 {
    /// @notice Daimo P256Verifier deployed at deterministic address
    address constant DAIMO_VERIFIER = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

    /// @notice EIP-7212 P256VERIFY precompile address
    address constant PRECOMPILED_VERIFIER = 0x0000000000000000000000000000000000000100;

    /// @notice P256 curve order n/2 for signature malleability check
    uint256 constant P256_N_DIV_2 = 57896044605178124381348723474703786764998477612067880171211129530534256022184;

    /**
     * @notice Verify P256 signature with malleability check
     * @param messageHash The message hash
     * @param r Signature r component
     * @param s Signature s component
     * @param x Public key X coordinate
     * @param y Public key Y coordinate
     * @param usePrecompiled Whether to try precompile first
     * @return True if signature is valid
     */
    function verifySignature(bytes32 messageHash, uint256 r, uint256 s, uint256 x, uint256 y, bool usePrecompiled)
        internal
        view
        returns (bool)
    {
        // Reject malleable signatures (s must be in lower half of curve order)
        if (s > P256_N_DIV_2) {
            return false;
        }

        return verifySignatureAllowMalleability(messageHash, r, s, x, y, usePrecompiled);
    }

    /**
     * @notice Verify P256 signature without malleability check
     * @param messageHash The message hash
     * @param r Signature r component
     * @param s Signature s component
     * @param x Public key X coordinate
     * @param y Public key Y coordinate
     * @param usePrecompiled Whether to try precompile first
     * @return True if signature is valid
     */
    function verifySignatureAllowMalleability(
        bytes32 messageHash,
        uint256 r,
        uint256 s,
        uint256 x,
        uint256 y,
        bool usePrecompiled
    ) internal view returns (bool) {
        bytes memory args = abi.encode(messageHash, r, s, x, y);

        if (usePrecompiled) {
            (bool success, bytes memory ret) = PRECOMPILED_VERIFIER.staticcall(args);
            if (success && ret.length > 0) {
                return abi.decode(ret, (uint256)) == 1;
            }
            // Precompile not available, fall through to Daimo verifier
        }

        // Fallback: Daimo P256Verifier (Solidity-based)
        (bool daimoSuccess, bytes memory daimoRet) = DAIMO_VERIFIER.staticcall(args);
        if (daimoSuccess && daimoRet.length > 0) {
            return abi.decode(daimoRet, (uint256)) == 1;
        }

        return false;
    }
}
