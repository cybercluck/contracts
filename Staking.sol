// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "./Counters.sol";
import "./ERC721.sol";
import "./ReentrancyGuard.sol";
import "./Ownable.sol";
import "./IEggToken.sol";

contract Staking is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;

    bool public isStakingAvailable;
    uint256 public eggPerBlock;
    uint256 public totalAllocPoint;
    uint256 public totalAmountDepositedPool;
    uint256 public startBlock;
    uint256 public endBlock;
    
    struct StakingItem {
        uint256 itemId;
        address contractAddress;
        address owner;
        uint256 tokenId;
        uint256 poolId;
        bool isEnded;
    }

    struct PoolInfo {
        address contractAddress;
        uint256 allocPoint;
        uint256 eggPower;
        uint256 maxStakeCount;
        uint256 stakedCount;
        uint256[] tokenIds;
    }

    struct UserInfo {
        bool isStaked;
        uint256 pendingEgg;
        uint256 userEggPower;
        uint256 stakedCount;
        uint256 lastHarvestBlock;
    }

    mapping(uint256 => PoolInfo) public pools;
    mapping(uint256 => StakingItem) public items;
    mapping(address => uint256) public poolIdOfContract;
    mapping(address => mapping(uint256 => UserInfo)) public userInfo;
    mapping(uint256 => mapping(uint256 => bool)) public whitelistedTokenIds;
    mapping(uint256 => address[]) public stakedUsers;

    Counters.Counter public stakingPoolCount;
    Counters.Counter public stakingItemCount;
    
    IEggToken tokenEgg;

    event StakingItemCreated(
        uint256 itemId,
        address indexed nftContract,
        address indexed owner,
        uint256 tokenId
    );

    event Harvest(
        uint256 itemId,
        address indexed owner,
        uint256 amount
    );

    constructor(IEggToken _tokenEgg) {
        tokenEgg = _tokenEgg;
        totalAllocPoint = 0;
        eggPerBlock = 0;
        totalAmountDepositedPool = 0;
        isStakingAvailable = false;
    }

    function depositEggToPool(uint256 _totalAmountDepositedPool, uint256 _startBlock, uint256 _endBlock) public onlyOwner {
        require(tokenEgg.balanceOf(owner()) >= _totalAmountDepositedPool * 10 ** 18, "insufficient Egg amount to Deposit");
        require(_endBlock > block.number, "End Block must bigger than now");
        require(_endBlock > _startBlock, "End Block Number must bigger than Start Block Number");
        tokenEgg.transferFrom(owner(), address(this), _totalAmountDepositedPool * 10 ** 18);
        
        totalAmountDepositedPool = _totalAmountDepositedPool * 10 ** 6;
        startBlock = _startBlock;
        endBlock = _endBlock;
        eggPerBlock = totalAmountDepositedPool / (_endBlock - _startBlock);
        isStakingAvailable = true;
    }

    function addEggReward(uint256 _amountReward) public onlyOwner {
        require(tokenEgg.balanceOf(owner()) >=  _amountReward * 10 ** 18, "insufficient Egg amount to Deposit");
        require(block.number >= startBlock && block.number <= endBlock, "Now is not Staking Period");

        uint256 paidReward = 0;
        for(uint256 i = 1; i <= stakingPoolCount.current(); i ++) {
            for(uint256 j = 0; j < stakedUsers[i].length; j ++) {
                _updateUserInfo(i, stakedUsers[i][j]);
                paidReward += userInfo[stakedUsers[i][j]][i].pendingEgg;
            }
        }

        tokenEgg.transferFrom(owner(), address(this), _amountReward * 10 ** 18);

        uint256 remainReward = totalAmountDepositedPool - paidReward;
        remainReward += _amountReward * 10 ** 6;
        eggPerBlock = remainReward / (endBlock - block.number);
        totalAmountDepositedPool += _amountReward * 10 ** 6;
    }

    function setPeriod(uint256 _startBlock, uint256 _endBlock) public onlyOwner {
        require(_endBlock > block.number, "End Block must bigger than now");
        require(_endBlock > _startBlock, "End Block Number must bigger than Start Block Number");
        
        uint256 paidReward = 0;
        for(uint256 i = 1; i <= stakingPoolCount.current(); i ++) {
            for(uint256 j = 0; j < stakedUsers[i].length; j ++) {
                _updateUserInfo(i, stakedUsers[i][j]);
                paidReward += userInfo[stakedUsers[i][j]][i].pendingEgg;
            }
        }
        
        uint256 tmpBlockNumber = _startBlock;
        if(block.number > _startBlock || block.number > startBlock)
            tmpBlockNumber = block.number;

        uint256 remainReward = totalAmountDepositedPool - paidReward;
        
        eggPerBlock = remainReward / (_endBlock - tmpBlockNumber);

        startBlock = _startBlock;
        endBlock = _endBlock;
    }    

    function setIsStakingAvailable(bool _isStakingAvailable) public onlyOwner{
        isStakingAvailable = _isStakingAvailable;
    }

    function addPool(address _contractAddress, uint256 _allocPoint, uint256 _eggPower, uint256 _maxStakeCount) public onlyOwner {
        require(startBlock != 0 && endBlock != 0, "Reward Token not deposited yet!");
        stakingPoolCount.increment();
        uint256 poolId = stakingPoolCount.current();
        uint256[] memory tokenIds;
        pools[poolId] = PoolInfo(
            _contractAddress,
            _allocPoint,
            _eggPower,
            _maxStakeCount,
            0,
            tokenIds
        );

        poolIdOfContract[_contractAddress] = poolId;

        totalAllocPoint = totalAllocPoint + _allocPoint;
    }

    function setPoolIdOfContract(address _contractAddress, uint256 _poolId) public onlyOwner {
        poolIdOfContract[_contractAddress] = _poolId;
    }

    function setStakedCount(uint256 _poolId, uint256 _stakedCount) public onlyOwner {
        pools[_poolId].stakedCount = _stakedCount;
    }

    function updatePool(
        uint256 _poolId, 
        address _contractAddress, 
        uint256 _allocPoint, 
        uint256 _eggPower, 
        uint256 _maxStakeCount
    ) public onlyOwner {
        require(_poolId <= stakingPoolCount.current(), "invalid poolId");

        totalAllocPoint = totalAllocPoint - pools[_poolId].allocPoint;

        pools[_poolId] = PoolInfo(
            _contractAddress,
            _allocPoint,
            _eggPower,
            _maxStakeCount,
            pools[_poolId].stakedCount,
            pools[_poolId].tokenIds
        );

        poolIdOfContract[_contractAddress] = _poolId;

        totalAllocPoint = totalAllocPoint + _allocPoint;
    }

    function setTokenIds(uint256 _poolId, uint256[] calldata _tokenIds) public onlyOwner {
        PoolInfo storage _pool = pools[_poolId];

        for(uint256 i = 0; i < _pool.tokenIds.length; i ++) {
            whitelistedTokenIds[_poolId][_pool.tokenIds[i]] = false;
        }

        for(uint256 i = 0; i < _tokenIds.length; i ++) {
            whitelistedTokenIds[_poolId][_tokenIds[i]] = true;
        }

        _pool.tokenIds = _tokenIds;
    }

    modifier isValid(address _msgSender, address _contractAddress, uint256 _tokenId) {
        require(IERC721(_contractAddress).ownerOf(_tokenId) == _msgSender, "not owner");
        _;
    }

    function _updateUserInfo(uint256 _poolId, address _owner) internal {

        /**Update the Pending Egg for All Items */
        uint256 tmpEndBlock = 0;
        if(block.number > endBlock)
            tmpEndBlock = endBlock;
        else 
            tmpEndBlock = block.number;
        uint256 totalEggPower =  pools[_poolId].stakedCount * pools[_poolId].eggPower;

        UserInfo storage _userInfo = userInfo[_owner][_poolId];
        if(totalEggPower != 0 && _userInfo.lastHarvestBlock != 0)
            _userInfo.pendingEgg += eggPerBlock * (tmpEndBlock - _userInfo.lastHarvestBlock) * pools[_poolId].allocPoint / totalAllocPoint * _userInfo.userEggPower / totalEggPower;
        _userInfo.lastHarvestBlock = tmpEndBlock;
        /**End Update */
    }

    function stake(
        address _nftContract,
        uint256 _tokenId
    ) public nonReentrant isValid(msg.sender, _nftContract, _tokenId) {

        uint256 poolId = poolIdOfContract[_nftContract];

        require(block.number >= startBlock && block.number <= endBlock && isStakingAvailable == true, "Staking is not started!");
        require(poolId != 0, "There is no Contract Address in Pool");
        require(userInfo[msg.sender][poolId].stakedCount < pools[poolId].maxStakeCount, "Overflow of Max Staking Count");
        require(pools[poolId].tokenIds.length == 0 || whitelistedTokenIds[poolId][_tokenId] == true, "This token is not whitelisted!");

        if(userInfo[msg.sender][poolId].isStaked == false) {
            stakedUsers[poolId].push(msg.sender);
        }
        
        _updateUserInfo(poolId, msg.sender);

        stakingItemCount.increment();
        uint256 itemId = stakingItemCount.current();

        items[itemId] = StakingItem(
            itemId,
            _nftContract,
            msg.sender,
            _tokenId,
            poolId,
            false
        );

        IERC721(_nftContract).transferFrom(msg.sender, address(this), _tokenId);

        pools[poolId].stakedCount ++;
        userInfo[msg.sender][poolId].stakedCount ++;
        userInfo[msg.sender][poolId].userEggPower += pools[poolId].eggPower;
        userInfo[msg.sender][poolId].isStaked = true;
        emit StakingItemCreated(
            itemId,
            _nftContract,
            msg.sender,
            _tokenId
        );
    }

    function harvest(uint256 _poolId) public {

        _updateUserInfo(_poolId, msg.sender);
        uint256 userPendingEgg = userInfo[msg.sender][_poolId].pendingEgg;

        require(tokenEgg.balanceOf(address(this)) >= userPendingEgg * 10 ** 12, "insufficient Egg amount to Harvest");
        
        tokenEgg.transfer(msg.sender, userPendingEgg * 10 ** 12);

        userInfo[msg.sender][_poolId].pendingEgg = 0;
    }

    function getPendingEgg(uint256 _poolId, address _owner) public view returns(uint256){
        uint256 tmpEndBlock = 0;
        uint256 totalEggPower =  pools[_poolId].stakedCount * pools[_poolId].eggPower;
        UserInfo storage _userInfo = userInfo[_owner][_poolId];

        if(block.number > endBlock)
            tmpEndBlock = endBlock;
        else 
            tmpEndBlock = block.number;
        
        uint256 amount = 0;
        if(totalEggPower != 0)
            amount = eggPerBlock * (tmpEndBlock - _userInfo.lastHarvestBlock) * pools[_poolId].allocPoint / totalAllocPoint * _userInfo.userEggPower / totalEggPower;
        amount += _userInfo.pendingEgg;
        return amount;
    }

    function getWhitelistedTokenIds(uint256 _poolId) public view returns(uint256[] memory) {
        return pools[_poolId].tokenIds;
    }

    function getStakedItems(address _owner) public view returns(StakingItem[] memory){
        uint256 totalItemCount = stakingItemCount.current();
        uint256 itemCount = 0;
        uint256 currentIndex = 0;

        for(uint256 i = 1; i <= totalItemCount; i ++) {
            if(_owner == items[i].owner && items[i].isEnded == false) {
                itemCount += 1;
            }
        }

        StakingItem[] memory stakedItems = new StakingItem[](itemCount);
    
        for (uint256 i = 1; i <= totalItemCount; i ++) {
            if(_owner == items[i].owner && items[i].isEnded == false) {
                StakingItem storage currentItem = items[i];
                stakedItems[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }

        return stakedItems;

    }
   
    function getBlockNumber() public view returns(uint256) {
        return block.number;
    }

    function getTotalEggPower(uint256 _poolId) public view returns(uint256) {
        uint256 totalEggPower =  pools[_poolId].stakedCount * pools[_poolId].eggPower;
        return totalEggPower;
    }

    function getMyEggPower(uint256 _poolId, address _owner) public view returns(uint256) {
        return userInfo[_owner][_poolId].userEggPower;
    }

    function getDailyEggRate(uint256 _poolId) public view returns(uint256) {
        uint256 totalEggPower = getTotalEggPower(_poolId);
        uint256 dailyRate = 0;
        if(totalEggPower != 0)
            dailyRate = eggPerBlock * 20 * 60 * 24 * 100 / totalEggPower * pools[_poolId].allocPoint / totalAllocPoint;
        return dailyRate;
    }

    function unstake(
        uint256 _itemId
    ) public {
        StakingItem storage item = items[_itemId];

        require(item.owner == msg.sender, "you are not owner");
        require(item.isEnded == false, "This Staking Item was unstaked already!");

        _updateUserInfo(item.poolId, msg.sender);
        harvest(item.poolId);

        IERC721(item.contractAddress).transferFrom(address(this), msg.sender, item.tokenId);
        item.isEnded = true;
        pools[item.poolId].stakedCount --;
        userInfo[msg.sender][item.poolId].userEggPower -= pools[item.poolId].eggPower;
        userInfo[msg.sender][item.poolId].stakedCount --;
    }

    function withdraw() public onlyOwner {
        require(block.number > endBlock, "Staking is not finished");
        uint256 remainBalance = tokenEgg.balanceOf(address(this));
        tokenEgg.transfer(owner(), remainBalance);
        isStakingAvailable = false;
    }
}