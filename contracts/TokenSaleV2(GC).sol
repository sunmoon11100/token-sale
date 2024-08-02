// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./libs/Referral.sol";

contract TokenSaleV2 is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using Referral for Referral.Tree;
    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using SafeMathUpgradeable for uint256;

    /** @dev Divisor for calculating percentages. 100/10000=0.01=1%. */
    uint256 public constant DECIMALS = 10_000;
    /** @dev The number of seconds in a day. 60*60*24=86400. */
    uint256 public constant SECONDS_PER_DAY = 24 * 60 * 60;

    IERC20MetadataUpgradeable public token;

    mapping(address => uint256) public price;
    mapping(address => uint256) public minAmount;

    Referral.Tree private refTree;
    uint16[] public refLevelRate;

    // Struct to store staking info
    struct StakingInfo {
        uint256 amount;
        uint256 reward;
        uint256 refReward;
        uint256 dailyRefReward;
        uint16 rewardRate;
        uint16 lockingDays;
        uint48 stakedAt;
        uint48 lastCalcRewardAt; // lastClaimedAt
        uint48 lastCalcRefRewardAt;
        uint80 __gap;
    }

    mapping(address => StakingInfo) public stakers;
    uint256 public minStakeAmount;

    mapping(address => uint16) public investorRewardRates;

    struct Timestamps {
        uint48 lastReinvestedAt;
        uint48 lastRewardClaimedAt;
        uint48 lastRefRewardClaimedAt;
        uint48 lastSoldAt;
        uint64 __gap;
    }

    mapping(address => Timestamps) public timestamps;

    // solhint-disable-next-line var-name-mixedcase
    bytes32 private constant _SELL_TYPEHASH =
        keccak256("sell(address sender,uint256 amount,address[] tokens,uint256[] prices,uint256 nonce)");
    address public verifier;
    mapping(address => CountersUpgradeable.Counter) private _nonces;

    uint256 public totalStakedAmount;
    uint256 public totalRewardRate;
    address public admin;
    uint256 public maxStakeAmount;
    uint256 public stopStakingTimestamp;

    event Bought(address indexed account, address indexed _token, uint256 _amount, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event ClaimedReward(address indexed account, uint256 amount);
    event ClaimedRefReward(address indexed account, uint256 amount);
    event Sold(address indexed account, uint256 amount, address[] tokens, uint256[] prices);
    event Staked(address indexed account, uint256 amount, uint256 rewardRate);
    event UpdatedDailyRefReward(address indexed account, uint256 dailyRefReward);
    event UpdatedPrice(address indexed _token, uint256 _price);
    event VerifierUpdated(address verifier);
    event AdminUpdated(address admin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _token) public initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __EIP712_init("TokenSale", "2");

        token = IERC20MetadataUpgradeable(_token);
        admin = _msgSender();
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function nonces(address owner) public view returns (uint256) {
        return _nonces[owner].current();
    }

    /**
     * @dev "Consume a nonce": return the current value and increment.
     */
    function _useNonce(address owner) internal virtual returns (uint256 current) {
        CountersUpgradeable.Counter storage nonce = _nonces[owner];
        current = nonce.current();
        nonce.increment();
    }

    function stake(uint256 amount, address referrer) public whenNotPaused nonReentrant {
        StakingInfo storage staker = stakers[_msgSender()];
        require(staker.amount.add(amount) >= minStakeAmount, "Invalid amount");
        token.safeTransferFrom(_msgSender(), address(this), amount);

        _claimReward(_msgSender());
        _stake(_msgSender(), staker.amount.add(amount), false);

        if (!refTree.hasReferrer(_msgSender())) {
            if (
                referrer != address(0) &&
                referrer != _msgSender() &&
                !refTree.isCircularReference(referrer, _msgSender())
            ) {
                register(referrer);
            } else {
                if (admin != address(0)) register(admin);
            }
        }
    }

    function _stake(address account, uint256 amount, bool isReinvest) internal {
        require(amount <= maxStakeAmount, "Reached the maximum");

        StakingInfo storage staker = stakers[account];
        (uint16 rate, uint16 lockingDays) = _calcRewardRate(account, amount.div(10 ** token.decimals()));

        // Referral reward
        uint256 prevDailyRefReward = MathUpgradeable
            .mulDiv(staker.amount, staker.rewardRate, DECIMALS)
            .div(30)
            .div(10 ** token.decimals())
            .mul(10 ** token.decimals());
        uint256 curDailyRefReward = MathUpgradeable
            .mulDiv(amount, rate, DECIMALS)
            .div(30)
            .div(10 ** token.decimals())
            .mul(10 ** token.decimals());
        address referrer = _msgSender();
        uint256 length = refLevelRate.length;
        for (uint256 i; i < length; ) {
            referrer = refTree.linearTree[referrer].referrer;
            if (referrer == address(0)) break;

            uint256 _curDailyRefReward = stakers[referrer].dailyRefReward.add(
                MathUpgradeable.mulDiv(curDailyRefReward, refLevelRate[i], DECIMALS)
            );
            uint256 _prevDailyRefReward = MathUpgradeable.mulDiv(prevDailyRefReward, refLevelRate[i], DECIMALS);
            if (_curDailyRefReward < _prevDailyRefReward) {
                _prevDailyRefReward = _curDailyRefReward;
            }
            _claimRefReward(referrer);
            stakers[referrer].dailyRefReward = _curDailyRefReward.sub(_prevDailyRefReward);
            emit UpdatedDailyRefReward(referrer, stakers[referrer].dailyRefReward);

            unchecked {
                ++i;
            }
        }
        totalRewardRate =
            ((totalStakedAmount * totalRewardRate) - (staker.amount * staker.rewardRate) + (amount * rate)) /
            totalStakedAmount.sub(staker.amount).add(amount);
        totalStakedAmount = totalStakedAmount.sub(staker.amount).add(amount);

        staker.amount = amount;
        staker.rewardRate = rate;
        if (!isReinvest) staker.lockingDays = lockingDays;
        staker.stakedAt = uint48(block.timestamp);

        emit Staked(account, staker.amount, staker.rewardRate);
    }

    function reinvest(uint256 amount) public whenNotPaused nonReentrant {
        _claimReward(_msgSender());

        StakingInfo storage staker = stakers[_msgSender()];
        require(0 < amount && amount <= staker.reward, "Invalid amount");
        require(
            (block.timestamp.sub(timestamps[_msgSender()].lastReinvestedAt)).div(SECONDS_PER_DAY) > 7,
            "You've already reinvested this week"
        );
        timestamps[_msgSender()].lastReinvestedAt = uint48(block.timestamp);

        staker.reward = staker.reward.sub(amount);

        _stake(_msgSender(), staker.amount.add(amount), true);
    }

    function reinvestRefReward(uint256 amount) public whenNotPaused nonReentrant {
        _claimReward(_msgSender());
        _claimRefReward(_msgSender());

        StakingInfo storage staker = stakers[_msgSender()];
        require(0 < amount && amount <= staker.refReward, "Invalid amount");

        staker.refReward = staker.refReward.sub(amount);

        _stake(_msgSender(), staker.amount.add(amount), true);
    }

    function claim(uint256 amount) public nonReentrant {
        _claim(_msgSender(), amount);
    }

    function _claim(address account, uint256 amount) internal {
        StakingInfo storage staker = stakers[account];
        require(amount > 0 && amount <= staker.amount, "Invalid amount");
        require(
            (SECONDS_PER_DAY.mul(staker.lockingDays)).add(staker.stakedAt) < block.timestamp,
            "You can't withdraw yet"
        );

        _claimReward(account);
        _stake(account, staker.amount.sub(amount), true);

        token.safeTransfer(account, amount);

        emit Claimed(account, amount);
    }

    function forceClaim(address account, uint256 amount) external onlyOwner {
        _claim(account, amount);
    }

    function _calcRewardRate(address account, uint256 amount) internal view returns (uint16 rate, uint16 lockingDays) {
        if (investorRewardRates[account] > 0) {
            rate = investorRewardRates[account];
            lockingDays = 0;
        } else {
            if (amount < 5_000_000) {
                rate = 800;
                lockingDays = 90;
            } else if (amount < 25_000_000) {
                rate = 1000;
                lockingDays = 120;
            } else if (amount < 125_000_000) {
                rate = 1200;
                lockingDays = 180;
            } else {
                rate = 1400;
                lockingDays = 270;
            }
        }
    }

    function calcReward(address account) public view returns (uint256) {
        StakingInfo storage staker = stakers[account];
        uint256 diffDays = (
            MathUpgradeable.min(block.timestamp, stopStakingTimestamp).sub(
                MathUpgradeable.max(staker.lastCalcRewardAt, staker.stakedAt)
            )
        ).div(SECONDS_PER_DAY);
        return
            staker
                .reward
                .add(MathUpgradeable.mulDiv(staker.amount, staker.rewardRate, DECIMALS).mul(diffDays).div(30))
                .div(10 ** token.decimals())
                .mul(10 ** token.decimals());
    }

    function claimReward(uint256 amount) public nonReentrant {
        _claimReward(_msgSender(), amount);

        token.safeTransfer(_msgSender(), amount);
    }

    function claimReward(address _token, uint256 amount) public nonReentrant {
        require(price[_token] > 0, "Invalid token");

        _claimReward(_msgSender(), amount);

        uint256 _amount = MathUpgradeable.mulDiv(amount, price[_token], 10 ** token.decimals());
        IERC20MetadataUpgradeable(_token).safeTransfer(_msgSender(), _amount);
    }

    function _claimReward(address account, uint256 amount) internal {
        _claimReward(account);

        StakingInfo storage staker = stakers[account];
        require(0 < amount && amount <= staker.reward, "Invalid amount");
        require(
            (block.timestamp.sub(timestamps[account].lastRewardClaimedAt)).div(SECONDS_PER_DAY) > 30,
            "You can claim in the next month"
        );

        staker.reward = staker.reward.sub(amount);
        timestamps[account].lastRewardClaimedAt = uint48(block.timestamp);

        emit ClaimedReward(account, amount);
    }

    function _claimReward(address account) internal {
        StakingInfo storage staker = stakers[account];
        staker.reward = calcReward(account);
        staker.lastCalcRewardAt = uint48(block.timestamp);
    }

    function calcRefReward(address account) public view returns (uint256) {
        StakingInfo storage staker = stakers[account];
        uint256 diffSeconds = MathUpgradeable.min(block.timestamp, stopStakingTimestamp).sub(
            staker.lastCalcRefRewardAt
        );
        return
            staker
                .refReward
                .add(staker.dailyRefReward.div(SECONDS_PER_DAY).mul(diffSeconds))
                .div(10 ** token.decimals())
                .mul(10 ** token.decimals());
    }

    function claimRefReward(uint256 amount) public nonReentrant {
        _claimRefReward(_msgSender(), amount);

        token.safeTransfer(_msgSender(), amount);
    }

    function claimRefReward(address _token, uint256 amount) public nonReentrant {
        require(price[_token] > 0, "Invalid token");

        _claimRefReward(_msgSender(), amount);

        uint256 _amount = MathUpgradeable.mulDiv(amount, price[_token], 10 ** token.decimals());
        IERC20MetadataUpgradeable(_token).safeTransfer(_msgSender(), _amount);
    }

    function _claimRefReward(address account, uint256 amount) internal {
        _claimRefReward(account);

        StakingInfo storage staker = stakers[account];
        require(0 < amount && amount <= staker.refReward, "Invalid amount");
        require(
            (block.timestamp.sub(timestamps[account].lastRefRewardClaimedAt)).div(SECONDS_PER_DAY) > 30,
            "You can claim in the next month"
        );

        staker.refReward = staker.refReward.sub(amount);
        timestamps[account].lastRefRewardClaimedAt = uint48(block.timestamp);

        emit ClaimedRefReward(account, amount);
    }

    function _claimRefReward(address account) internal {
        StakingInfo storage staker = stakers[account];
        staker.refReward = calcRefReward(account);
        staker.lastCalcRefRewardAt = uint48(block.timestamp);
    }

    function getLinearNode(address account) public view returns (Referral.LinearNode memory) {
        return refTree.linearTree[account];
    }

    function getPartnersInStaking(address account) public view returns (uint256) {
        uint256 count;
        address[] storage referees = refTree.linearTree[account].referees;
        uint256 length = referees.length;
        for (uint256 i = 0; i < length; ) {
            if (stakers[referees[i]].amount > 0) {
                ++count;
            }
            unchecked {
                ++i;
            }
        }

        return count;
    }

    function register(address referrer) public {
        _register(_msgSender(), referrer);
    }

    function register(address account, address referrer) external onlyOwner {
        _register(account, referrer);
    }

    function register(address[] calldata _accounts, address[] calldata _referrers) external onlyOwner {
        uint256 length = _accounts.length;
        for (uint256 i; i < length; ) {
            _register(_accounts[i], _referrers[i]);
            unchecked {
                ++i;
            }
        }
    }

    function removeReferrer(address account) external onlyOwner {
        refTree.removeReferrer(account);
    }

    function _register(address account, address referrer) internal nonReentrant {
        refTree.register(account, referrer);
    }

    function setRefLevelRate(uint16[] calldata _refLevelRate) external onlyOwner {
        refLevelRate = _refLevelRate;
    }

    function setPrice(address _token, uint256 _price) external onlyOwner {
        price[_token] = _price;
        emit UpdatedPrice(_token, _price);
    }

    function setMinStakeAmount(uint256 _amount) external onlyOwner {
        minStakeAmount = _amount;
    }

    function setMaxStakeAmount(uint256 _amount) external onlyOwner {
        maxStakeAmount = _amount;
    }

    function setInvestorRewardRates(address[] calldata accounts, uint16 rate) external onlyOwner {
        uint256 length = accounts.length;
        for (uint256 i; i < length; ) {
            investorRewardRates[accounts[i]] = rate;

            StakingInfo storage staker = stakers[accounts[i]];
            uint16 rewardRate = rate;
            uint16 lockingDays = 0;

            if (rate == 0) {
                (rewardRate, lockingDays) = _calcRewardRate(accounts[i], staker.amount.div(10 ** token.decimals()));
            }

            totalRewardRate =
                ((totalStakedAmount * totalRewardRate) -
                    (staker.amount * staker.rewardRate) +
                    (staker.amount * rewardRate)) /
                totalStakedAmount;

            staker.rewardRate = rewardRate;
            staker.lockingDays = lockingDays;

            unchecked {
                ++i;
            }
        }
    }

    function setStopStakingTimestamp(uint256 _stopStakingTimestamp) external onlyOwner {
        stopStakingTimestamp = _stopStakingTimestamp;
    }

    function setVerifier(address _verifier) external onlyOwner {
        verifier = _verifier;
        emit VerifierUpdated(_verifier);
    }

    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
        emit AdminUpdated(_admin);
    }

    function withdraw(address _token, uint256 _amount) external onlyOwner {
        IERC20MetadataUpgradeable(_token).safeTransfer(_msgSender(), _amount);
    }
}
