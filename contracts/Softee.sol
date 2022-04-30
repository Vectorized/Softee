// SPDX-License-Identifier: MIT
// Author: vectorized.eth
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IERC721AFull.sol";

/**
 * @dev A simple soft staking contract for ERC721AQueryable.
 *
 * Warning: this code is still under construction. Do not use for production.
 */
contract Softee is Ownable {
    /**
     * Staking is closed. You can only unstake.
     */
    error StakingNotOpened();

    /**
     * Harvesting is closed.
     */
    error HarvestNotOpened();

    /**
     * Coin is already initialized.
     */
    error CoinInitialized();

    /**
     * Coin withdrawals are locked.
     */
    error WithdrawsLocked();

    /**
     * Cannot set timelock to a value less than the current value.
     */
    error InvalidTimelock();
    
    /**
     * @dev An entry in the vault.
     */
    struct Stake {
        // The address of the owner.
        address addr;
        // The start timestamp of token ownership.
        uint48 startTimestamp;
        // The last harvested timestamp.
        uint48 lastHarvested;
    }

    /**
     * @dev The vault. 
     */
    mapping(uint256 => Stake) private _vault;

    /**
     * @dev Total amount of coin distributed.
     */
    uint256 public distributed;

    /**
     * @dev Amount of coin harvestable per second per NFT staked.
     */
    uint256 public harvestRate;

    /**
     * @dev Minimum number of seconds since the last harvest for coin to be harvestable.
     */
    uint256 public harvestTimeThreshold;

    /**
     * @dev The address of the NFT contract.
     */
    IERC721AFull public immutable nft;

    /**
     * @dev The address of the coin contract.
     */
    IERC20 public coin;

    /**
     * @dev The timestamp before which coin withdrawals are blocked.
     */
    uint64 public coinWithdrawTimelock;

    /**
     * @dev Whether harvesting is turned on.
     */
    bool public harvestOpened;

    /**
     * @dev Whether staking is turned on.
     */
    bool public stakingOpened;

    /**
     * @dev Constructor. 
     * 
     * If the `coin_` has not yet been published, set it to the zero address.
     */
    constructor(address nft_, address coin_) {
        nft = IERC721AFull(nft_);
        coin = IERC20(coin_);
    }

    /**
     * @dev Initializes the coin address.
     *
     * Will reset the `distributed` to zero.
     */
    function initCoin(address addr) external onlyOwner {
        if (address(coin) != address(0)) revert CoinInitialized();
        coin = IERC20(addr);
    }

    function setCoinWithdrawTimelock(uint64 value) external onlyOwner {
        if (value < coinWithdrawTimelock) revert InvalidTimelock();
        coinWithdrawTimelock = value;
    }

    /**
     * @dev Sets the harvest rate.
     */
    function setHarvestRate(uint256 value) external onlyOwner {
        harvestRate = value;
    }

    /**
     * @dev Sets the minimum time staked for coins to be harvestable.
     */
    function setHarvestTimeThreshold(uint256 value) external onlyOwner {
        harvestTimeThreshold = value;
    }

    /**
     * @dev Opens harvesting.
     */
    function openHarvest() external onlyOwner {
        harvestOpened = true;
    }

    /**
     * @dev Closes harvesting.
     */
    function closeHarvest() external onlyOwner {
        harvestOpened = false;
    }

    /**
     * @dev Opens staking.
     */
    function openStaking() external onlyOwner {
        stakingOpened = true;
    }

    /**
     * @dev Closes staking.
     */
    function closeStaking() external onlyOwner {
        stakingOpened = false;
    }

    /**
     * @dev Withdraws all the coins.
     */
    function withdrawCoin() external onlyOwner {
        if (block.timestamp < coinWithdrawTimelock) revert WithdrawsLocked();
        uint256 amount = coin.balanceOf(address(this));
        coin.transfer(msg.sender, amount);
    }

    /**
     * @dev Stake the `tokenIds`.
     *
     * Each of the `tokenIds` must be owned by `msg.sender`, or else it will be skipped.
     */
    function stake(uint256[] calldata tokenIds) external {
        unchecked {
            if (!stakingOpened) revert StakingNotOpened();

            uint256 tokenIdsLength = tokenIds.length;
            for (uint256 i; i < tokenIdsLength; ++i) {
                uint256 tokenId = tokenIds[i];
                IERC721AFull.TokenOwnership memory ownership = nft.explicitOwnershipOf(tokenId);

                // If not owned by the sender, skip.
                if (ownership.burned || ownership.addr != msg.sender) continue;

                // If already staked, skip.
                if (_vault[tokenId].addr == ownership.addr && 
                    _vault[tokenId].startTimestamp == ownership.startTimestamp) continue;

                // Initialize the vault entry.
                _vault[tokenId].addr = ownership.addr;
                _vault[tokenId].startTimestamp = uint48(ownership.startTimestamp);
                _vault[tokenId].lastHarvested = uint48(block.timestamp);
            }    
        }
    }

    /**
     * @dev Returns whether the `tokenId` is staked.
     */
    function isStaked(uint256 tokenId) public view returns (bool) {
        unchecked {
            IERC721AFull.TokenOwnership memory ownership = nft.explicitOwnershipOf(tokenId);
            return (
                ownership.burned == false && 
                ownership.addr != address(0) &&
                _vault[tokenId].addr == ownership.addr && 
                _vault[tokenId].startTimestamp == ownership.startTimestamp
            );    
        }
    }

    /**
     * @dev Returns an array containing the token IDs that are staked within `tokenIDs`.
     *
     * This function is NOT intended for on-chain calling.
     */
    function filterStaked(uint256[] calldata tokenIds) external view returns (uint256[] memory) {
        unchecked {
            uint256 tokenIdsLength = tokenIds.length;
            uint256[] memory filtered = new uint256[](tokenIdsLength);
            if (tokenIdsLength == 0) {
                return filtered;
            }
            uint256 filteredIdx;
            for (uint256 i; i < tokenIdsLength; ++i) {
                uint256 tokenId = tokenIds[i];
                if (isStaked(tokenId)) {
                    filtered[filteredIdx++] = tokenId;
                }
            }
            // Downsize the array to fit.
            assembly {
                mstore(filtered, filteredIdx)
            }
            return filtered;    
        }
    }

    /**
     * @dev Returns an array of the staked token IDs owned by `owner`.
     *
     * If the collection is too big for this to be called in a single tx,
     * break the array up and call `filterStaked` multiple times.
     *
     * This function is NOT intended for on-chain calling.
     */
    function staked(address owner) external view returns (uint256[] memory) {
        return this.filterStaked(IERC721AFull(nft).tokensOfOwner(owner));
    }

    /**
     * @dev Harvests the coins from the `tokenIds`. 
     * 
     * Each of the `tokenIds` must be owned by `msg.sender`, or else it will be skipped.
     *
     * To estimate the amount of coins harvestable in web3 without sending a tx, you can use:
     * `contract.harvest.apply(undefined, tokenIds).call({ from: walletAddress }).then(...)`.
     */
    function harvest(uint256[] calldata tokenIds) external returns (uint256) {
        unchecked {
            if (!harvestOpened) revert HarvestNotOpened();
            uint256 harvestTimeThresholdCached = harvestTimeThreshold;
            uint256 harvestRateCached = harvestRate;

            uint256 tokenIdsLength = tokenIds.length;
            uint256 amount;
            
            for (uint256 i; i < tokenIdsLength; ++i) {
                uint256 tokenId = tokenIds[i];
                IERC721AFull.TokenOwnership memory ownership = nft.explicitOwnershipOf(tokenId);
                
                // If not owned by the sender, skip.
                if (ownership.burned || ownership.addr != msg.sender) continue;

                // If not staked, skip.
                if (_vault[tokenId].addr != ownership.addr ||
                    _vault[tokenId].startTimestamp != ownership.startTimestamp) continue;

                uint256 timeDiff = uint256(_vault[tokenId].lastHarvested) - block.timestamp;
                // If not enough time has passed, skip.
                if (timeDiff < harvestTimeThresholdCached) continue;

                amount += harvestRateCached * timeDiff;
                _vault[tokenId].lastHarvested = uint48(block.timestamp);
            }
            distributed += amount;
            coin.transfer(msg.sender, amount);
            return amount;
        }
    }

    /**
     * @dev Unstake the `tokenIds`.
     * 
     * Each of the `tokenIds` must be owned by `msg.sender`, or else it will be skipped.
     */
    function unstake(uint256[] calldata tokenIds) external {
        unchecked {
            uint256 tokenIdsLength = tokenIds.length;
            for (uint256 i; i < tokenIdsLength; ++i) {
                uint256 tokenId = tokenIds[i];
                IERC721AFull.TokenOwnership memory ownership = nft.explicitOwnershipOf(tokenId);
                
                // If not owned by the sender, skip.
                if (ownership.burned || ownership.addr != msg.sender) continue;
                
                // If not staked, skip.
                if (_vault[tokenId].addr != ownership.addr ||
                    _vault[tokenId].startTimestamp != ownership.startTimestamp) continue;
                
                // Delete the vault entry.
                delete _vault[tokenId];
            }
        }
    }
}