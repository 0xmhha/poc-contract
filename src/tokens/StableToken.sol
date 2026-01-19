// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StableToken (USDC)
 * @notice USD-pegged stablecoin implementation
 * @dev Features:
 *      - 6 decimals (standard for USDC)
 *      - Minter role for authorized minting
 *      - Blacklist functionality for compliance
 *      - Pausable for emergency situations
 *      - Compatible with ERC-4337 paymasters for gas payment
 *
 * Use Cases:
 * - Gas fee payment through ERC20Paymaster
 * - Subscription payments
 * - DeFi integrations (lending, DEX)
 * - Cross-border payments
 */
contract StableToken is ERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token name
    string private constant _NAME = "USD Coin";

    /// @notice Token symbol
    string private constant _SYMBOL = "USDC";

    /// @notice Token decimals (6 for USDC standard)
    uint8 private constant _DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of authorized minters
    mapping(address => bool) public minters;

    /// @notice Mapping of blacklisted addresses
    mapping(address => bool) public blacklisted;

    /// @notice Paused state
    bool public paused;

    /// @notice Total minted amount (for tracking)
    uint256 public totalMinted;

    /// @notice Total burned amount (for tracking)
    uint256 public totalBurned;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Mint(address indexed minter, address indexed to, uint256 amount);
    event Burn(address indexed burner, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMinter();
    error Blacklist();
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMinter() {
        _checkMinter();
        _;
    }

    function _checkMinter() internal view {
        if (!minters[msg.sender]) revert NotMinter();
    }

    modifier notBlacklisted(address account) {
        _checkNotBlacklisted(account);
        _;
    }

    function _checkNotBlacklisted(address account) internal view {
        if (blacklisted[account]) revert Blacklist();
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    function _checkNotPaused() internal view {
        if (paused) revert ContractPaused();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructor
     * @param owner_ The owner address
     */
    constructor(address owner_) Ownable(owner_) {
        // Owner is the initial minter
        minters[owner_] = true;
        emit MinterAdded(owner_);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the name of the token
    function name() public pure virtual override returns (string memory) {
        return _NAME;
    }

    /// @dev Returns the symbol of the token
    function symbol() public pure virtual override returns (string memory) {
        return _SYMBOL;
    }

    /// @dev Returns the decimals of the token
    function decimals() public pure virtual override returns (uint8) {
        return _DECIMALS;
    }

    /*//////////////////////////////////////////////////////////////
                           MINTER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a minter
     * @param minter The address to add as minter
     */
    function addMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    /**
     * @notice Remove a minter
     * @param minter The address to remove as minter
     */
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    /*//////////////////////////////////////////////////////////////
                         BLACKLIST MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Blacklist an address
     * @param account The address to blacklist
     */
    function blacklist(address account) external onlyOwner {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Remove an address from blacklist
     * @param account The address to unblacklist
     */
    function unBlacklist(address account) external onlyOwner {
        blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           MINT / BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint tokens to an address
     * @param to The recipient address
     * @param amount The amount to mint
     */
    function mint(address to, uint256 amount)
        external
        onlyMinter
        whenNotPaused
        notBlacklisted(to)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);
        totalMinted += amount;

        emit Mint(msg.sender, to, amount);
    }

    /**
     * @notice Burn tokens from caller
     * @param amount The amount to burn
     */
    function burn(uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();

        _burn(msg.sender, amount);
        totalBurned += amount;

        emit Burn(msg.sender, amount);
    }

    /**
     * @notice Burn tokens from an address (requires allowance)
     * @param from The address to burn from
     * @param amount The amount to burn
     */
    function burnFrom(address from, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(from)
        notBlacklisted(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();

        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
        totalBurned += amount;

        emit Burn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens with blacklist and pause checks
     * @param to The recipient
     * @param amount The amount
     * @return Success
     */
    function transfer(address to, uint256 amount)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        returns (bool)
    {
        return super.transfer(to, amount);
    }

    /**
     * @notice Transfer tokens from with blacklist and pause checks
     * @param from The sender
     * @param to The recipient
     * @param amount The amount
     * @return Success
     */
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        whenNotPaused
        notBlacklisted(from)
        notBlacklisted(to)
        notBlacklisted(msg.sender)
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }

    /**
     * @notice Approve with blacklist check
     * @param spender The spender
     * @param amount The amount
     * @return Success
     */
    function approve(address spender, uint256 amount)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(spender)
        returns (bool)
    {
        return super.approve(spender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get circulating supply
     * @return The circulating supply (minted - burned)
     */
    function circulatingSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }

    /**
     * @notice Check if an address is a minter
     * @param account The address to check
     * @return True if minter
     */
    function isMinter(address account) external view returns (bool) {
        return minters[account];
    }

    /**
     * @notice Check if an address is blacklisted
     * @param account The address to check
     * @return True if blacklisted
     */
    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }
}
