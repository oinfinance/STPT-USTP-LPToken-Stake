pragma solidity >=0.5.0 <0.8.0;

import "./Math.sol";
import "./SafeMath.sol";
import "./STPT.sol";
import "./IERC20.sol";
import "./Owned.sol";
import "./IDparam.sol";
import "./WhiteList.sol";

interface IESM {
    function isStakePaused() external view returns (bool);

    function isRedeemPaused() external view returns (bool);

    function isClosed() external view returns (bool);

    function time() external view returns (uint256);

    function shutdown() external;
}

contract SLPStake is Owned, WhiteList {
    using Math for uint256;
    using SafeMath for uint256;
    
       /**
     * @notice Struct reward pools state
     * @param index Accumulated earnings index
     * @param block Update index, updating blockNumber together
     */
    struct RewardState {
        uint256 index;
        uint256 block;
    }
    /**
     * @notice reward pools state
     * @param index Accumulated earnings index by staker
     * @param reward Accumulative reward
     */
    struct StakerState {
        uint256 index;
        uint256 reward;
    }
    
      /// @notice TThe reward pool put into by the project side 
    uint256 public reward;
    /// @notice The number of token per-block 
    uint256 public rewardSpeed = 11.57e18;
    /// @notice Inital index  
    uint256 public initialIndex = 1e36;
    /// @notice Amplification factor 
    uint256 public doubleScale = 1e36;
    /// @notice The instance reward pools state
    RewardState public rewardState;

    /// @notice All staker-instances state 
    mapping(address => StakerState) public stakerStates;
    
    /// @notice Token address
    STPTToken token;
    IERC20 coin;
    /// @notice The amount by staker with token
    mapping(address => uint256) public tokens;
    /// @notice The total amount of out-coin in sys
    uint256 public totalToken;
       /// @notice Dparam address
    IDparam params;
    /// @notice Esm address
    IESM esm;
    

    /// @notice Setup Dparam address success
    event SetupParam(address param);
    /// @notice Setup Esm address success
    event SetupEsm(address esm);
    /// @notice Setup Token&Coin address success
    event SetupCoin(address token,address coin);
    /// @notice Stake success
    event StakeEvent(uint256 token);
    /// @notice redeem success
    event RedeemEvent(uint256 token);
    /// @notice Update index success
    event IndexUpdate(uint256 delt, uint256 block, uint256 index);
    /// @notice ClaimToken success
    event ClaimToken(address holder, uint256 amount);
    /// @notice InjectReward success
    event InjectReward(uint256 amount);
    /// @notice ExtractReward success
    event ExtractReward(address reciver, uint256 amount);

     constructor(address _esm) public Owned(msg.sender) {
          esm = IESM(_esm);
       rewardState = RewardState(initialIndex, getBlockNumber());
    }
    
      /**
     * @notice get StableToken address.
     * @return ERC20 address
     */
    function getTokenAddress() public view returns (address) {
        return address(token);
    }

    /**
     * @notice inject token address & coin address only once.
     * @param _token token address
     */
    function setup(address _token,address _coin) public onlyWhiter {
        token = STPTToken(_token);
        coin = IERC20(_coin);
        emit SetupCoin(_token,_coin);
    }
    
     /**
     * @notice Get the number of debt by the `account` 
     * @param account token address
     * @return (tokenAmount)
     */
    function debtOf(address account) public view returns (uint256) {
        return (tokens[account]);
    }
    
     /**
     * @notice Normally redeem anyAmount internal
     */
    function stake(uint256 tokenAmount) public {
        require(!esm.isStakePaused(), "Stake paused");
        
        address from = msg.sender;
        
        accuredToken(from);
        
        token.transferFrom(from, address(this), tokenAmount);
  
        totalToken = totalToken.add(tokenAmount);
        tokens[from] = tokens[from].add(tokenAmount);
        emit StakeEvent(tokenAmount);
    }
    
    /**
     * @notice Normally redeem anyAmount internal 
     * @param receiver Address of receiving
     */
    function _normalRedeem(uint256 tokenAmount, address receiver)
        internal
            {
        require(!esm.isRedeemPaused(), "Redeem paused");
        address staker = msg.sender;
        require(tokens[staker] > 0, "No collateral");
        require(tokenAmount > 0, "The quantity is less than zero");
        require(tokenAmount <= tokens[staker], "input amount overflow");

        accuredToken(staker);
        token.transfer(receiver, tokenAmount);

        tokens[staker] = tokens[staker].sub(tokenAmount);
        totalToken = totalToken.sub(tokenAmount);

        emit RedeemEvent(tokenAmount);
    }
    

    
    /**
     * @notice Abnormally redeem anyAmount internal
     * @param receiver Address of receiving
     */
    function _abnormalRedeem(uint256 tokenAmount, address receiver) internal {
        require(esm.isClosed(), "System not Closed yet.");
        address from = msg.sender;
        require(tokenAmount > 0, "The quantity is less than zero");
        require(token.balanceOf(from) > 0, "The coin no balance.");
        require(tokenAmount <= token.balanceOf(from), "Coin balance exceed");

        token.transfer(receiver, tokenAmount);
        tokens[from] = tokens[from].sub(tokenAmount);
        totalToken = totalToken.sub(tokenAmount);

        emit RedeemEvent(tokenAmount);
    }

    /**
     * @notice Normally redeem anyAmount 
     * @param receiver Address of receiving
     */
    function redeem(uint256 tokenAmount, address receiver) public {
        _normalRedeem(tokenAmount, receiver);
    }

    /**
     * @notice Normally redeem anyAmount to msg.sender 
     */
    function redeem(uint256 tokenAmount) public {
        redeem(tokenAmount, msg.sender);
    }

    /**
     * @notice normally redeem them all at once 
     * @param holder reciver
     */
    function redeemMax(address holder) public {
        redeem(tokens[msg.sender], holder);
    }

    /**
     * @notice normally redeem them all at once to msg.sender 
     */
    function redeemMax() public {
        redeemMax(msg.sender);
    }

    /**
     * @notice System shutdown under the redemption rule 
     * @param tokenAmount The number coin
     * @param receiver Address of receiving
     */
    function oRedeem(uint256 tokenAmount, address receiver) public {
        _abnormalRedeem(tokenAmount, receiver);
    }

    /**
     * @notice System shutdown under the redemption rule 
     * @param tokenAmount The number coin
     */
    function oRedeem(uint256 tokenAmount) public {
        oRedeem(tokenAmount, msg.sender);
    }

    /**
     * @notice Refresh reward speed.
     */
    function setRewardSpeed(uint256 speed) public onlyWhiter {
        updateIndex();
        rewardSpeed = speed;
    }

    /**
     * @notice Used to correct the effect of one's actions on one's own earnings
     *         System shutdown will no longer count
     */
    function updateIndex() public {
        if (esm.isClosed()) {
            return;
        }

        uint256 blockNumber = getBlockNumber();
        uint256 deltBlock = blockNumber.sub(rewardState.block);

        if (deltBlock > 0) {
            uint256 accruedReward = rewardSpeed.mul(deltBlock);
            uint256 ratio = totalToken == 0
                ? 0
                : accruedReward.mul(doubleScale).div(totalToken);
            rewardState.index = rewardState.index.add(ratio);
            rewardState.block = blockNumber;
            emit IndexUpdate(deltBlock, blockNumber, rewardState.index);
        }
    }

    /**
     * @notice Used to correct the effect of one's actions on one's own earnings
     *         System shutdown will no longer count
     * @param account staker address
     */
    function accuredToken(address account) internal {
        updateIndex();
        StakerState storage stakerState = stakerStates[account];
        stakerState.reward = _getReward(account);
        stakerState.index = rewardState.index;
    }

    /**
     * @notice Calculate the current holder's mining income
     * @param staker Address of holder
     */
    function _getReward(address staker) internal view returns (uint256 value) {
        StakerState storage stakerState = stakerStates[staker];
        value = stakerState.reward.add(
            rewardState.index.sub(stakerState.index).mul(tokens[staker]).div(
                doubleScale
            )
        );
    }

    /**
     * @notice Estimate the mortgagor's reward
     * @param account Address of staker
     */
    function getHolderReward(address account)
        public
        view
        returns (uint256 value)
    {
        uint256 blockReward2 = (totalToken == 0 || esm.isClosed())
            ? 0
            : getBlockNumber()
                .sub(rewardState.block)
                .mul(rewardSpeed)
                .mul(tokens[account])
                .div(totalToken);
        value = _getReward(account) + blockReward2;
    }

    /**
     * @notice Extract the current reward in one go
     * @param holder Address of receiver
     */
    function claimToken(address holder) public {
        accuredToken(holder);
        StakerState storage stakerState = stakerStates[holder];
        uint256 value = stakerState.reward.min(reward);
        require(value > 0, "The reward of address is zero.");

        coin.transfer(holder, value);
        reward = reward.sub(value);

        stakerState.index = rewardState.index;
        stakerState.reward = stakerState.reward.sub(value);
        emit ClaimToken(holder, value);
    }

    /**
     * @notice Get block number now
     */
    function getBlockNumber() public view returns (uint256) {
        return block.number;
    }

    /**
     * @notice Inject token to reward
     * @param amount The number of injecting
     */
    function injectReward(uint256 amount) external onlyOwner {
        coin.transferFrom(msg.sender, address(this), amount);
        reward = reward.add(amount);
        emit InjectReward(amount);
    }

    /**
     * @notice Extract token from reward
     * @param account Address of receiver
     * @param amount The number of extracting
     */
    function extractReward(address account, uint256 amount) external onlyOwner {
        require(amount <= reward, "withdraw overflow.");
        coin.transfer(account, amount);
        reward = reward.sub(amount);
        emit ExtractReward(account, amount);
    }

    
}